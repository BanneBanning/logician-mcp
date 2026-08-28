import XCTest
@testable import Logician

/// The meter map's arithmetic and the Signature List's row grammar. All pure,
/// and held to the same standard as `TempoMapTests`: this decides which bar is
/// how many beats long, so it decides where every freeze slice is cut, where
/// every recorded note lands and where every automation point goes. The most
/// important tests here are the ones that prove the map changes NOTHING on a
/// constant-meter project — that is the whole safety argument for shipping it.
final class MeterMapTests: XCTestCase {

    private func meter(
        _ events: [(Int, Int, Int)], source: MeterMap.Source = .signatureList
    ) -> MeterMap {
        guard let map = MeterMap(
            events: events.map { MeterEvent(bar: $0.0, numerator: $0.1, denominator: $0.2) },
            source: source
        ) else { fatalError("test meter map is invalid") }
        return map
    }

    // MARK: - The constant-meter contract (nothing may move)

    /// A map with one signature must produce exactly the multiplication the bar
    /// math has always done — not approximately, exactly.
    func testConstantMapReproducesTheMultiplicationBitForBit() {
        for (numerator, denominator) in [(4, 4), (3, 4), (6, 8), (5, 4), (7, 8), (2, 2)] {
            let map = meter([(1, numerator, denominator)])
            let beatsPerBar = Double(numerator) * 4.0 / Double(denominator)
            for bar in [1, 2, 5, 9, 33, 57, 121, 400] {
                XCTAssertEqual(
                    map.beatOffset(bar: bar), Double(bar - 1) * beatsPerBar,
                    "\(numerator)/\(denominator) at bar \(bar)"
                )
            }
        }
    }

    /// `barRangeSeconds` with a CONSTANT meter map must return the identical
    /// Double as `barRangeSeconds` with no meter map at all. A constant map is
    /// reported and never used; if that ever stops being true, every existing
    /// project's slice boundaries move.
    func testConstantMeterMapChangesNoBoundary() throws {
        let constantMap = meter([(1, 4, 4)])
        let threeFour = meter([(1, 3, 4)])
        for tempo in [60.0, 97.3, 120.0, 174.0] {
            for beatsPerBar in [3.0, 4.0, 6.0] {
                for (startBar, endBar) in [(1, 2), (5, 9), (17, 33), (57, 121)] {
                    let legacy = try MCPServer.barRangeSeconds(
                        startBar: startBar, endBar: endBar,
                        tempo: tempo, beatsPerBar: beatsPerBar
                    )
                    for map in [constantMap, threeFour] {
                        let withMeter = try MCPServer.barRangeSeconds(
                            startBar: startBar, endBar: endBar,
                            tempo: tempo, beatsPerBar: beatsPerBar, meterMap: map
                        )
                        XCTAssertEqual(withMeter.start, legacy.start)
                        XCTAssertEqual(withMeter.end, legacy.end)
                    }
                }
            }
        }
    }

    /// The same guarantee one level down: a constant meter map must not knock
    /// `TempoMap.rangeSeconds` off its one-event fast path, whose exact
    /// operation order is itself a documented regression guard.
    func testConstantMeterMapKeepsTheTempoFastPath() {
        guard let tempo = TempoMap.constant(97.3) else { return XCTFail("no map") }
        let plain = tempo.rangeSeconds(startBar: 5, endBar: 9, beatsPerBar: 4)
        let mapped = tempo.rangeSeconds(
            startBar: 5, endBar: 9, beatsPerBar: 4, meter: meter([(1, 4, 4)])
        )
        XCTAssertEqual(mapped.start, plain.start)
        XCTAssertEqual(mapped.end, plain.end)
    }

    /// A one-event map built from the control bar's reading is NOT evidence, and
    /// it is constant anyway — both reasons it must never be integrated.
    func testSingleReadingMapIsNotIntegrated() {
        let knowledge = MeterKnowledge(
            map: MeterMap.constant(numerator: 7, denominator: 8), failure: nil
        )
        XCTAssertNil(knowledge.integratedMap)
        XCTAssertEqual(knowledge.payload["read"] as? Bool, false)
    }

    // MARK: - What a changing meter actually does

    /// 4/4 through bar 8, 3/4 from bar 9: bar 13's bar line is 8x4 + 4x3 beats
    /// in, which no single beats-per-bar produces.
    func testBarOffsetSumsEachSegmentsOwnLength() {
        let map = meter([(1, 4, 4), (9, 3, 4)])
        XCTAssertEqual(map.beatOffset(bar: 1), 0)
        XCTAssertEqual(map.beatOffset(bar: 9), 32)
        XCTAssertEqual(map.beatOffset(bar: 13), 44)
        XCTAssertEqual(map.beatsPerBar(atBar: 8), 4)
        XCTAssertEqual(map.beatsPerBar(atBar: 9), 3)
        XCTAssertTrue(map.isVariable)
    }

    /// The denominator is not decoration: Logic's BPM counts quarter notes, so
    /// 6/8 is three beats a bar and 7/8 is three and a half.
    func testDenominatorConvertsToQuarterNoteBeats() {
        XCTAssertEqual(MeterEvent(bar: 1, numerator: 6, denominator: 8).beatsPerBar, 3)
        XCTAssertEqual(MeterEvent(bar: 1, numerator: 7, denominator: 8).beatsPerBar, 3.5)
        XCTAssertEqual(MeterEvent(bar: 1, numerator: 2, denominator: 2).beatsPerBar, 4)
        XCTAssertEqual(MeterEvent(bar: 1, numerator: 5, denominator: 4).beatsPerBar, 5)
    }

    /// Two notations, one bar length: 3/4 and 6/8 are both three quarter-note
    /// beats, so a map holding both is CONSTANT for the arithmetic's purposes.
    /// The test exists because the notation-level answer is the other one.
    func testDifferentNotationsOfTheSameBarLengthAreConstant() {
        let map = meter([(1, 3, 4), (9, 6, 8)])
        XCTAssertTrue(map.isConstant)
        XCTAssertFalse(map.isVariable)
        XCTAssertEqual(map.signatures, ["3/4", "6/8"])
    }

    /// The composer's case, end to end: "bar 40 goes to 5/4" (COVERAGE (d)).
    /// Bars 40-44 at 120 BPM are 4 bars x 5 beats x 0.5 s = 10 s of audio, and
    /// they start 39 x 4 x 0.5 = 78 s in — both wrong under one beats-per-bar.
    func testTheFiveFourCueLandsWhereLogicPutsIt() throws {
        let map = meter([(1, 4, 4), (40, 5, 4)])
        let range = try MCPServer.barRangeSeconds(
            startBar: 40, endBar: 44, tempo: 120, beatsPerBar: 4, meterMap: map
        )
        XCTAssertEqual(range.start, 78.0, accuracy: 1e-9)
        XCTAssertEqual(range.end, 88.0, accuracy: 1e-9)
        // What the old math said, for the record: four beats a bar throughout.
        let assumed = try MCPServer.barRangeSeconds(
            startBar: 40, endBar: 44, tempo: 120, beatsPerBar: 4
        )
        XCTAssertEqual(assumed.end - assumed.start, 8.0, accuracy: 1e-9)
    }

    /// Meter and tempo compose: the meter decides how many beats a bar range
    /// is, the tempo map decides how many seconds those beats take, and neither
    /// half may quietly re-derive the other.
    func testMeterAndTempoMapsCompose() throws {
        // 4/4 to bar 8, then 3/4. 120 BPM to bar 5, then 60 BPM.
        guard let tempo = TempoMap(
            events: [TempoEvent(bar: 1, bpm: 120), TempoEvent(bar: 5, bpm: 60)],
            source: .tempoList
        ) else { return XCTFail("no tempo map") }
        let map = meter([(1, 4, 4), (9, 3, 4)])
        // Bar 9's bar line: 16 beats at 120 (8 s) + 16 beats at 60 (16 s).
        let range = try MCPServer.barRangeSeconds(
            startBar: 9, endBar: 11, tempo: 120, beatsPerBar: 4,
            map: tempo, meterMap: map
        )
        XCTAssertEqual(range.start, 24.0, accuracy: 1e-9)
        // Two 3/4 bars at 60 BPM: 6 beats x 1 s.
        XCTAssertEqual(range.end - range.start, 6.0, accuracy: 1e-9)
    }

    /// A tempo event that sits in a 3/4 bar must be placed at that bar's real
    /// beat offset, not at (bar - 1) x 4.
    func testTempoEventPositionsFollowTheMeter() {
        let map = meter([(1, 4, 4), (9, 3, 4)])
        XCTAssertEqual(
            TempoMap.beatOffset(bar: 13, beatsPerBar: 4, meter: map), 44
        )
        XCTAssertEqual(
            TempoMap.beatOffset(bar: 13, beatsPerBar: 4, meter: meter([(1, 4, 4)])), 48
        )
    }

    /// A map whose first signature is not at bar 1 (only a partial read can
    /// produce one) carries that signature backwards rather than inventing 4/4.
    func testFirstSignatureCarriesBackwards() {
        let map = meter([(5, 3, 4)])
        XCTAssertEqual(map.beatsPerBar(atBar: 1), 3)
        XCTAssertEqual(map.beatOffset(bar: 5), 12)
    }

    // MARK: - The inverse: where does a beat count land?

    func testPositionAtBeatOffsetInvertsBarOffset() {
        let map = meter([(1, 4, 4), (9, 3, 4), (17, 7, 8)])
        for bar in 1...40 {
            let position = map.position(atBeatOffset: map.beatOffset(bar: bar))
            XCTAssertEqual(position.bar, bar, "bar \(bar)")
            XCTAssertEqual(position.beatInBar, 1, accuracy: 1e-9)
        }
        // Halfway into bar 9 (a 3/4 bar): 32 + 1.5 beats.
        let inside = map.position(atBeatOffset: 33.5)
        XCTAssertEqual(inside.bar, 9)
        XCTAssertEqual(inside.beatInBar, 2.5, accuracy: 1e-9)
    }

    func testOffsetsBetweenTwoBarsSubtract() {
        let map = meter([(1, 4, 4), (9, 3, 4)])
        XCTAssertEqual(map.beatOffset(fromBar: 9, toBar: 11, beat: 1), 6)
        XCTAssertEqual(map.beatOffset(fromBar: 9, toBar: 9, beat: 2.5), 1.5)
        XCTAssertEqual(map.beatOffset(fromBar: 9, toBar: 5, beat: 1), -16)
    }

    // MARK: - takeEnd, the other place bars are counted

    /// Where a take ENDS is a bar count, and under a changing meter that is a
    /// walk rather than a division. The case that separates them is a note whose
    /// own duration crosses the signature change: a 12-beat note starting in the
    /// last 4/4 bar runs three bars into 3/4 territory and out the other side of
    /// bar 11, which the one-meter division reports as ending on bar 11 — a take
    /// measured (and rendered, and tempo-read) a whole bar short.
    func testTakeEndWalksTheMeterMap() {
        let map = meter([(1, 4, 4), (9, 3, 4)])
        let notes = [(bar: 8, beat: 1.0, durationBeats: 12.0)]
        let end = MCPServer.takeEnd(
            startBar: 5, beatsPerBar: 4, notes: notes, extraEventBars: [], meterMap: map
        )
        XCTAssertEqual(end.lastBeat, 24)
        XCTAssertEqual(end.endBar, 12)
        let assumed = MCPServer.takeEnd(
            startBar: 5, beatsPerBar: 4, notes: notes, extraEventBars: []
        )
        XCTAssertEqual(assumed.endBar, 11)
    }

    /// And the contract again: a constant map must leave `takeEnd` alone, for
    /// every shape the existing tests cover.
    func testTakeEndUnchangedUnderAConstantMeterMap() {
        let shapes: [([(bar: Int, beat: Double, durationBeats: Double)], [Int])] = [
            ([(bar: 5, beat: 1, durationBeats: 1)], []),
            ([(bar: 5, beat: 3.5, durationBeats: 2)], []),
            ([(bar: 5, beat: 1, durationBeats: 1), (bar: 9, beat: 4, durationBeats: 4)], [11]),
            ([], [7])
        ]
        for beatsPerBar in [3.0, 4.0, 6.0] {
            let numerator = Int(beatsPerBar)
            for (notes, extra) in shapes {
                let legacy = MCPServer.takeEnd(
                    startBar: 5, beatsPerBar: beatsPerBar, notes: notes, extraEventBars: extra
                )
                let mapped = MCPServer.takeEnd(
                    startBar: 5, beatsPerBar: beatsPerBar, notes: notes, extraEventBars: extra,
                    meterMap: meter([(1, numerator, 4)])
                )
                XCTAssertEqual(mapped.lastBeat, legacy.lastBeat)
                XCTAssertEqual(mapped.endBar, legacy.endBar)
            }
        }
    }

    // MARK: - Automation timing

    func testAutomationOffsetFollowsTheMeterMap() {
        let map = meter([(1, 4, 4), (9, 3, 4)])
        // Two 3/4 bars at 120 BPM = 6 beats = 3000 ms.
        XCTAssertEqual(
            MCUController.automationOffsetMs(
                bar: 11, beat: 1, firstBar: 9, beatsPerBar: 4,
                tempo: 120, map: nil, meter: map
            ),
            3000, accuracy: 1e-9
        )
        // A constant map must leave the shipped arithmetic exactly alone.
        XCTAssertEqual(
            MCUController.automationOffsetMs(
                bar: 11, beat: 1, firstBar: 9, beatsPerBar: 4,
                tempo: 120, map: nil, meter: meter([(1, 4, 4)])
            ),
            MCUController.automationOffsetMs(
                bar: 11, beat: 1, firstBar: 9, beatsPerBar: 4, tempo: 120, map: nil
            )
        )
    }

    // MARK: - Signature List row grammar

    func testSignatureParsing() {
        XCTAssertEqual(MeterMap.parseSignature("4/4")?.numerator, 4)
        XCTAssertEqual(MeterMap.parseSignature("4/4")?.denominator, 4)
        XCTAssertEqual(MeterMap.parseSignature(" 12/8 ")?.numerator, 12)
        XCTAssertEqual(MeterMap.parseSignature("7/16")?.denominator, 16)
        // A key-signature row, an empty cell and nonsense are all "not a time
        // signature" — skipped by the reader, never guessed at.
        XCTAssertNil(MeterMap.parseSignature("C major"))
        XCTAssertNil(MeterMap.parseSignature(""))
        XCTAssertNil(MeterMap.parseSignature("4"))
        XCTAssertNil(MeterMap.parseSignature("0/4"))
        // Logic's denominators are powers of two.
        XCTAssertNil(MeterMap.parseSignature("4/5"))
        XCTAssertNil(MeterMap.parseSignature("4/128"))
    }

    /// The Position cell is the Tempo List's grammar, and only the BAR is kept —
    /// with a flag for the sub-bar case rather than a silent rounding.
    func testPositionParsingKeepsTheBarAndFlagsSubBarPositions() {
        XCTAssertEqual(MeterMap.parsePosition("9 1 1 1 ")?.bar, 9)
        XCTAssertEqual(MeterMap.parsePosition("9 1 1 1 ")?.onBarLine, true)
        XCTAssertEqual(MeterMap.parsePosition("9 1 4 201")?.onBarLine, false)
        XCTAssertEqual(MeterMap.parsePosition("9 2 1 1")?.onBarLine, false)
        XCTAssertNil(MeterMap.parsePosition(""))
        XCTAssertNil(MeterMap.parsePosition("x 1 1 1"))
    }

    // MARK: - Construction and payload

    func testInvalidMapsAreRefused() {
        XCTAssertNil(MeterMap(events: [], source: .signatureList))
        XCTAssertNil(MeterMap(
            events: [MeterEvent(bar: 0, numerator: 4, denominator: 4)], source: .signatureList
        ))
        XCTAssertNil(MeterMap(
            events: [MeterEvent(bar: 1, numerator: 0, denominator: 4)], source: .signatureList
        ))
    }

    func testEventsAreSortedByBar() {
        let map = meter([(9, 3, 4), (1, 4, 4), (17, 5, 4)])
        XCTAssertEqual(map.bars, [1, 9, 17])
        XCTAssertEqual(map.signatures, ["4/4", "3/4", "5/4"])
    }

    /// An unreadable Signature List must report itself as unread — never as a
    /// project with one meter, which is the mistake the whole tempo-honesty
    /// family exists to prevent.
    func testUnreadableMeterReportsItselfUnread() {
        let knowledge = MeterKnowledge(map: nil, failure: .tabNotFound("Signature"))
        XCTAssertNil(knowledge.integratedMap)
        XCTAssertEqual(knowledge.payload["read"] as? Bool, false)
        XCTAssertEqual(knowledge.payload["integrated"] as? Bool, false)
        XCTAssertNotNil(knowledge.payload["reason"])
        XCTAssertNil(knowledge.warning(sliced: "x"))
    }

    func testVaryingMeterWarnsAndConstantOneDoesNot() {
        let varying = MeterKnowledge(map: meter([(1, 4, 4), (40, 5, 4)]), failure: nil)
        let warning = varying.warning(sliced: "the slice")
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("bar 40: 5/4") == true)
        XCTAssertEqual(varying.payload["integrated"] as? Bool, true)

        let constant = MeterKnowledge(map: meter([(1, 4, 4)]), failure: nil)
        XCTAssertNil(constant.warning(sliced: "the slice"))
        XCTAssertEqual(constant.payload["read"] as? Bool, true)
        XCTAssertEqual(constant.payload["integrated"] as? Bool, false)
    }

    // MARK: - Signature List rows (the grammar measured live 2026-08-28)

    /// The rule that broke the whole read before it was measured: the project's
    /// OWN first signature publishes an EMPTY Position cell, and that means bar
    /// 1 — not an unreadable row. A signature created later publishes a position
    /// like every other list does.
    func testAnEmptyPositionIsTheProjectsInitialSignatureAtBarOne() {
        let row = MeterMap.parseSignatureRow(
            cells: ["", "Time", "4/4"], positionIndex: 0
        )
        XCTAssertEqual(row, .timeSignature(MeterEvent(bar: 1, numerator: 4, denominator: 4)))
    }

    func testALaterSignaturePublishesItsBar() {
        let row = MeterMap.parseSignatureRow(
            cells: ["41 1 1 1 ", "Time", "5/4"], positionIndex: 0
        )
        XCTAssertEqual(row, .timeSignature(MeterEvent(bar: 41, numerator: 5, denominator: 4)))
    }

    /// The Signature List holds KEY signatures in the same table. A key row is
    /// counted (the truncation cross-check counts every row Logic counts) and
    /// then skipped, because it says nothing about bar lengths.
    func testAKeySignatureRowIsSkippedNotFailed() {
        XCTAssertEqual(
            MeterMap.parseSignatureRow(cells: ["", "Key", "B♭ Major"], positionIndex: 0),
            .keySignature(bar: 1)
        )
        XCTAssertEqual(
            MeterMap.parseSignatureRow(cells: ["57 1 1 1 ", "Key", "F Minor"], positionIndex: 0),
            .keySignature(bar: 57)
        )
    }

    /// A position that is neither empty nor a position is a real failure: the
    /// map is discarded rather than placed at a guessed bar.
    func testAnUnparsablePositionFailsTheRow() {
        guard case .unreadable = MeterMap.parseSignatureRow(
            cells: ["not a position", "Time", "4/4"], positionIndex: 0
        ) else { return XCTFail("expected unreadable") }
    }

    /// The Value cell is TWO elements — a numerator slider and a "/4" pop-up —
    /// joined into one string by the cell reader. This is what the join has to
    /// produce for the row parser to work.
    func testTheJoinedValueCellParsesAsASignature() {
        XCTAssertEqual(MeterMap.parseSignature("5" + "/4")?.numerator, 5)
        XCTAssertEqual(MeterMap.parseSignature("12" + "/8")?.denominator, 8)
    }

    /// The Marker tab puts Position in column 1, the Signature tab in column 0:
    /// the index is read off the header, so the parser must honour it.
    func testThePositionColumnIndexIsHonoured() {
        let row = MeterMap.parseSignatureRow(
            cells: ["", "9 1 1 1 ", "Time", "3/4"], positionIndex: 1
        )
        XCTAssertEqual(row, .timeSignature(MeterEvent(bar: 9, numerator: 3, denominator: 4)))
    }

    func testListEditorFailureReasonsNameTheTab() {
        XCTAssertTrue(
            ListEditorFailure.tabNotFound("Marker").reason.contains("Marker")
        )
        XCTAssertTrue(
            ListEditorFailure.countMismatch(tab: "Event", rows: 3, declared: 40)
                .reason.contains("40")
        )
        XCTAssertEqual(ListEditorFailure.paneUnavailable.code, "pane_unavailable")
    }
}
