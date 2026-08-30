import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

/// G30's pure half: reading Logic's own live preview off the Remove Silence
/// window.
enum RemoveSilence {
    /// "9 Regions" / "1 Region" -> 9 / 1. nil for anything else, because a
    /// preview that cannot be read must not be reported as a number.
    static func previewCount(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().contains("region") else { return nil }
        let digits = trimmed.prefix { $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
        return Int(digits)
    }
}

extension LogicAccessibility {
    // MARK: - Remove Silence (G30 — Logic 12's "strip silence")

    /// COVERAGE calls this row "strip silence". Logic Pro 12.3.1 has no
    /// command by that name at all: the Key Commands window's own row is
    /// **`Remove Silence from Audio Region…`** (⌃X, in the "Windows Showing
    /// Audio Files" group), verified 2026-08-28. It opens a floating window
    /// titled `Remove Silence`.
    static let removeSilenceCommand = KeyCommandRegistry.Name.removeSilenceFromAudioRegion

    /// The Remove Silence floating window.
    ///
    /// STILL TITLE-GATED: the window publishes no identifier this server has
    /// measured, and its shape (a few numeric groups, a checkbox, OK/Cancel)
    /// is not distinctive. A translated title means the command fires and the
    /// tool reports that no window appeared — nothing is left standing, so the
    /// failure is safe. Checklist item.
    func removeSilenceWindow(timeout: Double = 6) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let window = (try? logicWindows())?.first(where: {
                stringAttribute($0, kAXTitleAttribute as String) == LogicUIStrings.Window.removeSilence
            }) { return window }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return nil
    }

    /// The window's whole state as data: Logic's live region-count preview,
    /// the zero-crossing flag, and the four numeric fields as their displayed
    /// strings. The numbers are per-digit steppers (`AXSlider` `Segment N`,
    /// `AXIncrement`/`AXDecrement`), the same species as the bounce dialog's
    /// position fields, and this server does not write them — see the tool
    /// description.
    func readRemoveSilenceWindow(_ window: AXUIElement) -> [String: Any] {
        var state: [String: Any] = [:]
        var numbers: [String] = []
        for child in children(of: window) {
            switch stringAttribute(child, kAXRoleAttribute as String) {
            case "AXStaticText":
                let value = stringAttribute(child, kAXValueAttribute as String)
                if let count = RemoveSilence.previewCount(value) {
                    state["preview_regions"] = count
                    state["preview_text"] = value
                }
            case "AXCheckBox":
                state[stringAttribute(child, kAXTitleAttribute as String)] =
                    stringAttribute(child, kAXValueAttribute as String) == "1"
            case "AXGroup":
                let value = stringAttribute(child, kAXValueAttribute as String)
                if !value.isEmpty { numbers.append(value) }
            default:
                break
            }
        }
        // Reported in the window's own child order, which is the order the
        // labels follow them in: minimum silence time, post release, pre
        // attack, threshold (measured 2026-08-28 — the threshold is the one
        // with a -80...0 range, so it is identifiable on its own).
        if !numbers.isEmpty { state["numeric_fields_in_order"] = numbers }
        return state
    }

    /// Runs Logic's Remove Silence on ONE audio region.
    ///
    /// `apply: false` (the default) is the interesting mode: the window
    /// publishes a LIVE preview of how many regions the current settings would
    /// produce, so an agent can ask "what would this do?" and get a number
    /// without touching the arrangement. `apply: true` presses OK and verifies
    /// against the arrangement map.
    func removeSilence(
        trackName: String, regionName: String?, startBar: Int?, apply: Bool
    ) throws -> [String: Any] {
        let before = try regionSnapshot(trackName: trackName)
        let selection = try selectRegion(
            trackName: trackName, regionName: regionName, startBar: startBar, exclusive: true
        )
        // An audio-only function: on a MIDI region the command does nothing
        // and the window never appears, which would look like a bug.
        if let type = selection["type"] as? String, type != "audio" {
            throw LogicianError.currentValueMismatch(
                expected: "an AUDIO region",
                actual: "'\(selection["name"] ?? "?")' is a \(type) region. Remove Silence only "
                    + "works on audio; nothing was opened."
            )
        }
        var committed = false
        defer {
            if !committed, let window = removeSilenceWindow(timeout: 0.4),
               let cancel = abortButton(of: window, maximumDepth: 1) {
                _ = AXUIElementPerformAction(cancel, kAXPressAction as CFString)
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        try fireKeyCommand(
            LogicAccessibility.removeSilenceCommand,
            learnIfMissing: true, source: "logic_remove_silence"
        )
        guard let window = removeSilenceWindow() else {
            throw LogicianError.windowNotFound(
                "the Remove Silence window (the command fired; a MIDI region or a region Logic "
                    + "considers empty opens nothing)"
            )
        }
        let state = readRemoveSilenceWindow(window)
        guard apply else {
            return [
                "success": true, "verified": true, "state": "previewed",
                "applied": false,
                "track_name": trackName,
                "region": selection["name"] ?? NSNull(),
                "settings": state,
                "note": "NOTHING WAS CHANGED. `settings.preview_regions` is Logic's own live count of "
                    + "how many regions the CURRENT threshold and time settings would leave. Call "
                    + "again with apply: true to commit. The four numeric fields (threshold, minimum "
                    + "silence, pre-attack, post-release) are per-digit steppers this server does not "
                    + "write - change them in Logic's window if the preview is wrong."
            ]
        }
        guard let ok = confirmButton(of: window, maximumDepth: 1) else {
            throw LogicianError.windowNotFound("the OK button in the Remove Silence window")
        }
        _ = AXUIElementPerformAction(ok, kAXPressAction as CFString)
        committed = true
        var after = before
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.4)
            after = (try? regionSnapshot(trackName: trackName)) ?? after
            if after.count != before.count { break }
        }
        let expected = state["preview_regions"] as? Int
        let produced = after.count - before.count + 1
        var result: [String: Any] = [
            "success": after.count != before.count,
            "verified": expected == nil ? false : (produced == expected),
            "state": after.count != before.count ? "applied" : "unchanged",
            "applied": true,
            "track_name": trackName,
            "regions_before": before.count,
            "regions_after": after.count,
            "regions_produced": produced,
            "preview_regions": expected ?? NSNull(),
            "settings": state,
            "note": "One region became \(produced). Undo restores the single region. The gaps are "
                + "gone from the ARRANGEMENT, not from the audio file - the file is untouched."
        ]
        if let expected, produced != expected {
            result["warning"] = "Logic's own preview said \(expected) regions and the arrangement map "
                + "shows \(produced). The map only counts VISIBLE track rows, so a scrolled-out row "
                + "explains a low count; anything else means the operation did not do what the "
                + "preview promised."
        }
        if after.count == before.count {
            result["note"] = "The region count did not move: OK was pressed and nothing happened. "
                + "Either the settings produce one region (nothing was silent enough) or the window "
                + "did not accept the press."
        }
        return result
    }
}
