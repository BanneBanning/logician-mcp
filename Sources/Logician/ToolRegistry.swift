import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCPServer {
    /// THE list. `tools/list` renders it and `tools/call` dispatches
    /// through it, so a tool cannot exist in one and be missing from the
    /// other, and the listen_note guard reads the flags declared here
    /// instead of a hand-maintained set of names.
    ///
    /// Built once per process, not once per caller — see `wholeRegistry`.
    func toolRegistry() -> [Tool] { MCPServer.wholeRegistry }

    /// The registry, constructed ONCE.
    ///
    /// It is an array literal over string literals: nothing in it reads a
    /// runtime value, and `--toolsets` filters what is OFFERED without
    /// touching what exists, so every construction after the first produces
    /// the same 84 values as the first. It was doing exactly that — measured
    /// 2026-09-01, a `logic_find_tool` call built the whole thing 3 times plus
    /// once per match (13 constructions at `limit: 10`, 1.7 ms) because
    /// `toolsetExclusionNote` asked it "is this a real tool" per hit.
    ///
    /// `nonisolated(unsafe)` because `Tool` carries `[String: Any]` schemas
    /// and a handler function and so cannot be `Sendable`: the value is
    /// written once by this initialiser (`static let` is lazy, once-only and
    /// thread-safe) and only ever read afterwards, from the stdin thread and
    /// the executor thread alike.
    nonisolated(unsafe) static let wholeRegistry: [Tool] = buildToolRegistry()

    /// How many times `buildToolRegistry` has run. Always 1 in a process that
    /// has touched the registry at all; `ToolSearchTests` asserts it, which is
    /// how "built once, however many tools a search returns" stays pinned
    /// without a benchmark in the suite.
    nonisolated(unsafe) private(set) static var toolRegistryBuilds = 0

    /// The literal itself. Call `wholeRegistry` (or `toolRegistry()`); this is
    /// only its initialiser.
    private static func buildToolRegistry() -> [Tool] {
        toolRegistryBuilds += 1
        return [
            // First because it is the MAP. A client that defers definitions,
            // caps the list, or was launched with --toolsets=core sees a set
            // of names and nothing else; this is the one that turns a name
            // back into a schema, and the one that finds the name.
            Tool(
                name: "logic_find_tool",
                title: "Find a tool",
                description: "Search every tool this server has by keyword and get the matching typed definitions back: name, description, full input schema and safety annotations. Use it when you know what you want to do but not which tool does it, or when a tool you expected is not being offered. The search covers the whole registry even when `--toolsets` narrows a session, and each match says which toolsets hold it and whether it is active here.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "What you are trying to do, in the technical words a tool's own text would use. Ranked by keyword relevance (BM25) over names, descriptions and argument text - literal words, not meaning, so spell out the thing you want rather than describing it. An exact tool name is answered with that tool first."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "How many matches to return. Default 5, maximum 10.",
                            "minimum": 1,
                            "maximum": 10
                        ],
                        "schemas": [
                            "type": "boolean",
                            "description": "Include each match's full input schema and annotations. Default true; false returns a cheap shortlist of names, titles and descriptions."
                        ]
                    ],
                    "required": ["query"],
                    "additionalProperties": false
                ],
                // Reads a constant. The only tool here that never reaches
                // Logic Pro at all - it works with the app closed.
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleFindTool
            ),
            Tool(
                name: "logic_health",
                title: "Check readiness",
                description: "Check that Logic Pro is ready and set up, without changing anything: the process, the open project, Accessibility trust, the MCU bridge daemon (started here when it is down), the registered key commands, and Logic's UI LANGUAGE. Read-only, and it names the fix for whatever is missing. `logic_ui_language` is an INFERENCE (Logic's app bundle's localizations matched against the language order that applies to it - macOS cannot be asked what a running app is drawing in) and it says so; when it is not English the result also carries a top-level `language_note` naming exactly which planes degrade - the Accessibility plane matches some of Logic's own English words, while the control-surface plane speaks MIDI and is unaffected.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                // Starts the server's own bridge daemon if it is down; Logic
                // itself is only read.
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleHealth
            ),
            Tool(
                name: "logic_list_windows",
                title: "List Logic windows",
                description: "List Logic windows with subrole and project document path, read-only. Windows whose document is set are project windows; dialogs without a document are plugin or auxiliary windows. Each entry also reports `default_button` and `cancel_button` - the titles of whatever the window publishes as its Return and Escape buttons. Those are LOCALE-INDEPENDENT addresses (this server presses them before it ever matches an English button title), and `null` means the window publishes none, so answering it needs the title.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleListWindows
            ),
            Tool(
                name: "logic_list_tracks",
                title: "List tracks",
                description: "List the track headers currently rendered in the Tracks area (track number, name, selected), read-only. THIS LIST CAN BE INCOMPLETE AND SAYS SO: Accessibility publishes only the rows Logic has rendered, so the result carries `partial` (true when rows are PROVABLY missing), `partial_evidence` (one sentence per signal: headers scrolled out above, gaps in the numbering, collapsed track stacks, a scrollable Tracks area), `missing_track_numbers` where the numbering names them, and `completeness` ('partial' or 'unknown'). There is no 'complete' verdict, because a row Logic has not rendered publishes nothing at all - `partial: false` means nothing proved any missing, never that this is every track. Do not build a mental model of the project on this alone. Output/aux/bus strips (Stereo Out, Master, Aux 1, buses) have no track header and are NEVER listed here, yet the mixing, send and plugin tools accept their names.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleListTracks
            ),
            Tool(
                name: "logic_track_info",
                title: "Read a track's full state",
                description: "What each track IS, beyond its name: type, output routing, input, group, monitoring, automation mode, instrument, inserts and sends — everything Logic's track header and inspector channel strip publish. This is the orientation read logic_list_tracks cannot give you: it answers 'is this an audio track or a software instrument', 'where does it go', 'is anything already grouped', 'what is on it' before you plan a single write. IT IS ALSO THE CHEAP SINGLE-TRACK MIX READ: each strip's current volume_db, pan, mute, solo and record_armed come back with it, so one track's fader state costs one call instead of logic_mixer_snapshot's two bank walks. COSTS A SELECTION, ~0.7 s per track: Logic's left inspector shows the SELECTED track's strip and nothing else, so each track is selected in turn and the original selection is put back (selection_restored says whether it worked). Pass track_name for one, track_names for several, or all: true for every rendered header (mind logic_list_tracks' partiality — a track Logic has not rendered cannot be read here either). THREE THINGS THE RESULT MEANS. A field that is ABSENT (null) means Logic published nothing for it — never that it is off; `input: null` on a software instrument is a strip with no input slot, not an unrouted track. `kind` is INFERRED from which slots the strip publishes and `kind_evidence` says which: 'audio' (an Input slot), 'software_instrument' (a MIDI Effect slot), 'reduced' (no Output slot at all — measured on folder-stack main tracks, which publish only name/mute/solo/volume/automation/group), 'unknown'. And on a software instrument the INSTRUMENT slot carries the same bypass/open controls as an insert, so it appears in `inserts` too, flagged `is_instrument_slot` and named separately as `instrument`. Output/aux/bus strips (Stereo Out, Master, Aux 1) have no track header and cannot be read here; use logic_list_inserts route 'mcu' and logic_mixer_snapshot for those.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "One track, by its exact header name. Omit everything to read whichever track is selected."],
                        "track_names": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Several tracks, read in the order given."
                        ],
                        "all": ["type": "boolean", "description": "Read every rendered track header. ~0.7 s each."]
                    ],
                    "additionalProperties": false
                ],
                // Selects each track it reads, and puts the selection back.
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleTrackInfo
            ),
            Tool(
                name: "logic_set_track_routing",
                title: "Route a track",
                description: "Route a track: its OUTPUT (where the strip's signal goes), its INPUT (what an audio track records from) and its GROUP. Each is one of Logic's own channel-strip slots, written by opening the slot's pop-up menu and pressing the destination, then verified by reading the slot's label back — the same compare-and-set contract as every other write here. This is how 'group the drums to a bus' is done: set each drum track's output to 'Bus 4' and Logic creates the aux; the send tools (logic_add_send) are the parallel path, not the same one. DESTINATION NAMES are Logic's own menu titles, and Logic decorates them with where they already lead — 'Bus 2 → Aux 2' on the output side, 'Bus 2 ← Lofi Pad' on the input side. Pass either form: the HEAD ('Bus 2') is the identity and the arrow half is Logic explaining itself. Other output values: 'Stereo Output', 'No Output', 'Surround', 'Mono'. Inputs: 'Input 1', 'No Input', a bus. Groups: 'No Group', 'Group 1', or the '(new)' item Logic offers to create one. A name that matches nothing is REFUSED with the slot's actual menu listed rather than guessed at. REFUSED, on purpose: a slot this strip does not publish (a software instrument has no input slot; a folder-stack main track publishes a reduced strip with no routing slots at all — logic_track_info's `kind` and `kind_evidence` say which you have), and any mismatch against expected_current, checked for EVERY named slot before the first one is written so a two-slot call cannot half-apply. Changing an output CHANGES WHAT YOU HEAR and can silence a track (route it to a bus with no aux behind it); the before value is always reported so it can be set straight back. Two live-measured caveats. Routing to a BUS makes Logic CREATE the aux behind it, and routing away again does not remove that aux — the result says so in side_effect_note. And the press that opens a slot's menu is INTERMITTENT: Logic sometimes answers it with 'success' and opens nothing, so this retries (five times, clearing Logic's pending UI state with an Escape between attempts) and, if the menu still refuses, fails with 'the routing slot's menu did not open' having written NOTHING. That failure is safe to retry. The output slot was the reliable one in testing; the input and group slots hit it more often.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Exact track name as shown in the track header."],
                        "output": ["type": "string", "description": "Output destination, e.g. 'Stereo Output', 'Bus 4', 'Bus 2 → Aux 2', 'No Output'."],
                        "input": ["type": "string", "description": "Input source, e.g. 'Input 1', 'No Input', 'Bus 5'. Audio strips only."],
                        "group": ["type": "string", "description": "Group membership, e.g. 'No Group', 'Group 1'."],
                        "expected_current": [
                            "type": "object",
                            "description": "Compare-and-set: 'output', 'input' and/or 'group' with the values you believe are current (as logic_track_info reports them). Any mismatch refuses and writes nothing.",
                            "additionalProperties": true
                        ]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleSetTrackRouting
            ),
            Tool(
                name: "logic_list_inserts",
                title: "List insert slots",
                description: "List a strip's audio-effect insert slots (plugin display name, and bypass state on the Accessibility route). ONE tool, TWO routes, and `route_used` says which ran — with it the numbering the result carries. Route 'ax' reads the left inspector's channel strip and numbers the OCCUPIED slots as `index`, the insert_index logic_open_plugin / logic_close_plugin / logic_remove_plugin / logic_set_insert_bypass take; it needs the strip shown in an inspector. Route 'mcu' walks the control surface's plugin list and numbers the PHYSICAL slots 1-8 as `slot`, the insert_slot every logic_mcu_* tool takes; it reaches every strip and every plugin, custom-UI third-party included, and it selects the strip first. Default 'auto' tries ax and falls back to mcu when the inspector cannot reach the strip. The two numberings are DIFFERENT and were observed reversed on an output strip — read `route_used`, use the number it gave you, and never convert one into the other."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Exact track name as shown in the track header, or a headerless strip name ('Stereo Out', 'Aux 1', a bus) on the mcu route."],
                        "track_number": ["type": "integer", "description": "Tracks only; disambiguates two headers sharing a name."],
                        "route": [
                            "type": "string",
                            "enum": ["auto", "ax", "mcu"],
                            "description": "Which plane to read. 'auto' (default) reads Accessibility and falls back to the control surface. 'ax' returns insert_index and refuses rather than falling back. 'mcu' returns the Mackie insert_slot and always works."
                        ]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                // Not read-only in general: the mcu route SELECTS the strip and
                // moves the surface into the plugin list. The ax route changes
                // nothing, but one tool gets one annotation, and over-claiming
                // read-only on a tool that can select a track is the wrong way
                // to be wrong.
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleListInserts
            ),
            Tool(
                name: "logic_bounce_range",
                title: "Bounce a bar range",
                description: "Offline-bounce a bar range of the master output to an audio file and listen to the mix, many times faster than realtime playback. Drives Logic's bounce dialog and its XPC save panel entirely through verified accessibility (no playback). Switches the bounce destination to Uncompressed. DELIVERY OPTIONS: file_type, bit_depth, sample_rate, dithering and normalize drive the dialog's own pop-ups (values are matched leniently - '48k', '48000' and '48 kHz' all reach '48 kHz' - and an unknown one is refused with the real list BEFORE anything is bounced), and include_audio_tail drives its checkbox. Whatever is not passed is left exactly as the user set it, and the result reports the full delivery state in `delivered_as`, read off the dialog just before OK. These are the USER'S OWN settings and Logic keeps them for the next bounce: they are changed, not borrowed, and nothing puts them back — `options_changed` says what moved. MP3 and M4A destinations exist in the dialog with their own option set and are NOT implemented here. ONE CONSEQUENCE OF CHANGING file_type: the metrics reader parses AIFF/AIFC only, so a WAVE or CAF bounce comes back with no `metrics` and therefore WITHOUT the silent-bounce warning — keep the default AIFF when you intend to judge the file by its numbers, and switch format only for the delivery itself. Returns the file path.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "start_bar": ["type": "integer", "minimum": 1, "description": "First bar of the bounced range, 1-based (bar 1 = project start)."],
                        "end_bar": ["type": "integer", "minimum": 2, "description": "Exclusive: the range ends where this bar begins, so start_bar 5 / end_bar 9 bounces bars 5-8. Must be greater than start_bar."],
                        "label": ["type": "string", "description": "Filename label, e.g. 'A' or 'baseline'."],
                        "file_type": ["type": "string", "description": "AIFF, WAVE or CAF. Default: whatever the dialog is set to."],
                        "bit_depth": ["type": "string", "description": "8-bit, 16-bit, 24-bit or 32-bit float."],
                        "sample_rate": [
                            "type": ["string", "number"],
                            "description": "44.1 kHz, 48 kHz, 88.2 kHz, 96 kHz, 176.4 kHz, 192 kHz, or the lower rates (11.025/12/22.05/24/32 kHz). A number in Hz (48000) works too."
                        ],
                        "dithering": ["type": "string", "description": "None, POW-r #1 (Dithering), POW-r #2 (Noise Shaping), POW-r #3 (Noise Shaping) or UV22HR. Only meaningful when reducing bit depth."],
                        "normalize": ["type": "string", "description": "Off, Overload Protection Only, or On. 'On' changes the level of the delivered file - say so when you report the result."],
                        "include_audio_tail": ["type": "boolean", "description": "Let reverb/delay tails ring past the end bar into the file."],
                        "expected_project_path": ["type": "string"],
                        "include_audio": MCPServer.includeAudioProperty,
                        "blind": MCPServer.blindProperty
                    ],
                    "required": ["start_bar", "end_bar"],
                    "additionalProperties": false
                ],
                // Not read-only: drives the bounce dialog and swaps the
                // destination setting.
                safety: .write,
                mayWarn: true,
                handler: MCPServer.handleBounceRange
            ),
            Tool(
                name: "logic_bounce_in_place",
                title: "Bounce a track in place",
                description: "PRINT a region (or a whole track) back INTO the project as audio — the resampling verb. This is the one logic_render_track is not: render_track writes a file to DISK, this creates a new audio REGION in the arrangement that you can then chop, reverse, load into a sampler or bounce again. Drives 'File > Bounce > Regions in Place…' (scope 'region', the default) or 'Tracks in Place…' (scope 'track') and answers the sheet. Every sheet control is left exactly as the user set it unless you pass the matching argument, and the result reports the whole sheet state it used. ONE THING TO WATCH: 'Bypass Effect Plug-ins' is a real Logic setting that may be ON, which makes the print DRY — the result warns when it was, and bypass_effect_plugins: false is how you print the sound as you hear it. Verified against the arrangement map: a region that was not there before, with its track and bars reported - and the muted SOURCE is not mistaken for it (Logic renames a muted region, which the first live run reported as the print). UNDO IS NOT A FULL CLEANUP: it removes the printed region and restores the source, but every print also writes an audio FILE into the project's Media/Audio Files and that file STAYS - nine fully-undone runs left 16 files / ~68 MB behind. The result names it in `printed_file` (found by diffing the folder around the print, so the suffix Logic adds to a taken name is reported rather than guessed); delete it yourself if the print was a mistake. The sheet is modal and is always cancelled on any failure path.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "scope": ["type": "string", "enum": ["region", "track"], "description": "'region' (default) prints the named region; 'track' prints the whole selected track."],
                        "track_name": ["type": "string", "description": "The region's track (required for scope 'region'); the track to print for scope 'track'."],
                        "region_name": ["type": "string"],
                        "start_bar": ["type": "integer", "description": "The region's current start bar."],
                        "name": ["type": "string", "description": "Name for the printed region/file. Logic's default is '<region>_bip'."],
                        "destination": ["type": "string", "enum": ["new_track", "selected_track"], "description": "Where the printed audio lands."],
                        "source": ["type": "string", "enum": ["mute", "leave", "delete"], "description": "What happens to the source region: muted (Logic's default), left playing, or deleted."],
                        "normalize": ["type": "string", "description": "Off, Overload Protection Only, or On."],
                        "bypass_effect_plugins": ["type": "boolean", "description": "true prints DRY (inserts not rendered). Pass false to print with the track's plugins."],
                        "include_volume_pan_automation": ["type": "boolean"],
                        "include_audio_tail_in_region": ["type": "boolean", "description": "Let the tail extend the printed REGION."],
                        "include_audio_tail_in_file": ["type": "boolean", "description": "Let the tail into the FILE even when the region stops earlier."],
                        "bounce_second_loop_pass": ["type": "boolean"],
                        "include_instrument_multi_outputs": ["type": "boolean"]
                    ],
                    "additionalProperties": false
                ],
                // Destructive: with source 'delete' the original region goes,
                // and even 'mute' changes what the project sounds like. Not
                // idempotent - a repeat prints another copy.
                safety: .destructive,
                mayWarn: true,
                changesArrangement: true,
                handler: MCPServer.handleBounceInPlace
            ),
            Tool(
                name: "logic_export_stems",
                title: "Export stems",
                description: "Export ALIGNED STEMS: one offline bounce per named track over the SAME bar range, each with only that track soloed, solo restored after every one. The shared range contract is what makes these stems rather than a loop of renders, and the tool verifies it - the frame counts of the files are compared and 'aligned' says whether they really line up. WHAT A STEM CONTAINS: the full master output heard one track at a time - post-fader, post-pan, post-insert, WITH the return of anything that track sends to a bus, and with the master chain applied. Two consequences it will report but you must plan around: summing the stems reproduces the mix only while the master chain is linear (a master limiter reacts to the whole mix and cannot react to one stem), and a bus fed by several of these tracks is counted once per stem. logic_render_track is the OTHER kind of file - a pre-fader freeze of the track alone, no sends, no master chain - and it is not a stem. Refuses before the first render when any track is already soloed - ANYWHERE in the project, not just among the track headers Logic has rendered: the control surface's project-wide solo indicator is asked as well, so a solo on a hidden row or inside a collapsed track stack is caught by name-what-it-can and refused rather than baked silently into every stem. That indicator is also the only thing that clears `verified`: if it cannot be read, the stems still render and `verified` comes back false with the reason, because 'no rendered header is soloed' has never been proof that none is. Costs one full offline bounce plus about a quarter-second of solo toggling per track (~2.0 s per stem measured, 6.1 s for three); the limit is 16 per call. No audio is attached - the result carries paths. Alignment is measured from the files' frame counts, which the metrics reader gets from AIFF/AIFC only: if the bounce dialog's File Type has been switched to WAVE or CAF (logic_bounce_range can do that), the stems still render but `aligned` comes back false with 'UNVERIFIED' in the note rather than a claim.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "tracks": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Track names, exactly as logic_list_tracks reports them. Duplicates are refused."
                        ],
                        "start_bar": ["type": "integer", "minimum": 1],
                        "end_bar": ["type": "integer", "minimum": 2, "description": "Exclusive: the range ends where this bar begins. Must be greater than start_bar."],
                        "label": ["type": "string", "description": "Filename prefix for the set, e.g. 'cue7'. The track name is appended per stem."],
                        "expected_project_path": ["type": "string", "description": "Refuse unless this is the open project."]
                    ],
                    "required": ["tracks", "start_bar", "end_bar"],
                    "additionalProperties": false
                ],
                // Writes files and toggles solo on every named track (restored
                // after each). Idempotent in effect: a repeat produces another
                // timestamped set and leaves the project as it found it.
                safety: .write,
                mayWarn: true,
                handler: MCPServer.handleExportStems
            ),
            Tool(
                name: "logic_evaluate_change",
                title: "A/B a change by ear",
                description: "A/B A CHANGE AND HEAR BOTH VERSIONS: one complete closed-loop mix evaluation around exactly one verified plugin-parameter change, on a bar range - this is the tool for 'is this better?', and it returns the two renders as audio you can listen to. Takes 30-50 s. Three methods: 'render' (two dialog-free freeze renders of the SINGLE track, compared on the sliced bar range — fastest and most isolated; needs insert_slot, the MCU physical slot, and works for all plugins including third-party), 'bounce' (two offline MASTER renders via the bounce dialog, needs plugin_name), and 'solo_bounce' (two offline bounces with this track soloed, solo restored after; needs insert_slot like 'render' — use for tracks freeze refuses: stack subtracks and tracks sharing a channel strip. A track that was ALREADY soloed elsewhere is not refused, because the deltas stay honest when both bounces carry it, but the result WARNS and `solo_context` names it: the audio you hear is then not this track alone. A solo this tool could not switch off again warns too). All methods roll the change back by default, return baseline/after audio paths, metrics and dB deltas, and CARRY both versions as audio content blocks. TEMPO: method 'render' cuts its two slices itself, so it first reads the project's tempo map out of Logic's Tempo List (View > List Editors > Tempo; ~2 s, no playhead movement, cached per project) and INTEGRATES it — exact for step tempo changes, and the result reports the map in tempo_map. Only when the Tempo List cannot be read does it fall back to sampling the tempo at both ends of the range (parking the playhead) and REFUSE with precondition_failed if the readings differ, naming 'bounce'/'solo_bounce' as the tempo-accurate alternatives; those two hand Logic the bar numbers and are never sampled or refused. MASTER CHAIN: method 'bounce' accepts a strip without a track header ('Stereo Out', an aux, a bus) — it bounces the whole mix, so no track needs selecting; the strip must be visible in an inspector (see logic_list_inserts) because the parameter is written through the plugin WINDOW, which also means the plugin must publish an editable field for it (`ax_writable` in logic_list_plugin_parameters). A knob-only plugin is refused BEFORE the baseline bounce, naming the surface route; the reference project's whole master chain — Channel EQ, Limiter, Sensor — is knob-only, so 'bounce' cannot A/B it and only logic_bounce_range plus a separate logic_set_plugin_parameter can. 'render' (freeze) and 'solo_bounce' (solo) are track-only by nature.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer", "description": "Disambiguates duplicate track names (methods 'render' and 'solo_bounce')."],
                        "plugin_name": ["type": "string", "description": "Plugin window title; required for method 'bounce'."],
                        "insert_index": ["type": "integer", "description": "Method 'bounce' only." + Tool.axInsertIndexNote],
                        "insert_slot": ["type": "integer", "minimum": 1, "maximum": 8, "description": "Required for methods 'render' and 'solo_bounce'." + Tool.mcuInsertSlotNote],
                        "parameter": ["type": "string"],
                        "expected_current_value": ["type": "string"],
                        "target_value": ["type": "string"],
                        "start_bar": ["type": "integer", "minimum": 1],
                        "end_bar": ["type": "integer", "minimum": 2, "description": "Exclusive: the range ends where this bar begins. Must be greater than start_bar."],
                        "method": [
                            "type": "string",
                            "enum": ["render", "bounce", "solo_bounce"],
                            "description": "'render' (dialog-free single-track freeze A/B on the sliced bar range), 'bounce' (offline master A/B) or 'solo_bounce' (soloed offline A/B for tracks freeze refuses: stack subtracks, shared-channel tracks). NOTHING READS whether a track is a stack subtrack or shares a channel strip, so choosing between 'render' and 'solo_bounce' is discovered by trying: 'render' refuses in ~2 s naming 'solo_bounce', which costs a call and no state."
                        ],
                        "tempo": ["type": "number", "description": "Override BPM for bar math (method 'render'); default reads the control bar. Only used when the tempo map cannot be read from the Tempo List — a readable map is integrated and this override does not apply to it. Constant METER is still assumed (signature changes are not read)."],
                        "beats_per_bar": ["type": "number", "description": "Override meter for bar math; default reads the control bar's time signature."],
                        "keep_change": ["type": "boolean", "description": "true keeps the change after measuring; default false rolls it back."],
                        "expected_project_path": ["type": "string", "description": "Refuse unless this is the open project."],
                        "include_audio": MCPServer.includeAudioProperty,
                        "blind": MCPServer.blindProperty
                    ],
                    "required": ["track_name", "parameter", "expected_current_value", "target_value", "start_bar", "end_bar", "method"],
                    "additionalProperties": false
                ],
                // Rolls the change back by default; keep_change is an explicit
                // value write.
                safety: .write,
                mayWarn: true,
                changesSound: true,
                listenNote: Tool.evaluateChangeListenNote,
                handler: MCPServer.handleEvaluateChange
            ),
            Tool(
                name: "logic_mcu_instrument_parameters",
                title: "Read instrument parameters",
                description: "Read the INSTRUMENT slot's parameter names and formatted values (all MCU pages) for a track via host automation — reaches software instruments whose UIs expose nothing to Accessibility (Q-Sampler, Trilian, ...). PAGE-CAPPED: `truncated: true` with `pages` and `pages_total` means parameters were left unread - raise max_pages or treat the list as partial, never as the instrument's whole parameter set.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "max_pages": ["type": "integer", "description": "Page cap, default 12 (each uncached page costs ~1.7 s; large instruments have 80+). pages_total and truncated report what was left out."],
                        "track_number": ["type": "integer"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                // Not read-only: selects the track and enters instrument edit
                // mode.
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleMcuInstrumentParameters
            ),
            Tool(
                name: "logic_mcu_set_instrument_parameter",
                title: "Set an instrument parameter",
                description: "Set one INSTRUMENT parameter through host automation (MCU vpot) with LCD echo readback, same converge/step semantics and compare-and-set contract as logic_set_plugin_parameter.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "parameter": ["type": "string"],
                        "target_value": ["type": "string"],
                        "expected_current_value": ["type": "string"],
                        "tolerance": ["type": "number"]
                    ],
                    "required": ["track_name", "parameter", "target_value"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleMcuSetInstrumentParameter
            ),
            Tool(
                name: "logic_mcu_status",
                title: "Read the control surface",
                description: "Read the Mackie Control bridge's mirrored state: LCD text (track names/values as data), fader positions, transport LEDs, timecode display, online status. This is Logic's documented control-surface feedback channel — no UI, no focus, no windows involved. Requires logic-mcu-bridge running and a Mackie Control configured in Logic pointing at the 'Logic MCP MCU' ports.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleMcuStatus
            ),
            Tool(
                name: "logic_mcu_sends",
                title: "List a track's sends",
                description: "List a track's sends as data via the Mackie Control channel send view: slot number, destination bus, level in dB, position (pre/post fader) and status. UI-independent; competitors' MCPs do not expose sends at all."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "expected_project_path": ["type": "string"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                // Not read-only: selects the track and enters the send view.
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleMcuSends
            ),
            Tool(
                name: "logic_mcu_set_send",
                title: "Set a send level",
                description: "Set the LEVEL in dB of a send that ALREADY EXISTS, verified through the MCU LCD echo (compare-and-set with expected_current_value, readback, same discipline as plugin parameters). Only the level vpot is touched — never the destination, and no send is created or removed: to make a new send, use logic_add_send (which can set the level in the same call); to take one out, logic_remove_send. List sends first with logic_mcu_sends."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "send": ["type": "integer", "minimum": 1, "maximum": 8, "description": "Send slot 1-8."],
                        "level_db": ["type": "number", "description": "Target level in dB, e.g. -9.0."],
                        "expected_current_value": ["type": "string", "description": "Abort unless the current LCD value matches (e.g. '-9.0dB' or '-9.0')."],
                        "expected_project_path": ["type": "string"]
                    ],
                    "required": ["track_name", "send", "level_db"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleMcuSetSend
            ),
            Tool(
                name: "logic_record_automation",
                title: "Record an automation curve",
                description: "DESTRUCTIVE: a Latch pass OVERWRITES any automation already written across this range - read what is there first with logic_read_automation, because nothing but Undo puts it back. TAKES REAL WALL-CLOCK TIME (the automated range is played through, twice with verification). Writes an automation curve on a track — volume (absolute fader), pan, a send level (send: 1-8) or ANY plugin parameter (insert_slot + plugin_parameter) — with no mouse and no automation-lane clicking. The value scale follows the parameter: dB for volume/sends, -64..63 for pan, the plugin's own units otherwise. Mechanism: calibrate the control near the working range, switch the track to Latch over the control surface, roll playback placing calibrated moves at each musical moment, return to Read, restore the original value, and verify by REPLAYING the range while sampling Logic's own echo at every point. ramp (default true) interpolates between points. Points need bar >= 2 and carry value (or db for volume). Takes real time (the automated range, twice with verify). TEMPO MAP: each point's moment, the pre-roll bar and the per-point convergence budgets are integrated over the project's tempo map, read out of Logic's Tempo List (~2 s, no playhead movement, cached per project and reported in tempo_map), so a curve across a tempo change lands on the beats asked for; without a readable map it falls back to one msPerBeat from the control bar. The verification is bar-based either way, so it is the proof.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "parameter": [
                            "type": "string",
                            "enum": ["volume", "pan", "send", "plugin"],
                            "description": "What to automate. 'send' also needs send; 'plugin' also needs insert_slot and plugin_parameter. Default 'volume'."
                        ],
                        "send": ["type": "integer", "minimum": 1, "maximum": 8, "description": "Send slot 1-8, required when parameter is 'send'."],
                        "insert_slot": ["type": "integer", "minimum": 1, "maximum": 8, "description": "Required when parameter is 'plugin'." + Tool.mcuInsertSlotNote],
                        "plugin_parameter": ["type": "string", "description": "Parameter name as shown on the MCU, required when parameter is 'plugin'."],
                        "tolerance": ["type": "number", "description": "Accepted deviation per verified point, in the parameter's own units."],
                        "points": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "bar": ["type": "integer", "minimum": 2],
                                    "beat": ["type": "number", "description": "1-based, fractions allowed. Default 1."],
                                    "value": ["type": "number", "description": "Target in the parameter's own units (dB for volume/sends, -64..63 for pan, the plugin's units otherwise)."],
                                    "db": ["type": "number", "description": "Alias for value, kept for volume curves."]
                                ],
                                "required": ["bar"]
                            ]
                        ],
                        "ramp": ["type": "boolean", "description": "Default true: smooth linear ramps between points."],
                        "verify": ["type": "boolean", "description": "Default true: replay the range in Read and sample the echo per point."]
                    ],
                    "required": ["track_name", "points"],
                    "additionalProperties": false
                ],
                // Destructive: a Latch pass OVERWRITES any existing curve across
                // the range.
                safety: .destructive,
                mayWarn: true,
                idempotent: true,
                handler: MCPServer.handleRecordAutomation
            ),
            Tool(
                name: "logic_record_midi",
                title: "Record MIDI",
                description: "TAKES REAL WALL-CLOCK TIME (the music plays through: bars x beats x 60/BPM seconds, roughly doubled with the verification render). THE SIBLING: logic_import_midi writes a whole multi-track arrangement as a Standard MIDI File and lets Logic import it - byte-exact, seconds rather than minutes, and free of the Smart Tempo hazard below - and its `to_track` puts the material on an EXISTING track too, by moving it there after the import; this tool is the one that PERFORMS a part through an existing track's instrument in real time, so the take is audible as it happens. Composes MIDI into the project with ZERO dialogs and no files: notes are streamed in real time over the dedicated 'Logic MCP MIDI In' port while Logic records them onto the selected software-instrument track (playhead parked one bar early; the stream starts on the observed MCU-timecode crossing into start_bar, so count-in settings do not matter). Creates a normal recorded region. By default the result is verified with a dialog-free freeze render of the recorded bars (non-silent metrics prove the notes landed and sound through the instrument). The region can be removed with Undo in Logic. SMART TEMPO GUARD: a project tempo mode of ADAPT (or AUTO, which can resolve to Adapt) makes Logic rewrite the project's TEMPO MAP to follow the recording, so this refuses before arming and names the fix; when the mode cannot be read off the control bar the recording proceeds and the result carries a warning saying it went unverified. TEMPO MAP: note offsets are integrated over the project's tempo map, read out of Logic's Tempo List (View > List Editors > Tempo; ~2 s, no playhead movement, cached per project and reported in tempo_map), so notes land on the grid across a tempo change. When the Tempo List cannot be read, placement falls back to constant-tempo bar math and the tempo is sampled at the take's first and last bar instead (playhead parked, read, restored — once per call, shared with the verification render); differing readings then produce a `warning`. Either way speed > 1 is REFUSED with precondition_failed on a non-constant tempo: speed mode overwrites the tempo slider and restores a single value, which cannot put a tempo map back. Real-time recording (speed 1) touches no tempo and stays available.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Software instrument track to record onto (not a track stack)."],
                        "track_number": ["type": "integer"],
                        "notes": [
                            "type": "array",
                            "description": "The notes to record.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    // A UNION type, not a bare description:
                                    // this property accepts an int or a note
                                    // name, and several function-calling
                                    // backends reject a property schema that
                                    // carries only a description. The numeric
                                    // bounds constrain the integer branch
                                    // only - JSON Schema's minimum/maximum
                                    // ignore a string instance.
                                    "pitch": [
                                        "type": ["integer", "string"],
                                        "minimum": 0,
                                        "maximum": 127,
                                        "description": "MIDI number 0-127 or a name like 'C3' (= MIDI 60, Logic convention), 'F#1', 'Bb2'."
                                    ],
                                    "bar": ["type": "integer", "minimum": 1, "description": "Absolute bar position (1 = project start)."],
                                    "beat": ["type": "number", "description": "Beat within the bar, 1-based; fractions allowed (1.5 = offbeat). Default 1."],
                                    "duration_beats": ["type": "number", "description": "Length in beats. Default 1."],
                                    "velocity": ["type": "integer", "minimum": 1, "maximum": 127, "description": "1-127, default 100."],
                                    "channel": ["type": "integer", "minimum": 1, "maximum": 16, "description": "MIDI channel 1-16, default 1."]
                                ],
                                "required": ["pitch", "bar"]
                            ]
                        ],
                        "cc_events": [
                            "type": "array",
                            "description": "MIDI CC events recorded alongside the notes — e.g. mod-wheel sweeps (cc 1), expression (cc 11). Emit many points for smooth curves.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "bar": ["type": "integer"],
                                    "beat": ["type": "number", "description": "1-based, fractions allowed."],
                                    "cc": ["type": "integer", "minimum": 0, "maximum": 127, "description": "Controller number 0-127."],
                                    "value": ["type": "integer", "minimum": 0, "maximum": 127, "description": "0-127."],
                                    "channel": ["type": "integer", "minimum": 1, "maximum": 16, "description": "1-16, default 1."]
                                ],
                                "required": ["bar", "cc", "value"]
                            ]
                        ],
                        "pitch_bends": [
                            "type": "array",
                            "description": "Pitch-bend events: value -8192..8191 (0 = center). Emit many points for smooth bends, and return to 0 at the end.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "bar": ["type": "integer"],
                                    "beat": ["type": "number"],
                                    "value": ["type": "integer", "minimum": -8192, "maximum": 8191],
                                    "channel": ["type": "integer", "minimum": 1, "maximum": 16]
                                ],
                                "required": ["bar", "value"]
                            ]
                        ],
                        "start_bar": ["type": "integer", "minimum": 2, "description": "Recording start bar (>= 2); default = the earliest event's bar."],
                        "tempo": ["type": "number", "description": "Override BPM; default reads the control bar."],
                        "beats_per_bar": ["type": "number", "description": "Override meter; default reads the control bar."],
                        "verify_render": ["type": "boolean", "description": "Default true: freeze-render the recorded bars afterwards and return slice metrics as proof."],
                        "speed": ["type": "number", "description": "Optional fast mode: record at speed x tempo (1-8, default 1) and scale event times — same bar positions in a fraction of the wall time. Default 1 keeps real-time recording so the take is audible as it happens; higher speeds trade timing precision (jitter scales with speed) and chipmunked monitoring."],
                        "sync_compensation_ms": ["type": "number", "description": "Timecode display latency compensated in the beat-edge sync, default 45 ms (measured). Raise if notes land early, lower if late."],
                        "expected_project_path": ["type": "string"]
                    ],
                    "required": ["track_name", "notes"],
                    "additionalProperties": false
                ],
                // Additive: a new recorded region. Not idempotent - each call
                // records another.
                safety: .write,
                mayWarn: true,
                changesArrangement: true,
                handler: MCPServer.handleRecordMidi
            ),
            Tool(
                name: "logic_import_midi",
                title: "Import a composed arrangement",
                description: "Compose a WHOLE ARRANGEMENT in one call - many named tracks at once - by generating a Standard MIDI File server-side and driving Logic's own File > Import > MIDI File… The file is valid by construction (every value is validated before a byte is written) and nothing is played in real time, so the cost is the DIALOGS, not the music: measured end to end, a single track lands in ~7 s and a 2-track arrangement in ~15 s with note-level verification on, plus up to ~7 s more when the playhead has to travel to `at_bar`. Sixteen bars cost the same as two. THE SIBLING: logic_record_midi plays a part in over the MIDI port in REAL TIME through the track's actual instrument, onto a track that already exists - reach for it when the take should be audible as it happens; this one is byte-exact, fast, multi-track, and reaches an existing track through `to_track` rather than by performing into it. It also SIDESTEPS THE SMART TEMPO HAZARD entirely: there is no recording pass, so an Adapt-mode project has nothing to follow and cannot rewrite its own tempo map. WHERE IT LANDS: Logic imports at the bar line nearest the playhead, so this parks the playhead exactly on `at_bar` first (that park is the expensive step) and then verifies that every new region starts there. COMPOSE ONTO YOUR OWN TRACKS: give a `tracks[]` entry a `to_track` and that part ends up on the EXISTING track you name, playing through its instrument - which is the whole point, because Logic's own importer can only ever make new tracks with default patches. Per track, not per call: route drums onto 'Drums' and bass onto 'Bas' in one import and leave the third entry unrouted to keep a new track. It is a composition, and it says so: the import lands on a temp track, the region is moved onto the destination (Cut/Paste, with the same paste verification logic_copy_region uses), and the emptied temp track is deleted - a measured 5.9 s per routed track on top of the import. Destinations are resolved BEFORE the panel opens, so a destination that does not exist, is duplicated without `to_track_number`, or is a headerless output/aux/bus strip (no track lane for a region to sit on) is refused with the project untouched. If a move fails after the import has landed, NOTHING is rolled back - some of the material would already be on your own tracks - and the result is `state: 'partial'`, `restored: false`, with `remaining` naming every temp track and region still in the project. Every event's `bar` is an ABSOLUTE project bar at or after `at_bar`, and bar positions are written against the project's own meter map. NAMES, and this surprises people: for an UNROUTED entry, Logic names the new TRACK after whichever default patch it loads ('Studio Grand', 'Epic Cloud Formation'), NOT after your track name. Your names come back on the REGIONS - which is the only handle the import gives back, and what this tool's verification, its routing and its cleanup all address - so follow up with logic_rename_track when the track names matter. A routed entry sidesteps this entirely: the region ends up on the track you named. THE TEMPO PROMPT: Logic asks 'Also import tempo information?' on EVERY import, before it has even parsed the file, and this tool owns it - answered **No** by default, which leaves the project's tempo map byte-identical (measured). `import_tempo: true` answers 'Import Tempo' instead and is DESTRUCTIVE: it replaces the project's tempo information in the range of the file and desynchronises any previously recorded audio that is not in Flex mode; it requires an explicit `tempo` and discards the cached tempo map. Logic's 'Don't ask again' checkbox is never touched. VERIFICATION is a census: the track count and the region list are diffed against a snapshot taken before the import, and success means the new regions carry your track names and start on `at_bar`. `verify: 'events'` additionally selects each new region and reads its notes back out of the Event List, diffing them note for note against what was written (+~2 s per region). A file Logic cannot read fails SILENTLY - no error dialog, sometimes not even the tempo prompt - so an unchanged census is reported as `success: false` with the counts as evidence, never as an empty success. CLEANUP CONTRACT: no panel, sheet or prompt is ever left standing, and a half-landed import is taken back out one track at a time (`restored` says whether the census came back). An alert whose grammar this server has not measured is REPORTED and never pressed. The generated .mid is left in the captures directory and its path is in the result, so the same arrangement can be re-imported without regenerating it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "tracks": [
                            "type": "array",
                            "description": "The arrangement: one entry per track. Logic creates one new track per entry, in this order.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "name": [
                                        "type": "string",
                                        "description": "Names the REGION Logic creates (not the track - see the description). Must be unique across the call: it is the handle verification and cleanup address by."
                                    ],
                                    "to_track": [
                                        "type": "string",
                                        "description": "COMPOSE ONTO YOUR OWN TRACK: the name of an EXISTING track this part should end up on, so it plays through that track's instrument instead of the default patch Logic picks for a new one. Per track, not per call - route drums onto 'Drums' and bass onto 'Bas' in the same import, and leave it out on any entry that should keep a new track of its own. Costs 5.9 s per routed track (measured back to back against the same import unrouted: 13.8 s vs 7.9 s): the import still lands on a temp track, then the region is moved onto the destination (~2.6 s) and the emptied temp track is deleted (~3.3 s including the re-read census). Destinations are resolved BEFORE anything is imported, so a name that does not exist is refused with the project untouched; an output/aux/bus strip is refused too (a region needs a track lane)."
                                    ],
                                    "to_track_number": [
                                        "type": "integer",
                                        "description": "Disambiguates a duplicated `to_track` name, exactly as track_number does everywhere else. Only meaningful alongside to_track."
                                    ],
                                    "channel": [
                                        "type": "integer", "minimum": 1, "maximum": 16,
                                        "description": "MIDI channel every event on this track uses unless it says otherwise. Default 1. Channels do NOT split a track: the arrangement's shape is one Logic track per entry here, whatever channels the events carry."
                                    ],
                                    "notes": [
                                        "type": "array",
                                        "description": "The notes, in logic_record_midi's vocabulary.",
                                        "items": [
                                            "type": "object",
                                            "properties": [
                                                "pitch": [
                                                    "type": ["integer", "string"],
                                                    "minimum": 0, "maximum": 127,
                                                    "description": "MIDI number 0-127 or a name like 'C3' (= MIDI 60, Logic convention), 'F#1', 'Bb2'."
                                                ],
                                                "bar": ["type": "integer", "minimum": 1, "description": "ABSOLUTE project bar, at or after at_bar."],
                                                "beat": ["type": "number", "description": "Beat within the bar, 1-based; fractions allowed (1.5 = offbeat). Default 1."],
                                                "duration_beats": ["type": "number", "description": "Length in quarter-note beats. Default 1."],
                                                "velocity": ["type": "integer", "minimum": 1, "maximum": 127, "description": "1-127, default 100."],
                                                "channel": ["type": "integer", "minimum": 1, "maximum": 16, "description": "Overrides the track's channel for this note."]
                                            ],
                                            "required": ["pitch", "bar"]
                                        ]
                                    ],
                                    "control_changes": [
                                        "type": "array",
                                        "description": "CC events - mod wheel (1), expression (11), sustain (64). Emit many points for a smooth curve.",
                                        "items": [
                                            "type": "object",
                                            "properties": [
                                                "cc": ["type": "integer", "minimum": 0, "maximum": 127, "description": "Controller number 0-127."],
                                                "value": ["type": "integer", "minimum": 0, "maximum": 127],
                                                "bar": ["type": "integer", "minimum": 1],
                                                "beat": ["type": "number", "description": "1-based, fractions allowed. Default 1."],
                                                "channel": ["type": "integer", "minimum": 1, "maximum": 16]
                                            ],
                                            "required": ["cc", "value", "bar"]
                                        ]
                                    ],
                                    "pitch_bends": [
                                        "type": "array",
                                        "description": "Pitch bends: -8192..8191, 0 = centre. Return to 0 at the end of a bend.",
                                        "items": [
                                            "type": "object",
                                            "properties": [
                                                "value": ["type": "integer", "minimum": -8192, "maximum": 8191],
                                                "bar": ["type": "integer", "minimum": 1],
                                                "beat": ["type": "number"],
                                                "channel": ["type": "integer", "minimum": 1, "maximum": 16]
                                            ],
                                            "required": ["value", "bar"]
                                        ]
                                    ],
                                    "program_changes": [
                                        "type": "array",
                                        "description": "Program changes. `program` is the WIRE number 0-127; Logic's UI counts these from 1.",
                                        "items": [
                                            "type": "object",
                                            "properties": [
                                                "program": ["type": "integer", "minimum": 0, "maximum": 127],
                                                "bar": ["type": "integer", "minimum": 1],
                                                "beat": ["type": "number"],
                                                "channel": ["type": "integer", "minimum": 1, "maximum": 16]
                                            ],
                                            "required": ["program", "bar"]
                                        ]
                                    ]
                                ],
                                "required": ["name"]
                            ]
                        ],
                        "at_bar": [
                            "type": "integer", "minimum": 1,
                            "description": "The bar the arrangement's first bar lands on. Default 1. The playhead is parked exactly here first - up to ~7 s when it has to travel, and the single most expensive step of the call - because Logic imports at the bar line NEAREST the playhead, rounding rather than truncating (beat 3 of a 4/4 bar lands on the NEXT bar). Every event's `bar` must be this bar or later."
                        ],
                        "import_tempo": [
                            "type": "boolean",
                            "description": "DESTRUCTIVE, default false. Answers Logic's tempo prompt with 'Import Tempo' instead of 'No', which REPLACES the project's tempo information in the range of the file and puts previously recorded audio that is not in Flex mode out of sync. Requires `tempo`. Leave it out and the project's tempo map is provably untouched."
                        ],
                        "tempo": [
                            "type": "number",
                            "description": "A BPM written into the file's conductor track. Only ever applied to the project when import_tempo is true - otherwise it just travels with the .mid for a later re-import. No TIME SIGNATURE is ever written: that would be a write to the project's signature track, and this tool has no argument that asks for one."
                        ],
                        "verify": [
                            "type": "string",
                            "enum": ["census", "events"],
                            "description": "'census' (default): prove the import by the track/region diff - fast. 'events': additionally select each new region and diff its notes against what was written, reporting per-track counts and mismatches (+~2 s per region)."
                        ],
                        "expected_project_path": ["type": "string"]
                    ],
                    "required": ["tracks"],
                    "additionalProperties": false
                ],
                // Additive: new tracks, new regions, and one file in the
                // captures directory. Not idempotent - each call imports
                // another copy onto another set of new tracks.
                safety: .write,
                mayWarn: true,
                changesArrangement: true,
                handler: MCPServer.handleImportMIDI
            ),
            Tool(
                name: "logic_plugin_preset",
                title: "Browse plugin settings",
                description: "Browse and load a plugin's settings (presets). action 'list' enumerates the setting menu — every name, its category, and which one is marked as loaded — WITHOUT changing anything; action 'select' loads one by name (bare 'Rock Bass' or qualified '03 Guitars/Rock Bass'), verified against the plugin window's setting label; action 'step' walks next/previous N settings via Logic's topmost-plugin-window key command, the only route that needs no readable menu; action 'undo' presses the setting menu's own Undo, which is the ONLY way back from a load — it restores the parameter state rather than a name, so it also recovers a plugin that was on no named setting at all (measured on a headerless strip: all eight of a Limiter's parameters came back exactly). The plugin window is opened and closed again if this call opened it. Reading the menu needs Logic frontmost for a moment (a menu cannot open in a background app). Honesty contract: 'list' returns presets: null plus a reason when the plugin's UI exposes no Logic setting pop-up (fully custom UIs), and presets: [] — an empty list, not a failure — for plugins that genuinely ship no factory settings; 'step' reports success: false when the label did not move. WARNING: loading a setting overwrites EVERY parameter of the plugin, and a setting name is not a promise about the current state — unnamed tweaks on top of a named setting are lost and re-selecting the old name does not bring them back. Use action 'undo' to get back."
                    // The AX note alone: selection routes through the surface,
                    // but OPENING the plugin window is an Accessibility action
                    // on the strip, so this tool has the STRICTER of the two
                    // limits and saying both would be saying "see STRIP
                    // ADDRESSING" twice in one description.
                    + Tool.stripAddressingAXNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "plugin_name": ["type": "string"],
                        "insert_index": ["type": "integer", "description": "Needed only when the same plugin sits in several slots." + Tool.axInsertIndexNote],
                        "track_number": ["type": "integer"],
                        "action": ["type": "string", "enum": ["list", "select", "step", "undo"], "description": "'list' (read-only enumeration), 'select' (load the setting named by name), 'step' (relative next/previous), 'undo' (the setting menu's own Undo — the way back from a select; repeat to step further back). Default: 'step', or 'select' when name is given."],
                        "name": ["type": "string", "description": "For action 'select': the setting to load, as 'list' reports it. Bare name, or 'Category/Name' when two categories share a name (also accepts 'Category > Name'). Case- and diacritic-insensitive; never fuzzy — a near miss is refused with the available names rather than guessed at."],
                        "direction": ["type": "string", "enum": ["next", "previous"], "description": "For action 'step': 'next' (default) or 'previous'."],
                        "steps": ["type": "integer", "description": "For action 'step': how many settings to step, default 1."]
                    ],
                    "required": ["track_name", "plugin_name"],
                    "additionalProperties": false
                ],
                // Not idempotent as a whole: 'step' advances further each
                // call. ('list' changes nothing and 'select' is idempotent,
                // but the flag describes the tool, and the safe answer for a
                // tool that can write is `write`.)
                safety: .write,
                mayWarn: true,
                handler: MCPServer.handlePluginPreset
            ),
            Tool(
                name: "logic_rename_track",
                title: "Rename a track",
                description: "Rename a track by writing the channel strip's name field (element-addressed AX). Verified against the track headers.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "new_name": ["type": "string"]
                    ],
                    "required": ["track_name", "new_name"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleRenameTrack
            ),
            Tool(
                name: "logic_duplicate_track",
                title: "Duplicate a track",
                description: "Duplicate a track, with its settings and its regions, via Logic's Duplicate Track key command (learned automatically). THE RESULT NAMES THE COPY: `duplicate {track_number, track_name}`, read off the row Logic selects - address the copy by BOTH of those fields. You cannot derive them: the copy lands directly BELOW the source and renumbers every track under it, and Logic gives it either the source's own name (which then matches two rows, and every track tool refuses an ambiguous name) or an auto-incremented one ('Audio 9' duplicates to 'Audio 10', so the name you passed in now belongs to a different track). Verified by a named row appearing rather than by a count, because only rendered track rows can be read: on a project scrolled away from the insertion point the copy may be off-screen, which comes back state 'duplicated_not_visible' with verified:false and a warning to scroll and re-read - it is NOT a claim that nothing happened, and firing again would leave a second copy carrying a second set of the source's regions. To delete the copy afterwards, pass `duplicate`'s track_number AND track_name to logic_delete_track.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                safety: .write,
                handler: MCPServer.handleDuplicateTrack
            ),
            Tool(
                name: "logic_delete_track",
                title: "Delete a track",
                description: "DESTRUCTIVE: delete a track via the Delete Track key command. The selection is re-verified to be the named track immediately before firing, and the result is verified against the track list. Undo restores. A track that still holds REGIONS raises Logic's modal 'Delete Track and Regions?' confirmation: it is detected and answered here (Delete only while the selection still names the requested track, Cancel otherwise, and the alert's own text comes back in `confirmation`), because a modal left standing swallows every key command after it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer", "description": "Recommended for duplicate names."]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                // Destructive, and not idempotent: a repeat deletes the NEXT
                // track of that name.
                safety: .destructive,
                handler: MCPServer.handleDeleteTrack
            ),
            Tool(
                name: "logic_add_send",
                title: "Create a send",
                description: "CREATE a send on a track to a bus/output — this is the tool that makes a send that was not there; to change the LEVEL of one that already exists, use logic_mcu_set_send instead. Mouse-free via the control surface's send-destination browser (first empty slot, browsed to the named destination, settle-verified, confirmed). Destination names as Logic shows them, e.g. 'Bus 1', 'Bus 2'. LEVEL: a new send lands at -oo dB and is INAUDIBLE, so pass level_db to set it in the same call (the same converge-and-read-back write logic_mcu_set_send does, on the strip already selected). Without level_db the send is created silent and the result says so; if the level write fails the send still exists and the result carries a warning naming the follow-up call. TWO VERIFICATIONS, TWO KEYS: top-level `verified` is about the SEND being created, while the level write is reported separately as `level_verified` (with `level`, `level_db_requested` and `level_write_route`) - read that one before assuming the send is audible. REFUSED, on purpose: a FOLDER-STACK main track, whose reduced strip has no send slots at all (logic_track_info reports kind 'reduced') — put the send on the stack's subtracks instead. The way back is logic_remove_send, not Undo."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "destination": ["type": "string", "description": "e.g. 'Bus 3'."],
                        "level_db": ["type": "number", "description": "Set the new send's level to this dB in the same call, e.g. -12.0. Omit to leave it at -oo dB (silent), which then needs a logic_mcu_set_send before the send is audible."]
                    ],
                    "required": ["track_name", "destination"],
                    "additionalProperties": false
                ],
                // Additive: fills the first EMPTY slot; a repeat adds another
                // send.
                safety: .write,
                mayWarn: true,
                handler: MCPServer.handleAddSend
            ),
            Tool(
                name: "logic_remove_send",
                title: "Remove a send",
                description: "REMOVE a send that exists — the counterpart of logic_add_send, and the way a send is taken out without logic_trigger_key_command's blind Undo. Mouse-free via the control surface's send-destination browser: the send list is read FIRST, the slot's destination field is browsed back to the No-Send entry, settle-verified, confirmed, and the send list is read back to prove exactly that one send is gone. ADDRESS the send by slot (send: 1-8 as logic_mcu_sends numbers them), by destination name ('Bus 3'), or both — both is safest, because a slot holding a different destination than you named is REFUSED with the actual send list rather than removed. A destination two sends share, addressed by name alone, is refused too: pass send: to pick one. A send already gone is a verified no-op (state: 'already_removed') and nothing is pressed. AFTER A REMOVAL the remaining sends can renumber (Logic compacts them upward), so slot numbers held from before this call may be stale — the result carries sends_after, re-read from the surface, and renumbered: true when it happened; address the next send from that list."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "send": ["type": "integer", "minimum": 1, "maximum": 8, "description": "Send slot 1-8, as logic_mcu_sends lists them. Optional when destination alone identifies the send."],
                        "destination": ["type": "string", "description": "The send's destination as the send list shows it, e.g. 'Bus 3'. With send: also given it is a guard — the slot must hold this destination or nothing is removed."]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                // Destructive: the send and its level go. Idempotent: the
                // target state is 'absent', and a repeat is an
                // already_removed no-op.
                safety: .destructive,
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleRemoveSend
            ),
            Tool(
                name: "logic_create_track",
                title: "Create a track",
                description: "Create a new track (software_instrument or audio) via Logic's key command, verified by re-reading the track list. THE RESULT NAMES WHAT IT MADE: `created_track {track_number, track_name}`, read off the row Logic selects - pass that track_name straight to the next call instead of diffing two listings or guessing Logic's auto-name. IT DOES NOT LOAD AN INSTRUMENT: a software-instrument track is created EMPTY and makes no sound until one is put in its instrument slot, which is a different mechanism from the insert slots - logic_add_plugin fills the first empty audio-effect INSERT, never the instrument, so 'create a software instrument track' + 'add a plugin' both report success on a silent track. THE SECOND CALL IS logic_load_instrument {track_name: created_track.track_name, instrument}. Only rendered track rows can be counted, so on a project scrolled away from the insertion point the new row may be off-screen: that comes back state 'created_not_visible' with verified:false and a warning to scroll and re-read - it is NOT a claim that nothing happened, and firing again would leave two tracks. A Create New Track dialog is answered if one appears (Logic 12.3.1 raises none for these two commands). The alternative, when a track already carries the instrument you want, is logic_duplicate_track, which copies its settings and its content with it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "type": [
                            "type": "string",
                            "enum": ["software_instrument", "audio"],
                            "description": "'software_instrument' (default) or 'audio'."
                        ]
                    ],
                    "additionalProperties": false
                ],
                safety: .write,
                handler: MCPServer.handleCreateTrack
            ),
            Tool(
                name: "logic_list_regions",
                title: "List regions",
                description: "The arrangement map: every region on every visible track row, with name, start/end bar (and beat when off the barline), type (midi/audio) and selection state — parsed from Logic's own accessibility descriptions. Read-only. Optionally filter to one track. REGIONS HAVE NO STABLE HANDLE: they are addressed by (track_name, region_name, start_bar), and start_bar is exactly what an edit changes - so re-read this map between two edits of the same region instead of reusing the first read's start_bar. Duplicate region names make verification count occurrences rather than identify a region, which is why every edit tool selects exclusively first. Only regions on rendered track rows are listed, with the same caveat as logic_list_tracks. EMPTY IS PROVEN, NOT ASSUMED: a walk that finds no track rows is cross-checked against the track header column, and an arrangement that is unreadable (or visibly holds tracks the walk cannot see - e.g. a non-English Logic UI) is REFUSED with the reason rather than reported as an empty project.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Optional: only this track's regions."]
                    ],
                    "additionalProperties": false
                ],
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleListRegions
            ),
            Tool(
                name: "logic_select_region",
                title: "Select a region",
                description: "Select ONE region (by track + region_name and/or start_bar; ambiguity is refused with candidates listed). exclusive (default true) clears every other region selection first, so a following edit key command (cut/copy/delete/nudge) touches only this region; `deselected` counts what it cleared. exclusive: false ADDS this region to whatever is already selected instead, and PROVES it rather than claiming it: `selected_before` and `selected_count` are counted off the arrangement, and a selection that did not actually GROW comes back with a warning naming what was lost instead of a silent success. Those two counts see VISIBLE track rows only, while the selection itself is project-wide. Verified via the element's selection state either way; a region that is already selected is a verified no-op (state: \"already_selected\") and nothing is written to it, while the other selections are still cleared under exclusive: true. To select MANY regions in one call - a whole track, everything after a point, the whole project - use logic_select_regions (with the s), which fires Logic's own selection commands: adding them one at a time here works, but it is one round trip per region.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "region_name": ["type": "string"],
                        "start_bar": ["type": "integer"],
                        "exclusive": ["type": "boolean", "description": "Default true: clear other selections first. false ADDS this region to the current selection and reports selected_before/selected_count."]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                // Not read-only: changes the project-wide region selection.
                safety: .write,
                mayWarn: true,
                idempotent: true,
                handler: MCPServer.handleSelectRegion
            ),
            Tool(
                name: "logic_delete_region",
                title: "Delete a region",
                description: "DESTRUCTIVE: delete one region. Logic's Delete takes EVERY selected region in the PROJECT, while the arrangement map this server reads holds only the track rows Logic has RENDERED - so exclusivity is established, not assumed. The region is selected exclusively, then Logic's own project-wide 'Deselect All' clears the selection and is PROVEN to have landed (the rendered selection count is watched falling to zero) before the one target region is selected back; the result says `selection_scope: \"project\"` and carries that receipt. When 'Deselect All' is not in the key command registry the tool does not guess: if any track row is provably hidden (scrolled out, or a collapsed stack) it REFUSES before Delete and names those rows and how to reveal them, and if nothing proved a row hidden it goes ahead with `selection_scope: \"rendered_rows\"` and a warning saying exactly that. Logic's Tracks-area keyboard focus is established before Delete goes out - the command acts on the focused area, and fired without it does nothing at all, silently - and a delete that does not take names the focus and Logic's open dialogs rather than just repeating that the region is still there. VERIFICATION: the region total across EVERY rendered row must fall by exactly 1 AND the addressed region must be gone; a wider drop comes back as collateral damage, never as success. Undo restores.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "region_name": ["type": "string"],
                        "start_bar": ["type": "integer"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                // Destructive, and not idempotent: a repeat deletes another
                // region.
                safety: .destructive,
                changesArrangement: true,
                handler: MCPServer.handleDeleteRegion
            ),
            Tool(
                name: "logic_remove_silence",
                title: "Strip silence from a region",
                description: "Cut the silence out of ONE audio region — the first move of every audio-post session, and what other DAWs call strip silence. Logic Pro 12.3.1 has no command by that name: the real one is 'Remove Silence from Audio Region…' and it opens a floating window with a LIVE PREVIEW of how many regions the current settings would leave. That preview is why apply defaults to FALSE: the first call opens the window, reads Logic's own count and the current threshold/time settings, closes it again and changes nothing, so an agent can ask 'what would this do?' before doing it. apply: true presses OK and verifies against the arrangement map (one region becomes N; Undo restores it, and the audio FILE is never touched). Refuses on a MIDI region. NOT IMPLEMENTED: the window's four numeric fields (threshold in dB, minimum silence, pre-attack, post-release) are per-digit steppers and this server does not write them — the result reports their current values, and changing them means touching Logic's window.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "region_name": ["type": "string"],
                        "start_bar": ["type": "integer", "description": "The region's current start bar."],
                        "apply": ["type": "boolean", "description": "false (default) previews and changes nothing; true commits."]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                // Destructive with apply: true (one region becomes many and the
                // gaps go); a pure read otherwise, but the flag describes the
                // tool and the safe answer for a tool that can write is write.
                safety: .destructive,
                mayWarn: true,
                changesArrangement: true,
                handler: MCPServer.handleRemoveSilence
            ),
            Tool(
                name: "logic_select_regions",
                title: "Select several regions",
                description: "Select MANY regions in ONE call — logic_select_region takes one region per call, so a track's worth of them is a round trip each and a rule Logic already knows ('everything after bar 40') cannot be expressed at all. Modes, each one a real Logic command: 'track' (every region on the anchor's track), 'following' (the anchor and everything after it, on EVERY track), 'following_same_track' (the anchor and everything after it on that track only), 'all' (every region in the project), 'none' (clear the selection). The relative modes need an anchor: track_name, plus region_name and/or start_bar when the track holds more than one region — the anchor is selected exclusively first, then the command extends from it. VERIFICATION: the number of selected regions is counted before and after off the arrangement map, and a mode that moved nothing comes back success: false rather than pretending. The count sees VISIBLE track rows only, while the selection itself is project-wide — a following edit acts on every selected region, counted or not. Uses learned key commands (Logic 12.3.1 names: 'Select All Regions/Cells of Same Track', 'Select All Following', 'Select All Following of Same Track/Pitch', 'Select All', 'Deselect All'). THIS CAN WRITE INTO THE USER'S OWN LOGIC: a command missing from the registry is LEARNED on the spot, which adds a MIDI-note assignment to the user's active key command set (additive, removable in Logic's Key Commands window), and the result then carries `learned_key_command`, `learned_note` and a `consent_note` saying exactly that. Say so when you report the result.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "mode": [
                            "type": "string",
                            "enum": ["track", "following", "following_same_track", "all", "none"],
                            "description": "Which selection command to fire."
                        ],
                        "track_name": ["type": "string", "description": "The anchor's track; required for every mode except 'all' and 'none'."],
                        "region_name": ["type": "string", "description": "Which region is the anchor (with start_bar to disambiguate)."],
                        "start_bar": ["type": "integer", "description": "The anchor region's current start bar."]
                    ],
                    "required": ["mode"],
                    "additionalProperties": false
                ],
                // Changes the project-wide region selection, nothing else. The
                // absolute modes are idempotent; the relative ones are too,
                // since they re-anchor every call.
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleSelectRegions
            ),
            Tool(
                name: "logic_split_region",
                title: "Split a region",
                description: "Split ONE region at a bar (and optional beat) - the three-call recipe (select, park the playhead, fire 'Split Regions/Events at Playhead Position') as a single call with one verdict. Three failure modes are named and checked in order, and the first two refuse BEFORE anything is written: (1) the split point is not inside the named region - refused with the region's own bar span, nothing moved; (2) the playhead did not land where it was asked to - this parks the sub-beat fields of the control bar's position display as well, which logic_set_playhead does not, because a 'verified' bar/beat can still sit almost a whole beat late and for a split that is a wrong cut rather than a rounding error; (3) the command fired and the arrangement map still shows one region - reported as verification_failed with nothing undone. EXCLUSIVITY IS ESTABLISHED, NOT ASSUMED: Split cuts EVERY selected region in the PROJECT at the playhead, while the arrangement map this server reads holds only the track rows Logic has RENDERED, so before the command goes out Logic's own project-wide 'Deselect All' clears the selection and is PROVEN to have landed (the rendered selection count is watched falling to zero) and the one named region is selected back; the result says `selection_scope: \"project\"` and carries that receipt. Where 'Deselect All' is not in the key command registry the tool refuses if any track row is provably hidden (scrolled out, or a collapsed stack), naming those rows, and otherwise proceeds with `selection_scope: \"rendered_rows\"` and a warning saying exactly that. Success is proven by the map across EVERY rendered row, not the target track's: the project's region total must rise by exactly 1, so a Split that cut four regions is a loud failure instead of an invisible one. Both halves are reported. A MIDI SPLIT IS NOT SILENT: when a note crosses the cut, Logic raises a modal ('Notes Crossing Split Point') and freezes until it is answered - this answers it with notes_crossing (default 'split', Logic's own pre-selection) and reports which branch it took, and it cancels any dialog left over on a failure path, because an unanswered modal makes every later tool report 'the command fired and nothing happened'. Undo restores the single region. The halves are NEW regions - re-read logic_list_regions before addressing either of them.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "region_name": ["type": "string", "description": "Which region; with start_bar, to disambiguate."],
                        "start_bar": ["type": "integer", "description": "The region's CURRENT start bar."],
                        "at_bar": ["type": "integer", "minimum": 1, "description": "Bar to cut at; must be inside the region."],
                        "at_beat": ["type": "integer", "minimum": 1, "description": "Beat within that bar, 1-based. Default 1 (the bar line)."],
                        "notes_crossing": [
                            "type": "string",
                            "enum": ["keep", "shorten", "split"],
                            "description": "What happens to a MIDI note that straddles the cut, when Logic asks: 'keep' (the note stays whole in the first region), 'shorten' (truncated at the cut), 'split' (cut in two - Logic's own pre-selection and the default here). Audio regions and cuts no note crosses raise no dialog at all, and the result then says notes_crossing: 'not_asked'."
                        ]
                    ],
                    "required": ["track_name", "at_bar"],
                    "additionalProperties": false
                ],
                // Destructive in the same sense as the other region edits: one
                // region becomes two and only Undo puts it back. Not
                // idempotent - a second call splits a half again.
                safety: .destructive,
                mayWarn: true,
                changesArrangement: true,
                handler: MCPServer.handleSplitRegion
            ),
            Tool(
                name: "logic_move_region",
                title: "Move a region",
                description: "Move one region by whole bars and/or beats via Logic's nudge key commands (no dragging, no mouse). Whole-bar moves are verified exactly against the arrangement map. EXCLUSIVITY IS ESTABLISHED, NOT ASSUMED: Nudge moves EVERY selected region in the PROJECT, while the arrangement map this server reads holds only the track rows Logic has RENDERED, so before the first nudge Logic's own project-wide 'Deselect All' clears the selection and is PROVEN to have landed (the rendered selection count is watched falling to zero) and the one named region is selected back; the result says `selection_scope: \"project\"` and carries that receipt. Where 'Deselect All' is not in the key command registry the tool refuses if any track row is provably hidden (scrolled out, or a collapsed stack), naming those rows, and otherwise proceeds with `selection_scope: \"rendered_rows\"` and a warning saying exactly that. DESTRUCTIVE: a nudged region can land ON TOP of its neighbours, and Logic trims whatever it overlays - the region that was there loses the overlapped part and only Undo brings it back. Read logic_list_regions first to see what is in the way. A nudge creates and destroys nothing, so the region total across EVERY rendered row is checked to be unchanged afterwards: a neighbour swallowed whole comes back as verification_failed rather than as a silent success. Relative, so a repeat moves again.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "region_name": ["type": "string"],
                        "start_bar": ["type": "integer", "description": "Which region (its current start bar)."],
                        "by_bars": ["type": "integer", "description": "Positive = right, negative = left."],
                        "by_beats": ["type": "integer"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                // Destructive: a nudged region can overlay and trim its
                // neighbours. Relative, so not idempotent.
                safety: .destructive,
                changesArrangement: true,
                handler: MCPServer.handleMoveRegion
            ),
            Tool(
                name: "logic_copy_region",
                title: "Copy a region",
                description: "Copy (or move, with move: true = Cut) one region to a target bar, optionally onto another track: exclusive select, Copy/Cut, select destination track, park the playhead, Paste. Verified by the region appearing at the target bar in the arrangement map. IT LANDS ON THE BAR LINE, and that is not free: Paste lands at the playhead EXACTLY, while the control bar's position display publishes whole bars and beats only - measured, a 'verified' park sat a third of a beat late every time and a marker fired there came out a beat off. So the playhead is rewound and stepped onto the grid, and the sub-beat position is read back off the control surface; a park that cannot be proven exact refuses BEFORE Paste rather than pasting inside the beat. It also establishes Logic's Tracks-area keyboard focus first, because Cut/Copy/Paste act on the focused area and a copy fired without it does nothing at all, silently - and when nothing lands the refusal names what the focus actually was and reads Logic's window list, instead of sending you hunting for a modal that is not open. EXCLUSIVITY IS ESTABLISHED, NOT ASSUMED: Cut removes EVERY selected region in the PROJECT and Copy puts every one of them on the clipboard for Paste to put back down, while the arrangement map this server reads holds only the track rows Logic has RENDERED, so before Cut/Copy fires Logic's own project-wide 'Deselect All' clears the selection and is PROVEN to have landed (the rendered selection count is watched falling to zero) and the one named region is selected back; the result says `selection_scope: \"project\"` and carries that receipt. Where 'Deselect All' is not in the key command registry the tool refuses if any track row is provably hidden (scrolled out, or a collapsed stack), naming those rows, and otherwise proceeds with `selection_scope: \"rendered_rows\"` and a warning saying exactly that. DESTRUCTIVE: the paste can land ON TOP of a region already at the target bar, and Logic trims what it overlays; move: true CUTS the source instead of copying it, so the original is gone from where it was. Only Undo puts either back - read logic_list_regions first. VERIFICATION also counts the project: a copy must raise the region total across EVERY rendered row by exactly 1 and a move: true must leave it unchanged, so a Cut that took a region the Paste never brought back, or a Paste that swallowed one whole, is a loud failure instead of an invisible one.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "region_name": ["type": "string"],
                        "start_bar": ["type": "integer"],
                        "to_bar": ["type": "integer"],
                        "to_track": ["type": "string", "description": "Destination track; default same track."],
                        "move": ["type": "boolean", "description": "true uses Cut instead of Copy (moves across tracks)."]
                    ],
                    "required": ["track_name", "to_bar"],
                    "additionalProperties": false
                ],
                // Destructive: the paste can overlay existing regions, and move:
                // true cuts the source.
                safety: .destructive,
                changesArrangement: true,
                handler: MCPServer.handleCopyRegion
            ),
            Tool(
                name: "logic_get_region_params",
                title: "Read region parameters",
                description: "Read a region's own parameters out of Logic's Region inspector — the panel at the top of the left inspector that says 'Region: <name>'. This is the read side of logic_set_region_params and the only way to see a region's quantize, transpose, velocity, loop, mute, gain, fades or delay. Pass track_name (plus region_name and/or start_bar) and the region is selected first; call it with no arguments to read whatever is selected. THREE THINGS THE RESULT TELLS YOU BEFORE THE VALUES. `subject` says whose parameters these are: a region, 'multiple' when several are selected (values that differ read as mixed), or 'defaults' — with NOTHING selected the panel shows the TRACK's region defaults ('MIDI Defaults' / 'Audio Defaults'), which is a different thing entirely and is never written by this server. `region_type` is read off the rows Logic published, independently of the arrangement map: a MIDI region has Velocity Offset, Dynamics, Gate Time and the Q-rows, an audio region has Gain, Fine Tune, Fade-In/Out, Reverse and Smart Tempo. And `enabled` per row is load-bearing: Logic greys out every Q-row while Quantize is Off, and a disabled control cannot be written. `display` is Logic's own text for the value and is ABSENT at a parameter's default, because Logic prints the default blank. The panel is opened (and its 'More' section with it) and then LEFT open, because re-opening a collapsed panel costs 0.6 s and the next region call would only open it again; `panel_state` reports exactly what was found and what was left, and this server closes them again when the session ends.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Select this track's region first. Omit to read whatever is selected."],
                        "region_name": ["type": "string", "description": "With track_name: which region."],
                        "start_bar": ["type": "integer", "description": "With track_name: the region's current start bar."],
                        "include_quantize_values": [
                            "type": "boolean",
                            "description": "Also return every value Logic's Quantize pop-up offers (note values, triplets, swing A-F, tuplets) — the vocabulary logic_set_region_params accepts for `quantize`. The list belongs to the Logic INSTALL rather than the project, so it is read off the menu once (~0.7 s, and the menu is always dismissed) and served from cache afterwards; `quantize_values_source` says which, and the cache is retired the moment Logic's version or UI language changes."
                        ]
                    ],
                    "additionalProperties": false
                ],
                // Selects a region when addressed by name, and opens the
                // panel's disclosure triangles, which it closes again when the
                // session ends (see `InspectorDebt`).
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleGetRegionParams
            ),
            Tool(
                name: "logic_set_region_params",
                title: "Set region parameters",
                description: "Set a region's own parameters through Logic's Region inspector. MIDI: quantize (with its swing and strength), transpose, velocity offset, dynamics, gate time, delay. AUDIO: gain, fine tune, transpose, fade-in and fade-out with their curves and the fade/crossfade type, reverse, delay. Both: loop and mute. These are Logic's NON-DESTRUCTIVE playback parameters — no notes are rewritten and no audio file is touched, so every one of them is reversible by setting it back, and logic_list_events keeps showing the recorded positions rather than the quantized ones. Pass as many as you like in one call; they are applied in a fixed order with QUANTIZE FIRST, because Logic disables every Q-row while Quantize is Off (so 'quantize to 1/16 with 75% swing' is one call, not two), and each fade LENGTH before its curve and type. Each write is read back off Logic's own control and reported as before/after with the row it landed on; a parameter already at the requested value is a verified no-op in `unchanged` and nothing is pressed (with every named parameter already right, the whole call comes back as state: \"already_set\"). Compare-and-set with `expected_current` per parameter. VALUES: units and ranges are on each property below, and an out-of-range number is REFUSED rather than clamped. Four parameters take Logic's OWN MENU SPELLING — quantize, dynamics, gate_time, fade_type — and a near miss is refused with the real list rather than guessed at; read the quantize list with logic_get_region_params include_quantize_values. SCOPE: the default 'region' selects the named region exclusively and writes to it alone. scope 'selection' writes to every region currently selected (set that up with logic_select_regions) — measured, not assumed: two selected regions both took the write — and it leaves the selection alone. A parameter whose value DIFFERS between the selected regions reads as mixed and cannot be compare-and-set. REFUSED, on purpose: with nothing selected the panel shows the track's region defaults and a write there would change what every future region inherits; a MIDI-only parameter on an audio region (or the reverse) is refused by name BEFORE anything is written; under scope 'selection' every numeric parameter is refused, because Logic makes those controls relative over a multi-selection; and a fade row whose label pop-up has been switched to 'Speed Up'/'Slow Down' is refused, because its value is then a ramp length and not a fade.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Which track the region is on. Required for scope 'region'."],
                        "region_name": ["type": "string", "description": "Which region, with start_bar to disambiguate."],
                        "start_bar": ["type": "integer", "description": "The region's CURRENT start bar."],
                        "scope": [
                            "type": "string",
                            "enum": ["region", "selection"],
                            "description": "'region' (default) selects the named region and writes only to it; 'selection' writes to every currently selected region and changes no selection."
                        ],
                        "quantize": ["type": "string", "description": "Logic's own menu spelling, e.g. 'Off', '1/16 Note', '1/8 Swing C'."],
                        "q_swing": ["type": "integer", "minimum": 1, "maximum": 99, "description": "Swing percentage; 50 is straight. Needs quantize to be on."],
                        "q_strength": ["type": "integer", "minimum": 0, "maximum": 100, "description": "How far notes are pulled to the grid, 0-100 %. 100 is Logic's default; lower it to quantize and still leave feel. Needs quantize to be on."],
                        "transpose": ["type": "integer", "minimum": -96, "maximum": 96, "description": "Semitones. Audio regions cap at ±36."],
                        "velocity_offset": ["type": "integer", "minimum": -99, "maximum": 99, "description": "Added to every note's velocity. MIDI regions only."],
                        "dynamics": ["type": "string", "description": "Velocity scaling by name: Fixed, 25%, 50%, 75%, 88%, 94%, 100%, 106%, 112%, 125%, 150%, 175%, 200%, 300%, 400%. MIDI regions only."],
                        "gate_time": ["type": "string", "description": "Note-length scaling by name: the Dynamics list plus 'Legato'. MIDI regions only."],
                        "delay_ticks": ["type": "integer", "minimum": -999, "maximum": 9999, "description": "Playback offset in ticks; 240 ticks = a 1/16 note. Logic shows it as a musical value ('-1/32')."],
                        "gain_db": ["type": "number", "minimum": -30, "maximum": 30, "description": "Region gain in DECIBELS, one decimal (-6.5, +3.0). Audio regions only. Logic holds it as tenths of a dB; the result reports the raw value, the dB and Logic's own display."],
                        "fine_tune": ["type": "integer", "minimum": -50, "maximum": 50, "description": "Cents, on top of transpose. Audio regions only."],
                        "fade_in_ms": ["type": "integer", "minimum": 0, "maximum": 99999, "description": "Fade-in length in milliseconds. Audio regions only. 0 removes the fade."],
                        "fade_in_curve": ["type": "integer", "minimum": -99, "maximum": 99, "description": "Shape of the fade-in, -99..99 (0 is linear). Audio regions only."],
                        "fade_out_ms": ["type": "integer", "minimum": 0, "maximum": 99999, "description": "Fade-out length in milliseconds. Audio regions only. 0 removes the fade."],
                        "fade_type": ["type": "string", "description": "Fade-out/crossfade type, Logic's own menu spelling: 'Out', 'X (Crossfade)', 'EqP (Equal Power Crossfade)', 'X S (S-Curved Crossfade)'. The short form alone ('X', 'EqP', 'X S') is accepted, case-insensitively. Audio regions only."],
                        "fade_out_curve": ["type": "integer", "minimum": -99, "maximum": 99, "description": "Shape of the fade-out, -99..99 (0 is linear). Audio regions only. Logic labels this row 'Curve' exactly like the fade-in's; it is addressed by position."],
                        "reverse": ["type": "boolean", "description": "Play the region backwards. Audio regions only, non-destructive, and the file on disk is untouched."],
                        "loop": ["type": "boolean", "description": "Loop the region to the next region or the project end."],
                        "mute": ["type": "boolean", "description": "Mute this region (not the track)."],
                        "expected_current": [
                            "type": "object",
                            "description": "Compare-and-set: the same parameter names with the values you believe are current. Any mismatch refuses with precondition_failed and writes nothing.",
                            "additionalProperties": true
                        ]
                    ],
                    "additionalProperties": false
                ],
                // Changes how the region plays back but removes no work: every
                // parameter is a value that can be set straight back, and the
                // recorded notes are untouched. Idempotent by construction —
                // the arguments name absolute target values.
                safety: .write,
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleSetRegionParams
            ),
            Tool(
                name: "logic_rename_region",
                title: "Rename a region",
                description: "Rename ONE region. Logic's Region inspector publishes the region's name as an editable text field, so this is a single write and a confirm — no dialog, no key command, and the inspector's disclosure triangles are not even touched. The region is selected exclusively first (track_name plus region_name and/or start_bar; ambiguity is refused with the candidates listed) and the rename is verified TWICE: the inspector reads the new name back, and the arrangement map shows it on the region at that position. Names are the ARRANGEMENT's, not the audio file's — renaming an audio region never touches the file on disk, and Undo restores the old name. Compare-and-set with expected_current_name. Two notes worth knowing: a MUTED region reads as '<name>, muted' in the arrangement map while the inspector shows the bare name, and this tool compares the bare names; and if Logic renumbers OTHER regions on the track as a side effect (the way it renumbers default marker names by position), the ones that moved are reported in `also_renamed`. To rename a TRACK use logic_rename_track; to rename several regions call this once per region.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Which track the region is on."],
                        "region_name": ["type": "string", "description": "Which region (its current name), with start_bar to disambiguate."],
                        "start_bar": ["type": "integer", "description": "The region's current start bar."],
                        "new_name": ["type": "string", "description": "The new name. One line, non-empty."],
                        "expected_current_name": ["type": "string", "description": "Compare-and-set: the name you believe the region carries. A mismatch refuses and writes nothing."]
                    ],
                    "required": ["track_name", "new_name"],
                    "additionalProperties": false
                ],
                // Reversible by renaming back, and idempotent: a repeat with
                // the same name is a verified no-op ("already_set").
                safety: .write,
                idempotent: true,
                changesArrangement: true,
                handler: MCPServer.handleRenameRegion
            ),
            Tool(
                name: "logic_set_tempo",
                title: "Set the tempo",
                description: "Set the project tempo in BPM via the control bar's tempo display (rapid-fire stepwise converge, ~1.3 s per 120 BPM of distance). Whole-BPM resolution. Compare-and-set with expected_current_bpm. TEMPO MAP GUARD: the tempo display shows and sets the tempo AT THE PLAYHEAD, so on a project with a tempo track this write would edit one tempo node rather than the project tempo. It therefore reads the project's tempo map out of Logic's Tempo List (View > List Editors > Tempo; ~2 s, no playhead movement) and REFUSES with precondition_failed when the map holds more than one tempo: a tempo map is edited in Logic's tempo track / Tempo List, not through this slider. When the Tempo List cannot be read it falls back to sampling the tempo at the playhead and at bar 1 (parking the playhead and restoring it — roughly 0.13 s per bar of travel) and refuses the same way; two agreeing samples are evidence, not proof, so the result then reports which bars were compared in tempo_sampled_at_bars. There is no override argument.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bpm": ["type": "number", "minimum": 5, "maximum": 990, "description": "Target tempo, 5-990."],
                        "expected_current_bpm": ["type": "number", "description": "Abort unless the current tempo matches."]
                    ],
                    "required": ["bpm"],
                    "additionalProperties": false
                ],
                safety: .write,
                mayWarn: true,
                idempotent: true,
                handler: MCPServer.handleSetTempo
            ),
            Tool(
                name: "logic_save_project",
                title: "Save the project",
                description: "Save the open Logic project — the ONLY way this server ever saves; no other tool saves as a side effect. Fires the Save key command and verifies via the document's modified flag. Refuses when more than one project is open, when the project has never been saved, or when expected_project_path does not match. Returns state: \"already_saved\" when there is nothing to save - a verified no-op, not a failure.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "expected_project_path": ["type": "string", "description": "Recommended: absolute .logicx path that must match the open project."]
                    ],
                    "additionalProperties": false
                ],
                // A repeat answers already_saved; nothing is removed.
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleSaveProject
            ),
            Tool(
                name: "logic_new_project",
                title: "New project",
                description: "Create a NEW Logic project at the given .logicx path — dialog-free, from a bundled empty project template — and open it. Logic runs single-project: if the current project has unsaved changes the call fails unless if_current_modified explicitly chooses 'save' or 'dont_save'. That refusal happens BEFORE the template is written, so a refused call leaves NOTHING at `path` and the retry carrying your decision uses the same path — it does not collide with a half-made project. The created project is already saved on disk.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute destination path ending in .logicx; must not already exist."],
                        "if_current_modified": [
                            "type": "string",
                            "enum": ["fail", "save", "dont_save"],
                            "description": "'fail' (default), 'save' or 'dont_save' — what to do with the currently open project's unsaved changes."
                        ]
                    ],
                    "required": ["path"],
                    "additionalProperties": false
                ],
                // Destructive: CLOSES the current project, and
                // if_current_modified 'dont_save' discards its changes.
                safety: .destructive,
                handler: MCPServer.handleNewProject
            ),
            Tool(
                name: "logic_open_project",
                title: "Open a project",
                description: "Open an existing .logicx project. Single-project semantics as logic_new_project: unsaved changes in the current project require an explicit if_current_modified decision.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path to an existing .logicx."],
                        "if_current_modified": [
                            "type": "string",
                            "enum": ["fail", "save", "dont_save"],
                            "description": "'fail' (default), 'save' or 'dont_save'."
                        ]
                    ],
                    "required": ["path"],
                    "additionalProperties": false
                ],
                // Destructive for the same reason as logic_new_project;
                // idempotent because reopening the same path changes nothing
                // further.
                safety: .destructive,
                idempotent: true,
                handler: MCPServer.handleOpenProject
            ),
            Tool(
                name: "logic_duplicate_project",
                title: "Duplicate the project",
                description: "Duplicate the OPEN project on disk and (by default) open the copy — the safe sandbox for destructive experiments. Default destination: '<name> Copy.logicx' next to the original; a destination_path whose folder does not exist yet is created. The copy is a same-volume APFS clone, so a 174 MB project costs ~20 ms and no extra disk space (measured); a destination on ANOTHER volume copies real bytes. WHAT HAPPENS TO THE ORIGINAL, in words, because this tool is sold on the answer: the copy is the project's ON-DISK state, so unsaved changes are not in it unless you pass save_first: true — which SAVES THE ORIGINAL to get them there. Opening the copy closes the original (single-project mode), and Logic then asks what to do with any unsaved changes: if_current_modified defaults to 'fail', so a modified original is REFUSED with nothing copied and nothing closed rather than written to disk behind you — 'save' writes the original and leaves those changes OUT of the copy, 'dont_save' throws them away, save_first: true puts them in both, and open_copy: false leaves the original open and untouched. Note that Logic marks a project modified as soon as it is opened, so 'dont_save' is the honest answer for a project you have not actually edited. The result says which happened: `saved_before_copy`, `original_written_to_disk`, `original_unsaved_changes_discarded` and `dialogs_answered`. The open is verified by PATH against Logic's own document list — never by the project's name, which cannot tell two projects with the same basename apart. If the copy is made and the open then fails, the error names the copy's path and says so, so the retry does not hit 'already exists'.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "destination_path": ["type": "string", "description": "Optional .logicx path for the copy. Missing parent folders are created. Default: '<name> Copy.logicx' beside the original."],
                        "save_first": ["type": "boolean", "description": "Save the open project before copying so the copy includes unsaved changes — this WRITES THE ORIGINAL to disk. Default false."],
                        "open_copy": ["type": "boolean", "description": "Open the copy after duplicating, which closes the original. Default true. False leaves the original open and makes this a pure disk copy."],
                        "if_current_modified": [
                            "type": "string",
                            "enum": ["fail", "save", "dont_save"],
                            "description": "What happens to the ORIGINAL's unsaved changes when the copy is opened: 'fail' (default) refuses before anything is copied, 'save' writes them to the original (they will NOT be in the copy), 'dont_save' discards them. Same values and same default as logic_open_project."
                        ]
                    ],
                    "additionalProperties": false
                ],
                // Destructive: opening the copy closes the original, with the
                // same discard choice.
                safety: .destructive,
                mayWarn: true,
                handler: MCPServer.handleDuplicateProject
            ),
            Tool(
                name: "logic_close_project",
                title: "Close the project",
                description: "Close the open project and prove it closed. 'saving' must be an explicit 'yes' or 'no' — there is no default, because discarding versus persisting changes is always the caller's decision. **If you mean to close one project and open another, call logic_reset_to (clean slate, same path or a different one) or logic_open_project instead — both fold the close in, so closing first is a wasted round-trip.** This tool is for leaving Logic with nothing open. It shares logic_reset_to's close: the AppleScript runs off-thread (Logic's AppleScript suite blocks while a modal is up) while an Accessibility loop walks whatever Logic puts on screen, and every dialog it saw is reported in `dialogs`. With saving:'no' it answers 'Do you want to save the changes…?' with **Don't Save** — that is the contract you chose. With saving:'yes' that same alert is REPORTED AND NEVER PRESSED, along with any dialog whose grammar it does not know, and the call then fails on its timeout with the alert's own text and buttons rather than clicking a button whose consequence was never measured. The close is polled, not slept on, and `verified` comes from Logic's document list actually answering that the project is gone — a readback that could not be read is never reported as a successful close. All four per-project caches (bank map, tempo map, meter map, plugin parameter names) are cleared, listed in `caches_cleared`: they are scoped by project path, which cannot tell a reopened SAME path from state measured against tracks that only existed unsaved. expected_project_path is checked BEFORE anything closes, and a never-saved project (no path to compare) is refused rather than closed unguarded.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "saving": [
                            "type": "string",
                            "enum": ["yes", "no"],
                            "description": "'yes' saves before closing; 'no' discards unsaved changes."
                        ],
                        "expected_project_path": [
                            "type": "string",
                            "description": "Absolute path of the project you believe is open. Checked against Logic's own document path before anything closes, and the close is refused on a mismatch — the guard against closing the wrong project after Logic switched under you. A project that has never been saved has no path to compare, so passing this refuses that close instead of skipping the check."
                        ],
                        "timeout_seconds": ["type": "number", "description": "How long to wait for the close, polling Logic while it happens (5-300, default 30)."]
                    ],
                    "required": ["saving"],
                    "additionalProperties": false
                ],
                // Destructive: saving 'no' throws unsaved work away.
                safety: .destructive,
                // A close whose readback could not be read returns
                // `verified: false` and says so in `warning`.
                mayWarn: true,
                handler: MCPServer.handleCloseProject
            ),
            Tool(
                name: "logic_reset_to",
                title: "Reset the project",
                description: "**THIS TOOL DISCARDS THE OPEN PROJECT'S UNSAVED CHANGES. THAT IS ITS CONTRACT, NOT A SIDE EFFECT.** The episode-reset primitive: close whatever is open WITHOUT saving, open the .logicx at `path`, and prove the world is in a known state. Built for eval harnesses and for any agent that wants a clean slate between attempts — reset to the same file it was already in and every experiment of the last episode is gone. `confirm_discard: true` is REQUIRED and has no default, so this cannot be tripped into; call logic_save_project first if the changes matter. Refuses BEFORE touching Logic when the target file does not exist, so a bad path never costs you the open project. IT OWNS THE DIALOGS: the close runs off-thread (Logic's AppleScript blocks while a modal is up) while an Accessibility loop walks whatever appears, answers 'Do you want to save the changes…?' with **Don't Save** and the auto-save recovery prompt with **Saved**, and reports every dialog it saw in `dialogs`. A dialog whose grammar it does not recognise is REPORTED AND NEVER PRESSED — the reset then fails on the timeout with the alert's own text and buttons in the log, rather than clicking a button whose consequence was never measured. CACHES: all four per-project caches (bank map, tempo map, meter map, plugin parameter names) are cleared explicitly while nothing is open. They are scoped by project path, which already covers switching to a DIFFERENT project — but reopening the SAME path keeps the scope token identical, so a bank map measured against tracks that only existed unsaved would otherwise survive the reset and be trusted. VERIFICATION: the frontmost document window matches the target path, exactly one document is open, it is unmodified, logic_health's Accessibility and process checks pass, and no dialog is left on screen. Every check is reported individually and `verified` is the AND of all of them. If the open fails after the close, the error says so explicitly — the previous project is already gone at that point and Logic has nothing open.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path to the .logicx to reset to. Must already exist; pass the SAME path the project is currently at to reset an episode in place."],
                        "confirm_discard": [
                            "type": "boolean",
                            "description": "Must be exactly true. Acknowledges that the open project's unsaved changes are thrown away. There is no default."
                        ],
                        "timeout_seconds": ["type": "number", "description": "How long to wait for the close (5-300, default 30). The open has its own 30 s budget."]
                    ],
                    "required": ["path", "confirm_discard"],
                    "additionalProperties": false
                ],
                // The most destructive tool in the server: discarding unsaved
                // work is the thing it is FOR, not a risk it carries.
                safety: .destructive,
                mayWarn: true,
                // Resetting twice to the same path lands in the same state —
                // the second run simply has nothing to discard.
                idempotent: true,
                handler: MCPServer.handleResetTo
            ),
            Tool(
                name: "logic_project_snapshot",
                title: "Snapshot the project",
                description: "The TRUTH DOCUMENT: one call that aggregates the existing readers into a structured, diffable picture of the project. Pair it with logic_reset_to to diff an episode's start and end state, or call it once to understand a project you did not build instead of making twenty reads. SCOPE decides the cost, not the capability — each level is a superset of the one before. 'structure' (default) is Accessibility-only and never touches the control surface: transport (tempo, meter, playhead, project path), the tempo map, the meter map, markers, the rendered track list and the region map. 'mix' adds the control-surface strip census and the full mixer snapshot (two bank walks — the expensive part). 'full' adds per-track MCU inserts and sends, one strip selection each, capped by max_tracks. COMPLETENESS IS THE CONTRACT: every section named in `sections` is present in the result, and one that could not be read comes back as {\"unavailable\": \"<reason>\"} — never a missing key, because a diff would read a missing section as an empty project rather than a failed reader. `complete` is false whenever any section is unavailable, and `unavailable_sections` names them. Deterministic by design: fixed section and array ordering, keys serialized sorted, so two snapshots of the same project diff cleanly. `timing_ms` carries the per-section cost and is the ONE nondeterministic block — drop it before diffing. Composes the same functions the individual tools call (logic_get_transport, logic_list_signatures' meter map, logic_markers, logic_list_tracks, logic_list_regions, logic_list_strips, logic_mixer_snapshot, logic_list_inserts route 'mcu', logic_mcu_sends), so their caveats apply here unchanged — in particular the track list is only the RENDERED rows, and the MCU sections degrade honestly against an old bridge daemon.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "scope": [
                            "type": "string",
                            "enum": SnapshotScope.allCases.map(\.rawValue),
                            "description": "'structure' (default, AX-only), 'mix' (+ census and mixer), 'full' (+ per-track inserts and sends)."
                        ],
                        "max_tracks": ["type": "integer", "minimum": 1, "maximum": 64, "description": "Cap on tracks walked by scope 'full', default 8. Exceeding it truncates the inserts/sends sections, which say so."]
                    ],
                    "additionalProperties": false
                ],
                // Read-only about the PROJECT, but scope 'mix'/'full' banks the
                // control surface and every scope opens and restores a List
                // Editors pane — the same reason logic_mixer_snapshot is not
                // readOnly. Nothing in the project changes.
                safety: .write,
                mayWarn: true,
                idempotent: true,
                handler: MCPServer.handleProjectSnapshot
            ),
            Tool(
                name: "logic_setup_key_commands",
                title: "Set up key commands",
                description: "One-time onboarding: learn MIDI-note assignments for all standard key commands (Toggle Track Freeze, Undo, Redo, Flashback Capture as Recording, Split at Playhead, Create Marker) into the user's Logic via the Key Commands window automation. Additive to the user's key command set and removable there; collisions with existing assignments get alternate notes automatically. Idempotent — already-learned commands are verified and skipped, each reported in `results` as state: \"already_learned\" (the same entries also carry the older key `status`, which will be dropped in a later release). Runs automatically the first time a tool needs a missing command, so calling this explicitly is optional. Pass relearn: true to force re-learning even for commands that look bound — the repair when key commands silently stopped firing (e.g. after the MIDI ports were recreated: Logic scopes the assignments to the port identity).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "relearn": ["type": "boolean", "description": "Force re-learning of every standard command even when an assignment is already shown. Repairs bindings orphaned by MIDI-port changes. Default false."],
                        // Enumerated FROM the registry, never a copy of it:
                        // the handler filters against exactly this list and
                        // refuses when nothing matches, so a hand-kept
                        // duplicate here could only ever drift out of date.
                        "commands": [
                            "type": "array",
                            "items": [
                                "type": "string",
                                "enum": KeyCommandRegistry.standardCommands.map(\.name)
                            ],
                            "description": "Limit to these standard command names (default: all)."
                        ]
                    ],
                    "additionalProperties": false
                ],
                // Additive to the user's key command set, and idempotent by
                // construction.
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleSetupKeyCommands
            ),
            Tool(
                name: "logic_learn_key_command",
                title: "Learn a key command",
                description: "Learn ANY command in Logic's Key Commands window - not just the standard set - onto a MIDI note, so logic_trigger_key_command can fire it. Give the command's name EXACTLY as the Key Commands window spells it (e.g. 'Strip Silence…', 'Bounce Regions in Place', 'Select All Following of Same Track'); the search field is driven with the first words of that name unless you pass 'search' yourself. THIS WRITES INTO THE USER'S OWN LOGIC KEY COMMAND SET: the command gains an additional assignment on the dedicated 'Logic MCP Commands' MIDI port. It is additive - the user's existing keyboard shortcut is untouched - and removable in the same window (select the command, Delete Assignment). The MIDI note is chosen automatically from a range reserved for learned commands (60-99, then 122-127, then 21-59), so it can never take a note the product's own standard commands want; pass 'note' only to force one. The registry file is the consent record and records the name, note, timestamp, search term and that THIS tool bound it - read it back with logic_list_key_commands. Already-registered commands answer immediately without opening the window, as state: \"already_registered\" (or \"already_learned\" when the window confirmed an existing assignment); pass relearn: true to bind again, the repair after MIDI ports were recreated. When no row matches, the failure is not_found and it LISTS the rows the panel was showing: command names drift between Logic versions, so a near miss is answered with the real spellings rather than a guess.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "The command name exactly as Logic's Key Commands window shows it. Case-insensitive; Logic's own spelling is what gets registered."],
                        "search": ["type": "string", "description": "Optional search term for the window's filter field (default: the first words of 'name'). Use a shorter term when the exact name is uncertain - the not_found answer then lists more near misses."],
                        "note": ["type": "integer", "minimum": 0, "maximum": 127, "description": "Force a specific MIDI note instead of the next free one. Refused when another registered command already holds it."],
                        "relearn": ["type": "boolean", "description": "Bind again even when the registry already lists this command, wiping its existing controller assignments first. Default false."],
                        "dry_run": ["type": "boolean", "description": "Look, do not bind: open the window, filter on 'search', return every command name it shows with the assignment it already carries, and close again. Use this FIRST when unsure of a name — nothing is written to the user's key command set."]
                    ],
                    "required": ["name"],
                    "additionalProperties": false
                ],
                // Additive to the user's key command set, like
                // logic_setup_key_commands, and idempotent: a second call with
                // the same name answers already_registered.
                safety: .write,
                mayWarn: true,
                idempotent: true,
                handler: MCPServer.handleLearnKeyCommand
            ),
            Tool(
                name: "logic_list_key_commands",
                title: "List key commands",
                description: "List what the key command registry holds: every command name that has been learned onto the 'Logic MCP Commands' MIDI port, its note and channel, when it was learned, and which tool bound it. Read-only and Logic-free - this reads the registry FILE, so an entry it lists can still have been orphaned inside Logic (recreated MIDI ports do that silently; logic_setup_key_commands with relearn: true repairs it). The registry is what logic_trigger_key_command checks before firing anything, so this is also the list of commands an agent may fire. Also reports which standard commands are not learned yet.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleListKeyCommands
            ),
            Tool(
                name: "logic_trigger_key_command",
                title: "Trigger a key command",
                description: "Fire a Logic key command that was learned onto the dedicated 'Logic MCP Commands' MIDI port. Pass name (e.g. 'Toggle Track Freeze', 'Undo') or note+channel. Standard commands missing from the registry are learned automatically first; unknown notes are refused because they could be bound to anything. CAUTION with Undo: the menu shows no operation name, so only fire it right after a known edit.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        // No enum on `name`: the registry also holds whatever
                        // the user learned beyond the standard set, and the
                        // handler resolves against that live file.
                        "name": ["type": "string", "description": "Registered command name, e.g. 'Toggle Track Freeze'."],
                        "note": ["type": "integer", "minimum": 0, "maximum": 127, "description": "MIDI note of a registered command."],
                        "channel": ["type": "integer", "minimum": 1, "maximum": 16, "description": "MIDI channel, default 16."]
                    ],
                    "additionalProperties": false
                ],
                // Destructive: the registry holds Delete, Cut and Delete Track -
                // the effect is whatever the caller names.
                safety: .destructive,
                handler: MCPServer.handleTriggerKeyCommand
            ),
            Tool(
                name: "logic_render_track",
                title: "Render a track to a file",
                description: "Render ONE track offline to an audio file ON DISK with ZERO dialogs, via Track Freeze. NOT bounce-in-place: it produces a FILE, it does not commit a new audio region into the project, so it is not the tool for 'print that so I can chop it' - resampling a part back into the arrangement has no route in this server yet. Mechanism: selects the track, toggles freeze over the 'Logic MCP Commands' MIDI port, presses play (Logic then renders the whole track offline, typically seconds), copies the 32-bit float AIFF out of Media/Freeze Files to the captures folder, and unfreezes again. Requires 'Toggle Track Freeze' in the key command registry and the MCU bridge running. WHAT `verified` MEANS HERE: it reports the CLEANUP, not the render. `verified` aliases `unfrozen`, so a perfectly good render whose freeze could not be undone comes back verified: false with the track still frozen in Logic (unfreeze it there). Judge the render itself by `path` and `metrics`. Renders the full track from project start including all plugins and automation (freeze mode Pre Fader). If the track is already frozen the call fails safely and restores state. TEMPO: with start_bar/end_bar the slice's boundaries are integrated over the project's tempo map, read out of Logic's Tempo List (View > List Editors > Tempo; ~2 s, no playhead movement, cached per project and reported in tempo_map). When the Tempo List cannot be read the slice falls back to constant-tempo bar math and the tempo is sampled at both ends of the range instead (parks the playhead, reads, restores), with a `warning` naming both readings when they differ — the FULL render is unaffected either way. Without a bar range no tempo is read at all.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Track to render, matched against MCU LCD names or AX track headers."],
                        "track_number": ["type": "integer", "description": "Optional AX row number to disambiguate duplicates."],
                        "label": ["type": "string", "description": "Filename label; default is derived from the track name."],
                        "start_bar": ["type": "integer", "minimum": 1, "description": "With end_bar: also cut this bar range out of the render as a separate 32-bit float WAV with its own metrics (bar 1 = project start)."],
                        "end_bar": ["type": "integer", "minimum": 2, "description": "Exclusive: the slice ends where this bar begins. Must be greater than start_bar."],
                        "tempo": ["type": "number", "description": "Override BPM for the bar math; default reads the control bar. Only used when the tempo map cannot be read from the Tempo List — a readable map is integrated instead. Constant METER is still assumed (signature changes are not read)."],
                        "beats_per_bar": ["type": "number", "description": "Override meter; default reads the control bar's time signature."],
                        "expected_project_path": ["type": "string", "description": "Absolute .logicx path; when given, the open project's AXDocument must match before anything is changed."],
                        "include_audio": MCPServer.includeAudioProperty,
                        "blind": MCPServer.blindProperty
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                // Freezes and unfreezes the track; a new file per call.
                safety: .write,
                mayWarn: true,
                handler: MCPServer.handleRenderTrack
            ),
            Tool(
                name: "logic_mcu_command",
                title: "Send a raw surface command",
                description: "Send a command to Logic through the Mackie Control bridge (UI-independent). cmd is one of: press {button: play|stop|record|rewind|forward|cycle|click|bank_left|bank_right|channel_left|channel_right|flip|name_value|assign_track|assign_send|assign_pan|assign_plugin|assign_eq|assign_instrument|...}, select/mute/solo {channel: 0-7}, fader {channel: 0-8, value: 0-16383, verify: true}, vpot {index: 0-7, delta: +-n}, vpot_press {index}, raw {bytes: [..]}, ping. Read logic_mcu_status afterwards to verify via Logic's feedback. FADER: Logic does follow an absolute fader write (measured, with and without the fader-touch note), but it SNAPS the position to its own resolution — 5631 through 5635 all landed on 5628 — so never compare the echo to the value you asked for with ==. Pass verify: true to get final_value (where Logic actually settled) and followed back; to restore a fader exactly, write back a value Logic itself reported, which is on its grid by construction. Channel 8 is the dedicated master fader, which is Logic's `Master` strip and NOT `Stereo Out`.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        // The daemon's whole vocabulary, taken FROM the shared
                        // enum so the two can never drift. A few of these
                        // (await, converge, midi_stream) carry arguments this
                        // schema has no properties for and additionalProperties
                        // is false — they are listed because the daemon
                        // accepts them, not because they are useful here.
                        "cmd": ["type": "string", "enum": BridgeCommandName.allCases.map(\.rawValue).sorted()],
                        "button": ["type": "string", "enum": buttonNames.keys.sorted()],
                        // NO bounds on channel: the accepted range depends on
                        // cmd (0-7 for select/mute/solo, 0-8 for fader, 1-16
                        // for keycmd), and one schema range would refuse calls
                        // the daemon accepts.
                        "channel": ["type": "integer"],
                        "index": ["type": "integer", "minimum": 0, "maximum": 7, "description": "Vpot/channel-strip index 0-7."],
                        "value": ["type": "integer", "minimum": 0, "maximum": 16383, "description": "14-bit fader value 0-16383."],
                        "delta": ["type": "integer", "description": "Vpot ticks, positive = clockwise; magnitudes above 63 are clamped."],
                        "note": ["type": "integer", "minimum": 0, "maximum": 127],
                        "bytes": ["type": "array", "items": ["type": "integer", "minimum": 0, "maximum": 255]]
                    ],
                    "required": ["cmd"],
                    "additionalProperties": false
                ],
                // Destructive: a raw byte stream to the control surface can do
                // anything Logic exposes.
                safety: .destructive,
                handler: MCPServer.handleMcuCommand
            ),
            Tool(
                name: "logic_get_audio_clip",
                title: "Fetch an audio clip",
                description: "LISTEN to rendered audio: returns the seconds you ask for out of a local audio file as an MCP audio content block (mono AAC 64 kbps) that multimodal models can hear - default 8 s from second 0, max 20 s. The window is CUT from the file on every format it reads (AIFF/AIFC, WAV, CAF, M4A/AAC, MP3, FLAC - everything this server and Logic write), the result reports the clip it actually made, and a start past the end of the file is refused rather than quietly widened to the whole file. Use this on the file paths returned by logic_render_track / logic_bounce_range / logic_evaluate_change. WHAT IT COSTS, measured 2026-09-02: the default 8 s is ~50 KB encoded and ~70 KB on the wire (~17k tokens if your client stringifies it) on loud material, ~10 KB on quiet (AAC is variable-rate); the 20 s maximum is ~131 KB encoded and ~179 KB on the wire (~45k tokens). include_audio: false cuts that to ~1.3 KB and still returns clip_path and the resource_link - use it when you will listen through the file viewer anyway. NEVER read raw audio files with a text/file tool - megabytes of binary will overflow the model context and can crash the client. Also writes the clip to disk (clip_path in the result, unique per call): if the audio block does NOT reach you, your client drops MCP audio - open clip_path with your client's file viewer instead, which most clients pass to the model as real audio.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path to a local audio file (AIFF/AIFC, WAV, CAF, M4A, MP3, FLAC)."],
                        "start_seconds": ["type": "number", "minimum": 0, "description": "Offset into the file, default 0. Past the end of the file is refused, and a window the file ends inside comes back shortened with a warning saying so."],
                        // 20 s is the ceiling the handler clamps to and the
                        // description already promises; making it machine-
                        // readable turns a silently shortened clip into an
                        // argument error the model can act on.
                        "duration_seconds": ["type": "number", "minimum": 0, "maximum": 20, "description": "Clip length, default 8, max 20."],
                        // false leaves only clip_path - which is still worth
                        // having: the file viewer route works in clients that
                        // drop MCP audio blocks.
                        "include_audio": MCPServer.includeAudioProperty
                    ],
                    "required": ["path"],
                    "additionalProperties": false
                ],
                // Read-only: reads a file the caller already has. The clip it
                // writes is its own result artifact - see ToolSafety.readOnly.
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleGetAudioClip
            ),
            Tool(
                name: "logic_get_transport",
                title: "Read the transport",
                description: "Read the transport state and where the playhead is right now, from the control bar: playing, recording, cycle, playhead position in bars/beats, tempo, time signature, key signature, metronome, count-in. Read-only. AT THE PLAYHEAD, not project constants: tempo, time_signature and key_signature are the values IN FORCE WHERE THE PLAYHEAD IS — the same project answers 121 BPM in 5/4 with the playhead at bar 51 and 120 BPM in 4/4 with it at bar 1 (measured). For the whole maps call logic_tempo_events (tempo) and logic_list_signatures (meter). Fields whose control bar element is missing are null, and every field listed here is present on every call — null, never absent. The Smart Tempo project tempo mode (Keep/Adapt/Auto) is NOT in the cheap read — Logic publishes no value on the control bar's Project Tempo pop-up — so it comes back as project_tempo_mode_note saying why. Pass read_smart_tempo_mode: true to get the real value: that opens File > Project Settings on the Smart Tempo pane, reads the mode off its pop-up and closes the window again (~0.75 s, nothing written), and the result then carries project_tempo_mode plus project_tempo_mode_route. Worth knowing before recording: an ADAPT-mode project rewrites its own tempo map to follow a recording, and logic_record_midi runs this same read and refuses on Adapt/Auto.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "read_smart_tempo_mode": [
                            "type": "boolean",
                            "description": "Also read the Smart Tempo project tempo mode from File > Project Settings (opens and closes that window; default false, which keeps this call a pure control-bar read with no side effect)."
                        ]
                    ],
                    "additionalProperties": false
                ],
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleGetTransport
            ),
            Tool(
                name: "logic_tempo_events",
                title: "Read the tempo map",
                description: "Read and WRITE the project's tempo map — the tempo track, as rows in Logic's Tempo List. This is what makes a tempo map buildable: 'land a downbeat on the hit at 1:12' is create-an-event, and until now the map could only be read. action 'list' returns every event (bar, beat, BPM) and writes nothing; the map is cached per project, every cache hit is cross-checked against the control bar's live tempo, and a list whose cross-check could NOT run (the control bar unreadable, e.g. a non-English Logic UI) comes back verified: false with read_route 'tempo_list_cache' and a warning - never as a verified live read. 'create' makes a new event at bar/beat with bpm; 'set' retunes the event already there; 'delete' removes it. HOW THE WRITE WORKS, because two parts of it are surprising. Logic's own 'Create new Tempo Event' button places the event AT THE PLAYHEAD, not on a bar line, and parking the playhead only sets its bar and beat — the division and tick it already carried come along — so this tool creates the event and then steps the new row's own position fields back to the exact bar/beat you asked for. And the BPM is written through the CONTROL BAR's tempo slider, which edits the tempo event in force at the playhead: with the playhead parked on the event, that is this event. Neither half is trusted: the whole map is re-read afterwards and the result reports it, so a create that produced two events, or moved a neighbour, comes back as a failure (or a warning naming which other events moved) rather than as a success. Compare-and-set with expected_current_bpm on 'set' and 'delete'. REFUSED: 'create' where an event already sits (use 'set'), 'set'/'delete' where none does, deleting bar 1 (the project's base tempo — retune it instead), and any write at all while the Tempo List cannot be read, because a tempo write is not made blind. COST: a few seconds, dominated by the playhead travel to the bar (~0.13 s per bar) and by the tempo slider's one-BPM-per-step convergence. AFTER A WRITE the server's cached tempo and meter maps are dropped, so every later bar->seconds conversion re-reads the new map.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["list", "create", "set", "delete"],
                            "description": "'list' (default) reads the map and writes nothing."
                        ],
                        "bar": ["type": "integer", "minimum": 1, "description": "Which bar the event sits on. Required for create/set/delete."],
                        "beat": ["type": "integer", "minimum": 1, "description": "Which beat within the bar (default 1)."],
                        "bpm": ["type": "number", "minimum": 5, "maximum": 990, "description": "The tempo. Required for create and set. Logic's slider holds whole BPM."],
                        "expected_current_bpm": ["type": "number", "description": "Compare-and-set for 'set' and 'delete': the BPM you believe the event carries. A mismatch refuses and writes nothing."]
                    ],
                    "additionalProperties": false
                ],
                // Writes the project's tempo track, which every bar->seconds
                // conversion depends on. Idempotent by construction: the
                // arguments name an absolute position and an absolute tempo.
                safety: .write,
                mayWarn: true,
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleTempoEvents
            ),
            Tool(
                name: "logic_set_cycle",
                title: "Turn cycle on or off",
                description: "Turn cycle (loop) mode on or off via the control bar Cycle button and verify the new state.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "enabled": ["type": "boolean"]
                    ],
                    "required": ["enabled"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleSetCycle
            ),
            Tool(
                name: "logic_set_playing",
                title: "Start or stop playback",
                description: "Start or stop playback via the control bar Play button and verify the new state. Starting plays from the current playhead position (or the cycle range when cycle is on).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "playing": ["type": "boolean"]
                    ],
                    "required": ["playing"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleSetPlaying
            ),
            Tool(
                name: "logic_set_playhead",
                title: "Move the playhead",
                description: "Move the playhead to a 1-based bar (and optional beat) by stepping the control bar position display, then verify. Requires the control bar display mode that exposes bar/beat (Beats & Project).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bar": ["type": "integer"],
                        "beat": ["type": "integer"]
                    ],
                    "required": ["bar"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleSetPlayhead
            ),
            Tool(
                name: "logic_set_cycle_range",
                title: "Set the cycle range",
                description: "Set the cycle (loop) locators to a whole-bar range, e.g. bars 5-9. Anchors the ruler's grid-snapped cycle region to a bar line via the playhead thumb, moves the region start by writing its AXPosition, adjusts the length by dragging its right edge (hit-test guarded), verifies via the region's bar-denominated size description, and restores the playhead. The target range must be visible in the ruler. Optionally turns cycle on/off afterwards via 'enabled'.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "start_bar": ["type": "integer", "description": "1-based bar where the cycle starts."],
                        "end_bar": ["type": "integer", "description": "Bar where the cycle ends (exclusive right locator, as shown in Logic)."],
                        "enabled": ["type": "boolean", "description": "When given, turn cycle mode on or off after setting the range."]
                    ],
                    "required": ["start_bar", "end_bar"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleSetCycleRange
            ),
            Tool(
                name: "logic_select_track",
                title: "Select a track",
                description: "Select a track by name (and optional 1-based track number) so its channel strip is exposed in the inspector. Writes AXSelectedChildren on the Tracks header group, falls back to the header's Has Focus button, and verifies through both the header's selected state and the inspector strip. Fails with ambiguous when several visible tracks share the name, and restores the previous selection if verification fails. Only tracks whose headers are currently rendered can be selected.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Exact track name as shown in the track header."],
                        "track_number": ["type": "integer", "description": "1-based track number; required when several visible tracks share the name."],
                        "expected_project_path": ["type": "string", "description": "Absolute .logicx path; when given, the open project's AXDocument must match before anything is changed."]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                // Not read-only: changes the track selection.
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleSelectTrack
            ),
            Tool(
                name: "logic_set_track_stack",
                title: "Fold a track stack",
                description: "Expand or collapse a track stack by pressing its disclosure triangle, verifying the new state, and reporting which subtracks were revealed or hidden. Fails with not_exposed if the track is not a stack. Subtracks of a collapsed stack are otherwise invisible to logic_list_tracks and logic_select_track.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Exact name of the stack's main track."],
                        "track_number": ["type": "integer", "description": "1-based track number; required when several visible tracks share the name."],
                        "expanded": ["type": "boolean", "description": "true to show the stack's subtracks, false to hide them."],
                        "expected_project_path": ["type": "string", "description": "Absolute .logicx path; when given, the open project's AXDocument must match before anything is changed."]
                    ],
                    "required": ["track_name", "expanded"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleSetTrackStack
            ),
            Tool(
                name: "logic_survey_plugins",
                title: "Survey a track's plugins",
                description: "Inventory every insert on a track: open each plugin window, list its accessible parameters (name, raw range, writability), classify the exposure, and close windows that were opened. Takes a few seconds per insert. Use to map which plugins are controllable through this MCP."
                    + Tool.stripAddressingAXNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                // Not read-only: opens and closes plugin windows.
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleSurveyPlugins
            ),
            Tool(
                name: "logic_add_plugin",
                title: "Add a plugin",
                description: "Add a plugin to a track's first empty insert slot — mouse-free via the Mackie Control plugin browser (vpot-stepped, LCD-verified, vpot-press instantiates). Works for every plugin in Logic's browser including third-party. If the MCU bridge is down, the AX chooser fallback requires allow_mouse: true because it briefly takes over the pointer. `cross_check` names the SECOND, independent source: \"ax_insert_list\" (the inspector strip's insert list agreed) or \"unavailable\" (no inspector is showing that strip, so the control surface's own echo is the only evidence - the result warns when that happens)."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "plugin_name": ["type": "string", "description": "Menu title of the plugin, e.g. 'Gain', 'Channel EQ', 'Decapitator'."],
                        "format": ["type": "string", "description": "Channel format submenu item when offered, default 'Stereo'."],
                        "allow_mouse": ["type": "boolean", "description": "Permit the Accessibility chooser fallback, which moves the pointer. Default false (data-driven MCU browser only)."],
                        "expected_project_path": ["type": "string", "description": "Refuse unless this is the open project."]
                    ],
                    "required": ["track_name", "plugin_name"],
                    "additionalProperties": false
                ],
                // Additive: fills the first EMPTY slot; a repeat adds another
                // instance.
                safety: .write,
                mayWarn: true,
                handler: MCPServer.handleAddPlugin
            ),
            Tool(
                name: "logic_remove_plugin",
                title: "Remove a plugin",
                description: "Remove a plugin from a track — mouse-free via the Mackie Control plugin browser's No Plug-in entry (can take up to ~60 s of vpot stepping; verified via LCD and an AX cross-check on the named track). When the same display name occupies several slots, the mouse-free route refuses to guess: pass insert_slot to name the one to remove. If the MCU bridge is down, the AX chooser fallback requires allow_mouse: true because it briefly takes over the pointer. `cross_check` names that second source: \"ax_insert_list\" (the inspector strip's insert list agreed the plugin is gone - one fewer instance, when several were there) or \"unavailable\" (no inspector is showing that strip, so the control surface's own echo is the only evidence - the result warns when that happens)."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "plugin_name": ["type": "string"],
                        "insert_slot": ["type": "integer", "minimum": 1, "maximum": 8, "description": "Needed only when the same plugin sits in several slots - names which one the mouse-free route removes. Its LCD cell must show plugin_name or the call refuses without pressing anything." + Tool.mcuInsertSlotNote],
                        "insert_index": ["type": "integer", "description": "Same-plugin disambiguator for the allow_mouse Accessibility FALLBACK only (the mouse-free route takes insert_slot instead) - and DESTRUCTIVE if it is wrong: the plugin at that ordinal is the one removed." + Tool.axInsertIndexNote],
                        "allow_mouse": ["type": "boolean", "description": "Permit the Accessibility chooser fallback, which moves the pointer. Default false (data-driven MCU browser only)."],
                        "expected_project_path": ["type": "string", "description": "Refuse unless this is the open project."]
                    ],
                    "required": ["track_name", "plugin_name"],
                    "additionalProperties": false
                ],
                // Destructive: the plugin and its settings go. Idempotent: the
                // target state is 'absent'.
                safety: .destructive,
                mayWarn: true,
                idempotent: true,
                handler: MCPServer.handleRemovePlugin
            ),
            Tool(
                name: "logic_set_track_mute",
                title: "Mute a track",
                description: "Mute or unmute a track via its inspector channel strip mute button, verified by readback (control surface first, inspector strip as fallback). A track already in the requested state is a verified no-op (state: \"already_on\" / \"already_off\") and nothing is pressed."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "enabled": ["type": "boolean", "description": "true mutes the track, false unmutes it."],
                        "expected_current": ["type": "boolean", "description": "Compare-and-set: the mute state you believe the track is in. A mismatch refuses with precondition_failed and presses nothing."]
                    ],
                    "required": ["track_name", "enabled"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleSetTrackMute
            ),
            Tool(
                name: "logic_set_track_solo",
                title: "Solo a track",
                description: "Solo or unsolo a track via its inspector channel strip solo button, verified by readback (control surface first, inspector strip as fallback). A track already in the requested state is a verified no-op (state: \"already_on\" / \"already_off\") and nothing is pressed. A solo left on silently empties every later bounce, so unsolo before judging a mix."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "enabled": ["type": "boolean", "description": "true solos the track, false unsolos it."],
                        "expected_current": ["type": "boolean", "description": "Compare-and-set: the solo state you believe the track is in. A mismatch refuses with precondition_failed and presses nothing."]
                    ],
                    "required": ["track_name", "enabled"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleSetTrackSolo
            ),
            Tool(
                name: "logic_set_track_volume",
                title: "Set track volume",
                description: "Set a track's volume fader to a dB value, converging against Logic's own dB readout and reporting before_db / after_db / requested_db. `db` is ABSOLUTE, never an offset - read the current value first (logic_track_info and logic_mixer_snapshot both report volume_db), or pass relative_db instead, which computes the target from the value read immediately before the write ('2 dB louder' is relative_db: 2). The two are mutually exclusive and one of them is required. Compare-and-set with expected_current_db. Fader steps are about 0.1-0.3 dB apart; default tolerance 0.15 dB. WHAT `verified` MEANS HERE: exactly what you asked for — the landed value is within tolerance_db of the target, with no widening. When the fader will not reach that, the control-surface route re-converges and, failing that, returns verified: false with `deviation_db` and a `verification_note` saying how far out it stopped. `success` stays true either way, because the fader did move and after_db is Logic's own dB readout of where it is."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "db": ["type": "number", "description": "ABSOLUTE target level in dB (e.g. -14.2, 0.0). Mutually exclusive with relative_db; one of the two is required."],
                        "relative_db": ["type": "number", "description": "Offset in dB from the value read immediately before the write: 2 is '2 dB louder', -3 is '3 dB quieter'. Mutually exclusive with db. Saves the read-then-guess round trip, and the result still reports before_db and after_db."],
                        "expected_current_db": ["type": "number", "description": "Compare-and-set: the dB you believe the fader is at. A difference of more than 0.5 dB refuses with precondition_failed and moves nothing."],
                        "tolerance_db": ["type": "number", "description": "Accepted deviation from the target, default 0.15 dB. Note that `verified` on the control-surface fast path uses max(tolerance_db, 0.6) - see the description."]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleSetTrackVolume
            ),
            Tool(
                name: "logic_set_track_pan",
                title: "Set track pan",
                description: "Set a track's pan/balance knob position via the inspector strip, verified by readback. `position` is ABSOLUTE, not an offset: read the current value first (logic_track_info or logic_mixer_snapshot both report `pan`) and pass the number you want it to end on. Reports `before` and `after`."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "position": ["type": "integer", "description": "ABSOLUTE knob position, typically -64..63 with 0 at center; the knob's own range is enforced. Out of range is refused, never clamped."],
                        "expected_current_position": ["type": "integer", "description": "Compare-and-set: the position you believe the knob is at. A mismatch refuses with precondition_failed and writes nothing."]
                    ],
                    "required": ["track_name", "position"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleSetTrackPan
            ),
            Tool(
                name: "logic_open_plugin",
                title: "Open a plugin window",
                description: "Open the plugin window for one insert on the named (selected) track by pressing the insert's open button, then verify that the window appeared. If the window was already open it is identified via its toggle behaviour and restored. Fails closed on not_found, ambiguous (two inserts with the same plugin), not_exposed and verification_failed.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "plugin_name": ["type": "string", "description": "Plugin display name; truncated slot names such as 'Space D' match by prefix."],
                        "insert_index": ["type": "integer", "description": "Required when the same plugin occupies several slots." + Tool.axInsertIndexNote],
                        "expected_project_path": ["type": "string", "description": "Absolute .logicx path; when given, the open project's AXDocument must match before anything is pressed."]
                    ],
                    "required": ["track_name", "plugin_name"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleOpenPlugin
            ),
            Tool(
                name: "logic_close_plugin",
                title: "Close a plugin",
                description: "Close the plugin window of one insert on the named (selected) track by toggling the insert's open button, verifying that a window titled after the track disappeared. Precise even when several plugin windows share the same title. Reads the window list BEFORE pressing: with no window open for that track it returns state already_closed in ~10 ms without pressing anything, because the open button is a toggle and pressing it would OPEN the plugin. In the rare case where the press opens a window instead of closing one (another plugin on the same track had the only window with that title), that window is closed again and precondition_failed is returned.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "plugin_name": ["type": "string"],
                        "insert_index": ["type": "integer", "description": "Required when the same plugin occupies several slots." + Tool.axInsertIndexNote]
                    ],
                    "required": ["track_name", "plugin_name"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleClosePlugin
            ),
            Tool(
                name: "logic_close_plugin_window",
                title: "Close a plugin window",
                description: "Close one plugin window by pressing its close button and verifying that THAT window is gone (its element and its title, not merely some window). Closes only windows whose Accessibility subrole is AXDialog: plugin and auxiliary windows, INCLUDING document-carrying ones such as Drum Machine Designer. Any other subrole is refused - the project window and the Mixer are AXStandardWindow - and the refusal names the subrole it found. Fails with ambiguous when several windows share the title; use logic_close_plugin there. A window still on screen after the press is reported success: false, verified: false, never as closed.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "window_title": ["type": "string"]
                    ],
                    "required": ["window_title"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleClosePluginWindow
            ),
            Tool(
                name: "logic_list_plugin_parameters",
                title: "List plugin parameters",
                description: "Read a plugin's parameter names and current formatted values. ONE tool, TWO routes, and `route_used` says which ran. Pass window_title for the ACCESSIBILITY route: it reads an already-open plugin window and adds `ax_writable` per parameter — whether logic_set_plugin_parameter can write it through a text field. Logic reads a plugin through its sliders and writes it through editable \"knob and field\" controls, and knob-only plugins publish sliders but no field at all (measured: Channel EQ 26 sliders / 0 fields, Limiter 4 / 0), so an all-false list means the plugin is read-only from that plane. Pass track_name + insert_slot for the CONTROL-SURFACE route: host automation reads every MCU page, needs no window, and works for plugins whose UI exposes nothing to Accessibility (Decapitator, Trilian, ...) — it selects the strip and enters plugin edit mode. That route is PAGE-CAPPED: `truncated: true` with `pages` and `pages_total` means parameters were left unread — raise max_pages or treat the list as partial, never as the plugin's whole parameter set."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "window_title": ["type": "string", "description": "Accessibility route: exact Logic plugin window title, usually the track name. The window must already be open (logic_open_plugin)."],
                        "track_name": ["type": "string", "description": "Control-surface route: the strip the plugin sits on. With insert_slot, this is the route that needs no window."],
                        "track_number": ["type": "integer", "description": "Tracks only; disambiguates two headers sharing a name."],
                        "insert_slot": ["type": "integer", "minimum": 1, "maximum": 8, "description": "Names the plugin on the control-surface route." + Tool.mcuInsertSlotNote],
                        // No minimum on max_pages: the handler deliberately
                        // clamps 0 up to 1 rather than refusing it.
                        "max_pages": ["type": "integer", "description": "Control-surface route only: page cap, default 12 (each uncached page costs ~1.7 s; large instruments have 80+). pages_total and truncated report what was left out."],
                        "route": [
                            "type": "string",
                            "enum": ["auto", "ax", "mcu"],
                            "description": "'auto' (default) picks by argument: window_title means ax, track_name + insert_slot means mcu, and both means ax with an mcu fallback. 'ax' or 'mcu' forces one and refuses rather than falling back."
                        ]
                    ],
                    "additionalProperties": false
                ],
                // Not read-only: the mcu route selects the strip and enters
                // plugin edit mode. The ax route alone changes nothing.
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleListPluginParameters
            ),
            Tool(
                name: "logic_list_events",
                title: "List a region's MIDI events",
                description: "Read the MIDI events of a region out of Logic's Event List (View > List Editors > Event) — position, type, pitch, velocity and length, as Logic's own cells print them. This closes the asymmetry where logic_record_midi could WRITE MIDI that nothing could read back. SCOPE, and it matters: the Event List shows the SELECTED region (or the selected track's region at the playhead), never the project's MIDI as a whole — pass track_name (plus region_name and/or start_bar) to select one first, or select with logic_select_region and call this with no arguments to read whatever is showing. An EMPTY list means nothing is selected, not that the project has no MIDI, and the result says so. Every row carries Logic's published columns verbatim plus parsed bar/beat/pitch/velocity/length where the columns were recognised. The row count is cross-checked against the list's own 'Number of Items' and a mismatch REFUSES rather than returning a truncated take on the region (an AX table publishes only realised rows). Opens the List Editors pane if it was closed, restores the previously selected tab, and closes what it opened.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Select this track's region first (exclusive selection). Omit to read whatever is currently selected."],
                        "region_name": ["type": "string", "description": "With track_name: which region."],
                        "start_bar": ["type": "integer", "description": "With track_name: the region's current start bar."],
                        "limit": ["type": "integer", "description": "Maximum events in the result, default 500. The full count is always reported as event_count."]
                    ],
                    "additionalProperties": false
                ],
                // Not read-only: with track_name it CHANGES the region
                // selection, and it toggles a UI pane.
                safety: .write,
                mayWarn: true,
                idempotent: true,
                handler: MCPServer.handleListEvents
            ),
            Tool(
                name: "logic_edit_event",
                title: "Edit one MIDI note",
                description: "Fix ONE MIDI note in place — its pitch, velocity, position or length — or delete it, or add one, through Logic's Event List. This is the SURGICAL editor, not a composer: logic_record_midi plays a whole part in and is the tool for writing music, while this one is for the single flubbed note in a take you want to keep. SCOPE: the Event List edits the SELECTED region — pass track_name (plus region_name and/or start_bar) to select one first, or select with logic_select_region — and read the region first with logic_list_events, because that is where the addresses come from. ADDRESSING: bar plus pitch, because a chord publishes several rows on the same position; add beat/division/tick to narrow further. An address that matches two events REFUSES with both listed rather than editing the nearer one. MOVING a note: any to_* field you leave out keeps its current value, so to_beat alone moves the note without quantizing its sub-beat feel. Compare-and-set with expected_current_velocity and expected_current_length; an edit that asks for what is already there is a verified no-op (state 'already_set') and presses nothing. VERIFICATION, every time: the list is re-read and must show the event count the action implies, the event reading exactly what was asked, and EVERY OTHER EVENT UNTOUCHED — a write that disturbed a neighbour comes back with a warning naming which. WORTH KNOWING: every cell is a one-step-per-write stepper, so a big velocity or pitch move costs a few seconds; the table RE-SORTS on every position and pitch write, so row numbers from an earlier read are stale; and Logic's 'Create new Event' places the note at the PLAYHEAD, which this tool parks and then corrects. REFUSED: writing while the Event List is showing the project's REGIONS instead of a region's events (nothing there is editable); a row that is not a Note, because Logic's Num/Val columns mean controller number and value there; creating a duplicate of a note already at that position and pitch, which nothing could address afterwards; and creating OUTSIDE the selected region's bars, because Logic adds the note and does not grow the region, leaving an event that exists and never sounds. NOT writable from this plane at all: the Status column (an event's type) and the MIDI channel.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["set", "create", "delete"],
                            "description": "'set' edits an existing note, 'create' adds one, 'delete' removes one."
                        ],
                        "track_name": ["type": "string", "description": "Select this track's region first (exclusive). Omit to edit whatever region is showing."],
                        "region_name": ["type": "string", "description": "With track_name: which region."],
                        "start_bar": ["type": "integer", "description": "With track_name: the region's current start bar."],
                        "bar": ["type": "integer", "minimum": 1, "description": "The event's bar (for 'create', the bar to put it on). Required."],
                        "beat": ["type": "integer", "minimum": 1, "description": "The event's beat within the bar. Narrows the address; for 'create' it is where the note goes (default 1)."],
                        "division": ["type": "integer", "minimum": 1, "description": "Third position field. Narrows the address; for 'create', default 1."],
                        "tick": ["type": "integer", "minimum": 1, "description": "Fourth position field. Narrows the address; for 'create', default 1."],
                        "pitch": [
                            "type": ["string", "integer"],
                            "description": "For 'set'/'delete': WHICH note at that position, which is how a chord is told apart. For 'create': the note to make. A MIDI number 0-127 or Logic's own name, where C3 is middle C (60): 'D#2', 'A♯2', 'C3'."
                        ],
                        "new_pitch": [
                            "type": ["string", "integer"],
                            "description": "Transpose the addressed note to this pitch. Same spelling as pitch."
                        ],
                        "velocity": ["type": "integer", "minimum": 1, "maximum": 127, "description": "The new velocity (1-127)."],
                        "length": ["type": "string", "description": "The new length in Logic's own 'bars beats divisions ticks' spelling — the text logic_list_events prints. '0 1 0 0' is a quarter note."],
                        "to_bar": ["type": "integer", "minimum": 1, "description": "Move the note to this bar. Omitted position fields keep their current value."],
                        "to_beat": ["type": "integer", "minimum": 1, "description": "Move the note to this beat."],
                        "to_division": ["type": "integer", "minimum": 1, "description": "Move the note to this division."],
                        "to_tick": ["type": "integer", "minimum": 1, "description": "Move the note to this tick."],
                        "expected_current_velocity": ["type": "integer", "description": "Compare-and-set: the velocity you believe the note carries. A mismatch refuses and writes nothing."],
                        "expected_current_length": ["type": "string", "description": "Compare-and-set on the length, in the same four-field spelling."]
                    ],
                    "required": ["action", "bar"],
                    "additionalProperties": false
                ],
                // Writes MIDI into the user's region. Idempotent by
                // construction on 'set' (the arguments name absolute values)
                // and refused rather than repeated on 'create'.
                safety: .write,
                mayWarn: true,
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleEditEvent
            ),
            Tool(
                name: "logic_markers",
                title: "Read and write markers",
                description: "Markers: list, create, goto, rename or delete them. 'list' reads Logic's Marker List (View > List Editors > Marker) with each marker's bar and name. 'create' fires Logic's own Create Marker key command at the PLAYHEAD (pass bar to park the playhead there first) and verifies against a fresh read of the list; note that Logic's position stepping lands inside the bar rather than exactly on its line, so a marker can sit a fraction of a beat late. 'goto' parks the playhead at a named marker's bar. 'delete' uses the list row's own Delete action and verifies the marker is gone (Undo restores it). 'rename' writes the row's name cell IF Logic publishes a settable one and REFUSES with the reason if not — the Tempo List's cells turned out to be steppers rather than fields, so this is checked at runtime rather than assumed. Address a marker by name (exact, case-insensitive — never fuzzy, because renaming or deleting the wrong marker is silent damage) or by bar; ambiguity refuses with the candidates listed.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["list", "create", "goto", "rename", "delete"],
                            "description": "Default 'list'."
                        ],
                        "name": ["type": "string", "description": "Which marker (exact name), for goto/rename/delete. For 'create': the name to give it, applied as a separate write that is reported separately."],
                        "bar": ["type": "integer", "description": "Which marker (its bar), for goto/rename/delete. For 'create': park the playhead at this bar first."],
                        "new_name": ["type": "string", "description": "Required for action 'rename'."]
                    ],
                    "additionalProperties": false
                ],
                // 'list' and 'goto' change nothing durable, but 'create' and
                // 'delete' do; the flag describes the tool.
                safety: .destructive,
                mayWarn: true,
                handler: MCPServer.handleMarkers
            ),
            Tool(
                name: "logic_list_signatures",
                title: "List time signatures",
                description: "Read the project's time signatures out of Logic's Signature List (View > List Editors > Signature): each signature, the bar it starts on, and its bar length in QUARTER-note beats (what Logic's BPM counts — 6/8 is three beats a bar, 7/8 three and a half). This is the meter map, the last assumption that was left in this server's bar math after the tempo map landed. HOW IT IS USED: a map with more than one bar length is INTEGRATED by every tool that converts bars to seconds itself (logic_render_track's slice, logic_evaluate_change method 'render', logic_record_midi's note placement and verification slice, logic_record_automation's point placement) — those results then carry a meter_map block and a warning, and an explicit beats_per_bar argument no longer overrides the project's own grid. A map with ONE bar length is reported and deliberately not used, so a constant-meter project's boundaries are bit-for-bit what they have always been. The Signature List also holds KEY signatures; those rows are counted for the truncation cross-check and skipped. Read cost ~2 s, no playhead movement, cached per project.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                // Not read-only: it toggles the List Editors pane and switches
                // a tab (both restored).
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleListSignatures
            ),
            Tool(
                name: "logic_set_insert_bypass",
                title: "Bypass an insert",
                description: "Bypass or un-bypass one insert — the fastest honest A/B in mixing, and the write side of the bypass state logic_list_inserts has always been able to READ. Address the insert by plugin_name, by insert_index, or both (both is safest: a name that does not match the slot at that index is refused). insert_index is the ACCESSIBILITY ordinal from logic_list_inserts, NOT the Mackie insert_slot the logic_mcu_* tools take. Compare-and-set with expected_current_bypassed; an insert already in the requested state is a verified no-op (state: \"already_bypassed\" / \"already_active\") rather than a blind toggle, because this control publishes only AXPress and no absolute write. Verified by re-reading the same checkbox. Pass expected_current_bypassed anyway; it is what turns a stale idea of the state into a refusal instead of a wrong toggle."
                    + Tool.stripAddressingAXNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer", "description": "Disambiguates duplicate track names; tracks only."],
                        "plugin_name": ["type": "string", "description": "Plugin display name as logic_list_inserts shows it; truncated names such as 'Space D' match by prefix."],
                        "insert_index": ["type": "integer", "description": "1-based." + Tool.axInsertIndexNote],
                        "bypassed": ["type": "boolean", "description": "true bypasses the plugin, false makes it active again."],
                        "expected_current_bypassed": ["type": "boolean", "description": "Abort with precondition_failed unless the insert is currently in this state."]
                    ],
                    "required": ["track_name", "bypassed"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleSetInsertBypass
            ),
            Tool(
                name: "logic_set_mixer",
                title: "Open or close the Mixer",
                description: "WINDOW MANAGEMENT: opens or closes the Mixer WINDOW (Window > Open Mixer), verified against the window list. It does not set any mixer VALUE - faders, pans, mutes and sends are logic_set_track_volume, logic_set_track_pan, logic_set_track_mute/solo and logic_mcu_set_send, none of which need this window. Returns state already_open / already_closed when the window is already the way you asked for. WHAT THE MIXER DOES AND DOES NOT DO (measured, not hoped): the Mixer window publishes EVERY channel strip to Accessibility - the result lists them in `mixer_strips`, Master, Stereo Out and the auxes included - but they are NOT inspector strips, and the Accessibility strip tools (logic_list_inserts, logic_survey_plugins, logic_open_plugin, logic_plugin_preset, logic_set_insert_bypass) still cannot address them: with the Mixer open, logic_list_inserts on Master fails exactly as it does with the Mixer closed. `inspector_strips` is the list those tools CAN reach (the selected track and its output). For Master, an aux or a bus, use the logic_mcu_* tools, which never needed a window. AND IT COSTS SOMETHING: the Mixer is a second document window carrying the same project, so it can shadow the project window - while Logic is in the background it may be the only window Accessibility publishes, and then every track-header read fails. This server skips Mixer windows when it resolves the project window, but close the Mixer when you are done anyway. What it is genuinely good for: putting the Mixer in front of a HUMAN, and reading the complete strip census out of the window.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "open": ["type": "boolean", "description": "true opens the Mixer, false closes it."]
                    ],
                    "required": ["open"],
                    "additionalProperties": false
                ],
                safety: .write,
                mayWarn: true,
                idempotent: true,
                handler: MCPServer.handleSetMixer
            ),
            Tool(
                name: "logic_set_plugin_parameter",
                title: "Set a plugin parameter",
                description: "Set ONE plugin parameter, verified by readback. START HERE: `{track_name, plugin_name, parameter, target_value}` is the whole call — \"more bass around 500 Hz\" is logic_set_plugin_parameter {track_name: \"Bas\", plugin_name: \"Channel EQ\", parameter: \"Pea2Ga\", target_value: \"4.9\"}, with no logic_list_inserts and no logic_list_plugin_parameters in front of it. The tool finds the insert itself from the strip's own insert list and reports which one it used in `resolved_slot`; pass insert_slot instead when you already know the physical slot, or to pick between two copies of the same plugin. ONE tool, TWO routes, and `route_used` says which ran. track_name + plugin_name (or insert_slot) is the CONTROL-SURFACE route: host automation (MCU vpot) with the LCD value echo as readback — it reaches EVERY plugin, custom-UI third-party included, needs no window, converges numeric targets adaptively, steps text targets (e.g. 'On', 'B') until exact match, matches the parameter against the MCU's abbreviated names ('Thrs' matches 'Threshold'), and rolls back on failed verification; expected_current_value is optional there. Pass window_title instead for the ACCESSIBILITY route: the parameter's formatted text field is written and read back, and the prior value is restored on verification failure; it needs expected_current_value (compare-and-set) and only reaches parameters logic_list_plugin_parameters marks `ax_writable`. Give BOTH and a knob-only plugin no longer dead-ends: the write starts on the Accessibility route and falls back to the surface when the parameter publishes no field, reporting route_used 'mcu' and fallback_from 'ax'."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "window_title": ["type": "string", "description": "Accessibility route: exact plugin window title, usually the track name. The window must already be open (logic_open_plugin)."],
                        "track_name": ["type": "string", "description": "Control-surface route: the strip the plugin sits on."],
                        "track_number": ["type": "integer", "description": "Tracks only; disambiguates two headers sharing a name."],
                        "plugin_name": ["type": "string", "description": "Control-surface route, and the one-call way in: name the plugin ('Channel EQ', 'Compressor') and the tool resolves the insert slot itself from the strip's insert list, reporting it as resolved_slot. Matched against the LCD's 6-character abbreviation, so 'Channel EQ' finds 'Cha EQ'. Two inserts answering to the name is reported as ambiguous with the slot numbers, never guessed — pass insert_slot to choose."],
                        "insert_slot": ["type": "integer", "minimum": 1, "maximum": 8, "description": "Names the plugin on the control-surface route by physical slot, when you already know it or need to pick between two copies of the same plugin. plugin_name is the cheaper way in and costs no extra call." + Tool.mcuInsertSlotNote],
                        "parameter": ["type": "string", "description": "Parameter name as the plugin spells it - an EQ band's Frequency or Gain, a compressor's Threshold or Ratio, a reverb's Mix."],
                        "target_value": ["type": "string", "description": "Value to write, in the parameter's own units - '500 Hz', '2.0 dB', 'On'."],
                        "expected_current_value": ["type": "string", "description": "Compare-and-set. REQUIRED on the ax route (it is that route's whole safety contract); optional on the mcu route, which verifies by LCD echo."],
                        "tolerance": ["type": "number", "description": "Control-surface route only: accepted deviation for a numeric target, in the parameter's own units."],
                        "route": [
                            "type": "string",
                            "enum": ["auto", "ax", "mcu"],
                            "description": "'auto' (default) picks by argument: window_title means ax (falling back to mcu when the surface arguments are there and the parameter is not ax_writable), track_name + plugin_name/insert_slot means mcu. 'ax' or 'mcu' forces one and refuses rather than falling back."
                        ]
                    ],
                    "required": ["parameter", "target_value"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleSetPluginParameter
            ),
            Tool(
                name: "logic_list_strips",
                title: "List every channel strip",
                description: "The CENSUS: every channel strip the control surface can reach, in project order — audio and instrument tracks, auxes, buses, the output and the master. Unlike logic_list_tracks, which can only see the track headers Logic has currently RENDERED (19 of 25 strips on the reference project), this walks the surface's banks, so nothing is hidden by scrolling or by a collapsed stack. Each row carries the strip's position, its bank/channel address and Logic's own 6-character LCD name cell; track_name and track_number are filled in only where exactly one rendered track header abbreviates to that cell, and everything else is reported as kind 'unresolved' (an output/aux/bus, a track scrolled out, or two tracks that share a name) rather than guessed at. Address strips by their full Mixer name, never by the abbreviation. Always walks the surface fresh — a census that could be stale would be the very failure this tool exists to fix — which costs a few seconds and refreshes the bank map every other control-surface tool uses.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                // Not read-only: banks the surface and leaves it in the pan
                // view. Nothing in the project changes.
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleListStrips
            ),
            Tool(
                name: "logic_mixer_snapshot",
                title: "Snapshot the whole mixer",
                description: "The whole mixer in ONE call, off Logic's own control-surface feedback: per strip the fader value in dB, pan, mute/solo/select/record-arm state and the raw 14-bit fader echo. volume_db is the dB string Logic paints in its channel-strip Volume view — the same readout logic_set_track_volume converges against — NOT a conversion of the fader position, which is reported separately and raw as fader_14bit; a cell that does not parse comes back null with the LCD text beside it, never interpolated. record_armed is sampled across a full blink cycle because Logic FLASHES an armed strip's record LED (~640 ms on / 640 ms off, measured), so a single instant would report half the armed strips as unarmed. Two bank walks (names and pan, then dB and LEDs), about 16 s on a 25-strip project; the surface is left in the pan view at the leftmost bank."
                    + " Strip identity is established by a fresh scan, never from the cached bank map, and follows the same track_name/'unresolved' rule as logic_list_strips."
                    + " METERS: where the bridge daemon publishes it, each strip also carries meter_level (0-12) and meter_overload — Logic's OWN control-surface meter, the segment count it would light on a Mackie Control. That is a state read of a value Logic published, exactly like the fader echo; it is NOT an audio measurement, has no dB calibration, and must never be reported as loudness. MEASURED: Logic does NOT feed this virtual surface meters during playback in the default Control Surfaces configuration — 8 s of rolling transport through real audio produced zero meter events (a handful of 0xD0 bytes arrive sporadically at idle, all level 0). Expect meter_level to be 0/absent until a way to enable Logic's MCU meter mode is found (candidate: the Mackie Control device's settings in Control Surfaces Setup — an open research item). Each bank is sampled at a different instant during the walk, so any values are eight-strip snapshots rather than a comparison across the mixer. When the running daemon predates this feature the fields are ABSENT rather than zero and meter_feed says 'unavailable'.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                // Not read-only: banks the surface and switches its view.
                safety: .write,
                mayWarn: true,
                idempotent: true,
                handler: MCPServer.handleMixerSnapshot
            ),
            Tool(
                name: "logic_set_track_record_arm",
                title: "Arm a track to record",
                description: "Arm or disarm a track for recording — the control surface's rec/ready button (MCU note 0x00-0x07), verified by Logic's own record LED AND, independently, by the track header's Record Enable checkbox. Compare-and-set: a track already in the requested state is reported as state: \"already_armed\" / \"already_disarmed\" and nothing is pressed. `cross_check` names the SECOND, independent source: \"ax_record_enable_checkbox\" (the track header agreed), \"disagreed\" (it did not - treat the arm state as unknown and re-read) or \"unavailable\" (no track header could be read, so the surface's LED is the only evidence). Logic FLASHES the record LED of an armed strip (~640 ms on / 640 ms off), so the LED evidence is a window rather than an instant: seen lit once means armed, and only a whole quiet window is read as disarmed. Several tracks can be armed at once, so arming one does NOT disarm another — read logic_mixer_snapshot before rolling if that matters. Output, aux, bus and master strips have no record enable and are refused before anything is pressed. Needs the MCU bridge: there is no Accessibility-only route.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Exact track name as Logic shows it (not the 6-character LCD abbreviation)."],
                        "track_number": ["type": "integer", "description": "1-based track number; disambiguates duplicate track names."],
                        "enabled": ["type": "boolean", "description": "true arms the track, false disarms it."]
                    ],
                    "required": ["track_name", "enabled"],
                    "additionalProperties": false
                ],
                safety: .write,
                mayWarn: true,
                idempotent: true,
                handler: MCPServer.handleSetTrackRecordArm
            ),
            Tool(
                name: "logic_set_metronome",
                title: "Set the metronome",
                description: "Turn the metronome click on or off via the control surface's click button, verified by reading the control bar's own Metronome Click checkbox back (the same field logic_get_transport reports), with the surface's click LED as a second source. Compare-and-set: already-correct is reported as state: \"already_on\" / \"already_off\" and nothing is pressed; a press that does not land is undone. Count-in is a separate setting and is not touched.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "enabled": ["type": "boolean"]
                    ],
                    "required": ["enabled"],
                    "additionalProperties": false
                ],
                safety: .write,
                mayWarn: true,
                idempotent: true,
                handler: MCPServer.handleSetMetronome
            ),
            Tool(
                name: "logic_load_instrument",
                title: "Load an instrument",
                description: "Load a software instrument into a track's INSTRUMENT slot — mouse-free via the control surface's instrument browser (the IN bank view's vpot), the slot logic_add_plugin cannot reach because it fills an insert instead. One vpot tick per browser entry, the shown entry re-verified after settling, and a vpot press instantiates; leaving the view cancels a browse without loading anything. Entries carry Logic's channel format ('Drum Kit Designer Stereo', 'Drum Kit Designer Multi-Output', 'Abbey Road Saturator (m) Mono'), so instrument may be given bare or with the format, or the format passed separately; matching is case-insensitive and exact on the name — a near miss is refused with the entries seen, never guessed at. Verified by the instrument slot's own name in the IN bank view; read the loaded instrument's parameters with logic_mcu_instrument_parameters as an independent second look. REPLACES any instrument already on the track, settings and all — Logic's Undo is the only way back.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Software-instrument track to load onto."],
                        "instrument": ["type": "string", "description": "Instrument name as Logic's browser shows it, e.g. 'Drum Kit Designer', 'Sampler', 'Analog Lab V'. May include the format ('Drum Kit Designer Stereo')."],
                        "format": ["type": "string", "description": "Channel format to pick when a plugin offers several: 'Stereo', 'Mono' or 'Multi-Output' (Logic also spells that last one 'Multi Output'). Matched case-insensitively against the suffix Logic puts on the browser entry. Default: the first entry whose name matches, and the result reports which format that was."],
                        "max_steps": ["type": "integer", "description": "How many browser entries to step through before giving up, default 1200 (~0.11 s each, so a full sweep of a large plug-in library can take a couple of minutes). The list holds every installed instrument in every channel format and is NOT alphabetical, so a 'never showed' refusal at a low cap usually means the browse had not reached it yet, not that the name is wrong."],
                        "expected_project_path": ["type": "string", "description": "Refuse unless this is the open project."]
                    ],
                    "required": ["track_name", "instrument"],
                    "additionalProperties": false
                ],
                // Replaces whatever instrument the track had, with its settings.
                safety: .destructive,
                mayWarn: true,
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleLoadInstrument
            ),
            Tool(
                name: "logic_read_automation",
                title: "Read an automation curve",
                description: "READ an existing automation curve before you overwrite it — volume, pan, a send level or any plugin parameter — over a bar range. NOTHING IN THE PROJECT CHANGES: no automation mode is switched, no fader or vpot is moved, and the playhead is put back where it started (`playhead_restored` says whether that worked). It is not free of side effects, though, which is why it is not flagged read-only: it SELECTS the strip it reads and leaves the control surface in its Pan view. Mechanism: park the playhead at each sampled position and read the value Logic chases the lane to, which is the verification pass logic_record_automation already runs, with the writing half removed. HONESTY: these are SAMPLES, not the lane's breakpoints — a move that happens entirely between two samples is invisible, so lower resolution_beats when the shape matters — and an unautomated lane reads as a flat line at the track's static value, which the result says rather than implying a curve exists. Positions run from start_bar beat 1 to end_bar beat 1 inclusive; if the grid would exceed max_points the step is widened rather than the range truncated. Costs roughly a second per sampled position.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "parameter": [
                            "type": "string",
                            "enum": ["volume", "pan", "send", "plugin"],
                            "description": "What to read. 'send' also needs send; 'plugin' also needs insert_slot and plugin_parameter. Default 'volume'."
                        ],
                        "send": ["type": "integer", "minimum": 1, "maximum": 8, "description": "Send slot 1-8, required when parameter is 'send'."],
                        "insert_slot": ["type": "integer", "minimum": 1, "maximum": 8, "description": "Required when parameter is 'plugin'." + Tool.mcuInsertSlotNote],
                        "plugin_parameter": ["type": "string", "description": "Parameter name as shown on the MCU, required when parameter is 'plugin'."],
                        "start_bar": ["type": "integer", "minimum": 1],
                        "end_bar": ["type": "integer", "minimum": 1, "description": "INCLUSIVE here, unlike the render and bounce ranges: the last sampled position is this bar's beat 1. Must be >= start_bar."],
                        "resolution_beats": ["type": "integer", "minimum": 1, "description": "Beats between samples, default 1 (whole beats only — the playhead is parked on the beat grid)."],
                        "max_points": ["type": "integer", "minimum": 1, "maximum": 200, "description": "Cap on sampled positions, default 64. Exceeding it widens the step; the range is never truncated."],
                        "settle_seconds": ["type": "number", "description": "How long to let Logic's echo settle at each position, default 0.8 s. Raise if values look like the previous position's."]
                    ],
                    "required": ["track_name", "start_bar", "end_bar"],
                    "additionalProperties": false
                ],
                // Not read-only: selects the strip, switches the surface view
                // and moves the playhead (restored). Nothing in the project
                // changes.
                safety: .write,
                mayWarn: true,
                idempotent: true,
                handler: MCPServer.handleReadAutomation
            ),
        ]
    }

    /// The `include_audio` opt-out, declared identically by every tool that
    /// can attach an MCP audio block (logic_bounce_range, logic_render_track,
    /// logic_evaluate_change, logic_get_audio_clip). Default TRUE: hearing the
    /// result is the point of this server, and a client that forwards audio
    /// blocks must keep getting them. false is for the other kind of client —
    /// one that stringifies content blocks it does not know, where 300-800 KB
    /// of base64 is a context overflow rather than a sound. Honoured centrally
    /// in `toolResult`, so it holds for every audio-carrying tool at once.
    /// Computed, not a stored static: `[String: Any]` is not Sendable, and a
    /// schema fragment is cheap to rebuild.
    static var includeAudioProperty: [String: Any] { [
        "type": "boolean",
        // The reasoning — what passing false actually costs you, and how to
        // listen without the blocks — is the instructions' AUDIO RESULTS
        // paragraph, sent once per session instead of four times per list.
        // Said here rather than in four descriptions: the link is the reason
        // false is no longer a dead end.
        "description": "Attach the rendered audio as MCP audio content blocks, default true — see AUDIO RESULTS in the server instructions before passing false. Either way the result carries a resource_link to logician://captures/<filename>, so false still leaves you able to fetch the audio with resources/read."
    ] }

    /// The `blind: true` opt-in, declared identically by the three tools whose
    /// results carry audio AND measurements of it (logic_bounce_range,
    /// logic_render_track, logic_evaluate_change). What it withholds, what it
    /// deliberately keeps and why the seal is a file rather than a key is the
    /// `Blind` type's documentation; the workflow it belongs to is the
    /// instructions' LISTENING paragraph, so this says the minimum and points
    /// there. Computed for the same reason as `includeAudioProperty`:
    /// `[String: Any]` is not Sendable.
    static var blindProperty: [String: Any] { [
        "type": "boolean",
        "description": "LISTEN FIRST: withhold this result's measurements of the audio — peak/RMS metrics and, for an A/B, the dB deltas — so the only thing left to describe the sound from is the sound. The audio blocks, every file path, `success`, `verified`, `state` and any `warning` all still come back untouched, and the withheld keys are sealed into the JSON file named by `sealed_metrics_path`, which you open AFTER writing down what you heard (nothing is re-rendered). Default false. If you can receive audio, pass true on your FIRST listen of any material — see LISTENING in the server instructions."
    ] }

    /// What `tools/list` puts on the wire, derived from the registry —
    /// never a second list that could drift from it. Filtered to the active
    /// toolsets (`--toolsets`), which by default is all of them.
    func toolDefinitions() -> [[String: Any]] {
        activeTools().map(\.definition)
    }
}
