import XCTest
@testable import Logician

/// `LogicAccessibility.resolveTrackStackTarget` — whether `setTrackStack`
/// needs to pay for the scroll-insurance `selectTrack` call before it can
/// resolve its toggle target.
///
/// `selectTrack` used to run UNCONDITIONALLY before the header walk that
/// finds the target — 142-304 ms live, 73-74% of a no-op call (measured
/// 2026-09-03, profiles/logic_set_track_stack.md §5) — even though every one
/// of the 8 live toggles in that profile found the row already rendered. The
/// fix asks the free walk first and only falls back to the expensive select
/// on a genuine miss. A live "row not yet scrolled into view" state cannot be
/// arranged in a unit test, so the ORDER — not just the outcome — is proven
/// here with call-counting closures, mirroring
/// `MCUController.resolveMetronomeState`'s tests.
final class TrackStackTargetResolutionTests: XCTestCase {

    func testAnAlreadyRenderedRowNeverPaysForSelectAndRetry() {
        var selectCalls = 0
        let result = LogicAccessibility.resolveTrackStackTarget(
            resolve: { 9 },
            selectAndRetry: { selectCalls += 1; return 9 }
        )
        XCTAssertEqual(result, 9)
        XCTAssertEqual(selectCalls, 0, "selectAndRetry must not run when the plain walk already found the row")
    }

    func testAMissingRowFallsBackToSelectAndRetryExactlyOnce() {
        var resolveCalls = 0
        var selectCalls = 0
        let result = LogicAccessibility.resolveTrackStackTarget(
            resolve: { resolveCalls += 1; return Int?.none },
            selectAndRetry: { selectCalls += 1; return 10 }
        )
        XCTAssertEqual(result, 10)
        XCTAssertEqual(resolveCalls, 1)
        XCTAssertEqual(selectCalls, 1)
    }

    func testBothMissingResolvesToNil() {
        let result: Int? = LogicAccessibility.resolveTrackStackTarget(
            resolve: { nil },
            selectAndRetry: { nil }
        )
        XCTAssertNil(result)
    }

    func testResolveRunsBeforeSelectAndRetryWhenBothWouldSucceed() {
        var order: [String] = []
        _ = LogicAccessibility.resolveTrackStackTarget(
            resolve: { order.append("resolve"); return Int?.none },
            selectAndRetry: { order.append("selectAndRetry"); return 1 }
        )
        XCTAssertEqual(order, ["resolve", "selectAndRetry"])
    }
}
