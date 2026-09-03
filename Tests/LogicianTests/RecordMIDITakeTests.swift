import XCTest
@testable import Logician

/// The four decisions `logic_record_midi` makes around the recording itself.
/// All pure, all wrong until 2026-09-02, and not one of them visible from
/// watching Logic:
///
/// * the SHUTDOWN silenced the MIDI stream before it stopped the transport, so
///   the all-notes-off blast went into the port Logic was recording FROM and a
///   two-note take read back as eighteen events;
/// * the SYNC took the pre-roll bar's beat count from the signature at the
///   PLAYHEAD, so a take at bar 2 fell into the uncompensated branch whenever
///   the user had left the playhead in a bar of a different length;
/// * the PARK paid for Logic's count-in bar on top of its own pre-roll bar;
/// * the RESULT named no region, so an agent could not take its own take back.
final class RecordMIDITakeTests: XCTestCase {

    private func meter(_ events: [(Int, Int, Int)]) -> MeterMap {
        MeterMap(
            events: events.map { MeterEvent(bar: $0.0, numerator: $0.1, denominator: $0.2) },
            source: .signatureList
        )!
    }

    // MARK: D1 — the shutdown's order

    func testConfirmedStopIsWhatLicencesTheSilence() {
        let shutdown = MIDITakePlan.shutdown(recordingStopped: true)
        XCTAssertTrue(shutdown.silence)
        XCTAssertEqual(shutdown.state, "stopped_then_silenced")
        XCTAssertNil(shutdown.warning)
    }

    /// The blast is CC123 + CC64=0 on sixteen channels into the record port. If
    /// Logic cannot be confirmed out of record, sending it writes sixteen
    /// sustain events into the user's region — so it is not sent, and the
    /// result says so instead of going quiet.
    func testUnconfirmedStopWithholdsTheSilenceAndWarns() {
        let shutdown = MIDITakePlan.shutdown(recordingStopped: false)
        XCTAssertFalse(shutdown.silence)
        XCTAssertEqual(shutdown.state, "stop_unconfirmed")
        let warning = shutdown.warning ?? ""
        XCTAssertTrue(warning.contains("was NOT sent"), warning)
        XCTAssertTrue(warning.contains("sixteen sustain"), warning)
        XCTAssertTrue(warning.lowercased().contains("press stop"), warning)
    }

    // MARK: N4 — where the playhead parks

    func testCountInProvidesThePreRollBar() {
        let park = MIDITakePlan.park(startBar: 9, countIn: true)
        XCTAssertEqual(park.bar, 9, "with Logic counting in, the park is ON start_bar")
        XCTAssertEqual(park.preRollBar, 8, "the sync still watches the bar before start_bar")
        XCTAssertEqual(park.route, "logic_count_in")
    }

    func testWithoutCountInTheToolParksItsOwnPreRollBar() {
        let park = MIDITakePlan.park(startBar: 9, countIn: false)
        XCTAssertEqual(park.bar, 8)
        XCTAssertEqual(park.preRollBar, 8)
        XCTAssertEqual(park.route, "own_pre_roll")
    }

    /// An unreadable flag takes the SAFE route, not the cheap one: guessing
    /// count-in ON when it is off leaves the sync no bar to observe at all.
    func testUnreadableCountInKeepsTheOwnPreRollBar() {
        let park = MIDITakePlan.park(startBar: 2, countIn: nil)
        XCTAssertEqual(park.bar, 1)
        XCTAssertEqual(park.route, "own_pre_roll")
        XCTAssertTrue(park.note.contains("could not be read"), park.note)
    }

    // MARK: D2 — the compensation, per branch

    func testBeatEdgeSchedulesTheLeadMinusTheMeasuredLatency() {
        let plan = MIDITakePlan.syncPlan(
            branch: .beatEdge, leadMs: 500,
            compensationMs: MIDITakePlan.defaultCompensationMs(
                route: "own_pre_roll", positionExact: false
            )
        )
        XCTAssertEqual(plan.branch, "beat_edge")
        // 500 - 23. The shipped 45 gave 455, which measured 21.5 ms EARLY,
        // 2/2 takes — the arithmetic that fixes it is this subtraction.
        XCTAssertEqual(plan.shiftMs, 477, accuracy: 1e-9)
        XCTAssertEqual(plan.compensationApplied ?? -1, 23, accuracy: 1e-9)
    }

    /// A READ position needs no latency constant; an ASSUMED beat does, and
    /// then it differs by route — measured 2026-09-02, the edge is ~23 ms
    /// behind inside a pre-roll bar this tool parked and ~46 ms behind inside
    /// Logic's count-in bar.
    func testTheCompensationDefaultFollowsWhatWasActuallyKnown() {
        // A computed lead leaves only the send path's own latency, which
        // measured 16.1 / 17.2 / 20.3 ms late with nothing subtracted.
        XCTAssertEqual(
            MIDITakePlan.defaultCompensationMs(route: "logic_count_in", positionExact: true), 18
        )
        XCTAssertEqual(
            MIDITakePlan.defaultCompensationMs(route: "own_pre_roll", positionExact: true), 18,
            "a read position is a read position whichever bar it was read in"
        )
        XCTAssertEqual(
            MIDITakePlan.defaultCompensationMs(route: "own_pre_roll", positionExact: false), 23
        )
        XCTAssertEqual(
            MIDITakePlan.defaultCompensationMs(route: "logic_count_in", positionExact: false), 46
        )
        XCTAssertEqual(
            MIDITakePlan.defaultCompensationMs(
                route: MIDITakePlan.park(startBar: 2, countIn: true).route, positionExact: false
            ),
            46,
            "the park decision and the compensation must read the same route"
        )
    }

    func testTheOldSingleDefaultWasWrongForTheRouteTheToolTook() {
        let old = MIDITakePlan.syncPlan(branch: .beatEdge, leadMs: 500, compensationMs: 45)
        let now = MIDITakePlan.syncPlan(
            branch: .beatEdge, leadMs: 500,
            compensationMs: MIDITakePlan.defaultCompensationMs(
                route: "own_pre_roll", positionExact: false
            )
        )
        XCTAssertEqual(now.shiftMs - old.shiftMs, 22, accuracy: 1e-9,
                       "the take moves 22 ms later, which is the 21.5 ms it measured early")
    }

    // MARK: D2 — the lead is READ off the display, not assumed to be a beat

    /// `BBB bb dd ttt`: division is the sixteenth of the beat (1-4), ticks the
    /// tick inside it (1-240), 960 to a beat. Assuming a whole beat put five
    /// takes anywhere from 22.9 ms early to 23.4 ms late; the digits say how
    /// far past the edge the repaint was.
    func testBeatsRemainingReadsTheSubBeatDigits() {
        // Exactly on beat 4's line of a 4/4 bar: one whole beat left.
        XCTAssertEqual(
            MIDITakePlan.beatsRemainingInBar(beat: 4, division: 1, ticks: 1, beatsInBar: 4) ?? -1,
            1, accuracy: 1e-9
        )
        // A quarter of the way into it: three quarters of a beat left.
        XCTAssertEqual(
            MIDITakePlan.beatsRemainingInBar(beat: 4, division: 2, ticks: 1, beatsInBar: 4) ?? -1,
            0.75, accuracy: 1e-9
        )
        // The last tick before the bar line.
        XCTAssertEqual(
            MIDITakePlan.beatsRemainingInBar(beat: 4, division: 4, ticks: 240, beatsInBar: 4) ?? -1,
            1.0 / 960, accuracy: 1e-9
        )
        // A 5/4 pre-roll bar, seen on its fifth beat.
        XCTAssertEqual(
            MIDITakePlan.beatsRemainingInBar(beat: 5, division: 1, ticks: 1, beatsInBar: 5) ?? -1,
            1, accuracy: 1e-9
        )
    }

    /// Logic blanks those digits on some paints, and a blanked field must not
    /// be read as "tick 0" — that would claim a beat and a bit of lead.
    func testBlankedSubBeatDigitsAreNotAPosition() {
        XCTAssertNil(MIDITakePlan.beatsRemainingInBar(
            beat: 4, division: 0, ticks: 0, beatsInBar: 4
        ))
        XCTAssertNil(MIDITakePlan.beatsRemainingInBar(
            beat: 4, division: 1, ticks: 0, beatsInBar: 4
        ))
        XCTAssertNil(MIDITakePlan.beatsRemainingInBar(
            beat: 5, division: 1, ticks: 1, beatsInBar: 4
        ), "a beat outside the bar is not a position in it")
    }

    func testTheReportedNoteSaysWhetherThePositionWasReadOrAssumed() {
        let read = MIDITakePlan.syncPlan(
            branch: .beatEdge, leadMs: 375, compensationMs: 18, positionExact: true
        )
        XCTAssertEqual(read.shiftMs, 357, accuracy: 1e-9)
        XCTAssertTrue(read.note.contains("exact position"), read.note)
        let uncompensated = MIDITakePlan.syncPlan(
            branch: .beatEdge, leadMs: 375, compensationMs: 0, positionExact: true
        )
        XCTAssertEqual(uncompensated.shiftMs, 375, accuracy: 1e-9)
        XCTAssertFalse(uncompensated.note.contains("minus"), uncompensated.note)
        let assumed = MIDITakePlan.syncPlan(
            branch: .beatEdge, leadMs: 500, compensationMs: 46, positionExact: false
        )
        XCTAssertEqual(assumed.shiftMs, 454, accuracy: 1e-9)
        XCTAssertTrue(assumed.note.contains("ASSUMED"), assumed.note)
        XCTAssertTrue(assumed.note.contains("23 ms either side"), assumed.note)
    }

    /// The knob is documented "raise if notes land early, lower if late" and
    /// was INERT on the branch where the notes land late: `max(0, 0 - x)` is 0
    /// for every x. It now says so rather than pretending to apply.
    func testBarLineBranchHasNothingToCompensateAndSaysSo() {
        for compensation in [0.0, 23.0, 45.0, 500.0] {
            let plan = MIDITakePlan.syncPlan(
                branch: .barLine, leadMs: 0, compensationMs: compensation
            )
            XCTAssertEqual(plan.branch, "bar_line")
            XCTAssertEqual(plan.shiftMs, 0, accuracy: 1e-9)
            XCTAssertNil(plan.compensationApplied,
                         "no compensation was applied, so none is claimed")
            XCTAssertTrue(plan.note.contains("does NOT apply"), plan.note)
            XCTAssertTrue(plan.note.contains("39 ms late"), plan.note)
        }
    }

    func testACompensationLargerThanTheLeadIsReportedAsWhatWasApplied() {
        let plan = MIDITakePlan.syncPlan(branch: .beatEdge, leadMs: 100, compensationMs: 400)
        XCTAssertEqual(plan.shiftMs, 0, accuracy: 1e-9)
        XCTAssertEqual(plan.compensationApplied ?? -1, 100, accuracy: 1e-9,
                       "the clamp ate 300 ms of it; the result must not claim 400 was used")
    }

    // MARK: D3 — the pre-roll bar's beat count comes from the METER MAP

    /// The sandbox's shape: 4/4 from bar 1, 5/4 from bar 41. A take at bar 2
    /// with the playhead parked at bar 41 got `beatsPerBar` 5 off the control
    /// bar, waited for a fifth beat of bar 1, never saw one, and fell into the
    /// bar-line branch. The map answers about bar 1 instead.
    func testPreRollBeatsComeFromTheMapNotFromTheSignatureAtThePlayhead() {
        let map = meter([(1, 4, 4), (41, 5, 4)])
        XCTAssertEqual(
            MCUController.automationBeatSlots(inBar: 1, meter: map, fallback: 5), 4,
            "the control bar's 5/4 at bar 41 must not decide bar 1's last beat"
        )
        XCTAssertEqual(MCUController.automationBeatSlots(inBar: 41, meter: map, fallback: 4), 5)
    }

    /// With no map readable the caller's scalar is still the fallback — that is
    /// the assumption this server has always documented, and it is better than
    /// refusing a take.
    func testNoMapFallsBackToTheCallersScalar() {
        XCTAssertEqual(MCUController.automationBeatSlots(inBar: 3, meter: nil, fallback: 3), 3)
        XCTAssertEqual(MCUController.automationBeatSlots(inBar: 3, meter: nil, fallback: 0), 1)
    }

    // MARK: D4 — the region the call leaves behind

    /// The measured take: two notes in bar 2 (beats 1 and 3, one beat each) at
    /// 120 BPM 4/4. `takeEnd` says bar 3 and the region measured bars 2-4,
    /// because Logic records through the 600 ms tail (1.2 beats at 120).
    func testRecordedEndBarIsPastTheTakesLastEvent() {
        let take = MCPServer.takeEnd(
            startBar: 2, beatsPerBar: 4,
            notes: [(bar: 2, beat: 1, durationBeats: 1), (bar: 2, beat: 3, durationBeats: 1)],
            extraEventBars: []
        )
        XCTAssertEqual(take.lastBeat, 3, accuracy: 1e-9)
        XCTAssertEqual(take.endBar, 3, "where the take's events end")
        XCTAssertEqual(
            MIDITakePlan.recordedEndBar(
                startBar: 2, lastBeat: take.lastBeat, tailBeats: 600 / (60000.0 / 120),
                beatsPerBar: 4, meterMap: nil
            ),
            4,
            "where the REGION ends, which is what logic_delete_region has to address around"
        )
    }

    func testRecordedEndBarIsAtLeastOneBar() {
        XCTAssertEqual(
            MIDITakePlan.recordedEndBar(
                startBar: 5, lastBeat: 0.25, tailBeats: 0, beatsPerBar: 4, meterMap: nil
            ),
            6
        )
    }

    /// Under a changing meter "how many bars is this many beats" is a walk, not
    /// a division — the same reason `takeEnd` honours the map.
    func testRecordedEndBarWalksAVaryingMeter() {
        let map = meter([(1, 4, 4), (3, 7, 8)])
        // Bars 1 and 2 are four quarter-note beats, bar 3 onwards three and a
        // half (7/8, which is what Logic's BPM counts). A take from bar 2
        // running 7.5 beats fills bar 2 and bar 3 exactly.
        XCTAssertEqual(
            MIDITakePlan.recordedEndBar(
                startBar: 2, lastBeat: 4, tailBeats: 3.5, beatsPerBar: 4, meterMap: map
            ),
            4
        )
        // Half a beat further and it spills into bar 4 — where the single
        // division a constant meter would have used still answers bar 4.
        XCTAssertEqual(
            MIDITakePlan.recordedEndBar(
                startBar: 2, lastBeat: 4, tailBeats: 4, beatsPerBar: 4, meterMap: map
            ),
            5
        )
        XCTAssertEqual(
            MIDITakePlan.recordedEndBar(
                startBar: 2, lastBeat: 4, tailBeats: 4, beatsPerBar: 4, meterMap: nil
            ),
            4,
            "the constant-meter division is what the walk exists to replace"
        )
    }

    // MARK: The playhead restore's own verdict (2026-09-03)

    /// Live 2026-09-02/03: a take from bar 1 with the playhead found at bar 56
    /// left it at bar 56 beat 3 (the bar came back, the beat never did — the
    /// old `defer` restored `barNumber: bar, beat: nil`) and, once the
    /// verification render's own playhead jump piled on top, at bar 5 beat 4
    /// — nowhere near 56 — with `verified: true` and no warning either time.
    /// These pin the three-state shape `PlayheadRestoreReport.payload` owes
    /// the result, exactly the contract `logic_render_track` already reports
    /// via `restorePlayheadReport` — pure, no Logic session needed.
    func testPlayheadAlreadyAtBaselineNeedsNoWrite() {
        // No write ATTEMPTED — the caller's own "before" read already matched
        // `saved`, exactly the free path `restorePlayheadOnce` takes when the
        // take started where the playhead already was.
        let report = PlayheadRestoreReport.payload(
            saved: (bar: 56, beat: 1), current: (bar: 56, beat: 1),
            attempted: false, wroteSuccessfully: false
        )
        XCTAssertEqual(report["restored"] as? Bool, true)
        XCTAssertEqual(report["verified"] as? Bool, true)
        XCTAssertEqual(report["state"] as? String, "already_at_baseline")
        XCTAssertEqual(report["bar"] as? Int, 56)
        XCTAssertEqual(report["beat"] as? Int, 1)
        XCTAssertNil(report["note"], "nothing moved, so there is nothing to explain")
        XCTAssertNil(report["left_at"])
    }

    func testPlayheadRestoredAfterAWriteThatMovedIt() {
        // `attempted: true` is what distinguishes THIS from the baseline case
        // above — both read `current == saved` after the fact, but only one
        // of them cost a write. `state: "restored"` names the move.
        let report = PlayheadRestoreReport.payload(
            saved: (bar: 56, beat: 1), current: (bar: 56, beat: 1),
            attempted: true, wroteSuccessfully: true
        )
        XCTAssertEqual(report["restored"] as? Bool, true)
        XCTAssertEqual(report["verified"] as? Bool, true)
        XCTAssertEqual(report["state"] as? String, "restored")
        XCTAssertEqual(report["bar"] as? Int, 56)
        XCTAssertEqual(report["beat"] as? Int, 1)
        XCTAssertNotNil(report["note"], "a real move is explained, unlike the free no-op")
    }

    func testPlayheadNotRestoredWhenTheWriteThrows() throws {
        // The write itself threw (`try? logic.setPlayhead` returned nil) and
        // the take's own stop left the playhead at bar 5 beat 4 — the exact
        // live reading the verification render's un-restored jump produced.
        let report = PlayheadRestoreReport.payload(
            saved: (bar: 56, beat: 1), current: (bar: 5, beat: 4),
            attempted: true, wroteSuccessfully: false
        )
        XCTAssertEqual(report["restored"] as? Bool, false)
        XCTAssertEqual(report["verified"] as? Bool, false)
        XCTAssertEqual(report["state"] as? String, "not_restored")
        XCTAssertEqual(report["bar"] as? Int, 56, "what was ASKED for, not where it ended up")
        XCTAssertEqual(report["beat"] as? Int, 1)
        let leftAt = report["left_at"] as? [String: Any]
        XCTAssertEqual(leftAt?["bar"] as? Int, 5)
        XCTAssertEqual(leftAt?["beat"] as? Int, 4)
        let note = try XCTUnwrap(report["note"] as? String)
        XCTAssertTrue(note.contains("bar 56 beat 1"))
        XCTAssertTrue(note.contains("bar 5 beat 4"))
        XCTAssertTrue(note.contains("logic_set_playhead"), "names the fix, not just the failure")
    }

    func testPlayheadNotRestoredWhenEvenTheReadbackFails() {
        // The write threw AND the follow-up read could not say where the
        // playhead ended up either — `left_at` must publish nulls, never
        // silently drop the key (house style: no `{}` where `{unavailable:
        // reason}` belongs).
        let report = PlayheadRestoreReport.payload(
            saved: (bar: 56, beat: 1), current: nil, attempted: true, wroteSuccessfully: false
        )
        XCTAssertEqual(report["state"] as? String, "not_restored")
        let leftAt = report["left_at"] as? [String: Any]
        XCTAssertTrue(leftAt?["bar"] is NSNull)
        XCTAssertTrue(leftAt?["beat"] is NSNull)
        let note = report["note"] as? String ?? ""
        XCTAssertTrue(note.contains("unreadable position"), note)
    }

    func testPlayheadNotRestoredWhenTheWriteSucceedsButTheReadbackDisagrees() {
        // `setPlayhead` did not throw, but the fresh read afterwards is NOT
        // where it was asked to go — the write is not trusted on its own say-
        // so, exactly like `restorePlayheadReport`'s render_track contract.
        let report = PlayheadRestoreReport.payload(
            saved: (bar: 56, beat: 1), current: (bar: 55, beat: 4),
            attempted: true, wroteSuccessfully: true
        )
        XCTAssertEqual(report["restored"] as? Bool, false)
        XCTAssertEqual(report["state"] as? String, "not_restored")
        let leftAt = report["left_at"] as? [String: Any]
        XCTAssertEqual(leftAt?["bar"] as? Int, 55)
        XCTAssertEqual(leftAt?["beat"] as? Int, 4)
    }
}
