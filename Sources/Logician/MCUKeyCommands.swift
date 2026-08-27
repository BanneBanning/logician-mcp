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
            throw LogicianError.trackNotExposed(
                requested: "key command note \(note) channel \(channel)",
                exposed: "registered commands: "
                    + KeyCommandRegistry.commands().map {
                        "\($0["name"] ?? "?") (note \($0["note"] ?? "?"))"
                    }.joined(separator: ", ")
            )
        }
        let response = try MCUBridge.send(.keycmd(note: note, channel: channel))
        guard response.ok else {
            throw LogicianError.writeFailed("keycmd failed: \(response.error ?? "?")")
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
        let response = try MCUBridge.send(.channel(.select, channel))
        guard response.ok else { return false }
        _ = awaitEvents(since: before, timeoutMs: 400)
        return true
    }

    /// Which strips' SELECT LEDs (notes 0x18-0x1F) Logic reports lit. Logic
    /// echoes these — verified live 2026-08-27 — which makes them the one
    /// piece of the mirror that says WHICH strip the surface is pointed at.
    static func selectedStrips(in status: [String: Any]) -> [Int] {
        (0..<8).filter { ledLit(0x18 + $0, in: status) }
    }

    /// Selects a strip and PROVES, before any write, that the surface's
    /// selection landed on the strip the caller named. Returns which evidence
    /// it got, for the result to report.
    ///
    /// The PL and plugin-edit views do not name the channel they are editing —
    /// which is exactly how plugins once landed on Stereo Out by accident
    /// (FINDINGS 2026-08-25, v0.31.0). So the proof is taken in the pan-names
    /// view, where the names ARE painted, from two independent pieces of the
    /// mirror: the strip's LCD cell must be a plausible abbreviation of the
    /// requested name, and its SELECT LED must then light. The name is read
    /// BEFORE the press because Logic paints a transient `Select` banner over
    /// the cell right after it (observed 2026-08-27), so the cell text is
    /// unusable for a moment.
    ///
    /// The LED half refuses only on POSITIVE evidence, like the timecode
    /// guard: a *different* strip lit is proof of a wrong selection and fails
    /// the call, but NO strip lit proves nothing (the echo is verified on one
    /// machine, and a surface configuration that never sends it must not break
    /// a working operation) — the LCD-name evidence stands alone and the
    /// caller reports that it did.
    @discardableResult
    static func selectChannelVerified(channel: Int, expectedName: String) throws -> String {
        guard (0...7).contains(channel) else {
            throw LogicianError.invalidArguments("MCU channel must be 0-7; got \(channel)")
        }
        guard try ensurePanNames(), let status = freshStatus(),
              let top = status["lcd_top"] as? String else {
            throw LogicianError.trackNotExposed(
                requested: "control-surface selection of '\(expectedName)'",
                exposed: "the pan-names view could not be reached, so which strip is selected cannot be proven"
            )
        }
        let cell = lcdFields(top)[channel]
        guard lcdAbbreviationPlausible(track: expectedName, lcd: cell) else {
            throw LogicianError.verificationFailed(
                requested: "strip \(channel + 1) showing '\(expectedName)'",
                actual: "it shows '\(cell)' (bank row: '\(top.trimmingCharacters(in: .whitespaces))'); nothing was selected or written",
                restored: true
            )
        }
        guard try selectFoundChannel(channel) else {
            throw LogicianError.writeFailed("the MCU select for strip \(channel + 1) was refused by the bridge")
        }
        if waitFor(seconds: 2.0, { ledLit(0x18 + channel, in: $0) }) != nil {
            return "mcu_lcd_name_and_select_led"
        }
        let lit = freshStatus().map { selectedStrips(in: $0) } ?? []
        guard lit.isEmpty else {
            throw LogicianError.verificationFailed(
                requested: "the SELECT LED of strip \(channel + 1) ('\(expectedName)')",
                actual: "strip(s) \(lit.map { $0 + 1 }) are selected instead — the surface is pointed"
                    + " at another channel; nothing was written",
                restored: false
            )
        }
        debugLog("selectChannelVerified: no SELECT LED echo for strip \(channel); LCD name evidence only")
        return "mcu_lcd_name_only"
    }

}
