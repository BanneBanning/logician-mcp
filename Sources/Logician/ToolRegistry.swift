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
                description: "Check that Logic Pro is ready and set up, without changing anything: the process, the open project, Accessibility trust, the MCU bridge daemon (started here when it is down), the registered key commands, and Logic's UI LANGUAGE. Read-only in the strict sense - it reads the control surface, it never moves it, and a session that only ran this tool leaves the surface exactly where the user had it. It names the fix for whatever is missing. `key_commands` is a COUNT (`registered` of `of`, plus `all_registered`); the names appear only in `missing`, when some are, alongside `key_commands_fix`. When `mcu_connected` is false the fix names any dialog Logic had open at that moment and lists them in `open_dialogs`: a modal alert stops Logic feeding the control surface, which looks identical to a surface that was never set up, and the two have nothing to do with each other. `logic_ui_language` is an INFERENCE, never a measurement: macOS publishes no way to ask a running application which language it is drawing in, so the answer is Logic's app bundle's localizations matched against the language preference order that applies to it - the same choice Logic makes when it launches - and a Logic that has been running since before a language change is still showing the OLD language. `determined_by` carries the evidence for whichever verdict came back. When it is not English the result also carries a top-level `language_note`, one line pointing at the full plane-by-plane account in `logic_ui_language.language_note`: the Accessibility plane matches some of Logic's own English words, while the control-surface plane speaks MIDI and is unaffected.",
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
                description: "List Logic windows with subrole and project document path, read-only. `kind` is derived from the SUBROLE, never from the document, because carrying the project document is neither necessary nor sufficient for being the project window: 'project' (AXStandardWindow with a document), 'mixer' (the same, titled '<project> - Mixer: …' - a SECOND document window that can shadow the project window; close it with logic_set_mixer), 'standard' (AXStandardWindow, no document), 'plugin_or_auxiliary' (AXDialog - the only kind logic_close_plugin_window will close, INCLUDING document-carrying ones such as Drum Machine Designer) and 'other'. Each entry also reports `default_button` and `cancel_button` - the titles of whatever the window publishes as its Return and Escape buttons. Those are LOCALE-INDEPENDENT addresses (this server presses them before it ever matches an English button title), and `null` means the window publishes none, so answering it needs the title.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleListWindows
            ),
            Tool(
                name: "logic_list_tracks",
                title: "List tracks",
                description: "List the track headers currently rendered in the Tracks area (track number, name, selected), read-only. THIS LIST CAN BE INCOMPLETE AND SAYS SO: Accessibility publishes only the rows Logic has rendered, so the result carries `partial` (true when rows are PROVABLY missing), `partial_evidence` (one sentence per signal: headers scrolled out above, gaps in the numbering, collapsed track stacks, a scrollable Tracks area), `missing_track_numbers` where the numbering names them, and `completeness` ('partial' or 'unknown'). There is no 'complete' verdict, because a row Logic has not rendered publishes nothing at all - `partial: false` means nothing proved any missing, never that this is every track. When a run of missing numbers begins immediately after a COLLAPSED stack, `hidden_by` names that stack: expand it with logic_set_track_stack and those tracks appear. `scroll_signal` says what Logic's own scroll bar reported, and it is usually `unavailable` - Logic publishes no scroll bar on the Tracks area, so rows BELOW the last one listed, with no gap in the numbering to give them away, leave no evidence here at all. Rows omit `selected` and `is_stack` when false. Do not build a mental model of the project on this alone. Output/aux/bus strips (Stereo Out, Master, Aux 1, buses) have no track header and are NEVER listed here, yet the mixing, send and plugin tools accept their names.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleListTracks
            ),
            Tool(
                name: "logic_track_info",
                title: "Read a track's full state",
                description: "What each track IS, beyond its name: type, output routing, input, group, monitoring, automation mode, instrument, inserts and sends — everything Logic's track header and inspector channel strip publish. This is the orientation read logic_list_tracks cannot give you: it answers 'is this an audio track or a software instrument', 'where does it go', 'is anything already grouped', 'what is on it' before you plan a single write. IT IS ALSO THE CHEAP SINGLE-TRACK MIX READ: each strip's current volume_db, pan, mute, solo and record_armed come back with it, so one track's fader state costs one call instead of logic_mixer_snapshot's two bank walks. COSTS A SELECTION, ~0.6 s per track it has to move to: Logic's left inspector shows the SELECTED track's strip and nothing else, so each track is selected in turn and the original selection is put back (selection_restored says whether it worked). Pass track_name for one, track_names for several, or all: true for every rendered header (mind logic_list_tracks' partiality — a track Logic has not rendered cannot be read here either). TWO TRACKS CAN SHARE A NAME, and rows are addressed by NUMBER throughout, so all: true reads each of them in its own right. A name carried by more than one row is REFUSED with those rows' numbers: pass track_number beside track_name to say which you mean. THREE THINGS THE RESULT MEANS. A field that is ABSENT (null) means Logic published nothing for it — never that it is off; `input: null` on a software instrument is a strip with no input slot, not an unrouted track. `kind` is INFERRED from which slots the strip publishes and `kind_evidence` says which: 'audio' (an Input slot), 'software_instrument' (a MIDI Effect slot), 'reduced' (no Output slot at all — measured on folder-stack main tracks, which publish only name/mute/solo/volume/automation/group), 'unknown'. And on a software instrument the INSTRUMENT slot carries the same bypass/open controls as an insert, so it appears in `inserts` too, flagged `is_instrument_slot` and named separately as `instrument`. Output/aux/bus strips (Stereo Out, Master, Aux 1) have no track header and cannot be read here; use logic_list_inserts route 'mcu' and logic_mixer_snapshot for those. THE INSPECTOR CAN BE HIDDEN, and this tool reads the strip out of it: when it is, the call shows it for the length of the call and puts it back (`inspector` says what it found, `inspector_shown_for_call` and `inspector_restored` say what it did about it). A strip that still could not be read comes back as null with a strip_note naming View > Inspector, never as an empty strip.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "One track, by its header name. Omit everything to read whichever track is selected."],
                        "track_number": ["type": "integer", "description": "Disambiguates two headers sharing a name. Pairs with track_name; refused with track_names."],
                        "track_names": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Several tracks, read in the order given. A name matching more than one row refuses the call and names their numbers."
                        ],
                        "all": ["type": "boolean", "description": "Read every rendered track header, each by its own number."]
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
                description: "Send a track's signal somewhere else: its OUTPUT (where the strip goes), its INPUT (what an audio track records from) and its GROUP, each written through Logic's own channel-strip slot and verified by reading the slot's label back. This is how 'group the drums to a bus' is done — set each drum track's output to 'Bus 4' and Logic creates the aux; logic_add_send is the parallel path, not the same one. DESTINATION NAMES are Logic's own menu titles, which it decorates with where they already lead ('Bus 2 → Aux 2' on the output side, 'Bus 2 ← Lofi Pad' on the input side): pass either form, since the HEAD ('Bus 2') is the identity and the arrow half is Logic explaining itself. Outputs also take 'Stereo Output' and 'No Output'; inputs 'Input 1', 'No Input' or a bus; groups 'No Group', 'Group 1', or the '(new)' item Logic offers. A name that matches nothing is REFUSED with the slot's actual menu listed rather than guessed at, and so is a name that is a CATEGORY in Logic's menu rather than a destination ('Mono' is one), because pressing a category opens a submenu and routes nothing. ALSO REFUSED, on purpose: a slot this strip does not publish (a software instrument has no input slot; a folder-stack main track publishes a reduced strip with no routing slots at all — logic_track_info's `kind` and `kind_evidence` say which you have), and any mismatch against expected_current, checked for EVERY named slot before the first one is written so a two-slot call cannot half-apply. CHANGING AN OUTPUT CHANGES WHAT YOU HEAR and can silence a track (route it to a bus with no aux behind it); the before value is always reported so it can be set straight back, and routing to a BUS makes Logic create the aux behind it, which routing away again does not remove (side_effect_note says so). The press that opens a slot's menu is INTERMITTENT and is retried; a call that still cannot open it fails having written NOTHING and is safe to retry, with `menu_route` naming which look found the menu when one did. Mechanism and measured costs: see the guide.",
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
                description: "List a strip's audio-effect insert slots (plugin display name, and bypass state on the Accessibility route). ONE tool, TWO routes, and `route_used` says which ran — with it the numbering the result carries. Route 'ax' reads the left inspector's channel strip and numbers the OCCUPIED slots as `index`, the insert_index logic_open_plugin / logic_close_plugin / logic_remove_plugin / logic_set_insert_bypass take; it needs the strip shown in an inspector. On a software instrument (or a summing track stack's main channel) the occupied INSTRUMENT slot has the exact same bypass/open shape as a real insert and is otherwise indistinguishable, so it is one more row here too — flagged `is_instrument_slot: true` (the same flag logic_track_info carries) so a reader can tell it from a real effect and reconcile the row count against route 'mcu', which never counts the instrument at all (measured live on `Drum Synth Kit`: 8 ax rows, one flagged, against 7 mcu inserts). Route 'mcu' walks the control surface's plugin list and numbers the PHYSICAL slots 1-8 as `slot`, the insert_slot every logic_mcu_* tool takes; it reaches every strip and every plugin, custom-UI third-party included, and it selects the strip first. Default 'auto' tries ax and falls back to mcu when the inspector cannot reach the strip. The two numberings are DIFFERENT and were observed reversed on an output strip — read `route_used`, use the number it gave you, and never convert one into the other."
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
                        "track_number": ["type": "integer", "description": Tool.regionTrackNumberNote],
                        "region_name": ["type": "string", "description": Tool.regionNameNote],
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
                        "expected_project_path": MCPServer.expectedProjectPathRefuseProperty
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
                description: "A/B A CHANGE AND HEAR BOTH VERSIONS: renders the mix as it is, applies exactly one verified plugin-parameter change, renders it again, rolls the change back and hands you both versions as audio plus the dB deltas between them. This is the tool for 'is this better?', and it takes 30-50 s. Three methods: 'render' (two dialog-free freeze renders of the SINGLE track, compared on the sliced bar range — fastest and most isolated; needs insert_slot, the MCU physical slot, and reaches every plugin including third-party), 'bounce' (two offline MASTER renders via the bounce dialog, needs plugin_name), and 'solo_bounce' (two offline bounces with this track soloed, solo restored after; needs insert_slot like 'render' — use it for the tracks freeze refuses, which are stack subtracks and tracks sharing a channel strip). A track that was ALREADY soloed elsewhere is not refused, because the deltas stay honest when both bounces carry it, but the result WARNS and `solo_context` names it: what you hear is then not this track alone. Every method returns the SAME keys — decision, change, range, deltas, baseline_metrics/after_metrics and the audio paths — and carries both versions as audio content blocks, baseline first. REFUSALS worth knowing. Method 'render' cuts its own slices, so where the Tempo List cannot be read and the tempo at the two ends of the range disagrees it refuses with precondition_failed and names 'bounce'/'solo_bounce', which hand Logic the bar numbers and are never sampled. Method 'bounce' writes the parameter through the plugin WINDOW, so it needs a plugin that publishes an editable field (`ax_writable` in logic_list_plugin_parameters) on a strip an inspector is showing: a knob-only plugin is refused BEFORE the baseline bounce, naming the surface route instead. That method is also the one that reaches a headerless strip ('Stereo Out', an aux, a bus), because it bounces the whole mix and needs no track selected; 'render' and 'solo_bounce' are track-only by nature. Mechanism and measured costs: see the guide.",
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
                        "expected_project_path": MCPServer.expectedProjectPathRefuseProperty,
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
                        "max_pages": ["type": "integer", "description": "Page cap, default 12 (a page this build has not read before costs ~2.1 s of Logic's own indicator fade; large instruments have 80+). The pages actually read are cached, so repeating the same call is cheap. pages_total and truncated report what was left out."],
                        "track_number": ["type": "integer"],
                        "expected_project_path": MCPServer.expectedProjectPathRefuseProperty
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
                        "tolerance": ["type": "number"],
                        "expected_project_path": MCPServer.expectedProjectPathRefuseProperty
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
                description: "Read the Mackie Control bridge's mirrored state: LCD text (track names/values as data), fader positions, transport LEDs, timecode display, online status, and the assignment display decoded (assignment_view, plus assignment_plugin_edit / assignment_send_view for the two standing view hazards). This is Logic's documented control-surface feedback channel — no UI, no focus, no windows involved. CHECK age_seconds: it is how many seconds ago this snapshot was taken. source: \"socket\" means the daemon computed it just now (age ~0); source: \"state_file\" means the daemon did not answer and this is the mirror it left on disk, which it rewrites only when Logic sends something — that mirror can be MINUTES old, and every field in it, assignment included, then describes the surface as it was, not as it is. Requires logic-mcu-bridge running and a Mackie Control configured in Logic pointing at the 'Logic MCP MCU' ports.",
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
                description: "RIDE a control across a bar range and leave a real automation curve behind — volume (the absolute fader), pan, a send level (send: 1-8) or ANY plugin parameter (insert_slot + plugin_parameter) — with no mouse and no automation-lane clicking. The track is switched to Latch, the moves are played in at the musical moments you give, the control and the mode are put back, and the curve is proved by REPLAYING the range and sampling Logic's own echo at every point. DESTRUCTIVE: a Latch pass OVERWRITES any automation already written across this range - read what is there first with logic_read_automation, because nothing but Undo puts it back. It also overwrites a FRACTION OF A BEAT IN FRONT of the range (~0.1 s), because Latch records from the moment the control is touched and the first value has to be armed just before the range for bar N beat 1 to carry it. TAKES REAL WALL-CLOCK TIME: the range is played through, twice with verification. The value scale follows the parameter: dB for volume/sends, -64..63 for pan, the plugin's own units otherwise. ramp (default true) interpolates between points. Points need bar >= 2 and carry value (or db for volume). IT REFUSES A ROLL IT CANNOT PLACE: Logic plays from its own last play-start position, not from the playhead this tool parked, so a roll that begins at or past the range is refused with nothing written and the refusal says how to move that position (click the ruler at the pre-roll bar, or play and stop once from there). roll_anchor names the bar the schedule was actually timed from, and a verification replay that could not run comes back as state 'recorded_unverified' rather than a plain 'recorded'. Mechanism, fader calibration and measured costs: see the guide.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer", "description": "Breaks a tie when several strips abbreviate alike on the control surface (duplicate track names) — the same numbers a matches-N-strips refusal names."],
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
                name: "logic_remove_automation",
                title: "Remove a track's automation",
                description: "Clear a track's recorded automation — the way back from a ride, and the one thing logic_record_automation cannot undo. DESTRUCTIVE AND TRACK-WIDE: Logic's own command clears EVERY lane on the addressed track — volume, pan, sends, plugin parameters — so read anything you want to keep with logic_read_automation first and re-record it. AND IT CAN CHANGE THE SOUND: Logic leaves the control where the automation last put it, not where it stood before the curve was written, so check the static value afterwards with logic_mixer_snapshot. PROVEN, NOT HOPED: the lane you nominate is read before the press (a curve has to actually be there) and again after (it has to be flat), and the result carries points_before, points_after, value_spread_before/after and verified. A lane that already reads flat comes back as already_empty with NOTHING pressed — a flat reading is what an unautomated lane and a perfectly flat curve both look like from here, and it says nothing about the track's other lanes, so pass force: true when you know better. IT REFUSES RATHER THAN GUESSES, and each refusal names the way round: scope 'lane', because Logic's per-lane command deletes whichever lane the automation view is SHOWING and nothing outside Logic can read that; a bar RANGE, because Logic's delete commands take a track and never a range (ride the old value across those bars with logic_record_automation instead); and scope 'project', because no readback here could prove what it destroyed. WHAT IT CAN ADDRESS is a TRACK ROW — Logic's command acts on selected TRACKS, so a mixer-only aux or bus is out of reach and is refused with the rendered rows named; logic_list_tracks is the list of what it can reach. An unrecognised dialog is CANCELLED, never answered. Mechanism and measured costs: see the guide.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "The track ROW to clear. Not a headerless strip: this route selects a track header."],
                        "track_number": ["type": "integer", "description": "Cross-check: a number that names a differently-named row refuses before anything is pressed."],
                        "scope": [
                            "type": "string",
                            "enum": ["track", "lane", "range", "project"],
                            "description": "Default 'track': every automation lane on the addressed track. The other three are refused with the reason and the alternative."
                        ],
                        "parameter": [
                            "type": "string",
                            "enum": ["volume", "pan", "send", "plugin"],
                            "description": "Which lane is READ as the proof, before and after. It is NOT a lane filter — the removal is track-wide whatever this says. Default 'volume'."
                        ],
                        "send": ["type": "integer", "minimum": 1, "maximum": 8, "description": "Send slot 1-8, when the proof lane is a send."],
                        "insert_slot": ["type": "integer", "minimum": 1, "maximum": 8, "description": "When the proof lane is a plugin parameter." + Tool.mcuInsertSlotNote],
                        "plugin_parameter": ["type": "string", "description": "Parameter name as shown on the MCU, when the proof lane is a plugin parameter."],
                        "verify_start_bar": ["type": "integer", "minimum": 1, "description": "First bar of the proof read. Default 2 (bar 1 is where a Latch pass cannot start)."],
                        "verify_end_bar": ["type": "integer", "minimum": 1, "description": "Last bar of the proof read. Default verify_start_bar + 2."],
                        "verify_resolution_beats": ["type": "integer", "minimum": 1, "description": "Beats between sampled positions. Default 4 — one a bar, which is enough to see a curve appear or vanish and costs ~1 s a point."],
                        "verify_max_points": ["type": "integer", "minimum": 2, "maximum": 32, "description": "Cap on sampled positions per read. Default 6."],
                        "tolerance": ["type": "number", "description": "How far the sampled values may spread and still count as flat, in the lane's own units. Default 0.05."],
                        "force": ["type": "boolean", "description": "Press even though the proof lane shows no curve — for a track whose automation is on a lane this call is not reading. Default false."],
                        "expected_project_path": ["type": "string"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                // Destructive: it removes existing work, and every lane on the
                // track rather than the one it reads back.
                safety: .destructive,
                mayWarn: true,
                // Clearing a cleared track changes nothing further; the second
                // call answers already_empty without pressing.
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleRemoveAutomation
            ),
            Tool(
                name: "logic_record_midi",
                title: "Record MIDI",
                description: "PERFORM a MIDI part onto an existing software-instrument track: the notes are streamed in real time over the dedicated 'Logic MCP MIDI In' port while Logic records them, so the take is audible as it happens and lands as a normal recorded region, with no dialogs and no files. THE SIBLING: logic_import_midi writes a whole multi-track arrangement as a Standard MIDI File and lets Logic import it - byte-exact, seconds rather than minutes, free of the Smart Tempo hazard below, and its `to_track` reaches an EXISTING track too; prefer it for anything longer than a few bars or wider than one track, and this one when the take should be heard as it is played. TAKES REAL WALL-CLOCK TIME: ~7 s of overhead plus (the take's bars + ONE pre-roll bar) played through, plus ~5 s more when the verification render runs. SMART TEMPO GUARD: a project tempo mode of ADAPT (or AUTO, which can resolve to Adapt) makes Logic rewrite the project's TEMPO MAP to follow the recording, so this refuses before arming and names the fix; when the mode cannot be read off the control bar the recording proceeds and the result carries a warning saying it went unverified. speed > 1 is REFUSED with precondition_failed on a non-constant tempo - speed mode overwrites the tempo slider and restores a single value, which cannot put a tempo map back; real-time recording (speed 1) touches no tempo and stays available. start_bar is 2 or later: one bar leads into it. THE RESULT NAMES YOUR TAKE: created_region {track_name, track_number, start_bar, end_bar, recorded_end_bar, delete_with} - remove it with logic_delete_region, NOT with Undo - and recorded_end_bar is past end_bar on purpose, because Logic keeps recording until the transport stops. THE PLAYHEAD IS PUT BACK: where you had it is read first and restored afterwards, verified against Logic's control bar and reported in `playhead` {restored | already_at_baseline | not_restored, bar, beat, left_at}; a failed restore WARNS and names where it was left. `verified` describes the RECORDING, while the freeze render that proves the notes sound is reported apart from it in verification_render - to HEAR the take, pass verification.rendered_slice to logic_get_audio_clip. Sync branches, tempo-map handling and measured costs: see the guide.",
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
                        "verify_render": ["type": "boolean", "description": "Default true: freeze-render the recorded bars afterwards and return slice metrics as proof (it moves the playhead again and restores it, so `playhead` in the result describes its outcome)."],
                        "speed": ["type": "number", "description": "Record at speed x tempo (1-8, default 1) and scale event times: the same bar positions in a fraction of the wall time, at the cost of timing precision and a chipmunked monitor."],
                        "sync_compensation_ms": ["type": "number", "description": "Timecode display latency subtracted in the beat-edge sync only; lower it if notes land late, raise it if they land early, and leave it out for the measured default (see the guide)."],
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
                description: "Compose a WHOLE ARRANGEMENT in one call - many named tracks at once - by generating a Standard MIDI File server-side and letting Logic import it. Nothing is played in real time, so sixteen bars cost the same as two and a fourth track is nearly free: a 4-track arrangement lands in about four seconds. THE SIBLING: logic_record_midi PERFORMS a part through an existing track's instrument in real time, so the take is audible as it happens; reach for this one for everything else. It also sidesteps the Smart Tempo hazard entirely - there is no recording pass, so an Adapt-mode project cannot rewrite its own tempo map. COMPOSE ONTO YOUR OWN TRACKS: give a `tracks[]` entry a `to_track` and that part ends up on the EXISTING track you name, playing through its instrument, because Logic's own importer can only ever make new tracks with default patches. Per track, not per call: route drums onto 'Drums' and bass onto 'Bas' in one import and leave a third entry unrouted to keep a new track. Destinations are resolved BEFORE the panel opens, so one that does not exist, is duplicated without `to_track_number`, or is a headerless output/aux/bus strip (no track lane for a region to sit on) is refused with the project untouched. If a move fails AFTER the import has landed, nothing is rolled back - some of the material would already be on your tracks - and the result is `state: 'partial'`, `restored: false`, with `remaining` naming every temp track and region still there. NAMES, and this surprises people: for an UNROUTED entry Logic names the new TRACK after whichever default patch it loads ('Studio Grand'), NOT after your track name - your names come back on the REGIONS, so follow up with logic_rename_track when the track names matter. A routed entry sidesteps that. Every event's `bar` is an ABSOLUTE project bar at or after `at_bar`. THE TEMPO PROMPT is owned by this tool and answered **No** by default, which leaves the project's tempo map byte-identical; `import_tempo: true` answers 'Import Tempo' instead and is DESTRUCTIVE - it replaces the project's tempo information in the range of the file and desynchronises previously recorded audio that is not in Flex mode. VERIFICATION is a census of the track count and the region list against a snapshot taken before the import; `verify: 'events'` additionally reads each new region's notes back and diffs them. A file Logic cannot read fails SILENTLY, so an unchanged census comes back as `success: false` with the counts as evidence, never as an empty success. CLEANUP CONTRACT: no panel, sheet or prompt is ever left standing, an alert whose grammar this server has not measured is REPORTED rather than pressed, and the generated .mid is removed again on every path (`file`, `file_removed`). Mechanism and measured costs: see the guide.",
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
                                        "description": "The EXISTING track this part should end up on, so it plays through that track's instrument instead of the default patch Logic picks for a new one; leave it out on any entry that should keep a new track of its own, and expect ~2.6 s per routed track."
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
                            "description": "The bar the arrangement's first bar lands on, default 1; the playhead is parked exactly here first (the call's most expensive step) because Logic imports at the bar line NEAREST the playhead. Every event's `bar` must be this bar or later."
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
                            "description": "'census' (default) proves the import by the track/region diff; 'events' additionally reads each new region's notes back and diffs them note for note (+3.9 s for one region), reporting anything unreadable as `verification: 'unverified'` rather than as a mismatch."
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
                description: "Browse and load a plugin's factory settings (presets) — the fastest way to a sound, and the read side is free. action 'list' enumerates the setting menu (every name, its category, and which one is marked as loaded) WITHOUT changing anything; 'select' loads one by name (bare 'Rock Bass' or qualified '03 Guitars/Rock Bass'), verified against the plugin window's setting label; 'step' walks next/previous N settings through Logic's topmost-plugin-window key command, the only route that needs no readable menu; 'undo' presses the setting menu's own Undo, which is the ONLY way back from a load and restores the parameter state rather than a name, so it also recovers a plugin that was on no named setting at all. WARNING: loading a setting overwrites EVERY parameter of the plugin, and a setting name is not a promise about the current state — unnamed tweaks on top of a named setting are lost, and re-selecting the old name does not bring them back. A 'select' whose setting the header ALREADY NAMES presses nothing and comes back state \"already_loaded_by_name\" — a NAME match, never a check of the parameters, which is what protects a tweak made on top of the setting; pass reload: true when you need the setting's own values loaded and verified. Honesty contract: 'list' returns presets: null plus a reason where the plugin's UI exposes no Logic setting pop-up (fully custom UIs) and presets: [] — an empty list, not a failure — for plugins that genuinely ship no factory settings, and 'step' reports success: false when the label did not move. Reading the menu needs Logic frontmost for a moment, and a plugin window this call opened is closed again. Mechanism and the way back: see the guide."
                    // The AX note alone, and the reason is the WINDOW, not
                    // the write: measured 2026-09-02, `list`, `select` and
                    // `undo` are pure Accessibility (a menu in the plugin
                    // window's header) and only `action: "step"` touches the
                    // control surface, as one key command. What every action
                    // shares is opening the plugin window, an Accessibility
                    // action on the strip — so this tool carries the strip
                    // limit, and saying both would be saying "see STRIP
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
                        "reload": ["type": "boolean", "description": "For action 'select', default false. Press the entry even when the plugin window's header already names it — the way to get a setting's OWN values back after tweaks were made on top of it. The default false is a name-match no-op (state \"already_loaded_by_name\") that leaves those tweaks alone; reload: true OVERWRITES every parameter of the plugin, exactly as any other load does."],
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
                description: "Rename a track by writing the channel strip's name field (element-addressed AX). VERIFIED BY ROW: the row you addressed must carry the new name character for character - so a rename that changes only the CASE ('Inst 2' -> 'INST 2') is a real rename and is proven as one, and a rename to the name the row already has fires nothing at all and comes back state 'already_named'. The result names the row afterwards: `renamed_track {track_number, track_name}` plus `previous_name` - address the track by BOTH of those next, because the old name no longer resolves. Pass track_number to rename ONE of two rows sharing a name (the state logic_duplicate_track leaves behind, and this is the way out of it); a new_name another row already carries is REFUSED for a name-addressed call, naming that row, rather than manufacturing a pair no name-addressed tool can reach - pass track_number to make such a pair deliberately (restoring one is a real move) and the result warns which other row shares the name. On a project that renders only part of its track list, a row scrolled out of view comes back state 'renamed_not_visible' with verified:false and a warning to scroll and re-read - it is NOT a claim that nothing happened, and a retry addressed to the old name will not find the row if it worked.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "new_name": ["type": "string"],
                        "track_number": ["type": "integer", "description": "Recommended for duplicate names - the only way to address one of two rows sharing a name."]
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
                description: "Duplicate a track, with its settings and its regions, via Logic's Duplicate Track key command (learned automatically). THE RESULT NAMES THE COPY: `duplicate {track_number, track_name}`, read off the row Logic selects - address the copy by BOTH of those fields. You cannot derive them: the copy lands directly BELOW the source and renumbers every track under it, and Logic gives it either the source's own name (which then matches two rows, and every track tool refuses an ambiguous name) or an auto-incremented one ('Audio 9' duplicates to 'Audio 10', so the name you passed in now belongs to a different track). Verified by a named row appearing rather than by a count, because only rendered track rows can be read: when the rendered rows SHIFT without a new name among them the copy may be off-screen, which comes back state 'duplicated_not_visible' with verified:false and a warning to scroll and re-read - it is NOT a claim that nothing happened, and firing again would leave a second copy carrying a second set of the source's regions. When the rendered rows read identically before and after - same numbers, same names, same order - no copy was made where this call can see, and the state is 'unchanged', never a 'duplicated_' one: a copy lands directly BELOW its source and renumbers every row under it, so rendered rows below the source that kept their numbers refute the insertion outright (`insertion_refuted: true`, and then nothing happened and nothing needs undoing). LOGIC DOES NOT DUPLICATE A TRACK STACK: measured 2026-09-03, the command is a silent no-op on the MAIN track of a folder or summing stack (the row carries `is_stack: true`) and works normally on the subtracks inside it and on every plain track. Duplicate the members, or build the stack again. To delete the copy afterwards, pass `duplicate`'s track_number AND track_name to logic_delete_track.",
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
                description: "Create a new track (software_instrument or audio) via Logic's key command, verified by re-reading the track list. THE RESULT NAMES WHAT IT MADE: `created_track {track_number, track_name}`, read off the row Logic selects - pass that track_name straight to the next call instead of diffing two listings or guessing Logic's auto-name. IT DOES NOT LOAD AN INSTRUMENT: a software-instrument track is created EMPTY and makes no sound until one is put in its instrument slot, which is a different mechanism from the insert slots - logic_add_plugin fills the first empty audio-effect INSERT, never the instrument, so 'create a software instrument track' + 'add a plugin' both report success on a silent track. THE SECOND CALL IS logic_load_instrument {track_name: created_track.track_name, instrument}. Only rendered track rows can be counted, so when the rendered rows shift without a new name among them the new row may be off-screen: that comes back state 'created_not_visible' with verified:false and a warning to scroll and re-read - it is NOT a claim that nothing happened, and firing again would leave two tracks. Rendered rows that read identically before and after come back state 'unchanged' instead, never 'created_not_visible'. A Create New Track dialog is answered if one appears (Logic 12.3.1 raises none for these two commands). The alternative, when a track already carries the instrument you want, is logic_duplicate_track, which copies its settings and its content with it.",
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
                description: "The arrangement map, and the first call before any arrangement edit: every region on every rendered track row, with name, start/end bar (and beat when off the barline), type (midi/audio), mute state and selection state. Read-only; optionally filtered to one track. `name` IS THE REGION'S OWN NAME AND `muted` IS BESIDE IT, because Logic writes a region's live state into the same string it publishes the name in (`808 Mutation Bass, muted`) — both spellings are accepted wherever a region_name is taken. `muted: true` has TWO causes the element does not distinguish: the region's own mute, and the silence a solo on another track puts it in. `muted: \"unavailable\"` means the name ends in a ', …' this build cannot read as a state word (a localized Logic, or a region genuinely named with a comma) — never that it is unmuted. THIS MAP CAN BE INCOMPLETE AND SAYS SO IN FIELDS, not in a footnote: `partial` (true when rows are PROVABLY missing), `completeness` ('partial' or 'unknown' - never 'complete', because a row Logic has not rendered publishes nothing at all), `partial_evidence`, `missing_track_numbers` where the numbering names them, and `coverage_checked` saying which signals were read. By default it reads the ROW NUMBERING only, which is free; collapsed track stacks and a scrolled Tracks area can hide rows WITHOUT leaving a gap in it, so pass check_hidden_rows: true to read the track header column and scroll bar too. REGIONS HAVE NO STABLE HANDLE: they are addressed by (track_name, region_name, start_bar), and start_bar is exactly what an edit changes - so re-read this map between two edits of the same region instead of reusing the first read's start_bar. Every row here carries its `track_number`, and that is what to pass to the region tools when several rows share a name (an imported project is full of 'Studio Grand' rows): a name that matches two rendered rows is REFUSED as ambiguous rather than resolved to the first of them, and track_number + track_name are cross-checked against each other. FIELDS OMITTED AT THEIR DEFAULT: start_beat/end_beat on the barline, and `selected` when false - absent means not selected. `type` IS NOT GUARANTEED: Logic publishes it unevenly, so where one region on a row carries it the rest are filled in from it (type_from: 'track_row', because a track holds one kind of region) and where none does the field is ABSENT - which means unknown, never 'not audio'. EMPTY IS PROVEN, NOT ASSUMED: a walk that finds no track rows is cross-checked against the track header column, and an arrangement that is unreadable (or visibly holds tracks the walk cannot see - e.g. a non-English Logic UI) is REFUSED with the reason rather than reported as an empty project. Mechanism and measured costs: see the guide.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Optional: only this track's regions."],
                        "check_hidden_rows": [
                            "type": "boolean",
                            "description": "Default false. true also reads the track header column and the Tracks-area scroll bar, so collapsed stacks and scrolled-out rows are reported even when the row numbering has no gap. Costs a measured +40-50 ms on a 95-120 ms call."
                        ]
                    ],
                    "additionalProperties": false
                ],
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleListRegions
            ),
            Tool(
                name: "logic_delete_region",
                title: "Delete a region",
                description: "DESTRUCTIVE: delete one region. Logic's Delete takes EVERY selected region in the PROJECT, while the arrangement map this server reads holds only the track rows Logic has RENDERED - so exclusivity is established, not assumed. The region is selected exclusively, then Logic's own project-wide 'Deselect All' clears the selection and is PROVEN to have landed (the rendered selection count is watched falling to zero) before the one target region is selected back; the result says `selection_scope: \"project\"` and carries that receipt. When 'Deselect All' is not in the key command registry the tool does not guess: if any track row is provably hidden (scrolled out, or a collapsed stack) it REFUSES before Delete and names those rows and how to reveal them, and if nothing proved a row hidden it goes ahead with `selection_scope: \"rendered_rows\"` and a warning saying exactly that. Logic's Tracks-area keyboard focus is established before Delete goes out - the command acts on the focused area, and fired without it does nothing at all, silently - and a delete that does not take names the focus and Logic's open dialogs rather than just repeating that the region is still there. VERIFICATION: the region total across EVERY rendered row must fall by exactly 1 AND the addressed region must be gone; a wider drop comes back as collateral damage, never as success. Undo restores.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer", "description": Tool.regionTrackNumberNote],
                        "region_name": ["type": "string", "description": Tool.regionNameNote],
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
                description: "Cut the silence out of ONE audio region — the first move of every audio-post session, and what other DAWs call strip silence. Logic Pro 12.3.1 has no command by that name: the real one is 'Remove Silence from Audio Region…' and it opens a floating window with a LIVE PREVIEW of how many regions the current settings would leave. That preview is why apply defaults to FALSE: the first call opens the window, reads Logic's own count and the current threshold/time settings, closes it again and changes nothing, so an agent can ask 'what would this do?' before doing it. apply: true presses OK and verifies against the arrangement map (one region becomes N; Undo restores it, and the audio FILE is never touched) — and because Logic's Remove Silence acts on the PROJECT-WIDE selection, that path takes the same guard as the other region commands: Logic's own 'Deselect All' first, proven by the rendered selection falling to zero, then the target selected back, and an after-check against the region total across EVERY rendered row rather than the target track's. The result says `selection_scope`, names the regions it produced in `produced_regions` — all of which Logic leaves SELECTED, so clear them with logic_select_regions {mode: \"none\"} before the next selection-based command — and refuses when rows are provably hidden and that clear is unavailable. The preview path writes nothing and so does not pay for the clear; it says `selection_scope: \"rendered_rows\"` and warns that Logic's count is of the whole SELECTION. Refuses on a MIDI region BEFORE it selects anything. NOT IMPLEMENTED: the window's four numeric fields are per-digit steppers and this server does not write them — each is reported with the LABEL Logic printed beside it in `settings.fields`, plus the stable keys threshold_db, minimum_silence_seconds, pre_attack_seconds and post_release_seconds when those labels are recognised. Logic's own ORDER is minimum silence, post release, pre attack, threshold (not what this description used to claim), and the printed values carry the SYSTEM's decimal separator — \"0,1000\" on a Swedish Mac — so read `number`, never Double() over `value`. Changing them means touching Logic's window.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer", "description": Tool.regionTrackNumberNote],
                        "region_name": ["type": "string", "description": Tool.regionNameNote],
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
                title: "Select regions",
                description: "Select ONE region, a whole track's worth, everything after a point, the whole project, or nothing — every edit command in Logic acts on the SELECTION, and this is the tool that sets it. mode 'region' (the DEFAULT) selects the one region named by track_name plus region_name and/or start_bar, through the element itself; ambiguity is refused with the candidates listed. The other modes fire Logic's own commands: 'track' (every region on the anchor's track), 'following' (the anchor and everything after it, on EVERY track), 'following_same_track' (the same, that track only), 'all' (every region in the project), 'none' (clear the selection). They need an anchor — track_name, plus region_name and/or start_bar when the track holds more than one region — and the anchor is selected exclusively first, then the command extends from it. UNDER mode 'region': exclusive (default true) clears every other region selection first, so a following edit key command (cut/copy/delete/nudge) touches only this region and `deselected` counts what it cleared; exclusive: false ADDS this region to whatever is already selected and PROVES it rather than claiming it — `selected_before` and `selected_count` are counted off the arrangement, and a selection that did not actually GROW comes back with a warning naming what was lost instead of a silent success. A region that is already selected is a verified no-op (state: \"already_selected\") and nothing is written to it, while the other selections are still cleared under exclusive: true. VERIFICATION for the command modes: the number of selected regions is counted before and after off the arrangement map, and a mode that moved nothing comes back success: false rather than pretending. A CLEAR says it cleared: mode 'none' reports state \"cleared\", or \"already_clear\" when nothing was selected to begin with — never \"selected\", which the other modes use to mean regions were just selected. Those modes also report `key_focus`, because a selection command fired while Logic's keyboard focus sits elsewhere does nothing at all, silently: the focus is probed first and repaired where it can be, and a focus held by ANOTHER Logic window (a plug-in window, the Mixer) is not fought over — the result names that window and the call that closes it (logic_close_plugin_window, logic_set_mixer {open: false}). Every count sees VISIBLE track rows only, while the selection itself is project-wide — a following edit acts on every selected region, counted or not. THE COMMAND MODES CAN WRITE INTO THE USER'S OWN LOGIC: they use learned key commands, and one missing from the registry is LEARNED on the spot, which adds a MIDI-note assignment to the user's active key command set (additive, removable in Logic's Key Commands window); the result then carries `learned_key_command`, `learned_note` and a `consent_note` saying exactly that. Say so when you report the result. Mode 'region' needs none of that. The command names and the focus mechanism: see the guide.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "mode": [
                            "type": "string",
                            "enum": ["region", "track", "following", "following_same_track", "all", "none"],
                            "description": "Default 'region': the ONE region named below. The others fire Logic's own selection command."
                        ],
                        "track_name": ["type": "string", "description": "The region's own track — the anchor's, for the command modes; required for every mode except 'all' and 'none'."],
                        "track_number": ["type": "integer", "description": Tool.regionTrackNumberNote],
                        "region_name": ["type": "string", "description": "Which region (with start_bar to disambiguate). " + Tool.regionNameNote],
                        "start_bar": ["type": "integer", "description": "The region's current start bar."],
                        "exclusive": ["type": "boolean", "description": "Mode 'region' only, default true: clear other selections first. false ADDS this region to the current selection and reports selected_before/selected_count. Refused with the other modes, which always replace the selection."]
                    ],
                    "additionalProperties": false
                ],
                // Changes the project-wide region selection, nothing else. The
                // absolute modes are idempotent; the relative ones are too,
                // since they re-anchor every call.
                safety: .write,
                mayWarn: true,
                idempotent: true,
                handler: MCPServer.handleSelectRegions
            ),
            Tool(
                name: "logic_split_region",
                title: "Split a region",
                description: "Cut ONE region in two at a bar (and optional beat), in a single call with one verdict — the select-park-split recipe, verified. Three failure modes are checked in order, and the first two refuse BEFORE anything is written: the split point is not inside the named region (refused with the region's own bar span); the playhead did not land exactly where it was asked to, sub-beat fields included, because for a split an almost-right position is a wrong cut rather than a rounding error; and the command fired while the arrangement map still shows one region, reported as verification_failed with nothing undone. EXCLUSIVITY IS ESTABLISHED, NOT ASSUMED: Split cuts EVERY selected region in the PROJECT, so the selection is cleared project-wide and PROVEN clear before the one named region is selected back, and the result says `selection_scope: \"project\"` with that receipt. Where the clearing command is unavailable the tool refuses if any track row is provably hidden, naming those rows, and otherwise proceeds with `selection_scope: \"rendered_rows\"` and a warning saying exactly that. Success is proven across EVERY rendered row, not just the target track's: the project's region total must rise by exactly 1, so a Split that cut four regions is a loud failure instead of an invisible one, and both halves are reported. A MIDI SPLIT IS NOT SILENT: when a note crosses the cut, Logic raises a modal and freezes until it is answered — this answers it with notes_crossing (default 'split', Logic's own pre-selection), reports which branch it took, and cancels any dialog left standing on a failure path. Undo restores the single region, and the halves are NEW regions, so re-read logic_list_regions before addressing either of them. Mechanism and measured costs: see the guide.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer", "description": Tool.regionTrackNumberNote],
                        "region_name": ["type": "string", "description": "Which region; with start_bar, to disambiguate. " + Tool.regionNameNote],
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
                description: "Move one region by whole bars and/or beats via Logic's nudge key commands (no dragging, no mouse). VERIFIED IN BOTH TERMS against the arrangement map, on every call: the region's bar AND its beat, so a by_beats nudge and a mixed by_bars+by_beats one are checked as exactly as a whole-bar move, and the result publishes `from_bar`/`from_beat` beside `to_bar`/`to_beat` so you can see the displacement it proved. A nudge that moved nothing at all is a failure naming the keyboard focus, never a success. EXCLUSIVITY IS ESTABLISHED, NOT ASSUMED: Nudge moves EVERY selected region in the PROJECT, while the arrangement map this server reads holds only the track rows Logic has RENDERED, so before the first nudge Logic's own project-wide 'Deselect All' clears the selection and is PROVEN to have landed (the rendered selection count is watched falling to zero) and the one named region is selected back; the result says `selection_scope: \"project\"` and carries that receipt. Where 'Deselect All' is not in the key command registry the tool refuses if any track row is provably hidden (scrolled out, or a collapsed stack), naming those rows, and otherwise proceeds with `selection_scope: \"rendered_rows\"` and a warning saying exactly that. DESTRUCTIVE: a nudged region can land ON TOP of its neighbours, and Logic trims whatever it overlays - the region that was there loses the overlapped part and only Undo brings it back. Read logic_list_regions first to see what is in the way. AND THAT TRIM IS CHECKED, not just the count: the target row's regions are compared span for span either side of the nudge, so a neighbour that lost bars off its front comes back as verification_failed naming it and its new span - and so does the moved region itself if what it landed on trimmed IT (whatever the nudge did to its start it must have done to its end). A nudge creates and destroys nothing, so the region total across EVERY rendered row is checked unchanged as well, which is what catches a neighbour swallowed whole. Relative, so a repeat moves again.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer", "description": Tool.regionTrackNumberNote],
                        "region_name": ["type": "string", "description": Tool.regionNameNote],
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
                        "track_number": ["type": "integer", "description": Tool.regionTrackNumberNote],
                        "region_name": ["type": "string", "description": Tool.regionNameNote],
                        "start_bar": ["type": "integer"],
                        "to_bar": ["type": "integer"],
                        "to_track": ["type": "string", "description": "Destination track; default same track."],
                        "to_track_number": ["type": "integer", "description": "Which destination ROW, when several tracks share `to_track`'s name. Cross-checked against to_track exactly as track_number is against track_name."],
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
                description: "See how a region is set to play back before you change it — quantize, transpose, velocity, loop, mute, gain, fades, delay — read out of Logic's Region inspector. This is the read side of logic_set_region_params. Pass track_name (plus region_name and/or start_bar) and the region is selected first; call it with no arguments to read whatever is already selected. A call that NAMED a region gets that region's rows or a refusal: rows still showing the selection it replaced, or the track's defaults, are never reported as if they were the region's. THREE THINGS THE RESULT TELLS YOU BEFORE THE VALUES. `subject` says whose parameters these are — a region, 'multiple' when several are selected (values that differ read as mixed), or 'defaults', the last two only on the no-arguments path; with NOTHING selected the panel shows the TRACK's region defaults, which is a different thing entirely and is never written by this server. `region_type` is read off the rows Logic published, independently of the arrangement map. And `enabled` per row is load-bearing: Logic greys out every Q-row while Quantize is Off, and a disabled control cannot be written. `display` is Logic's own text for the value and is ABSENT at a parameter's default, because Logic prints the default blank. The panel is opened and left open for the next region call (`panel_state`), and a HIDDEN INSPECTOR is shown, read and put back rather than refused (`inspector`, `inspector_shown_for_call`, `inspector_restored`). Mechanism and measured costs: see the guide.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Select this track's region first. Omit to read whatever is selected."],
                        "track_number": ["type": "integer", "description": Tool.regionTrackNumberNote],
                        "region_name": ["type": "string", "description": "With track_name: which region. " + Tool.regionNameNote],
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
                description: "Shape how a region PLAYS BACK without touching what was recorded — quantize with its swing and strength, transpose, velocity offset, dynamics, gate time and delay on MIDI; gain, fine tune, fades with their curves and type, and reverse on audio; loop and mute on both. Nothing is rewritten and no audio file is touched, so every one of them is reversible by setting it back, and logic_list_events keeps showing where the notes were actually played. Pass as many as you like in one call: they are applied in a fixed order with QUANTIZE FIRST, because Logic disables every Q-row while Quantize is Off (so 'quantize to 1/16 with 75% swing' is one call, not two), and each fade LENGTH before its curve and type. Each write is read back off Logic's own control and reported as before/after with the row it landed on; a parameter already at the requested value is a verified no-op in `unchanged` and nothing is pressed (with every named parameter already right, the whole call comes back as state: \"already_set\"). Compare-and-set with `expected_current` per parameter. VALUES: units and ranges are on each property below, and an out-of-range number is REFUSED rather than clamped. Four parameters take Logic's OWN MENU SPELLING — quantize, dynamics, gate_time, fade_type — and a near miss is refused with the real list rather than guessed at; read the quantize list with logic_get_region_params include_quantize_values. SCOPE: the default 'region' selects the named region exclusively and writes to it alone; scope 'selection' writes to every region currently selected (set that up with logic_select_regions) and leaves the selection alone, and a value that DIFFERS between them reads as mixed and cannot be compare-and-set. REFUSED, on purpose: with nothing selected the panel shows the track's region defaults and a write there would change what every future region inherits; a MIDI-only parameter on an audio region (or the reverse) is refused by name BEFORE anything is written; under scope 'selection' every numeric parameter is refused, because Logic makes those controls relative over a multi-selection; and a fade row switched to 'Speed Up'/'Slow Down' is refused, because its value is then a ramp length and not a fade. A HIDDEN INSPECTOR is not a refusal: the call shows it, writes, reads back and puts it away again (`inspector`, `inspector_shown_for_call`, `inspector_restored`). Mechanism and measured costs: see the guide.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Which track the region is on. Required for scope 'region'."],
                        "track_number": ["type": "integer", "description": Tool.regionTrackNumberNote],
                        "region_name": ["type": "string", "description": "Which region, with start_bar to disambiguate. " + Tool.regionNameNote],
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
                description: "Rename ONE region, in about 0.18 s (measured 2026-09-02). Logic's Region inspector publishes the region's name as an editable text field, so this is a single write and a confirm — no dialog, no key command, and the inspector's disclosure triangles are not even touched. The region is selected exclusively first (track_name plus region_name and/or start_bar; ambiguity is refused with the candidates listed) and the rename is verified in BOTH channels before it reports success: the inspector reads the new name back AND the arrangement map shows it on the region at that position, compared exactly, case included — the two disagreeing is a verification_failed naming both. Names are the ARRANGEMENT's, not the audio file's — renaming an audio region never touches the file on disk, and Undo restores the old name. Compare-and-set with expected_current_name. Three notes worth knowing: a MUTED region publishes '<name>, muted' as its accessibility description while the inspector shows the bare name, and both channels are compared on the bare name (since 2026-09-03 the arrangement map strips that state off the name and reports it as `muted` instead, so the two now agree by construction) - the one name this cannot round-trip is a new_name that itself ends in ', muted', which the map is unable to tell from a muted region of the shorter name; if Logic renumbers OTHER regions on the track as a side effect (the way it renumbers default marker names by position), the ones that moved are reported in `also_renamed`; and the two strings Logic prints in that name field for ITSELF — '2 selected', and the '... Defaults' it shows when no region is selected — are refused as names before anything is written, because a region carrying one reads as a selection state to every Region-inspector tool. The name field lives in Logic's Inspector, and a HIDDEN Inspector (View > Inspector, or the I key) is not a refusal: the call shows it, renames, verifies and presses it back (`inspector`, `inspector_shown_for_call` and `inspector_restored` say what it found and did) — measured 0.88-0.91 s for the round trip rather than the 0.18 s above. To rename a TRACK use logic_rename_track; to rename several regions call this once per region.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Which track the region is on."],
                        "track_number": ["type": "integer", "description": Tool.regionTrackNumberNote],
                        "region_name": ["type": "string", "description": "Which region (its current name), with start_bar to disambiguate. " + Tool.regionNameNote],
                        "start_bar": ["type": "integer", "description": "The region's current start bar."],
                        "new_name": ["type": "string", "description": "The new name. One line, non-empty."],
                        "expected_current_name": ["type": "string", "description": "Compare-and-set: the name you believe the region carries. A mismatch refuses and writes nothing."]
                    ],
                    "required": ["track_name", "new_name"],
                    "additionalProperties": false
                ],
                // Reversible by renaming back, and idempotent: a repeat with
                // the same name is a verified no-op ("already_set").
                //
                // NOT `changesArrangement`, which is a claim about the SOUND:
                // it attaches the standing instruction to bounce a range and
                // listen across the seam for a displaced groove. A rename
                // writes METADATA — the tool's own note says the file on disk
                // is untouched — so that note sent the agent after a snare a
                // name change cannot move, and it was 457 B of an 890 B
                // response (51%), attached to the `already_set` no-op too.
                // The tools that CAN displace a groove keep it.
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleRenameRegion
            ),
            Tool(
                name: "logic_set_tempo",
                title: "Set the tempo",
                description: "Set the project tempo in BPM via the control bar's tempo display (rapid-fire stepwise converge, ~1.3 s per 120 BPM of distance). Whole-BPM resolution. Compare-and-set with expected_current_bpm. TEMPO MAP GUARD: the tempo display shows and sets the tempo AT THE PLAYHEAD, so on a project with a tempo track this write would edit one tempo node rather than the project tempo. It therefore reads the project's tempo map out of Logic's Tempo List (View > List Editors > Tempo; measured 0.4-0.8 s cold, ~7 ms from the per-project cache, no playhead movement) and REFUSES with precondition_failed when the map holds more than one tempo: a tempo map is edited in Logic's tempo track / Tempo List, not through this slider. A SUCCESSFUL write leaves that cache CORRECT rather than empty: on the single-tempo map this tool is the only one allowed to write into, the map afterwards is known exactly (same event, the BPM read back off the slider), so it is patched in place and the next tool that needs bars->seconds still gets its ~7 ms cache hit instead of re-reading the list — tempo_map.cache says which happened. When the Tempo List cannot be read it falls back to sampling the tempo at the playhead and at bar 1 (parking the playhead and restoring it; the park itself is milliseconds, the two reads dominate) and refuses the same way; two agreeing samples are evidence, not proof, so the result then reports which bars were compared in tempo_sampled_at_bars. There is no override argument.",
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
                description: "Create a NEW Logic project at the given .logicx path — from a bundled empty project template — and open it, with no dialog left on screen. Logic runs single-project: if the current project has unsaved changes the call fails unless if_current_modified explicitly chooses 'save' or 'dont_save'. That refusal happens BEFORE the template is written, so a refused call leaves NOTHING at `path` and the retry carrying your decision uses the same path — it does not collide with a half-made project. The created project is already saved on disk. Logic will not show a project with no tracks: it raises its 'Create New Track' sheet over every empty project, and CANCELLING that sheet closes the project (measured), so this tool answers it with Create and reports it in `dialogs_answered`. The new project therefore has ONE track, and `initial_track` names it: `type` as the sheet spells it ('MIDI/Software Instrument', 'Audio/Mic or Line', …), `category` and `variant` separately, `track_number` and `track_name` read back from the track list, and `offered` — every kind that sheet had on it, in its own words. Pass `initial_track` to CHOOSE the kind instead of inheriting whichever was used last on this Mac: 'software_instrument', 'audio', or any label from `offered`. A name the sheet does not offer is not a refusal — by then the project exists and cancelling that sheet would close it — so the project opens with the sheet's own selection and a `warning` lists the real vocabulary. Nothing is left standing on screen: a software-instrument `initial_track` makes Logic open that track's own plug-in window unasked, asynchronously — measured 2026-09-03, 1.1-1.8 s after this tool would otherwise already have returned, never before; an audio track opens none — and this tool now waits for it (up to 2.5 s, only when the kind just created is one measured to raise it), detects it the way `logic_list_windows` does and closes it the way `logic_close_plugin_window` does, reporting the outcome in `dialogs_closed` (always present, empty when nothing needed closing) — a window that will not close carries a `warning` naming `logic_close_plugin_window` as the way out, because a fresh project starting with a stray plug-in window standing over it leaves Tracks-area keyboard focus unverified for whatever tool runs next. `caches_cleared` names the per-project caches forgotten, which matters when you recreate a project at a path you deleted.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute destination path ending in .logicx; must not already exist."],
                        "if_current_modified": [
                            "type": "string",
                            "enum": ["fail", "save", "dont_save"],
                            "description": "'fail' (default), 'save' or 'dont_save' — what to do with the currently open project's unsaved changes."
                        ],
                        "initial_track": [
                            "type": "string",
                            "description": "Kind of the one track Logic demands before it will show a new project: 'software_instrument', 'audio', or an exact label from a previous call's `initial_track.offered` such as 'Session Player/Drummer' or 'Pattern/Software Instrument' (underscores and case ignored). Matched against the categories and variants this Logic's Create New Track sheet actually prints — they differ by Logic version and are localized — and the sheet is read back after the choice, so `initial_track.requested_honoured` reports what happened rather than what was intended. Default: whichever kind that sheet already has selected, the last one used on this Mac."
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
                description: "Open an existing .logicx project. Single-project semantics as logic_new_project: unsaved changes in the current project require an explicit if_current_modified decision. Opening a project with NO TRACKS raises Logic's 'Create New Track' sheet, which cancelling would close the project out from under you; it is answered with Create and reported in `dialogs_answered` and `initial_track`, so such a project opens with one more track than the file holds. `caches_cleared` names the per-project caches forgotten on the way in.",
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
                description: "Understand a whole project in ONE call, as a structured document you can diff: transport, tempo and meter maps, markers, tracks, regions, and — at the wider scopes — the mixer, inserts and sends. Pair it with logic_reset_to to diff an episode's start and end state, or call it once instead of making twenty reads. SCOPE decides the cost, not the capability, and each level is a superset of the one before: 'structure' (default) is Accessibility-only and never touches the control surface; 'mix' adds the strip census and the full mixer snapshot (two bank walks — the expensive part); 'full' adds per-track MCU inserts and sends, capped by max_tracks. COMPLETENESS IS THE CONTRACT, and it has TWO halves. Every section named in `sections` is present in the result, and one that could not be read comes back as {\"unavailable\": \"<reason>\"} — never a missing key, because a diff would read a missing section as an empty project rather than a failed reader (`unavailable_sections` names them). A section that DID read and can prove it is short of the project is named in `partial_sections` instead, with every track number it proved exists in `missing_track_numbers`. `complete` is false for EITHER, and the top-level `warning` then names the sections and the evidence, so a BEFORE/AFTER diff cannot mistake ten hidden tracks for a whole project. `complete: true` means nothing proved anything missing, which is the strongest claim the Accessibility plane can make — for a census of every strip on or off screen, ask logic_list_strips. SERVED FROM CACHE: `cached_sections` names any section answered from this server's earlier read of the tempo or meter map rather than from Logic on this call, `verified` is false whenever that list is not empty, and the caveat is promoted into the top-level `warning`. Deterministic by design — fixed section and array ordering, keys serialized sorted — so two snapshots diff cleanly once you drop `timing_ms`, the one nondeterministic block. It composes the individual readers, so their caveats apply here unchanged: the track list is only the RENDERED rows, and the MCU sections degrade honestly against an old bridge daemon. Section-by-section costs: see the guide.",
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
                description: "One-time onboarding: learn MIDI-note assignments for the 19 key commands this server's tools actually fire (Toggle Track Freeze, Split at Playhead, Cut/Copy/Paste/Delete, the four Nudges, the track lifecycle, Save, Create Marker) into the user's Logic via the Key Commands window automation. THE SET IS THE SET OF COMMANDS SOMETHING FIRES: Undo, Redo and Flashback Capture as Recording are spelled and reserved but NOT installed, because no tool fires them (a tool restores by inverse operation with a verified readback, never by a blind Undo whose menu shows no operation name) - each is learned on the spot the first time anything really asks for it, and `commands: [\"Undo\"]` installs one deliberately. Create Marker is installed although logic_markers presses the Marker tab's own button instead (measured 3/3): it is that button's fallback, and it is the one GLOBAL command with a cheap count readback, which makes it the probe for 'are key commands firing at all' (fire it, then logic_markers list - the count rises by 1). Additive to the user's key command set and removable there; collisions with existing assignments get alternate notes automatically, picked by the same reserved-aware allocator as the first note, so a fallback can never land on a note another command has spoken for. Idempotent — already-learned commands are verified and skipped, each reported in `results` as state: \"already_learned\" (the same entries also carry the older key `status`, which will be dropped in a later release). Runs automatically the first time a tool needs a missing command, so calling this explicitly is optional. Pass relearn: true to force re-learning even for commands that look bound — the repair when key commands silently stopped firing (e.g. after the MIDI ports were recreated: Logic scopes the assignments to the port identity). REFUSED, binding nothing, while Logic's port list shows an orphaned twin of the MCP ports: an assignment made then is scoped to a port identity Logic may not be reading, and the refusal names the repair.",
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
                                "enum": KeyCommandRegistry.allNamedCommands.map(\.name)
                            ],
                            "description": "Limit to these command names (default: the 19 the install round writes). Undo, Redo and Flashback Capture as Recording are accepted here but are NOT in that default - nothing fires them, so naming one is how you install it deliberately."
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
                description: "Learn ANY command in Logic's Key Commands window - not just the standard set - onto a MIDI note, so logic_trigger_key_command can fire it. Give the command's name EXACTLY as the Key Commands window spells it (e.g. 'Strip Silence…', 'Bounce Regions in Place', 'Select All Following of Same Track'); the search field is driven with the first words of that name unless you pass 'search' yourself. THIS WRITES INTO THE USER'S OWN LOGIC KEY COMMAND SET: the command gains an additional assignment on the dedicated 'Logic MCP Commands' MIDI port. It is additive - the user's existing keyboard shortcut is untouched - and removable in the same window (select the command, Delete Assignment). The MIDI note is chosen automatically from a range reserved for learned commands (60-99, then 122-127, then 21-59), so it can never take a note the product's own standard commands want; pass 'note' only to force one, and one another command already answers to is refused whether or not relearn is set. The registry file is the consent record and records the name, note, timestamp, search term and that THIS tool bound it - read it back with logic_list_key_commands. Already-registered commands answer immediately without opening the window, as state: \"already_registered\" (or \"already_learned\" when the window confirmed an existing assignment); pass relearn: true to bind again, the repair after MIDI ports were recreated. A command the window shows already carrying a DIFFERENT assignment is REFUSED rather than given a second one - learning stacks, it does not replace - and the refusal says what it answers to today; relearn: true deletes the old assignments first. Learning is refused outright while Logic's port list shows an orphaned twin of the 'Logic MCP Commands' port, because Logic scopes an assignment to a port's unique ID and a binding made onto the wrong twin can never fire. When no row matches, the failure is not_found and it LISTS the rows the panel was showing: command names drift between Logic versions, so a near miss is answered with the real spellings rather than a guess.",
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
                description: "List what the key command registry holds: every command name that has been learned onto the 'Logic MCP Commands' MIDI port and the note that fires it. Read-only and Logic-free - this reads the registry FILE, which is also why the result carries NO verified field: nothing here was confirmed against Logic, and an entry it lists can still have been orphaned inside Logic (recreated MIDI ports do that silently; logic_setup_key_commands with relearn: true repairs it). The registry is what logic_trigger_key_command checks before firing anything, so this is also the list of commands an agent may fire. Each constant fact is said ONCE, not on every row: channel appears only when it is not the default (channel_default), source only when the entry records one (unrecorded_sources counts the rest), and the learn timestamps and search terms stay in the file at registry_path. Also reports which standard commands are not learned yet, and - for entries learned since the identity was recorded - whether the 'Logic MCP Commands' port they were bound against is still the live one, warning by name when it is not.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleListKeyCommands
            ),
            Tool(
                name: "logic_trigger_key_command",
                title: "Trigger a key command",
                description: "Fire a Logic key command that was learned onto the dedicated 'Logic MCP Commands' MIDI port. Pass name (e.g. 'Toggle Track Freeze', 'Undo') or note+channel. Standard commands missing from the registry are learned automatically first; unknown notes are refused because they could be bound to anything. 'Undo', 'Redo' and 'Flashback Capture as Recording' are deliberately NOT part of the install round (nothing in this server fires them), so the first call naming one opens the Key Commands window once to learn it and says so in `first_run_learning`. THIS VERIFIES NOTHING ABOUT LOGIC'S REACTION: a `success: true` proves only that the bridge daemon accepted the MIDI send, never that Logic executed the command — measured live, two identical {name: 'Create Marker'} calls returned byte-identical success while the marker count went 4 to 5 to 5, the second call a silent no-op Logic swallowed at an already-marked position. Fire only when the command's precondition plainly holds, and verify the SPECIFIC effect yourself afterward by reading Logic back (a before/after count, the AX or LED state a command is known to change) — this result alone cannot tell a real effect from nothing happening. CAUTION with Undo especially: the menu shows no operation name, so only fire it right after a known edit.",
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
                description: "Render ONE track offline to an audio file ON DISK with ZERO dialogs, via Track Freeze — the whole track from project start with every plugin and automation on it, in ~8-9 s. NOT bounce-in-place: it produces a FILE, it does not commit a new audio region into the project, so logic_bounce_in_place is the tool for 'print that so I can chop it'. WHAT `verified` MEANS HERE: it reports the CLEANUP, not the render. `verified` aliases `unfrozen`, so a perfectly good render whose freeze could not be undone comes back verified: false with the track still frozen in Logic (unfreeze it there). Judge the render itself by `path` and `metrics`. THE PLAYHEAD MOVES AND IS PUT BACK: the render jumps it to the project start and rolls from there, so where you had it is read first, restored afterwards, verified against Logic's control bar and reported in `playhead` — and if that fails the result WARNS and names the position it was left at. LISTENING: a full-track freeze render is the whole PROJECT long whatever bars you ask for, which is far past what one MCP audio block may carry — so what rides along is a bounded WINDOW of the first ~42 s, named in `audio_window` and in `listen_note`, with the complete file at `path`, an AAC copy at `preview_path` and any other stretch one logic_get_audio_clip call away. A short render is carried whole; with start_bar/end_bar the SLICE is what gets previewed and attached. A result never arrives audio-less in silence: when no block can be made, `listen_note` says why and where to listen instead. DISK: every call writes ~46 MB of project-length audio into the captures folder, and a retention policy shared by every tool that writes there keeps the newest 200 captures within 2 GB, reporting anything it removed in `captures_pruned`. Requires 'Toggle Track Freeze' in the key command registry and the MCU bridge running; a track that is already frozen fails safely and restores state. Mechanism, tempo handling and measured costs: see the guide.",
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
                        "expected_project_path": MCPServer.expectedProjectPathStrictProperty,
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
                description: "Send a command to Logic through the Mackie Control bridge (UI-independent) - the raw escape hatch underneath every other MCU tool here. cmd is one of: press {button | note 0-127, hold_ms}, select/mute/solo {channel: 0-7}, vpot_press {index: 0-7}, fader {channel: 0-8, value: 0-16383, verify: true}, vpot {index: 0-7, delta: +-n}, converge {index, target, field, tolerance, max_ms, ratio}, raw {bytes: [..]}, midi_stream {events: [[offset_ms, byte, ..], ..]}, midi_abort, keycmd {note, channel, hold_ms} (routed through the key-command registry, which refuses notes it has not recorded consent for), status, await {since, timeout_ms}, ping. BUTTONS, all 26: play, stop, record, rewind, forward, cycle, click, marker, nudge, drop, replace, solo_global; bank_left, bank_right, channel_left, channel_right, flip, global_view, name_value, smpte_beats; assign_track, assign_send, assign_pan, assign_plugin, assign_eq, assign_instrument. WHAT THE RESULT MEANS: state is \"sent\" for anything that only put bytes on the wire, and that is nearly everything here - an MCU note Logic has nothing bound to answers exactly like one that worked. To find out what Logic actually did, send {\"cmd\": \"status\"} on THIS tool: it is the daemon's live in-process snapshot of the surface, where logic_mcu_status reads a state FILE that can be minutes old. state is \"read\" for status/ping/await, which change nothing and so carry no verified at all; \"verified\" or \"unconfirmed\" only where the daemon really did read Logic back, which is fader with verify: true and converge; \"refused\" when the daemon rejected the command, with error saying why. HOLD: hold_ms is how long a press keeps the button down, and it defaults to 0 on the press family and on keycmd alike - both swept live, the key-command one across 0-40 ms with zero duplicates and zero drops. Both note edges are always sent: a note-on with no release leaves the change half-done. Pass hold_ms only for Logic Control's hold behaviours, which the sweeps did not cover - held SEND opens the submode chooser. FADER: Logic does follow an absolute fader write, but it SNAPS the position to its own resolution, so never compare the echo to the value you asked for with ==. Pass verify: true to get final_value (where Logic actually settled) and followed back; to restore a fader exactly, write back a value Logic itself reported, which is on its grid by construction. Channel 8 is the dedicated master fader, which is Logic's `Master` strip and NOT `Stereo Out`. The sweeps and snapping measurements behind those rules: see the guide.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        // The daemon's whole vocabulary, taken FROM the shared
                        // enum so the two can never drift — and, since
                        // 2026-09-02, EVERY field of that vocabulary is
                        // declared below. Three of the fifteen commands used
                        // to be advertised here and be structurally
                        // uncallable: `converge`, `midi_stream` and a
                        // parameterised `await` need target/field/max_ms/
                        // tolerance/ratio/events/since/timeout_ms, none of
                        // which were properties, and additionalProperties is
                        // false — so the enum offered a route that
                        // rejectUnknownArguments closed before the handler
                        // ran. One measurement in the ledger (`fastConverge`'s
                        // seed ratio) was abandoned over exactly that.
                        // `verify` was the same bug with the description as
                        // the victim: it told callers to pass verify: true for
                        // the daemon's only readback, and the schema refused
                        // the key, so every fader write through this tool was
                        // blind. McuCommandContractTests holds the two sets
                        // equal from here on.
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
                        "bytes": ["type": "array", "items": ["type": "integer", "minimum": 0, "maximum": 255]],
                        "verify": ["type": "boolean", "description": "fader only: wait for Logic's own echo (up to 400 ms) and report final_value and followed. The only readback this tool has."],
                        "hold_ms": [
                            "type": "integer", "minimum": 0,
                            "maximum": BridgeCommand.maxPressHoldMs,
                            "description": "How long a press/select/mute/solo/vpot_press - or a keycmd - holds the button down; the default 0 is the measured one on both planes, so pass a hold only for Logic Control's own hold behaviours, which remain unswept."
                        ],
                        "target": ["type": "number", "description": "converge: the value to steer the vpot's LCD field to."],
                        "field": ["type": "integer", "minimum": 0, "maximum": 7, "description": "converge: which LCD value field to read; defaults to index."],
                        "max_ms": ["type": "integer", "minimum": 0, "description": "converge: give up after this long (clamped to 15000)."],
                        "tolerance": ["type": "number", "minimum": 0, "description": "converge: how close to target counts as arrived."],
                        "ratio": ["type": "number", "description": "converge: seed for ticks-per-unit; the loop re-estimates it as it goes."],
                        "events": [
                            "type": "array",
                            "items": ["type": "array", "items": ["type": "number"]],
                            "description": "midi_stream: [[offset_ms, byte, ...], ...] on the performance port, max 20000 events. Playback is asynchronous - poll midi_streaming on status, or stop it with midi_abort."
                        ],
                        "since": ["type": "integer", "description": "await: return as soon as received_events passes this. -1, the default, returns on the next event of any kind."],
                        "timeout_ms": ["type": "integer", "minimum": 0, "description": "await: give up after this long (default 500, clamped to 5000)."],
                        "expected_project_path": ["type": "string", "description": "Absolute .logicx path; when given, the open project's AXDocument must match before a single byte is sent."]
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
                description: "Build and read the project's TEMPO MAP — every tempo change in the song, as rows in Logic's Tempo List. 'land a downbeat on the hit at 1:12' is a create; 'list' returns every event (bar, beat, BPM) and writes nothing; 'set' retunes the event already there and 'delete' removes it. A 'list' served from the per-project cache is cross-checked against the control bar's live tempo, and one whose cross-check could NOT run (an unreadable control bar, e.g. a non-English Logic UI) comes back verified: false with read_route 'tempo_list_cache' and a warning — never as a verified live read. A WRITE IS NEVER TRUSTED BLIND: the whole map is re-read afterwards and reported, so a create that produced two events, or moved a neighbour, comes back as a failure (or a warning naming which other events moved) rather than as a success. Compare-and-set with expected_current_bpm on 'set' and 'delete'. REFUSED: 'create' where an event already sits (use 'set'), 'set'/'delete' where none does, deleting bar 1 (the project's base tempo — retune it instead), and any write at all while the Tempo List cannot be read, because a tempo write is not made blind. AFTER A WRITE the server's cached tempo map is dropped, so every later bar-to-seconds conversion re-reads the new map. Costs: a 'list' is milliseconds from the cache and under a second live; a write is a couple of seconds. Mechanism and measured costs: see the guide.",
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
                description: "Start or stop playback and verify the new state against three independent witnesses - the control surface's play/stop lamps, the control bar's own Play button, and whether the position display is advancing - so a lamp that has gone stale can no longer report playback that is not happening. Starting plays from the current playhead position (or the cycle range when cycle is on). A stop is NEVER pressed at a transport the witnesses say is already stopped: that press is Logic's rewind-to-bar-1 and would move the playhead. When the lamps are the ones that were wrong the result carries led_desync plus a warning naming what each witness read, and the lamps resync by themselves on the next real play.",
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
                description: "Move the playhead to a 1-based bar (and optional beat) by stepping the control bar position display, then verify. Requires the control bar display mode that exposes bar/beat (Beats & Project). A bar past the end of the project is refused by name, saying which bar Logic stopped at. Nothing the call did not ask for is left changed: when 'beat' is omitted and Logic moves it anyway (it resets the sub-bar position at the last bar), the beat is put back and the result carries a warning saying so; when the move cannot be verified, the playhead is returned to where the call found it and 'restored' says whether that worked.",
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
                description: "Set the cycle (loop) locators to a whole-bar range, e.g. bars 5-9. Anchors the ruler's grid-snapped cycle region to a bar line via the playhead thumb, MEASURES the two requested bar lines by parking the playhead on them (rather than extrapolating one average pixels-per-bar, which is wrong by up to a whole bar on a project that changes meter - 'mapping' reports the route and how far a straight-line ruler would have missed), moves the region start by writing its AXPosition, adjusts the length by dragging its right edge (hit-test guarded), verifies the region's own distance from the ruler's Start marker plus its bar-denominated size description, and restores the playhead. A range that is not currently visible in the ruler is scrolled into view first - the ruler is moved by measured pixels and read back, and a range it cannot reach is refused with the pixels it managed; a bar past the end of the project is refused by name. A write that fails verification is put BACK to the range this call read first, verified, and says so ('Restored: true') or names the bars it is left at. Cycle mode is left exactly as it was found: a drag engages Cycle the way it would for a human, so when 'enabled' is omitted that is undone, and 'cycle_enabled_before' and 'cycle_enabled' both appear in the result. Optionally turns cycle on/off afterwards via 'enabled'.",
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
                description: "Select a track by name (and optional 1-based track number) so its channel strip is exposed in the inspector. Writes AXSelectedChildren on the Tracks header group, falls back to the header's Has Focus button, and verifies through both the header's selected state and the inspector strip. Fails with ambiguous when several visible tracks share the name, and restores the previous selection if verification fails. Only tracks whose headers are currently rendered can be selected - and a name that matches none of them is refused in one of TWO ways, because the two situations are different: when nothing proves the rendered rows short of the project the refusal says the name is not there, and when rows are provably missing it says so instead, names the collapsed track stack they sit behind and the logic_set_track_stack call that opens it, and names the track numbers that exist and are not rendered. Rows 10-19 of a project can be inside one collapsed stack; a name in there is not a typo. `inspector` says what Logic's Inspector was doing when the call ran ('shown', 'hidden' or 'unavailable'), because it decides what proved the selection: with the Inspector hidden there is no channel strip for any track, the selected header row is the whole readback, and `readback_route` says 'ax_selected_header_row' instead of naming the strip.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Exact track name as shown in the track header."],
                        "track_number": ["type": "integer", "description": "1-based track number; required when several visible tracks share the name."],
                        "expected_project_path": MCPServer.expectedProjectPathStrictProperty
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
                        "expected_project_path": MCPServer.expectedProjectPathStrictProperty
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
                description: "Inventory every insert on a track: open each plugin window, list its accessible parameters (name, raw range, writability), classify the exposure, and close windows that were opened. Roughly a second per insert. Use to map which plugins are controllable through this MCP. READ open_state PER INSERT before you believe a parameter count: 'opened'/'swapped_in'/'already_open' mean the window really is up, and 'unverified' means Logic accepted the press and opened nothing — on which an empty parameter list says nothing about the plugin, only about the window that never appeared, so classification comes back {\"unavailable\": \"<reason>\"} rather than the false claim 'no_semantic_sliders'. parameter_settle appears only when the read was not straightforwardly stable, and says what was odd about it."
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
                        "expected_project_path": MCPServer.expectedProjectPathRefuseProperty
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
                description: "Remove a plugin from a track — mouse-free via the Mackie Control plugin browser's No Plug-in entry (~4-5 s measured; the browse steps backward to the boundary and jumps most of the way once this Logic install's catalog positions have been learned, and a browse that cannot reach the boundary within 30 s or 700 catalog entries refuses and says how far it got rather than pressing anything; verified via LCD and an AX cross-check on the named track). When the same display name occupies several slots, the mouse-free route refuses to guess: pass insert_slot to name the one to remove. If the MCU bridge is down, the AX chooser fallback requires allow_mouse: true because it briefly takes over the pointer. `cross_check` names that second source: \"ax_insert_list\" (the inspector strip's insert list agreed the plugin is gone - one fewer instance, when several were there) or \"unavailable\" (no inspector is showing that strip, so the control surface's own echo is the only evidence - the result warns when that happens)."
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
                        "expected_project_path": MCPServer.expectedProjectPathRefuseProperty
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
                name: "logic_set_track_mix",
                title: "Set a track's mix",
                description: "Set a track's LEVEL, PAN, MUTE and SOLO — any one of them, or all four in ONE call. Pass only what you want to change: volume_db (or relative_volume_db), pan, mute, solo; a call that names none of them is refused naming them. volume_db and pan are ABSOLUTE, never offsets — read the current values first (logic_track_info and logic_mixer_snapshot both report volume_db and pan), or pass relative_volume_db, which computes the target from the value read immediately before the write ('2 dB louder' is relative_volume_db: 2). Each write is verified by readback (control surface first, inspector strip as fallback) and lands its OWN section of the result — `volume`, `pan`, `mute`, `solo`, each with that write's state and readback — while top-level `success`/`verified` are the AND of them and `written`/`unchanged`/`refused` name which parameters went which way. FIXED ORDER: volume, pan, mute, then solo. Solo goes last on purpose — Logic flashes the mute LED of every channel a standing solo silences, so a mute written after this call's own solo would have to be read through that blink window. COMPARE-AND-SET IS PER PARAMETER (expected_current_volume_db, expected_current_pan, expected_current_mute, expected_current_solo): a mismatch refuses THAT parameter with precondition_failed and writes nothing for it, the others still go, and the result says so in `refused` plus a warning. A guard passed without its parameter is refused rather than ignored. VOLUME converges against Logic's own dB readout and reports before_db / after_db / requested_db; `verified` there means exactly what you asked for — the landed value within tolerance_db (default 0.15 dB, no widening) — and a fader that will not reach it comes back verified: false with `deviation_db` and a `verification_note`, its own `success` still true because the fader did move and after_db is Logic's own readout of where it is. MUTE IS SAFE UNDER A SOLO: only a steady LED counts as a mute, so a flashing one is reported `mute_led_blinking` with `mute_blink_note`, meaning \"silent right now but NOT muted\" — mute: false on such a track is a truthful no-op instead of a press that would have muted it, and mute: true really mutes it. `any_soloed` is Logic's whole-project solo indicator, and `led_evidence` says which sampling window was paid. A parameter already at the value asked for is a verified no-op (`already_set` / `already_on` / `already_off`) and nothing is pressed. A SOLO LEFT ON silently empties every later bounce, so unsolo before judging a mix. Mechanism and measured costs: see the guide."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "volume_db": ["type": "number", "description": "ABSOLUTE target level in dB (e.g. -14.2, 0.0). Mutually exclusive with relative_volume_db."],
                        "relative_volume_db": ["type": "number", "description": "Offset in dB from the value read immediately before the write: 2 is '2 dB louder', -3 is '3 dB quieter'. Mutually exclusive with volume_db."],
                        "expected_current_volume_db": ["type": "number", "description": "Compare-and-set for the fader: the dB you believe it is at. More than 0.5 dB out refuses the volume write and moves nothing."],
                        "tolerance_db": ["type": "number", "description": "Accepted deviation from the volume target, default 0.15 dB. `verified` means this number and nothing wider, on both routes."],
                        "pan": ["type": "integer", "description": "ABSOLUTE knob position, typically -64..63 with 0 at center; the knob's own range is enforced. Out of range is refused, never clamped."],
                        "expected_current_pan": ["type": "integer", "description": "Compare-and-set for the pan knob: the position you believe it is at. A mismatch refuses the pan write."],
                        "mute": ["type": "boolean", "description": "true mutes the track, false unmutes it."],
                        "expected_current_mute": ["type": "boolean", "description": "Compare-and-set for mute: the state you believe the track is in."],
                        "solo": ["type": "boolean", "description": "true solos the track, false unsolos it."],
                        "expected_current_solo": ["type": "boolean", "description": "Compare-and-set for solo: the state you believe the track is in."]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                // Four independent scalar settings of one channel strip, folded
                // into one PATCH-style tool (2026-09-03 token audit fold #4):
                // logic_set_track_volume, _pan, _mute and _solo spent 6,280
                // bytes of `tools/list` repeating one set of addressing,
                // verification and compare-and-set rules four times. Every
                // write path is the one that tool had.
                safety: .write,
                mayWarn: true,
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleSetTrackMix
            ),
            Tool(
                name: "logic_open_plugin",
                title: "Open a plugin window",
                description: "Open the plugin window for one insert on the named (selected) track by pressing the insert's open button, then verify by what the WINDOW SHOWS. Logic reuses ONE plugin window per channel and swaps the plugin into it in place, so a second plugin on the same track opens without any window appearing; `window_shows` carries the plugin name the window's own header publishes, `state` is `swapped_in` with `replaced_plugin` when Logic reused the channel's window, `opened` when a new one appeared, and `verified_by` says which proof was taken. Reads the header BEFORE pressing: a window already showing this plugin returns state already_open in ~150 ms without pressing anything and without the window flickering off screen. Fails closed on not_found, ambiguous (two inserts with the same plugin) and not_exposed; a press Logic accepted whose effect could not be seen returns success: false, state unverified, never a claimed open.",
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
                description: "Read the MIDI events of a region out of Logic's Event List (View > List Editors > Event) — position, type, pitch, velocity and length, as Logic's own cells print them. This closes the asymmetry where logic_record_midi could WRITE MIDI that nothing could read back. SCOPE, and it matters: the Event List shows the SELECTED region (or the selected track's region at the playhead), never the project's MIDI as a whole — pass track_name (plus region_name and/or start_bar) to select one first, or select with logic_select_regions and call this with no arguments to read whatever is showing. An EMPTY list means nothing is selected, not that the project has no MIDI, and the result says so. Every row carries Logic's published columns verbatim plus parsed bar/beat/pitch/velocity/length where the columns were recognised. IT ANSWERS ONLY THE ROWS LOGIC HAS DRAWN: a List Editors table publishes every row it holds and draws the cells of the ones IN VIEW (measured — a 54-event region published all 54 and drew 26), so a region longer than the pane comes back short. `event_count` is the LIST'S own count, never the array's length, and when they differ the result carries `events_read`, `unreadable_rows`, `unreadable_row_numbers` and a warning. Those events are missing from the RESULT, not from the project: scroll in Logic (or make the pane taller) and read again. The row count is also cross-checked against the list's own 'Number of Items' and a mismatch REFUSES rather than returning a truncated take on the region. Opens the List Editors pane if it was closed, restores the previously selected tab, and closes what it opened.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Select this track's region first (exclusive selection). Omit to read whatever is currently selected."],
                        "track_number": ["type": "integer", "description": Tool.regionTrackNumberNote],
                        "region_name": ["type": "string", "description": "With track_name: which region. " + Tool.regionNameNote],
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
                description: "Fix ONE MIDI note in place — its pitch, velocity, position or length — or delete it, or add one, through Logic's Event List. This is the SURGICAL editor, not a composer: logic_record_midi plays a whole part in and is the tool for writing music, while this one is for the single flubbed note in a take you want to keep. SCOPE: the Event List edits the SELECTED region — pass track_name (plus region_name and/or start_bar) to select one first, or select with logic_select_regions — and read the region first with logic_list_events, because that is where the addresses come from. ADDRESSING: bar plus pitch, because a chord publishes several rows on the same position; add beat/division/tick to narrow further. An address that matches two events REFUSES with both listed rather than editing the nearer one. MOVING a note: any to_* field you leave out keeps its current value, so to_beat alone moves the note without quantizing its sub-beat feel. Compare-and-set with expected_current_velocity and expected_current_length; an edit that asks for what is already there is a verified no-op (state 'already_set') and presses nothing. VERIFICATION, every time: the list is re-read and must show the event count the action implies, the event reading exactly what was asked, and EVERY OTHER EVENT UNTOUCHED — a write that disturbed a neighbour comes back with a warning naming which. WORTH KNOWING: a big velocity or pitch move costs a few seconds, because every cell is a one-step-per-write stepper, and row numbers from an earlier read go stale the moment a position or pitch write re-sorts the table. REFUSED: writing while the Event List is showing the project's REGIONS instead of a region's events (nothing there is editable); a row that is not a Note, because Logic's Num/Val columns mean controller number and value there; creating a duplicate of a note already at that position and pitch, which nothing could address afterwards; and creating OUTSIDE the selected region's bars, because Logic adds the note and does not grow the region, leaving an event that exists and never sounds. NOT writable from this plane at all: the Status column (an event's type) and the MIDI channel. Mechanism and measured costs: see the guide.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["set", "create", "delete"],
                            "description": "'set' edits an existing note, 'create' adds one, 'delete' removes one."
                        ],
                        "track_name": ["type": "string", "description": "Select this track's region first (exclusive). Omit to edit whatever region is showing."],
                        "track_number": ["type": "integer", "description": Tool.regionTrackNumberNote],
                        "region_name": ["type": "string", "description": "With track_name: which region. " + Tool.regionNameNote],
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
                description: "Markers: list, create, goto or delete them. 'list' reads Logic's Marker List (View > List Editors > Marker) with each marker's bar and name. 'create' presses the Marker tab's own Create new Marker button at the PLAYHEAD - that button, not Logic's Create Marker key command, is the route this tool takes (measured 3/3; the key command runs only when the Marker tab publishes no button) - and verifies against the list's own count; pass bar to park the playhead there first, which rewinds and then steps so the marker lands EXACTLY on the bar line rather than a fraction of a beat late, checked against the control surface's position display. 'goto' parks the playhead on the marker's bar AND BEAT — a marker at 33 4 1 1 leaves the playhead on 33|4, not 33|1. 'delete' uses the list row's own Delete action and verifies the marker is gone (Undo restores it). NAMES ARE READ-ONLY on Logic Pro 12.3.1: no cell in a Marker List row publishes a settable value, so 'rename' refuses with the reason and 'create' refuses a name argument up front rather than creating a marker and then failing to name it — markers keep Logic's own default names (Marker 1, Marker 2, ...) unless you rename them by hand in Logic. Address a marker by name (exact, case-insensitive — never fuzzy, because deleting the wrong marker is silent damage) or by bar; ambiguity refuses with the candidates listed. 'list' ANSWERS ONLY THE ROWS LOGIC HAS DRAWN, exactly as logic_list_events does: the Marker tab publishes every row it holds and draws the cells of the rows IN VIEW ONLY, so a marker list longer than the pane comes back short. `marker_count` is the list's OWN count, and when it disagrees with what could be read the result carries `markers_read`, `unreadable_rows`, `unreadable_row_numbers` and a warning — those markers are missing from the RESULT, not from the project. Scroll the list in Logic (or make the pane taller) and read again; a 'goto' or 'delete' that cannot find a marker says the same thing rather than reporting it absent. Each action is ONE List Editors pane cycle, so create and delete cost about as much as a list.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["list", "create", "goto", "rename", "delete"],
                            "description": "Default 'list'."
                        ],
                        "name": ["type": "string", "description": "Which marker (exact name), for goto/rename/delete. REFUSED for 'create': a marker's name cannot be written from this plane on Logic Pro 12.3.1, and the refusal comes before anything is created."],
                        "bar": ["type": "integer", "description": "Which marker (its bar), for goto/rename/delete. For 'create': park the playhead exactly on this bar's line first."],
                        "new_name": ["type": "string", "description": "Required for action 'rename', which refuses on Logic Pro 12.3.1 — the name cell is not settable. Rename markers in Logic."]
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
                description: "Read the project's time signatures out of Logic's Signature List (View > List Editors > Signature): each signature, the bar it starts on, and its bar length in QUARTER-note beats (what Logic's BPM counts — 6/8 is three beats a bar, 7/8 three and a half). This is the meter map, the last assumption that was left in this server's bar math after the tempo map landed. HOW IT IS USED: a map with more than one bar length is INTEGRATED by every tool that converts bars to seconds itself (logic_render_track's slice, logic_evaluate_change method 'render', logic_record_midi's note placement and verification slice, logic_record_automation's point placement) — those results then carry a meter_map block and a warning, and an explicit beats_per_bar argument no longer overrides the project's own grid. A map with ONE bar length is reported and deliberately not used, so a constant-meter project's boundaries are bit-for-bit what they have always been. The Signature List also holds KEY signatures; those rows are counted for the truncation cross-check and skipped. IT ANSWERS ONLY THE ROWS LOGIC HAS DRAWN — and unlike logic_list_events and logic_markers, which report what they could read and name what they could not, this one REFUSES: a List Editors table draws the cells of the rows IN VIEW ONLY, an undrawn signature row is indistinguishable from the project's own initial signature, and a meter map that quietly dropped a signature change would place every later bar confidently wrong. So a published-but-undrawn row comes back as a refusal naming the row numbers; scroll the Signature List in Logic (or make the pane taller) and call again. Read cost 0.23-0.66 s cold, ~7 ms from the per-project cache, no playhead movement.",
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
                description: "WINDOW MANAGEMENT: opens or closes the Mixer WINDOW (Window > Open Mixer), verified against the window list. It does not set any mixer VALUE - faders, pans, mutes and sends are logic_set_track_mix and logic_mcu_set_send, neither of which needs this window. Returns state already_open / already_closed when the window is already the way you asked for. WHAT THE MIXER DOES AND DOES NOT DO (measured, not hoped): the Mixer window publishes EVERY channel strip to Accessibility - the result lists them in `mixer_strips`, Master, Stereo Out and the auxes included - but they are NOT inspector strips, and the Accessibility strip tools (logic_list_inserts, logic_survey_plugins, logic_open_plugin, logic_plugin_preset, logic_set_insert_bypass) still cannot address them: with the Mixer open, logic_list_inserts on Master fails exactly as it does with the Mixer closed. `inspector_strips` is the list those tools CAN reach (the selected track and its output). For Master, an aux or a bus, use the logic_mcu_* tools, which never needed a window. AND IT COSTS SOMETHING: the Mixer is a second document window carrying the same project, so it can shadow the project window - while Logic is in the background it may be the only window Accessibility publishes, and then every track-header read fails. This server skips Mixer windows when it resolves the project window, but close the Mixer when you are done anyway. What it is genuinely good for: putting the Mixer in front of a HUMAN, and reading the complete strip census out of the window.",
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
                description: "Set ONE plugin parameter, verified by readback. START HERE: `{track_name, plugin_name, parameter, target_value}` is the whole call — \"more bass around 500 Hz\" is logic_set_plugin_parameter {track_name: \"Bas\", plugin_name: \"Channel EQ\", parameter: \"Pea2Ga\", target_value: \"4.9\"}, with no logic_list_inserts and no logic_list_plugin_parameters in front of it. The tool finds the insert itself from the strip's own insert list and reports which one it used in `resolved_slot`; pass insert_slot instead when you already know the physical slot, or to pick between two copies of the same plugin. ONE tool, TWO routes, and `route_used` says which ran. track_name + plugin_name (or insert_slot) is the CONTROL-SURFACE route: it reaches EVERY plugin, custom-UI third-party included, needs no window, matches the parameter against the MCU's abbreviated names ('Thrs' matches 'Threshold'), verifies against the LCD echo and rolls back on failure; expected_current_value is optional there. Pass window_title instead for the ACCESSIBILITY route, which writes and reads back the parameter's own text field: it REQUIRES expected_current_value and only reaches parameters logic_list_plugin_parameters marks `ax_writable`. Give BOTH and a knob-only plugin no longer dead-ends — the write starts on the Accessibility route and falls back to the surface when the parameter publishes no field, reporting route_used 'mcu' and fallback_from 'ax'. Mechanism and measured costs: see the guide."
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
                description: "The CENSUS: every channel strip the control surface can reach, in project order — audio and instrument tracks, auxes, buses, the output and the master. Unlike logic_list_tracks, which can only see the track headers Logic has currently RENDERED (19 of 25 strips on the reference project, measured 2026-09-02), this walks the surface's banks, so nothing is hidden by scrolling or by a collapsed stack. Each row carries the strip's position, its bank/channel address and Logic's own 6-character LCD name cell; track_name and track_number are filled in only where exactly one rendered track header abbreviates to that cell, and everything else is reported as kind 'unresolved' (an output/aux/bus, a track scrolled out, or two tracks that share a name) rather than guessed at. Address strips by their full Mixer name, never by the abbreviation. Always walks the surface fresh — a census that could be stale would be the very failure this tool exists to fix — which costs a few seconds and refreshes the bank map every other control-surface tool uses.",
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
                description: "The whole mixer in ONE call, off Logic's own control-surface feedback: per strip the fader value in dB, pan, mute/solo/select/record-arm state and the raw 14-bit fader echo. volume_db is the dB string Logic paints in its channel-strip Volume view — the same readout logic_set_track_mix converges against — NOT a conversion of the fader position, which is reported separately and raw as fader_14bit; a cell that does not parse comes back null with the LCD text beside it, never interpolated."
                    + " EVERY LED ANSWER IS A WINDOW, NOT AN INSTANT, because Logic uses a BLINKING LED as a state of its own. An armed strip's record LED flashes, so seen-lit-once means armed. The mute LED flashes on every channel a STANDING SOLO silences, so only a steady mute LED is a mute: a blinking one is reported muted: false and marked mute_led_blinking — that strip is silent right now but not muted, and pressing mute on it would mute it. any_soloed is Logic's whole-project solo indicator, which also sees a soloed channel that has no strip on this surface."
                    + " Two bank walks, 8.5-10 s on a 25-strip project, or 5.5 s with include_record_arm: false when no solo is standing. The surface is HANDED OVER in the channel-strip Volume view (assignment_after, surface_restore): the next control-surface tool that needs the pan view restores it, so that cost is not charged to this call."
                    + " Strip identity is established by a fresh scan, never from the cached bank map, and follows the same track_name/'unresolved' rule as logic_list_strips. Measured costs and the LED windows: see the guide."
                    + " METERS: where the bridge daemon publishes it, each strip also carries meter_level (0-12) and meter_overload — Logic's OWN control-surface meter, the segment count it would light on a Mackie Control. That is a state read of a value Logic published, exactly like the fader echo; it is NOT an audio measurement, has no dB calibration, and must never be reported as loudness. MEASURED: Logic does NOT feed this virtual surface meters during playback in the default Control Surfaces configuration — 8 s of rolling transport through real audio produced zero meter events (a handful of 0xD0 bytes arrive sporadically at idle, all level 0). Expect meter_level to be 0/absent until a way to enable Logic's MCU meter mode is found (candidate: the Mackie Control device's settings in Control Surfaces Setup — an open research item). Each bank is sampled at a different instant during the walk, so any values are eight-strip snapshots rather than a comparison across the mixer. When the running daemon predates this feature the fields are ABSENT rather than zero and meter_feed says 'unavailable'.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "include_record_arm": [
                            "type": "boolean",
                            "description": "Default true. false makes record_armed ABSENT from every strip — never false — and halves the call: the 1.6 s-per-bank blink window is the only thing that question needs. A standing solo still costs the full window, because that window is also the evidence behind `muted`. Pass false for a mix read that is about levels and pan."
                        ]
                    ],
                    "additionalProperties": false
                ],
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
                description: "Turn the metronome click on or off via the control surface's click button, verified by reading the surface's own click LED back, with the control bar's Metronome Click checkbox (the same field logic_get_transport reports) as a second source when the LED cannot be read. Compare-and-set: already-correct is reported as state: \"already_on\" / \"already_off\" and nothing is pressed; a press that does not land is undone. Count-in is a separate setting and is not touched.",
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
                description: "Load a software instrument into a track's INSTRUMENT slot — mouse-free via the control surface's instrument browser (the IN bank view's vpot), the slot logic_add_plugin cannot reach because it fills an insert instead. One vpot tick per browser entry, the shown entry re-verified after settling, and a vpot press instantiates; leaving the view cancels a browse without loading anything. Entries carry Logic's channel format ('Drum Kit Designer Stereo', 'Drum Kit Designer Multi-Output', 'Abbey Road Saturator (m) Mono'), so instrument may be given bare or with the format, or the format passed separately; matching is case-insensitive and exact on the name — a near miss is refused with the entries seen, never guessed at. THE TRACK ALREADY HOLDING IT IS A NO-OP: that comes back state 'already_loaded' in about a second, read off the slot without touching the browser, and naming a format always browses instead (a six-character slot cell cannot say which format it holds). Verified by the instrument slot's own name in the IN bank view; read the loaded instrument's parameters with logic_mcu_instrument_parameters as an independent second look. REPLACES any instrument already on the track, settings and all — Logic's Undo is the only way back.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Software-instrument track to load onto."],
                        "instrument": ["type": "string", "description": "Instrument name as Logic's browser shows it, e.g. 'Drum Kit Designer', 'Sampler', 'Analog Lab V'. May include the format ('Drum Kit Designer Stereo')."],
                        "format": ["type": "string", "description": "Channel format to pick when a plugin offers several: 'Stereo', 'Mono' or 'Multi-Output' (Logic also spells that last one 'Multi Output'). Matched case-insensitively against the suffix Logic puts on the browser entry. Default: the first entry whose name matches, and the result reports which format that was."],
                        "max_steps": ["type": "integer", "description": "How many catalog ENTRIES to look at before giving up, default 700 — entries actually shown, not messages sent. A wall-clock budget scales with it (15 s at the default), so a fruitless search stops in seconds instead of minutes and raising this really does buy a longer search. The list holds every installed instrument in every channel format and is grouped by vendor, not alphabetical, so a 'never showed' refusal reports how much of the catalog it got through and which bound it hit."],
                        "expected_project_path": MCPServer.expectedProjectPathRefuseProperty
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
                description: "READ an existing automation curve before you overwrite it — volume, pan, a send level or any plugin parameter — over a bar range, by sampling the value Logic chases the lane to at each position. NOTHING IN THE PROJECT CHANGES: no automation mode is switched, no fader or vpot is moved, and the playhead is put back where it started (`playhead_restored` says whether that worked). It is still not read-only: it SELECTS the strip it reads and hands the control surface over in the view it read through, which the next tool that needs another view settles for itself. THE POSITION IS PART OF THE READING: every point's bar/beat is the position the park VERIFIED on the control bar and the MCU display CONFIRMED, never the one merely requested — a position the playhead could not reach is listed in omitted_positions with its reason instead of carrying a neighbour's value, a park that landed elsewhere is reported where it landed (with requested_bar/requested_beat), and a first position that cannot be reached refuses the call. HONESTY: these are SAMPLES, not the lane's breakpoints — a move that happens entirely between two samples is invisible, so lower resolution_beats when the shape matters — and an unautomated lane reads as a flat line at the track's static value, which the result says rather than implying a curve exists. automation_mode is the inspector's own label; when none is published the result carries automation_mode_unavailable, because a null mode means UNKNOWN and cannot rule out Off. Positions run from start_bar beat 1 to end_bar beat 1 inclusive and end_bar is ALWAYS sampled: a resolution_beats wider than the remaining span shortens the LAST interval (final_interval_beats) rather than dropping the end. Costs roughly a second per sampled position plus ~0.5 s of setup. Mechanism and the meter-map sampling grid: see the guide.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer", "description": "Breaks a tie when several strips abbreviate alike on the control surface (duplicate track names) — the same numbers a matches-N-strips refusal names."],
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
                        "max_points": ["type": "integer", "minimum": 1, "maximum": 200, "description": "Cap on sampled positions, default 64. Exceeding it widens the step; the range is never truncated, and end_bar is sampled either way. The one exception is max_points: 1, which leaves room for start_bar only and warns that end_bar was not sampled."],
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
        // The reasoning — what passing false actually costs you, the
        // resource_link fallback, how to listen without the blocks — is the
        // instructions' AUDIO RESULTS AND LISTENING paragraph, sent once per
        // session instead of four times per list. Shortened 2026-09-03
        // (token audit Cut 1) to an actual pointer: the paragraph already
        // said everything below used to repeat.
        "description": "Attach the rendered audio as MCP audio content blocks (default true) — see AUDIO RESULTS AND LISTENING in the server instructions before passing false."
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
        // Shortened 2026-09-03 (token audit Cut 1): what it withholds, what
        // it keeps, and the sealed-file mechanism are spelled out in full in
        // the instructions' AUDIO RESULTS AND LISTENING paragraph, which
        // every session already pays for once.
        "description": "LISTEN FIRST: withhold this result's audio measurements, sealed into `sealed_metrics_path`, until you've described what you heard (default false) — see AUDIO RESULTS AND LISTENING in the server instructions."
    ] }

    /// The plain compare-and-set form of `expected_project_path`: refuse the
    /// whole call unless the named path is the open project. Declared
    /// identically by seven tools (introduced 2026-09-03, token audit Cut 1,
    /// replacing seven hand-typed copies of the same nine words).
    static var expectedProjectPathRefuseProperty: [String: Any] { [
        "type": "string",
        "description": "Refuse unless this is the open project."
    ] }

    /// The stricter compare-and-set form: an ABSOLUTE path checked against
    /// Logic's own `AXDocument` before the write goes out, worded per call
    /// site for what "before" means there (nothing changed / not a byte sent
    /// / nothing pressed). Declared once for the "before anything is changed"
    /// wording, shared by the three tools whose write has no more specific
    /// verb to name (introduced 2026-09-03, token audit Cut 1).
    static var expectedProjectPathStrictProperty: [String: Any] { [
        "type": "string",
        "description": "Absolute .logicx path; when given, the open project's AXDocument must match before anything is changed."
    ] }

    /// What `tools/list` puts on the wire, derived from the registry —
    /// never a second list that could drift from it. Filtered to the active
    /// toolsets (`--toolsets`), which by default is all of them.
    func toolDefinitions() -> [[String: Any]] {
        activeTools().map(\.definition)
    }
}
