import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {

    /// The third proof, taken after the PL view is up and before a browser
    /// write: the list the surface shows must agree with the one
    /// Accessibility reads off the same strip. Throws when they disagree,
    /// returns the evidence otherwise — `"ax_insert_list"` when the check ran,
    /// `"unavailable"` when no inspector shows the strip and it could not.
    /// See `pluginListAgreesWithAX` for the observation that made this
    /// necessary: the SELECT LED can be right while the PL view is not.
    @discardableResult
    static func verifyPluginListStrip(
        inserts: [String], logic: LogicAccessibility, trackName: String
    ) throws -> String {
        let axNames = (try? logic.insertPluginNames(trackName: trackName)) ?? []
        switch pluginListAgreesWithAX(mcuCells: inserts, axNames: axNames) {
        case true?:
            return "ax_insert_list"
        case false?:
            exitToPan()
            throw LogicianError.verificationFailed(
                requested: "the control surface's plug-in list to be '\(trackName)'s",
                actual: "it shows [\(inserts.filter { !$0.isEmpty && $0 != MCULCDStrings.emptySlot }.joined(separator: ", "))]"
                    + " while Accessibility reads [\(axNames.joined(separator: ", "))] on that strip"
                    + " — the PL view is pointed at another channel (a SELECT press on an already-lit"
                    + " strip is a no-op; select a different strip and come back). Nothing was written",
                restored: true
            )
        case nil:
            // No inspector shows this strip, so there is nothing to compare
            // against — never a reason to refuse a working operation.
            return "unavailable"
        }
    }

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
        // Prove the surface is pointed at the intended strip BEFORE the view
        // that cannot name it is entered (see selectChannelVerified).
        try selectChannelVerified(channel: channel, expectedName: trackName)
        guard let inserts = try pluginInsertNames() else { return nil }
        let listEvidence = try verifyPluginListStrip(
            inserts: inserts, logic: logic, trackName: trackName
        )
        guard let emptyIndex = inserts.firstIndex(where: {
            $0.isEmpty || $0 == MCULCDStrings.emptySlot
        }) else {
            throw LogicianError.trackNotExposed(
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
            let response = try MCUBridge.send(.vpot(index: emptyIndex, delta: 2))
            guard response.ok else { abortBrowse(); return nil }
            _ = awaitEvents(since: before, timeoutMs: 250)
            if step % 4 == 3 { _ = quiescentStatus() }
            guard let name = browseName(), !name.isEmpty, name != MCULCDStrings.emptySlot else { continue }
            if matches(name) { found = true; break }
            if name == entries.last { continue }
            if let first = entries.first, name == first, entries.count > 2 {
                abortBrowse()
                throw LogicianError.trackNotExposed(
                    requested: "plugin '\(pluginName)' in the control-surface browser",
                    exposed: "the browser wrapped around without a match; entries seen: \(entries.joined(separator: ", "))"
                )
            }
            entries.append(name)
        }
        guard found else {
            abortBrowse()
            throw LogicianError.openVerificationFailed(
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
            _ = try? MCUBridge.send(.vpot(index: emptyIndex, delta: -2))
            Thread.sleep(forTimeInterval: 0.4)
            _ = quiescentStatus()
            settledName = browseName()
            corrections += 1
        }
        guard let settled = settledName, matches(settled) else {
            abortBrowse()
            throw LogicianError.verificationFailed(
                requested: "'\(pluginName)' shown at confirmation time",
                actual: "the browser entry drifted to '\(browseName() ?? "?")' and back-stepping could not recover it; aborted without instantiating",
                restored: true
            )
        }
        let shownName = settled
        // Confirm: vpot press instantiates and drops into the edit view.
        let response = try MCUBridge.send(.vpotPress(index: emptyIndex))
        guard response.ok else { abortBrowse(); return nil }
        // The press drops the surface into the plugin-edit view, and it gets
        // there at once: measured 2026-08-31 over four live adds, the
        // assignment already read `P<slot>` on the FIRST status read after the
        // press returned (0-1 ms), while the blind `Thread.sleep(1.0)` this
        // replaces went on waiting for another full second. Wait for the view
        // POSITIVELY instead. What that second was really insuring against —
        // a plugin that has not finished instantiating when its slot is read —
        // is not dropped, it moves to the readback below, where it is spent
        // only when it is actually needed.
        _ = waitFor(seconds: 1.5) { status in
            (status["assignment"] as? String).map(isPluginEditAssignment) ?? false
        }
        _ = quiescentStatus()
        // Verify: back in the plugin list the slot is occupied.
        guard let after = try pluginInsertNames() else { return nil }
        func slotCell(_ cells: [String]) -> String {
            cells.indices.contains(emptyIndex)
                ? cells[emptyIndex].trimmingCharacters(
                    in: CharacterSet(charactersIn: MCULCDStrings.bypassMarker)
                )
                : ""
        }
        var slotName = slotCell(after)
        if slotName.isEmpty || slotName == MCULCDStrings.emptySlot {
            // Waiting for the NAME to appear rather than for a duration to
            // elapse: a slow plugin gets as long as it needs, a fast one
            // costs nothing at all.
            _ = waitFor(seconds: 2.0) { status in
                guard let bottom = status["lcd_bottom"] as? String else { return false }
                let cell = slotCell(lcdFields(bottom))
                return !cell.isEmpty && cell != MCULCDStrings.emptySlot
            }
            if let bottom = freshStatus()?["lcd_bottom"] as? String {
                slotName = slotCell(lcdFields(bottom))
            }
        }
        guard !slotName.isEmpty, slotName != MCULCDStrings.emptySlot else {
            exitToPan()
            throw LogicianError.verificationFailed(
                requested: "'\(pluginName)' instantiated in slot \(emptyIndex + 1)",
                actual: "the slot still shows empty after confirmation",
                restored: false
            )
        }
        // The surface stays on the insert list, which `pluginInsertNames` just
        // proved by content. Returning to Pan costs ~3.3 s — measured
        // 2026-08-31 at 30% of this entire call — and the next plugin tool
        // only has to leave again, so record the debt instead and let it be
        // settled by whoever actually needs the Pan view. Same mechanism, and
        // the same three ways of settling, as the read tools use.
        deferSurfaceRestore(SurfaceDebt(strip: trackName, view: "plugin_list", slot: nil))
        // Cross-verify through Accessibility — an independent source that
        // names the strip, so a wrong-channel insertion cannot pass silently.
        var axConfirmed = false
        var axReachable = false
        for _ in 0..<10 {
            // Readable-but-empty is REACHABLE and not confirmed: that is the
            // strip saying the plugin is not there, which must fail the call,
            // not degrade it to a warning.
            if let names = try? logic.insertPluginNames(trackName: trackName) {
                axReachable = true
                if names.contains(where: { axNamesPlugin($0, requested: pluginName) }) {
                    axConfirmed = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        guard axConfirmed || !axReachable else {
            exitToPan()
            throw LogicianError.verificationFailed(
                requested: "'\(pluginName)' on '\(trackName)' (AX cross-check)",
                actual: "the LCD claimed success but the strip's AX insert list never showed the plugin — it may have landed on another channel; check the mixer",
                restored: false
            )
        }
        var result: [String: Any] = [
            "success": true,
            "verified": true,
            "state": "added",
            "plugin": pluginName,
            "browser_entry": shownName,
            "mcu_slot": emptyIndex + 1,
            "write_route": "mcu_plugin_browser",
            "cross_check": axConfirmed ? "ax_insert_list" : "unavailable",
            // Which strip the PL view was proven to belong to BEFORE the
            // browse, independently of the SELECT LED.
            "pl_view_check": listEvidence,
            "note": "Added via the control-surface plugin browser — no mouse, no menus."
        ]
        // A headerless output/aux/bus strip is only in the inspector while
        // something is showing it, so the independent check can be MISSING
        // rather than failed. Degrade the check, never the honesty: the write
        // stands on the surface's own evidence and the result says so.
        if !axReachable {
            appendWarning(
                "The independent Accessibility cross-check could not run: no inspector strip named "
                    + "'\(trackName)' is on screen. The insertion is confirmed only by the control "
                    + "surface's own echo (the strip was LCD/LED-verified as selected before the write, "
                    + "and its MCU slot now names the plugin). Open the Mixer or select a track routed "
                    + "to it and re-read the inserts if you want a second source.",
                to: &result
            )
        }
        return result
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
        try selectChannelVerified(channel: channel, expectedName: trackName)
        guard let inserts = try pluginInsertNames() else { return nil }
        let listEvidence = try verifyPluginListStrip(
            inserts: inserts, logic: logic, trackName: trackName
        )
        // Match the target slot by LCD name (truncated) against the request.
        let matches = inserts.enumerated().filter { _, name in
            let cleaned = name.trimmingCharacters(
                in: CharacterSet(charactersIn: MCULCDStrings.bypassMarker)
            )
            guard !cleaned.isEmpty, cleaned != MCULCDStrings.emptySlot else { return false }
            return lcdNameMatches(track: pluginName, lcd: cleaned)
                || pluginName.lowercased().hasPrefix(cleaned.lowercased())
        }
        guard matches.count == 1, let target = matches.first else {
            exitToPan()
            throw LogicianError.trackNotExposed(
                requested: "exactly one insert matching '\(pluginName)'",
                exposed: "MCU slots: " + inserts.enumerated()
                    .map { "\($0 + 1): \($1.isEmpty ? MCULCDStrings.emptySlot : $1)" }.joined(separator: ", ")
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
            let response = try MCUBridge.send(.vpot(index: slotIndex, delta: -2))
            guard response.ok else { exitToPan(); return nil }
            _ = awaitEvents(since: before, timeoutMs: 250)
            if step % 4 == 3 { _ = quiescentStatus() }
            if browseName() == MCULCDStrings.emptySlot { reached = true; break }
        }
        guard reached else {
            exitToPan()
            throw LogicianError.openVerificationFailed(
                "the browser never reached the No Plug-in entry within 400 steps; nothing was changed (browse abandoned)"
            )
        }
        // Settle and re-verify "--" is still shown before confirming.
        _ = quiescentStatus()
        Thread.sleep(forTimeInterval: 0.3)
        var corrections = 0
        while browseName() != MCULCDStrings.emptySlot, corrections < 4 {
            _ = try? MCUBridge.send(.vpot(index: slotIndex, delta: 2))
            Thread.sleep(forTimeInterval: 0.4)
            _ = quiescentStatus()
            corrections += 1
        }
        guard browseName() == MCULCDStrings.emptySlot else {
            exitToPan()
            throw LogicianError.verificationFailed(
                requested: "the No Plug-in entry shown at confirmation time",
                actual: "the entry drifted to '\(browseName() ?? "?")'; aborted without removing",
                restored: true
            )
        }
        let response = try MCUBridge.send(.vpotPress(index: slotIndex))
        guard response.ok else { exitToPan(); return nil }
        Thread.sleep(forTimeInterval: 1.0)
        _ = quiescentStatus()
        guard let after = try pluginInsertNames() else { return nil }
        exitToPan()
        let nowEmpty = !after.indices.contains(slotIndex)
            || after[slotIndex].isEmpty || after[slotIndex] == MCULCDStrings.emptySlot
        // AX cross-check: the plugin must be gone from the strip's inserts.
        var axGone = false
        var axReachable = false
        for _ in 0..<10 {
            if let names = try? logic.insertPluginNames(trackName: trackName) {
                axReachable = true
                if !names.contains(where: { axNamesPlugin($0, requested: pluginName) }) {
                    axGone = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        guard nowEmpty, axGone || !axReachable else {
            throw LogicianError.verificationFailed(
                requested: "'\(pluginName)' removed from '\(trackName)'",
                actual: nowEmpty
                    ? "the LCD slot cleared but AX still lists the plugin"
                    : "the LCD slot still shows '\(after[slotIndex])'",
                restored: false
            )
        }
        var result: [String: Any] = [
            "success": true,
            "verified": true,
            "state": "removed",
            "plugin": pluginName,
            "mcu_slot": slotIndex + 1,
            "write_route": "mcu_plugin_browser",
            "cross_check": axGone ? "ax_insert_list" : "unavailable",
            "pl_view_check": listEvidence,
            "note": "Removed via the control-surface plugin browser's No Plug-in entry — no mouse, no menus."
        ]
        if !axReachable {
            appendWarning(
                "The independent Accessibility cross-check could not run: no inspector strip named "
                    + "'\(trackName)' is on screen. The removal is confirmed only by the control "
                    + "surface's own echo (the strip was LCD/LED-verified as selected before the write, "
                    + "and its MCU slot now reads empty).",
                to: &result
            )
        }
        return result
    }

}
