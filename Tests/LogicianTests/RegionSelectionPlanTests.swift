import XCTest
@testable import Logician

/// The read-before-write decision inside `selectRegion`.
///
/// Writing `AXSelected = true` onto a region that is ALREADY selected makes
/// Logic republish the layout item, so the readback lands on a stale element
/// and reports NOT selected for longer than 300 ms. The "stale-element
/// transient" retry then fired on every idempotent call: 8/8 live samples on
/// 2026-09-02, 1116–1125 ms for an already-selected target against 305–306 ms
/// for a genuine change. Reading the attribute first is the whole cure — but
/// only if the `exclusive:` contract survives the shortcut, which is what
/// these pin: an already-selected target is never an excuse to leave a sibling
/// selected, because the caller's next key command would take that one too.
final class RegionSelectionPlanTests: XCTestCase {

    /// The COLD shape, and the one that used to cost 1.1 s: the target is
    /// already selected AND two of its siblings are too. Nothing is written to
    /// the target; the siblings are still cleared; and because that clear
    /// writes to the same rendered rows, the skip has to be re-proved by a
    /// second read afterwards rather than taken on trust.
    func testAnAlreadySelectedTargetStillClearsItsSiblings() {
        let plan = LogicAccessibility.regionSelectionPlan(
            targetSelected: true, exclusive: true, otherSelectedCount: 2
        )
        XCTAssertFalse(plan.writeTarget)
        XCTAssertTrue(plan.clearSiblings)
        XCTAssertEqual(plan.siblingsToClear, 2)
        XCTAssertTrue(plan.reproveAfterClear)
    }

    /// Already selected with nothing else selected: the call touches Logic not
    /// at all, and there is no clear that could have disturbed the target, so
    /// the pre-read stands as the proof.
    func testAnAlreadySelectedTargetAloneWritesNothingAndNeedsNoSecondRead() {
        let plan = LogicAccessibility.regionSelectionPlan(
            targetSelected: true, exclusive: true, otherSelectedCount: 0
        )
        XCTAssertFalse(plan.writeTarget)
        XCTAssertEqual(plan.siblingsToClear, 0)
        XCTAssertFalse(plan.reproveAfterClear)
    }

    /// `exclusive: false` means the caller wants this region ADDED to whatever
    /// is selected. The siblings are left alone however many of them there are,
    /// and the already-selected target is still a no-op.
    func testANonExclusiveSelectionLeavesEverySiblingSelected() {
        let plan = LogicAccessibility.regionSelectionPlan(
            targetSelected: true, exclusive: false, otherSelectedCount: 3
        )
        XCTAssertFalse(plan.clearSiblings)
        XCTAssertEqual(plan.siblingsToClear, 0)
        XCTAssertFalse(plan.writeTarget)
        XCTAssertFalse(plan.reproveAfterClear)
    }

    /// A target that is NOT selected is a genuine change: the write happens,
    /// with the retry behind it, and there is nothing to re-prove because the
    /// write's own readback is the proof.
    func testAnUnselectedTargetIsWritten() {
        let changed = LogicAccessibility.regionSelectionPlan(
            targetSelected: false, exclusive: true, otherSelectedCount: 1
        )
        XCTAssertTrue(changed.writeTarget)
        XCTAssertEqual(changed.siblingsToClear, 1)
        XCTAssertFalse(changed.reproveAfterClear)

        let alone = LogicAccessibility.regionSelectionPlan(
            targetSelected: false, exclusive: false, otherSelectedCount: 0
        )
        XCTAssertTrue(alone.writeTarget)
        XCTAssertFalse(alone.clearSiblings)
        XCTAssertFalse(alone.reproveAfterClear)
    }

    /// The re-prove is about a WRITE having happened to the rows, not about how
    /// many regions were selected: no clear, no second read, on either
    /// exclusivity setting.
    func testNoClearMeansNoSecondRead() {
        for exclusive in [true, false] {
            XCTAssertFalse(
                LogicAccessibility.regionSelectionPlan(
                    targetSelected: true, exclusive: exclusive, otherSelectedCount: 0
                ).reproveAfterClear,
                "exclusive: \(exclusive)"
            )
        }
    }
}
