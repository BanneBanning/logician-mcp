import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

/// MCU-first implementations of the high-level controls. Each function returns
/// nil when the MCU route is unavailable or cannot safely resolve the target
/// (nothing was written — callers fall back to Accessibility), returns a result
/// on verified success, and throws when a write happened but verification
/// failed (never silently fall back after a partial write).
enum MCUController {
    /// Hot-view cache: which track/slot the plugin-edit view currently
    /// shows, so consecutive parameter writes skip the whole select +
    /// view-switch choreography.
    ///
    /// This cache is NOT authoritative and is not cleared by every view
    /// change — bank scans, send/instrument views and the automation paths
    /// all leave it set. What makes that safe is that the read path
    /// re-verifies the live LCD assignment code against the cached slot
    /// before trusting it (see setPluginParameter), and callers re-select
    /// the track anyway. exitToPan() clears it explicitly on shutdown so a
    /// leaked hot view cannot make Logic auto-open plugin windows later.
    nonisolated(unsafe) static var hotPluginView: (track: String, slot: Int, cacheKey: String?)? // single-threaded server loop

    /// A view this server switched the surface INTO and has not switched back
    /// out of — the debt left behind when a plugin tool skips its `exitToPan`.
    ///
    /// Returning to the Pan-names view costs ~3.3 s (`ensurePanNames`, two
    /// full-second silence proofs and the mode banner), and the read tools used
    /// to pay it on the way out of EVERY call — 6.6 s of the 15.8 s three-call
    /// EQ-write flow, spent putting the surface back so the next call could
    /// take it somewhere else again. So the restore is DEFERRED and the debt
    /// recorded here instead. It is settled in exactly three ways, and there is
    /// no fourth:
    ///
    /// 1. `ensurePanNames()` clears it the moment the names view is verified —
    ///    which is the same call every tool that NEEDS that view already makes,
    ///    so "settle before a tool whose correctness depends on PN" is not a
    ///    rule anyone has to remember, it is the mechanism.
    /// 2. `settleSurfaceDebt(before:)` pays it up front when the next thing to
    ///    happen is an Accessibility track selection onto a DIFFERENT strip.
    ///    That is the documented hazard of a leaked plugin-edit view: Logic
    ///    auto-opens plugin windows on later track selections.
    /// 3. `MCPServer.shutdown()` pays it when stdin closes, through the
    ///    unchanged `didTouchSurface` cleanup — so a session that ends mid-debt
    ///    still leaves the user's surface in the neutral view.
    ///
    /// Recording the debt is therefore not what makes the restore happen; the
    /// surface's actual state does. The record exists so the deferral can be
    /// REASONED about (and tested) rather than inferred from the LCD.
    struct SurfaceDebt: Equatable {
        /// The strip whose view is showing, when the view belongs to one.
        let strip: String?
        /// What is on the LCD: "plugin_list" or "plugin_edit".
        let view: String
        /// The MCU physical insert slot, for a plugin-edit view.
        let slot: Int?
    }

    nonisolated(unsafe) static var surfaceDebt: SurfaceDebt? // single-threaded server loop

    /// Leaves the surface where it is and records what it is showing. The
    /// caller must have verified that view; nothing here reads the LCD.
    static func deferSurfaceRestore(_ debt: SurfaceDebt) {
        surfaceDebt = debt
    }

    /// Pays the deferred restore when the next operation cannot safely run on
    /// top of the view we left behind. `strip` names the strip that operation
    /// is about to address: a debt on the SAME strip is left standing (the
    /// plugin tools reuse it, and selecting an already-selected track opens no
    /// windows), a debt on any other strip is settled first.
    ///
    /// Returns true when a restore was actually paid, so callers and tests can
    /// see the decision rather than infer it.
    @discardableResult
    static func settleSurfaceDebt(before strip: String?) -> Bool {
        if let debt = surfaceDebt {
            if let strip, let owed = debt.strip, owed == strip { return false }
            exitToPan()
            return true
        }
        // No debt in memory is not proof that none is owed. A previous process
        // can have left a plugin-edit view standing — a crash, a kill, a client
        // that never closed stdin — and the hazard belongs to the SURFACE, not
        // to this process's bookkeeping. Observed live 2026-08-31: a session
        // whose bridge daemon died mid-write left the surface on the per-insert
        // bank, and the next track selection made Logic auto-open that
        // plugin's window. One 0.7 ms status read closes that hole.
        guard let assignment = freshStatus()?["assignment"] as? String,
              isPluginEditAssignment(assignment) else { return false }
        debugLog("settleSurfaceDebt: surface is in view '\(assignment)' with no debt recorded; restoring")
        exitToPan()
        return true
    }

    /// The assignment codes that make Logic auto-open plugin windows on the
    /// next track selection: the eight per-insert parameter banks and the
    /// instrument edit view. Pure, so the rule is tested without a surface.
    static func isPluginEditAssignment(_ code: String) -> Bool {
        if code == MCULCDStrings.Assignment.instrument { return true }
        return (1...8).contains { MCULCDStrings.Assignment.insertSlot($0) == code }
    }

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
        let status = (try? MCUBridge.sendForDictionary(.status)) ?? MCUBridge.status()
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
        try? MCUBridge.sendForDictionary(.awaitEvents(since: since, timeoutMs: timeoutMs))
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
        let response = try MCUBridge.send(.press(button: button))
        guard response.ok else {
            throw LogicianError.writeFailed("MCU press \(button) failed: \(response.error ?? "?")")
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

    /// Set when the most recent resolve had to learn the command on the
    /// spot (the Key Commands window flashes briefly) — surfaced in tool
    /// results so users understand what they just saw.
    nonisolated(unsafe) static var lastResolveLearned = false // single-threaded server loop
}
