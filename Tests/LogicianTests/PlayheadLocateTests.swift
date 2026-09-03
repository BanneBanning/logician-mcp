import XCTest
@testable import Logician

/// The pure decisions inside `convergeSlider` — the shared LCD stepper behind
/// `logic_set_playhead`, the cycle range's two locator cells and 14 more call
/// sites.
///
/// The loop itself needs a live Accessibility tree (the CI grep forbids one
/// here), so what is pinned is the part that decides WITHOUT one: the write
/// budget and the unrequested-beat verdict.
final class PlayheadLocateTests: XCTestCase {

    // MARK: - The write budget

    func testTheBudgetIsTheDistancePlusAnAllowance() {
        XCTAssertEqual(PlayheadLocate.stepBudget(from: 41, to: 43), 6)
        XCTAssertEqual(PlayheadLocate.stepBudget(from: 64, to: 41), 27)
    }

    func testTheBudgetIsSymmetric() {
        XCTAssertEqual(
            PlayheadLocate.stepBudget(from: 5, to: 40),
            PlayheadLocate.stepBudget(from: 40, to: 5)
        )
    }

    func testTheBudgetIsCappedSoNothingCanSpinAgainstAClamp() {
        XCTAssertEqual(PlayheadLocate.stepBudget(from: 1, to: 100_000), 512)
    }

    func testANoOpStillGetsEnoughBudgetToProveItself() {
        XCTAssertGreaterThan(PlayheadLocate.stepBudget(from: 7, to: 7), 0)
    }

    /// A long locate must be allowed to keep writing: the budget is the whole
    /// distance, because the slider moves one bar per write and nothing here
    /// may cut the walk short. (There is deliberately no pre-write range
    /// check — the slider's own `AXMinValue`/`AXMaxValue` were measured
    /// 2026-09-03 to be a ±1 window around the CURRENT value, not the
    /// project's range; see `convergeSlider`'s comment.)
    func testTheBudgetCoversTheWholeDistanceOfALongLocate() {
        XCTAssertGreaterThanOrEqual(PlayheadLocate.stepBudget(from: 56, to: 1), 55)
        XCTAssertGreaterThanOrEqual(PlayheadLocate.stepBudget(from: 1, to: 400), 399)
    }

    // MARK: - The beat nobody asked about (defect: beat 3 -> 1, silently)

    func testABeatThatMovedOnItsOwnIsPutBack() {
        XCTAssertEqual(
            PlayheadLocate.unrequestedBeatDrift(requested: nil, before: 3, after: 1), 3
        )
    }

    func testABeatTheCallerAskedForIsNeverUndone() {
        XCTAssertNil(PlayheadLocate.unrequestedBeatDrift(requested: 1, before: 3, after: 1))
    }

    func testABeatThatDidNotMoveIsLeftAlone() {
        XCTAssertNil(PlayheadLocate.unrequestedBeatDrift(requested: nil, before: 3, after: 3))
    }

    func testAnUnreadableBeatIsNotGuessedAt() {
        XCTAssertNil(PlayheadLocate.unrequestedBeatDrift(requested: nil, before: nil, after: 1))
        XCTAssertNil(PlayheadLocate.unrequestedBeatDrift(requested: nil, before: 3, after: nil))
    }

    func testTheWarningNamesBothBeatsAndTheOutcome() {
        let restored = PlayheadLocate.beatDriftWarning(from: 3, to: 1, restored: true)
        XCTAssertTrue(restored.contains("3"))
        XCTAssertTrue(restored.contains("1"))
        XCTAssertTrue(restored.contains("put back"))

        let leaked = PlayheadLocate.beatDriftWarning(from: 3, to: 1, restored: false)
        XCTAssertTrue(leaked.contains("NOT"))
        XCTAssertTrue(leaked.contains("logic_set_playhead"), leaked)
    }

}

/// What `logic_set_cycle_range` still asks of the ruler now that it writes
/// the locators as numbers: an ESTIMATE of which bar the cycle region is drawn
/// around — the second witness against the LCD's exact numbers — and the
/// sentence a failed write ends with.
final class RulerBarMappingTests: XCTestCase {

    func testTheBarOfAnOffsetIsRoundedToTheNearestLine() {
        XCTAssertEqual(
            RulerBarMapping.barAt(offset: 210, anchorOffset: 10, anchorBar: 5, pixelsPerBar: 40), 10
        )
        XCTAssertEqual(
            RulerBarMapping.barAt(offset: 205, anchorOffset: 10, anchorBar: 5, pixelsPerBar: 40), 10
        )
    }

    func testTheBarOfAnOffsetIsNeverBeforeTheFirstBar() {
        XCTAssertEqual(
            RulerBarMapping.barAt(offset: -4000, anchorOffset: 10, anchorBar: 5, pixelsPerBar: 40), 1
        )
        XCTAssertEqual(
            RulerBarMapping.barAt(offset: 10, anchorOffset: 10, anchorBar: 5, pixelsPerBar: 0), 5
        )
    }

    func testTheRestoreSentenceNamesWhereTheRangeWentBackTo() {
        let sentence = RulerBarMapping.restoreSentence(
            restored: true, original: "bars 5-9", leftAt: "bars 43-47"
        )
        XCTAssertTrue(sentence.contains("bars 5-9"), sentence)
        XCTAssertFalse(sentence.contains("bars 43-47"), sentence)
    }

    func testTheRestoreSentenceNamesWhereItIsLeftWhenItCannot() {
        let sentence = RulerBarMapping.restoreSentence(
            restored: false, original: "bars 5-9", leftAt: "bars 43-47"
        )
        XCTAssertTrue(sentence.contains("NOT"), sentence)
        XCTAssertTrue(sentence.contains("bars 43-47"), sentence)
        XCTAssertTrue(sentence.contains("logic_set_cycle_range"), sentence)
    }
}
