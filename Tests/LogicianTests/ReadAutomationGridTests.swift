import XCTest
@testable import Logician

/// The three pieces of `logic_read_automation` that decide whether a reported
/// value belongs to the bar/beat it is reported under. All pure, and all of
/// them wrong until 2026-09-02:
///
/// * the GRID took its bar lengths from the signature at the playhead, so a
///   read of bars 2-4 asked for "bar 2 beat 5" whenever the playhead happened
///   to sit in a 5/4 bar;
/// * the SAMPLE DECISION did not exist — a failed park was discarded by a
///   `try?` and the lane's value at wherever the playhead stood was appended
///   under the position that had been asked for;
/// * the END BAR was dropped whenever the resolution overshot it, on a tool
///   whose description promised the range is never truncated.
///
/// None of these can be caught by watching Logic: every one of them produces a
/// plausible-looking curve rather than a visible failure.
final class ReadAutomationGridTests: XCTestCase {

    private func map(_ events: [(Int, Int, Int)]) -> MeterMap {
        MeterMap(
            events: events.map { MeterEvent(bar: $0.0, numerator: $0.1, denominator: $0.2) },
            source: .signatureList
        )!
    }

    private func grid(
        _ startBar: Int, _ endBar: Int, resolution: Int = 1, maxPoints: Int = 64,
        meter: MeterMap? = nil, fallback: Int = 4
    ) -> MCUController.AutomationSampleGrid {
        MCUController.automationSampleGrid(
            startBar: startBar, endBar: endBar, resolutionBeats: resolution,
            maxPoints: maxPoints,
            beatSlots: {
                MCUController.automationBeatSlots(inBar: $0, meter: meter, fallback: fallback)
            }
        )
    }

    private func labels(_ grid: MCUController.AutomationSampleGrid) -> [String] {
        grid.positions.map { "\($0.bar).\($0.beat)" }
    }

    // MARK: - D2: the grid follows the meter map, bar by bar

    /// The sandbox's own shape: 4/4 from bar 1, 5/4 from bar 41. A read that
    /// crosses the boundary gets four beats in bar 40 and five in bar 41 — and
    /// no beat 5 anywhere before bar 41, which is the position the old grid
    /// asked the playhead for and never reached.
    func testTheGridTakesEachBarsOwnMeterAcrossASignatureChange() {
        let meter = map([(1, 4, 4), (41, 5, 4)])
        XCTAssertEqual(
            labels(grid(40, 42, meter: meter)),
            ["40.1", "40.2", "40.3", "40.4", "41.1", "41.2", "41.3", "41.4", "41.5", "42.1"]
        )
    }

    func testNoBeatFiveIsEverAskedForInAFourBeatBar() {
        let meter = map([(1, 4, 4), (41, 5, 4)])
        let positions = grid(2, 6, meter: meter).positions
        XCTAssertFalse(positions.isEmpty)
        for position in positions {
            XCTAssertLessThanOrEqual(
                position.beat,
                MCUController.automationBeatSlots(inBar: position.bar, meter: meter, fallback: 4),
                "bar \(position.bar) beat \(position.beat) does not exist"
            )
        }
    }

    /// The bug's exact ingredients: the playhead sat at bar 41 (5/4) and the
    /// control bar answered "5", so the FALLBACK path — the only one left when
    /// the Signature List cannot be read — is the one that can still build an
    /// impossible grid. It is a fallback the result names, and the first park
    /// refuses the call; what it must not do is silently disagree with a map
    /// that IS readable.
    func testAFallbackReadingAtThePlayheadNoLongerDecidesTheGrid() {
        let meter = map([(1, 4, 4), (41, 5, 4)])
        XCTAssertEqual(labels(grid(2, 3, meter: meter, fallback: 5)),
                       ["2.1", "2.2", "2.3", "2.4", "3.1"])
        // Without a map, the caller's reading is all there is.
        XCTAssertEqual(labels(grid(2, 3, meter: nil, fallback: 5)),
                       ["2.1", "2.2", "2.3", "2.4", "2.5", "3.1"])
    }

    func testBeatSlotsAreTheNumeratorInForceAtTheBar() {
        let meter = map([(1, 4, 4), (9, 3, 4), (17, 6, 8)])
        XCTAssertEqual(MCUController.automationBeatSlots(inBar: 1, meter: meter, fallback: 4), 4)
        XCTAssertEqual(MCUController.automationBeatSlots(inBar: 8, meter: meter, fallback: 4), 4)
        XCTAssertEqual(MCUController.automationBeatSlots(inBar: 9, meter: meter, fallback: 4), 3)
        XCTAssertEqual(MCUController.automationBeatSlots(inBar: 16, meter: meter, fallback: 4), 3)
        // 6/8 has SIX beat slots on the position display even though it is
        // three quarter-note beats of bar math.
        XCTAssertEqual(MCUController.automationBeatSlots(inBar: 20, meter: meter, fallback: 4), 6)
        XCTAssertEqual(meter.beatsPerBar(atBar: 20), 3.0)
    }

    func testTheMeterChangesInsideARangeAreReported() {
        let meter = map([(1, 4, 4), (41, 5, 4), (60, 4, 4)])
        let changes = MCUController.automationMeterChanges(startBar: 39, endBar: 42, meter: meter)
        XCTAssertEqual(changes.map(\.bar), [41])
        XCTAssertEqual(changes.map(\.signature), ["5/4"])
        // The signature in force AT start_bar is not a change inside the range.
        XCTAssertTrue(
            MCUController.automationMeterChanges(startBar: 41, endBar: 45, meter: meter).isEmpty
        )
        XCTAssertTrue(
            MCUController.automationMeterChanges(startBar: 2, endBar: 2, meter: meter).isEmpty
        )
    }

    // MARK: - D4: end_bar is always sampled

    /// The measured defect: `{start 2, end 3, resolution 5}` came back with ONE
    /// point, at bar 2 beat 1, and bar 3 was never sampled at all.
    func testAResolutionWiderThanTheRangeStillSamplesTheEndBar() {
        let result = grid(2, 3, resolution: 5)
        XCTAssertEqual(labels(result), ["2.1", "3.1"])
        XCTAssertTrue(result.endBarSampled)
        XCTAssertEqual(result.stepBeats, 5)
        // The last hop is SHORTER than the step, and the number says so.
        XCTAssertEqual(result.finalIntervalBeats, 4)
    }

    func testAnUnevenStepKeepsTheEndBarAndReportsTheShortLastHop() {
        let result = grid(1, 4, resolution: 5)
        XCTAssertEqual(labels(result), ["1.1", "2.2", "3.3", "4.1"])
        XCTAssertEqual(result.stepBeats, 5)
        XCTAssertEqual(result.finalIntervalBeats, 2)
        XCTAssertTrue(result.endBarSampled)
    }

    func testAnEvenStepReportsTheSameFinalInterval() {
        let result = grid(2, 4, resolution: 2)
        XCTAssertEqual(labels(result), ["2.1", "2.3", "3.1", "3.3", "4.1"])
        XCTAssertEqual(result.stepBeats, 2)
        XCTAssertEqual(result.finalIntervalBeats, 2)
    }

    func testMaxPointsWidensTheStepAndStillReachesTheEndBar() {
        for maxPoints in 2...12 {
            let result = grid(1, 9, maxPoints: maxPoints)
            XCTAssertLessThanOrEqual(result.positions.count, maxPoints)
            XCTAssertEqual(result.positions.first,
                           MCUController.AutomationSamplePosition(bar: 1, beat: 1))
            XCTAssertEqual(result.positions.last,
                           MCUController.AutomationSamplePosition(bar: 9, beat: 1))
            XCTAssertTrue(result.endBarSampled)
        }
    }

    /// The one case where the end genuinely cannot be reached — and it is
    /// reported rather than passed off as a sampled range.
    func testMaxPointsOfOneCannotSpanARangeAndSaysSo() {
        let result = grid(2, 6, maxPoints: 1)
        XCTAssertEqual(labels(result), ["2.1"])
        XCTAssertFalse(result.endBarSampled)
        // A one-bar range IS fully sampled by one point.
        XCTAssertTrue(grid(2, 2, maxPoints: 1).endBarSampled)
    }

    func testASingleBarRangeIsOnePositionAndCountsAsComplete() {
        let result = grid(3, 3)
        XCTAssertEqual(labels(result), ["3.1"])
        XCTAssertTrue(result.endBarSampled)
        XCTAssertEqual(result.finalIntervalBeats, 0)
    }

    func testNonsenseRangesYieldNoGridRatherThanAGuess() {
        XCTAssertTrue(grid(8, 4).positions.isEmpty)
        XCTAssertTrue(grid(0, 4).positions.isEmpty)
        XCTAssertTrue(grid(1, 4, maxPoints: 0).positions.isEmpty)
        // A bar the meter cannot describe stops the grid rather than dividing
        // the range by a zero-length bar.
        XCTAssertTrue(MCUController.automationSampleGrid(
            startBar: 1, endBar: 4, resolutionBeats: 1, maxPoints: 64, beatSlots: { _ in 0 }
        ).positions.isEmpty)
        // The slot lookup itself never hands one out: a bar has at least one
        // beat, whatever the caller's fallback reading said.
        XCTAssertEqual(MCUController.automationBeatSlots(inBar: 3, meter: nil, fallback: 0), 1)
        XCTAssertTrue(MCUController.automationSamplePositions(
            startBar: 1, endBar: 4, beatsPerBar: 0, resolutionBeats: 1, maxPoints: 64
        ).isEmpty)
    }

    // MARK: - D1: the park is proven before the value is attributed

    func testAFailedParkOmitsTheSampleRatherThanRelabellingIt() {
        let verdict = MCUController.automationSampleVerdict(
            requested: .init(bar: 2, beat: 5),
            parkFailure: #"requested "beat 5", actual "beat 1""#,
            landed: .init(bar: 4, beat: 1)
        )
        guard case .omit(let reason) = verdict else {
            return XCTFail("a failed park must not become a sample: \(verdict)")
        }
        XCTAssertTrue(reason.contains("bar 2 beat 5"))
        XCTAssertTrue(reason.contains("beat 1"))
    }

    func testAVerifiedParkConfirmedBySurfaceReportsWhatWasAsked() {
        XCTAssertEqual(
            MCUController.automationSampleVerdict(
                requested: .init(bar: 2, beat: 4), parkFailure: nil,
                landed: .init(bar: 2, beat: 4)
            ),
            .report(bar: 2, beat: 4, confirmedBySurface: true, landedElsewhere: false)
        )
    }

    /// The park verified against the control bar and the surface says another
    /// position: the value is reported at the position it was READ at, never at
    /// the one that was requested.
    func testAPlayheadThatLandedElsewhereIsReportedWhereItLanded() {
        XCTAssertEqual(
            MCUController.automationSampleVerdict(
                requested: .init(bar: 2, beat: 5), parkFailure: nil,
                landed: .init(bar: 4, beat: 1)
            ),
            .report(bar: 4, beat: 1, confirmedBySurface: true, landedElsewhere: true)
        )
    }

    /// An unreadable position display (SMPTE mode, blank, `ALERT`) loses the
    /// second witness, not the first: `setPlayhead` verified the control bar's
    /// bar AND beat sliders before returning.
    func testAnUnreadableDisplayKeepsTheControlBarsProofAndFlagsIt() {
        XCTAssertEqual(
            MCUController.automationSampleVerdict(
                requested: .init(bar: 7, beat: 2), parkFailure: nil, landed: nil
            ),
            .report(bar: 7, beat: 2, confirmedBySurface: false, landedElsewhere: false)
        )
    }

    // MARK: - D3: a null mode carries its reason

    func testAnUnreadableAutomationModeNamesWhatItIsNot() {
        let reason = MCUController.automationModeUnavailable(
            trackName: "Stereo Out", attempts: 4, waitedMs: 1_050
        )
        XCTAssertTrue(reason.contains("Stereo Out"))
        XCTAssertTrue(reason.contains("4 attempts"))
        XCTAssertTrue(reason.contains("1050 ms"))
        // The sentence exists to stop `null` being read as "Off" or as
        // "therefore a bus".
        XCTAssertTrue(reason.contains("UNKNOWN"))
        XCTAssertTrue(reason.contains("not Off"))
    }

    // MARK: - The printed form of a sampled value

    func testASampledValueSerialisesWithoutItsBinaryTail() throws {
        let payload: [String: Any] = [
            "a": MCUController.automationSampleNumber(-6.2),
            "b": MCUController.automationSampleNumber(-12.699999999999999),
            "c": MCUController.automationSampleNumber(-18.0),
            "d": MCUController.automationSampleNumber(0.0)
        ]
        let json = String(
            data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            encoding: .utf8
        )
        XCTAssertEqual(json, #"{"a":-6.2,"b":-12.7,"c":-18,"d":0}"#)
        // A non-finite value is not a reading; nothing pretends otherwise.
        XCTAssertTrue(MCUController.automationSampleNumber(.nan) is NSNull)
        XCTAssertTrue(MCUController.automationSampleNumber(-.infinity) is NSNull)
    }
}
