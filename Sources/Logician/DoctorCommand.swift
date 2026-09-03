import AppKit
import ApplicationServices
import Darwin
import Foundation
import LogicMCUBridge

// `logician doctor` — the support report.
//
// WHO IT IS FOR. `logic_health` is the AGENT's doctor: it starts the bridge,
// answers in JSON, and hands back the open project's path because the tools
// that follow need it. The human in Terminal filing an issue needs almost the
// opposite — the Logic build, the macOS build, Intel or Apple Silicon, the UI
// language, the port list, which MCP client is registered — and needs the
// project path to stay on their own machine. One tool cannot be both without
// lying to one of them, so this is the second one.
//
// IT ONLY READS. No daemon is started (the ping it uses is the one command
// exempt from `transact`'s self-healing restart), no MIDI is emitted, no
// config file is written, no Accessibility action is taken. A support tool
// that changes the state it is describing is a support tool that destroys
// evidence — and starting the bridge would repaint the user's control surface
// as a side effect of asking a question.

enum DoctorCommand {

    /// The whole subcommand: parse, collect, print, maybe write a file, exit
    /// code. Returns the exit code rather than calling `exit`, so the shape is
    /// readable and `main.swift` stays one line.
    static func run(_ arguments: [String]) -> Int32 {
        let options: DoctorFacts.Options
        switch DoctorFacts.parseOptions(arguments) {
        case .success(let parsed): options = parsed
        case .failure(let error):
            FileHandle.standardError.write(
                Data((error.message + "\n\n" + DoctorFacts.usage + "\n").utf8)
            )
            return 2
        }
        if options.help {
            print(DoctorFacts.usage)
            return 0
        }
        let redactor = DoctorRedactor.forThisMac(enabled: options.redact)
        let now = Date()
        let report = collect(options: options).redacted(by: redactor)
        let text = report.rendered(
            version: serverVersion,
            timestamp: DoctorFacts.headerTimestamp(at: now),
            redacted: options.redact
        )
        print(text, terminator: "")
        if options.bundle {
            let name = DoctorFacts.bundleFileName(at: now)
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(name)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                // Through the redactor like everything else: this line is
                // printed under the report and gets copied with it, and a
                // report that redacts nine sections and then prints the user's
                // home path in the tenth has protected nothing.
                print("\nWritten to \(redactor.redact(url.path)) — attach that file to the issue.")
            } catch {
                FileHandle.standardError.write(Data(
                    ("could not write \(url.path): \(error.localizedDescription). "
                        + "The report above is complete; copy it by hand, or run the doctor from a "
                        + "folder you can write to.\n").utf8
                ))
                return 2
            }
        }
        return report.exitCode
    }

    // MARK: - Collection

    static func collect(options: DoctorFacts.Options) -> DoctorReport {
        // ONE ping, reused by three sections. It is also the one bridge
        // command that never restarts a dead daemon behind our back.
        let bridge = MCUBridge.daemonAnswers() ? try? MCUBridge.send(.status) : nil
        let logic = LogicAccessibility()
        let facts = logic.healthFacts()
        return DoctorReport(sections: [
            DoctorSection(title: "Logician", lines: logicianLines()),
            DoctorSection(title: "This Mac", lines: macLines()),
            DoctorSection(title: "Logic Pro", lines: logicLines(logic: logic, facts: facts)),
            DoctorSection(title: "Accessibility", lines: accessibilityLines(facts: facts)),
            DoctorSection(title: "Bridge daemon", lines: bridgeLines(bridge)),
            DoctorSection(title: "MIDI ports", lines: portSection(bridge: bridge, options: options)),
            DoctorSection(title: "Key commands", lines: keyCommandLines()),
            DoctorSection(title: "Control surface", lines: surfaceLines(bridge)),
            DoctorSection(title: "MCP clients", lines: clientLines()),
            DoctorSection(title: "Bridge log", lines: bridgeLogLines())
        ])
    }

    // MARK: Logician

    static func logicianLines() -> [DoctorLine] {
        var lines: [DoctorLine] = [
            .ok("version", "\(serverVersion) (\(DoctorFacts.buildConfiguration) build)"),
            .ok("built with", "Swift \(DoctorFacts.swiftCompilerVersion)")
        ]
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        lines.append(.ok("binary", executable.path))
        if let modified = (try? FileManager.default.attributesOfItem(atPath: executable.path))?[
            .modificationDate
        ] as? Date {
            lines.append(.ok(
                "binary built",
                DoctorFacts.headerTimestamp(at: modified)
                    + " (\(DoctorFacts.humanDuration(seconds: -modified.timeIntervalSinceNow)) ago)"
            ))
        } else {
            lines.append(.unavailable("binary built", "the binary's timestamp could not be read"))
        }
        // What THIS process would serve. Not what the user's client serves —
        // the client passes its own flags, which the MCP clients section reads
        // back out of its config. Saying so is the whole value of the line.
        MCPServer.configureToolsets(log: { _ in })
        let active = MCPServer.activeToolsets.map(\.rawValue).sorted().joined(separator: ", ")
        lines.append(MCPServer.toolsetsAreNarrowed
            ? .note("toolsets here", active + " — narrowed by this terminal's LOGICIAN_TOOLSETS; "
                + "your client's own setting is in the MCP clients section below")
            : .ok("toolsets here", "all (\(active))"))
        return lines
    }

    // MARK: This Mac

    static func macLines() -> [DoctorLine] {
        var lines: [DoctorLine] = []
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        if let build = systemVersionValue("ProductBuildVersion") {
            lines.append(.ok("macOS", "\(number) (build \(build))"))
        } else {
            lines.append(.ok("macOS", number))
        }
        let translated = sysctlFlag("sysctl.proc_translated") == 1
        lines.append(DoctorFacts.architectureLine(
            binary: DoctorFacts.binaryArchitecture,
            translated: translated,
            hardwareIsAppleSilicon: hardwareIsAppleSilicon(translated: translated)
        ))
        let locale = Locale.current
        lines.append(.ok(
            "locale",
            locale.identifier
                + " (region \(locale.region?.identifier ?? "unknown"),"
                + " language \(locale.language.languageCode?.identifier ?? "unknown"))"
        ))
        return lines
    }

    /// One key out of `SystemVersion.plist`. Read as a property list rather
    /// than shelling out to `sw_vers`: no subprocess, and no dependency on a
    /// PATH the user may have rearranged.
    static func systemVersionValue(_ key: String) -> String? {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any] else { return nil }
        return plist[key] as? String
    }

    /// Whether this is an Apple Silicon Mac, from three sources because no
    /// single one of them holds.
    ///
    /// `hw.optional.arch.arm64` is the name Apple documents and it is NOT
    /// published on macOS 26 (measured 2026-09-04: `sysctl: unknown oid`),
    /// which reported this M-series Mac as an Intel one. The older
    /// `hw.optional.arm64` still answers 1, and an arm64 binary or a
    /// translated process is proof on its own — a Rosetta process only exists
    /// on Apple Silicon.
    static func hardwareIsAppleSilicon(translated: Bool) -> Bool {
        if translated || DoctorFacts.binaryArchitecture == "arm64" { return true }
        return sysctlFlag("hw.optional.arm64") == 1 || sysctlFlag("hw.optional.arch.arm64") == 1
    }

    /// An integer sysctl by name, or nil when this Mac does not publish it.
    /// `sysctl.proc_translated` is absent on Intel and 0 on a native arm64
    /// process, and both mean "not translated" — which is why the caller
    /// compares against 1 rather than testing for nil.
    static func sysctlFlag(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    // MARK: Logic Pro

    static func logicLines(
        logic: LogicAccessibility, facts: LogicAccessibility.HealthFacts
    ) -> [DoctorLine] {
        var lines: [DoctorLine] = []
        // The INSTALLED copy, read off disk. Logic does not have to be running
        // for this — and the report is most often run when it is not.
        let bundleURL = facts.application?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: logic.bundleIdentifier)
        if let bundleURL, let info = Bundle(url: bundleURL)?.infoDictionary {
            let short = info["CFBundleShortVersionString"] as? String ?? "unknown"
            let build = info["CFBundleVersion"] as? String ?? "unknown"
            lines.append(.ok("installed", "\(short) (build \(build)) at \(bundleURL.path)"))
        } else {
            lines.append(.missing(
                "installed",
                "no application with bundle id \(logic.bundleIdentifier) on this Mac",
                fix: "install Logic Pro from the App Store; every tool in this server drives a "
                    + "running Logic, so nothing below this line can work without it."
            ))
        }
        if let application = facts.application {
            lines.append(.ok("running", "yes (pid \(application.processIdentifier))"))
        } else {
            lines.append(.note(
                "running", "no — open Logic Pro and a project, then run the doctor again; the "
                    + "surface, the ports and the Accessibility checks below all read a LIVE Logic."
            ))
        }
        let hasDocument = !(facts.payload["project_document"] is NSNull)
        lines.append(facts.application == nil
            ? .unavailable("project open", "Logic is not running")
            : (hasDocument
                ? .ok("project open", "yes (the path is redacted; it is not a support question)")
                : .note("project open", "no — open or save a project: tools that address tracks, "
                    + "regions and bars need a document on disk to verify against")))
        if facts.dialogTitles.isEmpty {
            lines.append(.ok("dialogs open", "none"))
        } else {
            lines.append(.problem(
                "dialogs open",
                facts.dialogTitles.joined(separator: ", "),
                fix: "while a modal alert is up Logic stops feeding the control surface and "
                    + "swallows key commands, so every tool reports that it fired and nothing "
                    + "happened — answer or cancel it in Logic and run the doctor again."
            ))
        }
        let language = LogicUILanguage.report(LogicUILanguage.evidence(
            bundleIdentifier: logic.bundleIdentifier, runningBundleURL: facts.application?.bundleURL
        ))
        switch (language.language, language.isEnglish) {
        case (let code?, true?):
            lines.append(.ok("UI language", "\(code) — the language this server's Accessibility "
                + "plane assumes"))
        case (let code?, _):
            lines.append(.note("UI language", "\(code), not English — the control-surface plane "
                + "(transport, faders, sends, plugin parameters) is unaffected, but tools that "
                + "read Logic's own English words can report 'not found' on a healthy Logic. "
                + "Ask your agent for logic_health, whose logic_ui_language block lists what "
                + "degrades; switching Logic to English in System Settings ▸ General ▸ Language "
                + "& Region ▸ Applications restores it."))
        default:
            lines.append(.unavailable("UI language", "Logic's bundle could not be read, so no "
                + "claim is made either way"))
        }
        return lines
    }

    // MARK: Accessibility

    static func accessibilityLines(facts: LogicAccessibility.HealthFacts) -> [DoctorLine] {
        var lines: [DoctorLine] = []
        let trusted = facts.payload["accessibility_trusted"] as? Bool == true
        let parent = processName(pid: getppid())
        if trusted {
            lines.append(.ok("this process", "trusted"))
        } else {
            lines.append(.problem(
                "this process",
                "NOT trusted",
                fix: "macOS grants Accessibility to the app that launched this, not to the "
                    + "binary — tick \(parent ?? "your terminal app") in System Settings ▸ "
                    + "Privacy & Security ▸ Accessibility (click + and add it if it is not "
                    + "listed), then run the doctor again."
            ))
        }
        lines.append(.ok(
            "launched by",
            (parent ?? "unknown (pid \(getppid()))")
                + " — this is the app whose Accessibility tick the line above reflects"
        ))
        lines.append(.note(
            "your MCP client",
            "macOS does not let one app read another's Accessibility grant, so this cannot be "
                + "checked from here: your client (Claude Code, Antigravity, Cursor, …) needs its "
                + "own tick in the same System Settings pane, and the first Logic tool it runs "
                + "will ask for it."
        ))
        return lines
    }

    /// A process's display name: the app name when it has one, the executable
    /// name otherwise. `nil` when neither can be resolved, which is reported
    /// as unknown rather than guessed at.
    static func processName(pid: pid_t) -> String? {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        let path = String(decoding: buffer[0..<Int(length)], as: UTF8.self)
        return path.isEmpty ? nil : URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: Bridge daemon

    static func bridgeLines(_ bridge: BridgeResponse?) -> [DoctorLine] {
        var lines: [DoctorLine] = []
        let pid = daemonPid()
        guard let bridge, bridge.ok else {
            let stale = pid.map { kill($0, 0) == 0 || errno == EPERM } ?? false
            lines.append(.problem(
                "running",
                stale
                    ? "no — a daemon process (pid \(pid!)) exists but does not answer its socket"
                    : "no",
                fix: stale
                    ? "quit it with 'kill \(pid!)' in Terminal; the next Logic tool your agent "
                        + "runs starts a fresh one."
                    : "it starts by itself the first time your agent calls a Logic tool — ask for "
                        + "logic_health once. If you have never done that, this line is expected "
                        + "and nothing is broken."
            ))
            return lines
        }
        lines.append(.ok("running", "yes" + (pid.map { " (pid \($0))" } ?? "")))
        if let pid, let started = processStartTime(pid: pid) {
            lines.append(.ok(
                "uptime",
                DoctorFacts.humanDuration(seconds: -started.timeIntervalSinceNow)
                    + " (started \(DoctorFacts.headerTimestamp(at: started)))"
            ))
        } else {
            lines.append(.unavailable(
                "uptime", "the daemon's pid file is missing, so its start time cannot be read"
            ))
        }
        let spoken = bridge.bridgeProtocol ?? 0
        if spoken >= bridgeProtocolVersion {
            lines.append(.ok("protocol", "\(spoken) (this build speaks \(bridgeProtocolVersion))"))
        } else {
            lines.append(.problem(
                "protocol",
                "the running daemon speaks \(spoken), this build speaks \(bridgeProtocolVersion)",
                fix: "an old daemon survived an upgrade; it is replaced automatically the next "
                    + "time your agent runs logic_health, and until then newer commands fail."
            ))
        }
        return lines
    }

    /// The daemon's pid from the lockfile it writes at startup. `nil` for no
    /// lockfile, or one left by a daemon old enough to predate the pid file.
    static func daemonPid() -> pid_t? {
        let url = MCUBridge.directory.appendingPathComponent(BridgeProcess.lockFileName)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return BridgeProcess.parsePidFile(contents)
    }

    /// When a process started, from the kernel rather than from a file we
    /// wrote: a lockfile's timestamp survives the daemon it describes, and
    /// "uptime 4 days" about a daemon started ten minutes ago is worse than no
    /// uptime at all.
    static func processStartTime(pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        guard started.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970:
            Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }

    // MARK: MIDI ports

    static func portSection(bridge: BridgeResponse?, options: DoctorFacts.Options) -> [DoctorLine] {
        let verdict = DoctorFacts.classifyPorts(midiEndpointCensus())
        let namesListed = !options.redact && !verdict.otherNames.isEmpty
        var lines = DoctorFacts.portLines(
            verdict, bridgeRunning: bridge?.ok == true, namesListed: namesListed
        )
        if namesListed {
            lines.append(.ok("other devices", verdict.otherNames.joined(separator: ", ")))
        }
        return lines
    }

    // MARK: Key commands

    /// How much of the standard set Logic has been taught.
    ///
    /// A NOTE when some are missing, never a problem: they are learned lazily
    /// by the first tool that needs one, and `docs/INSTALL.md` step 3 tells
    /// every new user in so many words that a missing set is expected. Marking
    /// it `!!` would put a red flag on every fresh install and teach the
    /// reader to ignore the red flags.
    static func keyCommandLines() -> [DoctorLine] {
        let registered = Set(KeyCommandRegistry.commands().compactMap { $0["name"] as? String })
        let census = MCPServer.keyCommandCensus(
            standard: KeyCommandRegistry.standardCommands.map(\.name), registered: registered
        )
        let total = KeyCommandRegistry.standardCommands.count
        let have = total - census.missing.count
        guard !census.missing.isEmpty else {
            return [.ok("registry", "\(have) of \(total) learned")]
        }
        return [.note(
            "registry",
            "\(have) of \(total) learned; not yet learned: \(census.missing.joined(separator: ", "))"
                + " — expected on a new install, since each one is learned by the first tool that "
                + "needs it. Ask your agent for logic_setup_key_commands to do them all now, or "
                + "with relearn: true if a command is listed as learned and still does nothing."
        )]
    }

    // MARK: Control surface

    static func surfaceLines(_ bridge: BridgeResponse?) -> [DoctorLine] {
        guard let snapshot = bridge?.snapshot else {
            return [.unavailable(
                "mirror", "the bridge daemon is not answering, so there is no mirror to read"
            )]
        }
        let age = snapshot.lastReceive > 0
            ? Date().timeIntervalSince1970 - snapshot.lastReceive
            : nil
        var lines = [DoctorFacts.mirrorLine(
            lastReceiveAge: age, receivedEvents: snapshot.receivedEvents
        )]
        let assignment = snapshot.assignment.trimmingCharacters(in: .whitespaces)
        lines.append(assignment.isEmpty
            ? .unavailable("view", "Logic has not painted the assignment display yet")
            : .ok("view", "\(assignment) (\(MCUStatusReport.viewName(assignment)))"))
        return lines
    }

    // MARK: MCP clients

    static func clientLines() -> [DoctorLine] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var lines: [DoctorLine] = []
        var anyRegistered = false
        for config in DoctorClients.known {
            let url = home.appendingPathComponent(config.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url) else {
                lines.append(.unavailable(
                    config.client, "~/\(config.relativePath) exists but could not be opened"
                ))
                continue
            }
            let (reading, parsed) = DoctorClients.reading(of: data)
            guard let object = parsed else {
                switch reading {
                case .empty:
                    lines.append(.note(config.client, "found (~/\(config.relativePath)) but the "
                        + "file is empty — the client made it and nothing has been registered "
                        + "yet; docs/INSTALL.md step 2 has this client's one-line command."))
                case .commentedMentioningUs:
                    anyRegistered = true
                    lines.append(.note(config.client, "found (~/\(config.relativePath)), mentions "
                        + "logician, but the file is not strict JSON — this client allows // "
                        + "comments and the doctor will not guess at their meaning, so check "
                        + "that entry by hand."))
                default:
                    lines.append(.unavailable(
                        config.client, "~/\(config.relativePath) is not readable JSON"
                    ))
                }
                continue
            }
            let registration = DoctorClients.registration(in: object)
            guard registration.isRegistered else {
                lines.append(.note(
                    config.client,
                    "found (\(config.relativePath)) but Logician is not registered in it — see "
                        + "docs/INSTALL.md step 2 for this client's one-line command, and restart "
                        + "the client afterwards; it only reads MCP servers at launch."
                ))
                continue
            }
            anyRegistered = true
            var detail = "registered as " + registration.serverNames.joined(separator: ", ")
            if let command = registration.command {
                let exists = FileManager.default.isExecutableFile(atPath: command)
                detail += exists
                    ? " → \(command)"
                    : " → \(command) (THAT FILE IS NOT THERE: rebuild with 'swift build -c "
                        + "release', or re-register with the path 'echo \"$(pwd)/.build/release/"
                        + "logician\"' prints)"
                if !exists {
                    lines.append(DoctorLine(label: config.client, value: detail, status: .problem))
                    continue
                }
            }
            if let toolsets = registration.toolsets {
                detail += " [\(toolsets) — this client is offered only those tools; remove the "
                    + "flag and restart it to get all of them]"
            }
            lines.append(.ok(config.client, detail))
        }
        if lines.isEmpty {
            lines.append(.missing(
                "MCP clients",
                "none of the config files this doctor knows about exists on this Mac",
                fix: "register Logician with your client — docs/INSTALL.md step 2 has the "
                    + "one-line command for Claude Code, Antigravity, Gemini CLI, Cursor, VS Code "
                    + "and LM Studio; a client this doctor does not know about is fine and simply "
                    + "will not appear here."
            ))
        } else if !anyRegistered {
            lines.append(.problem(
                "registration",
                "clients were found but none of them has Logician in it",
                fix: "run your client's add command from docs/INSTALL.md step 2 and then fully "
                    + "quit and reopen the client."
            ))
        }
        return lines
    }

    // MARK: Bridge log

    static func bridgeLogLines() -> [DoctorLine] {
        guard let lines = MCUBridge.tailBridgeLog(lines: 12) else {
            return [.unavailable(
                "recent output",
                "no log yet at \(MCUBridge.bridgeLogURL.path) — it is written from the moment a "
                    + "daemon is started by logician \(serverVersion) or newer, so an older "
                    + "daemon that is still running has none"
            )]
        }
        guard !lines.isEmpty else {
            return [.ok("recent output", "the log exists and is empty — the daemon has said nothing, "
                + "which is what a healthy one does")]
        }
        return lines.enumerated().map { index, line in
            .ok(index == 0 ? "recent output" : "", line)
        }
    }
}
