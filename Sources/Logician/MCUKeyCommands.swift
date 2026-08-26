import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {
    // MARK: Key commands over the dedicated MIDI port

    /// Fires a key command learned onto the "Logic MCP Commands" port. Only
    /// registry-listed notes are sent — an unlisted note could be bound to
    /// anything in the user's key command set.
    static func triggerKeyCommand(note: Int, channel: Int) throws -> [String: Any] {
        guard let entry = KeyCommandRegistry.entry(note: note, channel: channel) else {
            throw DemoError.trackNotExposed(
                requested: "key command note \(note) channel \(channel)",
                exposed: "registered commands: "
                    + KeyCommandRegistry.commands().map {
                        "\($0["name"] ?? "?") (note \($0["note"] ?? "?"))"
                    }.joined(separator: ", ")
            )
        }
        let response = try MCUBridge.send([
            "cmd": "keycmd", "note": note, "channel": channel
        ])
        guard response["ok"] as? Bool == true else {
            throw DemoError.writeFailed("keycmd failed: \(response["error"] ?? "?")")
        }
        return [
            "success": true,
            "command": entry["name"] ?? "?",
            "note": note,
            "channel": channel,
            "route": "midi_key_command"
        ]
    }

    /// Selects the MCU channel found by findChannel and confirms via the
    /// select-echo Logic paints into that channel's LCD field.
    static func selectFoundChannel(_ channel: Int) throws -> Bool {
        let before = freshStatus()?["received_events"] as? Int ?? -1
        let response = try MCUBridge.send(["cmd": "select", "channel": channel])
        guard response["ok"] as? Bool == true else { return false }
        _ = awaitEvents(since: before, timeoutMs: 400)
        return true
    }

}
