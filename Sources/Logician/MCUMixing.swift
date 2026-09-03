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
        // Logic answers a per-strip press by painting the control's own name
        // over that strip's LCD NAME cell (`Fill` → `Mute`) for about two
        // seconds. Recording it here is what lets the NEXT resolution of this
        // same track know the odd-looking cell is its own echo rather than a
        // stale bank map, and skip a 1.6-1.7 s re-navigation of the bank the
        // surface is already standing on (`bankedAtMatch`, FS-1). Both of
        // these words fit inside one 7-character cell, which is what makes
        // record-arm's `Record Enable` the odd one out.
        noteControlPressBanner(
            track: trackName, channel: channel,
            banner: strip == .mute ? MCULCDStrings.muteBanner : MCULCDStrings.soloBanner
        )
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
    ///
    /// `writeRoute` is nil for the verified no-op: nothing was turned, so
    /// there is no route to name, and an absent key says that better than a
    /// route called "none" would (the same shape `setToggle`'s already-set
    /// payload uses).
    static func volumeVerdict(
        trackName: String,
        startDb: Double,
        targetDb: Double,
        landedDb: Double,
        toleranceDb: Double,
        writeRoute: String?,
        state: String = "volume_set"
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
            "state": state,
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
            "readback_route": "mcu_lcd_db"
        ]
        if let writeRoute { payload["write_route"] = writeRoute }
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
        // repeated presses) - the LCD label is the functional truth. Shared
        // with `logic_mixer_snapshot`, which reads the same view.
        guard try ensureVolumeView() else {
            debugLog("setVolume: volume view not reached (top: \(freshStatus()?["lcd_top"] as? String ?? "?"))")
            exitToPan()
            return nil
        }
        debugLog("setVolume: channel \(channel), volume view ok")
        // PATTERN #1, the debt. This call used to press back to the Pan-names
        // view in its own `defer`, on every path. It is the same walk home the
        // sends, the plug-in views and `logic_mixer_snapshot` already stopped
        // paying: the view is HANDED OVER instead, `ensurePanNames` settles the
        // debt inside whichever later call needs the names row, and
        // `MCPServer.shutdown()` pays it if nothing else does — so the surface
        // is never LEFT in the Volume view, only handed over in it.
        //
        // WHAT IT IS AND IS NOT WORTH, measured live 2026-09-03, nine
        // consecutive writes on one strip, old binary then new. The restore is
        // one press of assign_pan and then ~2 s of Logic's own mode banner
        // before `ensurePanNames` can confirm the names row, and deferring does
        // not delete that — it MOVES it, because the next volume write's own
        // `findChannel` needs the names row to read them. So a chain of writes
        // is a wash (2 293 ms mean before, 2 412 ms after) with the VARIANCE
        // gone: the worst call fell from 4 483 to 2 481 ms and the mode-banner
        // outliers the profile saw on 4 of 9 calls did not recur. What the
        // deferral genuinely buys is the call that is NOT followed by another
        // surface write — the verified no-op below went 2 965 → 713 ms, and
        // the last write of any chain hands its restore to whoever comes next
        // instead of charging the caller for it.
        //
        // Every refusal and every throw still restores explicitly: a refusal
        // has no result for the debt to travel with.
        var handedOver = false
        defer { if !handedOver { exitToPan() } }
        func handOver(_ payload: [String: Any]) -> [String: Any] {
            handedOver = true
            deferSurfaceRestore(SurfaceDebt(strip: nil, view: "channel_strip", slot: nil))
            var carried = payload
            carried["surface_view"] = "channel_strip"
            return carried
        }

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

        func verdict(
            landedAt db: Double, writeRoute: String?, state: String = "volume_set"
        ) -> [String: Any] {
            volumeVerdict(
                trackName: trackName, startDb: startDb, targetDb: targetDb,
                landedDb: db, toleranceDb: toleranceDb, writeRoute: writeRoute, state: state
            )
        }

        // The verified no-op, which this tool did not have: `relative_db: 0`,
        // or a `db` the fader is already sitting at, used to turn the vpot
        // anyway and cost the same as a real move (339 ms against 368 ms,
        // measured 2026-09-03). It cannot skip as much as mute/solo's
        // `already_set` does — the dB readout only exists inside the Volume
        // view, so the view still has to be entered to learn the answer — but
        // it skips `fastConverge` (90–125 ms) and, more to the point, it turns
        // NOTHING on a call that means nothing. Same epsilon as `volumeVerdict`
        // so a landing the verdict would call verified is never converged at.
        if abs(startDb - targetDb) <= toleranceDb + 1e-9 {
            debugLog("setVolume: already at target (\(startDb) dB), nothing turned")
            return handOver(verdict(landedAt: startDb, writeRoute: nil, state: "already_set"))
        }

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

        if let fast = fastConverge(index: channel, target: targetDb,
                                   tolerance: toleranceDb, maxMs: 3000, seedRatio: 2.5) {
            let landed = currentDb() ?? fast.value
            // The same epsilon `volumeVerdict` uses, so a landing it would
            // call verified never triggers a pointless refinement pass.
            guard abs(landed - targetDb) > toleranceDb + 1e-9 else {
                return handOver(verdict(landedAt: landed, writeRoute: "bridge_converge"))
            }
            // Outside what the caller asked for: try again with the vpot loop
            // before reporting. Re-converging is the answer the caller wanted;
            // an honest `verified: false` is the answer they get if it cannot.
            let refined = try correct(from: landed, stopWhenStuck: false)
            return handOver(verdict(landedAt: refined, writeRoute: "bridge_converge+vpot_refine"))
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
        return handOver(verdict(landedAt: db, writeRoute: "mcu_vpot_converge"))
    }
}

extension MCUController {

    /// What the surface is showing when a plug-in tool looks at it. The four
    /// states are measured, not guessed (live, 2026-09-02):
    ///
    /// - `.insertList` — the eight slot labels across the top row
    ///   (`Ins1Pl Ins2Pl …`) and the slot CONTENTS underneath. The only state
    ///   `pluginInsertNames` may read.
    /// - `.browseStanding` — assignment still `PL`, but the top row reads
    ///   `Insert N Plug-in` spanning three cells and the bottom row shows a
    ///   CATALOG ENTRY rather than the slot's content. An abandoned browse
    ///   leaves exactly this, and reading the row here would report a catalog
    ///   entry as an installed plug-in.
    /// - `.perInsertBank` — `P1`…`P8`, the per-insert parameter bank. **Its
    ///   top row is the PAN NAMES row**, byte-identical to the neutral view's,
    ///   so the assignment code is the only thing that tells them apart —
    ///   which is why this classifier reads both.
    /// - `.elsewhere` — anything else, `PN` included.
    ///
    /// Pure so all four can be pinned by a test rather than by a surface.
    enum PluginListView: Equatable {
        case insertList
        case browseStanding
        case perInsertBank
        case elsewhere
    }

    static func pluginListView(assignment: String?, lcdTop: String?) -> PluginListView {
        if lcdTop?.hasPrefix(MCULCDStrings.insertListFirstSlotLabel) == true { return .insertList }
        guard let assignment, isPluginEditAssignment(assignment) else { return .elsewhere }
        return assignment == MCULCDStrings.Assignment.pluginList ? .browseStanding : .perInsertBank
    }

    static func pluginListView(status: [String: Any]) -> PluginListView {
        pluginListView(
            assignment: status["assignment"] as? String,
            lcdTop: status["lcd_top"] as? String
        )
    }

    /// Why the last `ensurePluginList` could not put the insert list on screen.
    /// Read by the tools whose refusal used to blame the bridge for it.
    nonisolated(unsafe) static var lastPluginListRefusal: String? // single-threaded server loop

    /// Presses assign_plugin until the selected track's insert list is
    /// showing, PACED ON THE PRESS LANDING rather than on a fixed settle.
    ///
    /// MEASURED 2026-09-02, and it is why this loop used to give up with the
    /// view one press away: **`assign_plugin` ALTERNATES `P1` ↔ `PL`**, and the
    /// `P1` half paints the pan-names top row, so the row test alone cannot
    /// see which half it is in. The old shape waited for ONE event
    /// (`awaitEvents(since:, 350)` returns on the first byte of a repaint) and
    /// then discarded a `quiescentStatus`, so a press could be read before its
    /// repaint had landed, the next press went into that unfinished repaint —
    /// which Logic swallows — and five presses later the loop returned nil with
    /// the surface parked on `P1`. Live: `logic_add_plugin` on `Sweeps` then
    /// refused three times out of three in under a second with *"the MCU bridge
    /// is unavailable"* while the bridge was up, the strip resolved and the
    /// insert list arriving on screen a moment after the refusal was written.
    ///
    /// So each press is now proved by Logic's own answer — the assignment code
    /// CHANGING (~100 ms) or the insert row appearing — before the loop looks
    /// again, and a loop that still cannot get there says what it saw and hands
    /// the surface back to the neutral view instead of leaving a `P…` bank
    /// standing (a plug-in view left standing makes the next track selection
    /// auto-open that plug-in's window — see `settleSurfaceDebt`).
    static func ensurePluginList() throws -> [String: Any]? {
        lastPluginListRefusal = nil
        var lastSeen: PluginListView?
        for _ in 0..<5 {
            guard let status = freshStatus() else {
                lastPluginListRefusal = "the control surface's status could not be read at all"
                return nil
            }
            let view = pluginListView(status: status)
            lastSeen = view
            if view == .insertList { return status }
            let before = (status["assignment"] as? String) ?? ""
            try press("assign_plugin")
            if let landed = waitFor(seconds: 1.0, { later in
                pluginListView(status: later) == .insertList
                    || (later["assignment"] as? String) ?? "" != before
            }), pluginListView(status: landed) == .insertList {
                return landed
            }
        }
        lastPluginListRefusal = "five presses of the surface's PLUG-IN button did not bring the"
            + " insert list up; the last thing it showed was "
            + (lastSeen.map(pluginListViewDescription) ?? "nothing readable")
            + ". The surface has been returned to the Pan view, so this is safe to retry"
        exitToPan()
        return nil
    }

    static func pluginListViewDescription(_ view: PluginListView) -> String {
        switch view {
        case .insertList: return "the insert list"
        case .browseStanding:
            return "a plug-in BROWSE standing on one slot (an abandoned browse from an"
                + " earlier call, or another session's; it writes nothing and is cancelled"
                + " by leaving the view)"
        case .perInsertBank: return "a plug-in edit view (the per-insert bank P1-P8, or IN)"
        case .elsewhere: return "another view altogether"
        }
    }

    /// Returns the surface to the neutral Pan-names view and forgets every
    /// view this server was keeping. Unchanged in what it does; it is now also
    /// the one place a deferred restore is paid, so the debt is cleared here
    /// even if `ensurePanNames` fails — a failed restore is not a debt anyone
    /// can settle by trying again from the same call, and `ensurePanNames`
    /// itself clears the record on success.
    static func exitToPan() {
        forgetSurfaceViews()
        // `ensurePanNames` VERIFIES the half of the pan toggle it landed on
        // (`panRowState`), so its answer is a fact about the surface, not a
        // hope — and a restore that could not land is worth saying out loud
        // rather than dropping on the floor: the next tool will meet a surface
        // that is not where this one left it.
        if (try? ensurePanNames()) != true {
            debugLog("exitToPan: the pan-names view could not be confirmed; the surface is NOT in PN")
        }
    }

    /// Drops every view this server was keeping a note of. Separate from
    /// `exitToPan` only so the rule can be asserted without a surface: a debt
    /// that survived a restore would make the next tool skip a restore it needs.
    static func forgetSurfaceViews() {
        hotEditView = nil
        surfaceDebt = nil
    }

}
