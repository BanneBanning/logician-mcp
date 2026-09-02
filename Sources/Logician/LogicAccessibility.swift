import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

final class LogicAccessibility {
    let bundleIdentifier = "com.apple.logic10"

    /// Everything `logic_health` needs off the process and Accessibility
    /// planes, gathered in ONE pass: one `runningApplications` lookup, one
    /// window walk, and the resolved process handed back so the UI-language
    /// inference does not repeat the lookup either.
    struct HealthFacts {
        /// The `logic_health` keys that come from this plane.
        let payload: [String: Any]
        /// The running Logic, or nil when it is not running. Passed on rather
        /// than looked up again.
        let application: NSRunningApplication?
        /// Titles of the dialogs, sheets and floating windows Logic had open
        /// at the moment of the walk — the evidence that tells "the surface
        /// was never set up" apart from "Logic is sitting on a modal". Not a
        /// modality proof; see `modalWindowTitles(in:)`.
        let dialogTitles: [String]
    }

    func healthFacts() -> HealthFacts {
        let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier).first
        let trusted = AXIsProcessTrusted()
        var result: [String: Any] = [
            "accessibility_trusted": trusted,
            "logic_running": application != nil,
            "logic_pid": application.map { Int($0.processIdentifier) } ?? NSNull(),
            "bundle_identifier": bundleIdentifier
        ]
        // One walk, two answers. `projectDocumentPath()` took its own and
        // `modalWindowTitles()` would have taken a third.
        let windows: [AXUIElement] = trusted
            ? application.map { self.windows(ofProcess: $0.processIdentifier) } ?? []
            : []
        result["project_document"] = windows.lazy
            .compactMap { self.documentPath(of: $0) }.first ?? NSNull()
        return HealthFacts(
            payload: result,
            application: application,
            dialogTitles: modalWindowTitles(in: windows)
        )
    }

    func health() -> [String: Any] { healthFacts().payload }

    // MARK: - Read-only discovery

    func listWindows() throws -> [[String: Any]] {
        try logicWindows().map { window in
            // `default_button` / `cancel_button` are the LOCALE-INDEPENDENT
            // way to answer a dialog: the titles of whatever `AXDefaultButton`
            // and `AXCancelButton` point at. Reported here because this is
            // where a dialog on screen is already being described, and because
            // it is the probe that says whether a given Logic dialog CAN be
            // answered without reading English — the question a locale session
            // has to answer per dialog. `null` means the window publishes no
            // such attribute, and the code falls back to matching the button's
            // English title (see `AXDialogShape`).
            let defaultTitle = defaultButton(of: window)
                .map { stringAttribute($0, kAXTitleAttribute as String) }
            let cancelTitle = cancelButton(of: window)
                .map { stringAttribute($0, kAXTitleAttribute as String) }
            return [
                "title": stringAttribute(window, kAXTitleAttribute as String),
                "subrole": stringAttribute(window, kAXSubroleAttribute as String),
                "is_main": stringAttribute(window, kAXMainAttribute as String) == "1",
                "document": documentPath(of: window) ?? NSNull(),
                "kind": documentPath(of: window) != nil ? "project" : "plugin_or_auxiliary",
                "default_button": defaultTitle ?? NSNull(),
                "cancel_button": cancelTitle ?? NSNull()
            ]
        }
    }

    func projectDocumentPath() throws -> String {
        for window in try logicWindows() {
            if let path = documentPath(of: window) {
                return path
            }
        }
        throw LogicianError.windowNotFound("project window with AXDocument")
    }

    func listTracks() throws -> [String: Any] {
        let headers = try parsedTrackHeaders()
        let tracks: [[String: Any]] = headers.map { header in
            var entry: [String: Any] = [
                "track_number": header.number,
                "track_name": header.name,
                "selected": header.selected,
                "is_stack": header.disclosure != nil
            ]
            if let expanded = header.expanded {
                entry["expanded"] = expanded
            }
            return entry
        }
        // Is this every track? The honest answer is "provably not" or "cannot
        // tell", never "yes" — see TrackListCompleteness for why, and for the
        // audit finding that made this the loudest field in the result instead
        // of a footnote on a successful one.
        let scroll = tracksAreaScrollable()
        let verdict = TrackListCompleteness.evaluate(
            rows: headers.map {
                TrackListCompleteness.Row(
                    number: $0.number, name: $0.name,
                    isStack: $0.disclosure != nil, expanded: $0.expanded
                )
            },
            scrollable: scroll.scrollable
        )
        var result: [String: Any] = [
            "project_document": (try? projectDocumentPath()) ?? NSNull(),
            "tracks": tracks,
            "visible_tracks": tracks.count,
            "partial": verdict.partial,
            "completeness": verdict.completeness,
            "partial_evidence": verdict.evidence,
            "note": TrackListCompleteness.standingNote
        ]
        if !verdict.missingTrackNumbers.isEmpty {
            result["missing_track_numbers"] = verdict.missingTrackNumbers
        }
        if let scrollable = scroll.scrollable {
            result["tracks_area_scrollable"] = scrollable
        }
        return result
    }

    func listInserts(trackName: String) throws -> [String: Any] {
        let strip = try inspectorStrip(named: trackName)
        let slots = insertSlots(of: strip)
        return [
            "project_document": (try? projectDocumentPath()) ?? NSNull(),
            "track": trackName, "track_name": trackName,
            "strip_source": "left_inspector_channel_strip",
            "inserts": slots.map(\.dictionary)
        ]
    }

}
