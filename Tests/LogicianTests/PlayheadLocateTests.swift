import XCTest
@testable import Logician

/// The pure decisions inside `convergeSlider` — the shared playhead stepper
/// behind `logic_set_playhead`, `logic_set_cycle_range` and 14 more call
/// sites — and the ruler-visibility geometry `setCycleRange` recovers with.
///
/// The loop itself needs a live Accessibility tree (the CI grep forbids one
/// here), so what is pinned is the part that decides WITHOUT one: the write
/// budget, the pre-write range refusal, the unrequested-beat verdict, and
/// which way the ruler has to move.
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

    // MARK: - Ruler visibility (defect: a valid range dragged out of reach)

    func testARangeWellInsideTheRulerIsVisible() {
        XCTAssertTrue(RulerVisibility.isVisible(
            startX: 200, endX: 400, rulerMinX: 100, rulerMaxX: 900, margin: 30
        ))
    }

    func testARangeTouchingTheEdgeIsNotVisibleEnoughToDragOn() {
        XCTAssertFalse(RulerVisibility.isVisible(
            startX: 110, endX: 400, rulerMinX: 100, rulerMaxX: 900, margin: 30
        ))
        XCTAssertFalse(RulerVisibility.isVisible(
            startX: 200, endX: 880, rulerMinX: 100, rulerMaxX: 900, margin: 30
        ))
    }

    func testAVisibleRangeNeedsNoShift() {
        XCTAssertEqual(RulerVisibility.shiftToReveal(
            startX: 200, endX: 400, rulerMinX: 100, rulerMaxX: 900, margin: 30
        ), 0)
    }

    func testARangeOffTheLeftMovesTheContentRight() {
        let shift = RulerVisibility.shiftToReveal(
            startX: -50, endX: 150, rulerMinX: 100, rulerMaxX: 900, margin: 30
        )
        XCTAssertEqual(shift, 180)
    }

    func testARangeOffTheRightMovesTheContentLeft() {
        let shift = RulerVisibility.shiftToReveal(
            startX: 800, endX: 1000, rulerMinX: 100, rulerMaxX: 900, margin: 30
        )
        XCTAssertEqual(shift, -130)
    }

    /// The property the recovery depends on: applying the shift it asks for
    /// makes the range visible, from either side.
    func testApplyingTheShiftMakesTheRangeVisible() {
        for (startX, endX) in [(-50.0, 150.0), (800.0, 1000.0), (-400.0, -200.0), (2000.0, 2100.0)] {
            let shift = RulerVisibility.shiftToReveal(
                startX: startX, endX: endX, rulerMinX: 100, rulerMaxX: 900, margin: 30
            )
            XCTAssertTrue(
                RulerVisibility.isVisible(
                    startX: startX + shift, endX: endX + shift,
                    rulerMinX: 100, rulerMaxX: 900, margin: 30
                ),
                "shifting (\(startX), \(endX)) by \(shift) should reveal it"
            )
        }
    }

    /// A span wider than the window can never fit; the recovery brings its
    /// START into view, because that is the edge the drag begins on.
    func testASpanWiderThanTheWindowRevealsItsStart() {
        let shift = RulerVisibility.shiftToReveal(
            startX: -500, endX: 2000, rulerMinX: 100, rulerMaxX: 900, margin: 30
        )
        XCTAssertEqual(-500 + shift, 130)
    }
}
