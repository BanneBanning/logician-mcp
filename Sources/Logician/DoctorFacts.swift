import Foundation
import LogicMCUBridge

// The judgements `logician doctor` makes, separated from the readings it makes
// them about. Everything here is a pure function of plain values: a port list,
// a number of seconds, an architecture triple. The collectors in
// DoctorCommand.swift do the reading; this file decides what the reading MEANS
// and writes the sentence — which is the half that has to be right, and the
// half no live Mac can be persuaded to reproduce on demand (an orphaned twin
// port is precisely the state you cannot arrange for a test).

enum DoctorFacts {

    // MARK: - Command line

    /// Flags `logician doctor` accepts.
    struct Options: Equatable {
        /// ON by default. The report is a public artefact until the user says
        /// otherwise, and a default that leaks is not a default.
        var redact = true
        /// Also write the report next to the user, as a file they can attach.
        var bundle = false
        /// `--help`: print usage and exit 0 without collecting anything.
        var help = false
    }

    /// An unusable command line, carrying the sentence to print. A value, not
    /// a thrown error: a support tool answers a typo with the list of flags.
    struct UsageError: Error, Equatable {
        let message: String
    }

    /// Parses the arguments AFTER the `doctor` subcommand. Returns the usage
    /// error as text rather than throwing: an unknown flag on a support tool
    /// should print the flags and stop, not produce a stack trace.
    static func parseOptions(_ arguments: [String]) -> Result<Options, UsageError> {
        var options = Options()
        for argument in arguments {
            switch argument {
            case "--redact": options.redact = true
            case "--no-redact": options.redact = false
            case "--bundle": options.bundle = true
            case "-h", "--help": options.help = true
            default:
                return .failure(UsageError(
                    message: "logician doctor: unknown option '\(argument)'. Valid options are "
                        + "--redact (the default), --no-redact, --bundle and --help."
                ))
            }
        }
        return .success(options)
    }

    static let usage = """
        logician doctor — the setup report to paste into a support issue.

          logician doctor              collect and print the report (redacted)
          logician doctor --no-redact  include real paths, project and file names
          logician doctor --bundle     also write logician-doctor-<timestamp>.txt here
          logician doctor --help       print this

        Exits 0 when everything Logician needs is present, 1 when something is missing.
        Nothing is written to Logic, the bridge daemon or any config file: the doctor
        only reads.
        """

    // MARK: - This build

    /// The Swift compiler this binary was built with, from the only source
    /// that survives into a release build: the compile-time `#if compiler`
    /// ladder. There is no runtime API for it, and reporting a guess would be
    /// worse than reporting a range, so the newest rung says "or newer".
    static var swiftCompilerVersion: String {
        #if compiler(>=6.4)
        return "6.4 or newer"
        #elseif compiler(>=6.3)
        return "6.3.x"
        #elseif compiler(>=6.2)
        return "6.2.x"
        #elseif compiler(>=6.1)
        return "6.1.x"
        #elseif compiler(>=6.0)
        return "6.0.x"
        #elseif compiler(>=5.10)
        return "5.10.x"
        #else
        return "older than 5.10"
        #endif
    }

    /// `debug` or `release`. SwiftPM defines `DEBUG` for the debug
    /// configuration only, so this is exact rather than inferred — and it
    /// matters: a debug binary is several times slower, which is a support
    /// case all by itself ("everything times out").
    static var buildConfiguration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    /// The architecture this binary was COMPILED for. Compile-time, so it
    /// cannot be confused by Rosetta the way `uname` is.
    static var binaryArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// The architecture line, including the Rosetta verdict.
    ///
    /// A `note`, not a problem: an x86_64 build under Rosetta genuinely works
    /// — CoreMIDI and Accessibility are both translated — it is merely slow
    /// and unsupported, and telling a user whose setup works that they have a
    /// PROBLEM is how a doctor loses their trust. It still says what to do.
    static func architectureLine(
        binary: String, translated: Bool, hardwareIsAppleSilicon: Bool
    ) -> DoctorLine {
        let hardware = hardwareIsAppleSilicon ? "Apple Silicon" : "Intel"
        guard translated else {
            return .ok("architecture", "\(binary) binary on \(hardware) (native)")
        }
        return .note(
            "architecture",
            "\(binary) binary on \(hardware) — RUNNING UNDER ROSETTA. It works, but it is slower "
                + "and untested: rebuild natively by opening Terminal with 'Open using Rosetta' "
                + "UNTICKED (right-click Terminal in Applications ▸ Get Info) and running "
                + "'swift build -c release' again."
        )
    }

    // MARK: - Durations

    /// A duration a human reads at a glance. Support reports are skimmed, and
    /// `1209600 s` is not a number anybody parses.
    static func humanDuration(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "unknown" }
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        if seconds < 90 { return String(format: "%.0f s", seconds) }
        let minutes = seconds / 60
        if minutes < 90 { return String(format: "%.0f min", minutes) }
        let hours = minutes / 60
        if hours < 48 { return String(format: "%.1f h", hours) }
        return String(format: "%.1f days", hours / 24)
    }

    // MARK: - The MCU mirror

    /// How old the surface mirror is, and whether that is a fault.
    ///
    /// Three different states wear the same "it does not work" clothes, and
    /// they need three different fixes: Logic has NEVER spoken to the surface
    /// (the Mackie Control was never added, or Logic dropped the port on a
    /// bridge restart); Logic spoke to it and has since gone quiet longer than
    /// the server itself will trust (`MCUController.staleMirrorSeconds`, 600 s
    /// — normal for an idle Logic, and one wake probe answers it); or it is
    /// live. Only the first is a problem.
    static func mirrorLine(lastReceiveAge: Double?, receivedEvents: Int) -> DoctorLine {
        guard receivedEvents > 0, let age = lastReceiveAge else {
            return .problem(
                "surface mirror",
                "Logic has never sent this surface anything (0 events)",
                fix: "add the Mackie Control in Logic ▸ Control Surfaces ▸ Setup ▸ New ▸ Install ▸ "
                    + "'Mackie Control', and set BOTH its Input Port and Output Port to "
                    + "'Logic MCP MCU'; if it was already there, Logic drops the port when the "
                    + "bridge restarts, so re-pick it in the same window (or restart Logic)."
            )
        }
        let echo = "last echo from Logic \(humanDuration(seconds: age)) ago, \(receivedEvents) events"
        guard age >= MCUController.staleMirrorSeconds else { return .ok("surface mirror", echo) }
        return .note(
            "surface mirror",
            echo + " — older than the \(Int(MCUController.staleMirrorSeconds)) s the server will "
                + "trust, which is normal for an idle Logic: the next tool that needs the surface "
                + "wakes it with one probe and the mirror is fresh again."
        )
    }

    // MARK: - MIDI ports

    /// What the CoreMIDI port list says about this install.
    struct PortVerdict: Equatable {
        /// Our endpoints that are present with the identity Logic binds to.
        let present: [String]
        /// Our endpoints that are absent altogether.
        let missing: [String]
        /// Endpoints named like ours carrying an identity we never claimed —
        /// the orphaned twins.
        let orphans: [String]
        /// Names appearing more than once anywhere in the list, ours or not.
        let duplicates: [String]
        let sourceCount: Int
        let destinationCount: Int
        /// Every port that is not ours, for `--no-redact`.
        let otherNames: [String]
    }

    /// Classifies a port census. Pure, so the states that matter — a missing
    /// port, an orphaned twin, a hardware desk with a colliding name — can be
    /// pinned by tests against a list this Mac does not have.
    static func classifyPorts(_ census: [MIDIEndpointInfo]) -> PortVerdict {
        var present: [String] = []
        var missing: [String] = []
        for expected in expectedBridgeEndpoints {
            let match = census.first {
                $0.name == expected.name && $0.isSource == expected.isSource
                    && $0.uniqueID == expected.uniqueID
            }
            let label = "\(expected.name) (\(expected.isSource ? "input" : "output"))"
            if match != nil { present.append(label) } else { missing.append(label) }
        }
        let orphans = census
            .filter { $0.name.hasPrefix("Logic MCP") && !expectedPortUniqueIDs.contains($0.uniqueID) }
            .map { "\($0.name) (\($0.isSource ? "input" : "output"), id \($0.uniqueID))" }
        var seen: Set<String> = []
        var duplicates: [String] = []
        for endpoint in census {
            let key = "\(endpoint.name)|\(endpoint.isSource)"
            if seen.contains(key) {
                if !duplicates.contains(endpoint.name) { duplicates.append(endpoint.name) }
            }
            seen.insert(key)
        }
        let otherNames = census
            .filter { !$0.name.hasPrefix("Logic MCP") }
            .map { "\($0.name) (\($0.isSource ? "input" : "output"))" }
        return PortVerdict(
            present: present,
            missing: missing,
            orphans: orphans,
            duplicates: duplicates,
            sourceCount: census.filter(\.isSource).count,
            destinationCount: census.filter { !$0.isSource }.count,
            otherNames: otherNames
        )
    }

    /// The port section's lines. The orphan case gets the long fix because it
    /// is the single most confusing failure in this system: everything looks
    /// connected while key commands fire into a dead endpoint.
    /// `namesListed` is true when the caller is about to print the other
    /// devices by name anyway (`--no-redact`), so the count line does not
    /// advertise a flag the reader has already used.
    static func portLines(
        _ verdict: PortVerdict, bridgeRunning: Bool, namesListed: Bool = false
    ) -> [DoctorLine] {
        var lines: [DoctorLine] = []
        if verdict.missing.isEmpty {
            lines.append(.ok("bridge ports", verdict.present.joined(separator: ", ")))
        } else if bridgeRunning {
            lines.append(.problem(
                "bridge ports",
                "missing: " + verdict.missing.joined(separator: ", ")
                    + (verdict.present.isEmpty ? "" : "; present: " + verdict.present.joined(separator: ", ")),
                fix: "the bridge daemon is answering but did not publish these, which means "
                    + "something else holds their identity: quit your MCP client, run "
                    + "'killall MIDIServer' in Terminal, then start the client again."
            ))
        } else {
            lines.append(.problem(
                "bridge ports",
                "missing: " + verdict.missing.joined(separator: ", "),
                fix: "the bridge daemon is not running, and the ports are its doing — ask your "
                    + "agent to run logic_health once, which starts it, then reopen Logic ▸ "
                    + "Control Surfaces ▸ Setup and pick 'Logic MCP MCU' for both ports."
            ))
        }
        if !verdict.orphans.isEmpty {
            lines.append(.problem(
                "stale twin ports",
                verdict.orphans.joined(separator: ", "),
                fix: "these are leftovers from a bridge that died without cleaning up, and Logic "
                    + "binds key commands to a port's identity — so picking the wrong twin makes "
                    + "every key command silently stop firing. Quit your MCP client, run "
                    + "'killall MIDIServer' in Terminal, start the client again, re-pick "
                    + "'Logic MCP MCU' in Logic ▸ Control Surfaces ▸ Setup, then ask your agent "
                    + "for logic_setup_key_commands with relearn: true."
            ))
        } else {
            lines.append(.ok("stale twin ports", "none"))
        }
        let colliding = verdict.duplicates.filter { $0.hasPrefix("Logic MCP") }
        if !colliding.isEmpty {
            lines.append(.problem(
                "duplicate names",
                colliding.joined(separator: ", "),
                fix: "two ports answer to one of our names, so Logic's port menu shows two "
                    + "identical rows and either one can be picked: 'killall MIDIServer' in "
                    + "Terminal after quitting your MCP client clears the impostor."
            ))
        }
        lines.append(.ok(
            "all MIDI ports",
            "\(verdict.sourceCount) inputs, \(verdict.destinationCount) outputs on this Mac"
                + (verdict.otherNames.isEmpty
                    ? " (none besides ours)"
                    : " — \(verdict.otherNames.count) belong to other devices"
                        + (namesListed ? "" : "; `--no-redact` lists them by name"))
        ))
        return lines
    }

    // MARK: - The bundle file

    /// `logician-doctor-20260904-210311.txt`. Second resolution and no colons:
    /// this name has to survive being attached to an issue, mailed and
    /// unzipped on a case-insensitive filesystem.
    static func bundleFileName(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "logician-doctor-\(formatter.string(from: date)).txt"
    }

    /// The timestamp in the report header. ISO-8601-ish with the offset, so a
    /// maintainer reading two reports can order them.
    static func headerTimestamp(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter.string(from: date)
    }
}
