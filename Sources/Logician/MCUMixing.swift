import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {
    // MARK: Mute / solo

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
        guard freshStatus() != nil else { return nil }
        guard let channel = try findChannel(trackName: trackName) else { return nil }
        let ledBase = strip == .mute ? 0x10 : 0x08
        let note = ledBase + channel
        guard let before = freshStatus() else { return nil }
        // Compare-and-set, off the state this route was already reading to
        // decide whether the button needs pressing at all.
        if let expectedCurrent, ledLit(note, in: before) != expectedCurrent {
            throw LogicianError.currentValueMismatch(
                expected: "\(control)=\(expectedCurrent)",
                actual: "\(control)=\(ledLit(note, in: before))"
            )
        }
        if ledLit(note, in: before) == enabled {
            return [
                "success": true, "verified": true,
                "state": "already_" + (enabled ? "on" : "off"),
                "track": trackName, "track_name": trackName, "control": control, control: enabled, "route": "mcu"
            ]
        }
        let response = try MCUBridge.send(.channel(strip, channel))
        guard response.ok else {
            throw LogicianError.writeFailed("MCU \(control) failed: \(response.error ?? "?")")
        }
        guard pollStatus(until: { ledLit(note, in: $0) == enabled }) != nil else {
            throw LogicianError.verificationFailed(
                requested: "\(control)=\(enabled)",
                actual: "MCU \(control) LED did not change",
                restored: false
            )
        }
        return [
            "success": true, "verified": true,
            "state": enabled ? "on" : "off",
            "track": trackName, "track_name": trackName, "control": control, control: enabled,
            "route": "mcu", "readback_route": "mcu_channel_led"
        ]
    }

    // MARK: Volume (vpot converge against the LCD dB readout)

    static func parseDb(_ text: String) -> Double? {
        // LCD cells are 7 characters; the "dB" suffix may be cut mid-way
        // ("-10,0 d"), so keep only the leading numeric run.
        let normalized = text
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        if normalized.hasPrefix("-oo") { return -70.0 } // Logic's minus infinity
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
            return top.contains("Channel Strip parameter: Volume")
        }
        var csReady = volumeViewShowing()
        for _ in 0..<3 where !csReady {
            try press("assign_track")
            csReady = waitFor(seconds: 1.2, { status in
                (status["lcd_top"] as? String)?.contains("Channel Strip parameter: Volume") == true
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
            if top.hasPrefix("Ins1Pl") { return status }
            let before = status["received_events"] as? Int ?? -1
            try press("assign_plugin")
            _ = awaitEvents(since: before, timeoutMs: 350)
            _ = quiescentStatus() // let the redraw finish before re-checking
        }
        return nil
    }

    static func exitToPan() {
        hotPluginView = nil
        _ = try? ensurePanNames()
    }

}
