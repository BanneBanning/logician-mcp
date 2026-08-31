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
        func browseCell(in bottom: String) -> String {
            let start = bottom.index(bottom.startIndex, offsetBy: min(emptyIndex * 7, bottom.count))
            // The name spills over several LCD fields; cut at the first long
            // gap so trailing slot fields do not leak into it — and take the
            // NEIGHBOUR'S "--" back off when the gap was too short to cut at
            // (see normalizedBrowseEntry: this is what used to defeat the wrap
            // test and what used to be reported as `browser_entry`).
            let raw = String(bottom[start...])
            let cut = raw.range(of: "    ").map { String(raw[..<$0.lowerBound]) } ?? raw
            return normalizedBrowseEntry(cut)
        }
        func browseName() -> String? {
            guard let status = freshStatus(),
                  let bottom = status["lcd_bottom"] as? String else { return nil }
            return browseCell(in: bottom)
        }
        func matches(_ shown: String) -> Bool {
            browseEntryMatches(shown, requested: pluginName)
        }
        func abortBrowse() {
            exitToPan()
        }
        // How many entries the browse has actually advanced from the No Plug-in
        // origin an EMPTY slot always starts at — which is why this is a
        // coordinate and not a guess: the slot was chosen for being empty two
        // dozen lines up. Counted by NAME CHANGES rather than by messages sent,
        // because a message sent into an unfinished repaint is swallowed (see
        // PluginCatalogMap for the measurements that settled this).
        var position = 0
        // The catalog in the order this browse met it. A read that repeats its
        // predecessor is the list not having moved, not a wrap; a wrap is the
        // FIRST entry reappearing after real progress.
        var entries: [String] = []
        var observed: [PluginCatalogMap.Entry] = []
        var found = false
        // Observations are only worth keeping while the walk is CONTIGUOUS
        // from the origin: a map with a hole in it could answer "first match"
        // with an entry that has an unseen earlier twin, and then this tool
        // would quietly start choosing a different one of two same-named
        // catalog entries than it used to.
        var contiguous = true
        var catalog = loadPluginCatalog()
        /// The ordinal a cached hint sent this browse to, once it has been
        /// consulted: nil = not yet, 0 = consulted and no usable hint.
        var jumpedToward: Int?
        var stepsSinceJump = 0
        /// Set while the next read is a jump's landing, whose ordinal the jump
        /// itself already accounted for — so it must not be counted twice.
        var landedByJump = false
        /// One entry forward, PACED: the next message is not sent until this
        /// one has visibly landed.
        ///
        /// Pacing is the whole job. Firing 2-tick messages as fast as the
        /// socket allows loses most of them — measured 2026-08-31, 46% of them
        /// over 500 messages and 76% over 2500, so an unpaced walk gets slower
        /// per ENTRY the deeper it goes (42 ms/entry early, 610 ms/entry at
        /// depth) even though each message looks cheap. Waiting for the cell to
        /// CHANGE spends exactly one repaint per entry and no more, which is
        /// both the fastest and the only shape that scales: the old fixed
        /// settle every fourth step held the loss to 18% and cost 66 ms/entry.
        ///
        /// A catalog holding the same display name at two adjacent positions
        /// times out here instead of returning early. That costs one timeout
        /// and undercounts the ordinal by one, which is the harmless direction
        /// (see `PluginCatalogMap`).
        func stepForward(from shown: String) throws -> Bool {
            let response = try MCUBridge.send(.vpot(index: emptyIndex, delta: browseTicksPerEntry))
            guard response.ok else { return false }
            _ = waitFor(seconds: 0.25) { status in
                (status["lcd_bottom"] as? String).map { browseCell(in: $0) != shown } ?? false
            }
            return true
        }
        /// Carries the browse `entries` entries from where it is now. Nothing is
        /// written by a browse — it is uncommitted until the vpot press — so a
        /// jump that lands in the wrong place costs steps and nothing else.
        func jump(entries entriesToJump: Int) throws -> Bool {
            for chunk in browseJumpPlan(ticks: entriesToJump * browseTicksPerEntry) {
                let before = freshStatus()?["received_events"] as? Int ?? -1
                guard try MCUBridge.send(.vpot(index: emptyIndex, delta: chunk)).ok else {
                    return false
                }
                position += chunk / browseTicksPerEntry
                _ = awaitEvents(since: before, timeoutMs: 400)
                // A 31-entry jump repaints far more of the row than a single
                // step does, and Logic goes on advancing the list while it
                // does: measured 2026-08-31, a second chunk sent into that
                // repaint is swallowed, so the landing is neither where it was
                // asked for nor reversible. Wait for real silence between
                // chunks and before reading.
                _ = waitForSurfaceQuiet(seconds: 2.0)
            }
            return true
        }
        let searchDeadline = Date().addingTimeInterval(browseSearchBudget)
        while entries.count < browseEntryCap, Date() < searchDeadline {
            let name = browseName() ?? ""
            if !name.isEmpty, name != MCULCDStrings.emptySlot {
                if matches(name) {
                    // The target is one more entry advanced, same as any other
                    // changed name — this is the ordinal that gets cached.
                    if !landedByJump { position += 1 }
                    found = true
                    break
                }
                if name != entries.last {
                    if let first = entries.first, name == first, entries.count > 2 {
                        // A full lap with no match. The walk has now SEEN the
                        // whole catalog, which is the one thing this failure is
                        // good for: keep the map before reporting it.
                        if contiguous {
                            var learned = catalog ?? PluginCatalogMap()
                            learned.merge(observed, coveredPositions: position)
                            savePluginCatalog(learned)
                        }
                        abortBrowse()
                        throw LogicianError.trackNotExposed(
                            requested: "plugin '\(pluginName)' in the control-surface browser",
                            exposed: "the browser wrapped around without a match; entries seen: \(entries.joined(separator: ", "))"
                        )
                    }
                    // A name that CHANGED is one entry advanced — the only
                    // trustworthy way to count them.
                    if !landedByJump { position += 1 }
                    entries.append(name)
                    if contiguous {
                        observed.append(PluginCatalogMap.Entry(name: name, position: position))
                    }
                }
                // The catalog is a property of the Logic install, so a previous
                // browse already knows where this plug-in lives. Take the jump
                // once, and only once the format annotation is on screen — the
                // mono and stereo catalogs are not the same list.
                if jumpedToward == nil, let known = catalog,
                   let hint = known.position(
                       matching: pluginName, format: browseEntryFormat(name)
                   ),
                   hint - browseJumpUndershootEntries > position {
                    jumpedToward = hint
                    contiguous = false
                    guard try jump(
                        entries: hint - browseJumpUndershootEntries - position
                    ) else { abortBrowse(); return nil }
                    landedByJump = true
                    continue
                }
                // No usable hint on the first real entry means there will not
                // be one later either; stop asking.
                if jumpedToward == nil { jumpedToward = 0 }
            }
            // A jump that has not paid off within a few steps was a wrong hint,
            // and a map that has been caught out is deleted rather than trusted
            // again — the walk carries on and still finds the plug-in, or still
            // wraps, exactly as it would have from cold.
            if let hint = jumpedToward, hint > 0 {
                stepsSinceJump += 1
                if catalog != nil, stepsSinceJump > browseJumpGraceSteps {
                    discardPluginCatalog()
                    catalog = nil
                }
            }
            guard try stepForward(from: name) else { abortBrowse(); return nil }
            landedByJump = false
        }
        guard found else {
            // Cut short rather than wrapped, so the catalog may well go on past
            // where this stopped. Say so — and keep what was enumerated, which
            // is the only thing this failure produced worth having.
            if contiguous {
                var learned = catalog ?? PluginCatalogMap()
                learned.merge(observed, coveredPositions: position)
                savePluginCatalog(learned)
            }
            abortBrowse()
            throw LogicianError.openVerificationFailed(
                "the plugin browser never showed '\(pluginName)' in the \(entries.count)"
                    + " catalog entries it looked at"
                    + (entries.count >= browseEntryCap
                        ? " (the \(browseEntryCap)-entry limit)"
                        : " in \(Int(browseSearchBudget)) s (the search budget)")
                    + ", and never came back round to where it started — so the catalog may well"
                    + " go on past there. Check the spelling, or name a plug-in nearer the top of"
                    + " Logic's list. Nothing was written"
            )
        }
        // The display could still advance one more entry after the matching
        // read, so prove it has stopped before confirming anything — but prove
        // it, rather than sleeping through it.
        //
        // The blind `Thread.sleep(0.3)` this replaces was insuring against a
        // real effect: measured 2026-08-31 on the unpaced loop, the cell moved
        // one entry past the match 33-47 ms after the matching read, on 3 of 3
        // runs, and the back-step loop below then fired on every one of them.
        // Pacing removed the cause — a change-driven step cannot leave ticks in
        // flight to arrive late — and on the paced walk and the jump alike the
        // surface was already silent (`timed_out` on the first ask) with zero
        // corrections needed. The 150 ms silence proof is kept because it is a
        // PROOF and it is nearly free; the correction loop is kept untouched
        // because it is verification, not waiting.
        waitForSurfaceQuiet(seconds: 0.6)
        var settledName = browseName()
        var corrections = 0
        while let drifted = settledName, !matches(drifted), corrections < 4 {
            _ = try? MCUBridge.send(.vpot(index: emptyIndex, delta: -browseTicksPerEntry))
            // Positive check first: the back-step landed when the target is on
            // screen (measured 47-57 ms), and only if it never shows up does
            // this fall back to proving the surface has gone quiet — which is
            // what the blind 0.4 s used to buy, more slowly and less honestly.
            let recovered = waitFor(seconds: 0.5) { status in
                (status["lcd_bottom"] as? String).map { matches(browseCell(in: $0)) } ?? false
            }
            if recovered == nil { waitForSurfaceQuiet(seconds: 0.5) }
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
        // This coordinate is the good one: read after the settle, corrected for
        // the drift, and proven by the name test that is about to gate the
        // press. Keep it — and everything the walk passed on the way — so the
        // next browse for any of them is a jump instead of a walk. Nothing is
        // kept from a browse that jumped: see PluginCatalogMap.ticks(matching:)
        // for why a map with a hole in it would be worse than no map.
        if contiguous {
            var learned = catalog ?? PluginCatalogMap()
            learned.merge(
                observed + [PluginCatalogMap.Entry(name: settled, position: position)],
                coveredPositions: position
            )
            savePluginCatalog(learned)
        }
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
