import XCTest
@testable import Logician

final class RegionTransferTests: XCTestCase {
    private func region(_ start: String = "1 bars", _ end: String = "3 bars", kind: String = "MIDI") throws -> RegionTransfer.Region {
        try XCTUnwrap(RegionTransfer.Region(name: "Take", help: "Region starts at \(start) and ends at \(end) , \(kind) region."))
    }
    private func fixture() throws -> (RegionTransfer.Plan, RegionTransfer.Snapshot) {
        let source = try region()
        let before = [1: RegionTransfer.Row(name: "Source", regions: [source]),
                      2: RegionTransfer.Row(name: "Target", regions: [])]
        let meter = try XCTUnwrap(MeterMap(events: [MeterEvent(bar: 1, numerator: 4, denominator: 4),
            MeterEvent(bar: 5, numerator: 5, denominator: 4)], source: .signatureList))
        return (try RegionTransfer.Plan(before: before, source: source, sourceTrack: 1,
            destinationTrack: 2, toBar: 5, meter: meter), before)
    }
    func testPreciseHelpDoesNotRoundDivisionsOrTicksIntoBeats() throws {
        let parsed = try region("41 bars 4 divisions 200 ticks", "42 bars 4 beats 4 divisions 200 ticks")
        XCTAssertEqual(parsed.start.beat, 1)
        XCTAssertEqual(parsed.start.division, 4)
        XCTAssertEqual(parsed.start.tick, 200)
        XCTAssertEqual(parsed.end.beat, 4)
        XCTAssertNil(RegionTransfer.Position.parse("41 bars garbage"))
        XCTAssertNil(RegionTransfer.Position.parse("41 bars 0 beats"))
        XCTAssertNil(RegionTransfer.Position.parse("41 takter"))
    }
    func testVariableMeterPreservesDurationAndSameTrackMovePreservesNeighbours() throws {
        let (plan, _) = try fixture()
        let copy = try XCTUnwrap(plan.copied[2]?.regions.keys.first)
        // Eight quarter beats starting at bar 5 in 5/4 end at bar 6 beat 4.
        XCTAssertEqual(copy.end.bar, 6)
        XCTAssertEqual(copy.end.beat, 4)
        XCTAssertTrue(plan.moved[1]!.regions.isEmpty)
        let source = try region()
        let neighbour = try region("9 bars", "10 bars")
        let before = [1: RegionTransfer.Row(name: "Source", regions: [source, neighbour])]
        let map = MeterMap(events: [MeterEvent(bar: 1, numerator: 4, denominator: 4)], source: .signatureList)!
        let same = try RegionTransfer.Plan(before: before, source: source, sourceTrack: 1,
            destinationTrack: 1, toBar: 5, meter: map)
        XCTAssertEqual(same.moved[1]?.regions[neighbour], 1)
        XCTAssertNil(same.moved[1]?.regions[source])
        XCTAssertEqual(same.moved[1]?.regions.count, 2)
    }
    func testUnsupportedSourceAndUncertainMeterRefuseBeforeAnyEdit() throws {
        let map = MeterMap(events: [MeterEvent(bar: 1, numerator: 4, denominator: 4)], source: .signatureList)!
        for source in [try region("1 bars 20 ticks"), try region(kind: "Audio")] {
            let before = [1: RegionTransfer.Row(name: "Source", regions: [source])]
            XCTAssertThrowsError(try RegionTransfer.Plan(before: before, source: source,
                sourceTrack: 1, destinationTrack: 1, toBar: 5, meter: map))
        }
        let source = try region()
        let before = [1: RegionTransfer.Row(name: "Source", regions: [source])]
        XCTAssertThrowsError(try RegionTransfer.Plan(before: before, source: source,
            sourceTrack: 1, destinationTrack: 1, toBar: 5, meter: MeterMap.constant(numerator: 4)!))
    }
    func testOverlapAndAmbiguousCopiesAreRefused() throws {
        let source = try region()
        let map = MeterMap(events: [MeterEvent(bar: 1, numerator: 4, denominator: 4)], source: .signatureList)!
        for regions in [[source], [source, source]] {
            XCTAssertThrowsError(try RegionTransfer.Plan(
                before: [1: RegionTransfer.Row(name: "Source", regions: regions)], source: source,
                sourceTrack: 1, destinationTrack: 1, toBar: 2, meter: map))
        }
        let adjacent = try region("3 bars", "5 bars 20 ticks")
        XCTAssertThrowsError(try RegionTransfer.Plan(before: [1: .init(name: "Source", regions: [source]),
            2: .init(name: "Target", regions: [adjacent])], source: source,
            sourceTrack: 1, destinationTrack: 2, toBar: 5, meter: map))
    }
    func testFailuresAtEveryPreDeleteBoundaryNeverRemoveTheSource() throws {
        let (plan, before) = try fixture()
        for failing in ["project", "copy", "witness", "contents", "selection", "drift", "cancel"] {
            var state = before
            var deletes = 0
            var prepared = false
            XCTAssertThrowsError(try RegionTransfer.execute(plan: plan, checkProject: {
                if failing == "project" { throw RegionTransfer.Failure("switched project") }
            }, copy: {
                if failing == "copy" { throw RegionTransfer.Failure("Paste timed out") }
                state = failing == "witness" ? before : plan.copied
            }, verifyCopy: {
                if failing == "contents" { throw RegionTransfer.Failure("stale clipboard has different notes") }
            }, prepareDelete: {
                prepared = true
                if failing == "selection" { throw RegionTransfer.Failure("selection failed") }
                if failing == "drift" { state = before }
            }, snapshot: { state }, delete: {
                deletes += 1
                state = plan.moved
            }, cancelled: { failing == "cancel" && prepared }))
            XCTAssertEqual(deletes, 0, failing)
            XCTAssertEqual(state[1]?.regions[plan.source], 1, failing)
        }
    }
    func testSuccessfulMoveAndUncertainDeleteAreNeverRetriedOrUndone() throws {
        let (plan, _) = try fixture()
        for deleteFails in [false, true] {
            var state = plan.copied
            var deletions = 0
            let operation = {
                try RegionTransfer.execute(plan: plan, checkProject: {}, copy: {},
                    prepareDelete: {}, snapshot: { state }, delete: {
                        deletions += 1
                        state = plan.moved
                        if deleteFails { throw RegionTransfer.Failure("reply lost") }
                    })
            }
            if deleteFails {
                XCTAssertThrowsError(try operation()) { error in
                    XCTAssertTrue(String(describing: error).contains("Delete attempted"))
                    XCTAssertTrue(String(describing: error).contains("no automatic Undo or retry"))
                }
            } else { try operation() }
            XCTAssertEqual(deletions, 1)
            XCTAssertEqual(state, plan.moved)
        }
    }
    func testSameCountWithTrimmedNeighbourFailsVerification() throws {
        let (plan, _) = try fixture()
        var state = plan.copied
        state[2] = .init(name: "Target", regions: [try region("5 bars", "6 bars")])
        var deleted = false
        XCTAssertThrowsError(try RegionTransfer.execute(plan: plan, checkProject: {}, copy: {},
            prepareDelete: {}, snapshot: { state }, delete: { deleted = true }))
        XCTAssertFalse(deleted)
    }
}
