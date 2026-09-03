import XCTest
@testable import Logician

/// `LogicAccessibility.stackFoldFallback` — what `logic_set_track_stack` does
/// when the mouse-free Accessibility press does not move the disclosure
/// triangle.
///
/// The fold used to take the pointer with no opt-in, on the belief that
/// `AXPress` was a silent no-op on Logic's track-header controls. Re-measured
/// 2026-09-03 (Logic 12.3.1, sandbox `Testlåt Copy`, stack 9
/// `Drum Synth Kit`): the press folds the stack in 22-40 ms, 4/4, both
/// directions, with another app frontmost. So the press is the route, and the
/// click is an `allow_mouse: true` fallback — which makes the REFUSAL the
/// product this covers: it has to name the argument that lets the pointer in,
/// and it has to say that nothing was changed.
final class TrackStackFoldRouteTests: XCTestCase {

    /// A press Logic really carried out and simply did not fold with.
    private let realPress = 45.0

    func testWithoutAllowMouseTheFallbackRefuses() {
        XCTAssertNotEqual(
            LogicAccessibility.stackFoldFallback(
                allowMouse: false, trackName: "Drum Synth Kit", expanded: true,
                pressMilliseconds: realPress
            ),
            .mouse,
            "the pointer must never be taken unless the caller asked for it"
        )
    }

    func testTheRefusalNamesTheArgumentThatLetsThePointerIn() {
        guard case .refuse(let text) = LogicAccessibility.stackFoldFallback(
            allowMouse: false, trackName: "Drum Synth Kit", expanded: true,
            pressMilliseconds: realPress
        ) else { return XCTFail("expected a refusal") }
        XCTAssertTrue(text.contains("allow_mouse: true"), text)
        XCTAssertTrue(text.contains("Nothing was changed."), text)
    }

    func testTheRefusalNamesTheStackAndTheDirection() {
        guard case .refuse(let opening) = LogicAccessibility.stackFoldFallback(
            allowMouse: false, trackName: "Drum Synth Kit", expanded: true,
            pressMilliseconds: realPress
        ) else { return XCTFail("expected a refusal") }
        XCTAssertTrue(opening.contains("'Drum Synth Kit'"), opening)
        XCTAssertTrue(opening.contains("open the stack"), opening)

        guard case .refuse(let closing) = LogicAccessibility.stackFoldFallback(
            allowMouse: false, trackName: "Vocals", expanded: false,
            pressMilliseconds: realPress
        ) else { return XCTFail("expected a refusal") }
        XCTAssertTrue(closing.contains("'Vocals'"), closing)
        XCTAssertTrue(closing.contains("close the stack"), closing)
    }

    /// The three routes that are NOT available are the reason this refusal is
    /// a refusal and not a "try X instead", so it says all three. A future
    /// pass that re-opens one of them has to come through this test.
    func testTheRefusalSaysWhyThereIsNoOtherMouseFreeRoute() {
        guard case .refuse(let text) = LogicAccessibility.stackFoldFallback(
            allowMouse: false, trackName: "Drum Synth Kit", expanded: true,
            pressMilliseconds: realPress
        ) else { return XCTFail("expected a refusal") }
        XCTAssertTrue(text.contains("AXValue is not settable"), text)
        XCTAssertTrue(text.contains("AXDisclosing"), text)
        XCTAssertTrue(text.contains("Open/Close Track Stack"), text)
    }

    /// The diagnosis that turns "this call failed" into "every
    /// element-addressed write is affected right now": a press that returns in
    /// a fraction of a millisecond was never carried out.
    func testAnInstantPressIsReportedAsLogicsActionsGoingInert() {
        guard case .refuse(let text) = LogicAccessibility.stackFoldFallback(
            allowMouse: false, trackName: "Drum Synth Kit", expanded: false,
            pressMilliseconds: 0.1
        ) else { return XCTFail("expected a refusal") }
        XCTAssertTrue(text.contains("0.1 ms"), text)
        XCTAssertTrue(text.contains("inert app-wide"), text)
        XCTAssertTrue(text.contains("not an Accessibility action"), text)
    }

    func testARealPressIsNotBlamedOnTheActionPlane() {
        guard case .refuse(let text) = LogicAccessibility.stackFoldFallback(
            allowMouse: false, trackName: "Drum Synth Kit", expanded: false,
            pressMilliseconds: realPress
        ) else { return XCTFail("expected a refusal") }
        XCTAssertFalse(text.contains("inert app-wide"), text)
    }

    func testWithAllowMouseTheFallbackIsTheClick() {
        XCTAssertEqual(
            LogicAccessibility.stackFoldFallback(
                allowMouse: true, trackName: "Drum Synth Kit", expanded: false,
                pressMilliseconds: 0.1
            ),
            .mouse
        )
    }

    // MARK: - Is the triangle where a write can reach it?

    private let viewport = CGRect(x: 0, y: 100, width: 400, height: 500)

    func testATriangleInsideTheViewportIsReachable() {
        XCTAssertTrue(
            LogicAccessibility.stackHeaderIsReachable(
                disclosure: CGRect(x: 45, y: 206, width: 22, height: 31), visible: viewport
            )
        )
    }

    /// The measured failure state of 2026-09-03: stack 9's triangle published
    /// at y = -284 after an expand scrolled the Tracks area, where the click
    /// route's hit test resolves to nothing at all.
    func testATriangleScrolledAboveTheViewportIsNotReachable() {
        XCTAssertFalse(
            LogicAccessibility.stackHeaderIsReachable(
                disclosure: CGRect(x: 45, y: -284, width: 22, height: 31), visible: viewport
            )
        )
    }

    func testATriangleScrolledBelowTheViewportIsNotReachable() {
        XCTAssertFalse(
            LogicAccessibility.stackHeaderIsReachable(
                disclosure: CGRect(x: 45, y: 900, width: 22, height: 31), visible: viewport
            )
        )
    }

    /// A probe that could not read the geometry must never be the reason a
    /// working write is turned away — so every unknown answers "reachable".
    func testUnreadableGeometryIsTreatedAsReachable() {
        XCTAssertTrue(
            LogicAccessibility.stackHeaderIsReachable(disclosure: nil, visible: viewport)
        )
        XCTAssertTrue(
            LogicAccessibility.stackHeaderIsReachable(
                disclosure: CGRect(x: 45, y: -284, width: 22, height: 31), visible: nil
            )
        )
        XCTAssertTrue(
            LogicAccessibility.stackHeaderIsReachable(
                disclosure: CGRect(x: 45, y: -284, width: 22, height: 31), visible: .zero
            )
        )
        XCTAssertTrue(
            LogicAccessibility.stackHeaderIsReachable(disclosure: .zero, visible: viewport)
        )
    }
}
