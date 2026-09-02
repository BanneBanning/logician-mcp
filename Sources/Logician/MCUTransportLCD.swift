import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {
    // MARK: Transport

    static func setPlaying(_ playing: Bool) throws -> [String: Any]? {
        guard let status = freshStatus() else { return nil }
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

    static func setCycle(_ enabled: Bool) throws -> [String: Any]? {
        guard let status = freshStatus() else { return nil }
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
        for iteration in 0..<6 {
            if confirmedFullNames() {
                surfaceDebt = nil
                return true
            }
            guard let state = stableState() else { debugLog("ensurePanNames[\(iteration)]: no stable state"); return false }
            debugLog("ensurePanNames[\(iteration)]: asgn='\(state.assignment)' top='\(state.top.prefix(48))'")
            if fullNames(["lcd_top": state.top, "assignment": state.assignment]) {
                surfaceDebt = nil
                return true
            }
            if state.top.contains(MCULCDStrings.parameterBannerMarker)
                && state.assignment == MCULCDStrings.Assignment.pan {
                // Names view with Logic's mode BANNER ("Pan/Surround
                // parameter: Pan") still covering the right half - it fades
                // on its own; pressing now would toggle AWAY from the
                // correct view, so wait it out.
                debugLog("ensurePanNames[\(iteration)]: waiting out mode banner")
                if waitFor(seconds: 5.0, fullNames) != nil {
                    surfaceDebt = nil
                    return true
                }
                continue
            }
            // Any other stable state (single-channel pan, the channel-strip
            // overview, a plugin view, ...) - press toward the names view.
            try press("assign_pan")
            // Wait for the TARGET rather than for the display to go quiet.
            // This used to be a bare `awaitEvents(800)` and the next iteration
            // then paid another full second of silence proof plus, usually, a
            // separate wait for the mode banner to fade — three sequential
            // waits for one press. `fullNames` is the same predicate the
            // banner branch above already trusts from `waitFor`, and the next
            // iteration's `confirmedFullNames` still has to see the row hold
            // still for 100 ms before this returns true, so the press is
            // followed by a positive check and a stability check, not by a
            // guess. A press that goes nowhere falls through to the unchanged
            // `stableState` classification on the next iteration.
            _ = waitFor(seconds: 5.0, fullNames)
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

    static func resetToLeftmostBank() throws {
        for _ in 0..<8 {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            try press("bank_left")
            _ = awaitEvents(since: before, timeoutMs: 150)
        }
    }

    /// Is the surface ALREADY showing the bank a cached map put this channel
    /// in, given a live name row that may be carrying Logic's press banner?
    ///
    /// THE BANNER. Logic overwrites the touched strip's NAME cell with the name
    /// of the control it just saw and leaves it there: press solo on `Bas` and
    /// the row reads `LofPad Solo   808    Inst 2 …` where the bank map says
    /// `LofPad Bas    808    Inst 2 …`. It does not clear on a short timer —
    /// measured 2026-09-02 on `Testlåt Copy`, a 600 ms wait for the mapped
    /// row to come back never once succeeded, and what actually repainted the
    /// cell was the next thing to touch the surface.
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
        try resetToLeftmostBank()
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

        try resetToLeftmostBank()
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
        for _ in 0..<10 {
            if bankTops.last == top { break }
            bankTops.append(top)
            try press("bank_right")
            guard let next = try settledTop(previous: top) else {
                debugLog("no settled top in scan")
                return .unavailable(reason: "a bank's channel-name row never settled during the scan")
            }
            top = next
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

    /// Waits until the LCD top row holds stable, non-transient channel content
    /// (two consecutive identical reads that are not a "-      " banner), and
    /// differs from `previous` when given (returns previous content on timeout,
    /// which scan loops interpret as "rightmost bank reached").
    static func settledTop(previous: String? = nil) throws -> String? {
        let deadline = Date().addingTimeInterval(3.0)
        var quietRepeats = 0
        // Same hazard as `stableState`: a record-armed strip's blinking LED is
        // MIDI traffic that never touches the LCD, so "quiet" can never arrive.
        // An unchanged top row held for a second is the second proof.
        var unchangedSince: Date?
        var lastSeenTop: String?
        while Date() < deadline {
            guard let status = freshStatus(), let top = status["lcd_top"] as? String else { return nil }
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
                    if heldASecond { return top }
                    if let after = awaitEvents(since: events, timeoutMs: 120),
                       after["timed_out"] as? Bool == true {
                        return top
                    }
                    continue
                }
                // same as previous: two quiet rounds means the display will not
                // change (e.g. rightmost bank reached)
                if heldASecond { return previous }
                if let after = awaitEvents(since: events, timeoutMs: 200),
                   after["timed_out"] as? Bool == true {
                    quietRepeats += 1
                    if quietRepeats >= 2 { return previous }
                }
                continue
            }
            _ = awaitEvents(since: events, timeoutMs: 250)
        }
        return previous
    }

}
