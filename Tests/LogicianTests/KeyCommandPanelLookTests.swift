import XCTest
@testable import Logician

/// `KeyCommandPanelLook` — how many times one learn WALKS Logic's Key Commands
/// panel, and when the conflict-alert search is allowed to run at all.
///
/// Why a walk count deserves its own tests. The install round was measured at
/// **223 s for 22 commands** (live, 2026-09-02) while the literal `Thread
/// .sleep` constants on that path account for 3.3-4.1 s per command; the
/// review that sized the gap put the missing ~6 s a command on two unsized AX
/// walks — `rowMatching` re-reading every visible row up to six times per
/// target, and a depth-6 walk over every Logic window per candidate note to
/// prove that no conflict alert was up. Neither shows in any result, no
/// assertion about the RETURN VALUE would catch a regression, and the tools
/// cannot be run live (they rewrite the user's persisted key command set). So
/// the decisions are pure and these tests COUNT THE CALLS — the shape
/// `resolveTrackStackTarget` uses for exactly the same reason.
final class KeyCommandPanelLookTests: XCTestCase {

    // MARK: - One look per target

    func testAFoundRowCostsExactlyOneLookAndNeverWidens() {
        var looks = 0
        var widens = 0
        let outcome = KeyCommandPanelLook.resolve(
            look: { looks += 1; return ["Save", "Save As"] },
            match: { $0.first { $0 == "Save" } },
            widen: { widens += 1; return ["never"] }
        )
        XCTAssertEqual(outcome.match, "Save")
        XCTAssertEqual(looks, 1, "the panel must be walked once per target")
        XCTAssertEqual(widens, 0)
    }

    func testAMissWithRowsOnScreenOffersThemAndStillWalksOnlyOnce() {
        var looks = 0
        var widens = 0
        let outcome = KeyCommandPanelLook.resolve(
            look: { looks += 1; return ["Split Regions", "Split at Playhead"] },
            match: { _ in String?.none },
            widen: { widens += 1; return ["never"] }
        )
        XCTAssertNil(outcome.match)
        XCTAssertEqual(outcome.candidates, ["Split Regions", "Split at Playhead"])
        XCTAssertEqual(looks, 1)
        XCTAssertEqual(widens, 0, "rows are already on screen; widening would show the same panel")
    }

    func testAMissWithAnEmptyPanelWidensExactlyOnce() {
        var looks = 0
        var widens = 0
        let outcome = KeyCommandPanelLook.resolve(
            look: { looks += 1; return [String]() },
            match: { _ in String?.none },
            widen: { widens += 1; return ["Remove Silence from Audio Region…"] }
        )
        XCTAssertNil(outcome.match)
        XCTAssertEqual(outcome.candidates, ["Remove Silence from Audio Region…"])
        XCTAssertEqual(looks, 1)
        XCTAssertEqual(widens, 1, "an empty panel is the one case a second look earns its cost")
    }

    func testAMissWithNoWiderTermToTryReturnsNothingRatherThanRepeatingTheSearch() {
        var looks = 0
        let outcome = KeyCommandPanelLook.resolve(
            look: { looks += 1; return [String]() },
            match: { _ in String?.none },
            widen: nil
        )
        XCTAssertNil(outcome.match)
        XCTAssertTrue(outcome.candidates.isEmpty)
        XCTAssertEqual(looks, 1)
    }

    // MARK: - The verify loop reads the row it already holds

    func testALiveRowIsReadDirectlyAndNeverRefound() {
        var refinds = 0
        let text = KeyCommandPanelLook.rowText(
            live: { ["Save", "Note 105"] },
            refind: { refinds += 1; return ["never"] }
        )
        XCTAssertEqual(text, "Save Note 105")
        XCTAssertEqual(refinds, 0, "a live row must not cost a walk on every verify tick")
    }

    func testARowInertisedByARerenderIsRefoundExactlyOnce() {
        var refinds = 0
        let text = KeyCommandPanelLook.rowText(
            live: { [] },
            refind: { refinds += 1; return ["Save", "Note 105"] }
        )
        XCTAssertEqual(text, "Save Note 105")
        XCTAssertEqual(refinds, 1)
    }

    func testARowThatIsGoneReadsAsNothingRatherThanAnEmptyString() {
        // An empty string would compare unequal to the pre-learn text and
        // count as "the assignment changed" — a false verification.
        XCTAssertNil(KeyCommandPanelLook.rowText(live: { [] }, refind: { nil }))
        XCTAssertNil(KeyCommandPanelLook.rowText(live: { [] }, refind: { [] }))
    }

    // MARK: - The conflict-alert gate

    func testAnUnchangedWindowLayerNeverEarnsTheDeepAlertSearch() {
        XCTAssertFalse(KeyCommandPanelLook.windowLayerMoved(
            now: ["project", "keycmds"], nowSheets: 0,
            baseline: ["project", "keycmds"], baselineSheets: 0,
            sameElement: ==
        ))
    }

    func testANewWindowMovesTheLayer() {
        XCTAssertTrue(KeyCommandPanelLook.windowLayerMoved(
            now: ["project", "keycmds", "alert"], nowSheets: 0,
            baseline: ["project", "keycmds"], baselineSheets: 0,
            sameElement: ==
        ))
    }

    func testASheetOnAWindowThatWasAlreadyThereMovesTheLayer() {
        // The alert may be a SHEET rather than a window, and a sheet changes
        // no window count — which is exactly how a count-only gate would miss
        // a standing modal in the user's Logic.
        XCTAssertTrue(KeyCommandPanelLook.windowLayerMoved(
            now: ["project", "keycmds"], nowSheets: 1,
            baseline: ["project", "keycmds"], baselineSheets: 0,
            sameElement: ==
        ))
    }

    func testOneWindowSwappedForAnotherMovesTheLayerEvenAtTheSameCount() {
        XCTAssertTrue(KeyCommandPanelLook.windowLayerMoved(
            now: ["project", "alert"], nowSheets: 0,
            baseline: ["project", "keycmds"], baselineSheets: 0,
            sameElement: ==
        ))
    }

    func testAWindowMERELYCLOSINGAlsoMovesTheLayer() {
        // Fewer windows than before is still "something happened", and the
        // ungated last look is what finally settles it either way.
        XCTAssertTrue(KeyCommandPanelLook.windowLayerMoved(
            now: ["project"], nowSheets: 0,
            baseline: ["project", "keycmds"], baselineSheets: 0,
            sameElement: ==
        ))
    }
}
