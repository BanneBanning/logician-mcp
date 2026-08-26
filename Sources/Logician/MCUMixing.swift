import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {
    // MARK: Mute / solo

    static func setToggle(
        trackName: String,
        control: String, // "mute" | "solo"
        enabled: Bool
    ) throws -> [String: Any]? {
        guard freshStatus() != nil else { return nil }
        guard let channel = try findChannel(trackName: trackName) else { return nil }
        let ledBase = control == "mute" ? 0x10 : 0x08
        let note = ledBase + channel
        guard let before = freshStatus() else { return nil }
        if ledLit(note, in: before) == enabled {
            return [
                "success": true, "verified": true,
                "state": "already_" + (enabled ? "on" : "off"),
                "track": trackName, "control": control, control: enabled, "route": "mcu"
            ]
        }
        let response = try MCUBridge.send(["cmd": control, "channel": channel])
        guard response["ok"] as? Bool == true else {
            throw DemoError.writeFailed("MCU \(control) failed: \(response["error"] ?? "?")")
        }
        guard pollStatus(until: { ledLit(note, in: $0) == enabled }) != nil else {
            throw DemoError.verificationFailed(
                requested: "\(control)=\(enabled)",
                actual: "MCU \(control) LED did not change",
                restored: false
            )
        }
        return [
            "success": true, "verified": true,
            "state": enabled ? "on" : "off",
            "track": trackName, "control": control, control: enabled,
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

    static func setVolume(
        trackName: String,
        targetDb: Double,
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
            return parseDb(lcdFields(bottom)[channel])
        }
        guard let startDb = currentDb() else { debugLog("setVolume: no dB readback for channel \(channel)"); return nil }
        if let fast = fastConverge(index: channel, target: targetDb,
                                   tolerance: toleranceDb, maxMs: 3000, seedRatio: 2.5) {
            _ = fast
            let landed = currentDb() ?? fast.value
            return [
                "success": true, "verified": abs(landed - targetDb) <= max(toleranceDb, 0.6),
                "state": "volume_set", "requested_db": targetDb, "db": landed,
                "route": "mcu", "write_route": "bridge_converge"
            ]
        }
        var db = startDb
        var ticksPerDb = 2.5
        var stuck = 0
        for _ in 0..<30 {
            let difference = targetDb - db
            if abs(difference) <= toleranceDb { break }
            let ticks = max(1, min(60, Int((abs(difference) * ticksPerDb).rounded())))
            let before = freshStatus()?["received_events"] as? Int ?? -1
            let response = try MCUBridge.send([
                "cmd": "vpot", "index": channel, "delta": difference > 0 ? ticks : -ticks
            ])
            guard response["ok"] as? Bool == true else {
                throw DemoError.writeFailed("MCU vpot failed: \(response["error"] ?? "?")")
            }
            _ = awaitEvents(since: before, timeoutMs: 300)
            guard let updated = currentDb() else { break }
            if abs(updated - db) < 0.01 {
                stuck += 1
                if stuck >= 3 {
                    throw DemoError.verificationFailed(
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
        guard abs(db - targetDb) <= max(toleranceDb, 0.25) else {
            throw DemoError.verificationFailed(
                requested: String(format: "%.1f dB", targetDb),
                actual: String(format: "%.1f dB", db),
                restored: false
            )
        }
        return [
            "success": true, "verified": true, "state": "volume_set",
            "track": trackName,
            "before_db": round(startDb * 10) / 10,
            "after_db": round(db * 10) / 10,
            "requested_db": targetDb,
            "route": "mcu",
            "write_route": "mcu_vpot_converge",
            "readback_route": "mcu_lcd_db"
        ]
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
