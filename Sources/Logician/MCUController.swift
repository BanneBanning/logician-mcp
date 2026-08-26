import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

enum MCUController {
    /// Hot-view cache: which track/slot the plugin-edit view currently
    /// shows, so consecutive parameter writes skip the whole select +
    /// view-switch choreography. Cleared by anything that changes views.
    nonisolated(unsafe) static var hotPluginView: (track: String, slot: Int, cacheKey: String?)? // single-threaded server loop

    /// The open project's document path - the identity every on-disk cache is
    /// scoped to. Costs one Accessibility window scan, so callers resolve it
    /// ONCE per operation and pass it down rather than per page or per bank.
    /// nil (Logic closed, no AX trust, no document window) means the scope
    /// cannot be established, and every cache then reads as absent.
    static func currentProjectPath() -> String? {
        try? LogicAccessibility().projectDocumentPath()
    }

    static func freshStatus() -> [String: Any]? {
        // In-memory status straight from the bridge socket (no file throttle);
        // fall back to the state file if the socket round trip fails.
        let status = (try? MCUBridge.send(["cmd": "status"])) ?? MCUBridge.status()
        guard status["ok"] as? Bool == true || status["bridge_running"] as? Bool == true else { return nil }
        // A silent Logic sends nothing, so do not require recent traffic —
        // only that Logic has ever talked this session. Every write verifies
        // itself through LED/LCD feedback, which is the real liveness check.
        guard (status["received_events"] as? Int ?? 0) > 0 else { return nil }
        let age = Date().timeIntervalSince1970 - (status["last_receive"] as? Double ?? 0)
        guard age < 600 else { return nil }
        return status
    }

    /// Event-driven wait: blocks in the bridge until new MIDI arrived from
    /// Logic (or timeout), then returns the fresh in-memory status.
    static func awaitEvents(since: Int, timeoutMs: Int) -> [String: Any]? {
        try? MCUBridge.send(["cmd": "await", "since": since, "timeout_ms": timeoutMs])
    }

    /// Waits until `check` passes, driven by actual MIDI events rather than
    /// fixed sleeps. Returns the passing status, or nil on deadline.
    static func waitFor(
        seconds: Double = 2.5,
        _ check: ([String: Any]) -> Bool
    ) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(seconds)
        guard var status = freshStatus() else { return nil }
        while true {
            if check(status) { return status }
            if Date() >= deadline { return nil }
            let since = status["received_events"] as? Int ?? -1
            guard let next = awaitEvents(since: since, timeoutMs: 350) else { return nil }
            status = next
        }
    }

    /// True when 150 ms pass without new MIDI from Logic (display quiescent).
    static func quiescentStatus() -> [String: Any]? {
        guard let status = freshStatus() else { return nil }
        let since = status["received_events"] as? Int ?? -1
        guard let after = awaitEvents(since: since, timeoutMs: 150) else { return status }
        if after["timed_out"] as? Bool == true { return after }
        return nil // more data arrived; caller should re-check content first
    }

    static func press(_ button: String) throws {
        let response = try MCUBridge.send(["cmd": "press", "button": button])
        guard response["ok"] as? Bool == true else {
            throw DemoError.writeFailed("MCU press \(button) failed: \(response["error"] ?? "?")")
        }
    }

    static func ledLit(_ note: Int, in status: [String: Any]) -> Bool {
        (status["leds_lit"] as? [Int])?.contains(note) ?? false
    }

    static func pollStatus(
        until check: ([String: Any]) -> Bool,
        attempts: Int = 15
    ) -> [String: Any]? {
        waitFor(seconds: Double(attempts) * 0.15, check)
    }

    nonisolated(unsafe) static var lastResolveLearned = false // single-threaded server loop
}
