import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

// The metronome: read-only since `logic_get_transport` shipped, writable now.
//
// The whole gap was one button that was mapped and never pressed. `click`
// (note 0x59) has been in the bridge's `buttonNames` from the beginning, and
// `getTransport` has been reading the control bar's `Metronome Click` checkbox
// just as long — a write and its independent readback sitting on opposite sides
// of the server without a tool between them. Verified both directions live on
// 2026-08-28: off → on → off, with the AX checkbox and MCU LED 0x59 agreeing at
// every step.

extension MCUController {

    /// The MCU's own click LED, which Logic lights in step with the control
    /// bar's metronome button.
    static let clickLED = 0x59

    /// Resolves the metronome's current state, preferring the free in-memory
    /// LED read and calling `ax()` only when the LED itself is unreadable.
    ///
    /// `axState()` is a full AX control-bar walk (`getTransport()`, measured
    /// 5.7-161.5 ms live) that this session's control-bar layout never
    /// resolved at all (`metronome: null` 3/3 reads) — yet it used to run
    /// FIRST, unconditionally, on every branch including `already_*`: 65% of
    /// that fast path's cost, 3.2% of a warm toggle, spent on a value the
    /// call then discarded (profiles/logic_set_metronome.md N1, 2026-09-03).
    /// `ledState` is already-populated by the time this runs (`freshStatus`
    /// is an in-memory read, no socket call unless the mirror needs a pull),
    /// so it is asked first; `ax` stays the tie-breaker of record for when
    /// the LED cannot be read, never the first question.
    ///
    /// Pure and closure-driven so the ORDER — not just the outcome — is
    /// unit-tested: `ax` must not run at all when `ledState` already answers.
    static func resolveMetronomeState(
        ledState: Bool?, ax: () -> Bool?
    ) -> (current: Bool, route: String)? {
        if let ledState { return (ledState, "mcu_click_led") }
        if let value = ax() { return (value, "ax_control_bar_metronome") }
        return nil
    }

    /// Turns the metronome click on or off. Compare-and-set against the
    /// surface's own click LED (the free, always-populated source); verified
    /// by reading that LED back, with the control bar's checkbox as the
    /// tie-breaker when the LED cannot be read.
    static func setMetronome(logic: LogicAccessibility, enabled: Bool) throws -> [String: Any] {
        try requireSurface(
            "the metronome button on the control surface", consequence: "Nothing was pressed"
        )
        func axState() -> Bool? { (try? logic.getTransport())?["metronome"] as? Bool }
        func ledState() -> Bool? { freshStatus().map { ledLit(clickLED, in: $0) } }

        guard let (current, readbackRoute) = MCUController.resolveMetronomeState(
            ledState: ledState(), ax: axState
        ) else {
            throw LogicianError.trackNotExposed(
                requested: "the metronome's current state",
                exposed: "neither the surface's click LED nor the control bar's Metronome Click checkbox"
                    + " could be read, so a toggle could not be verified. Nothing was pressed."
            )
        }
        if current == enabled {
            return [
                "success": true, "verified": true,
                "state": "already_" + (enabled ? "on" : "off"),
                "metronome": enabled,
                "route": "mcu",
                "readback_route": readbackRoute
            ]
        }

        let events = freshStatus()?["received_events"] as? Int ?? -1
        try press("click")
        let afterPress = awaitEvents(since: events, timeoutMs: 1200)

        // Look first, sleep only on a miss — the same shape as
        // `MCUController.waitFor`/`pollStatus`. `awaitEvents` above already
        // blocks until the LED echo lands (measured 0.3-7.4 ms on both
        // real-toggle calls, 2026-09-03 profile, landing on loop iteration 1
        // every time) — yet this loop used to sleep 150 ms BEFORE every look
        // regardless, 94.6% of a warm toggle (167.9 of 177.3 ms) spent
        // waiting for a result that was already sitting in `afterPress`.
        func currentState() -> Bool? { ledState() ?? axState() }
        var landed = afterPress.map { ledLit(clickLED, in: $0) } ?? currentState()
        var attempts = 1 // the look above already spent the first, free look
        while landed != enabled, attempts < 12 {
            Thread.sleep(forTimeInterval: 0.15)
            landed = currentState()
            attempts += 1
        }
        let ledAfter = ledState()
        guard landed == enabled else {
            // One press is the whole operation, so undoing it is exact.
            try? press("click")
            throw LogicianError.verificationFailed(
                requested: "metronome=\(enabled)",
                actual: "the control bar still reads \(landed.map { "\($0)" } ?? "unreadable")"
                    + "; the press was undone",
                restored: true
            )
        }
        var result: [String: Any] = [
            "success": true, "verified": true,
            "state": enabled ? "on" : "off",
            "metronome": enabled,
            "before": current,
            "route": "mcu",
            "write_route": "mcu_click_button",
            "readback_route": readbackRoute,
            "click_led": ledAfter.map { $0 as Any } ?? NSNull() as Any
        ]
        if readbackRoute != "mcu_click_led" {
            appendWarning(
                "The surface's click LED could not be read, so this write is confirmed only by"
                    + " the control bar's Metronome Click checkbox.",
                to: &result
            )
        }
        return result
    }
}
