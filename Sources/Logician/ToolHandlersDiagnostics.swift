import Foundation
import LogicMCUBridge

// Diagnostics and the raw control-surface plane: health, key commands,
// MCU bridge status and raw MCU commands.
extension MCPServer {
    func handleHealth(_ arguments: [String: Any]) throws -> Any {
        var health = logic.health()
        // Doctor checks: every setup step as data, with the fix in text.
        MCUBridge.ensureRunning()
        let bridge = (try? MCUBridge.send(.status)) ?? BridgeResponse(ok: false)
        let bridgeUp = bridge.ok
        let receivedEvents = bridge.snapshot?.receivedEvents ?? 0
        health["bridge_running"] = bridgeUp
        health["mcu_connected"] = receivedEvents > 0
        if !bridgeUp {
            health["bridge_fix"] = "the bridge subprocess could not be started (self-spawn with --bridge failed)"
        } else if receivedEvents == 0 {
            health["mcu_fix"] = "no MIDI from Logic yet. If this is a FRESH setup: add a Mackie Control in Logic > Control Surfaces > Setup with ports 'Logic MCP MCU'. If it worked before and the bridge was restarted: Logic does not reopen the port by itself - open Control Surfaces > Setup and re-pick 'Logic MCP MCU' in Input/Output Port (or restart Logic). Tools fall back to Accessibility meanwhile, slower and less complete."
        }
        // Orphaned twin ports are the single most confusing failure
        // in this system: everything looks connected while key
        // commands fire into a dead endpoint.
        let orphans = orphanedPortNames()
        if !orphans.isEmpty {
            health["duplicate_ports"] = orphans
            health["duplicate_ports_fix"] = "Logic's port list shows TWO of these; the extras are "
                + "orphans from a bridge that died without cleaning up, and Logic binds key "
                + "commands to a port's unique ID - so picking the wrong twin makes every key "
                + "command silently stop firing. Fix: quit this MCP client, run 'killall "
                + "MIDIServer' in a terminal, start the client again, re-pick 'Logic MCP MCU' "
                + "in Logic > Control Surfaces > Setup, then run logic_setup_key_commands "
                + "with relearn: true."
        }
        let registered = Set(KeyCommandRegistry.commands().compactMap { $0["name"] as? String })
        health["key_commands"] = KeyCommandRegistry.standardCommands.map { command in
            ["name": command.name, "registered": registered.contains(command.name)]
        }
        if !KeyCommandRegistry.standardCommands.allSatisfy({ registered.contains($0.name) }) {
            health["key_commands_fix"] = "run logic_setup_key_commands (or let the first tool that needs one learn it automatically); if commands are listed as registered but never fire, run it with relearn: true - port recreation orphans the bindings in Logic"
        }
        if health["accessibility_trusted"] as? Bool != true {
            health["accessibility_fix"] = "grant Accessibility in System Settings: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }
        return health
    }

    func handleSetupKeyCommands(_ arguments: [String: Any]) throws -> Any {
        let relearn = (arguments["relearn"] as? Bool) ?? false
        var targets = KeyCommandRegistry.standardCommands
        if let onlyNames = arguments["commands"] as? [String], !onlyNames.isEmpty {
            targets = targets.filter { onlyNames.contains($0.name) }
            guard !targets.isEmpty else {
                throw LogicianError.invalidArguments(
                    "no standard command matches; valid names: "
                        + KeyCommandRegistry.standardCommands.map(\.name).joined(separator: ", ")
                )
            }
        }
        let results = try logic.setupKeyCommands(targets, forceRelearn: relearn)
        return [
            "results": results,
            "note": "Assignments were added to the user's active key command set (additive; removable in the Key Commands window). The registry file records the final note numbers."
        ]
    }

    func handleTriggerKeyCommand(_ arguments: [String: Any]) throws -> Any {
        let payload: Any
        if let name = arguments["name"] as? String {
            let found = try MCUController.resolveKeyCommand(named: name, logic: logic)
            var triggered = try MCUController.triggerKeyCommand(
                note: found.note, channel: found.channel
            )
            if MCUController.lastResolveLearned {
                triggered["first_run_learning"] =
                    "This command was just learned: the Key Commands window opened briefly (one-time per machine). Run logic_setup_key_commands during onboarding to do all learning up front."
            }
            payload = triggered
        } else {
            let note = arguments["note"] as? Int ?? -1
            let channel = arguments["channel"] as? Int ?? 16
            payload = try MCUController.triggerKeyCommand(note: note, channel: channel)
        }
        return payload
    }

    func handleMcuStatus(_ arguments: [String: Any]) throws -> Any {
        return MCUBridge.status()
    }

    func handleMcuCommand(_ arguments: [String: Any]) throws -> Any {
        let payload: Any
        // The registry is the consent record: firing a raw MIDI note
        // could trigger whatever the user has bound to it. Route
        // `keycmd` through the registry-checked path (refuses unlisted
        // notes) instead of forwarding it raw to the bridge.
        if (arguments["cmd"] as? String) == "keycmd" {
            guard let note = arguments["note"] as? Int else {
                throw LogicianError.invalidArguments("keycmd requires an integer note")
            }
            let channel = arguments["channel"] as? Int ?? 16
            payload = try MCUController.triggerKeyCommand(note: note, channel: channel)
            return payload
        }
        var command: [String: Any] = [:]
        for (key, value) in arguments where key != "expected_project_path" {
            command[key] = value
        }
        // sendRaw, not send: this tool exists to reach commands the server
        // does not model, so the agent's object goes over the wire verbatim
        // and the reply comes back verbatim. Everywhere else the server
        // speaks BridgeCommand/BridgeResponse.
        payload = try MCUBridge.sendRaw(command)
        return payload
    }
}
