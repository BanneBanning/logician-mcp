import Foundation

/// A named slice of the tool surface, so a session can advertise the tools it
/// will actually use instead of all 85.
///
/// WHY THIS EXISTS. A typed per-operation schema is the thing this server has
/// that a dispatcher-style MCP does not: the model sees `start_bar` with its
/// minimum and its exclusivity rule, and the client sees a per-tool
/// `destructiveHint`, instead of one `operation: string` and a prose manual.
/// That is worth paying for — but the whole 84-tool bill arrives before the
/// first call, in every session, whether the user came to mix a chorus or to
/// export stems. Toolsets keep the schemas and drop the tools that were never
/// going to be called: the GitHub MCP server's answer to the same problem.
///
/// The sets mirror what a session is FOR, not which file a handler lives in.
/// A tool may belong to several — `logic_bounce_range` is how you hear a mix
/// decision AND how you deliver a file, so it is in `core` and in `delivery`.
/// The one rule the tests enforce is that every registered tool belongs to at
/// least one set, so no flag combination can hide a tool from every session.
enum Toolset: String, CaseIterable {
    /// What a mixing session touches: readiness, orientation reads, transport,
    /// the strips, the plugins, the tracks they live on, and the renders that
    /// let you HEAR a decision. The set to reach for when narrowing.
    case core
    /// The ARRANGEMENT: its regions (list, select, split, move, copy, rename,
    /// delete, the region inspector's playback parameters), its markers, and
    /// the track lifecycle that shapes it — creating, renaming, duplicating,
    /// deleting and stacking tracks. Named for the regions because that is
    /// what most of it is; a mixing session does none of it.
    case regions
    /// Making new material and new curves: MIDI recording, automation passes
    /// and reads, the tempo map, meters, the Event List editor, and loading
    /// and dialling in the instruments that play the material.
    case composition
    /// Getting audio OUT: stems, bounce-in-place, silence stripping, and the
    /// bounce dialog's delivery options.
    case delivery
    /// Project lifecycle and the episode harness: save/open/new/duplicate/
    /// close, the reset, and the snapshot you diff against.
    case project
    /// Logic's key commands — the onboarding relearn, learning one, listing
    /// them, firing one — plus the raw control-surface escape hatch.
    case keycommands

    /// The name that means "every set", accepted in the flag and the
    /// environment variable but deliberately NOT a case: it is a wildcard over
    /// the cases, and making it a case would let a tool be assigned to it.
    static let everything = "all"

    static var all: Set<Toolset> { Set(allCases) }

    /// Which sets each tool belongs to. Exhaustive by test
    /// (`ToolsetTests.testEveryRegisteredToolBelongsToASet`): a new tool with
    /// no entry here fails the suite rather than quietly becoming unreachable
    /// under every non-`all` flag.
    static let membership: [String: Set<Toolset>] = [
        // The map, and therefore in EVERY set. A session narrowed to `core` is
        // the session most likely to need a tool it cannot see, and the search
        // covers the whole registry however the flag was set — so leaving it
        // out of any set would remove the one tool that explains the flag.
        "logic_find_tool": Set(Toolset.allCases),

        // Readiness and orientation
        "logic_health": [.core],
        "logic_list_windows": [.core],
        "logic_list_tracks": [.core],
        "logic_track_info": [.core],
        "logic_list_strips": [.core],
        "logic_mixer_snapshot": [.core],
        "logic_mcu_status": [.core],

        // Transport
        "logic_get_transport": [.core],
        "logic_set_playing": [.core],
        "logic_set_playhead": [.core],
        "logic_set_cycle": [.core],
        "logic_set_cycle_range": [.core],
        "logic_set_metronome": [.core],

        // Reaching a track (core) versus changing which tracks there are
        // (the arrangement). Routing stays in core: "send the drums to a bus"
        // is a mixing move, and it is the one that MAKES the aux.
        "logic_select_track": [.core, .regions],
        "logic_set_track_routing": [.core],
        "logic_create_track": [.regions],
        "logic_rename_track": [.regions],
        "logic_duplicate_track": [.regions],
        "logic_delete_track": [.regions],
        "logic_set_track_stack": [.regions],

        // The strips
        "logic_set_track_mix": [.core],
        "logic_set_track_record_arm": [.core, .composition],
        "logic_set_mixer": [.core],
        "logic_add_send": [.core],
        "logic_remove_send": [.core],
        "logic_mcu_sends": [.core],
        "logic_mcu_set_send": [.core],

        // Plugins and instruments
        "logic_list_inserts": [.core],
        "logic_survey_plugins": [.core],
        "logic_add_plugin": [.core],
        "logic_remove_plugin": [.core],
        "logic_open_plugin": [.core],
        "logic_close_plugin": [.core],
        "logic_close_plugin_window": [.core],
        "logic_list_plugin_parameters": [.core],
        "logic_set_plugin_parameter": [.core],
        "logic_set_insert_bypass": [.core],
        "logic_plugin_preset": [.core],
        // Instruments are what the notes are PLAYED on, not what the mix is
        // made of: choosing and dialling one belongs to writing the part.
        "logic_load_instrument": [.composition],
        "logic_mcu_instrument_parameters": [.composition],
        "logic_mcu_set_instrument_parameter": [.composition],

        // Hearing the result
        "logic_bounce_range": [.core, .delivery],
        "logic_render_track": [.core, .delivery],
        "logic_evaluate_change": [.core],
        "logic_get_audio_clip": [.core, .delivery],

        // Regions and markers
        "logic_list_regions": [.regions],
        "logic_select_regions": [.regions],
        "logic_split_region": [.regions],
        "logic_move_region": [.regions],
        "logic_copy_region": [.regions],
        "logic_rename_region": [.regions],
        "logic_delete_region": [.regions],
        "logic_get_region_params": [.regions],
        "logic_set_region_params": [.regions],
        "logic_markers": [.regions, .composition],

        // Composition: new material, new curves, the musical grid
        "logic_record_midi": [.composition],
        // Composition ONLY, deliberately, even though it is one of the
        // strongest tools here: it creates tracks and regions out of nothing,
        // which is writing material, not mixing one. A `core` session that
        // wants it finds it through logic_find_tool, which is in every set.
        "logic_import_midi": [.composition],
        "logic_record_automation": [.composition],
        "logic_read_automation": [.composition],
        "logic_remove_automation": [.composition],
        "logic_list_events": [.composition],
        "logic_edit_event": [.composition],
        "logic_set_tempo": [.composition],
        "logic_tempo_events": [.composition],
        "logic_list_signatures": [.composition],

        // Delivery
        "logic_export_stems": [.delivery],
        "logic_bounce_in_place": [.delivery],
        "logic_remove_silence": [.delivery],

        // Project lifecycle
        "logic_save_project": [.project],
        "logic_new_project": [.project],
        "logic_open_project": [.project],
        "logic_duplicate_project": [.project],
        "logic_close_project": [.project],
        "logic_reset_to": [.project],
        "logic_project_snapshot": [.project],

        // Key commands and the raw surface
        "logic_setup_key_commands": [.core, .keycommands],
        "logic_learn_key_command": [.keycommands],
        "logic_list_key_commands": [.keycommands],
        "logic_trigger_key_command": [.keycommands],
        "logic_mcu_command": [.keycommands]
    ]
}

extension MCPServer {
    /// The name of the launch flag and of the environment variable, in one
    /// place so the hint an unknown-tool error prints cannot drift from what
    /// `configureToolsets` actually parses.
    static let toolsetsFlag = "--toolsets"
    static let toolsetsEnvironmentVariable = "LOGICIAN_TOOLSETS"

    /// The sets this process advertises. Read on every `tools/list` and every
    /// `tools/call`, written once at launch.
    ///
    /// DEFAULT: everything. Narrowing the default is a PRODUCT decision (it
    /// changes what an existing user's client can call after an upgrade, with
    /// no error they asked for), so it is deliberately not made here — but it
    /// is one line when it is made: change this initial value.
    nonisolated(unsafe) static var activeToolsets: Set<Toolset> = Toolset.all

    /// Whether the surface is narrowed at all. `tools/call` only spends a
    /// sentence explaining the flag when the flag is the reason.
    static var toolsetsAreNarrowed: Bool { activeToolsets != Toolset.all }

    /// The one launch hook: reads `--toolsets=<comma list>` and, failing that,
    /// `LOGICIAN_TOOLSETS`. Deliberately the whole of main.swift's involvement.
    ///
    /// An unrecognised name is a typo, not a reason to serve a surprising
    /// surface: it is named on stderr with the real list, and ignored. A value
    /// that names NOTHING recognisable leaves the default alone rather than
    /// serving an empty tool list, because a client that got zero tools has no
    /// way to ask why.
    static func configureToolsets(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: (String) -> Void = { FileHandle.standardError.write(Data("[logician] \($0)\n".utf8)) }
    ) {
        let flagged = arguments
            .first { $0.hasPrefix(toolsetsFlag + "=") }?
            .dropFirst(toolsetsFlag.count + 1)
            .description
        guard let raw = flagged ?? environment[toolsetsEnvironmentVariable] else { return }
        let source = flagged == nil ? toolsetsEnvironmentVariable : toolsetsFlag
        var requested: Set<Toolset> = []
        var unknown: [String] = []
        for piece in raw.split(separator: ",") {
            let name = piece.trimmingCharacters(in: .whitespaces).lowercased()
            if name.isEmpty { continue }
            if name == Toolset.everything {
                requested.formUnion(Toolset.all)
            } else if let set = Toolset(rawValue: name) {
                requested.insert(set)
            } else {
                unknown.append(name)
            }
        }
        if !unknown.isEmpty {
            log("\(source): ignoring unknown toolset(s) \(unknown.joined(separator: ", "))."
                + " Known: \(Toolset.everything), "
                + Toolset.allCases.map(\.rawValue).sorted().joined(separator: ", "))
        }
        guard !requested.isEmpty else {
            log("\(source) named no known toolset; serving all of them")
            return
        }
        activeToolsets = requested
        log("toolsets: " + requested.map(\.rawValue).sorted().joined(separator: ", "))
    }

    /// True when this tool is in an active set. A tool with no membership entry
    /// stays VISIBLE: the test forbids that state, and an unclassified tool
    /// disappearing silently would be a worse failure than an over-broad list.
    func isActive(_ tool: Tool) -> Bool {
        guard let sets = Toolset.membership[tool.name] else { return true }
        return !sets.isDisjoint(with: MCPServer.activeToolsets)
    }

    /// The registry filtered to the active sets — what `tools/list` shows and
    /// what `tools/call` will dispatch. `toolRegistry()` itself stays complete
    /// on purpose: the flag decides what is OFFERED, never what exists.
    func activeTools() -> [Tool] {
        toolRegistry().filter(isActive)
    }
}
