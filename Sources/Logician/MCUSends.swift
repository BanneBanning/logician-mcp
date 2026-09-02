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
            // The one press in this server that keeps the old 50 ms hold, and
            // it asks for it BY NAME. Logic Control gives SEND a long-press
            // meaning — held, it opens the submode chooser instead of cycling
            // S1/SE — and the 2026-09-02 hold sweep only cleared the buttons
            // whose behaviour is hold-independent (assign_track, assign_pan,
            // bank_left). Until SEND is swept too, this press is timed exactly
            // as it always was.
            try press("assign_send", holdMs: BridgeCommand.unsweptPressHoldMs)
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

    /// The send slot number a send-view field label names, or nil for
    /// anything that is not a settled slot label. Pure, like its neighbours,
    /// and refusing the banner for the same reason they do: the browse banner
    /// spells the word out (`Send 1`), whose fourth character is not a digit,
    /// so a banner frame can never name a page. This is what proves a page
    /// ADVANCE landed: after a cursor-right, only a frame whose first cell
    /// reads `Sen3…` is the second page. The old walk had no such proof and
    /// a swallowed page press left it re-reading one page under three
    /// numbers — its two cells reported as sends 1, 3 and 5 (observed live
    /// 2026-08-31).
    static func sendSlotNumber(inFieldLabel label: String) -> Int? {
        let prefix = MCULCDStrings.sendFieldLabelPrefix
        guard label.hasPrefix(prefix),
              let digit = label.dropFirst(prefix.count).first?.wholeNumberValue,
              (1...8).contains(digit) else { return nil }
        return digit
    }

    /// How many cursor-lefts separate the page this row belongs to from the
    /// first page — read off the page's own name. A page carries slots
    /// `2p+1` and `2p+2`, so ANY cell that names a slot places the whole row:
    /// `Sen5In` and `Sen6Mu` both say page 3, two steps from home.
    ///
    /// It scans the row rather than reading cell 0 because of the browse
    /// BANNER. Measured live 2026-09-02: right after a confirming press the
    /// top row reads `Send 1 Instantiate   -      Sen2De …` — the banner
    /// covers the first three cells while the fourth already carries the
    /// slot's own label. Cell 0 alone therefore says "this row names no page"
    /// about a row that plainly does, and the four blind cursor-lefts that
    /// answer costs ~1.0 s on every readback an add or a removal makes.
    ///
    /// Pure, and one-sided in the same way as its neighbours: the banner
    /// spells the word out (`Send 1`), whose fourth character is not a digit,
    /// so a banner cell can never name a page; the number this returns is only
    /// ever used to press a key that is a no-op past the first page; and the
    /// landing is proven by the page's own label before anything is read or
    /// written on it.
    static func sendViewPageBacksteps(inRow top: String) -> Int? {
        for cell in lcdFields(top) {
            if let slot = sendSlotNumber(inFieldLabel: cell) { return (slot - 1) / 2 }
        }
        return nil
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
    /// must name the FIRST page AND still name it after the display goes
    /// quiet, so a frame caught mid-repaint cannot skip the walk.
    ///
    /// It asks the whole row (`sendViewPageBacksteps`), not cell 0, for the
    /// reason that function carries: the browse banner covers the first cells
    /// of the page it is editing, and a row whose fourth cell reads `Sen2De`
    /// is page 1 however its first cell is painted. Reading cell 0 alone sent
    /// every post-press readback on a ~1.0 s walk to the page it was already
    /// standing on (measured 2026-09-02, on all eight of that session's
    /// readbacks).
    static func sendViewIsLeftmost() -> Bool {
        func showsFirstPage() -> Bool {
            guard let top = freshStatus()?["lcd_top"] as? String else { return false }
            return sendViewPageBacksteps(inRow: top) == 0
        }
        guard showsFirstPage() else { return false }
        _ = quiescentStatus()
        return showsFirstPage()
    }

    static func sendViewLeftmost() throws {
        // Four blind cursor-lefts cost ~1.0 s (measured 2026-08-31 and again
        // 2026-09-02) and this function runs twice in one `logic_add_send` and
        // three times in one `logic_remove_send`. So: ask the row first, and
        // when it is not the first page, ask it HOW FAR it is instead of
        // walking blind.
        if sendViewIsLeftmost() { return }
        // The row that is not the first page NAMES the page it is: a cell
        // reading `Sen5In` puts the whole row on page 3, exactly two steps
        // from home. Step back that far, each press proven by the page it was
        // supposed to land on rather than by a 150 ms sleep — and keep the
        // four blind lefts for the row that names nothing at all.
        if let backsteps = (freshStatus()?["lcd_top"] as? String)
            .flatMap({ sendViewPageBacksteps(inRow: $0) }),
           backsteps > 0 {
            for page in stride(from: backsteps - 1, through: 0, by: -1) {
                try pressNote(0x62)
                let firstSlot = page * 2 + 1
                _ = waitFor(seconds: 0.6) { status in
                    guard let top = status["lcd_top"] as? String else { return false }
                    return sendViewPageBacksteps(inRow: top) == (firstSlot - 1) / 2
                }
            }
            if sendViewIsLeftmost() { return }
        }
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

    /// True when an OCCUPIED slot on this page is showing its own four field
    /// labels — the proof that the values under them are that slot's values.
    ///
    /// Logic paints two states over a settled send page, and both were caught
    /// live 2026-09-02 handing out other cells' text as a send's fields:
    ///
    /// * the post-write OVERLAY. For about two seconds after a level write
    ///   (1.76-2.01 s, sampled every 250 ms) Logic replaces the position label
    ///   with the destination's own aux name and lets the dB value spill into
    ///   the cell underneath — `Sen1In Send 1  Aux 2 Sen1Mu` over
    ///   `Bus 2  -11,8 dB      active`. Read as a settled row that says
    ///   position `B`.
    /// * the browse BANNER, which covers the first cells of the page it is
    ///   editing.
    ///
    /// An UNOCCUPIED slot is required to show nothing but its destination
    /// label, which is all Logic labels there.
    ///
    /// Pure, so both measured frames can be exercised without a surface.
    static func sendPageShowsSettledFields(_ fields: [(name: String, value: String)]) -> Bool {
        for half in 0..<2 {
            let base = half * 4
            guard fields.indices.contains(base + 3) else { return false }
            let destination = fields[base].value
            guard !destination.isEmpty, destination != MCULCDStrings.emptySlot else { continue }
            guard let slot = sendSlotNumber(inFieldLabel: fields[base].name),
                  sendSlotNumber(inFieldLabel: fields[base + 2].name) == slot,
                  sendSlotNumber(inFieldLabel: fields[base + 3].name) == slot else { return false }
        }
        return true
    }

    /// How long a page read waits for Logic to finish painting over it. Sized
    /// from the measured overlay above (~2 s) plus margin; a page that is
    /// already settled — every read that is not hard on the heels of a write —
    /// pays one status read and none of this.
    static let sendPageSettleBudget: TimeInterval = 3.0

    /// The send view's fields once `settledSendViewRows` agrees, the first
    /// cell's label names the expected slot, AND the page is showing its own
    /// field labels rather than one of Logic's overlays.
    ///
    /// The label check is what defeats the stale mirror: after a swallowed
    /// page press the mirror holds the OLD page perfectly stably, so two
    /// agreeing frames alone prove nothing — only the new page's own slot
    /// number says the page is the one the caller thinks it is reading. The
    /// overlay check is what defeats the opposite failure: a frame that is
    /// stable, current, correctly numbered, and still not the row whose values
    /// the caller wants (`sendPageShowsSettledFields`). Returns nil when the
    /// view is not standing, the mirror is unreadable, or the page never
    /// settles inside `sendPageSettleBudget`.
    static func settledSendPage(
        expectingFirstSlot slot: Int
    ) -> [(name: String, value: String)]? {
        let deadline = Date().addingTimeInterval(sendPageSettleBudget)
        repeat {
            guard sendViewStanding(in: freshStatus()) else { return nil }
            guard let rows = settledSendViewRows() else { return nil }
            let fields = zip(lcdFields(rows.top), lcdValueFields(rows.bottom))
                .map { ($0, $1) }
            if sendSlotNumber(inFieldLabel: fields[0].0) == slot,
               sendPageShowsSettledFields(fields) { return fields }
            _ = quiescentStatus()
        } while Date() < deadline
        return nil
    }

    /// Advances the send view one page and PROVES the landing: the next
    /// page's first slot label must appear in a settled frame. A press that
    /// changed nothing is retried once — the mirror cannot distinguish a
    /// swallowed press from slow repainting, and a second cursor-right is
    /// harmless because the press is a no-op past the last page. Returns the
    /// new page's fields, or nil when the page provably did not change, so
    /// the caller stops instead of reading the old page under new numbers.
    static func advanceSendPage(
        toShowFirstSlot slot: Int
    ) throws -> [(name: String, value: String)]? {
        for _ in 0..<2 {
            let status = freshStatus()
            guard sendViewStanding(in: status) else {
                throw sendViewDroppedError(status, before: "a page advance")
            }
            let events = status?["received_events"] as? Int ?? -1
            try pressNote(0x63)
            _ = awaitEvents(since: events, timeoutMs: 300)
            if let fields = settledSendPage(expectingFirstSlot: slot) { return fields }
        }
        return nil
    }

    /// The debt a finished send write leaves behind instead of walking the
    /// surface home.
    ///
    /// Returning to the Pan-names view costs 1.3-3.4 s (`ensurePanNames`), and
    /// the send tools paid it at the END of every call — putting the surface
    /// back so the next call could take it somewhere else again. The plug-in
    /// tools stopped doing that in package #1; the send tools are a SAFER
    /// place to defer than the plug-in tools were, because a standing send
    /// view is not a plugin-edit assignment (`isPluginEditAssignment` is false
    /// for `SE`), so it cannot make Logic auto-open a plug-in window on the
    /// next track selection — the one hazard the debt pattern was invented to
    /// contain.
    ///
    /// What settles it is unchanged and unmemorised: `ensurePanNames` clears
    /// the record the moment the names view is verified, and every tool that
    /// needs that view already calls it — `findChannel` first of all, which is
    /// why a send call FOLLOWING a send call pays the same restore it always
    /// paid, just at its own start instead of its predecessor's end. What the
    /// deferral actually buys is the call's own latency and the sequences that
    /// end somewhere else, which is most of them.
    ///
    /// FAILURE paths do not use this. A refusal restores explicitly, so a
    /// caller reading "nothing was written" also gets the surface back.
    static func sendViewDebt(strip: String?) -> SurfaceDebt {
        SurfaceDebt(strip: strip, view: "send", slot: nil)
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
            guard try browseToSendDestination(
                destIndex: destIndex, destination: destination
            ) else {
                return nil
            }
            // Let the display go QUIET before the drift check reads it, with
            // the old blind 0.3 s as the deadline rather than the duration.
            // The sleep was buying a settled cell; a proven 150 ms of silence
            // is the same thing measured instead of assumed, and it costs
            // ~155 ms where the sleep-plus-quiescence cost 465 ms (measured
            // 2026-09-02 across eight adds and removals, in which the entry
            // never drifted once — the check that would catch it is
            // untouched below).
            waitForSurfaceQuiet(seconds: 0.5)
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
        // And the browse BANNER has to be gone before the send list is read.
        // The two waits above are satisfied while Logic is still painting
        // `Send 1  Instantiate` over the first three cells, and a readback
        // that starts there cannot prove which page it is on: measured
        // 2026-09-02, its first pass through `settledSendPage` burned ~930 ms
        // failing to see slot 1's label, returned "no sends", and the
        // stale-frame guard then paid another 0.4 s and read the whole page
        // again — 1.9 s of reading a banner, twice. Waiting for the row to
        // name a page costs nothing the readback was not already paying, and
        // the readback below stays exactly as strict as it was.
        _ = waitFor(seconds: 2.5) { status in
            guard let top = status["lcd_top"] as? String else { return false }
            return sendSlotNumber(inFieldLabel: lcdFields(top)[0]) != nil
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
        // The write is done and verified. Nobody has to walk the surface home
        // for that to stay true, so the restore is RECORDED rather than paid:
        // see `sendViewDebt`.
        restoreOnExit = false
        if restoringView { deferSurfaceRestore(sendViewDebt(strip: trackName)) }
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

    /// Pages the send channel view to the page holding the given send slot,
    /// proving every advance landed (`advanceSendPage`) — the blind press it
    /// replaces left a caller reading, or writing, on whatever page a
    /// swallowed press had really left the surface on.
    static func sendViewToPage(forSend send: Int) throws {
        try sendViewLeftmost()
        var page = 0
        while page < (send - 1) / 2 {
            page += 1
            guard try advanceSendPage(toShowFirstSlot: page * 2 + 1) != nil else {
                throw LogicianError.preconditionUnmet(
                    "The send view would not advance to the page holding send"
                        + " \(send): the page press changed nothing twice — the"
                        + " view never painted slot \(page * 2 + 1)'s labels."
                        + " Nothing was read or written on the wrong page."
                )
            }
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
        func readOnce() throws -> [[String: Any]]? {
            try sendViewLeftmost()
            var sends: [[String: Any]] = []
            for page in 0..<4 {
                let firstSlot = page * 2 + 1
                // Every page is read settled AND proven to BE that page by
                // its own slot label. The walk this replaces read one raw
                // frame and pressed the page advance blind, which failed both
                // ways in one live session (2026-08-31): a swallowed press
                // re-read the same page as sends 1, 3 and 5, and a
                // mid-repaint frame hid an occupied slot 1 behind a blank —
                // and the removal that compared that garbage `before` against
                // a good `after` reported verification_failed on a removal
                // that had succeeded.
                let fields = page == 0
                    ? settledSendPage(expectingFirstSlot: firstSlot)
                    : try advanceSendPage(toShowFirstSlot: firstSlot)
                guard let fields else {
                    // The first page never readable means there is no send
                    // view to read; a later page that provably never arrived
                    // stops the walk with what is proven so far rather than
                    // reading the old page under new numbers.
                    if page == 0 { return nil }
                    break
                }
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
            }
            return sends
        }
        if let first = try readOnce(), !first.isEmpty { return first }
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
        sendNumber: Int, targetDb: Double, expectedCurrentValue: String?,
        strip: String? = nil
    ) throws -> [String: Any]? {
        guard (1...8).contains(sendNumber) else {
            throw LogicianError.invalidArguments("send must be 1-8")
        }
        guard try ensureSendView() else { return nil }
        // Every failure walks home; the verified write records the debt
        // instead (`sendViewDebt`).
        var restoreOnExit = true
        defer { if restoreOnExit { exitToPan() } }
        try sendViewToPage(forSend: sendNumber)
        guard let fields = settledSendPage(
            expectingFirstSlot: ((sendNumber - 1) / 2) * 2 + 1
        ) else { return nil }
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
        restoreOnExit = false
        deferSurfaceRestore(sendViewDebt(strip: strip))
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
        // the pattern the add-and-level path already runs on. A verified
        // removal RECORDS that restore instead of paying it (`sendViewDebt`);
        // every refusal still walks home before it reports.
        var restoreOnExit = true
        defer { if restoreOnExit { exitToPan() } }
        guard let beforeList = try readSends(restoringView: false) else { return nil }
        let before = sendListEntries(beforeList)
        switch try resolveSendRemoval(
            sendNumber: sendNumber, destination: destination, sends: before
        ) {
        case .alreadyRemoved(let detail):
            restoreOnExit = false
            deferSurfaceRestore(sendViewDebt(strip: trackName))
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
            var rowAtConfirmation = ""
            do {
                // Which SPELLING of the name the jump arithmetic is given
                // decides whether the jump happens at all — the send list
                // abbreviates (`B 200`), the caller does not — so
                // `sendRemovalHomeJump` owns that choice and carries the
                // reasoning.
                if let entries = sendRemovalHomeJump(
                    requested: destination, listed: listedDestination
                ) {
                    guard try sendBrowseJump(destIndex: destIndex, entries: entries)
                    else { return nil }
                }
                var reached = false
                var blankReads = 0
                var stepsHome = 0
                // LOOK before stepping. The jump above now aims at the
                // boundary itself rather than eight entries short of it, so
                // the walk's ordinary case is that it is already there — and a
                // walk that always stepped first would step PAST the entry it
                // came for. (Past it is only the clamp, so the old shape was
                // safe; it was just a step nobody needed.)
                reached = shownName() == MCULCDStrings.emptySlot
                while !reached, stepsHome < sendBrowseEntryCap {
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
                    stepsHome += 1
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
                // The same settle the add makes, and the same measurement
                // behind it: a proven 150 ms of silence in place of a blind
                // 0.3 s, with 0.5 s as the deadline. The boundary re-check
                // below is untouched — it is what stands between this call and
                // rewriting the send to whatever a repaint left showing.
                waitForSurfaceQuiet(seconds: 0.5)
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
                // Kept for the commit check below: the row the press was sent
                // into is what the repaint that answers it has to differ from.
                rowAtConfirmation = top
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
            // The press is answered by Logic REPAINTING the slot's field
            // group, exactly as the add's is — captured live 2026-09-02, which
            // the code that waited a flat second here could not yet say: the
            // top row changed 46, 49, 49 and 60 ms after the press (the
            // browsed slot's labels flipping, `Sen2In` -> `Sen2De`), while the
            // destination cell stayed on the No-Send entry it was confirmed
            // on. So wait for the ROW to move, with the same one second as the
            // deadline instead of the duration: a slower Logic gets exactly as
            // long as before, and the send-list readback below — the actual
            // verification — is untouched and keeps the last word.
            _ = waitFor(seconds: 1.0) { status in
                (status["lcd_top"] as? String) != rowAtConfirmation
            }
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
            restoreOnExit = false
            deferSurfaceRestore(sendViewDebt(strip: trackName))
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
