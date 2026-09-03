import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {
    // MARK: Key commands over the dedicated MIDI port

    /// Fires a key command learned onto the "Logic MCP Commands" port. Only
    /// registry-listed notes are sent — an unlisted note could be bound to
    /// anything in the user's key command set.
    ///
    /// `holdMs` is the wire's `hold_ms` (see `BridgeCommand.keycmdHoldMs`):
    /// `nil` leaves the daemon on its own default, MEASURED live 2026-09-03
    /// by `keycmd_hold_sweep.py` (0-40 ms all created exactly one marker,
    /// 16/16 at 0 ms, zero duplicates, zero drops) and now compiled to 0 ms
    /// — see `resolveKeycmdDefaultHoldMs`. A value asks for exactly that
    /// hold, including 0. Only `logic_mcu_command`'s `keycmd` route exposes
    /// it today; `logic_trigger_key_command` still asks for nothing, which
    /// now means the measured 0 ms instead of the old flat 40 ms.
    static func triggerKeyCommand(note: Int, channel: Int, holdMs: Int? = nil) throws -> [String: Any] {
        guard let entry = KeyCommandRegistry.entry(note: note, channel: channel) else {
            // A refusal names the alternative — it does not paste the whole
            // registry into an error string. This used to render 1159 B of
            // prose (measured 2026-09-02 against the real 27-command
            // registry), ~24x a normal reply from this plane, unparseable and
            // uncapped, to say one thing: that note is not registered. The
            // count is the fact worth carrying inline; the names live in the
            // tool whose entire job is to list them.
            throw LogicianError.trackNotExposed(
                requested: "key command note \(note) channel \(channel)",
                exposed: "\(KeyCommandRegistry.commands().count) commands are registered — "
                    + "logic_list_key_commands names them with their notes, and "
                    + "logic_learn_key_command adds one"
            )
        }
        let response = try MCUBridge.send(.keycmd(note: note, channel: channel, holdMs: holdMs))
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
        // Logic's focused channel is about to move to an INDEX; whether it
        // lands, and on which strip by NAME, is only proven by callers that
        // verify (selectChannelVerified re-records it). Until then the honest
        // record is "unknown", never the name that was true a press ago.
        forgetChannelFocus()
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
        // Same rule as the record-arm route's pre-press proof: the cell names
        // the strip, or the only thing on it is this server's own press banner
        // (`stripProvenByCell`). Without the second half, muting a track and
        // then opening a plug-in on it inside the banner's ~2 s window refuses
        // a strip `findChannel` had just proved — a hole the surface-wake
        // package opened here by making the resolution fast, and one that
        // record-arm now reaches too.
        guard stripProvenByCell(
            track: expectedName, cell: cell, channel: channel,
            record: lastControlPressBanner
        ) else {
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
            noteChannelFocus(expectedName, projectPath: currentProjectPath())
            return "mcu_lcd_name_and_select_led"
        }
        var lit = freshStatus().map { selectedStrips(in: $0) } ?? []
        if !lit.isEmpty {
            // The wrong strip is lit. Before refusing, try the one repair that
            // is known to work — see `resyncSelection`.
            debugLog("selectChannelVerified: strip(s) \(lit.map { $0 + 1 }) lit instead of"
                + " \(channel + 1); attempting a neighbour resync")
            if try resyncSelection(channel: channel, expectedName: expectedName) {
                noteChannelFocus(expectedName, projectPath: currentProjectPath())
                return "mcu_lcd_name_and_select_led_after_resync"
            }
            lit = freshStatus().map { selectedStrips(in: $0) } ?? []
        }
        guard lit.isEmpty else {
            throw LogicianError.verificationFailed(
                requested: "the SELECT LED of strip \(channel + 1) ('\(expectedName)')",
                actual: "strip(s) \(lit.map { $0 + 1 }) are selected instead — the surface is pointed"
                    + " at another channel and a neighbour resync did not recover it;"
                    + " nothing was written",
                restored: false
            )
        }
        debugLog("selectChannelVerified: no SELECT LED echo for strip \(channel); LCD name evidence only")
        noteChannelFocus(expectedName, projectPath: currentProjectPath())
        return "mcu_lcd_name_only"
    }

    /// Detect-and-resync: select a NEIGHBOUR strip, then come back.
    ///
    /// The failure this repairs is the one the project cares most about — the
    /// surface lit on a strip the caller did not ask for — and it cannot heal
    /// itself, because a SELECT press on a strip whose LED is ALREADY lit is a
    /// no-op (observed 2026-08-28 with the LED on strip 8 while the PL view
    /// showed a different strip's plugins). Pressing a neighbour first forces
    /// a real state change, so the press that follows is no longer a no-op.
    /// That neighbour bounce is the documented MANUAL fix; this is the same
    /// two presses, taken automatically, behind the verification rather than
    /// instead of it.
    ///
    /// It only ever runs AFTER the LCD-name evidence has already proven the
    /// strip index is the right one, so the worst case is two extra selects on
    /// a strip the caller was about to select anyway. Returns true only when
    /// the target's own SELECT LED is lit at the end — a resync that does not
    /// visibly land is reported as a failure, never assumed.
    ///
    /// The neighbour is chosen inside the bank (channel 0 borrows from the
    /// right, everything else from the left) so the bank never moves: banking
    /// would change what every strip index MEANS, which is a bigger hazard
    /// than the one being repaired.
    @discardableResult
    static func resyncSelection(channel: Int, expectedName: String) throws -> Bool {
        guard (0...7).contains(channel) else { return false }
        let neighbour = channel == 0 ? 1 : channel - 1
        guard try selectFoundChannel(neighbour) else { return false }
        _ = waitFor(seconds: 1.0, { ledLit(0x18 + neighbour, in: $0) })
        guard try selectFoundChannel(channel) else { return false }
        let landed = waitFor(seconds: 2.0, { ledLit(0x18 + channel, in: $0) }) != nil
        debugLog("resyncSelection: strip \(channel + 1) ('\(expectedName)') via neighbour"
            + " \(neighbour + 1) -> \(landed ? "lit" : "still not lit")")
        return landed
    }

}
