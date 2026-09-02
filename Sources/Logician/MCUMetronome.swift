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

    /// Turns the metronome click on or off. Compare-and-set against the control
    /// bar's own checkbox; verified by reading that checkbox back, with the
    /// surface LED as a second source.
    static func setMetronome(logic: LogicAccessibility, enabled: Bool) throws -> [String: Any] {
        try requireSurface(
            "the metronome button on the control surface", consequence: "Nothing was pressed"
        )
        func axState() -> Bool? { (try? logic.getTransport())?["metronome"] as? Bool }
        func ledState() -> Bool? { freshStatus().map { ledLit(clickLED, in: $0) } }

        let before = axState()
        guard let current = before ?? ledState() else {
            throw LogicianError.trackNotExposed(
                requested: "the metronome's current state",
                exposed: "neither the control bar's Metronome Click checkbox nor the surface's click LED"
                    + " could be read, so a toggle could not be verified. Nothing was pressed."
            )
        }
        if current == enabled {
            return [
                "success": true, "verified": true,
                "state": "already_" + (enabled ? "on" : "off"),
                "metronome": enabled,
                "route": "mcu",
                "readback_route": before != nil ? "ax_control_bar_metronome" : "mcu_click_led"
            ]
        }

        let events = freshStatus()?["received_events"] as? Int ?? -1
        try press("click")
        _ = awaitEvents(since: events, timeoutMs: 1200)

        var landed: Bool?
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.15)
            landed = axState() ?? ledState()
            if landed == enabled { break }
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
            "readback_route": before != nil ? "ax_control_bar_metronome" : "mcu_click_led",
            "click_led": ledAfter.map { $0 as Any } ?? NSNull() as Any
        ]
        if before == nil {
            appendWarning(
                "The control bar's Metronome Click checkbox could not be read, so this write is"
                    + " confirmed only by the surface's own click LED. logic_get_transport reports"
                    + " the checkbox when Accessibility can see it.",
                to: &result
            )
        }
        return result
    }
}
