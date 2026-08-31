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
    /// send slot (1 entry per tick in THIS browser, unlike the plugin
    /// browser's 1-per-2), settle-verifying the shown name, and confirming.
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
        func shownDestination() -> String { shownSendDestination(destIndex: destIndex) }
        var entries: [String] = []
        var found = false
        for _ in 0..<80 {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            let response = try MCUBridge.send(.vpot(index: destIndex, delta: 1))
            guard response.ok else { return nil }
            _ = awaitEvents(since: before, timeoutMs: 300)
            _ = quiescentStatus()
            let name = shownDestination()
            guard !name.isEmpty, name != MCULCDStrings.emptySlot else { continue }
            if name.caseInsensitiveCompare(destination) == .orderedSame { found = true; break }
            if name == entries.last { continue }
            if let firstEntry = entries.first, name == firstEntry, entries.count > 2 {
                exitToPan()
                throw LogicianError.trackNotExposed(
                    requested: "destination '\(destination)'",
                    exposed: "the browser wrapped; entries: " + entries.joined(separator: ", ")
                )
            }
            entries.append(name)
        }
        guard found else {
            throw LogicianError.openVerificationFailed(
                "the destination browser never showed '\(destination)'"
            )
        }
        Thread.sleep(forTimeInterval: 0.3)
        _ = quiescentStatus()
        guard shownDestination().caseInsensitiveCompare(destination) == .orderedSame else {
            throw LogicianError.verificationFailed(
                requested: "'\(destination)' shown at confirmation time",
                actual: "the entry drifted to '\(shownDestination())'; aborted",
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
        guard let sends = try readSends(restoringView: false),
              sends.contains(where: {
                  ($0["send"] as? Int) == slot
                      && (($0["destination"] as? String) ?? "").caseInsensitiveCompare(destination) == .orderedSame
              }) else {
            throw LogicianError.verificationFailed(
                requested: "send \(slot) -> \(destination)",
                actual: "the send list does not show it after confirmation",
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

    /// The destination text painted for one send's field group on the bottom
    /// row — what the add and remove browses both settle-verify before they
    /// trust a single vpot press.
    static func shownSendDestination(destIndex: Int) -> String {
        guard let status = freshStatus(),
              let bottom = status["lcd_bottom"] as? String else { return "" }
        let start = bottom.index(bottom.startIndex, offsetBy: min(destIndex * 7, bottom.count))
        let raw = String(bottom[start...])
        return (raw.range(of: "    ").map { String(raw[..<$0.lowerBound]) } ?? raw)
            .trimmingCharacters(in: .whitespaces)
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

    // MARK: Removing a send (the destination browser, walked the other way)

    /// What one removal request means against the send list that was just
    /// read. Pure: arguments and a read, no surface — so every branch of the
    /// addressing contract can be pinned by a test.
    enum SendRemoval: Equatable {
        /// This slot, holding this destination (as the send list spells it),
        /// is the one to remove.
        case remove(slot: Int, destination: String)
        /// The addressed send does not exist — a verified no-op, and `detail`
        /// says what the list showed instead.
        case alreadyRemoved(detail: String)
    }

    /// True when a listed destination is the one the caller named. Exact
    /// case-insensitive first (what `addSend` verifies against), then the LCD
    /// abbreviation matcher — but ONLY for a name the cell had to shorten.
    /// A name that fits the cell whole ('Bus 1', 'Bus 12') is shown whole,
    /// and letting the subsequence matcher at those makes 'Bus 1' answer for
    /// 'Bus 12': a wrong send removed on a trailing digit.
    static func sendDestinationMatches(requested: String, listed: String) -> Bool {
        if listed.caseInsensitiveCompare(requested) == .orderedSame { return true }
        let compactRequested = requested.replacingOccurrences(of: " ", with: "")
        let compactListed = listed.replacingOccurrences(of: " ", with: "")
        // Logic's first abbreviation is dropping the space ('Bus 100' paints
        // as 'Bus100'), which is still the whole name.
        if compactListed.caseInsensitiveCompare(compactRequested) == .orderedSame { return true }
        // Content width is the 7-character cell minus its separator column.
        guard compactRequested.count >= MCULCDRow.cellWidth else { return false }
        return lcdNameMatches(track: requested, lcd: listed)
    }

    /// The `readSends` result in the shape the pure resolution and verdict
    /// functions take.
    static func sendListEntries(_ sends: [[String: Any]]) -> [(slot: Int, destination: String)] {
        sends.compactMap { entry in
            guard let slot = entry["send"] as? Int,
                  let destination = entry["destination"] as? String else { return nil }
            return (slot, destination)
        }
    }

    /// Resolves (send?, destination?) against the send list. The contract:
    /// a slot holding something OTHER than the destination the caller named
    /// is a refusal, never a removal — the caller's model of the strip is
    /// wrong, and the send that would have gone is one nothing asked for.
    static func resolveSendRemoval(
        sendNumber: Int?, destination: String?,
        sends: [(slot: Int, destination: String)]
    ) throws -> SendRemoval {
        if let slot = sendNumber, !(1...8).contains(slot) {
            throw LogicianError.invalidArguments("send must be 1-8")
        }
        let listing = sends.isEmpty
            ? "the track has no sends"
            : "sends: " + sends.map { "\($0.slot): \($0.destination)" }.joined(separator: ", ")
        switch (sendNumber, destination) {
        case (nil, nil):
            throw LogicianError.invalidArguments(
                "name the send to remove: send (slot 1-8 as logic_mcu_sends lists them),"
                    + " destination (e.g. 'Bus 1'), or both"
            )
        case (let slot?, nil):
            guard let occupant = sends.first(where: { $0.slot == slot }) else {
                return .alreadyRemoved(detail: "send slot \(slot) is empty (\(listing))")
            }
            return .remove(slot: slot, destination: occupant.destination)
        case (nil, let requested?):
            let hits = sends.filter {
                sendDestinationMatches(requested: requested, listed: $0.destination)
            }
            guard hits.count <= 1 else {
                throw LogicianError.trackNotExposed(
                    requested: "exactly one send to '\(requested)'",
                    exposed: "sends \(hits.map { String($0.slot) }.joined(separator: " and "))"
                        + " each go there — pass send: to pick one"
                )
            }
            guard let hit = hits.first else {
                return .alreadyRemoved(detail: "no send goes to '\(requested)' (\(listing))")
            }
            return .remove(slot: hit.slot, destination: hit.destination)
        case (let slot?, let requested?):
            guard let occupant = sends.first(where: { $0.slot == slot }) else {
                // The named destination sitting in ANOTHER slot is not "already
                // removed" — it is a numbering the caller holds stale (sends
                // renumber when one is removed), and acting on either half of
                // a wrong address would be a guess.
                if let elsewhere = sends.first(where: {
                    sendDestinationMatches(requested: requested, listed: $0.destination)
                }) {
                    throw LogicianError.currentValueMismatch(
                        expected: "'\(requested)' in send slot \(slot)",
                        actual: "slot \(slot) is empty and '\(elsewhere.destination)' is send"
                            + " \(elsewhere.slot) — re-read with logic_mcu_sends"
                    )
                }
                return .alreadyRemoved(
                    detail: "send slot \(slot) is empty and no send goes to '\(requested)' (\(listing))"
                )
            }
            guard sendDestinationMatches(requested: requested, listed: occupant.destination) else {
                throw LogicianError.currentValueMismatch(
                    expected: "'\(requested)' in send slot \(slot)",
                    actual: "slot \(slot) goes to '\(occupant.destination)' (\(listing))"
                )
            }
            return .remove(slot: slot, destination: occupant.destination)
        }
    }

    /// The readback verdict on a removal. Pure, because Logic has two
    /// plausible after-states and the verdict must accept exactly those and
    /// nothing else: the slot left EMPTY where it was, or the remaining sends
    /// COMPACTED up over it — which renumbers them, so the verdict also says
    /// whether the caller's held slot numbers just went stale.
    ///
    /// What counts as verified is a set equation, not a slot peek: exactly one
    /// send fewer, and the destinations that remain are the destinations that
    /// were there minus one occurrence of the removed one. A slot peek would
    /// pass a removal that also dragged a neighbour along; the equation
    /// cannot.
    static func sendRemovalVerdict(
        before: [(slot: Int, destination: String)],
        after: [(slot: Int, destination: String)],
        removedSlot: Int, removedDestination: String
    ) -> (verified: Bool, renumbered: Bool, detail: String) {
        let shown = after.isEmpty
            ? "the track now has no sends"
            : "the send list now shows: "
                + after.map { "\($0.slot): \($0.destination)" }.joined(separator: ", ")
        guard after.count == before.count - 1 else {
            return (false, false,
                    "the send list holds \(after.count) sends where \(before.count - 1)"
                        + " were expected — \(shown)")
        }
        var remaining = before.map { $0.destination.lowercased() }
        guard let index = remaining.firstIndex(of: removedDestination.lowercased()) else {
            return (false, false,
                    "'\(removedDestination)' was not in the before list — nothing to judge against")
        }
        remaining.remove(at: index)
        guard after.map({ $0.destination.lowercased() }).sorted() == remaining.sorted() else {
            return (false, false,
                    "the send list changed by more than the one removal — \(shown)")
        }
        // Compaction is visible as the removed slot being re-occupied: only a
        // send from below can move up into it, and with the count and the set
        // equation already holding, that is the only way this can be true.
        let renumbered = after.contains { $0.slot == removedSlot }
        return (true, renumbered,
                renumbered
                    ? "The remaining sends renumbered (Logic compacts them upward), so slot"
                        + " numbers from before this call are stale — \(shown)."
                    : shown.prefix(1).uppercased() + String(shown.dropFirst()) + ".")
    }

    /// Removes a send by browsing its DESTINATION field back to the No-Send
    /// boundary entry ("--") and confirming — `removePluginViaBrowser`'s
    /// shape, in the browser `addSend` walks forward (1 entry per tick here,
    /// unlike the plugin browser's 1-per-2). Returns nil when the MCU route
    /// is unavailable.
    static func removeSend(
        trackName: String, sendNumber: Int?, destination: String?
    ) throws -> [String: Any]? {
        guard freshStatus() != nil else { return nil }
        guard let channel = try findChannel(trackName: trackName) else { return nil }
        guard try selectFoundChannel(channel) else { return nil }
        // ONE walk home for the whole call, however it exits: the read below,
        // the page walk, the browse and the readback all inherit the send
        // view (`restoringView: false`), and this defer is the only exit —
        // the pattern the add-and-level path already runs on.
        defer { exitToPan() }
        guard let beforeList = try readSends(restoringView: false) else { return nil }
        let before = sendListEntries(beforeList)
        switch try resolveSendRemoval(
            sendNumber: sendNumber, destination: destination, sends: before
        ) {
        case .alreadyRemoved(let detail):
            return [
                "success": true, "verified": true, "state": "already_removed",
                "sends": beforeList,
                "note": "Nothing was pressed: \(detail). A verified no-op, not a failure."
            ]
        case .remove(let slot, let listedDestination):
            let destIndex = ((slot - 1) % 2) * 4
            try sendViewToPage(forSend: slot)
            func shownName() -> String { shownSendDestination(destIndex: destIndex) }
            // The list read and this page view are moments apart, so the slot
            // must still show what the resolution matched before one tick is
            // sent: a surface that moved in between costs a refusal, never a
            // browse on a stranger's send.
            _ = quiescentStatus()
            guard shownName() == listedDestination else {
                throw LogicianError.verificationFailed(
                    requested: "'\(listedDestination)' shown in send slot \(slot) before browsing",
                    actual: "the field reads '\(shownName())'; nothing was changed",
                    restored: true
                )
            }
            // Browse backward toward the No-Send boundary. Bus 72 — the
            // deepest destination the add browse can reach — sits ~80 entries
            // in, so 120 steps is past every start this can be given, and the
            // browser wraps (measured on the add side), so even an overshoot
            // comes around again.
            var reached = false
            for _ in 0..<120 {
                let beforeEvents = freshStatus()?["received_events"] as? Int ?? -1
                let response = try MCUBridge.send(.vpot(index: destIndex, delta: -1))
                guard response.ok else { return nil }
                _ = awaitEvents(since: beforeEvents, timeoutMs: 300)
                _ = quiescentStatus()
                if shownName() == MCULCDStrings.emptySlot { reached = true; break }
            }
            guard reached else {
                throw LogicianError.openVerificationFailed(
                    "the destination browser never reached the No-Send entry within 120 steps;"
                        + " nothing was confirmed (browse abandoned, send unchanged)"
                )
            }
            // Settle and re-verify the boundary is STILL shown before
            // confirming — the same drift check the add makes on its
            // destination, and here it is what stands between this call and
            // REWRITING the send to whatever entry a repaint left showing.
            // Corrections walk forward: past the boundary is the wrapped far
            // end of the list, and forward from there comes back to it.
            Thread.sleep(forTimeInterval: 0.3)
            _ = quiescentStatus()
            var corrections = 0
            while shownName() != MCULCDStrings.emptySlot, corrections < 4 {
                _ = try? MCUBridge.send(.vpot(index: destIndex, delta: 1))
                Thread.sleep(forTimeInterval: 0.4)
                _ = quiescentStatus()
                corrections += 1
            }
            guard shownName() == MCULCDStrings.emptySlot else {
                throw LogicianError.verificationFailed(
                    requested: "the No-Send entry shown at confirmation time",
                    actual: "the entry drifted to '\(shownName())'; aborted without removing",
                    restored: true
                )
            }
            let confirm = try MCUBridge.send(.vpotPress(index: destIndex))
            guard confirm.ok else { return nil }
            // What the slot repaints to after a REMOVAL has not been captured
            // live the way the add's commit frame was, so there is no content
            // to wait for yet: wait the flat second the plugin removal waits
            // and let the send-list readback be the verdict.
            Thread.sleep(forTimeInterval: 1.0)
            _ = quiescentStatus()
            guard let afterList = try readSends(restoringView: false) else { return nil }
            let verdict = sendRemovalVerdict(
                before: before, after: sendListEntries(afterList),
                removedSlot: slot, removedDestination: listedDestination
            )
            guard verdict.verified else {
                throw LogicianError.verificationFailed(
                    requested: "send \(slot) -> \(listedDestination) removed",
                    actual: verdict.detail,
                    restored: false
                )
            }
            var result: [String: Any] = [
                "success": true, "verified": true, "state": "removed",
                "send": slot, "destination": listedDestination,
                "write_route": "mcu_send_destination_browser",
                "readback_route": "mcu_send_list",
                "sends_after": afterList,
                "note": "Removed by browsing the send's destination field back to the No-Send"
                    + " entry and confirming — no mouse, no blind Undo. " + verdict.detail
            ]
            if verdict.renumbered { result["renumbered"] = true }
            return result
        }
    }

}
