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

    /// Whether a strip can CONFIRM an automation-mode press at all, told apart
    /// from an inspector that has simply not repainted yet.
    ///
    /// `automationModeLabel` folds both into `nil`, and an automation pass has
    /// to tell them apart: a strip with no track header — an aux, a bus, an
    /// output — publishes no automation-mode row and never will, so the press
    /// can never be verified and the pass must refuse BEFORE it writes
    /// anything; an inspector still showing the previous track is a transient
    /// worth another look.
    enum AutomationModeAvailability: Equatable {
        /// The strip publishes a mode right now; the dB beside it is the
        /// static volume, read in the same walk.
        case publishes(mode: String, volumeDb: Double?)
        /// The strip is there and has no automation row: no header, no label,
        /// ever.
        case headerless(volumeDb: Double?)
        /// The inspector is showing something else (its own name, verbatim).
        case inspectorElsewhere(String)
    }

    /// The verdict for a strip that WAS read. Pure, so the distinction the
    /// refusal rests on can be tested without an inspector.
    static func availability(from reading: ChannelStripReading) -> AutomationModeAvailability {
        guard let mode = reading.automationMode else {
            return .headerless(volumeDb: reading.volumeDB)
        }
        return .publishes(mode: mode, volumeDb: reading.volumeDB)
    }

    static func automationModeAvailability(
        logic: LogicAccessibility, trackName: String
    ) -> AutomationModeAvailability {
        guard let reading = try? logic.stripAutomationReading(trackName: trackName) else {
            return .inspectorElsewhere("the inspector is not showing '\(trackName)'")
        }
        return availability(from: reading)
    }

    /// The refusal a headerless strip has earned, in the words that name the
    /// cause and the way out. Pure so the sentence is testable.
    static func headerlessAutomationRefusal(trackName: String) -> LogicianError {
        LogicianError.preconditionUnmet(
            "'\(trackName)' has no track header, so Logic publishes no automation mode for it —"
                + " the mode press could never be confirmed and no automation can be recorded"
                + " on this strip. Automate the tracks feeding the bus instead"
                + " (logic_track_info names each track's output), or write a static value with"
                + " logic_set_track_volume / logic_set_send_level."
        )
    }

    /// Refuses BEFORE anything is written when the strip cannot confirm a mode
    /// press, and hands back the strip reading the pass needs anyway (its
    /// current automation mode and its static volume in dB).
    ///
    /// MEASURED 2026-09-02: a headerless-strip call used to cost **10 364 ms**
    /// — 5 512 ms of calibration fader writes, then two 2.5 s label polls that
    /// could not succeed — before refusing with "Readback mismatch … the strip
    /// still shows '?'", which reads like a transient to retry. The refusal is
    /// now ~0.5 s of looks (1 283 and 998 ms for the whole call on `Aux 2`,
    /// most of it `findChannel`'s bank scan), with nothing written and the
    /// cause named.
    ///
    /// And whether a NAME is headerless is a property of the project, not of
    /// the name: `Aux 1` in the sandbox has an aux TRACK row, publishes a mode
    /// like any track, and records normally — which is why this asks the strip
    /// instead of pattern-matching the name.
    static func requireAutomationModeConfirmable(
        logic: LogicAccessibility, trackName: String
    ) throws -> (mode: String, volumeDb: Double?) {
        // Three looks, ~0.5 s: the MCU SELECT echo the caller waited for is
        // the SURFACE's, and Logic's inspector repaints on its own clock.
        var last = AutomationModeAvailability.inspectorElsewhere("not read yet")
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.2) }
            last = automationModeAvailability(logic: logic, trackName: trackName)
            switch last {
            case .publishes(let mode, let volumeDb):
                return (mode, volumeDb)
            case .headerless:
                // Looked at twice before it is believed: a strip mid-repaint
                // could publish its rows a frame late, and this refusal is
                // final.
                if attempt > 0 { throw headerlessAutomationRefusal(trackName: trackName) }
            case .inspectorElsewhere:
                continue
            }
        }
        if case .headerless = last { throw headerlessAutomationRefusal(trackName: trackName) }
        // A hidden Inspector publishes no strip for ANY track, so it is not the
        // ambiguity below — it is one fact with one way out, and this call has
        // already tried it (`InspectorHold` shows the Inspector for a call that
        // needs a strip and puts it back). Say so instead of listing three
        // possibilities the user can rule out at a glance.
        if logic.inspectorPresence() == .hidden {
            throw LogicianError.preconditionUnmet(
                "Logic's Inspector is hidden, so it publishes no channel strip for '\(trackName)'"
                    + " — or for any track — and an automation-mode press can only be confirmed"
                    + " off that strip's own label. Nothing was recorded."
                    + (logic.inspectorHold?.attempted == true
                        ? " This call pressed View > Inspector to show it and no strip appeared."
                        : "")
                    + " Show it in Logic (View > Inspector, or the I key) and call again."
            )
        }
        // The inspector never showed the strip. On a bus/aux/output that is the
        // headerless case wearing another face (an inspector shows the selected
        // track's own strip and its output, so `Master`, an aux and most buses
        // never appear there at all); on a normal track it means the repaint
        // never came. The message names both, because from here they are not
        // distinguishable and only one of them has a retry.
        throw LogicianError.preconditionUnmet(
            "Logic's inspector never showed a channel strip named '\(trackName)', so the"
                + " automation-mode press could not be verified and nothing was recorded."
                + " An inspector publishes the SELECTED track's strip and its output only:"
                + " if '\(trackName)' is a bus, an aux or Master it has no track header and no"
                + " automation mode — automate the tracks feeding it instead (logic_track_info"
                + " names each track's output). If it is a normal track, select it in Logic"
                + " (or with logic_select_track) and call again."
        )
    }

    /// Sets the selected track's automation mode via the MCU button and
    /// verifies through the channel strip's mode label ("Latch, automation
    /// enabled") — surface write, Accessibility readback.
    ///
    /// LOOKS BEFORE IT WAITS (2026-09-02). The poll used to sleep 250 ms
    /// before its first look; a zero-wait probe read the final label **6/6
    /// across three runs** immediately after the press, and every run then
    /// "converged after 1 tick". So the look comes first and the wait only
    /// happens when the label is not there yet — measured saving 500 ms a
    /// call, two mode switches per pass. The 2.5 s budget is unchanged.
    ///
    /// A strip that publishes no automation row at all fails FAST with the
    /// headerless refusal rather than polling out the whole budget: 5 of the
    /// 10.4 s the old headerless refusal cost were two of these polls running
    /// out against a label that was never coming.
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
        let deadline = Date().addingTimeInterval(2.5)
        var seen = "?"
        while true {
            switch automationModeAvailability(logic: logic, trackName: trackName) {
            case .publishes(let label, _):
                if label.lowercased().hasPrefix(mode.lowercased()) { return }
                seen = label
            case .headerless:
                throw headerlessAutomationRefusal(trackName: trackName)
            case .inspectorElsewhere(let reason):
                seen = reason
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw LogicianError.verificationFailed(
            requested: "automation mode '\(mode)' on '\(trackName)'",
            actual: "the strip still shows '\(seen)'",
            restored: false
        )
    }

    // MARK: The roll anchor (one rule, both passes)

    /// What one timecode observation during a pre-roll means for the anchor.
    ///
    /// The old loop was `bar >= first.bar`, one-sided: its FIRST observation
    /// could already be past the range, and then the anchor was taken at the
    /// wrong position, the whole curve was written THERE, and the verification
    /// replay repeated the same error and confirmed it — `success: true`,
    /// `verified: true`, curve in the wrong bar. The premise is not
    /// theoretical: `logic_get_transport`'s profile measured `logic_set_playing`
    /// starting playback at bar 40 while the playhead read bar 51, because
    /// Logic plays from its own last play-start position.
    ///
    /// So a crossing is only accepted once a bar BELOW the range has been
    /// seen. Pure, and unit-tested: this decides where every breakpoint of the
    /// curve lands.
    ///
    /// THE PRE-ROLL SIGHTING WAS NOT ENOUGH (measured 2026-09-03, sandbox).
    /// `sawPreRoll` was set by the first reading of the loop, and the first
    /// reading of the loop is the PARKED display — the surface has not yet
    /// repainted Logic's jump when the poll runs 10 ms after the play press.
    /// So one stale reading of the pre-roll bar armed the guard, the next
    /// reading was bar 9, and `bar >= firstBar` called that "the crossing".
    /// Live: playhead parked and verified at bar 1 on both planes, a curve
    /// asked for at bars 2→4, and `logic_read_automation` then found it at
    /// bars 9→11 (-18.4 / -11.6 / -7.9 / -5.1 / -2.1 dB), with bars 2-4 flat
    /// at the track's static -5.1. Playback started at bar 9 five times out of
    /// five, from three different parked bars and from a `Go to Beginning`
    /// locate: Logic plays from ITS OWN last play-start position.
    ///
    /// Two rules now, and both matter:
    ///
    /// - the crossing must be INTO `firstBar` itself. A bar PAST the range is
    ///   the display having jumped, never a crossing — a bar is seconds long
    ///   and the poll is 10 ms, so a real crossing cannot be missed.
    /// - the pre-roll sighting must come from a display that has MOVED off the
    ///   park (`rollHasLeftThePark`), which is what makes it evidence of a
    ///   roll rather than of a repaint that has not happened yet.
    enum RollSyncVerdict: Equatable {
        /// Still before the range — the pre-roll this pass asked for.
        case preRoll
        /// The crossing INTO the first bar, with a pre-roll bar behind it.
        case crossed
        /// Playback started, or jumped, at or past the range: nothing may be
        /// anchored on this.
        case startedPastRange
    }

    static func rollSyncVerdict(
        observedBar: Int, firstBar: Int, sawPreRoll: Bool
    ) -> RollSyncVerdict {
        if observedBar < firstBar { return .preRoll }
        guard observedBar == firstBar, sawPreRoll else { return .startedPastRange }
        return .crossed
    }

    /// Whether a position reading is evidence that the transport has ROLLED,
    /// or just the parked display not yet repainted.
    ///
    /// The recorder for vpot parameters has always asked this question (it
    /// anchors on the first reading that differs from the parked one); the
    /// volume recorder did not, and that is how a stale pre-roll reading came
    /// to arm the anchor guard. Pure, so the distinction can be tested without
    /// a surface.
    static func rollHasLeftThePark(
        parked: MCUTimecodeReading, observed: MCUTimecodeReading
    ) -> Bool {
        guard case .beats = observed else { return false }
        return observed != parked
    }

    /// Ticks in one quarter-note beat on the MCU position display: four
    /// divisions of 240 (`BBB bb dd ttt`, so `  5 1 4201` is bar 5, beat 1,
    /// division 4, tick 201 — 0.958 beats past the beat, which is the measured
    /// shape of the sub-beat residue a verified park leaves behind).
    static let mcuTicksPerBeat = 960.0

    /// Milliseconds from the position the display is showing to the NEXT bar
    /// line, or nil when the display is not showing a position at all.
    ///
    /// Why the arming lead cannot just count from roll start: `setPlayhead`
    /// parks on a bar and a beat but carries any SUB-BEAT offset along
    /// unchanged (measured: `  5 1 4201` after three verified parkings), so the
    /// crossing can arrive most of a beat earlier than the pre-roll bar's
    /// length predicts. Reading how far through the bar Logic actually is
    /// makes the arm land a fixed distance before the bar line however the
    /// pre-roll started. Pure.
    static func msToNextBarLine(
        reading: MCUTimecodeReading, beatSlots: Int, barMs: Double
    ) -> Double? {
        guard case .beats(_, let beat, let division, let ticks) = reading,
              beatSlots >= 1, barMs > 0 else { return nil }
        // A blanked division or tick field is the bar line itself, not a
        // missing reading — Logic prints spaces for zero.
        let withinBeat = (Double(max(division, 1) - 1) * 240 + Double(max(ticks, 1) - 1))
            / mcuTicksPerBeat
        let progress = (Double(beat - 1) + withinBeat) / Double(beatSlots)
        return barMs * (1 - min(max(progress, 0), 1))
    }

    static func rollStartedPastRangeError(
        observedBar: Int, firstBar: Int, restored: Bool
    ) -> LogicianError {
        LogicianError.verificationFailed(
            requested: "playback to start in bar \(firstBar - 1) and cross into bar \(firstBar)",
            actual: "the transport rolled from bar \(observedBar), already at or past the range,"
                + " so nothing was written. LOGIC PLAYS FROM ITS OWN LAST PLAY-START POSITION,"
                + " not from the playhead: measured 2026-09-03, the playhead was parked at bar 1,"
                + " bar 20 and bar 1 again — verified on the control bar AND on the surface's"
                + " position display each time, once through a 'Go to Beginning' locate — and"
                + " playback began at bar 9 all five times. logic_set_playhead cannot move that"
                + " position; clicking Logic's ruler at bar \(firstBar - 1) can, and so can"
                + " playing and stopping once from there. Do that and call again. Until then"
                + " logic_read_automation still works — it parks the playhead and never rolls",
            restored: restored
        )
    }

    /// The one pre-roll rule, in ONE place: a Latch pass needs a whole bar in
    /// front of its first point to arm in, so bar 1 has nothing to roll from.
    /// Checked by the handler before it reads any map (a pure argument error
    /// used to cost ~1.8 s of tempo- and meter-map reads to reject) and again
    /// by each recorder, so no route can lose it.
    @discardableResult
    static func automationPreRollBar(firstBar: Int) throws -> Int {
        guard firstBar >= 2 else {
            throw LogicianError.invalidArguments("points need bar >= 2 (one bar of pre-roll)")
        }
        return firstBar - 1
    }

    /// Waits for the playhead display to agree it is parked at `bar`, instead
    /// of sleeping a fixed 500 ms and hoping. The park itself is already
    /// verified through the control bar by `setPlayhead`; this is the SURFACE
    /// catching up, and reading it costs 0.5 ms (measured), so the wait is
    /// over as soon as it is true.
    static func awaitParkedBar(
        _ bar: Int, operation: String, timeout: TimeInterval = 1.0
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if timecodeBar() == bar { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Out of budget: let the shaped refusal say what the display shows
        // (SMPTE mode, blank, a modal alert, or the wrong bar) — and if it is
        // within the display's own tolerance, carry on as before.
        try requireBeatsDisplay(expectedBar: bar, operation: operation)
    }

    // MARK: Automation timing under a tempo map

    /// Milliseconds from the FIRST point's musical moment to (`bar`, `beat`).
    ///
    /// With a tempo map read from Logic's Tempo List this is the integral of the
    /// map between the two positions, so a curve whose points straddle a tempo
    /// change lands on the beats it was asked for. Without a map it is the single
    /// `msPerBeat` multiplication that shipped before — the same arithmetic, so a
    /// project with no readable map behaves exactly as it did.
    ///
    /// Pure, and unit-tested: automation timing is real-time and expensive to
    /// re-run, so its arithmetic should not need Logic to be trusted.
    static func automationOffsetMs(
        bar: Int, beat: Double, firstBar: Int, beatsPerBar: Double,
        tempo: Double, map: TempoMap?, meter: MeterMap? = nil
    ) -> Double {
        let meterMap = (meter?.isVariable == true) ? meter : nil
        let beatsFromFirst = meterMap?.beatOffset(fromBar: firstBar, toBar: bar, beat: beat)
            ?? (Double(bar - firstBar) * beatsPerBar + (beat - 1))
        guard let map, map.source == .tempoList, !map.isConstant else {
            return beatsFromFirst * (60000.0 / tempo)
        }
        let origin = TempoMap.beatOffset(bar: firstBar, beatsPerBar: beatsPerBar, meter: meterMap)
        return (map.seconds(
            atBeatOffset: origin + beatsFromFirst, beatsPerBar: beatsPerBar, meter: meterMap
        ) - map.seconds(atBeatOffset: origin, beatsPerBar: beatsPerBar, meter: meterMap)) * 1000
    }

    /// The milliseconds-per-beat IN FORCE at (`bar`, `beat`) — what a per-beat
    /// convergence budget and a ramp's subdivision step need once "the tempo" is
    /// no longer one number.
    static func automationMsPerBeat(
        bar: Int, beat: Double, beatsPerBar: Double, tempo: Double,
        map: TempoMap?, meter: MeterMap? = nil
    ) -> Double {
        guard let map, map.source == .tempoList, !map.isConstant else {
            return 60000.0 / tempo
        }
        let meterMap = (meter?.isVariable == true) ? meter : nil
        let position = TempoMap.beatOffset(
            bar: bar, beatsPerBar: beatsPerBar, meter: meterMap
        ) + (beat - 1)
        return 60000.0 / map.bpm(atBeatOffset: position, beatsPerBar: beatsPerBar, meter: meterMap)
    }

    static func currentFader14(_ channel: Int) -> Int? {
        guard let faders = freshStatus()?["faders_14bit"] as? [Int],
              faders.indices.contains(channel), faders[channel] >= 0 else { return nil }
        return faders[channel]
    }

    /// The beats-per-bar an automation pass measures its offsets in.
    ///
    /// `getTransport`'s `time_signature` is the signature AT THE PLAYHEAD, not
    /// in the range being written — a playhead parked in a 5/4 bar reported
    /// five beats a bar for a curve in 4/4 (measured 2026-09-02; on the read
    /// side the same reading made `logic_read_automation` ask for beat 5 of a
    /// four-beat bar). So the signature at the FIRST POINT's bar, taken from
    /// the project's meter map, wins whenever the Signature List could be
    /// read, and the control bar is the fallback for a project whose map
    /// cannot be. Pure.
    static func automationBeatsPerBar(
        firstBar: Int, meterKnowledge: MeterMap?, transportSignature: String?
    ) -> Double {
        if let meterKnowledge, meterKnowledge.source == .signatureList {
            return meterKnowledge.beatsPerBar(atBar: firstBar)
        }
        return Double(transportSignature?
            .split(separator: "/").first.flatMap { Int($0) } ?? 4)
    }

    /// Records a volume automation curve: calibrate each target dB to an
    /// absolute 14-bit fader position (from the session's cached fader map
    /// where the evidence allows, otherwise via LCD-converged writes + Logic's
    /// own motorized-fader echo), switch the track to Latch, roll playback and
    /// place the fader at each point's moment, then return to Read and
    /// verify by REPLAYING the range while sampling the fader echo.
    ///
    /// THE FIRST POINT IS ARMED BEFORE THE RANGE (2026-09-02). Latch records
    /// from the moment the fader is TOUCHED, and entry 0 sits at offset 0 —
    /// so a schedule that could only start sending after the crossing into
    /// `first.bar` was *observed* never wrote a breakpoint at bar N beat 1,
    /// and the range's first instant kept whatever the lane held before.
    /// Measured on `Audio 9`: `logic_read_automation` read bar 2 beat 1 at the
    /// lane's pre-existing −0.5 dB after a pass that wrote −14 dB there, while
    /// the verification — which samples that same instant — called it
    /// `verified: false` twice and, when the old value happened to be close,
    /// `verified: true` once over a point that had not landed. The first
    /// value is now sent a fraction of a beat BEFORE the crossing (the
    /// arming touch, which is what makes bar N beat 1 itself hold the
    /// requested value), and sent again on the observed crossing.
    static func recordVolumeAutomation(
        logic: LogicAccessibility,
        trackName: String,
        trackNumber: Int? = nil,
        points: [(bar: Int, beat: Double, db: Double)],
        ramp: Bool,
        verify: Bool,
        tempoMap: TempoMap? = nil,
        meterMap: MeterMap? = nil,
        meterKnowledge: MeterMap? = nil
    ) throws -> [String: Any] {
        let transport = try logic.getTransport()
        guard let tempo = transport["tempo"] as? Double else {
            throw LogicianError.trackNotExposed(
                requested: "tempo from the control bar", exposed: "not readable"
            )
        }
        let sorted = points.sorted {
            ($0.bar, $0.beat) < ($1.bar, $1.beat)
        }
        guard let first = sorted.first else {
            throw LogicianError.invalidArguments("points required: [{bar, beat?, db}, ...]")
        }
        let preRollBar = try automationPreRollBar(firstBar: first.bar)
        let beatsPerBar = automationBeatsPerBar(
            firstBar: first.bar, meterKnowledge: meterKnowledge,
            transportSignature: transport["time_signature"] as? String
        )
        // The roll sync below anchors on `timecodeBar()`, so the 10-digit
        // display has to be in bars/beats mode — in SMPTE mode it reports
        // hours and the curve would be written at an arbitrary position.
        // Shape check before the calibration pass touches the fader at all.
        try requireBeatsDisplay(operation: "volume automation from bar \(first.bar)")
        let volumeHeaders = ((try? logic.parsedTrackHeaders()) ?? [])
            .map { TrackRowAddressing.Row(number: $0.number, name: $0.name) }
        guard let channel = try findChannel(
            trackName: trackName, trackNumber: trackNumber, headers: volumeHeaders
        ) else {
            throw automationChannelError(trackName: trackName, resolution: lastChannelResolution)
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
        // The precondition that can NEVER pass, tested before a single fader
        // message goes out: a strip with no track header publishes no
        // automation mode, so the Latch press could not be confirmed. It used
        // to be discovered 5.5 s into a calibration pass that had already
        // moved the aux's fader.
        let strip = try requireAutomationModeConfirmable(logic: logic, trackName: trackName)

        // Calibrate: unique dB targets -> absolute fader values. Cached per
        // Logic build and project, cross-checked against the strip's own
        // static dB and the fader echo under it, and only the values that
        // evidence does not cover cost a converged write (~5 s each).
        var movedFader = false
        let calibrated = try resolveFaderCalibration(
            targets: sorted.map(\.db), liveDb: strip.volumeDb, liveFader: originalFader,
            table: loadFaderCalibration(),
            measure: { db in
                movedFader = true
                guard try setVolume(
                    trackName: trackName, request: .absolute(db), toleranceDb: 0.15
                ) != nil,
                      let position = currentFader14(channel) else {
                    _ = try? MCUBridge.send(.fader(channel: channel, value: originalFader))
                    throw LogicianError.verificationFailed(
                        requested: "calibration of \(db) dB",
                        actual: "volume converge or fader echo failed; original volume restored",
                        restored: true
                    )
                }
                return position
            }
        )
        let calibration = calibrated.map
        // A table that was caught out is deleted, not narrowed, and the file is
        // written from the one this call actually stands behind.
        if calibrated.retire { discardFaderCalibration() }
        saveFaderCalibration(calibrated.table)
        if movedFader {
            // Restore the static volume the calibration borrowed, and pace on
            // Logic's own echo of the restore rather than a blind 0.3 s.
            _ = try? MCUBridge.send(.fader(channel: channel, value: originalFader))
            _ = waitFor(seconds: 0.4) { status in
                guard let faders = status["faders_14bit"] as? [Int],
                      faders.indices.contains(channel) else { return false }
                return abs(faders[channel] - originalFader) <= 20
            }
        }

        // Timed schedule relative to the crossing into the first point's bar,
        // integrated over the tempo map when one was read.
        func offsetMs(_ bar: Int, _ beat: Double) -> Double {
            automationOffsetMs(
                bar: bar, beat: beat, firstBar: first.bar, beatsPerBar: beatsPerBar,
                tempo: tempo, map: tempoMap, meter: meterMap
            )
        }
        var schedule: [(ms: Double, value: Int)] = sorted.map {
            (offsetMs($0.bar, $0.beat), calibration[$0.db] ?? originalFader)
        }
        if ramp && sorted.count > 1 {
            var expanded: [(Double, Int)] = []
            for index in 0..<(sorted.count - 1) {
                let a = schedule[index], b = schedule[index + 1]
                expanded.append(a)
                // Half-beat resolution AT THIS POINT's tempo: under a map the
                // beat is not the same number of milliseconds everywhere.
                let localMsPerBeat = automationMsPerBeat(
                    bar: sorted[index].bar, beat: sorted[index].beat,
                    beatsPerBar: beatsPerBar, tempo: tempo, map: tempoMap, meter: meterMap
                )
                let steps = max(Int((b.ms - a.ms) / (localMsPerBeat / 2)), 1)
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

        // 0…100 across arm → roll → pass → verify. The `catch` below already
        // stops the transport, returns the track to Read and restores the
        // fader, so a cancellation thrown from any of the loops in here leaves
        // the lane exactly as a failed pass would.
        reportProgress("arming latch automation", percent: 15)
        try setAutomationMode("latch", logic: logic, trackName: trackName)
        var report: [String: Any] = [:]
        // How far before the range the first value is armed. Latch writes from
        // the touch, so this is what puts a breakpoint at bar N beat 1 — and
        // it is deliberately a FRACTION of a beat: the arming touch overwrites
        // that fraction of the lane ahead of the range too, and the shorter it
        // is the less of the bar before the range it disturbs. 120 ms is under
        // a quarter beat at 120 BPM and still ten times the MIDI round trip.
        let armLeadMs = min(120.0, abs(offsetMs(preRollBar, 1)) * 0.25)
        var armedAt: Date?
        // The bar the schedule was actually timed from. Reported, because it
        // is the one fact that decides where every breakpoint landed and the
        // caller had no way to audit it.
        var anchoredAtBar: Int?
        do {
            _ = try logic.setPlayhead(barNumber: preRollBar, beat: 1)
            // Decisive mode check, and the pacing too: the playhead was just
            // parked at a bar Logic itself verified, so the surface must come
            // to show that bar — waiting for THAT replaces a blind 0.5 s with
            // a 0.5 ms read (measured). Nothing is in the lane yet (the
            // calibration writes were already restored above), and the catch
            // below returns the track to Read and the original volume.
            try awaitParkedBar(
                preRollBar, operation: "volume automation from bar \(first.bar)"
            )
            // What the PARKED display reads, kept so the sync loop below can
            // tell a repaint that has not happened yet from a transport that
            // has moved. Read after `awaitParkedBar`, so it is the settled
            // park and not a value in flight.
            let parkedReading = timecodeReading()
            guard (try? setPlaying(true)) != nil else {
                throw LogicianError.writeFailed("play failed")
            }
            let rollStart = Date()
            // The pre-roll bar's own length: under a tempo map it is not the
            // length of any other bar, and `offsetMs` measures from the first
            // point, so the pre-roll is its negative offset.
            let preRollMs = abs(offsetMs(preRollBar, 1))
            // Sync: the timecode crossing INTO the first bar, accepted only
            // after a MOVING bar below it has been seen (see
            // `rollSyncVerdict` and `rollHasLeftThePark`).
            let syncDeadline = Date().addingTimeInterval(20)
            var anchor: Date?
            var sawPreRoll = false
            let preRollSlots = automationBeatSlots(
                inBar: preRollBar, meter: meterMap, fallback: Int(beatsPerBar.rounded())
            )
            reportProgress("rolling; waiting for bar \(first.bar)", percent: 25)
            while Date() < syncDeadline {
                try checkCancelled()
                let reading = timecodeReading()
                var msToCrossing: Double?
                if case .beats(let bar, _, _, _) = reading,
                   rollHasLeftThePark(parked: parkedReading, observed: reading) {
                    switch rollSyncVerdict(
                        observedBar: bar, firstBar: first.bar, sawPreRoll: sawPreRoll
                    ) {
                    case .preRoll:
                        sawPreRoll = true
                        if bar == preRollBar {
                            msToCrossing = msToNextBarLine(
                                reading: reading, beatSlots: preRollSlots, barMs: preRollMs
                            )
                        }
                    case .crossed:
                        anchor = Date()
                        anchoredAtBar = bar
                    case .startedPastRange:
                        throw rollStartedPastRangeError(
                            observedBar: bar, firstBar: first.bar, restored: true
                        )
                    }
                    if anchor != nil { break }
                }
                // Arm the first value a fraction of a beat before the crossing.
                // How far the crossing still is comes from the display's own
                // beat and tick fields where it publishes them — a park's
                // sub-beat residue can put the bar line most of a beat earlier
                // than the pre-roll bar's length alone would predict — and from
                // the elapsed time as the backstop.
                if armedAt == nil, sawPreRoll,
                   msToCrossing.map({ $0 <= armLeadMs })
                    ?? (Date().timeIntervalSince(rollStart) * 1000 >= preRollMs - armLeadMs) {
                    if let live = currentFader14(channel),
                       abs(live - schedule[0].value) < 40 {
                        // Latch writes on a TOUCH: a fader already sitting on
                        // the target would record nothing at all. Step off it
                        // and back, both inside the arming lead.
                        let nudge = schedule[0].value > 200
                            ? schedule[0].value - 200 : schedule[0].value + 200
                        _ = try? MCUBridge.send(.fader(channel: channel, value: nudge))
                    }
                    _ = try MCUBridge.send(.fader(channel: channel, value: schedule[0].value))
                    armedAt = Date()
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard let start = anchor else {
                throw LogicianError.verificationFailed(
                    requested: "playback rolling from bar \(preRollBar) into bar \(first.bar)",
                    actual: sawPreRoll
                        ? "the transport rolled but never reached bar \(first.bar) within 20 s;"
                            + " nothing was written"
                        : "the position display never moved off the parked bar \(preRollBar)"
                            + " within 20 s, so no roll could be proved and nothing was written",
                    restored: false
                )
            }
            for (position, entry) in schedule.enumerated() {
                try checkCancelled()
                reportProgress(
                    "writing automation point \(position + 1)/\(schedule.count)",
                    percent: 30 + 40 * Double(position) / Double(schedule.count), throttle: 1
                )
                let wait = entry.ms / 1000 - Date().timeIntervalSince(start)
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                _ = try MCUBridge.send(.fader(channel: channel, value: entry.value))
            }
            // Latch has to SEE the last move before the transport stops. The
            // proof is Logic's own echo of that value coming back, which is a
            // positive check where the blind 0.5 s tail was a guess; the same
            // 0.5 s is the budget, not the price.
            if let last = schedule.last {
                _ = waitFor(seconds: 0.5) { status in
                    guard let faders = status["faders_14bit"] as? [Int],
                          faders.indices.contains(channel) else { return false }
                    return abs(faders[channel] - last.value) <= 40
                }
            }
            let passStop = stopForCleanup()
            report["transport_stop"] = passStop.payload
            appendWarning(passStop.warning, to: &report)
            try setAutomationMode("read", logic: logic, trackName: trackName)
            _ = try? MCUBridge.send(.fader(channel: channel, value: originalFader))
            reportProgress("pass complete; back in Read", percent: 72)
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
        report["calibration"] = calibrated.evidence
        report["armed_before_range"] = [
            "lead_ms": (armLeadMs * 10).rounded() / 10,
            "armed": armedAt != nil,
            "note": "Latch records from the touch, so the first value is sent this far before bar \(first.bar) beat 1 — that instant then holds the requested value, at the cost of overwriting the same fraction of a beat in front of the range."
        ]
        // WHERE THE SCHEDULE WAS TIMED FROM. Every breakpoint's position is
        // this bar plus an offset, so a caller auditing "did the curve land
        // where I asked" needs the anchor, not just the points. It can only
        // be `first.bar` now — the sync refuses anything else — and saying so
        // is what makes that guarantee visible instead of implied.
        report["roll_anchor"] = [
            "pre_roll_bar": preRollBar,
            "crossed_into_bar": anchoredAtBar ?? first.bar,
            "note": "The schedule was timed from the OBSERVED crossing into bar \(first.bar), taken only after the position display had moved off the parked bar \(preRollBar). Logic plays from its own last play-start position rather than the parked playhead (measured 2026-09-03), and a roll that begins at or past the range is refused rather than anchored — that is how a curve asked for at bars 2-4 was once written at bars 9-11 and verified there."
        ]

        if verify {
            // Replay in Read and sample Logic's own fader echo at each point.
            var samples: [[String: Any]] = []
            var anchor: Date?
            var parkFailure: String?
            do {
                _ = try logic.setPlayhead(barNumber: preRollBar, beat: 1)
                try awaitParkedBar(
                    preRollBar, operation: "the verification replay of bar \(first.bar)"
                )
            } catch {
                // The pass itself is done and reported; a verification that
                // could not park is an unverified result, never a lost write
                // and never a sample read at a position the park did not
                // reach.
                parkFailure = error.localizedDescription
            }
            if parkFailure == nil {
                // The parked reading again, for the same reason as the pass:
                // the first poll after the play press reads the display
                // Logic has not repainted yet, and a stale pre-roll sighting
                // is what let the replay confirm a curve written seven bars
                // away.
                let parkedReading = timecodeReading()
                _ = try? setPlaying(true)
                let syncDeadline = Date().addingTimeInterval(20)
                var sawPreRoll = false
                reportProgress("replaying in Read to verify", percent: 75)
                while Date() < syncDeadline {
                    try checkCancelled()
                    let reading = timecodeReading()
                    if case .beats(let bar, _, _, _) = reading,
                       rollHasLeftThePark(parked: parkedReading, observed: reading) {
                        switch rollSyncVerdict(
                            observedBar: bar, firstBar: first.bar, sawPreRoll: sawPreRoll
                        ) {
                        case .preRoll: sawPreRoll = true
                        case .crossed: anchor = Date()
                        case .startedPastRange:
                            // The same one-sided anchor bug would have made
                            // the replay confirm a curve written in the wrong
                            // bar. It reports instead.
                            parkFailure = "the replay rolled from bar \(bar), already at or past the range, so no sample could be trusted — Logic plays from its own last play-start position, not the parked playhead"
                        }
                        if anchor != nil || parkFailure != nil { break }
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if anchor == nil, parkFailure == nil {
                    parkFailure = sawPreRoll
                        ? "the replay rolled but never reached bar \(first.bar) within 20 s"
                        : "the position display never moved off the parked bar \(preRollBar) within 20 s, so no replay could be proved"
                }
            }
            if let start = anchor {
                for (position, point) in sorted.enumerated() {
                    try checkCancelled()
                    reportProgress(
                        "verifying point \(position + 1)/\(sorted.count)",
                        percent: 78 + 21 * Double(position) / Double(sorted.count), throttle: 1
                    )
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
            // The verify replay's own stop — chronologically the LAST one this
            // call presses, so it is what `transport_stop` reports when a
            // verify pass ran at all.
            let verifyStop = stopForCleanup()
            report["transport_stop"] = verifyStop.payload
            appendWarning(verifyStop.warning, to: &report)
            _ = try? MCUBridge.send(.fader(channel: channel, value: originalFader))
            let allPass = !samples.isEmpty && samples.allSatisfy { $0["pass"] as? Bool == true }
            report["verified"] = allPass
            var verification: [String: Any] = [
                "samples": samples,
                "note": "The range was replayed in Read mode and Logic's own motorized-fader echo sampled at each point (14-bit positions; tolerance 500 ≈ 1.5 dB near unity). The first point is sampled 0.25 s after its own moment, which the arming touch has already covered."
            ]
            if let parkFailure {
                verification["unavailable"] = parkFailure
                report["state"] = "recorded_unverified"
                // NOT "the curve was written", which is what this used to
                // say. The schedule was sent against a crossing the pass DID
                // verify (bar \(first.bar)); what no longer stands is the
                // independent second look, and a sentence that promises the
                // write is exactly the sentence that let a misplaced curve
                // read as a good one.
                report["verification_note"] = "The pass ran and the schedule was sent from the"
                    + " observed crossing into bar \(first.bar); the verification replay could"
                    + " NOT run (\(parkFailure)), so nothing looked at the lane afterwards and"
                    + " verified is false without a point having failed. Read the lane back with"
                    + " logic_read_automation — it parks the playhead instead of rolling, so it"
                    + " does not depend on where Logic starts playback."
            }
            report["verification"] = verification
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

    /// True when the daemon that owns the socket right now is old enough to
    /// still read the rightmost value cell literally. Cached: the answer only
    /// ever moves upward (a daemon is replaced by a newer one, never an older
    /// one), so a stale answer costs speed, never correctness.
    private static func daemonPredatesSignedRightmostCell() -> Bool {
        if let known = cachedDaemonProtocol { return known < 4 }
        guard let pong = try? MCUBridge.send(.ping), pong.ok else { return false }
        let version = pong.bridgeProtocol ?? 0
        cachedDaemonProtocol = version
        return version < 4
    }

    nonisolated(unsafe) static var cachedDaemonProtocol: Int? // single-threaded server loop

    /// In-bridge convergence: the whole adaptive tick loop runs next to the
    /// LCD mirror (3 ms echo polling instead of a socket round trip + fat
    /// await per tick). Returns nil when the bridge lacks the command — the
    /// callers all own a slower loop of their own, so nil is "do it here".
    static func fastConverge(
        index: Int, field: Int? = nil, target: Double,
        tolerance: Double = 0, maxMs: Int = 3000, seedRatio: Double? = nil
    ) -> (text: String, value: Double)? {
        // A daemon older than protocol 4 reads the RIGHTMOST value cell
        // without the sign Logic shifts into cell 6, so it mistakes its own
        // downward step for an upward one and runs to the end stop
        // (MCULCDRow.valueCell). Declining here hands the write back to the
        // caller's own loop, which reads through `lcdValueFields`.
        if (field ?? index) == MCULCDRow.cellCount - 1,
           daemonPredatesSignedRightmostCell() {
            debugLog("fastConverge declined on the rightmost cell: daemon protocol < 4")
            return nil
        }
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
        trackNumber: Int? = nil,
        kindLabel: String,
        points: [(bar: Int, beat: Double, value: Double)],
        ramp: Bool,
        verify: Bool,
        tolerance: Double,
        enterView: (Int) throws -> (read: () -> Double?, write: (Double, TimeInterval) throws -> Void),
        refreshView: (() throws -> Void)? = nil,
        restoreView: @escaping () -> Void,
        tempoMap: TempoMap? = nil,
        meterMap: MeterMap? = nil,
        meterKnowledge: MeterMap? = nil
    ) throws -> [String: Any] {
        let transport = try logic.getTransport()
        guard let tempo = transport["tempo"] as? Double else {
            throw LogicianError.trackNotExposed(
                requested: "tempo from the control bar", exposed: "not readable"
            )
        }
        let sorted = points.sorted { ($0.bar, $0.beat) < ($1.bar, $1.beat) }
        guard let first = sorted.first else {
            throw LogicianError.invalidArguments("points required: [{bar, beat?, value}, ...]")
        }
        let preRollBar = try automationPreRollBar(firstBar: first.bar)
        let beatsPerBar = automationBeatsPerBar(
            firstBar: first.bar, meterKnowledge: meterKnowledge,
            transportSignature: transport["time_signature"] as? String
        )
        let vpotHeaders = ((try? logic.parsedTrackHeaders()) ?? [])
            .map { TrackRowAddressing.Row(number: $0.number, name: $0.name) }
        guard let channel = try findChannel(
            trackName: trackName, trackNumber: trackNumber, headers: vpotHeaders
        ) else {
            throw automationChannelError(trackName: trackName, resolution: lastChannelResolution)
        }
        guard try selectFoundChannel(channel) else {
            throw LogicianError.writeFailed("MCU select failed")
        }
        // The same precondition as the volume pass, and for the same reason,
        // before a view is entered or a probe tick is turned: a strip with no
        // track header has no automation mode to press.
        _ = try requireAutomationModeConfirmable(logic: logic, trackName: trackName)
        // ARMED BEFORE THE VIEW IS ENTERED. `enterView` presses its way into a
        // send or plug-in view and can throw half way, and a restore
        // registered after it would not run for the view that failed to open —
        // the surface would be left in it.
        defer { restoreView() }
        let view = try enterView(channel)
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

        func offsetMs(_ bar: Int, _ beat: Double) -> Double {
            automationOffsetMs(
                bar: bar, beat: beat, firstBar: first.bar, beatsPerBar: beatsPerBar,
                tempo: tempo, map: tempoMap, meter: meterMap
            )
        }
        func localMsPerBeat(_ bar: Int, _ beat: Double) -> Double {
            automationMsPerBeat(
                bar: bar, beat: beat, beatsPerBar: beatsPerBar, tempo: tempo,
                map: tempoMap, meter: meterMap
            )
        }
        // Each entry carries the ms-per-beat in force at its own position, so the
        // subdivision step and the convergence budget below stay musical after
        // the ramp expansion has thrown the bar/beat away.
        var schedule: [(ms: Double, value: Double, msPerBeat: Double)] = sorted.map {
            (offsetMs($0.bar, $0.beat), $0.value, localMsPerBeat($0.bar, $0.beat))
        }
        if ramp && schedule.count > 1 {
            var expanded: [(Double, Double, Double)] = []
            for index in 0..<(schedule.count - 1) {
                let a = schedule[index], b = schedule[index + 1]
                expanded.append(a)
                // 1 delvärde/slag, at the tempo in force where the segment starts.
                let steps = max(Int((b.ms - a.ms) / a.msPerBeat), 1)
                if steps > 1 {
                    for s in 1..<steps {
                        let t = Double(s) / Double(steps)
                        expanded.append((
                            a.ms + (b.ms - a.ms) * t,
                            a.value + (b.value - a.value) * t,
                            a.msPerBeat
                        ))
                    }
                }
            }
            expanded.append(schedule[schedule.count - 1])
            schedule = expanded
        }

        reportProgress("arming latch automation", percent: 15)
        try setAutomationMode("latch", logic: logic, trackName: trackName)
        // The pass's own cleanup stop, captured here (declared before the
        // `do` since `report` below is not in scope yet) rather than
        // discarded through `try?`.
        var passStop: (payload: [String: Any], warning: String?)?
        do {
            _ = try logic.setPlayhead(barNumber: preRollBar, beat: 1)
            // The parked bar is asserted, not assumed: this whole pass is
            // timed from roll start, so a transport that starts anywhere else
            // writes the curve in the wrong bar (see `rollSyncVerdict`).
            // Waiting for the display to show the parked bar also replaces the
            // blind 0.5 s that used to sit here.
            try awaitParkedBar(
                preRollBar, operation: "\(kindLabel) automation from bar \(first.bar)"
            )
            let parkedTimecode = freshStatus()?["timecode"] as? String
            guard (try? setPlaying(true)) != nil else {
                throw LogicianError.writeFailed("play failed")
            }
            // Anchor at ROLL START (the parked bar), not at the first point's
            // bar crossing: the whole pre-roll bar is then usable for the
            // first point's convergence lead.
            let syncDeadline = Date().addingTimeInterval(20)
            var anchor: Date?
            reportProgress("rolling; waiting for the transport to move", percent: 25)
            while Date() < syncDeadline {
                // The `catch` below stops the transport, restores Read mode and
                // puts the vpot back on its original value, so a cancellation
                // unwinds exactly like a failed sync.
                try checkCancelled()
                if let timecode = freshStatus()?["timecode"] as? String,
                   timecode != parkedTimecode {
                    // The transport moved — but from WHERE. A roll that began
                    // at or past the range cannot be the pre-roll this
                    // schedule is measured from, and accepting it would write
                    // the whole curve at the wrong position.
                    if let bar = timecodeBar(),
                       rollSyncVerdict(
                           observedBar: bar, firstBar: first.bar, sawPreRoll: false
                       ) == .startedPastRange {
                        throw rollStartedPastRangeError(
                            observedBar: bar, firstBar: first.bar, restored: true
                        )
                    }
                    anchor = Date()
                    break
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard let start = anchor else {
                throw LogicianError.verificationFailed(
                    requested: "playback rolling from bar \(preRollBar)",
                    actual: "the timecode never moved", restored: false
                )
            }
            // One bar before the first point — the length of THAT bar, which
            // under a tempo map is not the length of any other bar. `offsetMs`
            // is measured from the first point, so the pre-roll bar is its
            // negative offset.
            let preRollMs = abs(offsetMs(preRollBar, 1))
            for (position, entry) in schedule.enumerated() {
                // Vpot convergence takes time — lead each write so the curve
                // centers on the musical moment instead of trailing it. The
                // FIRST point gets a long lead and a full budget: an existing
                // lane can start playback far from the target (overriding the
                // pre-parked static value), and the anchor must be converged
                // BEFORE its moment arrives.
                try checkCancelled()
                reportProgress(
                    "writing automation point \(position + 1)/\(schedule.count)",
                    percent: 30 + 40 * Double(position) / Double(schedule.count), throttle: 1
                )
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
                // The middle points' budget is half a beat AT THIS POINT's tempo.
                try view.write(entry.value,
                               isFirst ? 1.0 : (isLast ? 1.5 : max(0.15, min(0.6, entry.msPerBeat / 2000))))
            }
            Thread.sleep(forTimeInterval: 0.5)
            passStop = stopForCleanup()
            try setAutomationMode("read", logic: logic, trackName: trackName)
            try view.write(original, 2.0)
            reportProgress("pass complete; back in Read", percent: 72)
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
        report["transport_stop"] = passStop?.payload
            ?? ["unavailable": "the cleanup stop was never reached"]
        appendWarning(passStop?.warning, to: &report)
        if verify {
            // The automation-mode button presses can knock the surface out of
            // the working view — re-enter it before reading anything.
            try refreshView?()
            // Playhead-chase verification: parked in Read mode, Logic chases
            // the automation lane to the playhead position — stationary,
            // exact reads with no live-LCD lag, and no realtime replay.
            var samples: [[String: Any]] = []
            reportProgress("chasing the playhead to verify", percent: 75)
            for (position, point) in sorted.enumerated() {
                try checkCancelled()
                reportProgress(
                    "verifying point \(position + 1)/\(sorted.count)",
                    percent: 78 + 21 * Double(position) / Double(sorted.count), throttle: 1
                )
                let beat = max(Int(point.beat.rounded()), 1)
                // The park's RESULT decides whether this sample means
                // anything. It used to be `try?`, so a park that never landed
                // was followed by a read at whatever position the playhead was
                // actually at, reported under the bar and beat that had been
                // ASKED for. Same rule, same primitive and same words as
                // `logic_read_automation`'s park-and-prove: the position the
                // playhead REACHED is what the sample is filed under, with the
                // requested one beside it when they differ.
                let requested = AutomationSamplePosition(bar: point.bar, beat: beat)
                var parkFailure: String?
                do {
                    _ = try logic.setPlayhead(barNumber: point.bar, beat: beat)
                } catch {
                    parkFailure = error.localizedDescription
                }
                Thread.sleep(forTimeInterval: 0.8)
                let observed = parkFailure == nil ? view.read() : nil
                switch automationSampleVerdict(
                    requested: requested, parkFailure: parkFailure,
                    landed: timecodeBarBeat().map {
                        AutomationSamplePosition(bar: $0.bar, beat: $0.beat)
                    }
                ) {
                case .omit(let reason):
                    samples.append([
                        "bar": point.bar, "beat": point.beat,
                        "expected": point.value,
                        "observed": NSNull() as Any,
                        "pass": false,
                        "unavailable": reason
                    ])
                case .report(let bar, let beat, let confirmed, let elsewhere):
                    var sample: [String: Any] = [
                        "bar": bar, "beat": beat,
                        "expected": point.value,
                        "observed": observed.map { $0 as Any } ?? NSNull() as Any,
                        // A value read at a position nobody asked for verifies
                        // nothing about the point, however well it matches.
                        "pass": !elsewhere
                            && (observed.map { abs($0 - point.value) <= tolerance } ?? false)
                    ]
                    if !confirmed { sample["position_confirmed"] = false }
                    if elsewhere {
                        sample["requested_bar"] = point.bar
                        sample["requested_beat"] = point.beat
                    }
                    samples.append(sample)
                }
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
