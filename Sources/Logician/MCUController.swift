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
    /// Which SLOT of a strip a parameter-edit view belongs to.
    ///
    /// The eight audio-effect inserts are numbered and Logic gives each its
    /// own assignment code (`P1`…`P8`), so an insert view names itself. The
    /// INSTRUMENT slot is not an insert: it has no number, it is reached with
    /// `assign_instrument` plus a vpot press rather than through the insert
    /// list, and its parameter pages share the `IN` assignment code with the
    /// instrument BANK view they were opened from. The channel is carried
    /// along because that shared code is exactly what makes the bank row the
    /// thing to rule out (`instrumentBankRowShowing`).
    enum HotSlot: Equatable {
        case insert(Int)
        case instrument(channel: Int)
    }

    /// Hot-view cache: which track/slot the parameter-edit view currently
    /// shows, so consecutive parameter reads and writes skip the whole select
    /// + view-switch choreography.
    ///
    /// This cache is NOT authoritative and is not cleared by every view
    /// change — bank scans, send/instrument views and the automation paths
    /// all leave it set. What makes that safe is that the read path
    /// re-verifies the live LCD against the cached slot before trusting it
    /// (see `hotViewStanding`), and callers re-select the track anyway.
    /// exitToPan() clears it explicitly on shutdown so a leaked hot view
    /// cannot make Logic auto-open plugin windows later.
    struct HotEditView: Equatable {
        let track: String
        let slot: HotSlot
        /// Logic's 6-character LCD name for whatever is in that slot
        /// (`Cha EQ`, `Q-Samp`) — the parameter name-cache key, not a display
        /// name. nil when the cell could not be read.
        let cacheKey: String?
    }

    nonisolated(unsafe) static var hotEditView: HotEditView? // single-threaded server loop

    /// Is the surface STILL showing the hot view this process left behind?
    ///
    /// The record says what we did; this says what the LCD says now, and only
    /// the second one may be acted on. An insert view proves itself with its
    /// own assignment code. The instrument slot's parameter pages share `IN`
    /// with the bank view, so the proof is the assignment code plus the one
    /// thing that tells those two views apart: the bank view names the STRIP
    /// in the top row cell of its own channel (that is
    /// `ensureInstrumentBankView`'s own `mcu_in_bank_named_strip` evidence),
    /// while the parameter pages paint parameter names there.
    static func hotViewStanding(_ hot: HotEditView) -> Bool {
        guard let status = freshStatus(),
              let assignment = status["assignment"] as? String else { return false }
        switch hot.slot {
        case .insert(let slot):
            return assignment == MCULCDStrings.Assignment.insertSlot(slot)
        case .instrument(let channel):
            guard assignment == MCULCDStrings.Assignment.instrument,
                  let top = status["lcd_top"] as? String else { return false }
            return !instrumentBankRowShowing(top: top, channel: channel, trackName: hot.track)
        }
    }

    /// True when an `IN` view's top row names this strip in its own channel
    /// cell — the signature of the instrument BANK view (and of a browse
    /// running in it). Pure, so the rule that separates the two views sharing
    /// the `IN` code is tested without a surface. Erring toward "bank view"
    /// costs one re-entry; erring the other way would search a browser row
    /// for parameter names.
    static func instrumentBankRowShowing(top: String, channel: Int, trackName: String) -> Bool {
        let cells = lcdFields(top)
        guard cells.indices.contains(channel) else { return false }
        return lcdAbbreviationPlausible(track: trackName, lcd: cells[channel])
    }

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
        /// What is on the LCD: "plugin_list", "plugin_edit", "send",
        /// "instrument_bank", "instrument_edit" or "channel_strip" (the mixer
        /// snapshot's Volume view, which belongs to no single strip).
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
    /// next track selection: the per-insert parameter family and the instrument
    /// edit view. Pure, so the rule is tested without a surface.
    ///
    /// The whole `P…` family rather than an `P1`…`P8` allow-list, and that is
    /// not laziness. The assignment display is two 7-segment characters decoded
    /// straight to ASCII, and Logic paints codes there this project has not
    /// enumerated: `P_` was observed live 2026-08-31 on a plugin-adjacent page,
    /// slipped through an exact-match list, and a track selection taken on top
    /// of it opened a plugin window — the exact failure the check exists to
    /// stop. Every code Logic's own documented modes use is covered
    /// (`PN` pan, `IN` instrument, `SE` send, `CS` channel strip, `EQ`), so
    /// "starts with P and is not PN" cannot swallow a view another tool set on
    /// purpose; it can only catch more of the family it is aimed at. Erring
    /// toward one extra 3.3 s restore beats erring toward a leaked plugin view.
    static func isPluginEditAssignment(_ code: String) -> Bool {
        if code == MCULCDStrings.Assignment.instrument { return true }
        return code.hasPrefix("P") && code != MCULCDStrings.Assignment.pan
    }

    /// The open project's document path - the identity every on-disk cache is
    /// scoped to. Costs one Accessibility window scan, so callers resolve it
    /// ONCE per operation and pass it down rather than per page or per bank.
    /// nil (Logic closed, no AX trust, no document window) means the scope
    /// cannot be established, and every cache then reads as absent.
    static func currentProjectPath() -> String? {
        try? LogicAccessibility().projectDocumentPath()
    }

    /// The raw control-surface snapshot: in-memory status straight from the
    /// bridge socket (no file throttle), falling back to the state file when
    /// the socket round trip fails. Undated and unjudged — `freshStatus` and
    /// `surfaceUnavailability` are where the judging happens.
    static func statusSnapshot() -> [String: Any] {
        (try? MCUBridge.sendForDictionary(.status)) ?? MCUBridge.status()
    }

    /// How old the mirror may be before it stops counting as a live read.
    ///
    /// The mirror is Logic's own echo and it does not rot on its own — but a
    /// mirror left behind by a Logic that has since quit, or by a surface
    /// connection that has since dropped, looks exactly like one from a Logic
    /// that is merely idle. So an old mirror is not served silently; it is
    /// PROBED (`requireSurface`).
    static let staleMirrorSeconds: Double = 600

    static func freshStatus() -> [String: Any]? {
        let status = statusSnapshot()
        guard status["ok"] as? Bool == true || status["bridge_running"] as? Bool == true else { return nil }
        // A silent Logic sends nothing, so do not require recent traffic —
        // only that Logic has ever talked this session. Every write verifies
        // itself through LED/LCD feedback, which is the real liveness check.
        guard (status["received_events"] as? Int ?? 0) > 0 else { return nil }
        // …and then, historically, the very next line required recent traffic
        // anyway, which is how ten idle minutes took the whole control-surface
        // plane down with "the bridge is not running" while the bridge was
        // running and Logic was fine (D1/D2 in profiles/logic_mixer_snapshot.md,
        // measured 2026-09-02 at last_receive_age 3 413 s). The guard stays —
        // a stale mirror must not be mistaken for a live read — but it is no
        // longer the last word: `requireSurface` wakes an idle surface and
        // tells the two faults apart before any tool refuses.
        let age = Date().timeIntervalSince1970 - (status["last_receive"] as? Double ?? 0)
        guard age < staleMirrorSeconds else { return nil }
        return status
    }

    // MARK: The surface guard — four faults that used to wear one message

    /// Why the surface could not be read. The old refusal named two of these
    /// and asserted both of them at once ("the bridge is not running or Logic
    /// has never talked to it"), which was wrong on both counts in the one
    /// case that actually happens.
    enum SurfaceUnavailability: Equatable {
        /// No daemon answered — the only case the old message described.
        case bridgeNotAnswering
        /// The daemon is fine; Logic is not there to talk to it.
        case logicNotRunning
        /// Daemon and Logic are both up, but Logic has never sent this daemon
        /// anything: the control surface is not set up in Logic's preferences.
        case logicNeverTalked
        /// Everything is up and Logic simply has not been touched. The mirror
        /// is old, nothing is broken, and one probe press ends it.
        case logicSilent(seconds: Double)
    }

    /// Decides which of the four it is, from the snapshot plus a clock. Pure,
    /// so the wording below is tested against an old `last_receive` and a
    /// non-zero `received_events` without a daemon or an idle hour.
    static func surfaceUnavailability(
        status: [String: Any]?, logicRunning: Bool, now: Double
    ) -> SurfaceUnavailability {
        guard let status,
              status["ok"] as? Bool == true || status["bridge_running"] as? Bool == true
        else { return .bridgeNotAnswering }
        guard logicRunning else { return .logicNotRunning }
        guard (status["received_events"] as? Int ?? 0) > 0 else { return .logicNeverTalked }
        let lastReceive = status["last_receive"] as? Double ?? 0
        return .logicSilent(seconds: max(0, now - lastReceive))
    }

    /// What to tell the caller. Each string names what was actually found and
    /// the repair for it, and none of them claims the bridge is down while it
    /// is answering.
    static func surfaceUnavailabilityDetail(_ why: SurfaceUnavailability) -> String {
        switch why {
        case .bridgeNotAnswering:
            return "no Mackie Control bridge daemon answered, so the surface cannot be read or"
                + " written. Run logic_health: it starts the bridge and audits the rest of the setup"
        case .logicNotRunning:
            return "the bridge daemon is answering but Logic Pro is not running, so there is"
                + " nothing on the other end of the control surface. Open the project and try again"
        case .logicNeverTalked:
            return "the bridge daemon is answering and Logic is running, but Logic has never sent"
                + " this daemon a single control-surface message — the Mackie Control is not set up"
                + " in Logic (Logic Pro ▸ Settings ▸ Control Surfaces ▸ Setup). Run logic_health,"
                + " which reports the surface setup"
        case .logicSilent(let seconds):
            let minutes = Int((seconds / 60).rounded())
            return "the bridge daemon is answering (so the bridge IS running) but Logic has not"
                + " answered the control surface for about \(minutes) minute(s), and a probe press"
                + " did not wake it either. Logic is running, so the surface connection itself is"
                + " the suspect: check Logic Pro ▸ Settings ▸ Control Surfaces ▸ Setup for the"
                + " Mackie Control, then run logic_health"
        }
    }

    /// Whether Logic Pro is running at all — one process-list look, no
    /// Accessibility permission and no window walk.
    static func logicIsRunning() -> Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: LogicAccessibility().bundleIdentifier)
            .isEmpty
    }

    /// How long to wait for Logic's answer to the wake probe. The observed
    /// wake produced 19 events; a bank step is answered in ~4 ms and this is
    /// generous by three orders of magnitude, because it is paid once per idle
    /// session.
    static let surfaceWakeTimeoutMs = 600

    /// Wakes a surface whose mirror has only gone QUIET, with one press.
    ///
    /// `bank_left` is the probe because it is the one press whose worst case is
    /// a bank the next thing to happen walks back anyway: every tool that reads
    /// banks starts at the left edge (`resetToLeftmostBank`) and every tool
    /// that addresses a channel resolves through it. It is also literally the
    /// press that fixed this by hand (2026-09-02, events 890 → 909).
    ///
    /// Returns the now-live status, or nil when Logic did not answer — which
    /// is the evidence that the fault is not idleness.
    static func wakeSurface() -> [String: Any]? {
        let events = statusSnapshot()["received_events"] as? Int ?? -1
        guard (try? press("bank_left")) != nil else { return nil }
        _ = awaitEvents(since: events, timeoutMs: surfaceWakeTimeoutMs)
        return freshStatus()
    }

    /// The guard every control-surface tool takes before its first press: the
    /// live mirror, or a refusal that says which fault it found.
    ///
    /// An idle session no longer needs a manual wake — `logicSilent` is the
    /// one case that is not a fault at all, so it is answered with a probe
    /// press instead of a refusal.
    ///
    /// - Parameter consequence: what did NOT happen, for a tool that would
    ///   have written something ("Nothing was pressed"). Kept as the callers'
    ///   own sentence because only they know what they were about to do.
    @discardableResult
    static func requireSurface(
        _ requested: String, consequence: String? = nil
    ) throws -> [String: Any] {
        if let status = freshStatus() { return status }
        let why = surfaceUnavailability(
            status: statusSnapshot(),
            logicRunning: logicIsRunning(),
            now: Date().timeIntervalSince1970
        )
        if case .logicSilent = why, let woken = wakeSurface() { return woken }
        throw LogicianError.trackNotExposed(
            requested: requested,
            exposed: surfaceUnavailabilityDetail(why)
                + (consequence.map { ". " + $0 } ?? "")
        )
    }

    /// Event-driven wait: blocks in the bridge until new MIDI arrived from
    /// Logic (or timeout), then returns the fresh in-memory status.
    static func awaitEvents(since: Int, timeoutMs: Int) -> [String: Any]? {
        try? MCUBridge.sendForDictionary(.awaitEvents(since: since, timeoutMs: timeoutMs))
    }

    /// How long one `awaitEvents` round may block while waiting for Logic.
    static let awaitRoundMs = 350

    /// How long the NEXT round may block: the round length, or whatever is
    /// left of the budget — whichever is shorter. nil when the budget is gone.
    ///
    /// The cap is the whole point. `waitFor` used to check its deadline only
    /// BETWEEN rounds and then block a full 350 ms regardless, so a stated
    /// 2.25 s budget overshot to 2.48-2.56 s every time it ran out (measured
    /// on `logic_set_playing`'s timeout path 2026-09-03: 2555.7/2483.6/2479.4
    /// ms, and on `render_track`'s 2 487/2 487/2 474 ms) — the ledger's
    /// standing "2.48 s poll". Pure, so the arithmetic is tested without a
    /// bridge.
    static func waitRoundTimeoutMs(remaining: Double, round: Int = awaitRoundMs) -> Int? {
        let remainingMs = Int((remaining * 1000).rounded(.down))
        guard remainingMs > 0 else { return nil }
        return min(round, remainingMs)
    }

    /// Waits until `check` passes, driven by actual MIDI events rather than
    /// fixed sleeps. Returns the passing status, or nil on deadline — which it
    /// now honours to the millisecond instead of overshooting by up to one
    /// round (see `waitRoundTimeoutMs`).
    static func waitFor(
        seconds: Double = 2.5,
        _ check: ([String: Any]) -> Bool
    ) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(seconds)
        guard var status = freshStatus() else { return nil }
        while true {
            if check(status) { return status }
            guard let timeoutMs = waitRoundTimeoutMs(
                remaining: deadline.timeIntervalSinceNow
            ) else { return nil }
            let since = status["received_events"] as? Int ?? -1
            guard let next = awaitEvents(since: since, timeoutMs: timeoutMs) else { return nil }
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

    /// `holdMs` is how long the button stays down; 0 — the default — is the
    /// measured one (see `BridgeCommand.pressHoldMs`), and it is what every
    /// press in this server takes unless the button's Logic behaviour depends
    /// on the hold. Against a daemon older than 2026-09-02 the argument is
    /// ignored and the press keeps its historical 50 ms.
    static func press(_ button: String, holdMs: Int = 0) throws {
        let response = try MCUBridge.send(.press(button: button, holdMs: holdMs))
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
