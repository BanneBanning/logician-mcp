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
//
// THE POSITION IS PART OF THE READING. A sampled value means nothing without
// the position it was sampled at, and this tool used to guess that half:
// `_ = try? logic.setPlayhead(...)` threw the park's failure away and appended
// whatever the lane read at wherever the playhead actually stood under the
// bar/beat that had been ASKED for. Measured 2026-09-02 on the sandbox:
// `{bar 2, beat 5, value -18.6}` came back — `readable`, no warning,
// `playhead_restored: true` — with the playhead standing at bar 4 beat 1, on a
// curve whose real value at 2.4 is -7.4 dB. Every sample now carries the
// position the park VERIFIED and the MCU timecode CONFIRMED, or it is not a
// sample at all: it is omitted and the reason is named.

extension MCUController {

    // MARK: - The sampling grid (pure)

    /// One position on the playhead's bar/beat grid.
    ///
    /// `beat` counts the position display's beat slots, which is the
    /// signature's NUMERATOR — a 5/4 bar has five, a 6/8 bar six. Deliberately
    /// not `MeterMap.beatsPerBar`, which counts quarter notes (6/8 is three) so
    /// that bar→seconds math works; the two agree for every x/4 signature,
    /// which is why nothing noticed until a 5/4 bar was in range.
    struct AutomationSamplePosition: Equatable {
        let bar: Int
        let beat: Int
    }

    /// The grid a read will park on, and what the grid had to do to fit.
    struct AutomationSampleGrid: Equatable {
        let positions: [AutomationSamplePosition]
        /// Beats between positions after any widening for `maxPoints`.
        let stepBeats: Int
        /// The LAST hop's length. Smaller than `stepBeats` when `endBar` does
        /// not fall on the step — it is sampled anyway (see `endBarSampled`),
        /// and this number is what says the final interval is a short one.
        let finalIntervalBeats: Int
        /// False in exactly one case: `maxPoints: 1` over a range wider than a
        /// single position, where there is no room for a second point. The
        /// caller warns; nothing else silently drops the end.
        let endBarSampled: Bool

        static let empty = AutomationSampleGrid(
            positions: [], stepBeats: 0, finalIntervalBeats: 0, endBarSampled: false
        )
    }

    /// The bar/beat positions a read will park on. Pure: the sampling grid
    /// decides what the caller is told the curve does, and getting it wrong is
    /// a plausible-looking lie rather than a visible failure.
    ///
    /// Positions run from (`startBar`, 1) through (`endBar`, 1) inclusive, one
    /// every `resolutionBeats` beats. Two rules, both of them things this
    /// function got wrong before it was measured (2026-09-02):
    ///
    /// - **`endBar` is always sampled.** The walk used to step `offset += step`
    ///   and stop, so a `resolutionBeats` wider than the remaining span dropped
    ///   the final position: `{start 2, end 3, resolution 5}` returned ONE
    ///   point, at bar 2 beat 1, while the description promised the range is
    ///   never truncated — and a single point cannot fire the flat-line warning
    ///   either, so the most over-readable answer came back with no caveat at
    ///   all. `endBar` beat 1 is now appended when the step misses it, which
    ///   makes the LAST interval shorter than the others and says so in
    ///   `finalIntervalBeats`.
    /// - **Bar lengths come from `beatSlots`, per bar.** The caller feeds this
    ///   the project's meter map, so a range crossing a signature change gets
    ///   each bar's own beats. It used to be one integer read off the control
    ///   bar — the signature in force AT THE PLAYHEAD — which is how a grid
    ///   asking for "bar 2 beat 5" of a four-beat bar was built while the
    ///   playhead sat in a 5/4 bar 39 bars away.
    ///
    /// When the grid would exceed `maxPoints` the step is widened until it
    /// fits — a coarser answer, never a truncated one, because a curve cut off
    /// half way is the more misleading of the two.
    static func automationSampleGrid(
        startBar: Int, endBar: Int, resolutionBeats: Int, maxPoints: Int,
        beatSlots: (Int) -> Int
    ) -> AutomationSampleGrid {
        guard startBar >= 1, endBar >= startBar, maxPoints >= 1 else { return .empty }
        // The bars BETWEEN the ends, each with its own length. A bar the meter
        // cannot describe (zero or negative slots) is refused rather than
        // guessed at: a wrong bar length silently misplaces every later sample.
        var lengths: [Int] = []
        for bar in startBar..<endBar {
            let slots = beatSlots(bar)
            guard slots >= 1 else { return .empty }
            lengths.append(slots)
        }
        let span = lengths.reduce(0, +)
        let single = AutomationSampleGrid(
            positions: [AutomationSamplePosition(bar: startBar, beat: 1)],
            stepBeats: max(resolutionBeats, 1), finalIntervalBeats: 0,
            endBarSampled: span == 0
        )
        guard span > 0 else { return single }
        // One point cannot span a range: say so here rather than pretend the
        // end was reached.
        guard maxPoints >= 2 else { return single }

        var step = max(resolutionBeats, 1)
        // Widen in one arithmetic step rather than by trial: ceil(span / hops)
        // is the smallest step whose grid fits, and the loop it replaces ran
        // once per beat of a long range.
        let hops = maxPoints - 1
        step = max(step, (span + hops - 1) / hops)

        func position(atOffset offset: Int) -> AutomationSamplePosition {
            var remaining = offset
            var index = 0
            while index < lengths.count, remaining >= lengths[index] {
                remaining -= lengths[index]
                index += 1
            }
            return AutomationSamplePosition(bar: startBar + index, beat: remaining + 1)
        }

        var offsets: [Int] = []
        var offset = 0
        while offset <= span {
            offsets.append(offset)
            offset += step
        }
        if offsets.last != span { offsets.append(span) }
        let final = offsets.count >= 2 ? offsets[offsets.count - 1] - offsets[offsets.count - 2] : 0
        return AutomationSampleGrid(
            positions: offsets.map(position(atOffset:)),
            stepBeats: step, finalIntervalBeats: final, endBarSampled: true
        )
    }

    /// The constant-meter grid, for the callers and tests that have one integer
    /// rather than a map.
    static func automationSamplePositions(
        startBar: Int, endBar: Int, beatsPerBar: Int,
        resolutionBeats: Int, maxPoints: Int
    ) -> [AutomationSamplePosition] {
        guard beatsPerBar >= 1 else { return [] }
        return automationSampleGrid(
            startBar: startBar, endBar: endBar, resolutionBeats: resolutionBeats,
            maxPoints: maxPoints, beatSlots: { _ in beatsPerBar }
        ).positions
    }

    /// The position display's beat slots in `bar` — the signature's numerator,
    /// taken from the meter map when there is one and from the caller's
    /// fallback integer when there is not.
    ///
    /// The map is honoured whether it VARIES or not, which is a deliberate
    /// exception to `MeterMap`'s constant-meter contract (a constant map is
    /// normally reported and never used, so a caller's own `beats_per_bar`
    /// stays authoritative). This tool has no such argument: the scalar it
    /// would otherwise fall back on is the control bar's signature at the
    /// playhead, and that scalar IS the defect. A read map, constant or not, is
    /// strictly better evidence about bar 2 than a reading taken at bar 41.
    static func automationBeatSlots(inBar bar: Int, meter: MeterMap?, fallback: Int) -> Int {
        guard let meter, let first = meter.events.first else { return max(fallback, 1) }
        var current = first.numerator
        for event in meter.events {
            if event.bar > bar { break }
            current = event.numerator
        }
        return max(current, 1)
    }

    /// The signature changes that fall strictly inside a sampled range — the
    /// thing that makes one `beats_per_bar` a lie. Reported, not warned about:
    /// the grid now follows them, so this is information rather than a caveat.
    static func automationMeterChanges(
        startBar: Int, endBar: Int, meter: MeterMap?
    ) -> [(bar: Int, signature: String)] {
        guard let meter, endBar > startBar else { return [] }
        return meter.events
            .filter { $0.bar > startBar && $0.bar <= endBar }
            .map { (bar: $0.bar, signature: $0.signature) }
    }

    // MARK: - The park-and-prove decision (pure)

    /// What one sampled position becomes in the result.
    enum AutomationSampleVerdict: Equatable {
        /// Report the value under `bar`/`beat` — the position that was PROVEN,
        /// not the one that was asked for. `confirmedBySurface` is false when
        /// the MCU position display could not be read, in which case the
        /// control bar's own verified sliders are the only witness.
        case report(bar: Int, beat: Int, confirmedBySurface: Bool, landedElsewhere: Bool)
        /// No sample: the park failed, so whatever the lane reads now belongs
        /// to some other position.
        case omit(reason: String)
    }

    /// Whether a sampled value may be attributed to the position it was asked
    /// for. Pure because it is the whole defect: this decision used to be
    /// "always yes", made by a `try?` that discarded the evidence.
    ///
    /// - `parkFailure`: the park's error message, nil when `setPlayhead`
    ///   verified the control bar's bar AND beat sliders.
    /// - `landed`: the MCU position display read AFTER the settle — the same
    ///   sensor plane, and the same instant, as the value itself.
    static func automationSampleVerdict(
        requested: AutomationSamplePosition,
        parkFailure: String?,
        landed: AutomationSamplePosition?
    ) -> AutomationSampleVerdict {
        if let parkFailure {
            return .omit(
                reason: "the playhead could not be parked at bar \(requested.bar)"
                    + " beat \(requested.beat): \(parkFailure)"
            )
        }
        guard let landed else {
            // The park verified against the control bar's sliders, which is
            // real proof of bar and beat; only the second witness is missing.
            return .report(
                bar: requested.bar, beat: requested.beat,
                confirmedBySurface: false, landedElsewhere: false
            )
        }
        return .report(
            bar: landed.bar, beat: landed.beat,
            confirmedBySurface: true, landedElsewhere: landed != requested
        )
    }

    /// What the result says about the strip's automation mode — the label, or
    /// the REASON there is no label.
    ///
    /// `null` alone was ambiguous in the worst possible direction: it is
    /// documented as the signature of a headerless strip, it was also what a
    /// mode read 140 ms after the surface selection returned on the FIRST call
    /// for a track (the same track answering `"Read"` on the next call), and
    /// `Off` — the mode that makes every sample the lane's static value — is
    /// exactly what a null cannot rule out. So a null now travels with the
    /// sentence that says which of those it is.
    static func automationModeUnavailable(
        trackName: String, attempts: Int, waitedMs: Int
    ) -> String {
        "the inspector published no automation-mode label for '\(trackName)' in \(attempts)"
            + " attempts over \(waitedMs) ms, so the mode is UNKNOWN — not Off. An inspector"
            + " shows the selected track's own strip and its output, so Master, auxes and buses"
            + " never publish it; on a normal track this means the label was still not there."
            + " Read it in Logic's inspector, or select the track and ask again."
    }

    /// A sampled value as JSON should carry it: two decimals, and no binary
    /// tail. `($0 * 100).rounded() / 100` rounded the VALUE and not the printed
    /// form, so a 2-decimal number serialised as `-6.2000000000000002` — ~15
    /// bytes of false precision per point, 8 % of a dense response, on a tool
    /// whose whole contract is "these are samples".
    static func automationSampleNumber(_ value: Double) -> Any {
        guard value.isFinite else { return NSNull() }
        return NSDecimalNumber(string: String(format: "%.2f", value))
    }

    // MARK: - The reader

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
    ///
    /// `viewDebt` names the view the call is HANDED OVER in on success instead
    /// of walking home from: `exitToPan` measured 3 262–4 562 ms here on
    /// 2026-09-02, which is 15 % of a dense read and **77 % of a one-point
    /// one** — paid after the last byte the caller was waiting for, and it also
    /// leaves the Pan/Surround banner painted for the NEXT call's
    /// `ensurePanNames` to wait out (three identical calls measured
    /// `findChannel` at 105 / 506 / 2 017 ms purely from that). The
    /// `parameter: "pan"` path never paid it and lands at 1 348 ms total, which
    /// is what the deferral buys the others. Every FAILURE path still restores
    /// explicitly: a refusal has no result for a debt to travel with.
    static func readAutomation(
        logic: LogicAccessibility,
        trackName: String,
        kindLabel: String,
        startBar: Int,
        endBar: Int,
        resolutionBeats: Int,
        maxPoints: Int,
        settleSeconds: Double,
        meter: MeterKnowledge,
        enterView: (Int) throws -> () -> Double?,
        restoreView: () -> Void,
        viewDebt: SurfaceDebt? = nil
    ) throws -> [String: Any] {
        guard startBar >= 1 else {
            throw LogicianError.invalidArguments("start_bar must be >= 1")
        }
        guard endBar >= startBar else {
            throw LogicianError.invalidArguments("end_bar must be >= start_bar")
        }
        try requireSurface("the Mackie Control bridge for the automation read")
        // The map when the Signature List was read, and the control bar's
        // reading only when it was not — and in that case the reading is a
        // FALLBACK that the result names, because it is the signature in force
        // at the playhead rather than in the range being read.
        let meterMap = meter.map?.source == .signatureList ? meter.map : nil
        var fallbackSlots = 4
        if meterMap == nil {
            let transport = try logic.getTransport()
            fallbackSlots = (transport["time_signature"] as? String)?
                .split(separator: "/").first.flatMap { Int($0) } ?? 4
        }
        let slots: (Int) -> Int = { bar in
            automationBeatSlots(inBar: bar, meter: meterMap, fallback: fallbackSlots)
        }
        let grid = automationSampleGrid(
            startBar: startBar, endBar: endBar,
            resolutionBeats: resolutionBeats, maxPoints: maxPoints, beatSlots: slots
        )
        guard !grid.positions.isEmpty else {
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
        //
        // Read up to three times, and the first two retries cost NO WAIT: the
        // inspector needs ~200 ms after the surface selection to publish the
        // label (measured: null on a track's first call, "Read" on the next),
        // and this call is about to spend 46 ms entering a view and then at
        // least `settle_seconds` parking the first point. So the retries are
        // taken at those two points, where the time has already been spent on
        // something else, and only the last one pays 150 ms of its own.
        var modeAttempts = 1
        var modeWaitedMs = 0
        let modeClock = Date()
        var mode = logic.automationModeLabel(trackName: trackName)

        // Armed BEFORE the view is entered: a view that half-opened and then
        // threw (a plugin slot entered, its parameter not found) used to leave
        // the surface where it stopped. One extra restore on a failure path is
        // the cheaper mistake.
        var handedOver = false
        defer { if !handedOver { restoreView() } }
        let read = try enterView(channel)
        if mode == nil {
            modeAttempts += 1
            mode = logic.automationModeLabel(trackName: trackName)
        }

        let startPosition = timecodeBarBeat()
        var samples: [[String: Any]] = []
        var omitted: [[String: Any]] = []
        var readable = 0
        var unconfirmed = 0
        var displaced = 0
        for position in grid.positions {
            var parkFailure: String?
            do {
                _ = try logic.setPlayhead(barNumber: position.bar, beat: position.beat)
            } catch {
                parkFailure = error.localizedDescription
            }
            // A park that cannot land on the FIRST position means the grid
            // itself does not exist in this project — the shape that produced
            // "bar 2 beat 5" of a four-beat bar — and the playhead is now
            // somewhere nobody asked for. Refuse rather than sample a grid we
            // invented, and put the playhead back before doing so.
            if let parkFailure, samples.isEmpty, omitted.isEmpty {
                if let start = startPosition {
                    _ = try? logic.setPlayhead(barNumber: start.bar, beat: start.beat)
                }
                throw LogicianError.preconditionUnmet(
                    "the playhead could not be parked at bar \(position.bar) beat"
                        + " \(position.beat), the first position of this read: \(parkFailure)."
                        + " Nothing was sampled, because a value read at an unknown position is"
                        + " not a reading of bar \(position.bar). Bar \(position.bar) has"
                        + " \(slots(position.bar)) beats"
                        + (meterMap == nil
                            ? " according to the control bar's signature AT THE PLAYHEAD (the"
                                + " Signature List could not be read) — check it with"
                                + " logic_list_signatures"
                            : " according to the project's Signature List")
                        + "; the playhead was returned to where it started."
                )
            }
            Thread.sleep(forTimeInterval: settleSeconds)
            let value = read()
            switch automationSampleVerdict(
                requested: position, parkFailure: parkFailure,
                landed: timecodeBarBeat().map {
                    AutomationSamplePosition(bar: $0.bar, beat: $0.beat)
                }
            ) {
            case .omit(let reason):
                omitted.append(["bar": position.bar, "beat": position.beat, "reason": reason])
            case .report(let bar, let beat, let confirmed, let elsewhere):
                if value != nil { readable += 1 }
                if !confirmed { unconfirmed += 1 }
                var sample: [String: Any] = [
                    "bar": bar, "beat": beat,
                    "value": value.map(automationSampleNumber) ?? NSNull() as Any
                ]
                // Only the exceptional point grows: a sample whose position was
                // proven by both witnesses stays the 40 bytes it always was.
                if !confirmed { sample["position_confirmed"] = false }
                if elsewhere {
                    displaced += 1
                    sample["requested_bar"] = position.bar
                    sample["requested_beat"] = position.beat
                }
                samples.append(sample)
            }
            if mode == nil, modeAttempts < 3 {
                // The free third attempt, taken ONCE: `settle_seconds` (0.8 s
                // by default) has now passed since the selection, five times
                // the interval the null was measured at. Retrying at every
                // point would spend 140 ms a walk on a strip that publishes no
                // label at all — 2.4 s across a dense read, for an answer the
                // first three attempts already gave.
                modeAttempts += 1
                mode = logic.automationModeLabel(trackName: trackName)
            }
        }
        if mode == nil {
            // The one attempt that pays for itself. 150 ms, once per call, on
            // the strips that are usually the headerless ones.
            Thread.sleep(forTimeInterval: 0.15)
            modeAttempts += 1
            mode = logic.automationModeLabel(trackName: trackName)
        }
        modeWaitedMs = Int(Date().timeIntervalSince(modeClock) * 1000)

        // Put the playhead back where it was found.
        var playheadRestored = false
        if let start = startPosition {
            playheadRestored = (try? logic.setPlayhead(barNumber: start.bar, beat: start.beat)) != nil
        }

        let values = samples.compactMap { ($0["value"] as? NSNumber)?.doubleValue }
        let flat = values.count >= 2 && (values.max()! - values.min()!) < 0.001
        var result: [String: Any] = [
            "success": true,
            "track": trackName, "track_name": trackName,
            "parameter": kindLabel,
            "start_bar": startBar,
            "end_bar": endBar,
            "beats_per_bar": slots(startBar),
            "requested_resolution_beats": resolutionBeats,
            "sample_count": samples.count,
            "points": samples,
            "automation_mode": mode.map { $0 as Any } ?? NSNull() as Any,
            "mcu_strip": channel + 1,
            "read_route": "playhead_chase_mcu_echo",
            "position_route": unconfirmed == 0
                ? "control_bar_verified_mcu_confirmed"
                : "control_bar_verified",
            "meter_route": meterMap == nil ? "control_bar_at_playhead" : "signature_list_map",
            "meter_map": meter.payload,
            "playhead_restored": playheadRestored,
            "note": "Sampled, not decoded: the playhead was parked at each position and Logic's own value echo read there. These are the values Logic evaluates the lane to — NOT the lane's breakpoints, so a move entirely between two samples is invisible and a finer resolution_beats is the only way to see it. Every point's bar/beat is the position the park VERIFIED, not the one requested; a position that could not be reached is in omitted_positions instead. Nothing was written: no automation mode change, no fader or vpot movement, and the playhead was put back."
        ]
        if mode == nil {
            result["automation_mode_unavailable"] = automationModeUnavailable(
                trackName: trackName, attempts: modeAttempts, waitedMs: modeWaitedMs
            )
        }
        if !omitted.isEmpty {
            result["omitted_positions"] = omitted
            result["requested_sample_count"] = grid.positions.count
        }
        let changes = automationMeterChanges(startBar: startBar, endBar: endBar, meter: meterMap)
        if !changes.isEmpty {
            result["meter_changes_in_range"] = changes.map {
                ["bar": $0.bar, "signature": $0.signature]
            }
        }
        if grid.positions.count > 1 {
            result["effective_resolution_beats"] = grid.stepBeats
            if grid.finalIntervalBeats != grid.stepBeats {
                result["final_interval_beats"] = grid.finalIntervalBeats
            }
        }
        if !grid.endBarSampled {
            appendWarning(
                "end_bar \(endBar) was NOT sampled: max_points is \(maxPoints), which leaves room"
                    + " for one position only. Raise max_points to see the end of the range.",
                to: &result
            )
        }
        if !omitted.isEmpty {
            appendWarning(
                "\(omitted.count) of \(grid.positions.count) positions were NOT sampled — the"
                    + " playhead could not be parked there — and are listed in"
                    + " omitted_positions rather than reported with a neighbour's value."
                    + " See omitted_positions for each reason.",
                to: &result
            )
        }
        if displaced > 0 {
            appendWarning(
                "\(displaced) sample(s) are reported at the position the playhead actually"
                    + " reached, which is not the one asked for; each carries requested_bar and"
                    + " requested_beat. The values belong to the bar/beat shown, not to the"
                    + " requested one.",
                to: &result
            )
        }
        if unconfirmed > 0 {
            appendWarning(
                "\(unconfirmed) of \(samples.count) positions could not be confirmed on the MCU"
                    + " position display (it reads SMPTE, or was blank), so their bar/beat rests"
                    + " on the control bar's verified sliders alone — which prove bar and beat"
                    + " but not the sub-beat offset.",
                to: &result
            )
        }
        if readable == 0 && !samples.isEmpty {
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
                    + (mode.map { " The strip's automation mode reads '\($0)'." }
                        ?? " The strip's automation mode could NOT be read, so Off — which makes"
                            + " every sample the lane's static value — cannot be ruled out here."),
                to: &result
            )
        }
        if samples.count == 1 {
            appendWarning(
                "One sampled position is a single value, not a curve: the flat-line check needs"
                    + " two. Lower resolution_beats or widen the bar range to see a shape.",
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
        // PATTERN #1, the debt: everything the caller is waiting for is in
        // memory by now, so the walk home is recorded instead of paid. The
        // failure paths above keep the explicit `restoreView` in the `defer`.
        if let viewDebt {
            deferSurfaceRestore(viewDebt)
            handedOver = true
            result["surface_left_in"] = viewDebt.view
        }
        return result
    }
}
