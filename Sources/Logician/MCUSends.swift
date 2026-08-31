import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {
    // MARK: Sends (assign_send channel view, assignment code "SE")

    /// The selected track's sends laid out as 4 fields per send, 2 sends per
    /// page: SenNIn (destination), Send N (level), SenNPo (position),
    /// SenNMu (status). NOTE: the multi-channel send view (code "S1") puts
    /// DESTINATION on the vpots — never turn vpots there.
    static func ensureSendView() throws -> Bool {
        for _ in 0..<4 {
            guard let status = freshStatus(),
                  let assignment = status["assignment"] as? String else { return false }
            if assignment == MCULCDStrings.Assignment.send { return true }
            let before = status["received_events"] as? Int ?? -1
            try press("assign_send")
            _ = awaitEvents(since: before, timeoutMs: 400)
            _ = quiescentStatus()
        }
        return (freshStatus()?["assignment"] as? String) == MCULCDStrings.Assignment.send
    }

    /// True when this top row is the send view's FIRST page (sends 1 and 2).
    /// Pure so the classification can be exercised against captured rows.
    ///
    /// Cell 0 carries send 1's destination label - `Sen1In`, or `Sen1De`
    /// mid-repaint. It is deliberately a PREFIX test on the measured label
    /// stem plus the slot number, because the browse banner Logic paints over
    /// a page it is editing spells the word out (`Send 1`, `Send 3`), which
    /// must NOT read as "already there": `Send` and `Sen1` diverge at the
    /// fourth character, so a banner frame falls through to the walk. The
    /// error is one-sided by construction - "not first page" when it is costs
    /// four harmless presses, and only `Sen1…`, which no other page paints,
    /// can say "first page".
    static func sendViewTopIsFirstPage(_ top: String) -> Bool {
        lcdFields(top)[0].hasPrefix(MCULCDStrings.sendFieldLabelPrefix + "1")
    }

    /// True when the slot's own field labels are painted at its field group -
    /// the positive proof that a destination press was taken and Logic has
    /// left the browse banner. Pure, for the same reason as
    /// `sendViewTopIsFirstPage`.
    static func sendSlotFieldsPainted(top: String, slot: Int, destIndex: Int) -> Bool {
        lcdFields(top)[min(destIndex + 3, 7)]
            .hasPrefix(MCULCDStrings.sendFieldLabelPrefix + "\(slot)")
    }

    /// The positive check, taken twice around one quiescence window: the row
    /// must say first-page AND still say it after the display goes quiet, so a
    /// frame caught mid-repaint cannot skip the walk.
    static func sendViewIsLeftmost() -> Bool {
        func showsFirstPage() -> Bool {
            guard let top = freshStatus()?["lcd_top"] as? String else { return false }
            return sendViewTopIsFirstPage(top)
        }
        guard showsFirstPage() else { return false }
        _ = quiescentStatus()
        return showsFirstPage()
    }

    static func sendViewLeftmost() throws {
        // Four blind cursor-lefts cost ~990 ms and this function is called up
        // to three times in one `logic_add_send`, which is ~3 s of walking to
        // a page the surface is usually already on (measured 2026-08-31: the
        // send view was ALREADY leftmost on every one of the six readback
        // calls in that session). So ask the row first, and only walk when it
        // does not answer with the first page.
        if sendViewIsLeftmost() { return }
        for _ in 0..<4 {
            try pressNote(0x62)
            Thread.sleep(forTimeInterval: 0.15)
        }
        _ = quiescentStatus()
    }

    /// Creates a send by browsing the destination field of the first empty
    /// send slot to the named destination (see `browseToSendDestination`),
    /// settle-verifying the shown name, and confirming.
    /// `restoringView: false` leaves the surface in the SEND VIEW for a
    /// caller that is about to use it again - which `logic_add_send` always
    /// is when it was given a `level_db`, because the level write runs in this
    /// same view on this same strip. Walking home and pressing straight back
    /// in cost two full `ensurePanNames` silence proofs (3.3 s and 1.3-3.4 s,
    /// measured 2026-08-31) for no change in end state. The caller that
    /// suppresses the restore OWNS it: it must exit on every path, including
    /// the one where its own write throws.
    static func addSend(
        logic: LogicAccessibility, trackName: String, destination: String,
        restoringView: Bool = true
    ) throws -> [String: Any]? {
        guard freshStatus() != nil else { return nil }
        guard let channel = try findChannel(trackName: trackName) else { return nil }
        guard try selectFoundChannel(channel) else { return nil }
        guard try ensureSendView() else { return nil }
        // A FAILURE always walks home, whatever the caller asked for: the
        // caller only takes over the restore for the path where it goes on to
        // write, and this function's throws all abandon that.
        var restoreOnExit = true
        defer { if restoreOnExit { exitToPan() } }
        try sendViewLeftmost()
        // find first empty slot across the pages
        var slotNumber: Int?
        for page in 0..<4 {
            guard let status = freshStatus(),
                  let top = status["lcd_top"] as? String,
                  let bottom = status["lcd_bottom"] as? String else { break }
            for half in 0..<2 {
                let base = half * 4
                if lcdFields(top)[base].hasPrefix(MCULCDStrings.sendFieldLabelPrefix),
                   ["", MCULCDStrings.emptySlot].contains(lcdFields(bottom)[base]) {
                    slotNumber = page * 2 + half + 1
                    break
                }
            }
            if slotNumber != nil { break }
            try pressNote(0x63)
            Thread.sleep(forTimeInterval: 0.2)
            _ = quiescentStatus()
        }
        guard let slot = slotNumber else {
            throw LogicianError.trackNotExposed(
                requested: "an empty send slot", exposed: "all 8 send slots are occupied"
            )
        }
        let destIndex = ((slot - 1) % 2) * 4
        guard try browseToSendDestination(destIndex: destIndex, destination: destination) else {
            return nil
        }
        Thread.sleep(forTimeInterval: 0.3)
        _ = quiescentStatus()
        let settled = shownSendDestination(destIndex: destIndex)
        guard settled.caseInsensitiveCompare(destination) == .orderedSame else {
            throw LogicianError.verificationFailed(
                requested: "'\(destination)' shown at confirmation time",
                actual: "the entry drifted to '\(settled)'; aborted",
                restored: true
            )
        }
        let confirm = try MCUBridge.send(.vpotPress(index: destIndex))
        guard confirm.ok else { return nil }
        // The press is answered by Logic REPAINTING the slot's field group:
        // the browse banner ("Send 3 / Destination") is replaced by the slot's
        // own labels, so cell base+3 goes from a filler dash to `Sen3Mu`.
        // Waiting a flat second for that was waiting for something that had
        // already happened - measured across six live adds it was there after
        // 0, 0, 7, 0, 0 and 2 ms. So wait for the CONTENT, with the same one
        // second as the deadline: a Logic that is slower than this session's
        // gets exactly as long as before, and a false pass is caught by the
        // readback below, which is the verification and is untouched.
        _ = waitFor(seconds: 1.0) { status in
            guard let top = status["lcd_top"] as? String else { return false }
            return sendSlotFieldsPainted(top: top, slot: slot, destIndex: destIndex)
        }
        // And the slot's own DESTINATION cell has to be painted before the send
        // list is read. The top row repaints first: while the browse banner is
        // still up, the bottom cell holds the first seven characters of the
        // browsed name rather than Logic's settled abbreviation of it — for
        // `Output 3-4` that is `Output `, which is a truncation of the request
        // and not evidence of anything. Measured live 2026-08-31: it made a
        // send that had been created perfectly report a readback mismatch with
        // `restored: false`. So wait for the CONTENT, and let the readback below
        // keep the last word on whether the send exists.
        _ = waitFor(seconds: 1.5) { status in
            guard let bottom = status["lcd_bottom"] as? String else { return false }
            return sendListDestinationMatches(
                lcdValueFields(bottom)[destIndex], requested: destination
            )
        }
        let sends = try readSends(restoringView: false)
        let listed = sends?.first { ($0["send"] as? Int) == slot }?["destination"] as? String
        guard let listed, sendListDestinationMatches(listed, requested: destination) else {
            throw LogicianError.verificationFailed(
                requested: "send \(slot) -> \(destination)",
                // Name what the list DID show. "Does not show it" was true and
                // unactionable; the cell is what tells a wrong destination from
                // a slot that never took the press from a list that could not
                // be read at all.
                actual: sends == nil
                    ? "the send list could not be read back after confirmation"
                    : (listed.map { "the send list shows slot \(slot) as '\($0)'" }
                        ?? "the send list shows no send in slot \(slot)"),
                restored: false
            )
        }
        restoreOnExit = restoringView
        return [
            "success": true, "verified": true, "state": "added",
            "send": slot, "destination": destination,
            "level": "-oo dB (new sends start silent; set with logic_mcu_set_send)",
            "write_route": "mcu_send_destination_browser"
        ]
    }

    /// The destination name the browse is showing at a send slot's field
    /// group right now.
    static func shownSendDestination(destIndex: Int) -> String {
        guard let status = freshStatus(),
              let bottom = status["lcd_bottom"] as? String else { return "" }
        return sendDestinationCell(bottom, destIndex: destIndex)
    }

    /// Browses an empty send slot's destination field to `destination` and
    /// leaves the browse standing on it, UNCOMMITTED — the confirming press is
    /// the caller's, after its own settle and drift check.
    ///
    /// Returns false when the bridge refuses a message (the caller's "the MCU
    /// route is unavailable"); throws when the browser does not hold the
    /// destination, saying what it did hold.
    ///
    /// # Why this is not a walk any more
    ///
    /// It was `for _ in 0..<80`, one entry per iteration, which put a ceiling
    /// on the catalog at entry 80 — `Bus 72` — and refused everything past it
    /// as though it did not exist. The browser does go on: the same session
    /// browsed to `Bus 83` at entry 91 and kept going, so `Bus 90` was being
    /// refused with "the destination browser never showed 'Bus 90'" after 9.6 s
    /// of walking, which reads as *there is no such bus*.
    ///
    /// The distance is now JUMPED, by the arithmetic in `MCUSendCatalog`. That
    /// is safe here for the same reason it is safe in the plug-in browser: a
    /// browse writes nothing until the vpot press, so a jump that lands in the
    /// wrong place costs steps and nothing else — and the landing is read back,
    /// then either matched or used to plan the next jump, so a wrong jump
    /// corrects itself. What must never happen is a wrong DESTINATION, and that
    /// is held by the exact name match here and by the caller's drift check
    /// before the press.
    static func browseToSendDestination(
        destIndex: Int, destination: String
    ) throws -> Bool {
        /// Entries advanced from the `--` origin an empty slot starts at.
        /// Counted by name CHANGES while stepping — a message swallowed by an
        /// unfinished repaint advances nothing — and by ticks while jumping.
        var position = 0
        var report = SendBrowseReport()
        var previous = ""
        var stalledReads = 0
        var stepsTaken = 0
        var jumps = 0
        var lastActionWasJump = false
        /// Set while the read being looked at is a jump's landing, whose
        /// entries the jump itself already counted.
        var landedByJump = false
        let deadline = Date().addingTimeInterval(sendBrowseSearchBudget)

        func matches(_ shown: String) -> Bool {
            // EXACT, case-insensitively. Never prefix-tolerant, however
            // truncated a cell may be: `Bus 1` is a prefix of `Bus 12`, so the
            // tolerance the plug-in browser can afford would put a send on the
            // wrong bus here.
            shown.caseInsensitiveCompare(destination) == .orderedSame
        }

        /// One entry forward, event-paced.
        func stepForward() throws -> Bool {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            guard try MCUBridge.send(
                .vpot(index: destIndex, delta: sendBrowseTicksPerEntry)
            ).ok else { return false }
            _ = awaitEvents(since: before, timeoutMs: 300)
            _ = quiescentStatus()
            stepsTaken += 1
            return true
        }

        /// Carries the browse `entries` entries from where it is now, in
        /// clamp-sized messages with a silence proof between them. The proof is
        /// not optional: a 63-entry repaint is still arriving when the next
        /// message would go out, and a message sent into it is swallowed — so
        /// the landing would be neither where it was asked for nor reversible
        /// (measured on the plug-in browser, same surface, same failure).
        ///
        /// `recording: false` is for the endgame jump, which runs after `seen`
        /// is finished and therefore puts no holes in it.
        func jump(entries entriesToJump: Int, recording: Bool = true) throws -> Bool {
            for chunk in sendBrowseJumpPlan(entries: entriesToJump) {
                let before = freshStatus()?["received_events"] as? Int ?? -1
                guard try MCUBridge.send(.vpot(index: destIndex, delta: chunk)).ok
                else { return false }
                position += chunk
                _ = awaitEvents(since: before, timeoutMs: 400)
                waitForSurfaceQuiet(seconds: 1.5)
            }
            if recording { report.jumped = true }
            jumps += 1
            return true
        }

        /// The jump worth taking from this reading, if any.
        func plannedJump(from shown: String) -> Int? {
            guard jumps < sendBrowseJumpCap else { return nil }
            if let delta = sendJumpDelta(from: shown, to: destination) {
                return sendClampedJump(delta, from: position)
            }
            // The cold start, and ONLY there: `position` is exactly 1, because
            // one step has been taken from an origin that was known by
            // construction, so the measured ordinal becomes a distance without
            // compounding any estimate. Everything after this is planned by the
            // same-family arithmetic above, which needs no table and no locale.
            guard position == 1, let ordinal = sendDestinationOrdinal(destination) else {
                return nil
            }
            return sendClampedJump(ordinal - position, from: position)
        }

        /// The endgame, run once the search proper has given up: go to the far
        /// end of the list and walk back through its last entries, matching
        /// each and recording them all.
        ///
        /// It earns its place twice over. The catalog ENDS in entries no
        /// arithmetic here can address — `Stereo Output`, `Output 3-4`,
        /// `Output 5-6`, `Output 7-8`, which carry no family number to subtract
        /// — and they sit at entries 265-268, far past anything a walk reaches
        /// inside the search budget. Without this they would be permanently
        /// unreachable while the tool invites their names. And when the
        /// destination genuinely is not there, the tail is what turns "the list
        /// ends at 'Output 7-8'" into "the highest bus in it is 256".
        ///
        /// Returns true standing ON the destination, uncommitted (the caller's
        /// settle and drift check still gate the press), false having read the
        /// tail without finding it, and nil when the bridge refused a message —
        /// which is not the same answer as "not in the list" and must not be
        /// reported as one.
        func lookAtTheEnd() throws -> Bool? {
            guard try jump(
                entries: sendClampedJump(sendBrowseEntryCap, from: position), recording: false
            ) else { return nil }
            var tail = [shownSendDestination(destIndex: destIndex)]
            if matches(tail[0]) { report.tail = tail; return true }
            for _ in 0..<sendBrowseTailEntries {
                let before = freshStatus()?["received_events"] as? Int ?? -1
                guard let response = try? MCUBridge.send(
                    .vpot(index: destIndex, delta: -sendBrowseTicksPerEntry)
                ), response.ok else { break }
                _ = awaitEvents(since: before, timeoutMs: 300)
                _ = quiescentStatus()
                let name = shownSendDestination(destIndex: destIndex)
                guard !name.isEmpty, name != MCULCDStrings.emptySlot,
                      name != tail.first else { continue }
                tail.insert(name, at: 0)
                if matches(name) { report.tail = tail; return true }
            }
            report.tail = tail
            return false
        }

        var stop: SendBrowseStop?
        // The bound is on how far the browse WALKS. It deliberately is not on
        // `position`: a jump aimed at the end of the catalog leaves `position`
        // past the bound, and exiting there would throw away the landing —
        // which is the one read that says where the list really stops.
        while stepsTaken < sendBrowseEntryCap {
            let shown = shownSendDestination(destIndex: destIndex)
            let isEntry = !shown.isEmpty && shown != MCULCDStrings.emptySlot
            if isEntry {
                if matches(shown) { return true }
                if shown == previous {
                    stalledReads += 1
                } else {
                    stalledReads = 0
                    // A wrap is the FIRST entry coming round again after real
                    // progress — and only a contiguous walk can say that: once
                    // a jump has been taken the browse can revisit an entry by
                    // going backwards, which is not a lap.
                    if !report.jumped, let first = report.seen.first,
                       shown == first, report.seen.count > 2 {
                        stop = .wrapped
                        break
                    }
                    if !landedByJump { position += 1 }
                    // Re-anchor the coordinate on a landing this build can
                    // place: a jump that Logic clamped at the end of the list
                    // travelled less than it was sent, and an over-counted
                    // `position` would then trim every later jump too hard.
                    if landedByJump, let anchored = sendDestinationOrdinal(shown) {
                        position = anchored
                    }
                    report.seen.append(shown)
                }
                previous = shown
            }
            landedByJump = false

            // The list has stopped answering. Prove what that means before
            // saying it: one probe jump, a distance a list with anything left
            // in it could not fail to move on. A step that lands in an
            // unfinished repaint reads its predecessor's name and is ordinary,
            // so stepping gets several tries; a JUMP that moved nothing gets
            // one, because a swallowed jump is exactly what the probe retries.
            if stalledReads >= (lastActionWasJump ? 1 : sendBrowseStallSteps) {
                guard try jump(entries: sendBrowseProbeEntries) else { return false }
                guard shownSendDestination(destIndex: destIndex) != shown else {
                    stop = .listEnded
                    break
                }
                stalledReads = 0
                landedByJump = true
                lastActionWasJump = true
                if Date() >= deadline { stop = .timeBudget; break }
                continue
            }

            if isEntry, sendJumpDelta(from: shown, to: destination).map({ $0 > 0 }) == true,
               plannedJump(from: shown) == 0 {
                // The destination is real, further on, and past the far end of
                // any catalog this build will look at.
                stop = .entryCap
                break
            }
            if isEntry, let delta = plannedJump(from: shown),
               delta <= -1 || delta >= sendBrowseMinJumpEntries {
                guard try jump(entries: delta) else { return false }
                landedByJump = true
                lastActionWasJump = true
            } else {
                guard try stepForward() else { return false }
                lastActionWasJump = false
            }
            if Date() >= deadline { stop = .timeBudget; break }
        }

        // A contiguous walk that reached the end of the list has seen every
        // entry there is; anything else has not, so look at the end before
        // refusing.
        if stop != .listEnded || report.jumped {
            guard let foundAtTheEnd = try lookAtTheEnd() else { return false }
            if foundAtTheEnd { return true }
        }
        throw LogicianError.trackNotExposed(
            requested: "send destination '\(destination)'",
            exposed: sendDestinationRefusalText(
                requested: destination,
                report: {
                    var final = report
                    final.stop = stop ?? .entryCap
                    return final
                }()
            )
        )
    }

    /// Pages the send channel view to the page holding the given send slot.
    static func sendViewToPage(forSend send: Int) throws {
        try sendViewLeftmost()
        for _ in 0..<((send - 1) / 2) {
            try pressNote(0x63)
            Thread.sleep(forTimeInterval: 0.2)
            _ = quiescentStatus()
        }
    }

    /// Walks the plugin-edit parameter pages until the named parameter is on
    /// screen; returns its vpot index and LEAVES the view on that page.
    static func locateParameter(named name: String) throws -> Int? {
        let total = try normalizeToPageOne()
        for page in 1...max(total, 1) {
            if let entries = settledParameterPage() {
                for (index, entry) in entries.enumerated() where !entry.name.isEmpty {
                    if entry.name.localizedCaseInsensitiveCompare(name) == .orderedSame
                        || lcdNameMatches(track: name, lcd: entry.name) {
                        return index
                    }
                }
            }
            if page < max(total, 1) { try pageRight() }
        }
        return nil
    }

    /// Reads all sends of the selected track. Returns nil when the MCU route
    /// is unavailable; an empty array when the track simply has no sends.
    /// `restoringView: false` is for a caller that is ALREADY inside a
    /// `defer { exitToPan() }` of its own - `addSend`, which reads the send
    /// list back to verify its own write. Walking the surface home and then
    /// having the caller's defer walk it home again cost 3.3 s of the 4.8 s
    /// this readback took (measured 2026-08-31), for no change in end state:
    /// whoever asked for the restore still gets it, once.
    static func readSends(restoringView: Bool = true) throws -> [[String: Any]]? {
        guard try ensureSendView() else { return nil }
        defer { if restoringView { exitToPan() } }
        try sendViewLeftmost()
        var sends: [[String: Any]] = []
        for page in 0..<4 {
            guard let fields = parameterPage() else { break }
            var pageHadSend = false
            for half in 0..<2 {
                let base = half * 4
                let number = page * 2 + half + 1
                guard fields[base].name.hasPrefix(MCULCDStrings.sendFieldLabelPrefix) else { continue }
                let destination = fields[base].value
                guard !destination.isEmpty, destination != MCULCDStrings.emptySlot else { continue }
                pageHadSend = true
                sends.append([
                    "send": number,
                    "destination": destination,
                    "level": fields[base + 1].value,
                    "position": fields[base + 2].value,
                    "status": fields[base + 3].value
                ])
            }
            if !pageHadSend { break }
            try pressNote(0x63)
            Thread.sleep(forTimeInterval: 0.2)
            _ = quiescentStatus()
        }
        return sends
    }

    /// Sets one send's level in dB by converging its vpot against the LCD
    /// echo, with the same compare-and-set/readback discipline as the plugin
    /// parameters. Touches ONLY the level vpot, never the destination.
    static func setSendLevel(
        sendNumber: Int, targetDb: Double, expectedCurrentValue: String?
    ) throws -> [String: Any]? {
        guard (1...8).contains(sendNumber) else {
            throw LogicianError.invalidArguments("send must be 1-8")
        }
        guard try ensureSendView() else { return nil }
        defer { exitToPan() }
        try sendViewLeftmost()
        let page = (sendNumber - 1) / 2
        for _ in 0..<page {
            try pressNote(0x63)
            Thread.sleep(forTimeInterval: 0.2)
            _ = quiescentStatus()
        }
        guard let fields = parameterPage() else { return nil }
        let base = ((sendNumber - 1) % 2) * 4
        let levelIndex = base + 1
        let destination = fields[base].value
        guard fields[base].name.hasPrefix(MCULCDStrings.sendFieldLabelPrefix),
              !destination.isEmpty, destination != MCULCDStrings.emptySlot else {
            throw LogicianError.trackNotExposed(
                requested: "send \(sendNumber)",
                exposed: "the selected track has no send in slot \(sendNumber)"
            )
        }
        guard fields[levelIndex].name == MCULCDStrings.sendLevelFieldLabel(sendNumber) else {
            return nil // unexpected layout: refuse rather than turn a stranger's vpot
        }
        let originalText = fields[levelIndex].value
        if let expected = expectedCurrentValue {
            let matchesText = originalText.localizedCaseInsensitiveCompare(expected) == .orderedSame
            let matchesNumber = parseNumber(originalText) != nil && parseNumber(expected) != nil
                && abs(parseNumber(originalText)! - parseNumber(expected)!) < 0.0001
            guard matchesText || matchesNumber else {
                throw LogicianError.currentValueMismatch(expected: expected, actual: originalText)
            }
        }
        func currentText() -> String? {
            parameterPage().map { $0[levelIndex].value }
        }
        func turn(_ ticks: Int) throws {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            let response = try MCUBridge.send(.vpot(index: levelIndex, delta: ticks))
            guard response.ok else {
                throw LogicianError.writeFailed("MCU vpot failed: \(response.error ?? "?")")
            }
            _ = awaitEvents(since: before, timeoutMs: 350)
        }
        let finalText: String
        if let fast = fastConverge(index: levelIndex, target: targetDb, maxMs: 4000) {
            finalText = fast.text
        } else {
            finalText = try convergeNumeric(
                target: targetDb,
                tolerance: nil,
                read: { currentText().flatMap(parseNumber) },
                readText: { currentText() },
                turn: turn
            )
        }
        return [
            "success": true,
            "verified": true,
            "state": "confirmed",
            "send": sendNumber,
            "destination": destination,
            "before": originalText,
            "after": finalText,
            "route": "mcu",
            "write_route": "mcu_vpot_converge",
            "readback_route": "mcu_lcd_echo"
        ]
    }

}
