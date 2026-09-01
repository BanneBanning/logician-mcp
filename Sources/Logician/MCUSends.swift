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

    /// True when this send-view PAIR of rows says the selected strip has no
    /// send slots at all. Pure, against captured rows, like its neighbours.
    ///
    /// Measured live 2026-08-31 on `Testlåt Copy`: a strip WITH send
    /// machinery paints something under every slot label it raises — a
    /// destination name, or the No-Send entry `--` for an empty slot
    /// (`Sweeps`, zero sends, painted `--` under both `Sen1In` and `Sen2In`).
    /// `Vocals`, a folder-stack main track whose reduced strip publishes no
    /// sends, painted the SAME top row over a completely blank bottom — and
    /// its destination vpot moved nothing, turned or pressed, in any send
    /// view. So a labelled slot-1 destination cell with NOTHING in it is the
    /// signature of a strip that cannot take a send, not of an empty slot.
    ///
    /// One frame is not proof — a repaint can blank the cell for a moment —
    /// which is why the caller reads this twice around a quiescence window.
    static func sendViewShowsSendlessStrip(top: String, bottom: String) -> Bool {
        sendViewTopIsFirstPage(top) && lcdFields(bottom)[0].isEmpty
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

    /// The send view's rows once two reads around a quiescence window agree —
    /// the read the empty-slot scan classifies from. One frame is not enough
    /// there: the view opens on whatever page the surface remembered, the
    /// leftmost walk repaints all 16 cells, and a frame caught mid-repaint
    /// shows a blank where the slot's real cell has not landed yet. Measured
    /// live 2026-08-31 on 'Drum Synth Kit': the scan read slot 1 as blank
    /// while slot 2 already showed `--`, and put the send in slot 2 of a
    /// strip whose slot 1 was empty.
    static func settledSendViewRows() -> (top: String, bottom: String)? {
        func rows() -> (top: String, bottom: String)? {
            guard let status = freshStatus(),
                  let top = status["lcd_top"] as? String,
                  let bottom = status["lcd_bottom"] as? String else { return nil }
            return (top, bottom)
        }
        for _ in 0..<4 {
            guard let first = rows() else { return nil }
            _ = quiescentStatus()
            guard let second = rows() else { return nil }
            if first == second { return second }
        }
        return rows()
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
        // Find the first empty slot across the pages. Empty means the cell
        // holds the No-Send entry `--`, and ONLY that: a blank cell used to
        // count too, and on a strip with no send slots at all — a
        // folder-stack main track, whose send view labels the slots over a
        // bottom row it leaves entirely blank — that read the dead cell as
        // "slot 1 is free" and spent the whole browse budget turning a vpot
        // Logic had given no parameter (~27 s to a refusal that said the
        // catalog was missing a bus, measured live 2026-08-31 on 'Vocals').
        var slotNumber: Int?
        for page in 0..<4 {
            guard let (top, bottom) = settledSendViewRows() else { break }
            for half in 0..<2 {
                let base = half * 4
                if lcdFields(top)[base].hasPrefix(MCULCDStrings.sendFieldLabelPrefix),
                   lcdFields(bottom)[base] == MCULCDStrings.emptySlot {
                    slotNumber = page * 2 + half + 1
                    break
                }
            }
            if slotNumber != nil { break }
            // The sendless-strip signature, and it can only show on the first
            // page: slot 1 is labelled on every strip that is in the send
            // view at all, and a strip that has sends to give always paints
            // slot 1's cell. Confirmed on a second read across a quiescence
            // window so a mid-repaint blank cannot fail a track that merely
            // repainted slowly.
            if page == 0, sendViewShowsSendlessStrip(top: top, bottom: bottom) {
                _ = quiescentStatus()
                if let settled = freshStatus(),
                   let settledTop = settled["lcd_top"] as? String,
                   let settledBottom = settled["lcd_bottom"] as? String,
                   sendViewShowsSendlessStrip(top: settledTop, bottom: settledBottom) {
                    throw LogicianError.trackNotExposed(
                        requested: "a send slot on '\(trackName)'",
                        exposed: "the send view raises the slot labels but paints no"
                            + " destination cell — not even the No-Send entry ('--') a"
                            + " browsable empty slot always shows. That is a strip with"
                            + " no send machinery: a folder-stack main track is the"
                            + " common case (logic_track_info reports it as kind"
                            + " 'reduced'); put the send on the stack's subtracks, or"
                            + " make it a summing stack, whose main track is a real aux."
                            + " Nothing was browsed"
                    )
                }
            }
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
        /// Every abandon of the browse funnels through here, whatever threw
        /// it: leave the send view — which CANCELS a pending browse, measured
        /// on empty and occupied slots alike — and then PROVE the slot is
        /// still empty before letting the failure out. "Nothing was written"
        /// used to be an assumption; since one abandoned browse left a send
        /// behind (2026-08-31), it is a readback.
        func abandonedBrowse(_ error: Error) throws -> Never {
            exitToPan()
            guard let after = (try? readSends(restoringView: false)) ?? nil else {
                throw LogicianError.preconditionUnmet(
                    "The destination browse was abandoned (\(error.localizedDescription)) AND the"
                        + " send list could not be read back to prove slot \(slot) is still empty"
                        + " — verify with logic_mcu_sends before trusting this strip."
                )
            }
            let verdict = sendAbandonVerdict(
                slot: slot, expected: nil, after: sendListEntries(after)
            )
            guard verdict.clean else {
                throw LogicianError.verificationFailed(
                    requested: "nothing written by the abandoned destination browse",
                    actual: verdict.detail
                        + ". Original failure: \(error.localizedDescription)",
                    restored: false
                )
            }
            throw error
        }
        let confirm: BridgeResponse
        do {
            guard try browseToSendDestination(destIndex: destIndex, destination: destination) else {
                return nil
            }
            Thread.sleep(forTimeInterval: 0.3)
            _ = quiescentStatus()
            // Settle and view check from ONE frame: the entry that is about
            // to be confirmed and the view that gives the press its meaning
            // must be facts about the same instant.
            let confirmationFrame = freshStatus()
            guard let top = confirmationFrame?["lcd_top"] as? String,
                  let bottom = confirmationFrame?["lcd_bottom"] as? String,
                  sendViewStanding(in: confirmationFrame) else {
                throw sendViewDroppedError(confirmationFrame, before: "the confirming press")
            }
            let settled = sendDestinationCell(top: top, bottom: bottom, destIndex: destIndex)
            guard settled.caseInsensitiveCompare(destination) == .orderedSame else {
                throw LogicianError.verificationFailed(
                    requested: "'\(destination)' shown at confirmation time",
                    actual: "the entry drifted to '\(settled)'; aborted",
                    restored: true
                )
            }
            confirm = try MCUBridge.send(.vpotPress(index: destIndex))
        } catch {
            try abandonedBrowse(error)
        }
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
            return sendDestinationMatches(
                requested: destination, listed: lcdValueFields(bottom)[destIndex]
            )
        }
        let sends = try readSends(restoringView: false)
        let listed = sends?.first { ($0["send"] as? Int) == slot }?["destination"] as? String
        guard let listed,
              sendDestinationMatches(requested: destination, listed: listed) else {
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

    /// The destination text painted for one send's field group on the bottom
    /// row — what the add and remove browses both settle-verify before they
    /// trust a single vpot press.
    static func shownSendDestination(destIndex: Int) -> String {
        guard let status = freshStatus(),
              let top = status["lcd_top"] as? String,
              let bottom = status["lcd_bottom"] as? String else { return "" }
        return sendDestinationCell(top: top, bottom: bottom, destIndex: destIndex)
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
    /// The distance is now JUMPED, by the arithmetic in `MCUSendCatalog`. A
    /// jump that lands in the wrong place costs steps and nothing else — and
    /// the landing is read back, then either matched or used to plan the next
    /// jump, so a wrong jump corrects itself. What must never happen is a
    /// wrong DESTINATION, and that is held by the exact name match here and by
    /// the caller's drift check before the press.
    ///
    /// # What "uncommitted until the press" actually covers
    ///
    /// This file used to reason "a browse writes nothing until the vpot press"
    /// as though it held unconditionally. It holds ONLY while the send view is
    /// standing, and the view does not stay standing on its own: Logic tears
    /// an idle send view down through the multi-channel send views to Pan
    /// (measured 2026-08-31 — `MCUSendCatalog`'s type comment has the whole
    /// sequence), and a tick or press that arrives mid-teardown addresses
    /// whatever control its index means in the view it lands in. One live
    /// browse ended with a pan driven to −64 that way, and a no-press "commit"
    /// traced back to the multi-channel view's direct-write vpots. So every
    /// message below is gated on the assignment display still reading `SE`,
    /// reads that show no entry are counted and capped instead of answered
    /// with more blind ticks, and the caller proves an abandoned browse left
    /// the slot untouched before it reports.
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

        /// One entry forward, event-paced. Gated like every other message: a
        /// step sent after the view has dropped is a pan write, so the view is
        /// re-checked on the same status read that anchors the event wait.
        func stepForward() throws -> Bool {
            let status = freshStatus()
            guard sendViewStanding(in: status) else {
                throw sendViewDroppedError(status, before: "a 1-entry step")
            }
            let before = status?["received_events"] as? Int ?? -1
            guard try MCUBridge.send(
                .vpot(index: destIndex, delta: sendBrowseTicksPerEntry)
            ).ok else { return false }
            _ = awaitEvents(since: before, timeoutMs: 300)
            _ = quiescentStatus()
            stepsTaken += 1
            return true
        }

        /// `sendBrowseJump` with this browse's bookkeeping around it.
        /// `recording: false` is for the endgame jump, which runs after `seen`
        /// is finished and therefore puts no holes in it.
        func jump(entries entriesToJump: Int, recording: Bool = true) throws -> Bool {
            guard try sendBrowseJump(destIndex: destIndex, entries: entriesToJump) else {
                return false
            }
            position += entriesToJump
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
                let status = freshStatus()
                guard sendViewStanding(in: status) else {
                    throw sendViewDroppedError(status, before: "a tail read-back step")
                }
                let before = status?["received_events"] as? Int ?? -1
                guard let response = try? MCUBridge.send(
                    .vpot(index: destIndex, delta: -sendBrowseTicksPerEntry)
                ), response.ok else { break }
                _ = awaitEvents(since: before, timeoutMs: 300)
                _ = quiescentStatus()
                let name = shownSendDestination(destIndex: destIndex)
                guard sendBrowseReadIsEntry(name), name != tail.first else { continue }
                tail.insert(name, at: 0)
                if matches(name) { report.tail = tail; return true }
            }
            report.tail = tail
            return false
        }

        var stop: SendBrowseStop?
        var blankReads = 0
        // The bound is on how far the browse WALKS. It deliberately is not on
        // `position`: a jump aimed at the end of the catalog leaves `position`
        // past the bound, and exiting there would throw away the landing —
        // which is the one read that says where the list really stops.
        while stepsTaken < sendBrowseEntryCap {
            // One status read serves the whole iteration, so the view check
            // and the cell it vouches for cannot come from different frames.
            guard let frame = freshStatus(),
                  let top = frame["lcd_top"] as? String,
                  let bottom = frame["lcd_bottom"] as? String else { return false }
            guard sendViewStanding(in: frame) else {
                throw sendViewDroppedError(frame, before: "the next browse message")
            }
            let shown = sendDestinationCell(top: top, bottom: bottom, destIndex: destIndex)
            let isEntry = sendBrowseReadIsEntry(shown)
            if isEntry, stepsTaken == 0, jumps == 0 {
                // The origin of an empty slot is `--` (or a not-yet-painted
                // blank). A real entry here before anything was sent means the
                // slot is occupied and the empty-slot scan was fooled — one
                // measured way is a stale frame painting occupied slots blank
                // — and browsing on would stand a REWRITE of an existing send
                // behind the confirming press.
                throw LogicianError.currentValueMismatch(
                    expected: "an empty destination field before the first tick",
                    actual: "the field already shows '\(shown)'; nothing was sent"
                )
            }
            if !isEntry {
                blankReads += 1
                if blankReads >= sendBrowseBlankReadCap {
                    throw LogicianError.preconditionUnmet(
                        "The destination browser stopped answering:"
                            + " \(blankReads) consecutive reads showed no catalog entry"
                            + " (last read '\(shown)') — the signature of a send view that"
                            + " never painted or is being torn down (measured 2026-08-31)."
                            + " The browse was abandoned with nothing confirmed."
                    )
                }
            }
            if isEntry {
                blankReads = 0
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
            } else if shown.isEmpty, previous.isEmpty {
                // A cell that paints NOTHING, read after read, is as stalled
                // as one that repeats a name — it is what a vpot Logic gave no
                // parameter looks like, and without this the walk would spend
                // the whole search budget stepping a control that moves
                // nothing. `previous` starts empty, so a dead cell stalls from
                // its first read; a single blank frame mid-repaint does not,
                // because the entry before it set `previous`.
                stalledReads += 1
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
        // refusing. Unless the browse never painted a single entry — then
        // there is no list to have an end, the vpot is not editing anything,
        // and the endgame would only spend seconds jumping a dead control.
        if stop != .listEnded || report.jumped, !report.seen.isEmpty {
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
        func readOnce() throws -> [[String: Any]] {
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
        let first = try readOnce()
        if !first.isEmpty { return first }
        // "No sends" is believed only on a second look. A freshly entered
        // send view can hold a stale frame that paints an occupied track's
        // slots blank (measured twice, 2026-08-31 — one such frame turned a
        // strip with a send into `[]` for a beat), and this list is what the
        // removal's addressing and the abandon verification decide from: a
        // stale `[]` there turns a real removal into a false "already
        // removed", or hides a write an abandoned browse left behind. A track
        // that truly has no sends pays one settle and one re-read.
        Thread.sleep(forTimeInterval: 0.4)
        _ = quiescentStatus()
        return try readOnce()
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
    /// case-insensitive first, then the LCD abbreviation matcher — but ONLY
    /// for a name the cell had to shorten. A name that fits the cell whole
    /// ('Bus 1', 'Bus 12') is shown whole, and letting the subsequence matcher
    /// at those makes 'Bus 1' answer for 'Bus 12': a wrong send removed on a
    /// trailing digit.
    ///
    /// Used by BOTH ends of the send tools — the removal's addressing and the
    /// add's readback — and each end needed the other's guard. The add needs
    /// the abbreviation: a send created to 'Output 3-4' reads back as 'Out3-4',
    /// and the exact compare it used to make called that perfectly good write a
    /// `verification_failed` with `restored: false` (measured live
    /// 2026-08-31, with the send sitting in the project the whole time).
    /// The removal needs the trailing NUMBER to agree, and so, it turns out,
    /// does the add: without it, `Output` — the first seven characters of
    /// 'Output 3-4', which is what the cell holds while the browse banner is
    /// still up — passes as proof of a settled send, and the readback then
    /// verifies a repaint frame instead of a write.
    static func sendDestinationMatches(requested: String, listed: String) -> Bool {
        if listed.caseInsensitiveCompare(requested) == .orderedSame { return true }
        let compactRequested = requested.replacingOccurrences(of: " ", with: "")
        let compactListed = listed.replacingOccurrences(of: " ", with: "")
        // Logic's first abbreviation is dropping the space ('Bus 100' paints
        // as 'Bus100'), which is still the whole name.
        if compactListed.caseInsensitiveCompare(compactRequested) == .orderedSame { return true }
        // Content width is the 7-character cell MINUS its separator column, and
        // the difference is not academic: `Bus 200` compacts to six characters
        // and Logic paints it `B 200`, so gating on the full cell width refused
        // the abbreviation test for exactly the destinations that get
        // abbreviated. Measured live 2026-08-31, that is what made
        // `logic_remove_send` answer "no send goes to 'Bus 200'" about the send
        // it was listing as `B 200` in the same sentence — reachable only since
        // the add browse stopped stopping at `Bus 72`, because `Bus 72` and
        // everything shorter is painted whole.
        guard compactRequested.count >= MCULCDRow.cellWidth - 1 else { return false }
        guard lcdNameMatches(track: requested, lcd: listed) else { return false }
        // Logic abbreviates by dropping characters from the MIDDLE and keeps
        // the tail ('Lofi Pad' -> 'LofPad', 'Output 3-4' -> 'Out3-4'), so
        // requiring the tail costs nothing and closes what the subsequence
        // test leaves open on numbers: 'Bus 10' is an ordered subsequence of
        // 'Bus 100', and 'Output' is one of 'Output 3-4'.
        return sendDestinationTrailingNumber(listed)
            == sendDestinationTrailingNumber(requested)
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

    /// The readback verdict on an ABANDONED destination browse — the proof
    /// behind "nothing was written", which used to be asserted and is now
    /// checked, because one abandoned browse left a send behind (2026-08-31,
    /// `B 200` at −12.2 dB on a strip nothing had confirmed anything on).
    /// Pure, so both promises can be pinned by tests: `expected: nil` is an
    /// add browse — the slot it ran on must still be empty; `expected:` some
    /// destination is a removal browse — the slot must still hold exactly what
    /// the removal matched, as the send list spells it.
    static func sendAbandonVerdict(
        slot: Int, expected: String?, after: [(slot: Int, destination: String)]
    ) -> (clean: Bool, detail: String) {
        let occupant = after.first { $0.slot == slot }?.destination
        switch (expected, occupant) {
        case (nil, nil):
            return (true, "send slot \(slot) is still empty")
        case (nil, let materialized?):
            return (false,
                    "send slot \(slot) now holds '\(materialized)' although nothing was confirmed"
                        + " — the abandoned browse left a write behind. Remove it with"
                        + " logic_remove_send and treat this strip's sends as suspect")
        case (let kept?, nil):
            return (false,
                    "send \(slot) -> '\(kept)' is gone although nothing was confirmed — the"
                        + " abandoned browse left a write behind; re-read with logic_mcu_sends")
        case (let kept?, let still?):
            guard still.caseInsensitiveCompare(kept) == .orderedSame else {
                return (false,
                        "send \(slot) now goes to '\(still)' where '\(kept)' stood although"
                            + " nothing was confirmed — the abandoned browse left a write behind")
            }
            return (true, "send \(slot) still goes to '\(kept)'")
        }
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
            /// Every abandon of the backward browse funnels through here:
            /// leave the send view — which CANCELS a pending browse, measured
            /// on an occupied slot exactly like this one (parked on 'Bus 65'
            /// over a 'Bus 2' send, left to Pan, 'Bus 2' intact) — then PROVE
            /// the send still stands as matched before letting the failure
            /// out. "Send unchanged" used to be asserted; now it is read back.
            func abandonedBrowse(_ error: Error) throws -> Never {
                exitToPan()
                guard let after = (try? readSends(restoringView: false)) ?? nil else {
                    throw LogicianError.preconditionUnmet(
                        "The removal browse was abandoned (\(error.localizedDescription)) AND the"
                            + " send list could not be read back to prove send \(slot) ->"
                            + " '\(listedDestination)' is untouched — verify with logic_mcu_sends."
                    )
                }
                let verdict = sendAbandonVerdict(
                    slot: slot, expected: listedDestination, after: sendListEntries(after)
                )
                guard verdict.clean else {
                    throw LogicianError.verificationFailed(
                        requested: "send \(slot) -> \(listedDestination) untouched by the"
                            + " abandoned removal browse",
                        actual: verdict.detail
                            + ". Original failure: \(error.localizedDescription)",
                        restored: false
                    )
                }
                throw error
            }
            // Browse backward toward the No-Send boundary.
            //
            // The 120-step cap this walk had was sound by construction: the add
            // browse could not reach past `Bus 72`, ~80 entries in, so no send
            // could exist deeper than the walk could climb back from. That
            // premise is gone — the add browse now reaches every destination
            // Logic offers, `Bus 256` at entry 264 — so the walk both has to be
            // able to climb further and ought not to have to.
            //
            // The destination's own name says how deep it is, so jump most of
            // the way home first and stop deliberately short: the paced walk is
            // still what finds the boundary, and a jump that lands wrong (or
            // overshoots into a wrap) costs steps, which the raised cap now has
            // room for.
            let confirm: BridgeResponse
            do {
                if let ordinal = sendDestinationOrdinal(listedDestination),
                   ordinal > sendRemovalHomeMargin {
                    guard try sendBrowseJump(
                        destIndex: destIndex, entries: -(ordinal - sendRemovalHomeMargin)
                    ) else { return nil }
                }
                var reached = false
                var blankReads = 0
                for _ in 0..<sendBrowseEntryCap {
                    // The view gate rides the same status read that anchors
                    // the event wait — a step sent after the view has dropped
                    // is a pan write (measured 2026-08-31, this exact walk).
                    let status = freshStatus()
                    guard sendViewStanding(in: status) else {
                        throw sendViewDroppedError(status, before: "a backward step")
                    }
                    let beforeEvents = status?["received_events"] as? Int ?? -1
                    let response = try MCUBridge.send(.vpot(index: destIndex, delta: -1))
                    guard response.ok else { return nil }
                    _ = awaitEvents(since: beforeEvents, timeoutMs: 300)
                    _ = quiescentStatus()
                    let name = shownName()
                    if name == MCULCDStrings.emptySlot { reached = true; break }
                    if sendBrowseReadIsEntry(name) {
                        blankReads = 0
                    } else {
                        blankReads += 1
                        if blankReads >= sendBrowseBlankReadCap {
                            throw LogicianError.preconditionUnmet(
                                "The destination browser stopped answering on the walk home:"
                                    + " \(blankReads) consecutive reads showed no catalog entry"
                                    + " (last read '\(name)') — the signature of a send view"
                                    + " being torn down. The browse was abandoned with nothing"
                                    + " confirmed."
                            )
                        }
                    }
                }
                guard reached else {
                    throw LogicianError.openVerificationFailed(
                        "the destination browser never reached the No-Send entry within"
                            + " \(sendBrowseEntryCap) steps; nothing was confirmed (browse"
                            + " abandoned)"
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
                    let status = freshStatus()
                    guard sendViewStanding(in: status) else {
                        throw sendViewDroppedError(status, before: "a forward correction")
                    }
                    _ = try? MCUBridge.send(.vpot(index: destIndex, delta: 1))
                    Thread.sleep(forTimeInterval: 0.4)
                    _ = quiescentStatus()
                    corrections += 1
                }
                // Boundary and view from ONE frame, so the press's meaning and
                // its target are facts about the same instant.
                let confirmationFrame = freshStatus()
                guard let top = confirmationFrame?["lcd_top"] as? String,
                      let bottom = confirmationFrame?["lcd_bottom"] as? String,
                      sendViewStanding(in: confirmationFrame) else {
                    throw sendViewDroppedError(confirmationFrame, before: "the confirming press")
                }
                let boundary = sendDestinationCell(top: top, bottom: bottom, destIndex: destIndex)
                guard boundary == MCULCDStrings.emptySlot else {
                    throw LogicianError.verificationFailed(
                        requested: "the No-Send entry shown at confirmation time",
                        actual: "the entry drifted to '\(boundary)'; aborted without removing",
                        restored: true
                    )
                }
                confirm = try MCUBridge.send(.vpotPress(index: destIndex))
            } catch {
                try abandonedBrowse(error)
            }
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
