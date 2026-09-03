import XCTest
@testable import Logician

/// The rules an automation pass cannot be allowed to get wrong, all pure.
///
/// Every one of these was a silent wrongness before it was a test: an anchor
/// that accepted a roll starting PAST the range and wrote the curve there
/// (then verified it against itself), a refusal that spent 10.4 s and a fader
/// write discovering a precondition that could never pass, and a cached fader
/// map that would be worth ten seconds a call and worthless if it could be
/// inherited by another Logic build or another project.
final class AutomationPassTests: XCTestCase {

    // MARK: - The roll anchor

    /// The regression that matters: the FIRST observation of a roll may not be
    /// accepted as the crossing. `logic_get_transport`'s profile measured
    /// playback starting at bar 40 while the playhead read 51, and the old
    /// `bar >= first.bar` test would have anchored the whole curve there.
    func testFirstObservationPastTheRangeIsRefusedNotAnchored() {
        XCTAssertEqual(
            MCUController.rollSyncVerdict(observedBar: 40, firstBar: 2, sawPreRoll: false),
            .startedPastRange
        )
        XCTAssertEqual(
            MCUController.rollSyncVerdict(observedBar: 2, firstBar: 2, sawPreRoll: false),
            .startedPastRange
        )
    }

    /// The normal path is unchanged: the pre-roll bar is seen, then the
    /// crossing into the range is the anchor.
    func testPreRollThenCrossingAnchors() {
        XCTAssertEqual(
            MCUController.rollSyncVerdict(observedBar: 1, firstBar: 2, sawPreRoll: false),
            .preRoll
        )
        XCTAssertEqual(
            MCUController.rollSyncVerdict(observedBar: 2, firstBar: 2, sawPreRoll: true),
            .crossed
        )
    }

    /// THE 2026-09-03 REGRESSION, and it is the whole dispute between
    /// `logic_record_automation` and `logic_read_automation`.
    ///
    /// A pre-roll sighting used to make ANY later bar the crossing, and the
    /// first sighting of a roll is the display Logic has not repainted yet.
    /// Live on the sandbox: playhead parked and verified at bar 1 on both
    /// planes, a volume curve asked for at bars 2→4 — and the stale bar-1
    /// reading armed the guard, the next reading was bar 9, that was accepted
    /// as "the crossing", and `logic_read_automation` then found the curve at
    /// bars 9→11 (-18.4 / -11.6 / -7.9 / -5.1 / -2.1 dB) with bars 2-4 flat at
    /// the track's static -5.1. The reader was right the whole time.
    ///
    /// A bar PAST the range is a jump, never a crossing: bars are seconds
    /// long and the sync polls every 10 ms.
    func testABarPastTheRangeIsNeverTheCrossingEvenAfterAPreRollSighting() {
        XCTAssertEqual(
            MCUController.rollSyncVerdict(observedBar: 9, firstBar: 2, sawPreRoll: true),
            .startedPastRange
        )
        XCTAssertEqual(
            MCUController.rollSyncVerdict(observedBar: 3, firstBar: 2, sawPreRoll: true),
            .startedPastRange
        )
        XCTAssertEqual(
            MCUController.rollSyncVerdict(observedBar: 41, firstBar: 40, sawPreRoll: true),
            .startedPastRange
        )
    }

    /// The other half of the same fix: a pre-roll reading only counts when
    /// the display has MOVED off the park. The parked reading itself is not
    /// evidence of a roll, and neither is a display that cannot be parsed.
    func testOnlyAMovedDisplayIsEvidenceOfARoll() {
        let parked = MCUTimecodeReading.beats(bar: 1, beat: 1, division: 1, ticks: 1)
        XCTAssertFalse(
            MCUController.rollHasLeftThePark(parked: parked, observed: parked),
            "the parked reading repeated is a repaint that has not happened, not a roll"
        )
        XCTAssertTrue(
            MCUController.rollHasLeftThePark(
                parked: parked,
                observed: .beats(bar: 1, beat: 1, division: 2, ticks: 30)
            ),
            "a sub-beat advance inside the pre-roll bar IS the transport moving"
        )
        XCTAssertTrue(
            MCUController.rollHasLeftThePark(
                parked: parked, observed: .beats(bar: 9, beat: 1, division: 1, ticks: 139)
            )
        )
        for unreadable: MCUTimecodeReading in [
            .notReported, .alert, .implausible(reason: "SMPTE")
        ] {
            XCTAssertFalse(
                MCUController.rollHasLeftThePark(parked: parked, observed: unreadable),
                "\(unreadable) says nothing about whether the transport moved"
            )
        }
    }

    /// A pre-roll bar several bars before the range still only ever reports
    /// pre-roll — the crossing is a bar test, not a distance test.
    func testAnyBarBelowTheRangeIsPreRoll() {
        for bar in 1...39 {
            XCTAssertEqual(
                MCUController.rollSyncVerdict(observedBar: bar, firstBar: 40, sawPreRoll: bar > 1),
                .preRoll,
                "bar \(bar)"
            )
        }
    }

    /// The refusal names both bars, says nothing was written, and — since
    /// 2026-09-03 — names the cause and the ONE thing that actually moves
    /// Logic's play-start position. `logic_set_playhead` is named as the tool
    /// that CANNOT do it, because that is the call an agent would otherwise
    /// retry forever: the playhead was verifiably parked all five times and
    /// playback still began at bar 9.
    func testStartedPastRangeErrorNamesBothBarsAndSaysNothingWasWritten() {
        let message = MCUController.rollStartedPastRangeError(
            observedBar: 51, firstBar: 40, restored: true
        ).localizedDescription
        XCTAssertTrue(message.contains("bar 39"), message)
        XCTAssertTrue(message.contains("bar 40"), message)
        XCTAssertTrue(message.contains("bar 51"), message)
        XCTAssertTrue(message.contains("nothing was written"), message)
        XCTAssertTrue(message.contains("logic_set_playhead"), message)
        XCTAssertTrue(message.lowercased().contains("last play-start position"), message)
        XCTAssertTrue(message.contains("ruler"), message)
        XCTAssertTrue(message.contains("logic_read_automation"), message)
    }

    // MARK: - How far the crossing still is (the arming lead)

    /// The arm has to fire a fixed distance before the bar line whatever the
    /// pre-roll started at — `setPlayhead` carries a sub-beat residue along, so
    /// counting milliseconds from roll start can miss the crossing by most of a
    /// beat.
    func testMsToNextBarLineReadsHowFarThroughTheBarLogicIs() {
        let barMs = 2000.0
        XCTAssertEqual(
            MCUController.msToNextBarLine(
                reading: .beats(bar: 1, beat: 1, division: 0, ticks: 0),
                beatSlots: 4, barMs: barMs
            ),
            2000
        )
        XCTAssertEqual(
            MCUController.msToNextBarLine(
                reading: .beats(bar: 1, beat: 3, division: 1, ticks: 1),
                beatSlots: 4, barMs: barMs
            ),
            1000
        )
        // Beat 4, division 4, tick 217: 0.975 beats past the beat — the shape
        // of a parked playhead's measured residue, 12.5 ms short of the bar
        // line in a 2 s bar.
        let almost = MCUController.msToNextBarLine(
            reading: .beats(bar: 1, beat: 4, division: 4, ticks: 217),
            beatSlots: 4, barMs: barMs
        )
        XCTAssertNotNil(almost)
        XCTAssertEqual(almost ?? -1, 12.5, accuracy: 0.1)
        // A bar with six display beats (6/8) is still one bar long.
        XCTAssertEqual(
            MCUController.msToNextBarLine(
                reading: .beats(bar: 1, beat: 4, division: 0, ticks: 0),
                beatSlots: 6, barMs: 1500
            ),
            750
        )
        for reading in [
            MCUTimecodeReading.notReported, .alert, .implausible(reason: "SMPTE")
        ] {
            XCTAssertNil(
                MCUController.msToNextBarLine(reading: reading, beatSlots: 4, barMs: barMs)
            )
        }
    }

    // MARK: - The pre-roll argument rule (checked before any map is read)

    func testPreRollBarRefusesBarOneAndAnswersTheParkBarOtherwise() {
        XCTAssertThrowsError(try MCUController.automationPreRollBar(firstBar: 1)) { error in
            guard case LogicianError.invalidArguments(let text) = error else {
                return XCTFail("expected invalidArguments, got \(error)")
            }
            XCTAssertTrue(text.contains("bar >= 2"), text)
        }
        XCTAssertThrowsError(try MCUController.automationPreRollBar(firstBar: 0))
        XCTAssertEqual(try? MCUController.automationPreRollBar(firstBar: 2), 1)
        XCTAssertEqual(try? MCUController.automationPreRollBar(firstBar: 41), 40)
    }

    // MARK: - The precondition a headerless strip can never pass

    /// The refusal has to name the CAUSE and the way out. The old one said
    /// "Readback mismatch … the strip still shows '?'", which reads as a
    /// transient worth retrying at 10.4 s a go.
    func testHeaderlessRefusalNamesTheCauseAndTheAlternative() {
        guard case LogicianError.preconditionUnmet(let text) =
            MCUController.headerlessAutomationRefusal(trackName: "Aux 1") else {
            return XCTFail("a headerless strip is a precondition, not a readback mismatch")
        }
        XCTAssertTrue(text.contains("'Aux 1'"), text)
        XCTAssertTrue(text.contains("no track header"), text)
        XCTAssertTrue(text.contains("no automation mode"), text)
        XCTAssertTrue(text.contains("Automate the tracks feeding the bus"), text)
        XCTAssertFalse(text.lowercased().contains("readback mismatch"), text)
    }

    /// A strip whose reading publishes no automation row is headerless, and
    /// one that publishes a mode is usable — the distinction
    /// `automationModeLabel`'s single `nil` could not make.
    func testAvailabilityTellsAHeaderlessStripFromAModeItCanRead() {
        var headerless = ChannelStripReading()
        headerless.volumeDB = -0.1
        XCTAssertEqual(
            MCUController.availability(from: headerless), .headerless(volumeDb: -0.1)
        )
        var track = ChannelStripReading()
        track.automationMode = "Latch"
        track.volumeDB = -20
        XCTAssertEqual(
            MCUController.availability(from: track),
            .publishes(mode: "Latch", volumeDb: -20)
        )
    }

    // MARK: - The fader calibration cache: scoping and the cross-check

    /// The saving is ten seconds a call; the risk is a fader map measured
    /// against another Logic build or another project. A stamped file must not
    /// decode into a different scope — that is what makes reuse safe.
    func testACalibrationTableCannotBeInheritedByAnotherScope() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("logician-fader-calibration-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var table = FaderCalibrationTable.empty
        table.record(db: -20, position: 5293)
        table.record(db: -14, position: 6702)
        saveScopedCache(table, to: url, scope: "v1|logic 11.2 (1)|/Songs/A.logicx")

        XCTAssertEqual(
            loadScopedCache(url, scope: "v1|logic 11.2 (1)|/Songs/A.logicx",
                            as: FaderCalibrationTable.self),
            table
        )
        for foreign in [
            "v2|logic 11.2 (1)|/Songs/A.logicx",          // another server build
            "v1|logic 11.3 (7)|/Songs/A.logicx",          // another Logic build
            "v1|logic 11.2 (1)|/Songs/B.logicx"           // another project
        ] {
            XCTAssertNil(
                loadScopedCache(url, scope: foreign, as: FaderCalibrationTable.self),
                foreign
            )
        }
        // No scope at all (Logic closed, no project) is treated as absent,
        // never as "any scope will do".
        XCTAssertNil(loadScopedCache(url, scope: nil, as: FaderCalibrationTable.self))
    }

    func testTableKeysDbAtOneDecimalAndAnswersFromIt() {
        var table = FaderCalibrationTable.empty
        XCTAssertTrue(table.isEmpty)
        table.record(db: -20.02, position: 5293)
        XCTAssertEqual(table.count, 1)
        XCTAssertEqual(table.position(forDb: -20), 5293)
        XCTAssertEqual(table.position(forDb: -19.97), 5293)
        XCTAssertNil(table.position(forDb: -19.5))
        table.record(db: -20, position: 5270)
        XCTAssertEqual(table.count, 1, "the same dB is one entry, refreshed")
        XCTAssertEqual(table.position(forDb: -20), 5270)
    }

    func testCrossCheckNeedsATableADbAndAnEcho() {
        var table = FaderCalibrationTable.empty
        table.record(db: -20, position: 5293)
        func verdict(
            _ table: FaderCalibrationTable?, _ db: Double?, _ fader: Int?
        ) -> MCUController.FaderCalibrationCrossCheck {
            MCUController.faderCalibrationCrossCheck(table: table, liveDb: db, liveFader: fader)
        }
        XCTAssertEqual(verdict(nil, -20, 5293), .unavailable(
            "no cached fader map for this Logic build and project"
        ))
        XCTAssertEqual(verdict(.empty, -20, 5293), .unavailable(
            "no cached fader map for this Logic build and project"
        ))
        if case .unavailable = verdict(table, nil, 5293) {} else {
            XCTFail("no strip dB is no evidence")
        }
        if case .unavailable = verdict(table, -20, nil) {} else {
            XCTFail("no fader echo is no evidence")
        }
        if case .unavailable = verdict(table, -20, -1) {} else {
            XCTFail("a negative echo is Logic saying nothing, not a position")
        }
        if case .unavailable = verdict(table, -6, 9000) {} else {
            XCTFail("a dB the table does not hold cannot confirm it")
        }
    }

    /// The measured process-to-process spread was 23 units; the tolerance is
    /// 250 and the pass's own per-point verification accepts 500. A table
    /// inside the tolerance is trusted, one outside it is retired.
    func testCrossCheckConfirmsWithinToleranceAndContradictsOutsideIt() {
        var table = FaderCalibrationTable.empty
        table.record(db: -20, position: 5293)
        let confirmed = MCUController.faderCalibrationCrossCheck(
            table: table, liveDb: -20, liveFader: 5270
        )
        XCTAssertEqual(confirmed, .confirmed(db: -20, cached: 5293, live: 5270))
        XCTAssertTrue(confirmed.trustsCache)
        XCTAssertEqual(confirmed.payload["verdict"] as? String, "confirmed")

        let edge = MCUController.faderCalibrationCrossCheck(
            table: table, liveDb: -20, liveFader: 5293 - MCUController.faderCalibrationTolerance
        )
        XCTAssertTrue(edge.trustsCache, "exactly on the tolerance is inside it")

        let contradicted = MCUController.faderCalibrationCrossCheck(
            table: table, liveDb: -20, liveFader: 5293 - MCUController.faderCalibrationTolerance - 1
        )
        XCTAssertEqual(contradicted, .contradicted(
            db: -20, cached: 5293, live: 5293 - MCUController.faderCalibrationTolerance - 1
        ))
        XCTAssertFalse(contradicted.trustsCache)
        XCTAssertEqual(contradicted.payload["verdict"] as? String, "contradicted")
    }

    /// With no table there is nothing to reuse, so every DISTINCT dB is
    /// measured exactly once — the behaviour that shipped before the cache
    /// existed.
    func testWithoutATableEachDistinctDbIsMeasuredOnce() throws {
        var asked: [Double] = []
        let resolved = try MCUController.resolveFaderCalibration(
            targets: [-20, -14, -20, -14, -20], liveDb: nil, liveFader: nil, table: nil,
            measure: { db in
                asked.append(db)
                return db == -20 ? 5293 : 6702
            }
        )
        XCTAssertEqual(asked.sorted(), [-20, -14].sorted())
        XCTAssertEqual(resolved.map[-20], 5293)
        XCTAssertEqual(resolved.map[-14], 6702)
        XCTAssertEqual(resolved.measured.sorted(), [-20, -14].sorted())
        XCTAssertEqual(resolved.evidence["source"] as? String, "measured")
        XCTAssertFalse(resolved.retire)
    }

    /// The saving, and the evidence it rests on: a table confirmed by the
    /// strip's own static dB serves every value it holds, and no fader moves.
    func testAConfirmedTableServesEveryValueAndMovesNoFader() throws {
        var table = FaderCalibrationTable.empty
        table.record(db: -20, position: 5293)
        table.record(db: -14, position: 6702)
        let resolved = try MCUController.resolveFaderCalibration(
            targets: [-14, -20], liveDb: -20, liveFader: 5270, table: table,
            measure: { db in
                XCTFail("nothing should be measured on a confirmed table (asked \(db))")
                return 0
            }
        )
        XCTAssertEqual(resolved.map, [-20: 5293, -14: 6702])
        XCTAssertTrue(resolved.measured.isEmpty)
        XCTAssertEqual(resolved.evidence["source"] as? String, "cached")
        XCTAssertFalse(resolved.retire)
    }

    /// No pair to check against: the FIRST live converge becomes the pair, and
    /// when it agrees the rest of the table is served. One measurement instead
    /// of all of them.
    func testTheFirstConverseDoublesAsTheCrossCheckWhenTheStripCannotProvideOne() throws {
        var table = FaderCalibrationTable.empty
        table.record(db: -20, position: 5293)
        table.record(db: -14, position: 6702)
        var asked: [Double] = []
        let resolved = try MCUController.resolveFaderCalibration(
            targets: [-14, -20], liveDb: 0, liveFader: 12000, table: table,
            measure: { db in
                asked.append(db)
                return 5270 // the -20 dB converge, 23 units from the cached one
            }
        )
        XCTAssertEqual(asked, [-20], "the lowest target is measured, then the table is trusted")
        XCTAssertEqual(resolved.map[-20], 5270, "the freshly measured value wins for itself")
        XCTAssertEqual(resolved.map[-14], 6702)
        XCTAssertEqual(resolved.evidence["source"] as? String, "mixed")
        XCTAssertFalse(resolved.retire)
        // The free pair the strip WAS able to give is recorded for next time.
        XCTAssertEqual(resolved.table.position(forDb: 0), 12000)
    }

    /// With no static pair, the value the table ALREADY HOLDS is the one worth
    /// measuring first: it is the only one whose converge can confirm the rest.
    /// Measuring the other one first would produce no evidence and cost both.
    func testTheMeasurementOrderPrefersAValueTheTableCanConfirm() throws {
        var table = FaderCalibrationTable.empty
        table.record(db: -6, position: 9500)
        var asked: [Double] = []
        let resolved = try MCUController.resolveFaderCalibration(
            targets: [-20, -6], liveDb: nil, liveFader: nil, table: table,
            measure: { db in
                asked.append(db)
                return db == -6 ? 9480 : 5340
            }
        )
        XCTAssertEqual(asked, [-6, -20], "the cached value is measured first")
        XCTAssertEqual(resolved.evidence["source"] as? String, "measured")
        XCTAssertEqual(
            (resolved.evidence["cross_check"] as? [String: Any])?["verdict"] as? String,
            "confirmed"
        )
    }

    /// A table that disagrees with the live pair is retired and every value
    /// re-measured — a cache caught out is deleted, never narrowed.
    func testAContradictedTableIsRetiredAndEverythingIsMeasuredAgain() throws {
        var table = FaderCalibrationTable.empty
        table.record(db: -20, position: 5293)
        table.record(db: -14, position: 6702)
        var asked: [Double] = []
        let resolved = try MCUController.resolveFaderCalibration(
            targets: [-14, -20], liveDb: -20, liveFader: 9000, table: table,
            measure: { db in
                asked.append(db)
                return db == -20 ? 8800 : 9600
            }
        )
        XCTAssertEqual(asked.sorted(), [-20, -14].sorted())
        XCTAssertTrue(resolved.retire)
        XCTAssertEqual(resolved.map, [-20: 8800, -14: 9600])
        XCTAssertEqual(resolved.evidence["retired_cache"] as? Bool, true)
        XCTAssertEqual(
            (resolved.evidence["cross_check"] as? [String: Any])?["verdict"] as? String,
            "contradicted"
        )
        XCTAssertNil(
            resolved.table.position(forDb: 6702),
            "nothing from the retired table survives except what was re-measured"
        )
    }

    /// And the same when the contradiction only shows up on the first live
    /// converge: the rest is measured rather than served.
    func testAConvergeThatContradictsTheTableRetiresItMidCall() throws {
        var table = FaderCalibrationTable.empty
        table.record(db: -20, position: 5293)
        table.record(db: -14, position: 6702)
        var asked: [Double] = []
        let resolved = try MCUController.resolveFaderCalibration(
            targets: [-14, -20], liveDb: nil, liveFader: nil, table: table,
            measure: { db in
                asked.append(db)
                return db == -20 ? 9000 : 9600
            }
        )
        XCTAssertEqual(asked.sorted(), [-20, -14].sorted())
        XCTAssertTrue(resolved.retire)
        XCTAssertEqual(resolved.map, [-20: 9000, -14: 9600])
    }

    // MARK: - Which bar's time signature the offsets are measured in

    /// `getTransport`'s signature is the one AT THE PLAYHEAD. With a playhead
    /// parked in a 5/4 bar and a curve in a 4/4 one, the map has to win.
    func testBeatsPerBarComesFromTheMapAtTheFirstPointNotFromThePlayhead() {
        guard let variable = MeterMap(
            events: [
                MeterEvent(bar: 1, numerator: 4, denominator: 4),
                MeterEvent(bar: 41, numerator: 5, denominator: 4)
            ],
            source: .signatureList
        ) else { return XCTFail("invalid test meter map") }
        XCTAssertEqual(
            MCUController.automationBeatsPerBar(
                firstBar: 2, meterKnowledge: variable, transportSignature: "5/4"
            ),
            4
        )
        XCTAssertEqual(
            MCUController.automationBeatsPerBar(
                firstBar: 41, meterKnowledge: variable, transportSignature: "4/4"
            ),
            5
        )
    }

    /// A CONSTANT map read from the Signature List answers exactly what the
    /// control bar would have, so a constant-meter project's placement is
    /// unchanged — and an x/8 signature is finally right: the old parse took
    /// the numerator alone and called 6/8 six beats a bar.
    func testReadConstantMapMatchesTheControlBarAndFixesEighthSignatures() {
        func read(_ numerator: Int, _ denominator: Int) -> MeterMap? {
            MeterMap(
                events: [MeterEvent(bar: 1, numerator: numerator, denominator: denominator)],
                source: .signatureList
            )
        }
        for (numerator, denominator) in [(4, 4), (3, 4), (5, 4), (2, 2)] {
            guard let map = read(numerator, denominator) else {
                return XCTFail("invalid constant map")
            }
            XCTAssertEqual(
                MCUController.automationBeatsPerBar(
                    firstBar: 9, meterKnowledge: map,
                    transportSignature: "\(numerator)/\(denominator)"
                ),
                Double(numerator) * 4 / Double(denominator)
            )
        }
        guard let sixEight = read(6, 8) else { return XCTFail("invalid constant map") }
        XCTAssertEqual(
            MCUController.automationBeatsPerBar(
                firstBar: 2, meterKnowledge: sixEight, transportSignature: "6/8"
            ),
            3
        )
    }

    /// A `singleReading` map is the control bar wearing the map's clothes, not
    /// evidence about the signature track, so it must not override the reading
    /// it came from — the type's own contract.
    func testASingleReadingMapDoesNotOverrideTheControlBar() {
        guard let borrowed = MeterMap.constant(numerator: 5, denominator: 4) else {
            return XCTFail("invalid constant map")
        }
        XCTAssertEqual(
            MCUController.automationBeatsPerBar(
                firstBar: 2, meterKnowledge: borrowed, transportSignature: "4/4"
            ),
            4
        )
    }

    /// No readable map: the control bar, exactly as before — and 4 when even
    /// that says nothing.
    func testWithoutAMapTheControlBarStillAnswers() {
        XCTAssertEqual(
            MCUController.automationBeatsPerBar(
                firstBar: 2, meterKnowledge: nil, transportSignature: "3/4"
            ),
            3
        )
        XCTAssertEqual(
            MCUController.automationBeatsPerBar(
                firstBar: 2, meterKnowledge: nil, transportSignature: nil
            ),
            4
        )
    }
}
