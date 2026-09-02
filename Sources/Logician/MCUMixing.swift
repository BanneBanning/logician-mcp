import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {
    // MARK: Mute / solo

    /// What one strip LED, watched across a window, says about the control it
    /// belongs to.
    enum ToggleReading: Equatable {
        /// The control is in this state. `ledBlinking` records that the answer
        /// came from a FLASHING LED rather than a steady one — which is a fact
        /// worth reporting, not a doubt: it is what a standing solo looks like.
        case state(Bool, ledBlinking: Bool)
        /// The window caught no sample at all: the mirror never answered.
        /// NEVER the same answer as `.state(false)`.
        case unreadable
        /// The LED was flashing where nothing has been measured to flash.
        case unexplainedBlink
    }

    /// The write-side evidence rule — one line per control, pure so it can be
    /// tested without a surface (`ToggleLEDEvidenceTests`).
    ///
    /// The two controls read the SAME kind of evidence with different rules,
    /// which is why this is a function of the control and not of the LED alone:
    ///
    /// - **mute**: only a STEADY LED is a mute. Logic flashes the mute LED of
    ///   every channel a standing solo silences (proven live 2026-09-02: `Bas`
    ///   soloed, nothing muted anywhere, and six strips read lit in a single
    ///   instant), so a blinking mute LED means "silent right now, NOT muted".
    ///   That is the same asymmetry `decodeBankLEDs` reads the census with, and
    ///   reading one instant of it here is how `enabled: false` on an unmuted
    ///   track could conclude "it is muted", press mute, and MUTE the track
    ///   while reporting success — while `enabled: true` could read the lit
    ///   phase as an existing mute and return a verified no-op having done
    ///   nothing. Both directions were silent wrongness on a tool that changes
    ///   what the song sounds like.
    /// - **solo**: a STEADY LED, and a flashing one is not answered at all.
    ///   The solo LED has been steady in every state measured: 15 consecutive
    ///   reads of a standing solo (2026-09-02), and 59 samples across 3 981 ms
    ///   of `Bas` soloed with ZERO edges on its solo LED (note 0x09) and zero
    ///   on the rude-solo LED, while the mute LEDs of two silenced strips
    ///   toggled six times each in the same sampling. So a flashing solo LED is
    ///   a surface state whose meaning this server has not established — and a
    ///   write refuses on it rather than pressing on a coin flip.
    static func toggleReading(
        control: BridgeCommandName, verdict: LEDSteadiness
    ) -> ToggleReading {
        switch verdict {
        case .steady(let lit): return .state(lit, ledBlinking: false)
        case .unsampled: return .unreadable
        case .blinking:
            return control == .mute ? .state(false, ledBlinking: true) : .unexplainedBlink
        }
    }

    /// The whole write-side branch as one value: what the window said, what
    /// the caller asked for, and therefore whether anything gets pressed.
    enum ToggleDecision: Equatable {
        /// The control is already the way the caller asked for it. Nothing is
        /// pressed. `ledBlinking` says the answer came from a flashing mute
        /// LED — the case that used to press mute on an unmuted track.
        case alreadySet(ledBlinking: Bool)
        /// It is in the other state, so the button is pressed. `currentlyOn`
        /// is what it was, for the compare-and-set message.
        case press(currentlyOn: Bool, ledBlinking: Bool)
        /// The window caught nothing; this route must not answer at all.
        case unreadable
        /// A flash where nothing is known to flash: refuse, press nothing.
        case unexplainedBlink
    }

    /// `toggleReading` against the caller's request. Pure, and the ONLY place
    /// that decides whether a mute or solo button gets pressed.
    static func toggleDecision(
        control: BridgeCommandName, verdict: LEDSteadiness, requested: Bool
    ) -> ToggleDecision {
        switch toggleReading(control: control, verdict: verdict) {
        case .unreadable: return .unreadable
        case .unexplainedBlink: return .unexplainedBlink
        case .state(let current, let blinking):
            return current == requested
                ? .alreadySet(ledBlinking: blinking)
                : .press(currentlyOn: current, ledBlinking: blinking)
        }
    }

    /// How long ONE strip LED has to be watched before a write may believe it.
    ///
    /// Only the mute LED blinks, and only while a solo stands somewhere in the
    /// project — so only that combination pays the full `recBlinkWindow`.
    /// Everything else pays `settledLEDWindow` (0.3 s), which is not a blink
    /// test but a settle: it still catches the late LED repaint after the bank
    /// step `findChannel` just made, which the old single instant did not.
    ///
    /// The same 1.6 s the census pays per bank, and deliberately not a cheaper
    /// number of this route's own: the mute blink's phase measures ~733 ms
    /// (2026-09-02, `recBlinkWindow`), so two edges are only guaranteed past
    /// 1 482 ms and there is nothing left to shave. What IS shaved is the
    /// blinking case, which `ledSteadinessOnSurface` returns on the second
    /// edge rather than at the end of the window.
    ///
    /// `soloStanding` nil — the surface could not be asked — takes the long
    /// window, because the conservative side of that question is the one that
    /// stays correct.
    static func toggleLEDWindow(
        control: BridgeCommandName, soloStanding: Bool?
    ) -> TimeInterval {
        guard control == .mute else { return settledLEDWindow }
        return soloStanding == false ? settledLEDWindow : recBlinkWindow
    }

    static func setToggle(
        trackName: String,
        control: String, // "mute" | "solo"
        enabled: Bool,
        expectedCurrent: Bool? = nil
    ) throws -> [String: Any]? {
        // Resolve the string to a real command name ONCE, up front: the two
        // branches below (LED base and the bridge command) then cannot drift
        // apart, and an unexpected value fails here instead of quietly
        // driving the other control.
        guard let strip = BridgeCommandName(rawValue: control), strip == .mute || strip == .solo
        else {
            throw LogicianError.invalidArguments("control must be mute or solo")
        }
        // `requireSurface` wakes a surface Logic has simply not talked to yet,
        // and a surface that stays unreachable is NOT an error on this path:
        // mute and solo have a real inspector-strip route, so nil hands the
        // write to it instead of refusing.
        guard (try? requireSurface("the \(control) LED for '\(trackName)'")) != nil else {
            return nil
        }
        guard let channel = try findChannel(trackName: trackName) else { return nil }
        let note = (strip == .mute ? muteLEDBase : soloLEDBase) + channel
        // Note 0x73 answers "is anything soloed" for the WHOLE project in one
        // steady read — a soloed channel with no strip on this surface
        // included — and it is what decides whether the mute LED can be
        // flashing at all. Only mute needs to ask.
        let soloStanding = strip == .mute ? anySoloedStripOnSurface() : nil
        let window = toggleLEDWindow(control: strip, soloStanding: soloStanding)
        let before = ledSteadinessOnSurface(note, window: window)
        let evidence = window >= recBlinkWindow ? "blink_window" : "settled_window"
        let decision = toggleDecision(
            control: strip, verdict: before.verdict, requested: enabled
        )
        let current: Bool
        let currentFromBlink: Bool
        switch decision {
        case .unreadable:
            // The mirror answered nothing across the whole window. Inventing
            // `false` here is exactly how an unmuted track gets muted, so the
            // write goes to the inspector-strip route instead.
            debugLog("setToggle: \(control) LED unreadable across \(window) s")
            return nil
        case .unexplainedBlink:
            throw LogicianError.preconditionUnmet(
                "The \(control) LED of '\(trackName)' (strip \(channel + 1)) was FLASHING:"
                    + " \(before.samples) samples across \(Int(before.elapsed * 1000)) ms with at"
                    + " least two edges. Nothing on this surface has been measured to flash a solo"
                    + " LED, so its state cannot be read and NOTHING was pressed. Read"
                    + " logic_mixer_snapshot to see what the surface is showing."
            )
        case .alreadySet(let blinking):
            current = enabled
            currentFromBlink = blinking
        case .press(let currentlyOn, let blinking):
            current = currentlyOn
            currentFromBlink = blinking
        }
        // Compare-and-set, off the state this route was already reading to
        // decide whether the button needs pressing at all.
        if let expectedCurrent, current != expectedCurrent {
            throw LogicianError.currentValueMismatch(
                expected: "\(control)=\(expectedCurrent)",
                actual: "\(control)=\(current)"
                    + (currentFromBlink
                        ? " (the mute LED is BLINKING, which is a standing solo silencing this"
                            + " channel, not a mute)"
                        : "")
            )
        }
        if case .alreadySet = decision {
            return toggleResult(
                trackName: trackName, control: control, strip: strip, enabled: enabled,
                channel: channel, state: "already_" + (enabled ? "on" : "off"),
                evidence: evidence, samples: before.samples, soloStanding: soloStanding,
                ledBlinking: currentFromBlink, pressed: false
            )
        }
        let events = freshStatus()?["received_events"] as? Int ?? -1
        let response = try MCUBridge.send(.channel(strip, channel))
        guard response.ok else {
            throw LogicianError.writeFailed("MCU \(control) failed: \(response.error ?? "?")")
        }
        // Let the LED repaint ARRIVE before the readback window opens. A window
        // that straddles the press catches the old blink's edges and the new
        // state together, counts two edges, and spends a second whole window
        // finding out what it already knew.
        _ = awaitEvents(since: events, timeoutMs: 800)
        // The readback re-runs the same window rule, and it has to: under a
        // standing solo the press lands in a bank of flashing mute LEDs, where
        // one instant confirms whichever phase it happened to catch. Unmuting a
        // genuinely muted track under a solo ends with the LED BLINKING rather
        // than dark — the solo silences it the moment the mute lets go — and
        // that is the correct reading of `mute: false`, not a failure.
        var after: (verdict: LEDSteadiness, samples: Int, elapsed: TimeInterval)?
        for _ in 0..<3 {
            let read = ledSteadinessOnSurface(note, window: window)
            if case .state(let value, _) = toggleReading(control: strip, verdict: read.verdict),
               value == enabled {
                after = read
                break
            }
        }
        guard let after else {
            throw LogicianError.verificationFailed(
                requested: "\(control)=\(enabled) on '\(trackName)' (strip \(channel + 1))",
                actual: "the MCU \(control) LED never settled at that state across three"
                    + " \(Int(window * 1000)) ms windows after the press",
                restored: false
            )
        }
        var landedBlinking = false
        if case .state(_, let blinking) = toggleReading(control: strip, verdict: after.verdict) {
            landedBlinking = blinking
        }
        return toggleResult(
            trackName: trackName, control: control, strip: strip, enabled: enabled,
            channel: channel, state: enabled ? "on" : "off",
            evidence: evidence, samples: after.samples, soloStanding: soloStanding,
            ledBlinking: landedBlinking, pressed: true
        )
    }

    /// The mute/solo result, with the LED evidence it was decided on.
    ///
    /// `led_evidence` and `mute_led_blinking` are the census's own key names
    /// (`logic_mixer_snapshot`), so an agent that reads the mixer and then
    /// writes a mute meets one vocabulary rather than two.
    private static func toggleResult(
        trackName: String,
        control: String,
        strip: BridgeCommandName,
        enabled: Bool,
        channel: Int,
        state: String,
        evidence: String,
        samples: Int,
        soloStanding: Bool?,
        ledBlinking: Bool,
        pressed: Bool
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "success": true, "verified": true,
            "state": state,
            "track": trackName, "track_name": trackName,
            "control": control, control: enabled,
            "mcu_strip": channel + 1,
            "route": "mcu",
            "readback_route": "mcu_channel_led_window",
            "led_evidence": evidence,
            "led_samples": samples
        ]
        if pressed { payload["write_route"] = "mcu_channel_button" }
        if strip == .mute, let soloStanding { payload["any_soloed"] = soloStanding }
        guard ledBlinking else { return payload }
        payload["mute_led_blinking"] = true
        payload["mute_blink_note"] = pressed
            ? "The mute LED of '\(trackName)' is BLINKING after the write, and that is the correct"
                + " reading of mute: false — Logic flashes the mute LED of every channel a standing"
                + " solo silences (any_soloed is true), so this channel is no longer muted but is"
                + " still SILENT until the solo goes."
            : "NOTHING was pressed. The mute LED of '\(trackName)' is BLINKING, which is not a mute:"
                + " Logic flashes the mute LED of every channel a standing solo silences (any_soloed"
                + " is true), so this channel is silent right now but NOT muted — pressing mute"
                + " would have muted it. Unsolo to hear it, or read logic_mixer_snapshot for the"
                + " whole picture."
        return payload
    }

    // MARK: Volume (vpot converge against the LCD dB readout)

    static func parseDb(_ text: String) -> Double? {
        // LCD cells are 7 characters; the "dB" suffix may be cut mid-way
        // ("-10,0 d"), so keep only the leading numeric run.
        let normalized = text
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        if normalized.hasPrefix(MCULCDStrings.minusInfinity) {
            return MCULCDStrings.minusInfinityDb
        }
        let numeric = normalized.prefix { "+-0123456789.".contains($0) }
        return Double(numeric)
    }

    /// The volume result, with ONE verdict rule for both write paths:
    /// `verified` is true when the fader is within the tolerance the CALLER
    /// asked for, and false otherwise.
    ///
    /// It used to be `abs(landed - target) <= max(tolerance, 0.6)` on the
    /// control-surface fast path, which meant a default call (tolerance
    /// 0.15 dB) could land 0.6 dB out — four times what it asked for, an
    /// audible move on a busy mix — and be told it was verified. A `verified`
    /// that quietly widens the caller's own tolerance is worse than an
    /// unverified result: an unverified result gets read back, and this one
    /// did not. The floor is gone.
    ///
    /// Outside the tolerance the result says so, says by how much, and stays
    /// `success: true` — the fader DID move, and `after_db` is Logic's own
    /// readout of where it is, not an estimate. Pure and static so the rule
    /// can be tested without a fader (`ChannelStripTests`).
    static func volumeVerdict(
        trackName: String,
        startDb: Double,
        targetDb: Double,
        landedDb: Double,
        toleranceDb: Double,
        writeRoute: String
    ) -> [String: Any] {
        let deviation = abs(landedDb - targetDb)
        // 1e-9, and it is not a floor sneaking back in: Logic prints dB to one
        // decimal and tolerances arrive as decimals, so a landing exactly ON
        // the tolerance (|-6.15 - -6.0| = 0.15000000000000036) would fail a
        // bare `<=` for no reason a caller could see or fix.
        let inside = deviation <= toleranceDb + 1e-9
        var payload: [String: Any] = [
            "success": true,
            "verified": inside,
            "state": "volume_set",
            // The fast path used to omit the track entirely, so a result could
            // not say WHICH track it moved - the slow path always named it.
            // Both report it the same way now.
            "track": trackName, "track_name": trackName,
            "before_db": round(startDb * 10) / 10,
            "after_db": round(landedDb * 10) / 10,
            "requested_db": targetDb,
            "deviation_db": round(deviation * 100) / 100,
            "tolerance_db": toleranceDb,
            "route": "mcu",
            "write_route": writeRoute,
            "readback_route": "mcu_lcd_db"
        ]
        if !inside {
            payload["verification_note"] = String(
                format: "The fader landed at %.1f dB, %.2f dB from the %.1f dB requested —"
                    + " outside the %.2f dB tolerance, so verified is false."
                    + " after_db is Logic's own dB readout, not an estimate;"
                    + " raise tolerance_db if that is close enough, or write again.",
                landedDb, deviation, targetDb, toleranceDb
            )
        }
        return payload
    }

    static func setVolume(
        trackName: String,
        request: VolumeWrite,
        toleranceDb: Double
    ) throws -> [String: Any]? {
        guard freshStatus() != nil else { debugLog("setVolume: no bridge status"); return nil }
        guard let channel = try findChannel(trackName: trackName) else {
            debugLog("setVolume: findChannel nil for '\(trackName)'")
            return nil
        }
        // Enter the multi-channel volume view. The assignment 7-segment code
        // is NOT a reliable indicator (submodes show other codes while the
        // view is functionally right, and the button TOGGLES submodes on
        // repeated presses) - the LCD label is the functional truth.
        func volumeViewShowing() -> Bool {
            guard let status = freshStatus(), let top = status["lcd_top"] as? String else { return false }
            return top.contains(MCULCDStrings.channelStripVolumeBanner)
        }
        var csReady = volumeViewShowing()
        for _ in 0..<3 where !csReady {
            try press("assign_track")
            csReady = waitFor(seconds: 1.2, { status in
                (status["lcd_top"] as? String)?
                    .contains(MCULCDStrings.channelStripVolumeBanner) == true
            }) != nil
        }
        guard csReady else {
            debugLog("setVolume: volume view not reached (top: \(freshStatus()?["lcd_top"] as? String ?? "?"))")
            _ = try? ensurePanNames()
            return nil
        }
        debugLog("setVolume: channel \(channel), volume view ok")
        defer { _ = try? ensurePanNames() }

        func currentDb() -> Double? {
            guard let status = freshStatus(), let bottom = status["lcd_bottom"] as? String else {
                return nil
            }
            return parseDb(lcdValueFields(bottom)[channel])
        }
        guard let startDb = currentDb() else { debugLog("setVolume: no dB readback for channel \(channel)"); return nil }
        // The compare-and-set check and the relative_db arithmetic both need
        // the value the fader is sitting at, which this route has just read.
        // Throwing here is deliberate: a precondition mismatch must NOT fall
        // through to the Accessibility route and be written there instead.
        let targetDb = try request.target(currentDb: startDb)

        /// The vpot correction loop, shared by both write paths.
        ///
        /// `stopWhenStuck` is the difference between them. On the slow path a
        /// fader that will not move is a verification FAILURE and throws — the
        /// write never landed. On a refinement pass it is not: the bridge
        /// already put the fader within reach of the target, and a stalled
        /// last tenth of a dB is a result to report honestly, not an error to
        /// throw over a write that mostly worked.
        func correct(from origin: Double, stopWhenStuck: Bool) throws -> Double {
            var db = origin
            var ticksPerDb = 2.5
            var stuck = 0
            for _ in 0..<30 {
                let difference = targetDb - db
                if abs(difference) <= toleranceDb { break }
                let ticks = max(1, min(60, Int((abs(difference) * ticksPerDb).rounded())))
                let before = freshStatus()?["received_events"] as? Int ?? -1
                let response = try MCUBridge.send(
                    .vpot(index: channel, delta: difference > 0 ? ticks : -ticks)
                )
                guard response.ok else {
                    throw LogicianError.writeFailed("MCU vpot failed: \(response.error ?? "?")")
                }
                _ = awaitEvents(since: before, timeoutMs: 300)
                guard let updated = currentDb() else { break }
                if abs(updated - db) < 0.01 {
                    stuck += 1
                    if stuck >= 3 {
                        guard stopWhenStuck else { return updated }
                        throw LogicianError.verificationFailed(
                            requested: String(format: "%.1f dB", targetDb),
                            actual: String(format: "volume stuck at %.1f dB", updated),
                            restored: false
                        )
                    }
                } else {
                    stuck = 0
                    ticksPerDb = min(30, max(0.5, Double(ticks) / abs(updated - db)))
                }
                db = updated
            }
            return db
        }

        func verdict(landedAt db: Double, writeRoute: String) -> [String: Any] {
            volumeVerdict(
                trackName: trackName, startDb: startDb, targetDb: targetDb,
                landedDb: db, toleranceDb: toleranceDb, writeRoute: writeRoute
            )
        }

        if let fast = fastConverge(index: channel, target: targetDb,
                                   tolerance: toleranceDb, maxMs: 3000, seedRatio: 2.5) {
            let landed = currentDb() ?? fast.value
            // The same epsilon `volumeVerdict` uses, so a landing it would
            // call verified never triggers a pointless refinement pass.
            guard abs(landed - targetDb) > toleranceDb + 1e-9 else {
                return verdict(landedAt: landed, writeRoute: "bridge_converge")
            }
            // Outside what the caller asked for: try again with the vpot loop
            // before reporting. Re-converging is the answer the caller wanted;
            // an honest `verified: false` is the answer they get if it cannot.
            let refined = try correct(from: landed, stopWhenStuck: false)
            return verdict(landedAt: refined, writeRoute: "bridge_converge+vpot_refine")
        }

        let db = try correct(from: startDb, stopWhenStuck: true)
        // The failure gate, unchanged: past this much the write did not land
        // at all and must not come back as a success of any kind.
        guard abs(db - targetDb) <= max(toleranceDb, 0.25) else {
            throw LogicianError.verificationFailed(
                requested: String(format: "%.1f dB", targetDb),
                actual: String(format: "%.1f dB", db),
                restored: false
            )
        }
        return verdict(landedAt: db, writeRoute: "mcu_vpot_converge")
    }
}

extension MCUController {
    /// Presses assign_plugin until the selected track's insert list ("Ins1Pl…")
    /// is showing. The button cycles PL <-> per-insert bank views, so content
    /// must be verified, never press-counted.
    static func ensurePluginList() throws -> [String: Any]? {
        for _ in 0..<5 {
            guard let status = freshStatus(), let top = status["lcd_top"] as? String else { return nil }
            if top.hasPrefix(MCULCDStrings.insertListFirstSlotLabel) { return status }
            let before = status["received_events"] as? Int ?? -1
            try press("assign_plugin")
            _ = awaitEvents(since: before, timeoutMs: 350)
            _ = quiescentStatus() // let the redraw finish before re-checking
        }
        return nil
    }

    /// Returns the surface to the neutral Pan-names view and forgets every
    /// view this server was keeping. Unchanged in what it does; it is now also
    /// the one place a deferred restore is paid, so the debt is cleared here
    /// even if `ensurePanNames` fails — a failed restore is not a debt anyone
    /// can settle by trying again from the same call, and `ensurePanNames`
    /// itself clears the record on success.
    static func exitToPan() {
        forgetSurfaceViews()
        _ = try? ensurePanNames()
    }

    /// Drops every view this server was keeping a note of. Separate from
    /// `exitToPan` only so the rule can be asserted without a surface: a debt
    /// that survived a restore would make the next tool skip a restore it needs.
    static func forgetSurfaceViews() {
        hotEditView = nil
        surfaceDebt = nil
    }

}
