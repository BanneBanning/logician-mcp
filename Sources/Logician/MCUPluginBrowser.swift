import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {

    /// Why the last plug-in browser call came back `nil` — i.e. "the MCU route
    /// is not available, try the other plane" — in words.
    ///
    /// `nil` is the browser's way of letting `allow_mouse: true` reach the
    /// Accessibility chooser, so it cannot be replaced by a throw. But it used
    /// to be the ONLY thing the caller got, and the caller spelled every one of
    /// them *"the MCU bridge is unavailable"*: measured live 2026-09-02,
    /// `logic_add_plugin` on `Sweeps` refused three times out of three with
    /// that sentence while `logic_health` reported the bridge running, the
    /// strip resolved and the insert list came up on screen a moment later —
    /// the real cause was `ensurePluginList` giving up one press short
    /// (`lastPluginListRefusal`). So every nil now leaves its reason here and
    /// the refusals quote it.
    nonisolated(unsafe) static var lastBrowserRefusal: String? // single-threaded server loop

    /// The reason to put in a refusal after a browser call returned nil: what
    /// the browser itself recorded, or what the plug-in list view recorded, or
    /// — when neither did — the honest fallback that the surface is not
    /// answering.
    static var browserUnavailabilityDetail: String {
        lastBrowserRefusal ?? lastPluginListRefusal
            ?? "the control surface did not answer; logic_health reports whether the MCU bridge is running"
    }

    /// A browse message the bridge would not send: records why, abandons the
    /// browse (which has written nothing) and hands the surface back to the
    /// Pan view. Both browsers call it on the same three occasions — a jump, a
    /// step, and the confirming press — so the reason is never lost to a bare
    /// `nil` again.
    static func browseSendFailed(_ what: String) {
        lastBrowserRefusal = "the bridge refused to send \(what) to the surface."
            + " The browse was abandoned before the confirming press, so nothing was written"
        exitToPan()
    }

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

    // MARK: What a browse that found nothing has to say for itself

    /// The refusal a forward search that never matched carries: how many
    /// catalog entries it looked at, which bound stopped it, WHAT IT SAW at
    /// both ends of the walk, and — the part that turns a dead end into an
    /// instruction — which of Logic's two catalogs it was walking.
    ///
    /// MEASURED LIVE 2026-09-02, and it is the whole reason this function
    /// exists. `logic_add_plugin {Crash, "Parametric EQ"}` walked **226
    /// entries in 15 s** and refused; the identical call on `Sweeps` finds the
    /// same plug-in at entry **1**. The difference is not the origin, the slot
    /// or the session: `Sweeps`' inserts browse the `(s/s)` catalog, which
    /// opens `Parametric EQ (s/s)` → `Low Pass Filter (s/s)` →
    /// `High Pass Filter (s/s)`, and `Crash`'s browse the `(m/m)` catalog,
    /// which opens `Low Pass Filter (m/m)` → `Chorus (m/m)` and had no
    /// `Parametric EQ` in the 226 entries there was time for. **The strip's
    /// channel format chooses the catalog**, `PluginCatalogMap` has said so
    /// about its cached ordinals since 2026-08-31, and the refusal an agent
    /// actually reads never mentioned it — so "not found" read as "not
    /// installed" on a plug-in that is one strip away.
    static func browseSearchRefusal(
        pluginName: String,
        slot: Int,
        entriesSeen: Int,
        opening: [String],
        tail: [String],
        format: String?,
        stoppedOnCap: Bool
    ) -> String {
        var text = "the plug-in browser never showed '\(pluginName)' in the \(entriesSeen)"
            + " catalog \(entriesSeen == 1 ? "entry" : "entries") it looked at"
            + (stoppedOnCap
                ? " (the \(browseEntryCap)-entry limit)"
                : " in \(Int(browseSearchBudget)) s (the search budget)")
            + ", and never came back round to where it started — so the catalog may well go on"
            + " past there."
        if !opening.isEmpty {
            text += " It opened at [\(opening.joined(separator: ", "))]"
            if !tail.isEmpty, tail != opening {
                text += " and was showing [\(tail.joined(separator: ", "))] when it stopped"
            }
            text += "."
        }
        if let format {
            text += " Slot \(slot) of this strip browses the \(format) catalog, and a MONO"
                + " strip's catalog is not a stereo strip's: a plug-in can be missing from one"
                + " of them, or sit far deeper in it (measured 2026-09-02 — 'Parametric EQ' is"
                + " entry 1 of the (s/s) catalog and was not in the first 226 entries of the"
                + " (m/m) one). Try the same plug-in on a strip of the other format, change this"
                + " strip's channel format in Logic, or name a plug-in this catalog has."
        } else {
            text += " Check the spelling, or name a plug-in nearer the top of Logic's list."
        }
        return text + " Nothing was written: a browse writes nothing until the confirming press,"
            + " and the press was never sent (browse abandoned)."
    }

    /// Whether the browse field is showing Logic's answer to the SELECT press —
    /// the strip's own NAME — rather than a catalog entry.
    ///
    /// MEASURED LIVE 2026-09-03 on `Drum Synth Kit`: `selectChannelVerified`
    /// presses SELECT, and Logic paints the channel's full name across the
    /// three LCD cells the browse field spans, so the insert row reads
    /// `Drum Synth Kit       Pedlba *Envlp …` while the slot's own content is
    /// `--`. It does NOT clear on its own — 1.5 s of event-driven waiting saw
    /// no further traffic — because the next thing to repaint that row is the
    /// browse itself.
    ///
    /// It matters twice. The origin check must not read it as a browse someone
    /// left standing; and the WALK must not count it as catalog entry 1, which
    /// is what shifts every ordinal by one and writes a name that is not a
    /// plug-in into `plugin-catalog-cache.json` — where three such entries were
    /// found sitting at position 1 (`Gain`, `LoPass ParEQ`,
    /// `Cha EQ Cha EQ Cha EQ Cha EQ`).
    ///
    /// The test is deliberately tighter than `lcdNameMatches`' subsequence
    /// rule: an exact name, or a truncation of it at least as long as an LCD
    /// name cell. A catalog entry that happened to be a subsequence of the
    /// track's name would otherwise be skipped.
    static func browseCellIsStripBanner(_ cell: String, trackName: String) -> Bool {
        let shown = cell.trimmingCharacters(in: .whitespaces).lowercased()
        let name = trackName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !shown.isEmpty, !name.isEmpty else { return false }
        return shown == name || (shown.count >= lcdNameCellWidth && name.hasPrefix(shown))
    }

    /// The refusal a browse that did not start at the No Plug-in entry carries.
    /// An empty slot's browse always opens there (measured on three slots,
    /// 2026-09-02), so a cell showing anything else means the slot is already
    /// mid-browse — left standing by a call that was cut off, or by another
    /// session driving the same surface — and every ordinal a walk from here
    /// produced would be measured from the wrong zero.
    static func browseOriginRefusal(
        slot: Int, showing: String, row: String? = nil, view: String? = nil
    ) -> String {
        "the browse on slot \(slot) opened on '\(showing)' instead of the No Plug-in entry"
            + (row.map { " (the surface's insert row reads '\($0)'" } ?? "")
            + (view.map { ", assignment \($0))" } ?? (row == nil ? "" : ")"))
            + ","
            + " so a walk from here would be counted from the wrong place. That slot is already"
            + " mid-browse: a browse writes nothing and is cancelled by leaving the view, so the"
            + " surface has been returned to the Pan view and this call is safe to repeat —"
            + " it will then start from the No Plug-in entry. Nothing was written"
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
        lastBrowserRefusal = nil
        guard freshStatus() != nil else {
            lastBrowserRefusal = "the surface's mirror is stale or the bridge is not running"
            return nil
        }
        // The PL channel view shows the MCU-SELECTED track's inserts without
        // naming it — and MCU selection can diverge from the AX selection
        // (this once put plugins on Stereo Out). Bind the MCU selection to
        // the target track explicitly before entering the view.
        guard let channel = try findChannel(trackName: trackName) else {
            lastBrowserRefusal = "the strip could not be resolved on the surface"
                + " (\(lastChannelResolution))"
            return nil
        }
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
        // THE ORIGIN, READ RATHER THAN ASSUMED. Every coordinate below — the
        // ordinal that gets cached, the jump's arithmetic, the "one more entry"
        // counting — is measured from the No Plug-in entry an empty slot starts
        // at, and until now that was an assumption resting on the slot having
        // been picked for being empty two dozen lines up.
        //
        // The assumption held on every strip probed live 2026-09-02 (`Sweeps`
        // slot 1 and slot 2, `Crash` slot 1: the cell reads `--`, the first
        // tick only widens the browse field and still reads `--`, the second
        // shows catalog entry 1, and −3 entries comes home to `--` exactly).
        // It is checked anyway because the one state that breaks it — a browse
        // left standing on this slot by an abandoned call — is invisible to the
        // slot-content read, and walking from an unknown position is how a
        // browse ends up looking at 226 entries with nothing to say about where
        // it started.
        //
        // The read is a POSITIVE WAIT, not a snapshot, because the row this
        // call has just been through paints over itself: `selectChannelVerified`
        // presses SELECT and Logic answers by writing the strip's full name
        // across the LCD for about a second (measured live 2026-09-02 — the
        // first version of this check read `Drum Synth Kit` off slot 1 and
        // refused a call that was perfectly fine). A banner clears; a standing
        // browse does not, so waiting for the boundary to appear tells the two
        // apart and costs nothing at all when the cell already reads `--`.
        func atOrigin(_ cell: String) -> Bool {
            cell.isEmpty || cell == MCULCDStrings.emptySlot
                || browseCellIsStripBanner(cell, trackName: trackName)
        }
        var origin = browseName() ?? ""
        if !atOrigin(origin) {
            _ = waitFor(seconds: 1.5) { status in
                (status["lcd_bottom"] as? String).map { atOrigin(browseCell(in: $0)) } ?? false
            }
            origin = browseName() ?? ""
        }
        guard atOrigin(origin) else {
            // Read the evidence BEFORE the restore, and carry it as a value.
            // The removal path learned this the expensive way: a message that
            // interpolates a surface read AFTER `exitToPan()` reports the PAN
            // view it just walked home to (see `removalDriftActual`).
            let seen = freshStatus()
            let refusal = browseOriginRefusal(
                slot: emptyIndex + 1, showing: origin,
                row: seen?["lcd_bottom"] as? String,
                view: seen?["assignment"] as? String
            )
            exitToPan()
            throw LogicianError.verificationFailed(
                requested: "the No Plug-in entry at the start of the browse",
                actual: refusal,
                restored: true
            )
        }
        let searchDeadline = Date().addingTimeInterval(browseSearchBudget)
        while entries.count < browseEntryCap, Date() < searchDeadline {
            let name = browseName() ?? ""
            if !name.isEmpty, name != MCULCDStrings.emptySlot,
               !browseCellIsStripBanner(name, trackName: trackName) {
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
                    ) else { browseSendFailed("a jump toward the cached position"); return nil }
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
            guard try stepForward(from: name) else {
                browseSendFailed("a step forward through the catalog")
                return nil
            }
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
                browseSearchRefusal(
                    pluginName: pluginName,
                    slot: emptyIndex + 1,
                    entriesSeen: entries.count,
                    opening: Array(entries.prefix(browseRefusalSampleEntries)),
                    tail: Array(entries.suffix(browseRefusalSampleEntries)),
                    format: entries.lazy.compactMap(browseEntryFormat).first,
                    stoppedOnCap: entries.count >= browseEntryCap
                )
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
        guard response.ok else { browseSendFailed("the confirming press"); return nil }
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

    // MARK: Pure removal resolution (unit-tested without a surface)

    /// Which slot (0-based offset into the 8 LCD cells) a removal should
    /// browse to "--". Resolution is by the same abbreviation-tolerant name
    /// match the browse verifies against, and it never guesses: a name that
    /// occupies several slots (three `Gain` inserts, observed 2026-08-31) is
    /// answered only by the caller's `insertSlot` — the Mackie physical slot
    /// 1-8, NOT the Accessibility insert_index. The LCD name proof holds on
    /// both paths: an `insertSlot` whose cell does not name the plugin is
    /// refused rather than cleared.
    static func resolveRemovalSlot(
        inserts: [String], pluginName: String, trackName: String, insertSlot: Int?
    ) throws -> Int {
        let matches = inserts.enumerated().filter { _, name in
            let cleaned = name.trimmingCharacters(
                in: CharacterSet(charactersIn: MCULCDStrings.bypassMarker)
            )
            guard !cleaned.isEmpty, cleaned != MCULCDStrings.emptySlot else { return false }
            return lcdNameMatches(track: pluginName, lcd: cleaned)
                || pluginName.lowercased().hasPrefix(cleaned.lowercased())
        }
        if let insertSlot {
            guard (1...8).contains(insertSlot) else {
                throw LogicianError.invalidArguments(
                    "insert_slot is the Mackie physical slot 1-8; got \(insertSlot)"
                )
            }
            guard matches.contains(where: { $0.offset == insertSlot - 1 }) else {
                let shown = inserts.indices.contains(insertSlot - 1)
                    && !inserts[insertSlot - 1].isEmpty
                    ? inserts[insertSlot - 1] : MCULCDStrings.emptySlot
                throw LogicianError.insertMismatch(
                    slot: insertSlot, expected: pluginName, actual: shown
                )
            }
            return insertSlot - 1
        }
        guard matches.count == 1, let target = matches.first else {
            guard !matches.isEmpty else {
                throw LogicianError.insertNotFound(
                    track: trackName, plugin: pluginName,
                    available: inserts.enumerated()
                        .filter { !$1.isEmpty && $1 != MCULCDStrings.emptySlot }
                        .map { "\($0 + 1): \($1)" }
                )
            }
            throw LogicianError.insertAmbiguous(
                track: trackName, plugin: pluginName,
                slots: matches.map { $0.offset + 1 }, parameter: "insert_slot"
            )
        }
        return target.offset
    }

    /// How many entries a removal's backward jump carries, given the ordinal
    /// the catalog map holds for the plug-in being removed and how far the
    /// browse has already travelled from where that plug-in sits. nil when
    /// there is no jump worth taking — the boundary is already inside the
    /// undershoot margin.
    ///
    /// The invariant is the whole point, and it is the one the add path does
    /// not need: for an exact hint the landing is
    /// `browseRemovalUndershootEntries` entries ABOVE the `--` origin, and for
    /// a hint that is too small — the only direction a cached ordinal can err,
    /// see `PluginCatalogMap` — it is further above still. So the jump can
    /// never carry the browse PAST the boundary, which is the one failure that
    /// costs a whole catalog lap instead of a step.
    static func removalJumpEntries(cachedOrdinal: Int, entriesTravelled: Int) -> Int? {
        let distance = cachedOrdinal - entriesTravelled - browseRemovalUndershootEntries
        return distance > 0 ? distance : nil
    }

    /// The refusal a backward walk that never reached `--` carries: how many
    /// catalog ENTRIES it looked at, which of the two bounds stopped it, and
    /// the last entries it still had on screen.
    ///
    /// Counted in entries because the old bound was counted in MESSAGES — 400
    /// of them, which at the unpaced loop's 15-23% swallow rate was ~330
    /// entries of a 590+-entry catalog (measured 2026-09-02), so the message
    /// "within 400 steps" was true and useless: it never said the browse had
    /// not been near the boundary.
    static func removalBoundaryRefusal(
        entriesSeen: Int, tail: [String], jumped: Bool
    ) -> String {
        let bound = entriesSeen >= browseEntryCap
            ? "the \(browseEntryCap)-entry limit"
            : "the \(Int(browseRemovalBudget)) s search budget"
        var text = "the browser never reached the No Plug-in entry: it looked at"
            + " \(entriesSeen) catalog \(entriesSeen == 1 ? "entry" : "entries")"
            + " and stopped on \(bound)"
        if !tail.isEmpty {
            text += ", still showing [\(tail.joined(separator: ", "))]"
        }
        text += ". The boundary is the top of the list, so a browse that has not"
            + " reached it has not been near it."
        if jumped {
            text += " The cached catalog position this browse jumped to cannot have been"
                + " right, and has been discarded — the next attempt walks instead, which is"
                + " slower but needs no cache."
        }
        return text + " Nothing was written: a browse writes nothing until the"
            + " confirming press, and the press was never sent (browse abandoned)."
    }

    /// The `actual` half of the drift refusal — the one failure mode the
    /// confirmation guard exists to explain.
    ///
    /// It takes the cell as a VALUE because the message used to read it as a
    /// side effect, `browseName()` interpolated AFTER `exitToPan()` had already
    /// run: so it reported a PAN row. Live 2026-09-02 it said the entry had
    /// "drifted to '0'", which is strip 1's pan value and not a catalog entry
    /// at all — and that reading had already cost one wrong diagnosis in
    /// `profiles/logic_add_plugin.md`, where the same '0' was attributed to
    /// another session pulling the surface out of the plug-in list.
    static func removalDriftActual(driftedTo: String?) -> String {
        "the entry drifted to '\(driftedTo ?? "?")' (read on the plug-in list, before the"
            + " surface was restored) and stepping back to the No Plug-in entry could not"
            + " recover it; aborted without removing"
    }

    /// Whether the LCD insert row read back after the confirming press shows
    /// the removal. Two honest after-states exist: the slot reads empty, or
    /// Logic closed the gap and the later inserts slid up one — the old row
    /// with the cleared cell dropped and an empty cell appended. Anything
    /// else (the name still in place, a reshuffle) is a failed removal.
    ///
    /// Which one Logic actually does is now measured, and it is the first:
    /// 2026-09-02, `Gain` removed from MCU slot 1 with `Parametric EQ` sitting
    /// in slot 2, the row went `["Gain", "ParEQ", …]` → `["--", "ParEQ", …]`
    /// and an independent `logic_list_inserts {route: "mcu"}` agreed. **Logic
    /// clears the slot in place; it does not compact.** The compaction branch
    /// below is therefore defensive rather than load-bearing — kept because one
    /// observation on one Logic version is thin ground for deleting a
    /// tolerance that costs nothing, and because the AX numbering DOES compact
    /// (`insert_index` is the occupied-slot ordinal), so the two planes really
    /// do disagree about this row.
    static func lcdRowShowsRemoval(before: [String], after: [String], slotIndex: Int) -> Bool {
        guard after.indices.contains(slotIndex) else { return true }
        func empty(_ cell: String) -> Bool { cell.isEmpty || cell == MCULCDStrings.emptySlot }
        if empty(after[slotIndex]) { return true }
        guard before.indices.contains(slotIndex) else { return false }
        var compacted = Array(before[(slotIndex + 1)...])
        compacted.append("")
        return zip(after[slotIndex...], compacted).allSatisfy { shown, expected in
            (empty(shown) && empty(expected)) || shown == expected
        }
    }

    /// The duplicate-aware reading of the removal's AX cross-check. With one
    /// instance on the strip, "the name is gone" is the proof — but one of
    /// three `Gain` inserts removed still leaves `Gain` listed, so when the
    /// strip held several instances the honest signal is the COUNT dropping.
    /// `beforeCount` is nil when the strip's AX list was unreadable before
    /// the press; absence is then the only bar left.
    static func axConfirmsRemoval(
        beforeCount: Int?, afterNames: [String], pluginName: String
    ) -> Bool {
        let after = afterNames.filter { axNamesPlugin($0, requested: pluginName) }.count
        guard let beforeCount, beforeCount > 0 else { return after == 0 }
        return after < beforeCount
    }

    /// Removes a plugin mouse-free: browse the occupied slot BACKWARD to the
    /// "--" (No Plug-in) entry at the list boundary and confirm. Returns nil
    /// when MCU is unavailable. `insertSlot` (Mackie physical 1-8) names the
    /// slot when the same display name occupies several of them.
    ///
    /// The distance to the boundary is exactly the removed plug-in's catalog
    /// ordinal, and that is the number `plugin-catalog-cache.json` already
    /// holds — so this jumps most of the way (deliberately UNDERSHOOTING, see
    /// `removalJumpEntries`) and paces the rest on the cell CHANGING, the same
    /// two mechanisms `addPluginViaBrowser` has carried since 2026-08-31. Both
    /// arrived here on 2026-09-02, with the walk's every-4th-step
    /// `quiescentStatus`, its blind settle sleeps and the blind second after
    /// the press replaced by proofs; measured mean 8553 ms before.
    ///
    /// Every proof the call had is still here and in the same order: the LCD
    /// name proof before the press, the SELECT LED, the PL-view cross-check
    /// against Accessibility, the slot readback and the duplicate-aware AX
    /// cross-check.
    static func removePluginViaBrowser(
        pluginName: String, logic: LogicAccessibility, trackName: String,
        insertSlot: Int? = nil
    ) throws -> [String: Any]? {
        lastBrowserRefusal = nil
        guard freshStatus() != nil else {
            lastBrowserRefusal = "the surface's mirror is stale or the bridge is not running"
            return nil
        }
        guard let channel = try findChannel(trackName: trackName) else {
            lastBrowserRefusal = "the strip could not be resolved on the surface"
                + " (\(lastChannelResolution))"
            return nil
        }
        try selectChannelVerified(channel: channel, expectedName: trackName)
        guard let inserts = try pluginInsertNames() else { return nil }
        let listEvidence = try verifyPluginListStrip(
            inserts: inserts, logic: logic, trackName: trackName
        )
        // Resolve WHICH slot to clear before anything is pressed — by LCD
        // name while it is unique, by the caller's insert_slot when it is not.
        let slotIndex: Int
        do {
            slotIndex = try resolveRemovalSlot(
                inserts: inserts, pluginName: pluginName,
                trackName: trackName, insertSlot: insertSlot
            )
        } catch {
            exitToPan()
            throw error
        }
        // The instance count AX sees BEFORE the press, so the cross-check
        // afterwards can tell "one of three removed" from "nothing happened".
        let axCountBefore = (try? logic.insertPluginNames(trackName: trackName))
            .map { names in names.filter { axNamesPlugin($0, requested: pluginName) }.count }
        func browseCell(in bottom: String) -> String {
            let start = bottom.index(bottom.startIndex, offsetBy: min(slotIndex * 7, bottom.count))
            // The entry spills over several LCD fields; cut at the first long
            // gap, then take the NEIGHBOUR'S "--" back off. A BARE "--" is left
            // alone by `normalizedBrowseEntry` (PluginCatalogTests covers
            // exactly that), which is what makes the shared reader safe to use
            // for the boundary test itself — and it stops the refusals below
            // reporting `Parametric EQ (s/s)  --` as an entry.
            let raw = String(bottom[start...])
            let cut = raw.range(of: "    ").map { String(raw[..<$0.lowerBound]) } ?? raw
            return normalizedBrowseEntry(cut)
        }
        func browseName() -> String? {
            guard let status = freshStatus(),
                  let bottom = status["lcd_bottom"] as? String else { return nil }
            return browseCell(in: bottom)
        }
        func atBoundary(_ shown: String) -> Bool { shown == MCULCDStrings.emptySlot }
        /// One entry BACKWARD, paced: the next message is not sent until this
        /// one has visibly landed.
        ///
        /// The unpaced loop this replaces fired 2-tick messages as fast as the
        /// socket allowed and lost 15-23% of them into unfinished repaints
        /// (measured 2026-09-02 over three live removals; `awaitEvents(250)`
        /// never once timed out, 0 of 126). That is not only slow — 56 ms per
        /// entry, and worse the deeper it goes — it is what made one removal in
        /// four FAIL: the loop left ticks in flight, so the read that declared
        /// the boundary reached was stale (the settle's `quiescentStatus`
        /// returned in 31 ms against 153-158 ms on the runs that worked), and
        /// four blind corrections then spent 2243 ms recovering nothing.
        /// Waiting for the cell to CHANGE spends exactly one repaint per entry
        /// and cannot leave a tick in flight to arrive late.
        func stepBackward(from shown: String) throws -> Bool {
            let response = try MCUBridge.send(.vpot(index: slotIndex, delta: -browseTicksPerEntry))
            guard response.ok else { return false }
            _ = waitFor(seconds: 0.25) { status in
                (status["lcd_bottom"] as? String).map { browseCell(in: $0) != shown } ?? false
            }
            return true
        }
        /// Carries the browse `entriesToJump` entries BACKWARD from where it
        /// is now. Nothing is written by a browse — it is uncommitted until the
        /// vpot press — so a jump that lands in the wrong place costs steps and
        /// nothing else. See `waitForSurfaceQuiet` for why the chunks are not
        /// allowed to run into each other.
        func jump(entries entriesToJump: Int) throws -> Bool {
            for chunk in browseJumpPlan(ticks: -entriesToJump * browseTicksPerEntry) {
                let before = freshStatus()?["received_events"] as? Int ?? -1
                guard try MCUBridge.send(.vpot(index: slotIndex, delta: chunk)).ok else {
                    return false
                }
                _ = awaitEvents(since: before, timeoutMs: 400)
                _ = waitForSurfaceQuiet(seconds: 2.0)
            }
            return true
        }
        // Browse backward toward the "--" boundary entry.
        var reached = false
        /// Entries this browse actually LOOKED at — name changes, which is the
        /// only trustworthy count (a swallowed message advances nothing).
        var entriesSeen = 0
        /// …plus the ones a jump carried it over: how far it has travelled from
        /// the ordinal the removed plug-in sits at, which is what the cached
        /// hint is measured against.
        var entriesTravelled = 0
        var tail: [String] = []
        var lastName: String?
        /// nil = the map has not been consulted yet, 0 = consulted and it had
        /// nothing usable.
        var hintTaken: Int?
        var jumpedEntries = 0
        var stepsSinceJump = 0
        var catalog = loadPluginCatalog()
        let deadline = Date().addingTimeInterval(browseRemovalBudget)
        func rememberTail(_ name: String) {
            tail.append(name)
            if tail.count > browseRemovalTailEntries { tail.removeFirst() }
        }
        while entriesSeen < browseEntryCap, Date() < deadline {
            let name = browseName() ?? ""
            if atBoundary(name) { reached = true; break }
            if browseCellIsStripBanner(name, trackName: trackName) {
                // Logic's answer to the SELECT press, not an entry this walk
                // passed (see browseCellIsStripBanner).
                guard try stepBackward(from: name) else {
                    browseSendFailed("a step back through the catalog")
                    return nil
                }
                continue
            }
            if !name.isEmpty, name != lastName {
                // The first read is the slot's own insert name — where the
                // browse STARTS, not an entry it has passed.
                if lastName != nil {
                    entriesSeen += 1
                    entriesTravelled += 1
                }
                lastName = name
                rememberTail(name)
            }
            // The destination is ordinal 0, so the distance to it is exactly
            // the removed plug-in's own ordinal — the one number
            // `plugin-catalog-cache.json` holds, written by every
            // `logic_add_plugin` browse. Consult it once, and only once a
            // catalog entry with its format annotation is on screen: the mono
            // and stereo catalogs are not the same list.
            if hintTaken == nil, entriesSeen >= 1, !name.isEmpty {
                if let known = catalog,
                   let hint = known.position(
                       matching: pluginName, format: browseEntryFormat(name)
                   ) {
                    hintTaken = hint
                    if let toJump = removalJumpEntries(
                        cachedOrdinal: hint, entriesTravelled: entriesTravelled
                    ) {
                        guard try jump(entries: toJump) else {
                            browseSendFailed("a jump back toward the No Plug-in entry")
                            return nil
                        }
                        jumpedEntries = toJump
                        entriesTravelled += toJump
                        // The landing is an entry the walk did not pass, so it
                        // is not counted as one it looked at — but it is worth
                        // reading back if this browse ends up refusing.
                        lastName = browseName()
                        if let landing = lastName, !landing.isEmpty { rememberTail(landing) }
                        continue
                    }
                } else {
                    hintTaken = 0
                }
            }
            // A jump that has not reached the boundary within the margin it
            // aimed for, plus a grace, was a wrong hint — and a map that has
            // been caught out is deleted rather than trusted again. The walk
            // carries on regardless and still finds the boundary, exactly as it
            // would have from cold.
            if jumpedEntries > 0 {
                stepsSinceJump += 1
                if catalog != nil,
                   stepsSinceJump > browseRemovalUndershootEntries + browseJumpGraceSteps {
                    discardPluginCatalog()
                    catalog = nil
                }
            }
            guard try stepBackward(from: name) else {
                browseSendFailed("a step back through the catalog")
                return nil
            }
        }
        guard reached else {
            // A jump is the one thing that could have carried this browse PAST
            // the boundary and into the far end of the catalog, so a walk that
            // jumped and then failed convicts the map on its way out.
            if jumpedEntries > 0 { discardPluginCatalog() }
            exitToPan()
            throw LogicianError.openVerificationFailed(
                removalBoundaryRefusal(
                    entriesSeen: entriesSeen, tail: tail, jumped: jumpedEntries > 0
                )
            )
        }
        // The display could still advance one more entry after the boundary
        // read, so prove it has stopped before confirming anything — but prove
        // it, rather than sleeping through it. The blind `Thread.sleep(0.3)`
        // this replaces was insuring against a real effect on the UNPACED loop;
        // pacing removed the cause, and the 150 ms silence proof is kept
        // because it is a proof and it is nearly free. The correction loop
        // below is verification, not waiting, so it stays — but its blind
        // 0.4 s per correction (2243 ms spent recovering nothing, live,
        // 2026-09-02) becomes a positive check that the boundary is back.
        waitForSurfaceQuiet(seconds: 0.6)
        var settledName = browseName()
        var corrections = 0
        while let drifted = settledName, !atBoundary(drifted), corrections < 4 {
            _ = try? MCUBridge.send(.vpot(index: slotIndex, delta: browseTicksPerEntry))
            let recovered = waitFor(seconds: 0.5) { status in
                (status["lcd_bottom"] as? String).map { atBoundary(browseCell(in: $0)) } ?? false
            }
            if recovered == nil { waitForSurfaceQuiet(seconds: 0.5) }
            settledName = browseName()
            corrections += 1
        }
        guard let settled = settledName, atBoundary(settled) else {
            // Read the cell BEFORE the restore, and carry it as a value: the
            // message used to interpolate `browseName()` after `exitToPan()`
            // and reported a pan row. See `removalDriftActual`.
            let drifted = settledName
            exitToPan()
            throw LogicianError.verificationFailed(
                requested: "the No Plug-in entry shown at confirmation time",
                actual: removalDriftActual(driftedTo: drifted),
                restored: true
            )
        }
        let eventsBeforePress = freshStatus()?["received_events"] as? Int ?? -1
        let response = try MCUBridge.send(.vpotPress(index: slotIndex))
        guard response.ok else { browseSendFailed("the confirming press"); return nil }
        // Logic's own answer to the press, positively: committing the slot
        // repaints the row. The blind `Thread.sleep(1.0)` this replaces was
        // 11.8% of the whole call (1006 ms mean, measured 2026-09-02) and it
        // was waiting for something that had already happened. What that
        // second was really insuring against — a plug-in that has not finished
        // tearing down when its slot is read — is not dropped, it moves to the
        // readback below, where it is spent only when it is actually needed.
        _ = awaitEvents(since: eventsBeforePress, timeoutMs: 1000)
        waitForSurfaceQuiet(seconds: 0.6)
        guard var after = try pluginInsertNames() else { return nil }
        func slotCell(_ cells: [String]) -> String {
            cells.indices.contains(slotIndex)
                ? cells[slotIndex].trimmingCharacters(
                    in: CharacterSet(charactersIn: MCULCDStrings.bypassMarker)
                )
                : ""
        }
        if !lcdRowShowsRemoval(before: inserts, after: after, slotIndex: slotIndex) {
            // Waiting for the CELL to clear rather than for a duration to
            // elapse: a plug-in that is slow to tear down gets as long as it
            // needs, a fast one costs nothing at all.
            _ = waitFor(seconds: 2.0) { status in
                guard let bottom = status["lcd_bottom"] as? String else { return false }
                let cell = slotCell(lcdFields(bottom))
                return cell.isEmpty || cell == MCULCDStrings.emptySlot
            }
            if let refreshed = (try? pluginInsertNames()) ?? nil { after = refreshed }
        }
        // The surface stays on the insert list, which `pluginInsertNames` just
        // proved by content, and the next plug-in call only has to enter it
        // again — so record the debt instead of walking home. Worth 2253 ms of
        // THIS call's latency (26.3% of it, measured 2026-09-02); worth less
        // than that across a chain, honestly, because the next MCU write tool
        // opens with `findChannel`, which was measured at 2148-2250 ms from a
        // standing plug-in list against 436 ms from Pan. That double charge is
        // `ensurePanNames`' to answer (N2 in profiles/logic_remove_plugin.md),
        // not this call's, and it is verification rather than waiting.
        deferSurfaceRestore(SurfaceDebt(strip: trackName, view: "plugin_list", slot: nil))
        let rowShowsRemoval = lcdRowShowsRemoval(before: inserts, after: after, slotIndex: slotIndex)
        // AX cross-check: with a single instance the plugin must be gone from
        // the strip's inserts; with duplicates, one fewer must be listed.
        var axGone = false
        var axReachable = false
        for _ in 0..<10 {
            if let names = try? logic.insertPluginNames(trackName: trackName) {
                axReachable = true
                if axConfirmsRemoval(
                    beforeCount: axCountBefore, afterNames: names, pluginName: pluginName
                ) {
                    axGone = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        guard rowShowsRemoval, axGone || !axReachable else {
            // The success path leaves the surface where it is on purpose; a
            // failure hands it back, because nobody is going to reuse the view
            // a refusal came out of.
            exitToPan()
            throw LogicianError.verificationFailed(
                requested: "'\(pluginName)' removed from '\(trackName)'",
                actual: rowShowsRemoval
                    ? "the LCD row shows the removal but AX still lists "
                        + "\(axCountBefore.map { "all \($0) instance(s) of" } ?? "") the plugin"
                    : "the LCD row still shows '\(after[slotIndex])' in slot \(slotIndex + 1)",
                restored: false
            )
        }
        var result: [String: Any] = [
            "success": true,
            "verified": true,
            "state": "removed",
            "plugin": pluginName,
            "mcu_slot": slotIndex + 1,
            "slot_resolved_by": insertSlot == nil ? "unique_name_match" : "insert_slot",
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
