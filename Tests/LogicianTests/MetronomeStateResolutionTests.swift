import XCTest
@testable import Logician

/// `MCUController.resolveMetronomeState` — which of the two current-state
/// sources `logic_set_metronome` trusts, and in what order.
///
/// `axState()` is a full AX control-bar walk (measured 5.7-161.5 ms live)
/// that this session's control-bar layout never resolved at all, yet it used
/// to run FIRST, unconditionally, on every branch including `already_*` —
/// 65% of that fast path's cost for a value the call then discarded
/// (profiles/logic_set_metronome.md N1, 2026-09-03). The fix asks the free,
/// already-populated LED read first and calls `ax()` only when the LED
/// itself is unreadable. A live idle-AX session cannot be arranged in a
/// test, so the ORDER — not just the outcome — is proven here with a
/// call-counting closure.
final class MetronomeStateResolutionTests: XCTestCase {

    func testTheLEDAnswersWithoutEverCallingAX() {
        var axCalls = 0
        let result = MCUController.resolveMetronomeState(ledState: true) {
            axCalls += 1
            return false
        }
        XCTAssertEqual(result?.current, true)
        XCTAssertEqual(result?.route, "mcu_click_led")
        XCTAssertEqual(axCalls, 0, "the AX control-bar walk must not run when the LED already answered")
    }

    func testALitLEDAndAnOffLEDBothResolveWithoutAX() {
        var axCalls = 0
        let ax: () -> Bool? = { axCalls += 1; return true }
        XCTAssertEqual(MCUController.resolveMetronomeState(ledState: false, ax: ax)?.current, false)
        XCTAssertEqual(MCUController.resolveMetronomeState(ledState: true, ax: ax)?.current, true)
        XCTAssertEqual(axCalls, 0)
    }

    func testAXIsTheFallbackOnlyWhenTheLEDCannotBeRead() {
        let result = MCUController.resolveMetronomeState(ledState: nil) { true }
        XCTAssertEqual(result?.current, true)
        XCTAssertEqual(result?.route, "ax_control_bar_metronome")
    }

    func testNeitherChannelReadableResolvesToNil() {
        XCTAssertNil(MCUController.resolveMetronomeState(ledState: nil) { nil })
    }
}
