import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {
    // MARK: Automation recording (Latch mode + timed absolute fader writes)

    /// Standard Mackie automation-mode buttons; they act on the selected track.
    static func automationModeNote(_ mode: String) -> Int? {
        switch mode.lowercased() {
        case "read": return 0x4A
        case "write": return 0x4B
        case "trim": return 0x4C
        case "touch": return 0x4D
        case "latch": return 0x4E
        default: return nil
        }
    }

    /// Sets the selected track's automation mode via the MCU button and
    /// verifies through the channel strip's mode label ("Latch, automation
    /// enabled") — surface write, Accessibility readback.
    static func setAutomationMode(
        _ mode: String, logic: LogicAccessibility, trackName: String
    ) throws {
        guard let note = automationModeNote(mode) else {
            throw LogicianError.invalidArguments("mode must be read/touch/latch/write/trim")
        }
        let response = try MCUBridge.send(.press(note: note))
        guard response.ok else {
            throw LogicianError.writeFailed("automation mode press failed")
        }
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.25)
            if let label = logic.automationModeLabel(trackName: trackName),
               label.lowercased().hasPrefix(mode.lowercased()) {
                return
            }
        }
        throw LogicianError.verificationFailed(
            requested: "automation mode '\(mode)' on '\(trackName)'",
            actual: "the strip still shows '\(logic.automationModeLabel(trackName: trackName) ?? "?")'",
            restored: false
        )
    }

    static func currentFader14(_ channel: Int) -> Int? {
        guard let faders = freshStatus()?["faders_14bit"] as? [Int],
              faders.indices.contains(channel), faders[channel] >= 0 else { return nil }
        return faders[channel]
    }

    /// Records a volume automation curve: calibrate each target dB to an
    /// absolute 14-bit fader position (via LCD-converged writes + Logic's own
    /// motorized-fader echo), switch the track to Latch, roll playback and
    /// place the fader at each point's moment, then return to Read and
    /// verify by REPLAYING the range while sampling the fader echo.
    static func recordVolumeAutomation(
        logic: LogicAccessibility,
        trackName: String,
        points: [(bar: Int, beat: Double, db: Double)],
        ramp: Bool,
        verify: Bool
    ) throws -> [String: Any] {
        let transport = try logic.getTransport()
        guard let tempo = transport["tempo"] as? Double else {
            throw LogicianError.trackNotExposed(
                requested: "tempo from the control bar", exposed: "not readable"
            )
        }
        let beatsPerBar = Double((transport["time_signature"] as? String)?
            .split(separator: "/").first.flatMap { Int($0) } ?? 4)
        let sorted = points.sorted {
            ($0.bar, $0.beat) < ($1.bar, $1.beat)
        }
        guard let first = sorted.first, first.bar >= 2 else {
            throw LogicianError.invalidArguments("points need bar >= 2 (one bar of pre-roll)")
        }
        // The roll sync below anchors on `timecodeBar()`, so the 10-digit
        // display has to be in bars/beats mode — in SMPTE mode it reports
        // hours and the curve would be written at an arbitrary position.
        // Shape check before the calibration pass touches the fader at all.
        try requireBeatsDisplay(operation: "volume automation from bar \(first.bar)")
        guard let channel = try findChannel(trackName: trackName) else {
            throw LogicianError.trackNotExposed(
                requested: "MCU channel for '\(trackName)'",
                exposed: "not found in the bank view"
            )
        }
        guard try selectFoundChannel(channel) else {
            throw LogicianError.writeFailed("MCU select failed")
        }
        guard let originalFader = currentFader14(channel) else {
            throw LogicianError.trackNotExposed(
                requested: "the track's fader echo",
                exposed: "Logic has not reported fader positions for this bank yet"
            )
        }

        // Calibrate: unique dB targets -> absolute fader values, then restore.
        var calibration: [Double: Int] = [:]
        for db in Set(sorted.map(\.db)) {
            guard try setVolume(trackName: trackName, targetDb: db, toleranceDb: 0.15) != nil,
                  let position = currentFader14(channel) else {
                _ = try? MCUBridge.send(.fader(channel: channel, value: originalFader))
                throw LogicianError.verificationFailed(
                    requested: "calibration of \(db) dB",
                    actual: "volume converge or fader echo failed; original volume restored",
                    restored: true
                )
            }
            calibration[db] = position
        }
        _ = try? MCUBridge.send(.fader(channel: channel, value: originalFader))
        Thread.sleep(forTimeInterval: 0.3)

        // Timed schedule relative to the crossing into the first point's bar.
        let msPerBeat = 60000.0 / tempo
        func offsetMs(_ bar: Int, _ beat: Double) -> Double {
            (Double(bar - first.bar) * beatsPerBar + (beat - 1)) * msPerBeat
        }
        var schedule: [(ms: Double, value: Int)] = sorted.map {
            (offsetMs($0.bar, $0.beat), calibration[$0.db] ?? originalFader)
        }
        if ramp && sorted.count > 1 {
            var expanded: [(Double, Int)] = []
            for index in 0..<(sorted.count - 1) {
                let a = schedule[index], b = schedule[index + 1]
                expanded.append(a)
                let steps = max(Int((b.ms - a.ms) / (msPerBeat / 2)), 1)
                if steps > 1 {
                    for s in 1..<steps {
                        let t = Double(s) / Double(steps)
                        expanded.append((a.ms + (b.ms - a.ms) * t,
                                         Int(Double(a.value) + Double(b.value - a.value) * t)))
                    }
                }
            }
            expanded.append(schedule[schedule.count - 1])
            schedule = expanded
        }

        try setAutomationMode("latch", logic: logic, trackName: trackName)
        var report: [String: Any] = [:]
        do {
            _ = try logic.setPlayhead(barNumber: first.bar - 1, beat: 1)
            Thread.sleep(forTimeInterval: 0.5)
            // Decisive mode check: the playhead was just parked at a bar
            // Logic itself verified, and the display has settled after the
            // move — so it must show that bar. Nothing is in the lane yet
            // (the calibration writes were already restored above), and the
            // catch below returns the track to Read and the original volume.
            try requireBeatsDisplay(
                expectedBar: first.bar - 1,
                operation: "volume automation from bar \(first.bar)"
            )
            guard (try? setPlaying(true)) != nil else {
                throw LogicianError.writeFailed("play failed")
            }
            // Sync: the timecode crossing into the first bar.
            let syncDeadline = Date().addingTimeInterval(20)
            var anchor: Date?
            while Date() < syncDeadline {
                if let bar = timecodeBar(), bar >= first.bar { anchor = Date(); break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard let start = anchor else {
                throw LogicianError.verificationFailed(
                    requested: "playback reaching bar \(first.bar)",
                    actual: "the timecode never got there", restored: false
                )
            }
            for entry in schedule {
                let wait = entry.ms / 1000 - Date().timeIntervalSince(start)
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                _ = try MCUBridge.send(.fader(channel: channel, value: entry.value))
            }
            Thread.sleep(forTimeInterval: 0.5)
            _ = try? setPlaying(false)
            try setAutomationMode("read", logic: logic, trackName: trackName)
            _ = try? MCUBridge.send(.fader(channel: channel, value: originalFader))
        } catch {
            _ = try? setPlaying(false)
            _ = try? setAutomationMode("read", logic: logic, trackName: trackName)
            _ = try? MCUBridge.send(.fader(channel: channel, value: originalFader))
            throw error
        }

        report["success"] = true
        report["state"] = "recorded"
        report["points"] = sorted.map { ["bar": $0.bar, "beat": $0.beat, "db": $0.db] }
        report["ramp"] = ramp
        report["write_route"] = "mcu_fader_latch"

        if verify {
            // Replay in Read and sample Logic's own fader echo at each point.
            _ = try logic.setPlayhead(barNumber: first.bar - 1, beat: 1)
            Thread.sleep(forTimeInterval: 0.4)
            _ = try? setPlaying(true)
            var samples: [[String: Any]] = []
            let syncDeadline = Date().addingTimeInterval(20)
            var anchor: Date?
            while Date() < syncDeadline {
                if let bar = timecodeBar(), bar >= first.bar { anchor = Date(); break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            if let start = anchor {
                for point in sorted {
                    let sampleAt = offsetMs(point.bar, point.beat) / 1000 + 0.25
                    let wait = sampleAt - Date().timeIntervalSince(start)
                    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                    let observed = currentFader14(channel) ?? -1
                    let expected = calibration[point.db] ?? -1
                    samples.append([
                        "bar": point.bar, "beat": point.beat, "db": point.db,
                        "expected_fader": expected,
                        "observed_fader": observed,
                        "pass": observed >= 0 && abs(observed - expected) <= 500
                    ])
                }
            }
            _ = try? setPlaying(false)
            _ = try? MCUBridge.send(.fader(channel: channel, value: originalFader))
            let allPass = !samples.isEmpty && samples.allSatisfy { $0["pass"] as? Bool == true }
            report["verified"] = allPass
            report["verification"] = [
                "samples": samples,
                "note": "The range was replayed in Read mode and Logic's own motorized-fader echo sampled at each point (14-bit positions; tolerance 500 ≈ 1.5 dB near unity)."
            ]
        } else {
            report["verified"] = false
        }
        return report
    }

    // MARK: Vpot automation (pan / send / plugin parameters)

    /// Splits a relative vpot move into wire-legal messages. ONE MCU vpot
    /// message carries at most 63 ticks - the bridge clamps with
    /// `min(abs(delta), 63)` and SILENTLY DROPS the rest, so any larger move
    /// must go out as several messages. Pure and exact on purpose: the undo
    /// paths (stepToText) depend on the chunks summing back to `delta`.
    static func vpotTickChunks(_ delta: Int) -> [Int] {
        var chunks: [Int] = []
        var remaining = delta
        while remaining != 0 {
            let chunk = max(-63, min(63, remaining))
            chunks.append(chunk)
            remaining -= chunk
        }
        return chunks
    }

    /// Sends a relative vpot move of any size (the wire format caps one
    /// message at 63 ticks).
    static func turnVpot(_ index: Int, by delta: Int) throws {
        for chunk in vpotTickChunks(delta) {
            let response = try MCUBridge.send(.vpot(index: index, delta: chunk))
            guard response.ok else {
                throw LogicianError.writeFailed("vpot failed mid-automation")
            }
        }
    }

    /// One quick "land on target" pass for a relative encoder during
    /// playback: a calibrated blind jump followed by up to two echo-checked
    /// corrections, all inside a small time budget so the point does not
    /// smear across the timeline.
    static func vpotJump(
        index: Int, target: Double, ticksPerUnit: Double,
        read: () -> Double?, budget: TimeInterval
    ) throws {
        if fastConverge(index: index, target: target,
                        maxMs: Int(budget * 1000), seedRatio: ticksPerUnit) != nil {
            return
        }
        // ADAPTIVE ratio: encoder scales are nonlinear (a dB near -inf is a
        // fraction of a tick; near unity several ticks), so the seed ratio
        // from the initial probe is only a starting guess — every turn's
        // observed movement refines it.
        let deadline = Date().addingTimeInterval(budget)
        var ratio = ticksPerUnit
        guard var current = read() else { return }
        while true {
            let step = abs(0.5 / max(abs(ratio), 0.01))
            if abs(current - target) <= step { return }
            var ticks = Int(((target - current) * ratio).rounded())
            if ticks == 0 {
                ticks = (target - current) * ratio > 0 ? 1 : -1
            }
            try turnVpot(index, by: ticks)
            guard Date() < deadline else { return }
            Thread.sleep(forTimeInterval: 0.12)
            guard let now = read() else { return }
            let change = now - current
            if abs(change) > 0.0001, ticks != 0 {
                let observedRatio = Double(ticks) / change
                if observedRatio.isFinite, abs(observedRatio) < 1000 {
                    ratio = 0.5 * ratio + 0.5 * observedRatio
                }
            }
            current = now
        }
    }

    /// In-bridge convergence: the whole adaptive tick loop runs next to the
    /// LCD mirror (3 ms echo polling instead of a socket round trip + fat
    /// await per tick). Returns nil when the bridge lacks the command.
    static func fastConverge(
        index: Int, field: Int? = nil, target: Double,
        tolerance: Double = 0, maxMs: Int = 3000, seedRatio: Double? = nil
    ) -> (text: String, value: Double)? {
        // `field` and `ratio` stay optional so an absent one is ABSENT on the
        // wire: the bridge defaults field to index and ratio to 2.0, and
        // sending a placeholder would override those defaults.
        let command = BridgeCommand.converge(
            index: index, field: field, target: target,
            tolerance: tolerance, maxMs: maxMs, ratio: seedRatio
        )
        guard let response = try? MCUBridge.send(command), response.ok,
              let text = response.finalText,
              let value = response.finalValue else { return nil }
        return (text, value)
    }

    /// Builds a write closure for a vpot-controlled value: probes the
    /// encoder's ticks-per-unit once, then lands on targets with a blind
    /// calibrated jump plus up to two echo-checked corrections.
    static func makeVpotWriter(
        index: Int, read: @escaping () -> Double?
    ) throws -> (Double, TimeInterval) throws -> Void {
        var current: Double?
        for _ in 0..<12 {
            if let value = read() { current = value; break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let origin = current else {
            throw LogicianError.trackNotExposed(requested: "a readable vpot echo", exposed: "none")
        }
        try turnVpot(index, by: 4)
        Thread.sleep(forTimeInterval: 0.35)
        guard let probed = read(), abs(probed - origin) > 0.0001 else {
            throw LogicianError.verificationFailed(
                requested: "a vpot probe response",
                actual: "the value did not move on a 4-tick probe",
                restored: false
            )
        }
        let ticksPerUnit = 4.0 / (probed - origin)
        try turnVpot(index, by: -4) // undo the probe
        Thread.sleep(forTimeInterval: 0.2)
        return { target, budget in
            try vpotJump(index: index, target: target, ticksPerUnit: ticksPerUnit,
                         read: read, budget: budget)
        }
    }

    /// Records an automation curve for a vpot-controlled value (pan, a send
    /// level, or a plugin parameter): measure the encoder's ticks-per-unit
    /// near the working range, converge to the first point, switch to Latch,
    /// roll playback placing calibrated jumps at each musical moment, return
    /// to Read, restore the original value, and verify by replaying while
    /// sampling the LCD echo.
    static func recordVpotAutomation(
        logic: LogicAccessibility,
        trackName: String,
        kindLabel: String,
        points: [(bar: Int, beat: Double, value: Double)],
        ramp: Bool,
        verify: Bool,
        tolerance: Double,
        enterView: (Int) throws -> (read: () -> Double?, write: (Double, TimeInterval) throws -> Void),
        refreshView: (() throws -> Void)? = nil,
        restoreView: @escaping () -> Void
    ) throws -> [String: Any] {
        let transport = try logic.getTransport()
        guard let tempo = transport["tempo"] as? Double else {
            throw LogicianError.trackNotExposed(
                requested: "tempo from the control bar", exposed: "not readable"
            )
        }
        let beatsPerBar = Double((transport["time_signature"] as? String)?
            .split(separator: "/").first.flatMap { Int($0) } ?? 4)
        let sorted = points.sorted { ($0.bar, $0.beat) < ($1.bar, $1.beat) }
        guard let first = sorted.first, first.bar >= 2 else {
            throw LogicianError.invalidArguments("points need bar >= 2 (one bar of pre-roll)")
        }
        guard let channel = try findChannel(trackName: trackName) else {
            throw LogicianError.trackNotExposed(
                requested: "MCU channel for '\(trackName)'", exposed: "not in the bank view"
            )
        }
        guard try selectFoundChannel(channel) else {
            throw LogicianError.writeFailed("MCU select failed")
        }
        let view = try enterView(channel)
        defer { restoreView() }
        // The control repaints for a moment after a view switch — poll patiently.
        var initial: Double?
        for _ in 0..<12 {
            if let value = view.read() { initial = value; break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let original = initial else {
            throw LogicianError.trackNotExposed(
                requested: "a readable \(kindLabel) value", exposed: "no echo after 3 s"
            )
        }
        // Park on the first point's value before rolling.
        try view.write(first.value, 2.0)

        let msPerBeat = 60000.0 / tempo
        func offsetMs(_ bar: Int, _ beat: Double) -> Double {
            (Double(bar - first.bar) * beatsPerBar + (beat - 1)) * msPerBeat
        }
        var schedule: [(ms: Double, value: Double)] = sorted.map {
            (offsetMs($0.bar, $0.beat), $0.value)
        }
        if ramp && schedule.count > 1 {
            var expanded: [(Double, Double)] = []
            for index in 0..<(schedule.count - 1) {
                let a = schedule[index], b = schedule[index + 1]
                expanded.append(a)
                let steps = max(Int((b.ms - a.ms) / msPerBeat), 1) // 1 delvärde/slag
                if steps > 1 {
                    for s in 1..<steps {
                        let t = Double(s) / Double(steps)
                        expanded.append((a.ms + (b.ms - a.ms) * t, a.value + (b.value - a.value) * t))
                    }
                }
            }
            expanded.append(schedule[schedule.count - 1])
            schedule = expanded
        }

        try setAutomationMode("latch", logic: logic, trackName: trackName)
        do {
            _ = try logic.setPlayhead(barNumber: first.bar - 1, beat: 1)
            Thread.sleep(forTimeInterval: 0.5)
            let parkedTimecode = freshStatus()?["timecode"] as? String
            guard (try? setPlaying(true)) != nil else {
                throw LogicianError.writeFailed("play failed")
            }
            // Anchor at ROLL START (the parked bar), not at the first point's
            // bar crossing: the whole pre-roll bar is then usable for the
            // first point's convergence lead.
            let syncDeadline = Date().addingTimeInterval(20)
            var anchor: Date?
            while Date() < syncDeadline {
                if let timecode = freshStatus()?["timecode"] as? String,
                   timecode != parkedTimecode { anchor = Date(); break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard let start = anchor else {
                throw LogicianError.verificationFailed(
                    requested: "playback rolling from bar \(first.bar - 1)",
                    actual: "the timecode never moved", restored: false
                )
            }
            let preRollMs = beatsPerBar * msPerBeat // one bar before the first point
            for (position, entry) in schedule.enumerated() {
                // Vpot convergence takes time — lead each write so the curve
                // centers on the musical moment instead of trailing it. The
                // FIRST point gets a long lead and a full budget: an existing
                // lane can start playback far from the target (overriding the
                // pre-parked static value), and the anchor must be converged
                // BEFORE its moment arrives.
                let isFirst = position == 0
                let isLast = position == schedule.count - 1
                let lead = isFirst ? 1.2 : 0.35
                let wait = (preRollMs + entry.ms) / 1000 - lead - Date().timeIntervalSince(start)
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                if isFirst, let current = view.read(), abs(current - entry.value) < 0.01 {
                    // Latch only writes on a TOUCH: already on target means
                    // nothing would be recorded — wiggle to anchor the curve.
                    try view.write(entry.value - 1, 0.25)
                }
                try view.write(entry.value,
                               isFirst ? 1.0 : (isLast ? 1.5 : max(0.15, min(0.6, msPerBeat / 2000))))
            }
            Thread.sleep(forTimeInterval: 0.5)
            _ = try? setPlaying(false)
            try setAutomationMode("read", logic: logic, trackName: trackName)
            try view.write(original, 2.0)
        } catch {
            _ = try? setPlaying(false)
            _ = try? setAutomationMode("read", logic: logic, trackName: trackName)
            _ = try? view.write(original, 2.0)
            throw error
        }

        var report: [String: Any] = [
            "success": true,
            "state": "recorded",
            "parameter": kindLabel,
            "points": sorted.map { ["bar": $0.bar, "beat": $0.beat, "value": $0.value] },
            "ramp": ramp,
            "write_route": "mcu_vpot_latch"
        ]
        if verify {
            // The automation-mode button presses can knock the surface out of
            // the working view — re-enter it before reading anything.
            try refreshView?()
            // Playhead-chase verification: parked in Read mode, Logic chases
            // the automation lane to the playhead position — stationary,
            // exact reads with no live-LCD lag, and no realtime replay.
            var samples: [[String: Any]] = []
            for point in sorted {
                _ = try? logic.setPlayhead(
                    barNumber: point.bar, beat: max(Int(point.beat.rounded()), 1)
                )
                Thread.sleep(forTimeInterval: 0.8)
                let observed = view.read()
                samples.append([
                    "bar": point.bar, "beat": point.beat,
                    "expected": point.value,
                    "observed": observed.map { $0 as Any } ?? NSNull() as Any,
                    "pass": observed.map { abs($0 - point.value) <= tolerance } ?? false
                ])
            }
            _ = try? view.write(original, 2.0)
            let allPass = !samples.isEmpty && samples.allSatisfy { $0["pass"] as? Bool == true }
            report["verified"] = allPass
            report["verification"] = [
                "samples": samples,
                "tolerance": tolerance,
                "note": "Verified by parking the playhead at each point in Read mode and reading the automation-chased value."
            ]
        } else {
            report["verified"] = false
        }
        return report
    }

}
