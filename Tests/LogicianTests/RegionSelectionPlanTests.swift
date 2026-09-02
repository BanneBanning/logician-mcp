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
    /// and the already-selected target is still a no-op. Nothing was written,
    /// so there is nothing to prove afterwards either.
    func testANonExclusiveSelectionLeavesEverySiblingSelected() {
        let plan = LogicAccessibility.regionSelectionPlan(
            targetSelected: true, exclusive: false, otherSelectedCount: 3
        )
        XCTAssertFalse(plan.clearSiblings)
        XCTAssertEqual(plan.siblingsToClear, 0)
        XCTAssertFalse(plan.writeTarget)
        XCTAssertFalse(plan.reproveAfterClear)
        XCTAssertFalse(plan.provePriorSelection)
    }

    /// D2, and the whole reason `exclusive: false` was a lie. The keyboard
    /// focus write is the thing that collapses Logic's selection onto one
    /// region — measured 2026-09-02, written ALONE with no `AXSelected` write
    /// anywhere in the call, it took four selected regions across four tracks
    /// down to one. It may go out on the exclusive path, where the collapse is
    /// what was asked for, and never on the additive one.
    func testTheFocusWriteIsExclusiveOnly() {
        for otherSelected in [0, 1, 5] {
            for targetSelected in [true, false] {
                XCTAssertTrue(
                    LogicAccessibility.regionSelectionPlan(
                        targetSelected: targetSelected, exclusive: true,
                        otherSelectedCount: otherSelected
                    ).focusTarget,
                    "exclusive, others: \(otherSelected), selected: \(targetSelected)"
                )
                XCTAssertFalse(
                    LogicAccessibility.regionSelectionPlan(
                        targetSelected: targetSelected, exclusive: false,
                        otherSelectedCount: otherSelected
                    ).focusTarget,
                    "additive, others: \(otherSelected), selected: \(targetSelected)"
                )
            }
        }
    }

    /// An additive call that WRITES has to count the arrangement again: the
    /// regions that were selected before it are the ones the defect used to
    /// take away, and only a fresh count can say they are still there.
    func testAnAdditiveWriteOverAnExistingSelectionIsProved() {
        XCTAssertTrue(
            LogicAccessibility.regionSelectionPlan(
                targetSelected: false, exclusive: false, otherSelectedCount: 2
            ).provePriorSelection
        )
    }

    /// The proof is owed only where something could have been lost. Nothing
    /// else selected means there is nothing to lose; an already-selected
    /// target means nothing was written; and the exclusive path DELIBERATELY
    /// takes the siblings away, so counting them again would be counting its
    /// own contract as a failure.
    func testNothingWrittenOrNothingAtRiskNeedsNoRecount() {
        XCTAssertFalse(
            LogicAccessibility.regionSelectionPlan(
                targetSelected: false, exclusive: false, otherSelectedCount: 0
            ).provePriorSelection, "nothing else was selected"
        )
        XCTAssertFalse(
            LogicAccessibility.regionSelectionPlan(
                targetSelected: true, exclusive: false, otherSelectedCount: 4
            ).provePriorSelection, "already selected: nothing is written"
        )
        XCTAssertFalse(
            LogicAccessibility.regionSelectionPlan(
                targetSelected: false, exclusive: true, otherSelectedCount: 4
            ).provePriorSelection, "exclusive clears them on purpose"
        )
    }

    /// A recount that adds up is a plain success — no warning key at all,
    /// because a warning nobody needs is a warning the next one hides behind.
    func testAnAdditiveSelectionThatGrewCarriesNoWarning() {
        let outcome = LogicAccessibility.additiveSelectionOutcome(expected: 3, observed: 3)
        XCTAssertEqual(outcome.selectedCount, 3)
        XCTAssertNil(outcome.warning)
    }

    /// The defect's own shape, reported honestly: three regions should be
    /// selected, Logic published one. The call DID select its target, so this
    /// is a warning on a successful selection rather than a throw — and it has
    /// to say how many went, and where the working route is.
    func testAnAdditiveSelectionThatCollapsedWarnsAndNamesTheAlternative() throws {
        let outcome = LogicAccessibility.additiveSelectionOutcome(expected: 3, observed: 1)
        XCTAssertEqual(outcome.selectedCount, 1)
        let warning = try XCTUnwrap(outcome.warning)
        XCTAssertTrue(warning.contains("2 that were selected before this call"), warning)
        XCTAssertTrue(warning.contains("logic_select_regions"), warning)
    }

    /// MORE regions selected than were counted is not this tool's failure —
    /// a scrolled-in row or the user's own click can do it — and the count is
    /// reported as read rather than dressed up as a warning.
    func testMoreSelectedThanExpectedIsNotAWarning() {
        let outcome = LogicAccessibility.additiveSelectionOutcome(expected: 2, observed: 5)
        XCTAssertEqual(outcome.selectedCount, 5)
        XCTAssertNil(outcome.warning)
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
