import Foundation
import LogicMCUBridge

/// Shapes the `logic_mcu_status` result out of a control-surface snapshot,
/// whichever plane produced it.
///
/// Pure on purpose. Every judgement this tool makes about the bytes it serves
/// — how old they are, whether Logic is really talking, which view the
/// surface is in — is a function of the snapshot plus a clock, so all of it
/// is decided here and tested without a daemon.
///
/// The reason it exists: until 2026-09-02 the tool handed the state FILE
/// straight over. The file is written by the daemon only when Logic sends
/// something (Bridge.swift:914, a 150 ms dirty timer), and `online` is
/// computed at write time (Bridge.swift:104) — so a written file says
/// `online: true` by construction and keeps saying it after Logic goes quiet.
/// Measured that day: mirrors 117 s, 177 s and 197 s old, served in silence,
/// all four of them claiming `online: true` while the daemon's live answer to
/// the same question was false.
enum MCUStatusReport {
    /// The daemon's own definition of `online`: traffic inside this window,
    /// and at least one event ever (Bridge.swift:104). Recomputed here at
    /// READ time against the same fields, which is the whole difference.
    static let onlineWindow: Double = 10

    /// Which plane answered. The agent is told, because the two are not
    /// equally good: the socket is computed now, the file is a mirror of
    /// whenever Logic last spoke.
    enum Source: String {
        case socket
        case stateFile = "state_file"
        /// No daemon answered and no mirror exists yet.
        case unavailable
    }

    static func payload(
        snapshot: [String: Any],
        source: Source,
        daemonPidAlive: Bool?,
        now: Double
    ) -> [String: Any] {
        var object = snapshot
        object["success"] = true
        object["state"] = "read"
        object["source"] = source.rawValue
        guard source != .unavailable else {
            // Nothing to date, nothing to decode - `MCUBridge.status()` has
            // already put the reason in `note`. Only the envelope is missing.
            object["bridge_running"] = false
            return object
        }

        // AGE. The result used to carry `updated` as a bare unix double and
        // nothing else, and an LLM agent has no reliable clock of its own —
        // so it could not tell a snapshot from this second from one from
        // three minutes ago. The subtraction happens here, where there IS a
        // clock.
        let updated = object["updated"] as? Double ?? 0
        if updated > 0 {
            object["age_seconds"] = round3(max(0, now - updated))
        } else {
            object["age_seconds"] = NSNull()
        }

        // ONLINE, recomputed rather than mirrored: the daemon's own predicate
        // evaluated against `last_receive` NOW. `last_receive_age_seconds` is
        // the evidence behind it, so the agent can audit the verdict instead
        // of trusting a bare bool.
        let received = object["received_events"] as? Int ?? 0
        let lastReceive = object["last_receive"] as? Double ?? 0
        if lastReceive > 0 {
            object["last_receive_age_seconds"] = round3(max(0, now - lastReceive))
            object["online"] = received > 0 && now - lastReceive < onlineWindow
        } else {
            // Logic has never sent this daemon anything. A daemon old enough
            // to omit `last_receive` lands here too, and "not proven online"
            // is the honest answer for both.
            object["last_receive_age_seconds"] = NSNull()
            object["online"] = false
        }

        // ASSIGNMENT, decoded. The server already knows how to read the
        // two-character code (`MCUController.isPluginEditAssignment`); the
        // agent reaching for this tool to ask "where did the last call leave
        // the surface" should not have to learn it too.
        if let code = object["assignment"] as? String, !code.isEmpty {
            object["assignment_view"] = viewName(code)
            object["assignment_plugin_edit"] = MCUController.isPluginEditAssignment(code)
            object["assignment_send_view"] = code == MCULCDStrings.Assignment.send
        }

        switch source {
        case .socket:
            // The round trip that produced this snapshot IS the proof, and it
            // is the same proof `logic_health` publishes under this name.
            object["bridge_running"] = true
        case .stateFile:
            // Whatever `MCUBridge.status()` learned from its ping, kept as
            // it found it: the field means "the daemon answered a probe just
            // now" in this tool exactly as it does in logic_health. That the
            // SNAPSHOT is old is a separate fact, and `source`, `age_seconds`
            // and the warning below are where it is said.
            let answering = object["bridge_running"] as? Bool ?? false
            object["bridge_running"] = answering
            object["bridge_fix"] = bridgeFix(
                pingAnswered: answering, daemonPidAlive: daemonPidAlive
            )
            if let age = object["age_seconds"] as? Double, age >= onlineWindow {
                object["warning"] = "SNAPSHOT IS \(Int(age.rounded())) s OLD. The live status"
                    + " round trip did not come back, so this is the state FILE on disk, and"
                    + " the daemon rewrites that file only when Logic sends something - every"
                    + " field here describes the surface as of \(Int(age.rounded())) s ago, not"
                    + " now. Treat assignment, faders, LEDs and LCD text as history;"
                    + " bridge_fix says what to do about it."
            }
        case .unavailable:
            break
        }
        return object
    }

    /// What to do about a `status` round trip that did not come back. Three
    /// different faults wear the same symptom, and telling them apart is
    /// free: the ping `MCUBridge.status()` already sent, plus the pid the
    /// daemon wrote into its own lockfile (`BridgeProcess.parsePidFile`).
    static func bridgeFix(pingAnswered: Bool, daemonPidAlive: Bool?) -> String {
        if pingAnswered {
            return "The bridge daemon answers a ping but did not answer a status round trip,"
                + " so this result is the state FILE on disk rather than a live read."
                + " Run logic_health, which replaces a daemon that stopped answering properly"
                + " and audits the rest of the setup."
        }
        if daemonPidAlive == true {
            return "A bridge daemon process is alive but its socket did not answer, so this"
                + " result is the state FILE it left behind rather than a live read."
                + " Run logic_health: it replaces a daemon that stopped answering and audits"
                + " the rest of the setup."
        }
        return "No bridge daemon answered. This result is the state FILE from an earlier run."
            + " Run logic_health, which starts the bridge and audits the rest of the setup."
    }

    /// The two-character assignment display in words. `MCULCDStrings.Assignment`
    /// names the documented modes; `P1`…`P8` is the per-insert parameter bank.
    /// Anything else is reported AS unrecognised rather than guessed at - Logic
    /// paints codes here this project has not enumerated (`P_`, live 2026-08-31).
    static func viewName(_ code: String) -> String {
        switch code {
        case MCULCDStrings.Assignment.pan: return "pan"
        case MCULCDStrings.Assignment.instrument: return "instrument edit"
        case MCULCDStrings.Assignment.send: return "send"
        case MCULCDStrings.Assignment.channelStrip: return "channel strip"
        case MCULCDStrings.Assignment.equalizer: return "EQ"
        default:
            if code.hasPrefix("P"), let slot = Int(code.dropFirst()), (1...8).contains(slot) {
                return "insert \(slot) parameters"
            }
            return "unrecognised (\(code))"
        }
    }

    /// Milliseconds are the finest thing worth reporting about a mirror's age,
    /// and a full double of them is noise in a result an agent reads.
    private static func round3(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }
}
