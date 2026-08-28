import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

final class LogicAccessibility {
    let bundleIdentifier = "com.apple.logic10"

    func health() -> [String: Any] {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        var result: [String: Any] = [
            "accessibility_trusted": AXIsProcessTrusted(),
            "logic_running": !applications.isEmpty,
            "logic_pid": applications.first.map { Int($0.processIdentifier) } ?? NSNull(),
            "bundle_identifier": bundleIdentifier
        ]
        result["project_document"] = (try? projectDocumentPath()) ?? NSNull()
        return result
    }

    // MARK: - Read-only discovery

    func listWindows() throws -> [[String: Any]] {
        try logicWindows().map { window in
            [
                "title": stringAttribute(window, kAXTitleAttribute as String),
                "subrole": stringAttribute(window, kAXSubroleAttribute as String),
                "is_main": stringAttribute(window, kAXMainAttribute as String) == "1",
                "document": documentPath(of: window) ?? NSNull(),
                "kind": documentPath(of: window) != nil ? "project" : "plugin_or_auxiliary"
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
