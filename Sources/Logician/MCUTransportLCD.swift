import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {
    // MARK: Transport

    /// Gates on `requireSurface`, not bare `freshStatus()` — a mirror that has
    /// merely gone idle (`SurfaceUnavailability.logicSilent`, past
    /// `staleMirrorSeconds`) is answerable with `requireSurface`'s one
    /// `wakeSurface()` probe, and used to downshift straight to the AX
    /// fallback instead (profiles/logic_set_cycle.md N1, 2026-09-02). `try?`
    /// turns a GENUINE unavailability (no daemon, Logic not running, Logic
    /// never talked to the surface) back into the `nil` this function already
    /// used to hand the write to `logic.setPlaying`'s AX route — only the
    /// merely-idle case now stays on MCU. Same shape as `MCUMixing.setToggle`
    /// and `MCUMetronome.setMetronome`.
    static func setPlaying(_ playing: Bool) throws -> [String: Any]? {
        guard let status = try? requireSurface(
            "the play/stop transport buttons on the control surface", consequence: "Nothing was pressed"
        ) else { return nil }
        let playLED = 0x5E
        if ledLit(playLED, in: status) == playing {
            return [
                "success": true, "verified": true,
                "state": playing ? "already_playing" : "already_stopped",
                "playing": playing, "route": "mcu"
            ]
        }
        try press(playing ? "play" : "stop")
        guard pollStatus(until: { ledLit(playLED, in: $0) == playing }) != nil else {
            throw LogicianError.verificationFailed(
                requested: "playing=\(playing)",
                actual: "MCU play LED did not change",
                restored: false
            )
        }
        return [
            "success": true, "verified": true,
            "state": playing ? "playing" : "stopped",
            "playing": playing,
            "route": "mcu",
            "readback_route": "mcu_transport_led"
        ]
    }

    /// See `setPlaying` above: `requireSurface` wakes a merely-idle mirror
    /// instead of silently taking the AX fallback (profiles/
    /// logic_set_cycle.md N1). `nil` still means genuinely unavailable.
    static func setCycle(_ enabled: Bool) throws -> [String: Any]? {
        guard let status = try? requireSurface(
            "the cycle button on the control surface", consequence: "Nothing was pressed"
        ) else { return nil }
        let cycleLED = 0x56
        if ledLit(cycleLED, in: status) == enabled {
            return [
                "success": true, "verified": true,
                "state": "already_" + (enabled ? "cycle_on" : "cycle_off"),
                "cycle": enabled, "route": "mcu"
            ]
        }
        try press("cycle")
        guard pollStatus(until: { ledLit(cycleLED, in: $0) == enabled }) != nil else {
            throw LogicianError.verificationFailed(
                requested: "cycle=\(enabled)",
                actual: "MCU cycle LED did not change",
                restored: false
            )
        }
        return [
            "success": true, "verified": true,
            "state": enabled ? "cycle_on" : "cycle_off",
            "cycle": enabled, "route": "mcu",
            "readback_route": "mcu_cycle_led"
        ]
    }

    // MARK: LCD helpers

    /// The eight cells as the row literally prints them — the reading for
    /// NAMES. Shared with the daemon so one slicer serves both planes.
    static func lcdFields(_ row: String) -> [String] {
        MCULCDRow.cells(row)
    }

    /// The eight cells read as numeric VALUE echoes: identical to `lcdFields`
    /// except on the rightmost strip, whose single-channel banner is shifted
    /// one column left and leaves its sign character in cell 6. Every read
    /// that a write is verified or converged against goes through this one;
    /// reading a value literally cost `Stereo Out` 6 dB (MCULCDRow.valueCell).
    static func lcdValueFields(_ row: String) -> [String] {
        MCULCDRow.valueCells(row)
    }

    /// Logic abbreviates track names on the MCU LCD by dropping characters
    /// ("Lofi Pad" -> "LofPad"); an ordered subsequence match recovers them.
    static func lcdNameMatches(track: String, lcd: String) -> Bool {
        guard !lcd.isEmpty else { return false }
        let target = track.replacingOccurrences(of: " ", with: "").lowercased()
        let shown = lcd.replacingOccurrences(of: " ", with: "").lowercased()
        guard let first = shown.first, target.first == first else { return false }
        var iterator = target.makeIterator()
        var pending = shown[...]
        while let character = pending.first {
            var found = false
            while let candidate = iterator.next() {
                if candidate == character { found = true; break }
            }
            if !found { return false }
            pending = pending.dropFirst()
        }
        return true
    }

    /// The assign_pan button TOGGLES between the multi-channel pan view (track
    /// names on top) and a single-channel view ("Pan    -      -   ..."), and
    /// the assignment display reads "PN" in both — so the mode must be verified
    /// by LCD content, never by blind presses.
    static func ensurePanNames() throws -> Bool {
        // The PAN assignment button TOGGLES between the multi-channel names
        // view and a single-channel pan view - and the transition into the
        // single view repaints through frames that LOOK like the names view
        // (names first, then the "Pan/Surround parameter:" label overwrites
        // the right half). Deciding on a transient frame makes the loop
        // fight its own toggles, so: wait for a STABLE display, classify,
        // only then press.
        func stableState() -> (top: String, assignment: String)? {
            // A full second of silence: the transition through the mode
            // banner ("Pan/Surround parameter: ...") contains sub-second
            // paint pauses that fool shorter windows into classifying a
            // frame that is still on its way somewhere else.
            //
            // But silence is not the only proof of a settled display, and
            // insisting on it was a real deadlock: with any track RECORD-ARMED
            // Logic flashes that strip's rec LED forever (~640 ms on, ~640 ms
            // off, measured 2026-08-28), so `timed_out` never comes true and
            // this whole function returned nil — taking findChannel, and with
            // it every MCU tool, down for as long as a track was armed. LED
            // traffic never touches the LCD, so a top row that has been
            // IDENTICAL for a full second is settled whether or not Logic is
            // still talking. Both proofs are accepted; the quiet one first,
            // because it is the stronger of the two.
            let deadline = Date().addingTimeInterval(5.0)
            var lastTop: String?
            var unchangedSince: Date?
            while Date() < deadline {
                guard let status = freshStatus(), let top = status["lcd_top"] as? String else { return nil }
                let events = status["received_events"] as? Int ?? -1
                if top == lastTop {
                    let since = unchangedSince ?? Date()
                    unchangedSince = since
                    if let after = awaitEvents(since: events, timeoutMs: 1000),
                       after["timed_out"] as? Bool == true,
                       let fresh = freshStatus(), (fresh["lcd_top"] as? String) == top {
                        return (top, status["assignment"] as? String ?? "")
                    }
                    if Date().timeIntervalSince(since) >= 1.0,
                       let fresh = freshStatus(), (fresh["lcd_top"] as? String) == top {
                        return (top, status["assignment"] as? String ?? "")
                    }
                } else {
                    unchangedSince = nil
                }
                lastTop = top
                _ = awaitEvents(since: events, timeoutMs: 200)
            }
            return nil
        }
        func fullNames(_ status: [String: Any]) -> Bool {
            guard let top = status["lcd_top"] as? String else { return false }
            return (status["assignment"] as? String) == MCULCDStrings.Assignment.pan
                && !top.contains(MCULCDStrings.parameterBannerMarker)
                && lcdFields(top).filter({ $0 == MCULCDStrings.clearingCell }).count < 4
        }
        /// FAST PATH — the positive check, tried before the silence proof.
        ///
        /// `stableState` costs ~1230 ms because it will not classify anything
        /// until the display has been quiet (or motionless) for a full second,
        /// and it is called at least twice per `ensurePanNames`. But a full
        /// second of proof is what you need when you do not know WHAT you are
        /// looking at. Here we do: this function has exactly one target state,
        /// and the LCD either already shows it or it does not.
        ///
        /// So: read the row, and only if it ALREADY passes `fullNames` spend
        /// 100 ms confirming it. The confirmation is two proofs at once — the
        /// top row must be byte-identical across the gap AND still classify as
        /// the names view. That rules out the frame this function's whole
        /// design is afraid of (the toggle into the single-channel view paints
        /// names first and overwrites the right half a moment later): a row
        /// caught mid-transition is not the same row 100 ms later.
        ///
        /// It is a fast path, not a weakened proof. Nothing is pressed on the
        /// strength of it — it only ever returns "already there" — and when it
        /// does not fire the full quiescence proof runs exactly as before, one
        /// `freshStatus` (0.7 ms) later.
        func confirmedFullNames() -> Bool {
            guard let first = freshStatus(), fullNames(first) else { return false }
            guard let top = first["lcd_top"] as? String else { return false }
            let events = first["received_events"] as? Int ?? -1
            _ = awaitEvents(since: events, timeoutMs: 100)
            guard let second = freshStatus(), fullNames(second) else { return false }
            return (second["lcd_top"] as? String) == top
        }
        /// FAST NEGATIVE — the other half of the fast path.
        ///
        /// `stableState` earns its full second when the question is "WHAT am I
        /// looking at?", and the answer is genuinely ambiguous inside the pan
        /// family: the multi-channel names view, the single-channel pan view
        /// and the mode banner all read `PN`. Outside it there is nothing to
        /// disambiguate — a row whose assignment code is `CS`, `SE`, `IN` or
        /// `P…` is not the names view under any reading, and the move from
        /// every one of them is the same press.
        ///
        /// So a non-`PN` code that is byte-identical (row AND code) across the
        /// same 100 ms gap `confirmedFullNames` uses skips the silence proof.
        /// Measured 2026-09-02: `stableState` cost 1 209.8 ms to conclude
        /// `asgn='CS'` about a view `ensureVolumeView` had verified 6.7 s
        /// earlier.
        ///
        /// The worst case is bounded and cheap: if the code is stale because a
        /// repaint INTO the pan view is in flight, the press toggles one step
        /// too far and the next iteration classifies and presses again — one
        /// extra pass through a six-iteration loop, against a second saved on
        /// every restore.
        func confirmedNonPanState() -> (top: String, assignment: String)? {
            guard let first = freshStatus(),
                  let top = first["lcd_top"] as? String,
                  let code = first["assignment"] as? String,
                  !code.isEmpty, code != MCULCDStrings.Assignment.pan else { return nil }
            let events = first["received_events"] as? Int ?? -1
            _ = awaitEvents(since: events, timeoutMs: 100)
            guard let second = freshStatus(),
                  (second["lcd_top"] as? String) == top,
                  (second["assignment"] as? String) == code else { return nil }
            return (top, code)
        }
        /// Waits for the names view to HOLD, not merely to appear.
        ///
        /// The press used to be followed by `waitFor(fullNames)`, and measured
        /// 2026-09-02 that returned hit=true in **20.3 ms** — on the frame
        /// where Logic had painted the names row and had not yet dropped the
        /// `Pan/Surround parameter:` banner over its right half. 200 µs later
        /// the same row failed `confirmedFullNames`, so the loop went round
        /// again and paid a full second of silence proof plus the banner wait
        /// for a press that had already worked: 2 029 ms for one press
        /// (pattern #5 — a fast check that disagrees pays ONE settled read,
        /// not a whole extra iteration).
        func waitForConfirmedFullNames(seconds: Double) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while true {
                if confirmedFullNames() { return true }
                if Date() >= deadline { return false }
                guard let status = freshStatus() else { return false }
                _ = awaitEvents(since: status["received_events"] as? Int ?? -1, timeoutMs: 200)
            }
        }
        for iteration in 0..<6 {
            if confirmedFullNames() {
                surfaceDebt = nil
                return true
            }
            if let quick = confirmedNonPanState() {
                debugLog("ensurePanNames[\(iteration)]: fast asgn='\(quick.assignment)'")
            } else {
                guard let proven = stableState() else { debugLog("ensurePanNames[\(iteration)]: no stable state"); return false }
                debugLog("ensurePanNames[\(iteration)]: asgn='\(proven.assignment)' top='\(proven.top.prefix(48))'")
                if fullNames(["lcd_top": proven.top, "assignment": proven.assignment]) {
                    surfaceDebt = nil
                    return true
                }
                if proven.top.contains(MCULCDStrings.parameterBannerMarker)
                    && proven.assignment == MCULCDStrings.Assignment.pan {
                    // Names view with Logic's mode BANNER ("Pan/Surround
                    // parameter: Pan") still covering the right half - it fades
                    // on its own; pressing now would toggle AWAY from the
                    // correct view, so wait it out.
                    debugLog("ensurePanNames[\(iteration)]: waiting out mode banner")
                    if waitForConfirmedFullNames(seconds: 5.0) {
                        surfaceDebt = nil
                        return true
                    }
                    continue
                }
            }
            // Any other state (single-channel pan, the channel-strip overview,
            // a plugin view, ...) - press toward the names view, then wait for
            // the target to HOLD. A press that goes nowhere falls through to
            // the unchanged classification on the next iteration.
            try press("assign_pan")
            if waitForConfirmedFullNames(seconds: 5.0) {
                surfaceDebt = nil
                return true
            }
        }
        return false
    }

    static func ensureAssignment(_ code: String, button: String) throws -> [String: Any]? {
        for _ in 0..<3 {
            guard let status = freshStatus() else { return nil }
            if (status["assignment"] as? String) == code { return status }
            try press(button)
            if let reached = waitFor(seconds: 1.2, { ($0["assignment"] as? String) == code }) {
                return reached
            }
        }
        return freshStatus().flatMap { ($0["assignment"] as? String) == code ? $0 : nil }
    }

    static func debugLog(_ message: String) {
        FileHandle.standardError.write(Data("[mcu] \(message)\n".utf8))
    }

    /// Banks to the leftmost position, scans right for a channel whose LCD
    /// name matches, and leaves the surface banked at the match. Returns nil
    /// (nothing written that matters) when not found or ambiguous.
    static var bankCacheURL: URL {
        MCUBridge.directory.appendingPathComponent("bank-cache.json")
    }

    /// The bank map is a picture of THIS project's track order as read by THIS
    /// build. Opening another project does not make it stale, it makes it
    /// wrong - every lookup would point at whatever track happens to sit in
    /// that slot instead - so the project path and schema version are part of
    /// the file. Returns nil for "no usable cache", which callers answer with
    /// a full scan, never a guess.
    static func loadBankCache(projectPath: String?) -> [String]? {
        loadScopedCache(bankCacheURL, projectPath: projectPath, as: [String].self)
    }

    // MARK: The left edge

    /// What a walk to the leftmost bank actually established.
    ///
    /// This helper used to be `for _ in 0..<8 { press("bank_left") }` with no
    /// return value at all, and that made it wrong in both directions:
    ///
    /// * **On a big project it did not reach the edge.** Eight presses is 64
    ///   strips. From bank 12 it landed on bank 4, and everything downstream —
    ///   the census's bank/strip numbers, `bank-cache.json`, and therefore
    ///   every later write resolved through `navigateToBank` — was SHIFTED by
    ///   the distance it had not travelled. Silently, with `success: true`.
    /// * **On a small one it paid for presses that did nothing.** A press that
    ///   moves a bank costs 57 ms (Logic answers, the wait returns at once); a
    ///   press at the edge costs 207 ms, because the whole 150 ms event wait
    ///   times out. Measured 2026-09-02: 1 245 ms from bank 4 and **1 703 ms
    ///   from the leftmost bank** — 48–56% of `logic_list_strips`, and the
    ///   call was half a second MORE expensive when the surface was already
    ///   where it wanted to be.
    ///
    /// Both are the same defect: a COUNT standing in for a proof. The walk now
    /// stops on the edge's own evidence and says whether it got there.
    enum LeftmostBankProof: Equatable {
        /// The surface is at the leftmost bank, and the edge itself said so
        /// (see `bankLeftLooksLikeEdge` and `leftEdgeConfirmed`).
        case atLeftEdge(presses: Int)
        /// The edge never proved itself. Callers must NOT read a bank map from
        /// here — where the surface is standing is unknown, which is the one
        /// state that makes a census point at the wrong channels.
        case unproven(presses: Int, reason: String)
    }

    /// The guard against pressing forever, not a distance. The walk stops on
    /// the edge's proof, so this only bounds a surface that has stopped
    /// behaving: 64 banks is 512 strips, eight times the old blind count, and
    /// reaching it is reported rather than mistaken for having arrived.
    static let leftEdgeWalkCap = 64

    /// The event wait after one `bank_left`. Logic answers a press that moved
    /// a bank in ~4 ms (57 ms round trip against a 53 ms press), so this is
    /// already generous; it is the cost of the ONE press that finds the edge.
    static let leftEdgePressWaitMs = 150

    /// The second, confirming window after a press that looked like the edge.
    static let leftEdgeConfirmMs = 150

    /// How long an unmoving name row is proof on its own, when Logic will not
    /// go quiet (a record-armed strip blinks its LED forever — LED traffic
    /// never touches the LCD). Same constant and same reasoning as
    /// `ensurePanNames`'s `stableState` and `settledTop`.
    static let motionlessRowProofSeconds = 1.0

    /// Does one `bank_left` press LOOK like it hit the left edge?
    ///
    /// Two independent facts, BOTH required: Logic answered the press with no
    /// MIDI at all, and the channel-name row is byte-identical across it.
    ///
    /// `timed_out` alone is not proof, and this is exactly what the
    /// `logic_export_stems` fix judged an early exit on it too risky for: a
    /// bank change Logic answers LATE would look like an edge, end the walk
    /// early, and start the census mid-project — a wrong-channel write hazard,
    /// which is worse than the second it saves. The row is the second witness
    /// (a bank that moved cannot show the same eight names, see
    /// `clampOverlap`), and `leftEdgeConfirmed` is the third: it waits out the
    /// late answer before believing either of them.
    static func bankLeftLooksLikeEdge(rowBefore: String, rowAfter: String, answered: Bool) -> Bool {
        !answered && rowBefore == rowAfter
    }

    /// The confirming look, after a press that looked like the edge: the row
    /// is still the one we pressed from, and either nothing arrived in a
    /// second quiet window (the late answer never came) or the row has held
    /// still long enough that Logic's ongoing chatter cannot be about it.
    static func leftEdgeConfirmed(
        rowBefore: String, rowNow: String, quiet: Bool, unchangedFor: TimeInterval
    ) -> Bool {
        guard rowNow == rowBefore else { return false }
        return quiet || unchangedFor >= motionlessRowProofSeconds
    }

    /// Spends one more window proving the press that looked like an edge did
    /// not simply get a late answer. True = the edge is proven.
    private static func confirmLeftEdge(row: String, since: Int) -> Bool {
        let unchangedSince = Date()
        let deadline = unchangedSince.addingTimeInterval(motionlessRowProofSeconds + 0.5)
        var events = since
        while true {
            let quiet = awaitEvents(since: events, timeoutMs: leftEdgeConfirmMs)?["timed_out"] as? Bool == true
            guard let now = freshStatus(), let rowNow = now["lcd_top"] as? String else { return false }
            events = now["received_events"] as? Int ?? events
            if leftEdgeConfirmed(
                rowBefore: row, rowNow: rowNow, quiet: quiet,
                unchangedFor: Date().timeIntervalSince(unchangedSince)
            ) { return true }
            // The row moved: the press DID change the bank and Logic was just
            // slow to say so. Keep walking.
            if rowNow != row { return false }
            if Date() >= deadline { return false }
        }
    }

    /// Walks to the leftmost bank and proves it got there.
    static func resetToLeftmostBank() throws -> LeftmostBankProof {
        var presses = 0
        while presses < leftEdgeWalkCap {
            guard let before = freshStatus(), let rowBefore = before["lcd_top"] as? String else {
                return .unproven(
                    presses: presses,
                    reason: "the control-surface mirror stopped answering during the walk to the leftmost bank"
                )
            }
            let beforeEvents = before["received_events"] as? Int ?? -1
            try press("bank_left")
            presses += 1
            let answered = awaitEvents(
                since: beforeEvents, timeoutMs: leftEdgePressWaitMs
            )?["timed_out"] as? Bool != true
            guard let after = freshStatus(), let rowAfter = after["lcd_top"] as? String else {
                return .unproven(
                    presses: presses,
                    reason: "the control-surface mirror stopped answering during the walk to the leftmost bank"
                )
            }
            guard bankLeftLooksLikeEdge(rowBefore: rowBefore, rowAfter: rowAfter, answered: answered) else {
                continue
            }
            if confirmLeftEdge(row: rowBefore, since: after["received_events"] as? Int ?? -1) {
                return .atLeftEdge(presses: presses)
            }
        }
        return .unproven(
            presses: presses,
            reason: "\(leftEdgeWalkCap) bank_left presses never reached an edge that proved itself — "
                + "the surface kept moving or kept answering, so which bank it is standing on is unknown"
        )
    }

    /// Is the surface ALREADY showing the bank a cached map put this channel
    /// in, given a live name row that may be carrying Logic's press banner?
    ///
    /// THE BANNER. Logic overwrites the touched strip's NAME cell with the name
    /// of the control it just saw and leaves it there: press solo on `Bas` and
    /// the row reads `LofPad Solo   808    Inst 2 …` where the bank map says
    /// `LofPad Bas    808    Inst 2 …`. It does not clear on a short timer —
    /// measured 2026-09-02 on `Testlåt Copy`, a 600 ms wait for the mapped
    /// row to come back never once succeeded. (Re-measured the same day at
    /// 50 ms resolution: it is a timed transient of **1.94–1.99 s**, and a
    /// bank change does not clear it — see `controlBannerFadeBudget`. So this
    /// tolerant match is still the right answer here, because waiting two
    /// seconds to confirm a bank the surface is already standing on would cost
    /// more than the navigation it saves.)
    ///
    /// WHAT IT COST. A byte-exact row comparison was the only way to answer
    /// "am I already banked here?", so that one transient cell sent every solo
    /// of a stem run into a full re-navigation OF THE BANK IT WAS ALREADY ON —
    /// `resetToLeftmostBank` presses bank_left eight times blind and, at the
    /// left edge, Logic answers each press with nothing at all, so every press
    /// burns its whole 150 ms event wait. Measured: 1 993 and 2 000 ms for the
    /// two solos that met a banner against 105 ms for the four that met a clean
    /// row — 51% of `logic_export_stems`, spent walking back to where the
    /// surface stood.
    ///
    /// WHY THIS IS MORE PROOF, NOT LESS. The exact row is still accepted first
    /// and unchanged. The second clause asks for something the exact-row test
    /// never asked at all: that the cell this call is about to WRITE reads its
    /// own mapped name on the LIVE display — the row test only ever proved the
    /// row and then trusted the cached map for the channel. On top of that at
    /// most one OTHER cell may differ, which is the banner's exact signature.
    /// A different bank cannot slip through: banks are contiguous windows of
    /// the strip list, so a neighbouring one is SHIFTED and differs in seven or
    /// eight cells (see `clampOverlap`), and passing would need seven
    /// duplicate names in seven aligned positions.
    static func bankedAtMatch(live: String, cached: String, channel: Int) -> Bool {
        if live == cached { return true }
        let liveCells = lcdFields(live)
        let cachedCells = lcdFields(cached)
        guard liveCells.count == cachedCells.count,
              liveCells.indices.contains(channel),
              liveCells[channel] == cachedCells[channel] else { return false }
        return zip(liveCells, cachedCells).filter(!=).count == 1
    }

    /// Navigates to a bank by index (from leftmost) and verifies the expected
    /// LCD content. Returns false on mismatch (stale cache).
    static func navigateToBank(_ index: Int, expecting expectedTop: String) throws -> Bool {
        // Counting right from an UNPROVEN left edge lands on bank
        // `index + (however far the walk fell short)`, and the row check below
        // would then have to catch it — which it does, but only after paying
        // the whole navigation. Refuse at the start instead.
        if case .unproven(let presses, let reason) = try resetToLeftmostBank() {
            debugLog("navigateToBank(\(index)): \(reason) after \(presses) presses")
            return false
        }
        for _ in 0..<index {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            try press("bank_right")
            _ = awaitEvents(since: before, timeoutMs: 250)
        }
        if waitFor(seconds: 1.5, { ($0["lcd_top"] as? String) == expectedTop }) != nil { return true }
        debugLog("navigateToBank(\(index)): expected '\(expectedTop)' actual '\(freshStatus()?["lcd_top"] as? String ?? "?")'")
        return false
    }

    /// The strip index of a named channel on the surface, with the surface
    /// left banked at it — or nil when it could not be resolved SAFELY, which
    /// callers answer by trying the other control plane, never by guessing.
    /// `lastChannelResolution` carries the reason.
    static func findChannel(trackName: String, retryOnEmpty: Bool = true) throws -> Int? {
        let resolution = try resolveChannel(trackName: trackName, retryOnEmpty: retryOnEmpty)
        lastChannelResolution = resolution
        guard case .resolved(let channel) = resolution else {
            debugLog("findChannel('\(trackName)'): \(resolution)")
            return nil
        }
        return channel
    }

    /// Banks to the leftmost position, scans right for a strip whose LCD name
    /// matches, and leaves the surface banked at the match. Nothing that
    /// matters is written on any failure path.
    static func resolveChannel(trackName: String, retryOnEmpty: Bool = true) throws -> ChannelResolution {
        guard try ensurePanNames() else {
            debugLog("pan multi-channel view failed")
            return .unavailable(reason: "the control surface's pan-names view could not be reached")
        }

        // Resolve the project ONCE: both cache reads below and the write at
        // the end of the scan must agree on which project the map belongs to,
        // and re-asking mid-scan could straddle a project switch.
        let projectPath = currentProjectPath()

        // Fast path: the cached bank map from the previous full scan. A cache
        // may be stale, so only a fresh scan is allowed to DECLARE not-found
        // or ambiguous — an unusable cache falls through to a rescan.
        if let cachedTops = loadBankCache(projectPath: projectPath) {
            let matches = channelMatches(name: trackName, bankTops: cachedTops)
            if matches.count == 1, let match = matches.first {
                // Fastest path: the surface is already banked at the match —
                // including when Logic is still showing the press banner over
                // some OTHER strip's name cell (see `bankedAtMatch`).
                if let top = freshStatus()?["lcd_top"] as? String,
                   bankedAtMatch(live: top, cached: cachedTops[match.bank], channel: match.channel) {
                    return .resolved(match.channel)
                }
                if try navigateToBank(match.bank, expecting: cachedTops[match.bank]) {
                    return .resolved(match.channel)
                }
            }
            try? FileManager.default.removeItem(at: bankCacheURL)
        }

        if case .unproven(let presses, let reason) = try resetToLeftmostBank() {
            debugLog("resolveChannel: \(reason)")
            return .unavailable(
                reason: "the surface would not walk to its leftmost bank (\(reason), \(presses) presses), "
                    + "and a scan that starts on an unknown bank would resolve the name to the wrong channel"
            )
        }
        // The single-channel Pan view ("Pan    -      -   ...") looks like a
        // transient display to settledTop (>= 4 dash fields) and would time
        // out the whole scan - re-enter the multi-channel names view and
        // retry once before giving up.
        var settled = try settledTop()
        if settled == nil {
            debugLog("no settled top after reset; re-entering pan names")
            _ = try ensurePanNames()
            settled = try settledTop()
        }
        guard var top = settled else {
            debugLog("no settled top after reset")
            return .unavailable(reason: "the surface's channel-name row never settled")
        }
        var bankTops: [String] = []
        var reachedRightmost = false
        scan: while bankTops.count < bankScanCap {
            bankTops.append(top)
            let beforeEvents = freshStatus()?["received_events"] as? Int ?? -1
            try press("bank_right")
            switch try settledTopOutcome(previous: top, eventsBeforePress: beforeEvents) {
            case .settled(let next):
                top = next
            case .unchanged:
                reachedRightmost = true
                break scan
            case .neverSettled, .surfaceUnreadable:
                debugLog("no settled top in scan")
                return .unavailable(reason: "a bank's channel-name row never settled during the scan")
            }
        }
        guard reachedRightmost else {
            // Same cap, same reasoning as `scanBanks`: a map that stops where
            // the loop ran out is a map that answers for the wrong channel.
            return .unavailable(
                reason: "the surface was still showing new banks after \(bankScanCap) of them "
                    + "(\(bankScanCap * 8) strips), so the bank map would be truncated; nothing was cached"
            )
        }
        saveScopedCache(bankTops, to: bankCacheURL, projectPath: projectPath)
        let matches = channelMatches(name: trackName, bankTops: bankTops)
        // Right after a project switch Logic rebuilds the control surface for
        // a few seconds and a full scan can come up empty — settle and rescan
        // once before giving up.
        if matches.isEmpty, retryOnEmpty {
            debugLog("empty bank scan; settling and rescanning once")
            Thread.sleep(forTimeInterval: 2.5)
            try? FileManager.default.removeItem(at: bankCacheURL)
            return try resolveChannel(trackName: trackName, retryOnEmpty: false)
        }
        guard matches.count == 1, let match = matches.first else {
            debugLog("match count \(matches.count)")
            let cells = matches.map { lcdFields(bankTops[$0.bank])[$0.channel] }
            return matches.isEmpty
                ? .notFound(cells: bankMapCells(bankTops))
                : .ambiguous(cells: cells)
        }
        // Navigate back from the left edge, never relatively: when the track
        // count is not a multiple of 8 the rightmost bank CLAMPS (shows the
        // last 8 tracks), so stepping left from there walks a SHIFTED grid
        // and the expected bank content never reappears.
        if try navigateToBank(match.bank, expecting: bankTops[match.bank]) {
            return .resolved(match.channel)
        }
        debugLog("navigate-back verify failed")
        return .unavailable(reason: "the surface would not bank back to the matching bank")
    }

    /// The bound on a bank walk to the RIGHT. Like `leftEdgeWalkCap` this is
    /// the guard against walking forever, not the expected length: a scan
    /// stops when the surface PROVES the list ended (the rightmost bank clamps
    /// and the row stops changing, `SettledTopOutcome.unchanged`). The old
    /// bound was 10 with no branch for running out, so a project past 80
    /// strips was silently truncated and still reported `success: true`;
    /// 128 banks is 1 024 strips and reaching it is a refusal.
    static let bankScanCap = 128

    /// What a wait for a settled channel-name row established. The three
    /// non-`settled` cases were all one `nil`-or-`previous` return before, and
    /// a bank walk cannot tell them apart from the outside — which is how "the
    /// row never settled" came to mean "the project ends here".
    enum SettledTopOutcome: Equatable {
        /// A stable, non-transient row, and a DIFFERENT one from `previous`
        /// where a previous was given.
        case settled(String)
        /// `previous` came back and held through the silence proof: this row
        /// will not change. On a bank walk that is the rightmost bank's clamp,
        /// and it is the only PROOF a scan has that the strip list ended.
        case unchanged(String)
        /// The budget ran out with the row still moving. NOT an end of list —
        /// a walk that treats it as one truncates itself in silence.
        case neverSettled
        /// The mirror stopped answering.
        case surfaceUnreadable
    }

    /// How many 200 ms silence rounds prove "this row is not going to change".
    ///
    /// Two, normally: a row that still equals `previous` is only evidence that
    /// nothing has repainted YET. But when the caller can say the press that
    /// preceded this wait produced NO MIDI EVENT AT ALL, the second round buys
    /// nothing — there was never anything in flight to wait for. That matters
    /// because this is the end-of-scan probe: the last step of a bank walk
    /// cost 480 ms against 182 ms for a real one, 19% of `logic_list_strips`
    /// (measured 2026-09-02). One round instead of two, −200 ms per walk.
    static func quietRoundsRequired(eventsBeforePress: Int?, eventsNow: Int) -> Int {
        guard let before = eventsBeforePress, before >= 0, eventsNow == before else { return 2 }
        return 1
    }

    /// Waits until the LCD top row holds stable, non-transient channel content
    /// (two consecutive identical reads that are not a "-      " banner), and
    /// differs from `previous` when given (returns previous content on timeout,
    /// which scan loops interpret as "rightmost bank reached").
    ///
    /// The optional-String reading of `settledTopOutcome`, kept for the callers
    /// that only ever want a row. A walk that has to tell "the list ended"
    /// apart from "the row never settled" asks the outcome directly.
    static func settledTop(previous: String? = nil) throws -> String? {
        switch try settledTopOutcome(previous: previous) {
        case .settled(let row), .unchanged(let row): return row
        case .neverSettled: return previous
        case .surfaceUnreadable: return nil
        }
    }

    /// - Parameter eventsBeforePress: the mirror's event count from
    ///   immediately BEFORE the press this wait is settling — the evidence
    ///   `quietRoundsRequired` uses to charge one silence round instead of two
    ///   for a press Logic ignored entirely.
    static func settledTopOutcome(
        previous: String? = nil, eventsBeforePress: Int? = nil
    ) throws -> SettledTopOutcome {
        let deadline = Date().addingTimeInterval(3.0)
        var quietRepeats = 0
        // Same hazard as `stableState`: a record-armed strip's blinking LED is
        // MIDI traffic that never touches the LCD, so "quiet" can never arrive.
        // An unchanged top row held for a second is the second proof.
        var unchangedSince: Date?
        var lastSeenTop: String?
        while Date() < deadline {
            guard let status = freshStatus(), let top = status["lcd_top"] as? String else {
                return .surfaceUnreadable
            }
            let events = status["received_events"] as? Int ?? -1
            if top == lastSeenTop {
                if unchangedSince == nil { unchangedSince = Date() }
            } else {
                unchangedSince = nil
            }
            lastSeenTop = top
            // ">= 4 dash fields" = the display is being cleared; "parameter:"
            // = a single-channel view label (or a half-repainted hybrid of
            // one) - neither is ever part of the multi-channel names row.
            let transient = lcdFields(top).filter { $0 == MCULCDStrings.clearingCell }.count >= 4
                || top.contains(MCULCDStrings.parameterBannerMarker)
            if !transient {
                let heldASecond = unchangedSince.map { Date().timeIntervalSince($0) >= 1.0 } ?? false
                if previous == nil || top != previous {
                    // stable = 120 ms without new MIDI from Logic, or a row
                    // that has not moved for a second while Logic keeps
                    // blinking a record LED at us.
                    if heldASecond { return .settled(top) }
                    if let after = awaitEvents(since: events, timeoutMs: 120),
                       after["timed_out"] as? Bool == true {
                        return .settled(top)
                    }
                    continue
                }
                // Same as previous: silence means the display will not change
                // (e.g. rightmost bank reached). Normally two rounds; one when
                // the press produced no event at all — see
                // `quietRoundsRequired`.
                guard let previous else { continue }
                if heldASecond { return .unchanged(previous) }
                if let after = awaitEvents(since: events, timeoutMs: 200),
                   after["timed_out"] as? Bool == true {
                    quietRepeats += 1
                    let needed = quietRoundsRequired(
                        eventsBeforePress: eventsBeforePress, eventsNow: events
                    )
                    if quietRepeats >= needed { return .unchanged(previous) }
                }
                continue
            }
            _ = awaitEvents(since: events, timeoutMs: 250)
        }
        return .neverSettled
    }

}
