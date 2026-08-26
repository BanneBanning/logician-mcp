import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {
    // MARK: Plugin insertion via the MCU plugin browser (mouse-free)

    /// Adds a plugin to the selected track's first empty insert slot by
    /// driving Logic's control-surface plugin browser: vpot turn on an empty
    /// slot steps through the plugin list (full names on the LCD), vpot
    /// press instantiates. Leaving to the pan view cancels a browse safely.
    /// Returns nil when the MCU route is unavailable.
    static func addPluginViaBrowser(
        pluginName: String, logic: LogicAccessibility, trackName: String
    ) throws -> [String: Any]? {
        guard freshStatus() != nil else { return nil }
        // The PL channel view shows the MCU-SELECTED track's inserts without
        // naming it — and MCU selection can diverge from the AX selection
        // (this once put plugins on Stereo Out). Bind the MCU selection to
        // the target track explicitly before entering the view.
        guard let channel = try findChannel(trackName: trackName) else { return nil }
        guard try selectFoundChannel(channel) else { return nil }
        guard let inserts = try pluginInsertNames() else { return nil }
        guard let emptyIndex = inserts.firstIndex(where: { $0.isEmpty || $0 == "--" }) else {
            throw DemoError.trackNotExposed(
                requested: "an empty insert slot",
                exposed: "all 8 MCU insert slots are occupied"
            )
        }
        func browseName() -> String? {
            guard let status = freshStatus(),
                  let bottom = status["lcd_bottom"] as? String else { return nil }
            let start = bottom.index(bottom.startIndex, offsetBy: min(emptyIndex * 7, bottom.count))
            // The name spills over several LCD fields; cut at the first long
            // gap so trailing slot fields do not leak into it.
            let raw = String(bottom[start...])
            let cut = raw.range(of: "    ").map { String(raw[..<$0.lowerBound]) } ?? raw
            return cut.trimmingCharacters(in: .whitespaces)
        }
        func matches(_ shown: String) -> Bool {
            // LCD shows e.g. "Compressor (s/s)"; strip the channel suffix and
            // compare prefixes both ways (either side may be truncated).
            let cleaned = shown.replacingOccurrences(
                of: #"\s*\([sm]/[sm]\)\s*$"#, with: "", options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { return false }
            let target = pluginName.trimmingCharacters(in: .whitespaces)
            return cleaned.lowercased() == target.lowercased()
                || cleaned.lowercased().hasPrefix(target.lowercased())
                || target.lowercased().hasPrefix(cleaned.lowercased())
        }
        func abortBrowse() {
            exitToPan()
        }
        // The LCD advances only every other vpot tick, so consecutive
        // duplicate names mean "not moved yet", not a wrap. A wrap is the
        // FIRST entry reappearing after real progress.
        var entries: [String] = []
        var found = false
        for step in 0..<500 {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            // The list advances one entry per TWO vpot ticks — send both at once.
            let response = try MCUBridge.send(["cmd": "vpot", "index": emptyIndex, "delta": 2])
            guard response["ok"] as? Bool == true else { abortBrowse(); return nil }
            _ = awaitEvents(since: before, timeoutMs: 250)
            if step % 4 == 3 { _ = quiescentStatus() }
            guard let name = browseName(), !name.isEmpty, name != "--" else { continue }
            if matches(name) { found = true; break }
            if name == entries.last { continue }
            if let first = entries.first, name == first, entries.count > 2 {
                abortBrowse()
                throw DemoError.trackNotExposed(
                    requested: "plugin '\(pluginName)' in the control-surface browser",
                    exposed: "the browser wrapped around without a match; entries seen: \(entries.joined(separator: ", "))"
                )
            }
            entries.append(name)
        }
        guard found else {
            abortBrowse()
            throw DemoError.openVerificationFailed(
                "the plugin browser never showed '\(pluginName)' within 250 steps"
            )
        }
        // The display can advance one more entry after the matching read
        // (trailing sysex from the double-tick) — settle and re-verify that
        // the shown entry is STILL the target before confirming anything.
        _ = quiescentStatus()
        Thread.sleep(forTimeInterval: 0.3)
        // The double-tick stepping tends to drift one entry past the match —
        // correct by stepping back until the target is shown again.
        var settledName = browseName()
        var corrections = 0
        while let drifted = settledName, !matches(drifted), corrections < 4 {
            _ = try? MCUBridge.send(["cmd": "vpot", "index": emptyIndex, "delta": -2])
            Thread.sleep(forTimeInterval: 0.4)
            _ = quiescentStatus()
            settledName = browseName()
            corrections += 1
        }
        guard let settled = settledName, matches(settled) else {
            abortBrowse()
            throw DemoError.verificationFailed(
                requested: "'\(pluginName)' shown at confirmation time",
                actual: "the browser entry drifted to '\(browseName() ?? "?")' and back-stepping could not recover it; aborted without instantiating",
                restored: true
            )
        }
        let shownName = settled
        // Confirm: vpot press instantiates and drops into the edit view.
        let response = try MCUBridge.send(["cmd": "vpot_press", "index": emptyIndex])
        guard response["ok"] as? Bool == true else { abortBrowse(); return nil }
        Thread.sleep(forTimeInterval: 1.0)
        _ = quiescentStatus()
        // Verify: back in the plugin list the slot is occupied.
        guard let after = try pluginInsertNames() else { return nil }
        let slotName = after.indices.contains(emptyIndex)
            ? after[emptyIndex].trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            : ""
        exitToPan()
        guard !slotName.isEmpty, slotName != "--" else {
            throw DemoError.verificationFailed(
                requested: "'\(pluginName)' instantiated in slot \(emptyIndex + 1)",
                actual: "the slot still shows empty after confirmation",
                restored: false
            )
        }
        // Cross-verify through Accessibility — an independent source that
        // names the track, so a wrong-channel insertion cannot pass silently.
        var axConfirmed = false
        for _ in 0..<10 {
            if let axInserts = (try? logic.listInserts(trackName: trackName))?["inserts"]
                as? [[String: Any]] {
                let names = axInserts.compactMap { $0["plugin_display_name"] as? String }
                if names.contains(where: {
                    $0.lowercased().hasPrefix(pluginName.lowercased())
                        || pluginName.lowercased().hasPrefix(
                            $0.trimmingCharacters(in: .whitespaces).lowercased())
                }) {
                    axConfirmed = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        guard axConfirmed else {
            throw DemoError.verificationFailed(
                requested: "'\(pluginName)' on track '\(trackName)' (AX cross-check)",
                actual: "the LCD claimed success but the track's AX insert list never showed the plugin — it may have landed on another channel; check the mixer",
                restored: false
            )
        }
        return [
            "success": true,
            "verified": true,
            "state": "added",
            "plugin": pluginName,
            "browser_entry": shownName,
            "mcu_slot": emptyIndex + 1,
            "write_route": "mcu_plugin_browser",
            "note": "Added via the control-surface plugin browser — no mouse, no menus."
        ]
    }

    /// Removes a plugin mouse-free: browse the occupied slot to the "--"
    /// (No Plug-in) entry at the list boundary and confirm. The boundary can
    /// be up to a full list away (~100 entries), so this takes up to ~60 s —
    /// still no pointer, no menus. Returns nil when MCU is unavailable.
    static func removePluginViaBrowser(
        pluginName: String, logic: LogicAccessibility, trackName: String
    ) throws -> [String: Any]? {
        guard freshStatus() != nil else { return nil }
        guard let channel = try findChannel(trackName: trackName) else { return nil }
        guard try selectFoundChannel(channel) else { return nil }
        guard let inserts = try pluginInsertNames() else { return nil }
        // Match the target slot by LCD name (truncated) against the request.
        let matches = inserts.enumerated().filter { _, name in
            let cleaned = name.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard !cleaned.isEmpty, cleaned != "--" else { return false }
            return lcdNameMatches(track: pluginName, lcd: cleaned)
                || pluginName.lowercased().hasPrefix(cleaned.lowercased())
        }
        guard matches.count == 1, let target = matches.first else {
            exitToPan()
            throw DemoError.trackNotExposed(
                requested: "exactly one insert matching '\(pluginName)'",
                exposed: "MCU slots: " + inserts.enumerated()
                    .map { "\($0 + 1): \($1.isEmpty ? "--" : $1)" }.joined(separator: ", ")
            )
        }
        let slotIndex = target.offset
        func browseName() -> String? {
            guard let status = freshStatus(),
                  let bottom = status["lcd_bottom"] as? String else { return nil }
            let start = bottom.index(bottom.startIndex, offsetBy: min(slotIndex * 7, bottom.count))
            let raw = String(bottom[start...])
            let cut = raw.range(of: "    ").map { String(raw[..<$0.lowerBound]) } ?? raw
            return cut.trimmingCharacters(in: .whitespaces)
        }
        // Browse backward toward the "--" boundary entry.
        var reached = false
        for step in 0..<400 {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            let response = try MCUBridge.send(["cmd": "vpot", "index": slotIndex, "delta": -2])
            guard response["ok"] as? Bool == true else { exitToPan(); return nil }
            _ = awaitEvents(since: before, timeoutMs: 250)
            if step % 4 == 3 { _ = quiescentStatus() }
            if browseName() == "--" { reached = true; break }
        }
        guard reached else {
            exitToPan()
            throw DemoError.openVerificationFailed(
                "the browser never reached the No Plug-in entry within 400 steps; nothing was changed (browse abandoned)"
            )
        }
        // Settle and re-verify "--" is still shown before confirming.
        _ = quiescentStatus()
        Thread.sleep(forTimeInterval: 0.3)
        var corrections = 0
        while browseName() != "--", corrections < 4 {
            _ = try? MCUBridge.send(["cmd": "vpot", "index": slotIndex, "delta": 2])
            Thread.sleep(forTimeInterval: 0.4)
            _ = quiescentStatus()
            corrections += 1
        }
        guard browseName() == "--" else {
            exitToPan()
            throw DemoError.verificationFailed(
                requested: "the No Plug-in entry shown at confirmation time",
                actual: "the entry drifted to '\(browseName() ?? "?")'; aborted without removing",
                restored: true
            )
        }
        let response = try MCUBridge.send(["cmd": "vpot_press", "index": slotIndex])
        guard response["ok"] as? Bool == true else { exitToPan(); return nil }
        Thread.sleep(forTimeInterval: 1.0)
        _ = quiescentStatus()
        guard let after = try pluginInsertNames() else { return nil }
        exitToPan()
        let nowEmpty = !after.indices.contains(slotIndex)
            || after[slotIndex].isEmpty || after[slotIndex] == "--"
        // AX cross-check: the plugin must be gone from the track's inserts.
        var axGone = false
        for _ in 0..<10 {
            if let axInserts = (try? logic.listInserts(trackName: trackName))?["inserts"]
                as? [[String: Any]] {
                let names = axInserts.compactMap { $0["plugin_display_name"] as? String }
                if !names.contains(where: {
                    $0.lowercased().hasPrefix(pluginName.lowercased())
                        || pluginName.lowercased().hasPrefix(
                            $0.trimmingCharacters(in: .whitespaces).lowercased())
                }) {
                    axGone = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        guard nowEmpty, axGone else {
            throw DemoError.verificationFailed(
                requested: "'\(pluginName)' removed from '\(trackName)'",
                actual: nowEmpty
                    ? "the LCD slot cleared but AX still lists the plugin"
                    : "the LCD slot still shows '\(after[slotIndex])'",
                restored: false
            )
        }
        return [
            "success": true,
            "verified": true,
            "state": "removed",
            "plugin": pluginName,
            "mcu_slot": slotIndex + 1,
            "write_route": "mcu_plugin_browser",
            "note": "Removed via the control-surface plugin browser's No Plug-in entry — no mouse, no menus."
        ]
    }

}
