import XCTest
@testable import Logician

/// The tempo map's arithmetic and the Tempo List's row grammar. All pure: the
/// integration decides where every freeze slice is cut and where every recorded
/// note lands, and the row parsing decides whether a map is trusted at all —
/// both are expensive to get wrong and cheap to check without Logic running.
final class TempoMapTests: XCTestCase {

    private func map(
        _ events: [TempoEvent], source: TempoMap.Source = .tempoList, subBeat: Bool = false
    ) -> TempoMap {
        guard let map = TempoMap(events: events, source: source, subBeatPositions: subBeat) else {
            fatalError("test map is invalid")
        }
        return map
    }

    // MARK: - The constant-map regression (today's formula, unchanged)

    /// A one-event map must reproduce the shipped constant-tempo formula
    /// EXACTLY, not approximately: constant-tempo projects are the common case,
    /// and a boundary that moved by a float's last bit would be a silent change
    /// to every freeze slice this server has ever cut.
    func testSingleEventMapReproducesTheConstantFormulaBitForBit() throws {
        for tempo in [60.0, 97.3, 120.0, 128.0, 174.0, 999.0] {
            for beatsPerBar in [3.0, 4.0, 6.0, 7.0] {
                for (startBar, endBar) in [(1, 2), (5, 9), (17, 33), (1, 200), (57, 121)] {
                    let legacy = try MCPServer.barRangeSeconds(
                        startBar: startBar, endBar: endBar,
                        tempo: tempo, beatsPerBar: beatsPerBar
                    )
                    let constant = map(
                        [TempoEvent(bar: 1, bpm: tempo)], source: .tempoList
                    ).rangeSeconds(startBar: startBar, endBar: endBar, beatsPerBar: beatsPerBar)
                    XCTAssertEqual(
                        constant.start, legacy.start,
                        "bars \(startBar)-\(endBar) @ \(tempo) BPM, \(beatsPerBar)/bar"
                    )
                    XCTAssertEqual(constant.end, legacy.end)
                }
            }
        }
    }

    /// The live calibration this project measured in 2026-08-25 (FINDINGS:634):
    /// bars 5-9 at 120 BPM in 4/4 is exactly 8.000 s of audio, 352 800 frames.
    func testTheCalibratedEightSecondsSurvivesTheMap() {
        let range = map([TempoEvent(bar: 1, bpm: 120)])
            .rangeSeconds(startBar: 5, endBar: 9, beatsPerBar: 4)
        XCTAssertEqual(range.start, 8.0)
        XCTAssertEqual(range.end, 16.0)
        XCTAssertEqual((range.end - range.start) * 44_100, 352_800)
    }

    /// A map read as a single event, and one read through `barRangeSeconds`'s
    /// map parameter, are the same answer — the wiring must not add its own math.
    func testBarRangeSecondsWithAMapAgreesWithTheMapItself() throws {
        let stepped = map([
            TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 5, bpm: 140)
        ])
        let wired = try MCPServer.barRangeSeconds(
            startBar: 3, endBar: 9, tempo: 120, beatsPerBar: 4, map: stepped
        )
        let direct = stepped.rangeSeconds(startBar: 3, endBar: 9, beatsPerBar: 4)
        XCTAssertEqual(wired.start, direct.start)
        XCTAssertEqual(wired.end, direct.end)
        // Tempo and meter are still reported as read, not as integrated.
        XCTAssertEqual(wired.tempo, 120)
        XCTAssertEqual(wired.beatsPerBar, 4)
    }

    /// A `.singleReading` map is the constant-tempo ASSUMPTION wearing the
    /// type's clothes, so the wiring must ignore it and take the legacy path.
    func testBarRangeSecondsIgnoresAMapThatWasNotRead() throws {
        let assumed = map([
            TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 5, bpm: 140)
        ], source: .singleReading)
        let wired = try MCPServer.barRangeSeconds(
            startBar: 1, endBar: 9, tempo: 120, beatsPerBar: 4, map: assumed
        )
        let legacy = try MCPServer.barRangeSeconds(
            startBar: 1, endBar: 9, tempo: 120, beatsPerBar: 4
        )
        XCTAssertEqual(wired.end, legacy.end)
    }

    // MARK: - Step changes

    func testStepChangeIntegratesEachSegmentAtItsOwnTempo() {
        // 120 BPM from bar 1, 140 from bar 5, 4/4.
        let stepped = map([TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 5, bpm: 140)])
        // Bars 1-5: 16 beats at 120 = 8 s.
        XCTAssertEqual(stepped.seconds(atBeatOffset: 16, beatsPerBar: 4), 8.0, accuracy: 1e-12)
        // Bars 5-9: 16 beats at 140.
        XCTAssertEqual(
            stepped.seconds(atBeatOffset: 32, beatsPerBar: 4),
            8.0 + 16 * 60 / 140, accuracy: 1e-12
        )
        // A range that STRADDLES the change gets both halves right.
        let straddling = stepped.rangeSeconds(startBar: 3, endBar: 7, beatsPerBar: 4)
        XCTAssertEqual(straddling.start, 4.0, accuracy: 1e-12)
        XCTAssertEqual(straddling.end, 8.0 + 8 * 60 / 140, accuracy: 1e-12)
        // And it is SHORTER than the constant-tempo answer, because the second
        // half is faster — the exact error the old math made.
        XCTAssertLessThan(straddling.end - straddling.start, 8.0)
    }

    func testThreeStepsAndARangeEntirelyAfterTheLastEvent() {
        let stepped = map([
            TempoEvent(bar: 1, bpm: 100),
            TempoEvent(bar: 3, bpm: 120),
            TempoEvent(bar: 5, bpm: 150)
        ])
        // To bar 3: 8 beats at 100 = 4.8 s. To bar 5: + 8 beats at 120 = 8.8 s.
        XCTAssertEqual(stepped.seconds(atBeatOffset: 8, beatsPerBar: 4), 4.8, accuracy: 1e-12)
        XCTAssertEqual(stepped.seconds(atBeatOffset: 16, beatsPerBar: 4), 8.8, accuracy: 1e-12)
        // Past the last event the tempo simply holds.
        let tail = stepped.rangeSeconds(startBar: 9, endBar: 13, beatsPerBar: 4)
        XCTAssertEqual(tail.end - tail.start, 16 * 60 / 150, accuracy: 1e-12)
    }

    func testEventsAreSortedAndSubBeatPositionsCount() {
        let unsorted = map([
            TempoEvent(bar: 9, bpm: 90),
            TempoEvent(bar: 1, bpm: 120),
            TempoEvent(bar: 5, beatInBar: 3, bpm: 100)
        ])
        XCTAssertEqual(unsorted.events.map(\.bar), [1, 5, 9])
        // The bar-5 event lands on beat 3, so the first two beats of bar 5 are
        // still at 120: 16 beats + 2 beats = 9 s at bar 5 beat 3.
        XCTAssertEqual(
            unsorted.seconds(atBeatOffset: 18, beatsPerBar: 4), 9.0, accuracy: 1e-12
        )
        XCTAssertEqual(
            unsorted.seconds(atBeatOffset: 20, beatsPerBar: 4),
            9.0 + 2 * 60 / 100, accuracy: 1e-12
        )
    }

    func testMeterChangesWhichBarABeatOffsetLandsIn() {
        let stepped = map([TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 5, bpm: 60)])
        // In 3/4 the bar-5 event sits 12 beats in, not 16.
        XCTAssertEqual(stepped.seconds(atBeatOffset: 12, beatsPerBar: 3), 6.0, accuracy: 1e-12)
        let waltz = stepped.rangeSeconds(startBar: 5, endBar: 9, beatsPerBar: 3)
        XCTAssertEqual(waltz.start, 6.0, accuracy: 1e-12)
        XCTAssertEqual(waltz.end - waltz.start, 12 * 60 / 60, accuracy: 1e-12)
    }

    func testInvalidMapsAreRefusedAtInit() {
        XCTAssertNil(TempoMap(events: [], source: .tempoList))
        XCTAssertNil(TempoMap(events: [TempoEvent(bar: 1, bpm: 0)], source: .tempoList))
        XCTAssertNil(TempoMap(events: [TempoEvent(bar: 1, bpm: -120)], source: .tempoList))
        XCTAssertNil(TempoMap(events: [TempoEvent(bar: 0, bpm: 120)], source: .tempoList))
    }

    func testIsConstantUsesTheSampleEpsilon() {
        XCTAssertTrue(map([TempoEvent(bar: 1, bpm: 120)]).isConstant)
        XCTAssertTrue(
            map([TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 5, bpm: 120.02)]).isConstant,
            "0.02 BPM is inside the 0.05 epsilon the two-point sample uses"
        )
        XCTAssertFalse(
            map([TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 5, bpm: 120.5)]).isConstant
        )
    }

    // MARK: - Linear BPM ramps (tempo curves)

    /// The exact integral, not subdivision: with BPM linear in beats,
    /// ∫ 60/BPM d(beat) = (60/k) ln(b1/b0).
    func testLinearRampIntegratesToTheExactLogarithm() {
        let ramp = map([
            TempoEvent(bar: 1, bpm: 120, rampToNext: true),
            TempoEvent(bar: 5, bpm: 240)
        ])
        // 120 -> 240 over 16 beats: k = 7.5, so the segment takes 8 * ln 2 s.
        XCTAssertEqual(
            ramp.seconds(atBeatOffset: 16, beatsPerBar: 4),
            8 * log(2.0), accuracy: 1e-12
        )
        // Halfway through the ramp (8 beats) the tempo is 180 and the elapsed
        // time is 8 * ln 1.5 — a partial segment, integrated as one.
        XCTAssertEqual(
            ramp.seconds(atBeatOffset: 8, beatsPerBar: 4),
            8 * log(1.5), accuracy: 1e-12
        )
        XCTAssertEqual(ramp.bpm(atBeatOffset: 8, beatsPerBar: 4), 180, accuracy: 1e-12)
        // A ramp is always slower than starting at the higher tempo and faster
        // than holding the lower one.
        XCTAssertGreaterThan(8 * log(2.0), 16 * 60 / 240)
        XCTAssertLessThan(8 * log(2.0), 8.0)
    }

    /// Subdividing the ramp finely must converge on the closed form — the test
    /// that the logarithm is the right closed form and not merely a formula.
    func testRampMatchesAFinelySubdividedApproximation() {
        let ramp = map([
            TempoEvent(bar: 1, bpm: 90, rampToNext: true),
            TempoEvent(bar: 9, bpm: 160)
        ])
        let exact = ramp.seconds(atBeatOffset: 32, beatsPerBar: 4)
        // Midpoint rule over 20 000 slices of the same ramp.
        let slices = 20_000
        var approximate = 0.0
        for index in 0..<slices {
            let beat = (Double(index) + 0.5) / Double(slices) * 32
            approximate += (32 / Double(slices)) * 60 / (90 + (160 - 90) * beat / 32)
        }
        XCTAssertEqual(exact, approximate, accuracy: 1e-6)
    }

    func testARampBetweenEqualTemposIsAStep() {
        let ramp = map([
            TempoEvent(bar: 1, bpm: 120, rampToNext: true),
            TempoEvent(bar: 5, bpm: 120)
        ])
        XCTAssertEqual(ramp.seconds(atBeatOffset: 16, beatsPerBar: 4), 8.0, accuracy: 1e-12)
    }

    func testBpmAtOffsetFollowsStepsAndHoldsAfterTheLastEvent() {
        let stepped = map([TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 5, bpm: 140)])
        XCTAssertEqual(stepped.bpm(atBeatOffset: 0, beatsPerBar: 4), 120)
        XCTAssertEqual(stepped.bpm(atBeatOffset: 15.9, beatsPerBar: 4), 120)
        XCTAssertEqual(stepped.bpm(atBeatOffset: 16, beatsPerBar: 4), 140)
        XCTAssertEqual(stepped.bpm(atBeatOffset: 1000, beatsPerBar: 4), 140)
    }

    /// A map whose first event is not at bar 1 (Logic always puts one there, so
    /// this is a partial read): the stretch before it is carried at its tempo
    /// rather than invented.
    func testAMapStartingLaterCarriesItsFirstTempoBackwards() {
        let late = map([TempoEvent(bar: 5, bpm: 120), TempoEvent(bar: 9, bpm: 60)])
        // Bars 1-5 are carried at 120 (8 s), and so are bars 5-9 — the 60 BPM
        // event only starts AT bar 9.
        XCTAssertEqual(late.seconds(atBeatOffset: 16, beatsPerBar: 4), 8.0, accuracy: 1e-12)
        XCTAssertEqual(late.seconds(atBeatOffset: 32, beatsPerBar: 4), 16.0, accuracy: 1e-12)
        // From bar 9 onward the map's own tempo takes over.
        XCTAssertEqual(late.seconds(atBeatOffset: 36, beatsPerBar: 4), 20.0, accuracy: 1e-12)
    }

    func testSecondsIsZeroAtAndBeforeTheProjectStart() {
        let stepped = map([TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 5, bpm: 140)])
        XCTAssertEqual(stepped.seconds(atBeatOffset: 0, beatsPerBar: 4), 0)
        XCTAssertEqual(stepped.seconds(atBeatOffset: -4, beatsPerBar: 4), 0)
        XCTAssertEqual(stepped.seconds(atBeatOffset: 8, beatsPerBar: 0), 0)
    }

    // MARK: - What a curve the Tempo List cannot report would cost

    func testCurveUncertaintyIsZeroWhenNoCurveCouldReachTheRange() {
        // A constant map has nothing to ramp between.
        XCTAssertEqual(
            map([TempoEvent(bar: 1, bpm: 120)])
                .curveUncertaintySeconds(startBar: 5, endBar: 9, beatsPerBar: 4),
            0
        )
        // Neither does a map whose adjacent points agree in tempo: two points at
        // the same BPM are the same line whether they are joined by a step or a
        // curve.
        XCTAssertEqual(
            map([
                TempoEvent(bar: 1, bpm: 120),
                TempoEvent(bar: 5, bpm: 120),
                TempoEvent(bar: 9, bpm: 140)
            ]).curveUncertaintySeconds(startBar: 1, endBar: 5, beatsPerBar: 4),
            0, accuracy: 1e-9
        )
    }

    /// These boundaries are measured from PROJECT START, so a curve earlier in
    /// the song displaces a later range even though no tempo change falls
    /// between its own bars. The number must say so.
    func testCurveUncertaintyCoversARangeAfterTheCurve() {
        XCTAssertGreaterThan(
            map([TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 5, bpm: 90)])
                .curveUncertaintySeconds(startBar: 9, endBar: 13, beatsPerBar: 4),
            0.5
        )
    }

    /// A range with no tempo change between its own bars is still INSIDE the
    /// segment those bars sit in — so a curve spanning that segment does move
    /// it, and the uncertainty must not be reported as zero.
    func testCurveUncertaintyCoversARangeInsideASegment() {
        XCTAssertGreaterThan(
            map([TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 33, bpm: 140)])
                .curveUncertaintySeconds(startBar: 5, endBar: 9, beatsPerBar: 4),
            0.1
        )
    }

    func testCurveUncertaintyIsTheStepVersusRampDifference() {
        let stepped = map([TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 5, bpm: 240)])
        // Step: bar 5 is at 8 s. Ramp: 8 * ln 2 ≈ 5.545 s.
        let uncertainty = stepped.curveUncertaintySeconds(
            startBar: 1, endBar: 5, beatsPerBar: 4
        )
        XCTAssertEqual(uncertainty, 8.0 - 8 * log(2.0), accuracy: 1e-9)
        XCTAssertGreaterThan(uncertainty, 2.4)
    }

    // MARK: - Tempo List row grammar (strings captured live 2026-08-27)

    func testPositionCellGrammarFromTheLiveRead() {
        // The exact string the live project published for its single event.
        let onTheBar = TempoMap.parseTempoListPosition("1 1 1 1 ")
        XCTAssertEqual(onTheBar?.bar, 1)
        XCTAssertEqual(onTheBar?.beatInBar, 1)
        XCTAssertEqual(onTheBar?.offBeat, false)

        let laterBeat = TempoMap.parseTempoListPosition("17 3 1 1 ")
        XCTAssertEqual(laterBeat?.bar, 17)
        XCTAssertEqual(laterBeat?.beatInBar, 3)
        XCTAssertEqual(laterBeat?.offBeat, false)

        // Division 3 of 4 (a 1/16 grid): half a beat in, and flagged as off-beat
        // because the 1/16 assumption is what produced the fraction.
        let offBeat = TempoMap.parseTempoListPosition("5 1 3 1 ")
        XCTAssertEqual(offBeat?.beatInBar, 1.5)
        XCTAssertEqual(offBeat?.offBeat, true)

        // Tick 121 of 240: half a division past the division line.
        let ticks = TempoMap.parseTempoListPosition("5 1 1 121 ")
        XCTAssertEqual(ticks?.beatInBar ?? 0, 1 + 120.0 / 960.0, accuracy: 1e-12)
        XCTAssertEqual(ticks?.offBeat, true)

        // Tab-separated and short forms still parse (a format change degrades to
        // "still read" rather than "every row unbelievable").
        XCTAssertEqual(TempoMap.parseTempoListPosition("9\t2\t1\t1")?.bar, 9)
        XCTAssertEqual(TempoMap.parseTempoListPosition("9")?.beatInBar, 1)
    }

    func testPositionCellRefusesWhatIsNotAPosition() {
        XCTAssertNil(TempoMap.parseTempoListPosition(""))
        XCTAssertNil(TempoMap.parseTempoListPosition("   "))
        XCTAssertNil(TempoMap.parseTempoListPosition("bar 5"))
        XCTAssertNil(TempoMap.parseTempoListPosition("0 1 1 1"), "bars are one-based in Logic")
        XCTAssertNil(TempoMap.parseTempoListPosition("5 0 1 1"), "so are beats")
        XCTAssertNil(TempoMap.parseTempoListPosition("01:00:00:00.00"), "that is the SMPTE column")
    }

    func testTempoCellAcceptsBothDecimalSeparators() {
        // The live read published a COMMA (Swedish locale).
        XCTAssertEqual(TempoMap.parseTempoListBPM("120,0000"), 120)
        XCTAssertEqual(TempoMap.parseTempoListBPM("97.5000"), 97.5)
        XCTAssertEqual(TempoMap.parseTempoListBPM(" 128,2500 "), 128.25)
        XCTAssertNil(TempoMap.parseTempoListBPM(""))
        XCTAssertNil(TempoMap.parseTempoListBPM("--"))
        XCTAssertNil(TempoMap.parseTempoListBPM("0,0000"))
        XCTAssertNil(TempoMap.parseTempoListBPM("1200,0000"), "Logic's tempo ceiling is 990 BPM")
    }

    func testItemCountIsTheTruncationCrossCheck() {
        XCTAssertEqual(TempoMap.parseTempoListItemCount("1 Event"), 1)
        XCTAssertEqual(TempoMap.parseTempoListItemCount("54 Events"), 54)
        XCTAssertEqual(TempoMap.parseTempoListItemCount("7 Events selected"), 7)
        XCTAssertNil(TempoMap.parseTempoListItemCount(""))
        XCTAssertNil(TempoMap.parseTempoListItemCount("No Events"))
    }

    // MARK: - Automation timing

    func testAutomationOffsetsFallBackToOneMsPerBeatWithoutAMap() {
        let offset = MCUController.automationOffsetMs(
            bar: 7, beat: 2, firstBar: 5, beatsPerBar: 4, tempo: 120, map: nil
        )
        XCTAssertEqual(offset, 9 * 500.0, accuracy: 1e-12)
        XCTAssertEqual(
            MCUController.automationMsPerBeat(
                bar: 7, beat: 1, beatsPerBar: 4, tempo: 120, map: nil
            ),
            500.0
        )
        // A map that was ASSUMED rather than read takes the same path.
        let assumed = map([
            TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 6, bpm: 60)
        ], source: .singleReading)
        XCTAssertEqual(
            MCUController.automationOffsetMs(
                bar: 7, beat: 2, firstBar: 5, beatsPerBar: 4, tempo: 120, map: assumed
            ),
            9 * 500.0, accuracy: 1e-12
        )
    }

    func testAutomationOffsetsIntegrateAReadMap() {
        // 120 BPM until bar 6, then 60: a point in bar 7 is much later than the
        // constant-tempo math thought.
        let stepped = map([TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 6, bpm: 60)])
        let offset = MCUController.automationOffsetMs(
            bar: 7, beat: 1, firstBar: 5, beatsPerBar: 4, tempo: 120, map: stepped
        )
        // Bar 5 -> 6 at 120 (4 beats = 2 s), bar 6 -> 7 at 60 (4 beats = 4 s).
        XCTAssertEqual(offset, 6000.0, accuracy: 1e-9)
        XCTAssertEqual(
            MCUController.automationMsPerBeat(
                bar: 7, beat: 1, beatsPerBar: 4, tempo: 120, map: stepped
            ),
            1000.0, accuracy: 1e-9
        )
        // The pre-roll bar's own length: bar 4 at 120 = 2 s before bar 5.
        XCTAssertEqual(
            abs(MCUController.automationOffsetMs(
                bar: 4, beat: 1, firstBar: 5, beatsPerBar: 4, tempo: 120, map: stepped
            )),
            2000.0, accuracy: 1e-9
        )
    }

    // MARK: - What an invocation knows, and what it therefore says

    private func knowledge(
        map: TempoMap?, failure: TempoListFailure? = nil, sample: TempoSample? = nil,
        startBar: Int = 5, endBar: Int = 9
    ) -> TempoKnowledge {
        TempoKnowledge(
            startBar: startBar, endBar: endBar, beatsPerBar: 4,
            map: map, mapFailure: failure, sample: sample
        )
    }

    func testAConstantReadMapSaysNothingAtAll() {
        let known = knowledge(map: map([TempoEvent(bar: 1, bpm: 120)]))
        XCTAssertNil(known.warning(sliced: "this slice"))
        XCTAssertEqual(known.isVarying, false)
        XCTAssertEqual(known.payload?["constant"] as? Bool, true)
        XCTAssertEqual(known.payload?["events"] as? Int, 1)
        XCTAssertEqual(known.curveUncertaintySeconds, 0)
    }

    func testAVaryingReadMapReportsIntegrationAndTheCurveCaveat() throws {
        let known = knowledge(
            map: map([TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 7, bpm: 90)]),
            startBar: 5, endBar: 9
        )
        let warning = try XCTUnwrap(known.warning(sliced: "the slice"))
        XCTAssertTrue(warning.contains("TEMPO MAP READ AND INTEGRATED"))
        XCTAssertTrue(warning.contains("120, 90 BPM"))
        XCTAssertTrue(warning.contains("no curve column"), "the caveat must name why")
        XCTAssertEqual(known.isVarying, true)
        XCTAssertGreaterThan(known.curveUncertaintySeconds, 0)
    }

    /// When every adjacent pair up to the range agrees in tempo, a curve cannot
    /// change anything — the caveat drops out and the boundaries are exact.
    func testTheCurveCaveatDropsOutWhenNoPairCouldRamp() throws {
        let known = knowledge(
            map: map([
                TempoEvent(bar: 1, bpm: 120),
                TempoEvent(bar: 5, bpm: 120),
                TempoEvent(bar: 33, bpm: 90)
            ]),
            startBar: 1, endBar: 5
        )
        let warning = try XCTUnwrap(known.warning(sliced: "the slice"))
        XCTAssertTrue(warning.contains("TEMPO MAP READ AND INTEGRATED"))
        XCTAssertFalse(warning.contains("no curve column"))
    }

    func testSubBeatPositionsAreDisclosed() throws {
        let known = knowledge(
            map: map([
                TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 7, beatInBar: 2.5, bpm: 90)
            ], subBeat: true)
        )
        let warning = try XCTUnwrap(known.warning(sliced: "the slice"))
        XCTAssertTrue(warning.contains("OFF the beat"))
        XCTAssertEqual(known.payload?["sub_beat_positions"] as? Bool, true)
    }

    func testAnUnreadableMapFallsBackToTheSampleAndNamesWhy() throws {
        let sample = TempoSample.verdict(.varying(TempoSpan(
            startBar: 5, endBar: 9, startTempo: 120, endTempo: 140
        )))
        let known = knowledge(map: nil, failure: .tempoTabNotFound, sample: sample)
        let warning = try XCTUnwrap(known.warning(sliced: "this slice"))
        XCTAssertTrue(warning.contains("TEMPO MAP DETECTED"), "the pre-map warning still applies")
        XCTAssertTrue(warning.contains("no Tempo tab"), "and says why the map could not be read")
        XCTAssertEqual(known.isVarying, true)
        XCTAssertNil(known.payload, "an unread map is never serialised as one")
        XCTAssertNotNil(known.refusalDetail)
    }

    func testAnUnverifiableSampleWithAnUnreadableMapKnowsNothing() {
        let known = knowledge(
            map: nil, failure: .listEditorsUnavailable,
            sample: .verdict(.unverified(reason: "no playhead position"))
        )
        XCTAssertNil(known.isVarying)
        XCTAssertNotNil(known.warning(sliced: "this slice"))
    }

    func testAReadMapIsOnlyOneThatCameFromTheTempoList() {
        XCTAssertNil(knowledge(map: TempoMap.constant(120)).readMap)
        XCTAssertNotNil(knowledge(map: map([TempoEvent(bar: 1, bpm: 120)])).readMap)
    }

    func testTruncationAndOtherFailuresExplainThemselves() {
        XCTAssertTrue(
            TempoListFailure.countMismatch(rows: 2, declared: 7).reason.contains("truncated")
        )
        XCTAssertTrue(
            TempoListFailure.rowsUnreadable("tempo 'x' is not a BPM").reason.contains("not a BPM")
        )
        XCTAssertFalse(TempoListFailure.tableNotFound.reason.isEmpty)
    }

    // MARK: - The cache's staleness check

    func testCouldProduceTempoIsTheCacheValidityCheck() {
        let constant = map([TempoEvent(bar: 1, bpm: 120)])
        XCTAssertTrue(constant.couldProduceTempo(120))
        XCTAssertTrue(constant.couldProduceTempo(120.03), "inside the read epsilon")
        XCTAssertFalse(constant.couldProduceTempo(128), "a user edit the cache cannot explain")

        let stepped = map([TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 33, bpm: 90)])
        XCTAssertTrue(stepped.couldProduceTempo(90))
        XCTAssertFalse(stepped.couldProduceTempo(105), "no step passes through 105")

        // A ramp passes through every value between its ends.
        let ramp = map([
            TempoEvent(bar: 1, bpm: 120, rampToNext: true), TempoEvent(bar: 33, bpm: 90)
        ])
        XCTAssertTrue(ramp.couldProduceTempo(105))
        XCTAssertFalse(ramp.couldProduceTempo(140))
    }

    // MARK: - What serving the cache may claim (the R4 silent failure)

    /// R4 regression (measured on a French Logic, 2026-08-30): the cache guard
    /// was `live == nil || cached.couldProduceTempo(live ?? 0)`, so a control
    /// bar that could not be read SKIPPED the cross-check and the cache was
    /// served as a verified live read. The three outcomes must stay distinct:
    /// "checked and passed" is not "could not check".
    func testAnUnreadableControlBarIsNotACrossCheckThatPassed() {
        let cached = map([TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 9, bpm: 121)])
        XCTAssertEqual(
            MCPServer.cachedTempoMapVerdict(cached, liveTempo: nil),
            .serveUnverified,
            "no live tempo means the check never ran — it must not count as passing"
        )
        XCTAssertEqual(
            MCPServer.cachedTempoMapVerdict(cached, liveTempo: 121),
            .serveCrossChecked
        )
        XCTAssertEqual(
            MCPServer.cachedTempoMapVerdict(cached, liveTempo: 97),
            .discard,
            "a tempo the map cannot produce proves the cache stale"
        )
    }

    /// The `logic_tempo_events {list}` payload must say when the map is a
    /// cache nothing cross-checked: on the French Logic it reported
    /// `success: true, verified: true, read_route: "tempo_list"` for exactly
    /// that case.
    func testTheTempoEventsListPayloadDisclosesAnUncheckedCache() throws {
        let served = map([TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 9, bpm: 121)])

        let checked = MCPServer.tempoEventsListPayload(map: served, liveCrossChecked: true)
        XCTAssertEqual(checked["success"] as? Bool, true)
        XCTAssertEqual(checked["verified"] as? Bool, true)
        XCTAssertEqual(checked["read_route"] as? String, "tempo_list")
        XCTAssertNil(checked["warning"], "a cross-checked read carries no cache caveat")

        let unchecked = MCPServer.tempoEventsListPayload(map: served, liveCrossChecked: false)
        XCTAssertEqual(unchecked["success"] as? Bool, true, "the cache is still the best answer")
        XCTAssertEqual(
            unchecked["verified"] as? Bool, false,
            "nothing verified this map against the live project"
        )
        XCTAssertEqual(unchecked["read_route"] as? String, "tempo_list_cache")
        let warning = try XCTUnwrap(unchecked["warning"] as? String)
        XCTAssertTrue(warning.contains("CACHE"), "the warning must name the provenance")
        XCTAssertTrue(
            warning.contains("cross-check"),
            "and say WHICH verification was unavailable"
        )
        // The events themselves are identical either way — provenance changes
        // the claim, never the data.
        XCTAssertEqual(
            (checked["events"] as? [[String: Any]])?.count,
            (unchecked["events"] as? [[String: Any]])?.count
        )
    }

    // MARK: - Codable (the per-project cache)

    func testTheMapSurvivesTheCacheRoundTrip() throws {
        let original = map([
            TempoEvent(bar: 1, bpm: 120),
            TempoEvent(bar: 17, beatInBar: 2.5, bpm: 143.75, rampToNext: true),
            TempoEvent(bar: 33, bpm: 90)
        ], subBeat: true)
        let decoded = try JSONDecoder().decode(
            TempoMap.self, from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(
            decoded.seconds(atBeatOffset: 200, beatsPerBar: 4),
            original.seconds(atBeatOffset: 200, beatsPerBar: 4)
        )
    }

    // MARK: - What the cache may hold after a tempo write

    /// The whole point of the patch: a one-event map plus the BPM the slider
    /// landed on IS the map afterwards, so the next reader must not be sent
    /// back to the Tempo List for something already known.
    func testASingleEventMapIsKnownExactlyAfterASliderWrite() throws {
        let before = map([TempoEvent(bar: 1, beatInBar: 1, bpm: 121)], subBeat: false)
        let after = try XCTUnwrap(
            MCPServer.tempoMapAfterConstantWrite(before, landedBPM: 122)
        )
        XCTAssertEqual(after.events.count, 1)
        XCTAssertEqual(after.events[0].bpm, 122)
        // Position and provenance are the write's business only in so far as it
        // did not touch them: a BPM step moves no event and downgrades no read.
        XCTAssertEqual(after.events[0].bar, 1)
        XCTAssertEqual(after.events[0].beatInBar, 1)
        XCTAssertEqual(after.source, .tempoList)
        XCTAssertTrue(after.isConstant)
        // And it must cross-check clean against the control bar's new reading,
        // or the very next `resolveTempoMap` would throw it away again.
        XCTAssertTrue(after.couldProduceTempo(122))
        XCTAssertFalse(after.couldProduceTempo(121))
    }

    /// An off-beat single event keeps its sub-beat position AND the disclosure
    /// that says the position came from the division/tick assumption.
    func testThePatchKeepsTheSubBeatPositionAndItsDisclosure() throws {
        let before = map(
            [TempoEvent(bar: 9, beatInBar: 1.7177, bpm: 121)], subBeat: true
        )
        let after = try XCTUnwrap(
            MCPServer.tempoMapAfterConstantWrite(before, landedBPM: 100)
        )
        XCTAssertEqual(after.events[0].bar, 9)
        XCTAssertEqual(after.events[0].beatInBar, 1.7177)
        XCTAssertTrue(after.subBeatPositions)
    }

    /// Everything else falls back to forgetting the cache. Several events with
    /// the SAME tempo read as constant, and `logic_set_tempo` would be allowed
    /// to write into that map — but which node the position-dependent slider
    /// moved is not knowable from here, so no patch may be guessed.
    func testAMapWhoseAftermathIsNotKnownIsNotPatched() {
        let twoEqual = map([
            TempoEvent(bar: 1, bpm: 121), TempoEvent(bar: 33, bpm: 121)
        ])
        XCTAssertTrue(twoEqual.isConstant, "the guard would let this write through")
        XCTAssertNil(MCPServer.tempoMapAfterConstantWrite(twoEqual, landedBPM: 122))

        let varying = map([
            TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 9, bpm: 140)
        ])
        XCTAssertNil(MCPServer.tempoMapAfterConstantWrite(varying, landedBPM: 122))

        // A single control-bar READING is not a read map, and patching it would
        // promote a guess to `.tempoList` — the provenance other callers gate on.
        let reading = map([TempoEvent(bar: 1, bpm: 121)], source: .singleReading)
        XCTAssertNil(MCPServer.tempoMapAfterConstantWrite(reading, landedBPM: 122))

        // A slider that could not be read back at all (`setTempo` returns -1 on
        // that path) must never be cached as a tempo.
        let single = map([TempoEvent(bar: 1, bpm: 121)])
        XCTAssertNil(MCPServer.tempoMapAfterConstantWrite(single, landedBPM: -1))
        XCTAssertNil(MCPServer.tempoMapAfterConstantWrite(single, landedBPM: 0))
    }
}
