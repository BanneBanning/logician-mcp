import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

enum MCUBridge {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LogicMCPMCU")
    }

    /// The state FILE mirror, not the socket — the fallback when the daemon
    /// cannot be reached, and the body of the `logic_mcu_status` tool result.
    ///
    /// Stays a verbatim dictionary on purpose. The file is written by
    /// whatever daemon build happens to be running, which during an upgrade
    /// is not necessarily this one; passing its contents through unchanged
    /// means a newer daemon's fields still reach the agent. Use
    /// `SurfaceSnapshot` when you want the typed view of the same bytes.
    static func status() -> [String: Any] {
        let stateURL = directory.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateURL),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [
                "bridge_running": false,
                "note": "no state file yet; the bridge starts automatically - call logic_health, which starts it and audits the rest of the setup"
            ]
        }
        let updated = object["updated"] as? Double ?? 0
        object["bridge_running"] = Date().timeIntervalSince1970 - updated < 15
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent("command.sock").path)
        return object
    }

    /// What `ensureRunning()` had to do.
    ///
    /// The caller needs this because a snapshot it read BEFORE the call can
    /// describe a daemon that no longer exists: a replaced daemon starts with
    /// `received_events` at 0, so reusing the old reading would report
    /// `mcu_connected: true` about a bridge Logic has not spoken to yet.
    /// `unchanged` is the promise that the daemon answering now is the one
    /// that was answering before, so an earlier read is still good.
    enum StartOutcome {
        /// Nothing moved — including the branch where an outdated daemon
        /// could not be stopped and was deliberately kept.
        case unchanged
        /// A daemon was spawned (there was none, or the old one was replaced).
        case started
        /// No daemon is answering.
        case failed
    }

    /// Starts the bridge daemon when its socket is dead: standard MCP
    /// practice is that the server manages its own sidecars. Looks for the
    /// logic-mcu-bridge binary next to this executable.
    @discardableResult
    static func ensureRunning() -> StartOutcome {
        if let pong = try? send(.ping), pong.ok {
            if (pong.bridgeProtocol ?? 0) >= bridgeProtocolVersion { return .unchanged }
            // An outdated daemon owns the socket (pre-versioned builds kept
            // answering pings and silently lacked newer commands) — replace it.
            FileHandle.standardError.write(Data("[logician] replacing outdated bridge daemon\n".utf8))
            guard replaceRunningDaemon() else {
                // The old daemon is still alive. Starting a second one now is
                // the worst available move: it cannot claim the fixed MIDI
                // unique IDs, so it would either die or run silently orphaned,
                // and for a moment two bridges would be driving Logic — the
                // exact hazard the single-instance lock exists to prevent.
                // Keep the working old daemon and say what is wrong instead.
                let lockName: String = BridgeProcess.lockFileName
                var message = "[logician] could not stop the outdated bridge daemon;"
                message += " keeping it rather than running two bridges."
                message += " Quit it by hand (it holds"
                message += " ~/Library/Application Support/LogicMCPMCU/" + lockName + ")"
                message += " and rerun logic_health.\n"
                FileHandle.standardError.write(Data(message.utf8))
                return .unchanged
            }
        }
        // The bridge daemon is this same binary launched with --bridge —
        // one distributable artifact, no sibling files to install.
        let serverURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let process = Process()
        process.executableURL = serverURL
        process.arguments = ["--bridge"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .failed }
        for _ in 0..<30 {
            usleep(100_000)
            if (try? send(.ping))?.ok == true {
                FileHandle.standardError.write(Data("[logician] started bridge daemon\n".utf8))
                return .started
            }
        }
        return .failed
    }

    /// Stops the daemon that currently owns the socket, and CONFIRMS it is
    /// gone. Returns false when something is still answering, in which case
    /// the caller must not start a replacement.
    ///
    /// Two ways to find the target, in order of precision:
    ///  1. the pid the daemon wrote into its own lockfile — exact, and immune
    ///     to how its command line was spelled;
    ///  2. a `ps` scan filtered by `BridgeProcess.daemonPids`, for a daemon
    ///     old enough to predate the pid file (which is precisely the daemon
    ///     an upgrade is most likely to meet).
    ///
    /// The previous implementation did neither: it `pkill -f`'d the server's
    /// own ABSOLUTE path plus " --bridge", which never matched a daemon
    /// started as `./.build/release/logician --bridge`. It then started a
    /// second bridge regardless, which is how one upgrade attempt briefly ran
    /// two of them (FINDINGS 2026-08-28).
    static func replaceRunningDaemon() -> Bool {
        var targets: [Int32] = []
        let lockURL = directory.appendingPathComponent(BridgeProcess.lockFileName)
        if let contents = try? String(contentsOf: lockURL, encoding: .utf8),
           let pid = BridgeProcess.parsePidFile(contents) {
            targets.append(pid)
        }
        if targets.isEmpty {
            targets = BridgeProcess.daemonPids(
                among: BridgeProcess.parsePS(runPS()), excluding: getpid()
            )
        }
        guard !targets.isEmpty else { return false }
        for pid in targets { kill(pid, SIGTERM) }
        // Confirm, rather than sleeping and hoping. The daemon closes its
        // socket on exit, so a ping that no longer answers IS the proof.
        for _ in 0..<40 {
            usleep(100_000)
            let alive = targets.contains { kill($0, 0) == 0 }
            if !alive, (try? send(.ping)) == nil { return true }
        }
        // Still there after 4 s: escalate once, then re-check.
        for pid in targets where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        for _ in 0..<20 {
            usleep(100_000)
            if !targets.contains(where: { kill($0, 0) == 0 }) { return true }
        }
        return false
    }

    private static func runPS() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -ww: do not truncate the argument vector to the terminal width.
        process.arguments = ["-axww", "-o", "pid=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The typed path: every command is built from `BridgeCommand`'s
    /// factories, so a key name is a compiler-checked identifier rather than
    /// a string literal repeated at 35 call sites.
    static func send(_ command: BridgeCommand) throws -> BridgeResponse {
        let data = try transact(try bridgeJSONEncoder.encode(command), command.name)
        guard let response = try? bridgeJSONDecoder.decode(BridgeResponse.self, from: data) else {
            throw LogicianError.openVerificationFailed("no response from the MCU bridge")
        }
        return response
    }

    /// Same typed command, but the reply is handed back as the raw parsed
    /// dictionary.
    ///
    /// Deliberate: `MCUController.freshStatus()` feeds dozens of call sites
    /// that read the snapshot as a dictionary, and `logic_mcu_status` hands
    /// the object to agents. Returning the parsed JSON verbatim means a
    /// NEWER daemon's extra keys survive an older server instead of being
    /// silently dropped by our decoder — which matters precisely because the
    /// two processes can be at different versions during an upgrade.
    static func sendForDictionary(_ command: BridgeCommand) throws -> [String: Any] {
        let data = try transact(try bridgeJSONEncoder.encode(command), command.name)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LogicianError.openVerificationFailed("no response from the MCU bridge")
        }
        return object
    }

    /// Untyped passthrough for `logic_mcu_command`, which forwards an
    /// agent-authored object verbatim. There is no type to check here by
    /// construction: the whole point of that tool is to reach commands the
    /// server does not model. Everything else goes through `send(_:)`.
    static func sendRaw(_ command: [String: Any]) throws -> [String: Any] {
        let payload = try JSONSerialization.data(withJSONObject: command)
        let data = try transact(
            payload, (command["cmd"] as? String).flatMap(BridgeCommandName.init(rawValue:))
        )
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LogicianError.openVerificationFailed("no response from the MCU bridge")
        }
        return object
    }

    /// Whether this process has ever sent the control surface a command that
    /// could have moved it.
    ///
    /// Set at the one boundary every command passes through, and read exactly
    /// once, on shutdown: a session that only listed tools must not reach into
    /// Logic and reset the user's surface view on the way out.
    ///
    /// WHICH commands count is `BridgeCommandName.emitsMIDI`'s answer, not a
    /// list kept here. This used to read `!= .ping`, which made every `status`
    /// a touch — and `status` is what `logic_health` sends, so the server's
    /// one `readOnly` doctor ended every session by pressing PAN (measured
    /// 2026-09-02: 145 ms on a surface already in Pan, and a real view change
    /// on a surface the user had left in a Send or insert view).
    nonisolated(unsafe) private(set) static var didTouchSurface = false // single writer, monotonic

    private static func transact(_ payload: Data, _ command: BridgeCommandName?) throws -> Data {
        if command?.emitsMIDI ?? true { didTouchSurface = true }
        do {
            return try sendOnce(payload)
        } catch LogicianError.writeFailed(let detail) where detail.hasPrefix("could not reach") {
            // The daemon died mid-session. Self-healing is the stated
            // philosophy everywhere else; do it here instead of making the
            // agent guess that logic_health is the cure. A ping is exempt
            // because a ping is how `ensureRunning()` looks: retrying one
            // through it would recurse.
            guard command != .ping else { throw LogicianError.writeFailed(detail) }
            ensureRunning()
            return try sendOnce(payload)
        }
    }

    private static func sendOnce(_ payload: Data) throws -> Data {
        let path = directory.appendingPathComponent("command.sock").path
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw LogicianError.writeFailed("could not create a socket")
        }
        defer { Darwin.close(fd) }
        // A daemon that closes the connection mid-command (a restart, a
        // crash, its own receive deadline) must cost THIS call an EPIPE —
        // surfaced below as LogicianError.writeFailed — not a process-wide
        // SIGPIPE, which is fatal by default and would take the entire MCP
        // server down with it. Set on the fd, not via signal(): the server
        // does not own the process's signal dispositions.
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
                   socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: UnsafeRawBufferPointer(
                    start: source, count: min(strlen(source) + 1, raw.count)
                ))
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard connected == 0 else {
            throw LogicianError.writeFailed(
                "could not reach the MCU bridge socket (it is started automatically; "
                    + "run logic_health if this persists)"
            )
        }
        // Write ALL of it (retrying short writes) and half-close so the
        // bridge sees a clean EOF; then read the whole reply until it closes.
        guard writeAll(fd, payload) else {
            throw LogicianError.writeFailed("the MCU bridge closed the connection mid-command")
        }
        Darwin.shutdown(fd, SHUT_WR)
        let data = readToEOF(fd)
        guard !data.isEmpty else {
            throw LogicianError.openVerificationFailed("no response from the MCU bridge")
        }
        return data
    }
}

