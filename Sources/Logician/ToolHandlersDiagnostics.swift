import Foundation
import LogicMCUBridge

// Diagnostics and the raw control-surface plane: health, key commands,
// MCU bridge status and raw MCU commands.
extension MCPServer {
    func handleHealth(_ arguments: [String: Any]) throws -> Any {
        let facts = logic.healthFacts()
        var health = facts.payload
        // Doctor checks: every setup step as data, with the fix in text.
        //
        // ONE round trip on a healthy Mac, where this used to make two:
        // `ensureRunning()`'s ping proved liveness and then `.status` was sent
        // for the snapshot. `.status` proves liveness exactly as well, and
        // since 2026-09-02 it echoes `bridge_protocol` too, so the version
        // check that justified the ping rides along. A daemon too old to echo
        // it — or a dead socket — falls back to the full start-and-upgrade
        // path, which is where that work belonged all along.
        var bridge = try? MCUBridge.send(.status)
        if bridge?.ok != true || (bridge?.bridgeProtocol ?? 0) < bridgeProtocolVersion {
            let outcome = MCUBridge.ensureRunning()
            if MCPServer.mustRereadStatus(firstReadAnswered: bridge?.ok == true, after: outcome) {
                bridge = try? MCUBridge.send(.status)
            }
        }
        let bridgeUp = bridge?.ok == true
        let receivedEvents = bridge?.snapshot?.receivedEvents ?? 0
        health["bridge_running"] = bridgeUp
        health["mcu_connected"] = receivedEvents > 0
        if !bridgeUp {
            health["bridge_fix"] = "the bridge subprocess could not be started (self-spawn with --bridge failed)"
        } else if receivedEvents == 0 {
            health["mcu_fix"] = MCPServer.mcuRemediation(dialogTitles: facts.dialogTitles)
            // The evidence behind that sentence, so the reader can go and look
            // rather than take the doctor's word for it. Only on this branch:
            // a dialog open on a working surface is not a fault, and this
            // report is already 87% boilerplate.
            if !facts.dialogTitles.isEmpty {
                health["open_dialogs"] = facts.dialogTitles
            }
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
        let keyCommands = MCPServer.keyCommandCensus(
            standard: KeyCommandRegistry.standardCommands.map(\.name), registered: registered
        )
        health["key_commands"] = keyCommands.census
        if !keyCommands.missing.isEmpty {
            health["key_commands_fix"] = "run logic_setup_key_commands (or let the first tool that needs one learn it automatically); if commands are listed as registered but never fire, run it with relearn: true - port recreation orphans the bindings in Logic"
        }
        // Which language Logic is drawing in — the one setup property that
        // silently disables a third of the surface and that nothing used to
        // report. An INFERENCE, and the block says so; see `LogicUILanguage`.
        // Promoted to a top-level `language_note` when it is not English, so
        // an agent skimming the doctor's output cannot miss it — as ONE LINE
        // pointing back at the block, not as a second copy of the 1 371-char
        // account (which is what it was until 2026-09-02).
        let language = LogicUILanguage.healthBlock(
            bundleIdentifier: logic.bundleIdentifier,
            runningBundleURL: facts.application?.bundleURL
        )
        health["logic_ui_language"] = language.payload
        if let note = language.topLevelNote {
            health["language_note"] = note
        }
        if health["accessibility_trusted"] as? Bool != true {
            health["accessibility_fix"] = "grant Accessibility in System Settings: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }
        // The two most basic preconditions had no fix line at all, so a report
        // with Logic closed read as a list of subsystem failures instead of
        // "open Logic". Both are pure functions of the facts above.
        for (key, text) in MCPServer.applicationRemediations(
            logicRunning: health["logic_running"] as? Bool == true,
            hasProjectDocument: !(health["project_document"] is NSNull)
        ) {
            health[key] = text
        }
        // `success` says the CHECK ran, never that everything it checked is
        // healthy — the individual booleans and the `*_fix` strings say that,
        // and a doctor that reported success: false on a missing key command
        // would be indistinguishable from one that could not look.
        health["success"] = true
        health["state"] = "checked"
        return health
    }

    /// `logic_fix` / `project_fix` for `logic_health`, as a pure function of
    /// the two facts they describe — the rest of the doctor's fixes need live
    /// MIDI or Accessibility state, these two do not.
    static func applicationRemediations(
        logicRunning: Bool,
        hasProjectDocument: Bool
    ) -> [String: String] {
        var fixes: [String: String] = [:]
        if !logicRunning {
            fixes["logic_fix"] = "Logic Pro is not running. Open Logic Pro and open a project; every tool in this server reads or writes a live Logic, and the control surface only exists while Logic is up. Nothing below this line can be diagnosed until it is."
        } else if !hasProjectDocument {
            // Only worth saying once Logic IS up: with Logic closed the missing
            // document is a consequence, not a second thing to fix.
            fixes["project_fix"] = "Logic is running but no project document is open (an empty Logic window, or a project that has never been saved to disk). Open or save a project: tools that address tracks, regions and bars need one, and the tools that verify against a project path cannot check anything without it."
        }
        return fixes
    }

    /// Whether the `status` read taken BEFORE `ensureRunning()` still
    /// describes the daemon that is answering AFTER it.
    ///
    /// Two things make it stale, and only two. The read may not have answered
    /// at all (dead socket), or `ensureRunning()` may have put a different
    /// daemon there — and a fresh daemon starts with `received_events` at 0,
    /// so reusing the old reading would report `mcu_connected: true` about a
    /// bridge Logic has never spoken to. Everything else keeps the first read,
    /// which is what makes the common case one socket round trip instead of
    /// two: a daemon too old to echo `bridge_protocol` on `status` is still
    /// proven alive AND current by the ping inside `ensureRunning()`, so its
    /// snapshot is still the right one and costs what it always did.
    static func mustRereadStatus(
        firstReadAnswered: Bool, after outcome: MCUBridge.StartOutcome
    ) -> Bool {
        !firstReadAnswered || outcome != .unchanged
    }

    /// `mcu_fix` — the remedy for "the bridge is up and Logic has sent it
    /// nothing yet".
    ///
    /// That one symptom has two completely unrelated cures, and until
    /// 2026-09-02 the doctor only knew the second. A Logic sitting on a modal
    /// alert stops feeding the control surface entirely (the same mechanism
    /// measured on `logic_add_send`: a modal reads as a dead bridge), so the
    /// tool most likely to be run BECAUSE something is stuck was answering
    /// "go and re-pick your MIDI ports" at someone whose only problem was an
    /// unanswered dialog. `logic_health` already walks Logic's window list for
    /// the project document; naming what it saw there costs nothing and is
    /// the only way to tell the reader which cure they are in.
    ///
    /// The dialog is named as a POSSIBILITY, not a verdict: the window list
    /// says a dialog, sheet or floating window is open, not that it is modal
    /// — an open plugin window looks the same from here.
    static func mcuRemediation(dialogTitles: [String]) -> String {
        let ports = "If this is a FRESH setup: add a Mackie Control in Logic > Control Surfaces > Setup with ports 'Logic MCP MCU'. If it worked before and the bridge was restarted: Logic does not reopen the port by itself - open Control Surfaces > Setup and re-pick 'Logic MCP MCU' in Input/Output Port (or restart Logic). Tools fall back to Accessibility meanwhile, slower and less complete."
        guard !dialogTitles.isEmpty else {
            return "no MIDI from Logic yet, and Logic has no dialog open (its window list was read"
                + " at the same moment), so this is the setup. " + ports
        }
        let named = dialogTitles.map { "'\($0)'" }.joined(separator: ", ")
        return "no MIDI from Logic yet, and Logic HAS a window open that can be the reason: "
            + named + ". While a modal alert is up Logic stops feeding the control surface"
            + " altogether, which looks exactly like a surface that was never set up - and it"
            + " swallows key commands too, so tools report that they fired and nothing happened."
            + " Answer or cancel it in Logic (logic_list_windows shows its buttons) and run"
            + " logic_health again. Only if mcu_connected is still false with nothing on screen"
            + " is it the MIDI setup: " + ports
    }

    /// The `key_commands` block, as a pure function of the two name sets.
    ///
    /// It used to be 22 rows of `{"name": …, "registered": true}` — 1 268 B,
    /// 56% of a healthy report's whole payload (measured 2026-09-02), every
    /// byte of it saying nothing is wrong. The names only carry information
    /// when one is MISSING, and the failure already has its own
    /// `key_commands_fix` line, so the healthy case is a count.
    static func keyCommandCensus(
        standard: [String], registered: Set<String>
    ) -> (census: [String: Any], missing: [String]) {
        let missing = standard.filter { !registered.contains($0) }
        var census: [String: Any] = [
            "registered": standard.count - missing.count,
            "of": standard.count,
            "all_registered": missing.isEmpty
        ]
        if !missing.isEmpty { census["missing"] = missing }
        return (census, missing)
    }

    func handleSetupKeyCommands(_ arguments: [String: Any]) throws -> Any {
        // 0.8 ms warm, 16.6 ms cold, against a call that binds 22 commands
        // over several minutes. Learning onto a port whose twin Logic is
        // actually bound to is the single most expensive way to produce a
        // registry entry that lies, and the server's own daemon-upgrade path
        // (SIGKILL after a 4 s SIGTERM) is one manufacturer of that orphan.
        if let refusal = KeyCommandRegistry.orphanRefusal(
            orphans: orphanedPortNames(), action: "learning key commands"
        ) { throw LogicianError.preconditionUnmet(refusal) }
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
        // The one hazard this flow's own readback provably cannot see: the row
        // text says "Note 74" whether or not the port Logic bound it to still
        // exists. The audit is one CoreMIDI enumeration (0.8 ms warm, 16.6 ms
        // cold). The read-only answers below carry it as a warning; the paths
        // that BIND refuse.
        let orphanWarning = KeyCommandRegistry.orphanRefusal(
            orphans: orphanedPortNames(), action: "learning '\(name)'"
        )

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
            let exact = rows.contains {
                ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame
            }
            var payload: [String: Any] = [
                "success": true, "verified": true, "state": "searched",
                "requested_name": name, "search": usedSearch,
                "exact_match": exact,
                "match_count": rows.count,
                "matches": rows,
                "note": exact
                    ? "NOTHING WAS BOUND (dry_run). Logic has a command with exactly this name - call again without dry_run to learn it."
                    : "NOTHING WAS BOUND (dry_run). No row carries exactly '\(name)'. Pick a name from matches (assignment shows what each command is already bound to), or search a shorter term."
            ]
            if let orphanWarning { payload["warning"] = orphanWarning }
            return payload
        }

        // Already in the registry and not being repaired: answer from the file
        // rather than opening the Key Commands window for nothing. The window
        // steals focus from Logic's project window, so not opening it is a
        // feature, not just a saving.
        if !relearn, let existing = KeyCommandRegistry.note(named: name) {
            var payload: [String: Any] = [
                "success": true, "verified": true, "state": "already_registered",
                "name": name, "midi_note": existing.note, "channel": existing.channel,
                "note": "Already in the key command registry - nothing was bound and the Key Commands window was not opened. Fire it with logic_trigger_key_command {name: \"\(name)\"}. Pass relearn: true to bind it again (the repair when a command silently stopped firing)."
            ]
            if let orphanWarning { payload["warning"] = orphanWarning }
            return payload
        }

        // Every path from here binds. Refuse rather than record something that
        // may never fire.
        if let orphanWarning { throw LogicianError.preconditionUnmet(orphanWarning) }

        // Read AFTER the early return above: the fast path used to parse the
        // registry file one extra time for a note it never chose.
        let taken = KeyCommandRegistry.takenNotes()

        var chosenNote: Int
        if let explicit = arguments["note"] as? Int {
            guard (0...127).contains(explicit) else {
                throw LogicianError.invalidArguments("note must be 0-127; got \(explicit)")
            }
            // An explicit note that another command already answers to would
            // make the registry lie about which command a note fires — and
            // that is just as true on the repair path, which is why the
            // `!relearn` prefix this guard used to carry is gone. The
            // exemption `relearn` actually needs is the SAME-NAME one, and
            // `explicitNoteRefusal` is exactly that: it never refuses a
            // command its own note.
            if let refusal = KeyCommandRegistry.explicitNoteRefusal(
                note: explicit, name: name, in: KeyCommandRegistry.commands()
            ) { throw LogicianError.invalidArguments(refusal) }
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
        // Refusals, not failures: the driver looked, found a state it must not
        // write over, and left everything alone. Their own text names the way
        // forward, so it is the whole message.
        if status == "already_assigned" || status == "relearn_refused",
           let explanation = entry["note"] as? String {
            throw LogicianError.preconditionUnmet(explanation)
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
        var warnings: [String] = []
        if let requested = entry["requested_name"] {
            payload["requested_name"] = requested
            warnings.append("Logic's own spelling is '\(entry["name"] ?? name)', not '\(name)' - the registry holds Logic's.")
        }
        // The driver's own warning — the registry refusing a note another
        // command holds — must not be lost behind the spelling one.
        if let carried = entry["warning"] as? String { warnings.append(carried) }
        if !warnings.isEmpty { payload["warning"] = warnings.joined(separator: " ") }
        if let deleted = entry["stale_assignments_deleted"] {
            payload["stale_assignments_deleted"] = deleted
        }
        // A cold bridge daemon costs up to 3 s inside the note send; it used
        // to be invisible.
        if let started = entry["bridge_start_ms"] { payload["bridge_start_ms"] = started }
        return payload
    }

    /// U4: the registry's contents, which nothing could read before. Logic is
    /// not touched, not even asked whether it is running — the file, plus one
    /// CoreMIDI enumeration (0.8 ms warm) for the port identity the entries
    /// are compared against.
    func handleListKeyCommands(_ arguments: [String: Any]) throws -> Any {
        let livePortID = sourceUniqueID(named: commandsPortName).map(Int.init)
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
            // Logic scopes an assignment to the port's unique ID, so an entry
            // that records which identity it was learned against can be
            // checked later; one that does not is silent about it rather than
            // presumed good.
            if let recorded = raw["port_unique_id"] as? Int {
                entry["port_unique_id"] = recorded
                if let livePortID { entry["port_identity"] = recorded == livePortID ? "current" : "changed" }
            }
            return entry
        }.sorted { (($0["name"] as? String) ?? "") < (($1["name"] as? String) ?? "") }

        let registered = Set(commands.compactMap { ($0["name"] as? String)?.lowercased() })
        let missing = KeyCommandRegistry.standardCommands
            .filter { !registered.contains($0.name.lowercased()) }
            .map(\.name)
        let stale = KeyCommandRegistry.staleIdentityNames(
            in: commands, currentPortUniqueID: livePortID
        )
        var payload: [String: Any] = [
            "success": true, "verified": true,
            "port": "Logic MCP Commands",
            "port_unique_id": livePortID ?? NSNull(),
            "registry_path": KeyCommandRegistry.url.path,
            "count": commands.count,
            "commands": commands,
            "standard_not_learned": missing,
            "learnable_note_range": "\(KeyCommandRegistry.learnableNoteRange.lowerBound)-\(KeyCommandRegistry.learnableNoteRange.upperBound)",
            "note": "The registry is the CONSENT RECORD: logic_trigger_key_command refuses any note that is not listed here, because an unlisted note could be bound to anything in the user's key command set. Every entry is an assignment that exists in the user's own Logic Key Commands window and can be removed there (select the command, Delete Assignment). This call read a file - Logic was not touched, so an entry listed here can still have been orphaned inside Logic (recreated MIDI ports do that silently); logic_setup_key_commands with relearn: true is the repair."
        ]
        if !stale.isEmpty {
            payload["port_identity_changed"] = stale
            payload["warning"] = "These commands were learned against a DIFFERENT 'Logic MCP "
                + "Commands' port identity than the one live now (\(stale.joined(separator: ", ")))"
                + ". Logic binds key commands to a port's unique ID, so they may look registered "
                + "and never fire. Repair: logic_setup_key_commands with relearn: true for the "
                + "standard set, logic_learn_key_command with relearn: true for the rest."
        }
        return payload
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

    // MARK: - Finding a tool

    /// The most tools `logic_find_tool` will return in one answer. Measured
    /// 2026-09-01: ten full typed definitions is 26.7-52.6 KB on the wire
    /// (6.7-13.2k tokens) against a whole `tools/list` of 171.6 KB, so a
    /// limit-10 answer already costs 15-31% of the surface it exists to spare
    /// you. Past that the search stops being cheaper than the list.
    static let findToolLimit = 10
    static let findToolDefaultLimit = 5

    /// `logic_find_tool`: keyword search over the WHOLE registry, answered
    /// with the same typed definitions `tools/list` advertises.
    ///
    /// The only tool here that never touches Logic Pro — no Accessibility, no
    /// control surface, no bridge. It reads `toolRegistry()`, which is a
    /// constant, so it is safe to call with Logic closed, and it deliberately
    /// searches the full registry rather than `activeTools()`: a session
    /// narrowed to `core` is exactly the session that needs to be told a tool
    /// exists and which flag would bring it back.
    func handleFindTool(_ arguments: [String: Any]) throws -> Any {
        let query = try requiredString("query", in: arguments)
        // A query with no letters and no digits in it is a caller bug, not a
        // search that found nothing, and the empty-result note ("no tool
        // shares a word with that query") would be a lie about it.
        guard !ToolSearch.tokenize(query).isEmpty else {
            throw LogicianError.invalidArguments(
                "query has no searchable words (letters or digits): '\(query)'"
            )
        }
        let includeSchemas = arguments["schemas"] as? Bool ?? true
        let limit = try findToolRequestedLimit(arguments)

        let registry = toolRegistry()
        // The index is built once per process, not once per call: the corpus
        // is `toolRegistry()`, which is a constant (see
        // `ToolSearch.advertisedSurface` for the measurement that made this a
        // cache rather than a rebuild).
        let index = ToolSearch.advertisedSurface
        let position = Dictionary(uniqueKeysWithValues: registry.enumerated().map { ($1.name, $0) })
        let ranked = index.ranking(for: query)
        let score = Dictionary(uniqueKeysWithValues: ranked.map { ($0.document, $0.score) })

        // Exact names first, then the keyword ranking with those removed:
        // an agent that typed a name has already made its choice, and BM25 is
        // not reliably able to honour it (see `ToolSearch.exactNames`).
        var order = ToolSearch.exactNames(in: query, registry: Set(position.keys))
            .compactMap { position[$0] }
        let named = Set(order)
        order += ranked.map(\.document).filter { !named.contains($0) }

        let matches = order.prefix(limit).map { document in
            findToolMatch(
                registry[document],
                score: score[document] ?? 0,
                byName: named.contains(document),
                schemas: includeSchemas
            )
        }
        var result: [String: Any] = [
            "success": true,
            "state": "searched",
            "query": query,
            "matches": matches,
            "match_count": matches.count,
            "total_matched": order.count,
            "searched_tools": registry.count,
            "active_toolsets": MCPServer.activeToolsets.map(\.rawValue).sorted()
        ]
        if matches.isEmpty {
            // Not an error: a search that matched nothing ran perfectly. What
            // it owes the caller is the reason and a better second attempt.
            result["note"] = "No tool shares a word with that query. This is a KEYWORD search, "
                + "not a semantic one: name the thing (a Logic noun like 'region', 'send', "
                + "'marker', 'tempo', or a verb like 'bounce', 'quantize', 'freeze') rather than "
                + "describing the outcome. The six groups the surface is built from - core, "
                + "regions, composition, delivery, project, keycommands - are described in the "
                + "server instructions and are the coarse map to search inside."
        }
        return result
    }

    /// One hit. The FULL typed definition by default, because the point of
    /// searching is to be able to CALL what you found without a second round
    /// trip — this tool finds tools, it does not run them.
    private func findToolMatch(
        _ tool: Tool, score: Double, byName: Bool, schemas: Bool
    ) -> [String: Any] {
        let sets = Toolset.membership[tool.name]?.map(\.rawValue).sorted() ?? []
        var match: [String: Any] = [
            "name": tool.name,
            "title": tool.title,
            // The ADVERTISED description, warning note and all: what a client
            // reading tools/list would have seen.
            "description": tool.definition["description"] as? String ?? tool.description,
            "toolsets": sets,
            "active": isActive(tool),
            "score": (score * 100).rounded() / 100,
            "matched_by": byName ? "name" : "keyword"
        ]
        // The same sentence `tools/call` answers with, from the same place, so
        // a hit you cannot call and a call that gets refused cannot disagree
        // about why or about the fix.
        if let excluded = toolsetExclusionNote(name: tool.name) {
            match["not_offered"] = excluded
        }
        if schemas {
            match["inputSchema"] = tool.inputSchema
            match["annotations"] = tool.annotations
        }
        return match
    }

    /// A refusal rather than a silent clamp: an agent that asked for 40 tools
    /// and got 10 would believe it had seen the whole ranking.
    private func findToolRequestedLimit(_ arguments: [String: Any]) throws -> Int {
        let requested = (arguments["limit"] as? Int)
            ?? doubleArgument("limit", in: arguments).map { Int($0.rounded()) }
        guard let requested else { return MCPServer.findToolDefaultLimit }
        guard requested >= 1, requested <= MCPServer.findToolLimit else {
            throw LogicianError.invalidArguments(
                "limit must be 1-\(MCPServer.findToolLimit) (got \(requested));"
                    + " each match carries a full typed schema."
            )
        }
        return requested
    }
}
