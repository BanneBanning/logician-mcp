import XCTest
@testable import Logician

/// What the two close tools accept as proof that a window closed.
///
/// Real `AXUIElement`s cannot be constructed in a test, so the decision is
/// generic over the key type and pinned here on plain integers — the same
/// arrangement `walkTree` uses. The property that matters is the
/// DISCRIMINATING one: a press that did nothing, plus some unrelated window
/// closing inside the poll, must not read as "the window closed". That is a
/// false `verified: true`, and it is the failure this project treats as
/// unacceptable.
final class WindowCloseVerificationTests: XCTestCase {

    // Two windows are open when the press happens: 1 is the plugin window the
    // caller aimed at (titled after its track), 2 is the project window.
    private let plugin = 1
    private let project = 2
    private let pluginTitle = "Crash"

    private var before: Set<Int> { [plugin, project] }

    // MARK: - The loose test the callers used to share

    func testAnUnrelatedWindowClosingIsNotProofThePressWorked() {
        // The old shape asked "is any member of the before-set missing?" and
        // this list answered yes — while the pressed window (1) is still open.
        let current: Set<Int> = [plugin]
        XCTAssertTrue(
            !before.isSubset(of: current),
            "precondition: the loose before-set question is satisfied by the project window going away"
        )
        XCTAssertFalse(
            anyTargetWindowVanished(targets: [plugin], current: current),
            "aimed at window 1, which is still open: nothing was closed"
        )
        XCTAssertFalse(
            pressedWindowIsGone(
                target: plugin,
                title: pluginTitle,
                current: [(key: plugin, title: pluginTitle)]
            ),
            "the pressed window is still in the list, by element and by title"
        )
    }

    // MARK: - anyTargetWindowVanished (logic_close_plugin's toggle press)

    func testATargetGoingAwayIsProof() {
        XCTAssertTrue(anyTargetWindowVanished(targets: [plugin], current: [project]))
    }

    func testOneOfTwoWindowsSharingTheTrackNameGoingAwayIsProof() {
        // Two plugin windows on one track share the track's title, so a
        // toggle press can only promise that one of them went away.
        let second = 3
        XCTAssertTrue(
            anyTargetWindowVanished(targets: [plugin, second], current: [second, project])
        )
    }

    func testNoTargetsIsNeverProof() {
        // An empty aim must not be satisfied by an empty difference — the
        // caller refuses before pressing, and this is the belt.
        XCTAssertFalse(anyTargetWindowVanished(targets: Set<Int>(), current: [project]))
    }

    // MARK: - pressedWindowIsGone (logic_close_plugin_window)

    func testThePressedWindowGoneByElementAndTitle() {
        XCTAssertTrue(
            pressedWindowIsGone(
                target: plugin,
                title: pluginTitle,
                current: [(key: project, title: "Testlåt Copy - Tracks")]
            )
        )
    }

    func testTheSameTitleUnderANewElementIsNotGone() {
        // If Logic vends a fresh reference for a window that is still on
        // screen, the identity test alone would call it closed.
        XCTAssertFalse(
            pressedWindowIsGone(
                target: plugin,
                title: pluginTitle,
                current: [(key: 99, title: pluginTitle), (key: project, title: "Tracks")]
            )
        )
    }

    // MARK: - windowToggleVerdict (both answers, one poll)

    func testTheVerdictWaitsWhileNothingHasHappened() {
        XCTAssertNil(
            windowToggleVerdict(targets: [plugin], before: before, current: [plugin, project])
        )
    }

    func testAWindowAppearingMeansThePluginWasNotOpen() {
        let appeared = 4
        XCTAssertEqual(
            windowToggleVerdict(targets: [plugin], before: before, current: [plugin, project, appeared]),
            .opened(appeared)
        )
    }

    func testAClosureOutranksAnAppearanceInTheSameTick() {
        // Both fired between two looks: the outcome the caller asked for wins.
        let appeared = 4
        XCTAssertEqual(
            windowToggleVerdict(targets: [plugin], before: before, current: [project, appeared]),
            .closed
        )
    }
}
