import ApplicationServices
import XCTest
@testable import Logician

/// The three pure decisions behind the Accessibility strip-reading fixes of
/// 2026-09-03: which row the inspector is showing (`logic_track_info`'s D1),
/// when a look-first stability poll may stop looking (the two blind
/// `Thread.sleep(0.3)` waits it replaced), and what an inspector-strip cache
/// hands back.
///
/// The loops these live in need a live AX walk to exercise end to end, so what
/// IS a pure decision is pinned here — the shape `LookFirstPollTests` already
/// uses for `lookFirstShouldSleep`.
final class StripReadSettleTests: XCTestCase {

    // MARK: - Which row is showing (logic_track_info D1)

    func testTheRowAlreadyShowingNeedsNoSelection() {
        XCTAssertTrue(inspectorAlreadyShows(row: 21, showing: 21))
    }

    func testAnotherRowNeedsASelection() {
        XCTAssertFalse(inspectorAlreadyShows(row: 22, showing: 21))
    }

    /// The defect itself. Rows 21 and 22 of the reference project are both
    /// called `Ivan Vocals`: the old gate compared the two NAMES, found them
    /// equal, skipped row 22's selection and reported row 21's strip under
    /// track_number 22. The numbers differ, so this gate does not.
    func testTwoRowsSharingANameStillGetTheirOwnSelection() {
        let rowTwentyOne = (number: 21, name: "Ivan Vocals")
        let rowTwentyTwo = (number: 22, name: "Ivan Vocals")
        XCTAssertEqual(rowTwentyOne.name, rowTwentyTwo.name, "the sandbox really does name both rows this")
        XCTAssertFalse(
            inspectorAlreadyShows(row: rowTwentyTwo.number, showing: rowTwentyOne.number),
            "row 22 must be selected in its own right, however row 21 is named"
        )
    }

    /// A selection that failed leaves the inspector somewhere unknown, and
    /// unknown must never read as "already there".
    func testAnUnknownSelectionAlwaysNeedsASelection() {
        for row in 1...30 {
            XCTAssertFalse(inspectorAlreadyShows(row: row, showing: nil))
        }
    }

    // MARK: - When a stability poll may stop

    func testAProvenFirstLookIsTakenWithoutWaiting() {
        XCTAssertEqual(
            settleDecision(attempt: 0, budget: 8, proven: true, matchedPrevious: false),
            .accept
        )
    }

    func testAnUnprovenFirstLookLooksAgain() {
        XCTAssertEqual(
            settleDecision(attempt: 0, budget: 8, proven: false, matchedPrevious: false),
            .lookAgain
        )
    }

    /// Attempt 0 has no previous look, so agreement with it means nothing.
    func testTheFirstLookCannotAgreeWithAPreviousOne() {
        XCTAssertEqual(
            settleDecision(attempt: 0, budget: 8, proven: false, matchedPrevious: true),
            .lookAgain
        )
    }

    func testTwoAgreeingLooksSettleIt() {
        XCTAssertEqual(
            settleDecision(attempt: 1, budget: 8, proven: false, matchedPrevious: true),
            .accept
        )
    }

    func testDisagreeingLooksKeepLookingWhileTheBudgetLasts() {
        for attempt in 1..<7 {
            XCTAssertEqual(
                settleDecision(attempt: attempt, budget: 8, proven: false, matchedPrevious: false),
                .lookAgain
            )
        }
    }

    /// The budget running out is its own answer — the caller reports the read
    /// as unproven rather than passing it off as settled.
    func testTheLastLookGivesUpRatherThanClaimingASettle() {
        XCTAssertEqual(
            settleDecision(attempt: 7, budget: 8, proven: false, matchedPrevious: false),
            .giveUp
        )
    }

    func testProofOnTheLastLookStillSettlesIt() {
        XCTAssertEqual(
            settleDecision(attempt: 7, budget: 8, proven: true, matchedPrevious: false),
            .accept
        )
    }

    /// The property the fix buys: a proven first look costs no gap at all, and
    /// the ordinary case costs exactly one.
    func testTheOrdinaryCaseCostsOneGap() {
        var gaps = 0
        var attempt = 0
        while attempt < 6 {
            if lookFirstShouldSleep(attempt: attempt) { gaps += 1 }
            let decision = settleDecision(
                attempt: attempt, budget: 6, proven: false, matchedPrevious: attempt > 0
            )
            if decision == .accept { break }
            attempt += 1
        }
        XCTAssertEqual(gaps, 1)
    }

    // MARK: - What track_names/track_number resolve to

    /// `logic_track_info` matches names case-insensitively and always has;
    /// what changed is that it now resolves them through the track family's
    /// shared rule, so a name carried by two rows refuses instead of silently
    /// meaning the first of them.
    private var duplicateRows: [TrackRowAddressing.Row] {
        [
            TrackRowAddressing.Row(number: 20, name: "Acke Slagverk"),
            TrackRowAddressing.Row(number: 21, name: "Ivan Vocals"),
            TrackRowAddressing.Row(number: 22, name: "Ivan Vocals")
        ]
    }

    func testANameCarriedByTwoRowsRefusesAndNamesTheirNumbers() {
        XCTAssertEqual(
            TrackRowAddressing.resolve(
                rows: duplicateRows, name: "Ivan Vocals", number: nil, caseInsensitive: true
            ),
            .ambiguous(numbers: [21, 22])
        )
    }

    func testTheNumberIsTheWayOutOfTheAmbiguity() {
        XCTAssertEqual(
            TrackRowAddressing.resolve(
                rows: duplicateRows, name: "Ivan Vocals", number: 22, caseInsensitive: true
            ),
            .resolved(number: 22)
        )
    }

    func testCaseStillDoesNotMatterToTrackInfosNames() {
        XCTAssertEqual(
            TrackRowAddressing.resolve(
                rows: duplicateRows, name: "acke slagverk", number: nil, caseInsensitive: true
            ),
            .resolved(number: 20)
        )
    }

    func testANumberNamingADifferentRowIsStillRefused() {
        XCTAssertEqual(
            TrackRowAddressing.resolve(
                rows: duplicateRows, name: "Ivan Vocals", number: 20, caseInsensitive: true
            ),
            .mismatch(number: 20, expected: "Ivan Vocals", actual: "Acke Slagverk")
        )
    }

    // MARK: - The inspector-strip cache

    func testAnEmptyCacheHandsBackNothing() {
        XCTAssertNil(InspectorStripCache()["Bas"])
    }

    func testAStoredStripComesBackUnderItsOwnNameOnly() {
        let cache = InspectorStripCache()
        let element = AXUIElementCreateSystemWide()
        cache.store(element, for: "Bas")
        XCTAssertNotNil(cache["Bas"])
        XCTAssertNil(cache["808"], "a cache hit belongs to one strip name, never to another")
    }

    func testTheCacheCountsWhatItSaved() {
        let cache = InspectorStripCache()
        XCTAssertEqual(cache.reuses, 0)
        cache.store(AXUIElementCreateSystemWide(), for: "Bas")
        XCTAssertEqual(cache.reuses, 0, "storing is not reusing — the walk was still paid")
        cache.noteReuse()
        cache.noteReuse()
        XCTAssertEqual(cache.reuses, 2)
    }
}
