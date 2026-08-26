import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

enum MCUBridge {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LogicMCPMCU")
    }

    static func status() -> [String: Any] {
        let stateURL = directory.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateURL),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [
                "bridge_running": false,
                "note": "no state file; start the bridge with .build/release/logic-mcu-bridge"
            ]
        }
        let updated = object["updated"] as? Double ?? 0
        object["bridge_running"] = Date().timeIntervalSince1970 - updated < 15
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent("command.sock").path)
        return object
    }

    /// Starts the bridge daemon when its socket is dead: standard MCP
    /// practice is that the server manages its own sidecars. Looks for the
    /// logic-mcu-bridge binary next to this executable.
    static func ensureRunning() {
        if let pong = try? send(["cmd": "ping"]), pong["ok"] as? Bool == true {
            if (pong["bridge_protocol"] as? Int ?? 0) >= 2 { return }
            // An outdated daemon owns the socket (pre-versioned builds kept
            // answering pings and silently lacked newer commands) — replace it.
            FileHandle.standardError.write(Data("[logician] replacing outdated bridge daemon\n".utf8))
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-f", "logic-mcu-bridge|logician --bridge"]
            try? kill.run()
            kill.waitUntilExit()
            Thread.sleep(forTimeInterval: 0.5)
        }
        // The bridge daemon is this same binary launched with --bridge —
        // one distributable artifact, no sibling files to install.
        let serverURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let process = Process()
        process.executableURL = serverURL
        process.arguments = ["--bridge"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        for _ in 0..<30 {
            usleep(100_000)
            if (try? send(["cmd": "ping"]))?["ok"] as? Bool == true {
                FileHandle.standardError.write(Data("[logician] started bridge daemon\n".utf8))
                return
            }
        }
    }

    static func send(_ command: [String: Any]) throws -> [String: Any] {
        let path = directory.appendingPathComponent("command.sock").path
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DemoError.writeFailed("could not create a socket")
        }
        defer { Darwin.close(fd) }
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
            throw DemoError.writeFailed(
                "could not reach the MCU bridge socket; is logic-mcu-bridge running?"
            )
        }
        let payload = try JSONSerialization.data(withJSONObject: command)
        _ = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, payload.count) }
        Darwin.shutdown(fd, SHUT_WR)
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &buffer, buffer.count)
        guard count > 0,
              let response = try? JSONSerialization.jsonObject(
                  with: Data(buffer[0..<count])
              ) as? [String: Any] else {
            throw DemoError.openVerificationFailed("no response from the MCU bridge")
        }
        return response
    }
}

/// Key commands learned onto the dedicated "Logic MCP Commands" MIDI port
/// (Key Commands window > Learn New Assignment). The registry file is the
/// consent record: only notes listed there may be triggered, because an
/// unlisted note could be bound to anything in the user's key command set.
