import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

// Reading an existing automation curve.
//
// Automation was write-only, which is why `logic_record_automation` is declared
// `destructive`: a Latch pass overwrites the whole range, and the agent could
// not see what it was about to overwrite. The mechanism to see it already
// existed — inside that same tool's verification pass. `recordVpotAutomation`
// finishes by parking the playhead at each point in Read mode and reading the
// value Logic chases to; with the writing half removed, that IS a read tool.
//
// What this returns is honest about what it is: the value Logic evaluates the
// lane to at each sampled position. It is not the lane's breakpoint list, so a
// curve can move between two samples without either sample noticing, and a
// track with no automation at all reads as a flat line at its static value.
// Both are stated in the result rather than left to be discovered.

extension MCUController {

    /// The bar/beat positions a read will park on. Pure: the sampling grid
    /// decides what the caller is told the curve does, and getting it wrong is
    /// a plausible-looking lie rather than a visible failure.
    ///
    /// Positions run from (`startBar`, 1) through (`endBar`, 1) inclusive, one
    /// every `resolutionBeats` beats. When that would exceed `maxPoints` the
    /// step is widened until it fits — a coarser answer, never a truncated one,
    /// because a curve cut off half way is the more misleading of the two.
    static func automationSamplePositions(
        startBar: Int, endBar: Int, beatsPerBar: Int,
        resolutionBeats: Int, maxPoints: Int
    ) -> [(bar: Int, beat: Int)] {
        guard startBar >= 1, endBar >= startBar, beatsPerBar >= 1, maxPoints >= 1 else { return [] }
        let span = (endBar - startBar) * beatsPerBar
        var step = max(resolutionBeats, 1)
        while span / step + 1 > maxPoints { step += 1 }
        var positions: [(bar: Int, beat: Int)] = []
        var offset = 0
        while offset <= span {
            positions.append((startBar + offset / beatsPerBar, offset % beatsPerBar + 1))
            offset += step
        }
        return positions
    }

    /// A read-only value reader for the channel-strip VOLUME view.
    /// Deliberately not built on `makeVpotWriter`: that probes the encoder by
    /// TURNING it, which is a write, and a read tool must not make one.
    static func volumeReader(channel: Int) throws -> () -> Double? {
        guard try ensureVolumeView() else {
            throw LogicianError.trackNotExposed(
                requested: "the control surface's channel-strip Volume view",
                exposed: "it could not be reached, so no dB value can be read"
            )
        }
        return {
            guard let bottom = freshStatus()?["lcd_bottom"] as? String else { return nil }
            return parseDb(lcdValueFields(bottom)[channel])
        }
    }

    /// Samples an automation lane by parking the playhead and reading Logic's
    /// own echo at each position. Writes nothing: no Latch, no fader move, no
    /// vpot turn — the only thing that moves is the playhead, and it is put
    /// back where it was found.
    static func readAutomation(
        logic: LogicAccessibility,
        trackName: String,
        kindLabel: String,
        startBar: Int,
        endBar: Int,
        resolutionBeats: Int,
        maxPoints: Int,
        settleSeconds: Double,
        enterView: (Int) throws -> () -> Double?,
        restoreView: () -> Void
    ) throws -> [String: Any] {
        guard startBar >= 1 else {
            throw LogicianError.invalidArguments("start_bar must be >= 1")
        }
        guard endBar >= startBar else {
            throw LogicianError.invalidArguments("end_bar must be >= start_bar")
        }
        try requireSurface("the Mackie Control bridge for the automation read")
        let transport = try logic.getTransport()
        let beatsPerBar = (transport["time_signature"] as? String)?
            .split(separator: "/").first.flatMap { Int($0) } ?? 4
        let positions = automationSamplePositions(
            startBar: startBar, endBar: endBar, beatsPerBar: beatsPerBar,
            resolutionBeats: resolutionBeats, maxPoints: maxPoints
        )
        guard !positions.isEmpty else {
            throw LogicianError.invalidArguments("the requested bar range yields no sample positions")
        }
        guard let channel = try findChannel(trackName: trackName) else {
            throw headerlessStripError(
                name: trackName,
                resolution: lastChannelResolution,
                visibleTracks: ((try? logic.parsedTrackHeaders()) ?? []).map(\.name),
                trackMiss: .trackNotFound(trackName, available: [])
            )
        }
        try selectChannelVerified(channel: channel, expectedName: trackName)
        // Report the lane's mode rather than changing it. Read is the mode the
        // chase is designed for; Latch and Touch chase too and write nothing
        // until a control is touched, which this never does. Off means Logic
        // ignores the lane entirely and the readings are the static value.
        let mode = logic.automationModeLabel(trackName: trackName)

        let read = try enterView(channel)
        defer { restoreView() }

        let startPosition = timecodeBarBeat()
        var samples: [[String: Any]] = []
        var readable = 0
        for position in positions {
            _ = try? logic.setPlayhead(barNumber: position.bar, beat: position.beat)
            Thread.sleep(forTimeInterval: settleSeconds)
            let value = read()
            if value != nil { readable += 1 }
            samples.append([
                "bar": position.bar,
                "beat": position.beat,
                "value": value.map { ($0 * 100).rounded() / 100 as Any } ?? NSNull() as Any
            ])
        }
        // Put the playhead back where it was found.
        var playheadRestored = false
        if let start = startPosition {
            playheadRestored = (try? logic.setPlayhead(barNumber: start.bar, beat: start.beat)) != nil
        }

        let values = samples.compactMap { $0["value"] as? Double }
        let flat = values.count >= 2 && (values.max()! - values.min()!) < 0.001
        var result: [String: Any] = [
            "success": true,
            "track": trackName, "track_name": trackName,
            "parameter": kindLabel,
            "start_bar": startBar,
            "end_bar": endBar,
            "beats_per_bar": beatsPerBar,
            "requested_resolution_beats": resolutionBeats,
            "sample_count": samples.count,
            "points": samples,
            "automation_mode": mode.map { $0 as Any } ?? NSNull() as Any,
            "mcu_strip": channel + 1,
            "read_route": "playhead_chase_mcu_echo",
            "playhead_restored": playheadRestored,
            "note": "Sampled, not decoded: the playhead was parked at each position and Logic's own value echo read there. These are the values Logic evaluates the lane to — NOT the lane's breakpoints, so a move entirely between two samples is invisible and a finer resolution_beats is the only way to see it. Nothing was written: no automation mode change, no fader or vpot movement, and the playhead was put back."
        ]
        if samples.count > positions.count { result["sample_count"] = positions.count }
        if let first = positions.first, let last = positions.last, positions.count > 1 {
            let usedStep = (last.bar - first.bar) * beatsPerBar + (last.beat - first.beat)
            result["effective_resolution_beats"] = usedStep / max(positions.count - 1, 1)
        }
        if readable == 0 {
            appendWarning(
                "None of the \(samples.count) positions produced a readable value — the view's echo"
                    + " was blank throughout. Nothing was written, and no conclusion about the lane"
                    + " should be drawn from this result.",
                to: &result
            )
        } else if readable < samples.count {
            appendWarning(
                "\(samples.count - readable) of \(samples.count) positions had no readable echo and"
                    + " are reported as null rather than interpolated.",
                to: &result
            )
        }
        if flat {
            appendWarning(
                "Every sampled value is the same. That is what an UNAUTOMATED lane looks like from"
                    + " here as well — the chase simply returns the static value — so this is not"
                    + " proof that a curve exists and is flat."
                    + (mode.map { " The strip's automation mode reads '\($0)'." } ?? ""),
                to: &result
            )
        }
        if !playheadRestored {
            appendWarning(
                "The playhead could not be returned to where it started; it is left at the last"
                    + " sampled position.",
                to: &result
            )
        }
        return result
    }
}
