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

    /// G00: learn ANY command in Logic's Key Commands window, not just the 22
    /// the product ships. The machinery underneath is the same one
    /// `logic_setup_key_commands` has used since v0.20 — the only thing that
    /// ever gated it was the schema `enum`. What is new here is the consent
    /// story: the note is picked from a range reserved for arbitrary commands,
    /// and the registry entry says this tool bound it, when, and from which
    /// search term.
    func handleLearnKeyCommand(_ arguments: [String: Any]) throws -> Any {
        let name = try requiredString("name", in: arguments)
        let search = (arguments["search"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? KeyCommandRegistry.defaultSearchTerm(for: name)
        let relearn = (arguments["relearn"] as? Bool) ?? false

        // Look before binding. A dry run is the honest answer to "names drift
        // between Logic versions": it opens the window, filters, reads the
        // rows and closes again, binding nothing.
        if (arguments["dry_run"] as? Bool) == true {
            var usedSearch = search
            var rows = try logic.searchKeyCommands(search)
            // A term that matches nothing tells the caller nothing. Widen to
            // the first word once — "strip silence" finds no row in Logic
            // 12.3.1 while "silence" finds the command that replaced it
            // ("Remove Silence from Audio Region…", measured 2026-08-28).
            if rows.isEmpty,
               let firstWord = search.split(separator: " ").first.map(String.init),
               firstWord != search {
                usedSearch = firstWord
                rows = try logic.searchKeyCommands(firstWord)
            }
            let search = usedSearch
            let exact = rows.contains {
                ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame
            }
            return [
                "success": true, "verified": true, "state": "searched",
                "requested_name": name, "search": search,
                "exact_match": exact,
                "match_count": rows.count,
                "matches": rows,
                "note": exact
                    ? "NOTHING WAS BOUND (dry_run). Logic has a command with exactly this name - call again without dry_run to learn it."
                    : "NOTHING WAS BOUND (dry_run). No row carries exactly '\(name)'. Pick a name from matches (assignment shows what each command is already bound to), or search a shorter term."
            ]
        }

        let taken = KeyCommandRegistry.takenNotes()

        // Already in the registry and not being repaired: answer from the file
        // rather than opening the Key Commands window for nothing. The window
        // steals focus from Logic's project window, so not opening it is a
        // feature, not just a saving.
        if !relearn, let existing = KeyCommandRegistry.note(named: name) {
            return [
                "success": true, "verified": true, "state": "already_registered",
                "name": name, "midi_note": existing.note, "channel": existing.channel,
                "note": "Already in the key command registry - nothing was bound and the Key Commands window was not opened. Fire it with logic_trigger_key_command {name: \"\(name)\"}. Pass relearn: true to bind it again (the repair when a command silently stopped firing)."
            ]
        }

        var chosenNote: Int
        if let explicit = arguments["note"] as? Int {
            guard (0...127).contains(explicit) else {
                throw LogicianError.invalidArguments("note must be 0-127; got \(explicit)")
            }
            // An explicit note that another command already answers to would
            // make the registry lie about which command a note fires.
            if !relearn, let holder = KeyCommandRegistry.entry(note: explicit, channel: 16),
               ((holder["name"] as? String) ?? "").caseInsensitiveCompare(name) != .orderedSame {
                throw LogicianError.invalidArguments(
                    "note \(explicit) is already registered to '\(holder["name"] ?? "?")'. "
                        + "Nothing was bound. Omit 'note' to let the free range pick one."
                )
            }
            chosenNote = explicit
        } else {
            guard let free = KeyCommandRegistry.freeNote(taken: taken) else {
                throw LogicianError.invalidArguments(
                    "no free MIDI note left for a new key command (the registry holds "
                        + "\(KeyCommandRegistry.commands().count)). Remove one in Logic's Key "
                        + "Commands window and delete its entry from \(KeyCommandRegistry.url.path)."
                )
            }
            chosenNote = free
        }

        let results = try logic.setupKeyCommands(
            [(search: search, name: name, preferredNote: chosenNote)],
            forceRelearn: relearn,
            source: "logic_learn_key_command"
        )
        guard let entry = results.first else {
            throw LogicianError.verificationFailed(
                requested: "learning '\(name)'",
                actual: "the Key Commands automation returned no result at all",
                restored: false
            )
        }
        let status = entry["status"] as? String ?? "failed"
        if status == "not_found" {
            throw LogicianError.keyCommandNotFound(
                requested: name, searched: search,
                candidates: (entry["candidates"] as? [String]) ?? []
            )
        }
        guard status == "learned" || status == "already_learned" else {
            throw LogicianError.verificationFailed(
                requested: "a MIDI-note assignment for '\(name)'",
                actual: "\(status): \(entry["note"] as? String ?? "the Key Commands window did not confirm a new assignment")",
                restored: false
            )
        }
        var payload: [String: Any] = [
            "success": true, "verified": true, "state": status,
            "name": entry["name"] ?? name,
            "midi_note": entry["midi_note"] ?? chosenNote,
            "channel": 16,
            "search": search,
            "registry_path": KeyCommandRegistry.url.path,
            "note": "This wrote into YOUR OWN Logic key command set: '\(entry["name"] ?? name)' now also answers to a MIDI note on the 'Logic MCP Commands' port. It is ADDITIVE - the existing keyboard shortcut is untouched - and removable in Logic's Key Commands window (select the command, Delete Assignment). The registry file records the name, the note, the timestamp and that logic_learn_key_command bound it; logic_list_key_commands reads it back. Fire it with logic_trigger_key_command."
        ]
        if let requested = entry["requested_name"] {
            payload["requested_name"] = requested
            payload["warning"] = "Logic's own spelling is '\(entry["name"] ?? name)', not '\(name)' - the registry holds Logic's."
        }
        if let deleted = entry["stale_assignments_deleted"] {
            payload["stale_assignments_deleted"] = deleted
        }
        return payload
    }

    /// U4: the registry's contents, which nothing could read before. Pure file
    /// read — Logic is not touched, not even asked whether it is running.
    func handleListKeyCommands(_ arguments: [String: Any]) throws -> Any {
        let standard = Dictionary(
            uniqueKeysWithValues: KeyCommandRegistry.standardCommands.map {
                ($0.name.lowercased(), $0)
            }
        )
        let commands = KeyCommandRegistry.commands().map { raw -> [String: Any] in
            let name = (raw["name"] as? String) ?? "?"
            var entry: [String: Any] = [
                "name": name,
                "note": raw["note"] ?? NSNull(),
                "channel": raw["channel"] ?? 16,
                // Entries written before v0.54 carry no source; saying so is
                // more honest than attributing them to the onboarding tool.
                "source": raw["source"] ?? "unrecorded (bound before the registry tracked a source)",
                "learned": raw["learned"] ?? NSNull(),
                "standard": standard[name.lowercased()] != nil
            ]
            if let at = raw["learned_at"] { entry["learned_at"] = at }
            if let search = raw["search"] { entry["search"] = search }
            if let notes = raw["notes"] { entry["notes"] = notes }
            return entry
        }.sorted { (($0["name"] as? String) ?? "") < (($1["name"] as? String) ?? "") }

        let registered = Set(commands.compactMap { ($0["name"] as? String)?.lowercased() })
        let missing = KeyCommandRegistry.standardCommands
            .filter { !registered.contains($0.name.lowercased()) }
            .map(\.name)
        return [
            "success": true, "verified": true,
            "port": "Logic MCP Commands",
            "registry_path": KeyCommandRegistry.url.path,
            "count": commands.count,
            "commands": commands,
            "standard_not_learned": missing,
            "learnable_note_range": "\(KeyCommandRegistry.learnableNoteRange.lowerBound)-\(KeyCommandRegistry.learnableNoteRange.upperBound)",
            "note": "The registry is the CONSENT RECORD: logic_trigger_key_command refuses any note that is not listed here, because an unlisted note could be bound to anything in the user's key command set. Every entry is an assignment that exists in the user's own Logic Key Commands window and can be removed there (select the command, Delete Assignment). This call read a file - Logic was not touched, so an entry listed here can still have been orphaned inside Logic (recreated MIDI ports do that silently); logic_setup_key_commands with relearn: true is the repair."
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
