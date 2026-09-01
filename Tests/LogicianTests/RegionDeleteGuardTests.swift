import XCTest
@testable import Logician

/// The decisions in front of `logic_delete_region`'s Delete.
///
/// Logic's Delete is project-wide; the arrangement map is not. The tool used to
/// promise the first while checking the second — a count over RENDERED track
/// rows only, an exclusive-clear that reached the same rendered rows only, and
/// an after-check that compared region counts on the target track alone. On the
/// sandbox project (`partial: true`, `missing_track_numbers: [10…19]`, a
/// collapsed `9 “Drum Synth Kit”` stack) a Delete that also took regions off
/// those hidden rows passed all three and reported `success: true`.
///
/// These pin the replacement without Logic running: what counts as a row this
/// walk cannot see, what the tool does about it, and what the after-check calls
/// a delete that removed more than one region.
final class RegionDeleteGuardTests: XCTestCase {

    private func headers(_ numbers: [Int], collapsedStacks: [Int] = []) -> [TrackListCompleteness.Row] {
        numbers.map {
            TrackListCompleteness.Row(
                number: $0, name: "T\($0)",
                isStack: collapsedStacks.contains($0),
                expanded: collapsedStacks.contains($0) ? false : nil
            )
        }
    }

    private func coverage(
        headerNumbers: [Int],
        regionRowNumbers: [Int]? = nil,
        scrollable: Bool? = false,
        collapsedStacks: [Int] = []
    ) -> RegionDeleteGuard.Coverage {
        RegionDeleteGuard.coverage(
            trackVerdict: TrackListCompleteness.evaluate(
                rows: headers(headerNumbers, collapsedStacks: collapsedStacks),
                scrollable: scrollable
            ),
            headerNumbers: headerNumbers,
            regionRowNumbers: regionRowNumbers ?? headerNumbers
        )
    }

    // MARK: Coverage

    /// The baseline: every rendered row has a region row, no gaps, no stacks,
    /// the scroll bar says everything fits. Nothing PROVES a row hidden — and
    /// the verdict is `unknown`, never `complete`, because a row Logic has not
    /// rendered publishes nothing at all.
    func testNothingProvedHiddenIsUnknownNotComplete() {
        let verdict = coverage(headerNumbers: Array(1...8))
        XCTAssertFalse(verdict.partial)
        XCTAssertEqual(verdict.completeness, "unknown")
        XCTAssertNotEqual(verdict.completeness, "complete")
        XCTAssertEqual(verdict.unseenTrackNumbers, [])
        XCTAssertTrue(verdict.reasons.isEmpty)
    }

    /// The sandbox project's own shape, reduced: a numbering gap where a
    /// collapsed stack's subtracks live. Both signals fire, and the missing rows
    /// are NAMED — a refusal that cannot say which rows it means is not
    /// actionable.
    func testCollapsedStackAndNumberingGapAreUnseenRows() {
        let verdict = coverage(
            headerNumbers: [1, 2, 9, 20, 21], collapsedStacks: [9]
        )
        XCTAssertTrue(verdict.partial)
        XCTAssertEqual(verdict.unseenTrackNumbers, [3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19])
        XCTAssertTrue(verdict.reasons.contains { $0.contains("collapsed track stack") })
        XCTAssertTrue(verdict.unseenSentence.contains("10"))
        XCTAssertTrue(verdict.unseenSentence.contains("project-wide"))
    }

    /// A scrolled Tracks area proves rows are out there without being able to
    /// name one. Partial all the same, and the sentence stays empty rather than
    /// inventing numbers.
    func testScrollableIsPartialWithNoNameableRows() {
        let verdict = coverage(headerNumbers: Array(1...8), scrollable: true)
        XCTAssertTrue(verdict.partial)
        XCTAssertEqual(verdict.unseenTrackNumbers, [])
        XCTAssertEqual(verdict.unseenSentence, "")
        XCTAssertTrue(verdict.reasons.contains { $0.contains("scroll") })
    }

    /// The signal the header verdict cannot give: a track row Logic renders a
    /// HEADER for while the arrangement walk finds no region row under it. Its
    /// regions are unreadable, so it is an unseen row like any other.
    func testHeaderWithoutARegionRowCountsAsUnseen() {
        let verdict = coverage(headerNumbers: [1, 2, 3], regionRowNumbers: [1, 3])
        XCTAssertTrue(verdict.partial)
        XCTAssertEqual(verdict.unseenTrackNumbers, [2])
        XCTAssertTrue(verdict.reasons.contains { $0.contains("no rendered region row") })
    }

    /// An unreadable header column is not a clean bill of health. This is the
    /// `(try? parsedTrackHeaders()) ?? []` path, and it must not read as "no
    /// tracks are hidden".
    func testUnreadableHeaderColumnIsPartial() {
        let verdict = RegionDeleteGuard.coverage(
            trackVerdict: TrackListCompleteness.evaluate(rows: [], scrollable: nil),
            headerNumbers: [],
            regionRowNumbers: [1, 2, 3]
        )
        XCTAssertTrue(verdict.partial)
        XCTAssertTrue(verdict.reasons.contains { $0.contains("could not be read") })
    }

    // MARK: The plan

    /// The whole point: with Logic's project-wide clear available, it is used —
    /// on EVERY delete, not only the ones that look partial. `partial: false`
    /// means "nothing proved rows missing", and a destructive command is the
    /// last place to spend an absence of evidence as a guarantee.
    func testTheProjectWideClearIsUsedWheneverItIsAvailable() {
        for verdict in [
            coverage(headerNumbers: Array(1...8)),
            coverage(headerNumbers: [1, 2, 9, 20], collapsedStacks: [9]),
            coverage(headerNumbers: Array(1...8), scrollable: true)
        ] {
            XCTAssertEqual(
                RegionDeleteGuard.plan(coverage: verdict, deselectAllRegistered: true),
                .projectWideClear
            )
        }
    }

    /// No project-wide clear and provably hidden rows: REFUSE, before anything
    /// is written. The message has to carry the rows and both ways out, because
    /// a refusal an agent cannot act on just becomes a retry.
    func testHiddenRowsWithoutTheClearCommandRefuse() {
        let plan = RegionDeleteGuard.plan(
            coverage: coverage(headerNumbers: [1, 2, 9, 20], collapsedStacks: [9]),
            deselectAllRegistered: false
        )
        guard case .refuse(let reason) = plan else {
            return XCTFail("expected a refusal, got \(plan)")
        }
        XCTAssertTrue(reason.contains("Refusing to fire Delete blind"))
        XCTAssertTrue(reason.contains("Nothing was deleted"))
        XCTAssertTrue(reason.contains("logic_set_track_stack"))
        XCTAssertTrue(reason.contains("logic_select_regions"))
        XCTAssertTrue(reason.contains("3, 4, 5"))
    }

    /// No project-wide clear and nothing proving a row hidden: go ahead, and say
    /// precisely what was checked. The warning is not decoration — it is the
    /// difference between this result and the one the tool used to give.
    func testCleanCoverageWithoutTheClearCommandProceedsWithAWarning() {
        let plan = RegionDeleteGuard.plan(
            coverage: coverage(headerNumbers: Array(1...8)), deselectAllRegistered: false
        )
        guard case .renderedRowsOnly(let warning) = plan else {
            return XCTFail("expected rendered-rows-only, got \(plan)")
        }
        XCTAssertTrue(warning.contains("RENDERED track rows only"))
        XCTAssertTrue(warning.contains("not a project-wide proof"))
    }

    // MARK: The after-check

    /// One region gone from the project's rendered total, and it is the one that
    /// was addressed.
    func testExactlyOneRegionGoneIsADelete() {
        XCTAssertEqual(
            RegionDeleteGuard.verify(
                targetStillPresent: false, regionsBefore: 54, regionsAfter: 53
            ),
            .deleted
        )
    }

    /// THE REGRESSION THIS FILE EXISTS FOR. The old check compared counts on the
    /// target track only, so a Delete that took the addressed region AND three
    /// on other rows read as a clean success. Across the whole rendered map it
    /// cannot: four fewer regions is collateral damage, reported as a failure.
    func testACollateralDeleteIsNeverASuccess() {
        XCTAssertEqual(
            RegionDeleteGuard.verify(
                targetStillPresent: false, regionsBefore: 54, regionsAfter: 50
            ),
            .collateral(alsoRemoved: 3)
        )
    }

    /// Delete took something, but not what was asked for.
    func testTheWrongRegionLeavingIsItsOwnVerdict() {
        XCTAssertEqual(
            RegionDeleteGuard.verify(
                targetStillPresent: true, regionsBefore: 54, regionsAfter: 53
            ),
            .wrongRegion(removed: 1)
        )
    }

    /// Nothing moved — the focus-dead Logic answer, and the poll's cue to keep
    /// looking rather than to declare anything.
    func testNothingMovedKeepsPolling() {
        XCTAssertEqual(
            RegionDeleteGuard.verify(
                targetStillPresent: true, regionsBefore: 54, regionsAfter: 54
            ),
            .unchanged
        )
    }

    /// A half-read snapshot — the target gone while the totals have not moved —
    /// is not a verified delete. It keeps polling; at the deadline it refuses.
    func testTargetGoneWithUnmovedTotalsIsNotYetADelete() {
        XCTAssertEqual(
            RegionDeleteGuard.verify(
                targetStillPresent: false, regionsBefore: 54, regionsAfter: 54
            ),
            .unchanged
        )
    }
}
