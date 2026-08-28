import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCPServer {
    /// THE list. `tools/list` renders it and `tools/call` dispatches
    /// through it, so a tool cannot exist in one and be missing from the
    /// other, and the listen_note guard reads the flags declared here
    /// instead of a hand-maintained set of names.
    func toolRegistry() -> [Tool] {
        [
            Tool(
                name: "logic_health",
                description: "Read Logic Pro process and Accessibility readiness without changing Logic.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                // Starts the server's own bridge daemon if it is down; Logic
                // itself is only read.
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleHealth
            ),
            Tool(
                name: "logic_list_windows",
                description: "List Logic windows with subrole and project document path, read-only. Windows whose document is set are project windows; dialogs without a document are plugin or auxiliary windows.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleListWindows
            ),
            Tool(
                name: "logic_list_tracks",
                description: "List the track headers currently rendered in the Tracks area (track number, name, selected), read-only. THIS LIST CAN BE INCOMPLETE AND SAYS SO: Accessibility publishes only the rows Logic has rendered, so the result carries `partial` (true when rows are PROVABLY missing), `partial_evidence` (one sentence per signal: headers scrolled out above, gaps in the numbering, collapsed track stacks, a scrollable Tracks area), `missing_track_numbers` where the numbering names them, and `completeness` ('partial' or 'unknown'). There is no 'complete' verdict, because a row Logic has not rendered publishes nothing at all - `partial: false` means nothing proved any missing, never that this is every track. Do not build a mental model of the project on this alone. Output/aux/bus strips (Stereo Out, Master, Aux 1, buses) have no track header and are NEVER listed here, yet the mixing, send and plugin tools accept their names.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleListTracks
            ),
            Tool(
                name: "logic_list_inserts",
                description: "List audio-effect insert slots (index, plugin display name, bypass state) of the named track's channel strip, read-only. The `index` here is the ACCESSIBILITY ordinal (inspector strip order) - the numbering logic_open_plugin, logic_close_plugin, logic_remove_plugin and logic_set_insert_bypass take as insert_index, and NOT the Mackie insert_slot the logic_mcu_* tools take (on an output strip the two orders were observed reversed). The track must be selected so its strip is shown in the left inspector; otherwise the error not_exposed reports which track is currently shown."
                    + Tool.stripAddressingAXNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Exact track name as shown in the track header."]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleListInserts
            ),
            Tool(
                name: "logic_bounce_range",
                description: "Offline-bounce a bar range of the master output to an audio file, many times faster than realtime playback. Drives Logic's bounce dialog and its XPC save panel entirely through verified accessibility (no playback). Switches the bounce destination to Uncompressed. DELIVERY OPTIONS: file_type, bit_depth, sample_rate, dithering and normalize drive the dialog's own pop-ups (values are matched leniently - '48k', '48000' and '48 kHz' all reach '48 kHz' - and an unknown one is refused with the real list BEFORE anything is bounced), and include_audio_tail drives its checkbox. Whatever is not passed is left exactly as the user set it, and the result reports the full delivery state in `delivered_as`, read off the dialog just before OK. These are the USER'S OWN settings and Logic keeps them for the next bounce: they are changed, not borrowed, and nothing puts them back — `options_changed` says what moved. MP3 and M4A destinations exist in the dialog with their own option set and are NOT implemented here. ONE CONSEQUENCE OF CHANGING file_type: the metrics reader parses AIFF/AIFC only, so a WAVE or CAF bounce comes back with no `metrics` and therefore WITHOUT the silent-bounce warning — keep the default AIFF when you intend to judge the file by its numbers, and switch format only for the delivery itself. Returns the file path.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "start_bar": ["type": "integer"],
                        "end_bar": ["type": "integer"],
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
                        "include_audio": MCPServer.includeAudioProperty
                    ],
                    "required": ["start_bar", "end_bar"],
                    "additionalProperties": false
                ],
                // Not read-only: drives the bounce dialog and swaps the
                // destination setting.
                safety: .write,
                handler: MCPServer.handleBounceRange
            ),
            Tool(
                name: "logic_bounce_in_place",
                description: "PRINT a region (or a whole track) back INTO the project as audio — the resampling verb. This is the one logic_render_track is not: render_track writes a file to DISK, this creates a new audio REGION in the arrangement that you can then chop, reverse, load into a sampler or bounce again. Drives 'File > Bounce > Regions in Place…' (scope 'region', the default) or 'Tracks in Place…' (scope 'track') and answers the sheet. Every sheet control is left exactly as the user set it unless you pass the matching argument, and the result reports the whole sheet state it used. ONE THING TO WATCH: 'Bypass Effect Plug-ins' is a real Logic setting that may be ON, which makes the print DRY — the result warns when it was, and bypass_effect_plugins: false is how you print the sound as you hear it. Verified against the arrangement map: a region that was not there before, with its track and bars reported - and the muted SOURCE is not mistaken for it (Logic renames a muted region, which the first live run reported as the print). Undo removes it. The sheet is modal and is always cancelled on any failure path.",
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
                changesArrangement: true,
                handler: MCPServer.handleBounceInPlace
            ),
            Tool(
                name: "logic_export_stems",
                description: "Export ALIGNED STEMS: one offline bounce per named track over the SAME bar range, each with only that track soloed, solo restored after every one. The shared range contract is what makes these stems rather than a loop of renders, and the tool verifies it - the frame counts of the files are compared and 'aligned' says whether they really line up. WHAT A STEM CONTAINS: the full master output heard one track at a time - post-fader, post-pan, post-insert, WITH the return of anything that track sends to a bus, and with the master chain applied. Two consequences it will report but you must plan around: summing the stems reproduces the mix only while the master chain is linear (a master limiter reacts to the whole mix and cannot react to one stem), and a bus fed by several of these tracks is counted once per stem. logic_render_track is the OTHER kind of file - a pre-fader freeze of the track alone, no sends, no master chain - and it is not a stem. Refuses before the first render when any track is already soloed (every stem would contain it). Costs one full offline bounce per track; the limit is 16 per call. No audio is attached - the result carries paths. Alignment is measured from the files' frame counts, which the metrics reader gets from AIFF/AIFC only: if the bounce dialog's File Type has been switched to WAVE or CAF (logic_bounce_range can do that), the stems still render but `aligned` comes back false with 'UNVERIFIED' in the note rather than a claim.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "tracks": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Track names, exactly as logic_list_tracks reports them. Duplicates are refused."
                        ],
                        "start_bar": ["type": "integer", "minimum": 1],
                        "end_bar": ["type": "integer", "description": "Exclusive: the range ends where this bar begins."],
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
                handler: MCPServer.handleExportStems
            ),
            Tool(
                name: "logic_evaluate_change",
                description: "A/B A CHANGE AND HEAR BOTH VERSIONS: one complete closed-loop mix evaluation around exactly one verified plugin-parameter change, on a bar range - this is the tool for 'is this better?', and it returns the two renders as audio you can listen to. Takes 30-50 s. Three methods: 'render' (two dialog-free freeze renders of the SINGLE track, compared on the sliced bar range — fastest and most isolated; needs insert_slot, the MCU physical slot, and works for all plugins including third-party), 'bounce' (two offline MASTER renders via the bounce dialog, needs plugin_name), and 'solo_bounce' (two offline bounces with ONLY this track soloed, solo restored after; needs insert_slot like 'render' — use for tracks freeze refuses: stack subtracks and tracks sharing a channel strip). All methods roll the change back by default, return baseline/after audio paths, metrics and dB deltas, and CARRY both versions as audio content blocks. TEMPO: method 'render' cuts its two slices itself, so it first reads the project's tempo map out of Logic's Tempo List (View > List Editors > Tempo; ~2 s, no playhead movement, cached per project) and INTEGRATES it — exact for step tempo changes, and the result reports the map in tempo_map. Only when the Tempo List cannot be read does it fall back to sampling the tempo at both ends of the range (parking the playhead) and REFUSE with precondition_failed if the readings differ, naming 'bounce'/'solo_bounce' as the tempo-accurate alternatives; those two hand Logic the bar numbers and are never sampled or refused. MASTER CHAIN: method 'bounce' accepts a strip without a track header ('Stereo Out', an aux, a bus) — it bounces the whole mix, so no track needs selecting; the strip must be visible in an inspector (see logic_list_inserts) because the parameter is written through the plugin WINDOW, which also means the plugin must publish an editable field for it (`ax_writable` in logic_list_plugin_parameters). A knob-only plugin is refused BEFORE the baseline bounce, naming the surface route; the reference project's whole master chain — Channel EQ, Limiter, Sensor — is knob-only, so 'bounce' cannot A/B it and only logic_bounce_range plus a separate logic_mcu_set_plugin_parameter can. 'render' (freeze) and 'solo_bounce' (solo) are track-only by nature.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer", "description": "Disambiguates duplicate track names (methods 'render' and 'solo_bounce')."],
                        "plugin_name": ["type": "string", "description": "Plugin window title; required for method 'bounce'."],
                        "insert_index": ["type": "integer", "description": "ACCESSIBILITY ordinal (inspector strip order) from logic_list_inserts. A DIFFERENT numbering from insert_slot: on Stereo Out the two were observed REVERSED (AX: Sensor, Limiter, Channel EQ / MCU: Channel EQ, Limiter, Sensor). Never translate one into the other - list with the tool you are about to use. Method 'bounce' only."],
                        "insert_slot": ["type": "integer", "minimum": 1, "maximum": 8, "description": "MACKIE physical insert slot 1-8, from logic_mcu_plugin_inserts. A DIFFERENT numbering from insert_index (see it) - never convert between them. Required for methods 'render' and 'solo_bounce'."],
                        "parameter": ["type": "string"],
                        "expected_current_value": ["type": "string"],
                        "target_value": ["type": "string"],
                        "start_bar": ["type": "integer", "minimum": 1],
                        "end_bar": ["type": "integer", "description": "Exclusive: the range ends where this bar begins."],
                        "method": [
                            "type": "string",
                            "enum": ["render", "bounce", "solo_bounce"],
                            "description": "'render' (dialog-free single-track freeze A/B on the sliced bar range), 'bounce' (offline master A/B) or 'solo_bounce' (soloed offline A/B for tracks freeze refuses: stack subtracks, shared-channel tracks). NOTHING READS whether a track is a stack subtrack or shares a channel strip, so choosing between 'render' and 'solo_bounce' is discovered by trying: 'render' refuses in ~2 s naming 'solo_bounce', which costs a call and no state."
                        ],
                        "tempo": ["type": "number", "description": "Override BPM for bar math (method 'render'); default reads the control bar. Only used when the tempo map cannot be read from the Tempo List — a readable map is integrated and this override does not apply to it. Constant METER is still assumed (signature changes are not read)."],
                        "beats_per_bar": ["type": "number", "description": "Override meter for bar math; default reads the control bar's time signature."],
                        "keep_change": ["type": "boolean", "description": "true keeps the change after measuring; default false rolls it back."],
                        "expected_project_path": ["type": "string", "description": "Refuse unless this is the open project."],
                        "include_audio": MCPServer.includeAudioProperty
                    ],
                    "required": ["track_name", "parameter", "expected_current_value", "target_value", "start_bar", "end_bar", "method"],
                    "additionalProperties": false
                ],
                // Rolls the change back by default; keep_change is an explicit
                // value write.
                safety: .write,
                changesSound: true,
                listenNote: Tool.evaluateChangeListenNote,
                handler: MCPServer.handleEvaluateChange
            ),
            Tool(
                name: "logic_mcu_plugin_inserts",
                description: "List a track's insert slots as the Mackie Control sees them (physical slot numbers 1-8 with plugin names), via the selected track's MCU plugin list. These slot numbers are the `insert_slot` every logic_mcu_* tool takes - a DIFFERENT numbering from the Accessibility `insert_index` of logic_list_inserts (observed reversed on Stereo Out); never convert one into the other. Works for ALL plugins including custom-UI third-party ones. Selects the strip first."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                // Not read-only: SELECTS the track and moves the surface into
                // the plugin list.
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleMcuPluginInserts
            ),
            Tool(
                name: "logic_mcu_plugin_parameters",
                description: "Read ALL of a plugin's parameter names and formatted values (every MCU page) via host automation — works for plugins whose UI exposes nothing to Accessibility (Decapitator, Trilian, ...). insert_slot is the MCU physical slot from logic_mcu_plugin_inserts."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        // No minimum on max_pages: the handler deliberately
                        // clamps 0 up to 1 rather than refusing it.
                        "max_pages": ["type": "integer", "description": "Page cap, default 12 (each uncached page costs ~1.7 s; large instruments have 80+). pages_total and truncated report what was left out."],
                        "track_number": ["type": "integer"],
                        "insert_slot": ["type": "integer", "minimum": 1, "maximum": 8, "description": "MACKIE physical insert slot 1-8, from logic_mcu_plugin_inserts. NOT the same numbering as the Accessibility insert_index of logic_list_inserts / logic_open_plugin - on an output strip the two were observed reversed; list with the tool you are about to use."]
                    ],
                    "required": ["track_name", "insert_slot"],
                    "additionalProperties": false
                ],
                // Not read-only: selects the track and enters plugin edit mode.
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleMcuPluginParameters
            ),
            Tool(
                name: "logic_mcu_set_plugin_parameter",
                description: "Set one plugin parameter through host automation (MCU vpot) with the LCD value echo as verified readback — the data-plane route that reaches every plugin. Numeric targets converge adaptively; text targets (e.g. 'On', 'B') step until exact match. Optional expected_current_value enforces compare-and-set; failed verification rolls back. Parameter is matched against the MCU's abbreviated names (e.g. 'Thrs' matches 'Threshold')."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "insert_slot": ["type": "integer", "minimum": 1, "maximum": 8, "description": "MACKIE physical insert slot 1-8, from logic_mcu_plugin_inserts. NOT the same numbering as the Accessibility insert_index of logic_list_inserts / logic_open_plugin - on an output strip the two were observed reversed; list with the tool you are about to use."],
                        "parameter": ["type": "string"],
                        "target_value": ["type": "string"],
                        "expected_current_value": ["type": "string"],
                        "tolerance": ["type": "number"]
                    ],
                    "required": ["track_name", "insert_slot", "parameter", "target_value"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleMcuSetPluginParameter
            ),
            Tool(
                name: "logic_mcu_instrument_parameters",
                description: "Read the INSTRUMENT slot's parameter names and formatted values (all MCU pages) for a track via host automation — reaches software instruments whose UIs expose nothing to Accessibility (Q-Sampler, Trilian, ...).",
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
                description: "Set one INSTRUMENT parameter through host automation (MCU vpot) with LCD echo readback, same converge/step semantics and compare-and-set contract as logic_mcu_set_plugin_parameter.",
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
                description: "Read the Mackie Control bridge's mirrored state: LCD text (track names/values as data), fader positions, transport LEDs, timecode display, online status. This is Logic's documented control-surface feedback channel — no UI, no focus, no windows involved. Requires logic-mcu-bridge running and a Mackie Control configured in Logic pointing at the 'Logic MCP MCU' ports.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleMcuStatus
            ),
            Tool(
                name: "logic_mcu_sends",
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
                description: "Set one send's level in dB on a track, verified through the MCU LCD echo (compare-and-set with expected_current_value, readback, same discipline as plugin parameters). Only the level vpot is touched — never the destination. List sends first with logic_mcu_sends."
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
                description: "TAKES REAL WALL-CLOCK TIME (the automated range is played through, twice with verification). Writes an automation curve on a track — volume (absolute fader), pan, a send level (send: 1-8) or ANY plugin parameter (insert_slot + plugin_parameter) — with no mouse and no automation-lane clicking. The value scale follows the parameter: dB for volume/sends, -64..63 for pan, the plugin's own units otherwise. Mechanism: calibrate the control near the working range, switch the track to Latch over the control surface, roll playback placing calibrated moves at each musical moment, return to Read, restore the original value, and verify by REPLAYING the range while sampling Logic's own echo at every point. ramp (default true) interpolates between points. Points need bar >= 2 and carry value (or db for volume). Takes real time (the automated range, twice with verify). TEMPO MAP: each point's moment, the pre-roll bar and the per-point convergence budgets are integrated over the project's tempo map, read out of Logic's Tempo List (~2 s, no playhead movement, cached per project and reported in tempo_map), so a curve across a tempo change lands on the beats asked for; without a readable map it falls back to one msPerBeat from the control bar. The verification is bar-based either way, so it is the proof.",
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
                        "insert_slot": ["type": "integer", "minimum": 1, "maximum": 8, "description": "MACKIE physical insert slot 1-8 (logic_mcu_plugin_inserts), required when parameter is 'plugin'. NOT the Accessibility insert_index."],
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
                idempotent: true,
                handler: MCPServer.handleRecordAutomation
            ),
            Tool(
                name: "logic_record_midi",
                description: "TAKES REAL WALL-CLOCK TIME (the music plays through: bars x beats x 60/BPM seconds, roughly doubled with the verification render). Composes MIDI into the project with ZERO dialogs and no files: notes are streamed in real time over the dedicated 'Logic MCP MIDI In' port while Logic records them onto the selected software-instrument track (playhead parked one bar early; the stream starts on the observed MCU-timecode crossing into start_bar, so count-in settings do not matter). Creates a normal recorded region. By default the result is verified with a dialog-free freeze render of the recorded bars (non-silent metrics prove the notes landed and sound through the instrument). Recording takes real time: bars x beats x 60/BPM seconds. The region can be removed with Undo in Logic. SMART TEMPO GUARD: a project tempo mode of ADAPT (or AUTO, which can resolve to Adapt) makes Logic rewrite the project's TEMPO MAP to follow the recording, so this refuses before arming and names the fix; when the mode cannot be read off the control bar the recording proceeds and the result carries a warning saying it went unverified. TEMPO MAP: note offsets are integrated over the project's tempo map, read out of Logic's Tempo List (View > List Editors > Tempo; ~2 s, no playhead movement, cached per project and reported in tempo_map), so notes land on the grid across a tempo change. When the Tempo List cannot be read, placement falls back to constant-tempo bar math and the tempo is sampled at the take's first and last bar instead (playhead parked, read, restored — once per call, shared with the verification render); differing readings then produce a `warning`. Either way speed > 1 is REFUSED with precondition_failed on a non-constant tempo: speed mode overwrites the tempo slider and restores a single value, which cannot put a tempo map back. Real-time recording (speed 1) touches no tempo and stays available.",
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
                changesArrangement: true,
                handler: MCPServer.handleRecordMidi
            ),
            Tool(
                name: "logic_plugin_preset",
                description: "Browse and load a plugin's settings (presets). action 'list' enumerates the setting menu — every name, its category, and which one is marked as loaded — WITHOUT changing anything; action 'select' loads one by name (bare 'Rock Bass' or qualified '03 Guitars/Rock Bass'), verified against the plugin window's setting label; action 'step' walks next/previous N settings via Logic's topmost-plugin-window key command, the only route that needs no readable menu; action 'undo' presses the setting menu's own Undo, which is the ONLY way back from a load — it restores the parameter state rather than a name, so it also recovers a plugin that was on no named setting at all (verified 2026-08-28 on a headerless strip: all eight of a Limiter's parameters came back exactly). Default action: 'step', or 'select' when name is given. The plugin window is opened and closed again if this call opened it. Reading the menu needs Logic frontmost for a moment (a menu cannot open in a background app). Honesty contract: 'list' returns presets: null plus a reason when the plugin's UI exposes no Logic setting pop-up (fully custom UIs), and presets: [] — an empty list, not a failure — for plugins that genuinely ship no factory settings; 'step' reports success: false when the label did not move. WARNING: loading a setting overwrites EVERY parameter of the plugin, and a setting name is not a promise about the current state — unnamed tweaks on top of a named setting are lost and re-selecting the old name does not bring them back. Use action 'undo' to get back."
                    + Tool.stripAddressingNote
                    // Selection routes through the surface, but OPENING the
                    // plugin window is an Accessibility action on the strip.
                    + Tool.stripAddressingAXNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "plugin_name": ["type": "string"],
                        "insert_index": ["type": "integer"],
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
                handler: MCPServer.handlePluginPreset
            ),
            Tool(
                name: "logic_rename_track",
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
                description: "Duplicate a track via Logic's Duplicate Track key command (learned automatically). Verified by the track count increasing.",
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
                description: "Create a send on a track to a bus/output — mouse-free via the control surface's send-destination browser (first empty slot, browsed to the named destination, settle-verified, confirmed). Destination names as Logic shows them, e.g. 'Bus 1', 'Bus 2'. LEVEL: a new send lands at -oo dB and is INAUDIBLE, so pass level_db to set it in the same call (the same converge-and-read-back write logic_mcu_set_send does, on the strip already selected). Without level_db the send is created silent and the result says so; if the level write fails the send still exists and the result carries a warning naming the follow-up call."
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
                handler: MCPServer.handleAddSend
            ),
            Tool(
                name: "logic_create_track",
                description: "Create a new track (software_instrument or audio) via Logic's key command, answering the Create New Track dialog automatically. Verified by the track count increasing. IT DOES NOT LOAD AN INSTRUMENT, and no tool in this server does yet: a software-instrument track is created EMPTY, and the instrument slot is a different mechanism from the insert slots - logic_add_plugin fills the first empty audio-effect INSERT, never the instrument. So 'create a software instrument track' + 'add a plugin' both report success and the track still makes no sound. Until an instrument loader exists, the honest answer to 'give me a bass' is to say the instrument must be chosen in Logic, or to duplicate a track that already has one (logic_duplicate_track copies its settings and content).",
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
                description: "The arrangement map: every region on every visible track row, with name, start/end bar (and beat when off the barline), type (midi/audio) and selection state — parsed from Logic's own accessibility descriptions. Read-only. Optionally filter to one track. REGIONS HAVE NO STABLE HANDLE: they are addressed by (track_name, region_name, start_bar), and start_bar is exactly what an edit changes - so re-read this map between two edits of the same region instead of reusing the first read's start_bar. Duplicate region names make verification count occurrences rather than identify a region, which is why every edit tool selects exclusively first. Only regions on rendered track rows are listed, with the same caveat as logic_list_tracks.",
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
                description: "Select exactly one region (by track + region_name and/or start_bar; ambiguity is refused with candidates listed). exclusive (default true) clears all other region selections first, so a following edit key command (cut/copy/delete/nudge) touches only this region. Verified via the element's selection state.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "region_name": ["type": "string"],
                        "start_bar": ["type": "integer"],
                        "exclusive": ["type": "boolean", "description": "Default true: clear other selections first."]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                // Not read-only: changes the project-wide region selection.
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleSelectRegion
            ),
            Tool(
                name: "logic_delete_region",
                description: "DESTRUCTIVE: delete one region (selected exclusively first; refuses unless exactly ONE region is selected project-wide right before Delete fires). Verified against the arrangement map; Undo restores.",
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
                changesArrangement: true,
                handler: MCPServer.handleRemoveSilence
            ),
            Tool(
                name: "logic_select_regions",
                description: "Select MANY regions at once — the thing logic_select_region deliberately cannot do (it is exclusive and single). Modes, each one a real Logic command: 'track' (every region on the anchor's track), 'following' (the anchor and everything after it, on EVERY track), 'following_same_track' (the anchor and everything after it on that track only), 'all' (every region in the project), 'none' (clear the selection). The relative modes need an anchor: track_name, plus region_name and/or start_bar when the track holds more than one region — the anchor is selected exclusively first, then the command extends from it. VERIFICATION: the number of selected regions is counted before and after off the arrangement map, and a mode that moved nothing comes back success: false rather than pretending. The count sees VISIBLE track rows only, while the selection itself is project-wide — a following edit acts on every selected region, counted or not. Uses learned key commands (Logic 12.3.1 names: 'Select All Regions/Cells of Same Track', 'Select All Following', 'Select All Following of Same Track/Pitch', 'Select All', 'Deselect All'); one that is missing from the registry is LEARNED into the user's own Logic key command set on the spot and the result says so.",
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
                description: "Split ONE region at a bar (and optional beat) - the three-call recipe (select, park the playhead, fire 'Split Regions/Events at Playhead Position') as a single call with one verdict. Three failure modes are named and checked in order, and the first two refuse BEFORE anything is written: (1) the split point is not inside the named region - refused with the region's own bar span, nothing moved; (2) the playhead did not land where it was asked to - this parks the sub-beat fields of the control bar's position display as well, which logic_set_playhead does not, because a 'verified' bar/beat can still sit almost a whole beat late and for a split that is a wrong cut rather than a rounding error; (3) the command fired and the arrangement map still shows one region - reported as verification_failed with nothing undone. Success is proven by the map: two regions where one was, both reported. A MIDI SPLIT IS NOT SILENT: when a note crosses the cut, Logic raises a modal ('Notes Crossing Split Point') and freezes until it is answered - this answers it with notes_crossing (default 'split', Logic's own pre-selection) and reports which branch it took, and it cancels any dialog left over on a failure path, because an unanswered modal makes every later tool report 'the command fired and nothing happened'. Undo restores the single region. The halves are NEW regions - re-read logic_list_regions before addressing either of them.",
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
                changesArrangement: true,
                handler: MCPServer.handleSplitRegion
            ),
            Tool(
                name: "logic_move_region",
                description: "Move one region by whole bars and/or beats via Logic's nudge key commands (no dragging, no mouse). Whole-bar moves are verified exactly against the arrangement map.",
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
                description: "Copy (or move, with move: true = Cut) one region to a target bar, optionally onto another track: exclusive select, Copy/Cut, select destination track, park playhead, Paste. Verified by the region appearing at the target bar in the arrangement map.",
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
                description: "Read a region's own parameters out of Logic's Region inspector — the panel at the top of the left inspector that says 'Region: <name>'. This is the read side of logic_set_region_params and the only way to see a region's quantize, transpose, velocity, loop, mute, gain, fades or delay. Pass track_name (plus region_name and/or start_bar) and the region is selected first; call it with no arguments to read whatever is selected. THREE THINGS THE RESULT TELLS YOU BEFORE THE VALUES. `subject` says whose parameters these are: a region, 'multiple' when several are selected (values that differ read as mixed), or 'defaults' — with NOTHING selected the panel shows the TRACK's region defaults ('MIDI Defaults' / 'Audio Defaults'), which is a different thing entirely and is never written by this server. `region_type` is read off the rows Logic published, independently of the arrangement map: a MIDI region has Velocity Offset, Dynamics, Gate Time and the Q-rows, an audio region has Gain, Fine Tune, Fade-In/Out, Reverse and Smart Tempo. And `enabled` per row is load-bearing: Logic greys out every Q-row while Quantize is Off, and a disabled control cannot be written. `display` is Logic's own text for the value and is ABSENT at a parameter's default, because Logic prints the default blank. The panel is opened (and its 'More' section with it) and put back exactly as it was found.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Select this track's region first. Omit to read whatever is selected."],
                        "region_name": ["type": "string", "description": "With track_name: which region."],
                        "start_bar": ["type": "integer", "description": "With track_name: the region's current start bar."],
                        "include_quantize_values": [
                            "type": "boolean",
                            "description": "Also open the Quantize pop-up and return every value Logic offers (note values, triplets, swing A-F, tuplets). Costs a menu open; the menu is always dismissed."
                        ]
                    ],
                    "additionalProperties": false
                ],
                // Selects a region when addressed by name, and toggles the
                // panel's disclosure triangles, which it restores.
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleGetRegionParams
            ),
            Tool(
                name: "logic_set_region_params",
                description: "Set a region's own parameters through Logic's Region inspector: quantize (and its swing and strength), transpose, velocity offset, dynamics, gate time, delay, loop and mute. These are Logic's NON-DESTRUCTIVE playback parameters — the notes are not rewritten, so every one of them is reversible by setting it back, and logic_list_events keeps showing the recorded positions rather than the quantized ones. Pass as many as you like in one call; they are applied in a fixed order with QUANTIZE FIRST, because Logic disables every Q-row while Quantize is Off (so 'quantize to 1/16 with 75% swing' is one call, not two). Each write is read back off Logic's own control and reported as before/after; a parameter already at the requested value is a verified no-op in `unchanged` and nothing is pressed. Compare-and-set with `expected_current` per parameter. VALUES: quantize takes Logic's own menu spelling ('Off', '1/16 Note', '1/8 Swing B', '1/16 Triplet (1/24)' — read the whole list with logic_get_region_params include_quantize_values, and a near miss is refused with the list rather than guessed at); q_swing 1-99 %, q_strength 0-100 %, transpose -96..96 semitones, velocity_offset -99..99, delay_ticks -999..9999 (240 ticks = a 1/16); dynamics and gate_time are Logic's SCALINGS, given by name ('Fixed', '50%', '100%', '125%', '400%', and 'Legato' for gate_time only). SCOPE: the default 'region' selects the named region exclusively and writes to it alone. scope 'selection' writes to every region currently selected (set that up with logic_select_regions) — measured, not assumed: two selected regions both took the write — and it leaves the selection alone. A parameter whose value DIFFERS between the selected regions reads as mixed and cannot be compare-and-set. REFUSED, on purpose: with nothing selected the panel shows the track's region defaults and a write there would change what every future region inherits; audio-only parameters (gain, fades, reverse, fine tune) are not implemented here even though the same panel publishes them.",
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
                name: "logic_set_tempo",
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
                idempotent: true,
                handler: MCPServer.handleSetTempo
            ),
            Tool(
                name: "logic_save_project",
                description: "Save the open Logic project — the ONLY way this server ever saves; no other tool saves as a side effect. Fires the Save key command and verifies via the document's modified flag. Refuses when more than one project is open, when the project has never been saved, or when expected_project_path does not match. Returns already_saved when there is nothing to save.",
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
                description: "Create a NEW Logic project at the given .logicx path — dialog-free, from a bundled empty project template — and open it. Logic runs single-project: if the current project has unsaved changes the call fails unless if_current_modified explicitly chooses 'save' or 'dont_save'. The created project is already saved on disk.",
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
                description: "Duplicate the OPEN project on disk and (by default) open the copy — the safe sandbox for destructive experiments: the original stays untouched. The copy is the on-disk state; pass save_first: true to save unsaved changes into it first. Default destination: '<name> Copy.logicx' next to the original. Opening the copy closes the current project (single-project mode; if_current_modified defaults to 'save' here since the original is the project being closed).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "destination_path": ["type": "string", "description": "Optional .logicx path for the copy."],
                        "save_first": ["type": "boolean", "description": "Save the open project before copying so the copy includes unsaved changes. Default false."],
                        "open_copy": ["type": "boolean", "description": "Open the copy after duplicating. Default true."],
                        // 'fail' is listed because the shared openProject
                        // guard still honours it; the DEFAULT differs here.
                        "if_current_modified": [
                            "type": "string",
                            "enum": ["fail", "save", "dont_save"],
                            "description": "'save' (default here) or 'dont_save' for closing the original when opening the copy."
                        ]
                    ],
                    "additionalProperties": false
                ],
                // Destructive: opening the copy closes the original, with the
                // same discard choice.
                safety: .destructive,
                handler: MCPServer.handleDuplicateProject
            ),
            Tool(
                name: "logic_close_project",
                description: "Close the open project via AppleScript. 'saving' must be an explicit 'yes' or 'no' — there is no default, because discarding versus persisting changes is always the caller's decision.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "saving": [
                            "type": "string",
                            "enum": ["yes", "no"],
                            "description": "'yes' saves before closing; 'no' discards unsaved changes."
                        ],
                        "expected_project_path": ["type": "string"]
                    ],
                    "required": ["saving"],
                    "additionalProperties": false
                ],
                // Destructive: saving 'no' throws unsaved work away.
                safety: .destructive,
                handler: MCPServer.handleCloseProject
            ),
            Tool(
                name: "logic_setup_key_commands",
                description: "One-time onboarding: learn MIDI-note assignments for all standard key commands (Toggle Track Freeze, Undo, Redo, Flashback Capture as Recording, Split at Playhead, Create Marker) into the user's Logic via the Key Commands window automation. Additive to the user's key command set and removable there; collisions with existing assignments get alternate notes automatically. Idempotent — already-learned commands are verified and skipped. Runs automatically the first time a tool needs a missing command, so calling this explicitly is optional. Pass relearn: true to force re-learning even for commands that look bound — the repair when key commands silently stopped firing (e.g. after the MIDI ports were recreated: Logic scopes the assignments to the port identity).",
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
                description: "Learn ANY command in Logic's Key Commands window - not just the standard set - onto a MIDI note, so logic_trigger_key_command can fire it. Give the command's name EXACTLY as the Key Commands window spells it (e.g. 'Strip Silence…', 'Bounce Regions in Place', 'Select All Following of Same Track'); the search field is driven with the first words of that name unless you pass 'search' yourself. THIS WRITES INTO THE USER'S OWN LOGIC KEY COMMAND SET: the command gains an additional assignment on the dedicated 'Logic MCP Commands' MIDI port. It is additive - the user's existing keyboard shortcut is untouched - and removable in the same window (select the command, Delete Assignment). The MIDI note is chosen automatically from a range reserved for learned commands (60-99, then 122-127, then 21-59), so it can never take a note the product's own standard commands want; pass 'note' only to force one. The registry file is the consent record and records the name, note, timestamp, search term and that THIS tool bound it - read it back with logic_list_key_commands. Already-registered commands answer immediately without opening the window (pass relearn: true to bind again, the repair after MIDI ports were recreated). When no row matches, the failure is not_found and it LISTS the rows the panel was showing: command names drift between Logic versions, so a near miss is answered with the real spellings rather than a guess.",
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
                idempotent: true,
                handler: MCPServer.handleLearnKeyCommand
            ),
            Tool(
                name: "logic_list_key_commands",
                description: "List what the key command registry holds: every command name that has been learned onto the 'Logic MCP Commands' MIDI port, its note and channel, when it was learned, and which tool bound it. Read-only and Logic-free - this reads the registry FILE, so an entry it lists can still have been orphaned inside Logic (recreated MIDI ports do that silently; logic_setup_key_commands with relearn: true repairs it). The registry is what logic_trigger_key_command checks before firing anything, so this is also the list of commands an agent may fire. Also reports which standard commands are not learned yet.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleListKeyCommands
            ),
            Tool(
                name: "logic_trigger_key_command",
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
                description: "Render ONE track offline to an audio file ON DISK with ZERO dialogs, via Track Freeze. NOT bounce-in-place: it produces a FILE, it does not commit a new audio region into the project, so it is not the tool for 'print that so I can chop it' - resampling a part back into the arrangement has no route in this server yet. Mechanism: selects the track, toggles freeze over the 'Logic MCP Commands' MIDI port, presses play (Logic then renders the whole track offline, typically seconds), copies the 32-bit float AIFF out of Media/Freeze Files to the captures folder, and unfreezes again. Requires 'Toggle Track Freeze' in the key command registry and the MCU bridge running. Renders the full track from project start including all plugins and automation (freeze mode Pre Fader). If the track is already frozen the call fails safely and restores state. TEMPO: with start_bar/end_bar the slice's boundaries are integrated over the project's tempo map, read out of Logic's Tempo List (View > List Editors > Tempo; ~2 s, no playhead movement, cached per project and reported in tempo_map). When the Tempo List cannot be read the slice falls back to constant-tempo bar math and the tempo is sampled at both ends of the range instead (parks the playhead, reads, restores), with a `warning` naming both readings when they differ — the FULL render is unaffected either way. Without a bar range no tempo is read at all.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Track to render, matched against MCU LCD names or AX track headers."],
                        "track_number": ["type": "integer", "description": "Optional AX row number to disambiguate duplicates."],
                        "label": ["type": "string", "description": "Filename label; default is derived from the track name."],
                        "start_bar": ["type": "integer", "description": "With end_bar: also cut this bar range out of the render as a separate 32-bit float WAV with its own metrics (bar 1 = project start)."],
                        "end_bar": ["type": "integer", "description": "Exclusive: the slice ends where this bar begins."],
                        "tempo": ["type": "number", "description": "Override BPM for the bar math; default reads the control bar. Only used when the tempo map cannot be read from the Tempo List — a readable map is integrated instead. Constant METER is still assumed (signature changes are not read)."],
                        "beats_per_bar": ["type": "number", "description": "Override meter; default reads the control bar's time signature."],
                        "expected_project_path": ["type": "string", "description": "Absolute .logicx path; when given, the open project's AXDocument must match before anything is changed."],
                        "include_audio": MCPServer.includeAudioProperty
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ],
                // Freezes and unfreezes the track; a new file per call.
                safety: .write,
                handler: MCPServer.handleRenderTrack
            ),
            Tool(
                name: "logic_mcu_command",
                description: "Send a command to Logic through the Mackie Control bridge (UI-independent). cmd is one of: press {button: play|stop|record|rewind|forward|cycle|click|bank_left|bank_right|channel_left|channel_right|flip|name_value|assign_track|assign_send|assign_pan|assign_plugin|assign_eq|assign_instrument|...}, select/mute/solo {channel: 0-7}, fader {channel: 0-8, value: 0-16383}, vpot {index: 0-7, delta: +-n}, vpot_press {index}, raw {bytes: [..]}, ping. Read logic_mcu_status afterwards to verify via Logic's feedback.",
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
                description: "LISTEN to rendered audio: returns a short clip (default 8 s, max 20 s) of a local audio file as an MCP audio content block (mono AAC, roughly 64 KB per 8 s) that multimodal models can hear. Use this on the file paths returned by logic_render_track / logic_bounce_range / logic_evaluate_change. NEVER read raw audio files with a text/file tool - megabytes of binary will overflow the model context and can crash the client. Also writes the clip to disk (clip_path in the result): if the audio block does NOT reach you, your client drops MCP audio - open clip_path with your client's file viewer instead, which most clients pass to the model as real audio.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path to a local audio file (AIFF/WAV/etc)."],
                        "start_seconds": ["type": "number", "minimum": 0, "description": "Offset into the file, default 0."],
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
                description: "Read the transport state from the control bar: playing, recording, cycle, playhead bar/beat, tempo, time signature, key signature, metronome, count-in. Read-only. Fields whose control bar element is missing are null.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleGetTransport
            ),
            Tool(
                name: "logic_set_cycle",
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
                description: "Add a plugin to a track's first empty insert slot — mouse-free via the Mackie Control plugin browser (vpot-stepped, LCD-verified, vpot-press instantiates). Works for every plugin in Logic's browser including third-party. If the MCU bridge is down, the AX chooser fallback requires allow_mouse: true because it briefly takes over the pointer."
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
                handler: MCPServer.handleAddPlugin
            ),
            Tool(
                name: "logic_remove_plugin",
                description: "Remove a plugin from a track — mouse-free via the Mackie Control plugin browser's No Plug-in entry (can take up to ~60 s of vpot stepping; verified via LCD and an AX cross-check on the named track). If the MCU bridge is down, the AX chooser fallback requires allow_mouse: true because it briefly takes over the pointer."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "plugin_name": ["type": "string"],
                        "insert_index": ["type": "integer"],
                        "allow_mouse": ["type": "boolean", "description": "Permit the Accessibility chooser fallback, which moves the pointer. Default false (data-driven MCU browser only)."],
                        "expected_project_path": ["type": "string", "description": "Refuse unless this is the open project."]
                    ],
                    "required": ["track_name", "plugin_name"],
                    "additionalProperties": false
                ],
                // Destructive: the plugin and its settings go. Idempotent: the
                // target state is 'absent'.
                safety: .destructive,
                idempotent: true,
                handler: MCPServer.handleRemovePlugin
            ),
            Tool(
                name: "logic_set_track_mute",
                description: "Mute or unmute a track via its inspector channel strip mute button, verified by readback (control surface first, inspector strip as fallback)."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "enabled": ["type": "boolean"]
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
                description: "Solo or unsolo a track via its inspector channel strip solo button, verified by readback (control surface first, inspector strip as fallback)."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "enabled": ["type": "boolean"]
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
                description: "Set a track's volume fader to a target dB value (e.g. -14.2, 0.0) by converging the inspector strip fader against its dB readout. Reports before/after dB. Fader steps are about 0.1-0.3 dB apart; default tolerance 0.15 dB."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "db": ["type": "number"],
                        "tolerance_db": ["type": "number"]
                    ],
                    "required": ["track_name", "db"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleSetTrackVolume
            ),
            Tool(
                name: "logic_set_track_pan",
                description: "Set a track's pan/balance knob position (integer, typically -64..63 where 0 is center) via the inspector strip, verified by readback."
                    + Tool.stripAddressingNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "position": ["type": "integer"]
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
                description: "Open the plugin window for one insert on the named (selected) track by pressing the insert's open button, then verify that the window appeared. If the window was already open it is identified via its toggle behaviour and restored. Fails closed on not_found, ambiguous (two inserts with the same plugin), not_exposed and verification_failed.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "plugin_name": ["type": "string", "description": "Plugin display name; truncated slot names such as 'Space D' match by prefix."],
                        "insert_index": ["type": "integer", "description": "1-based ACCESSIBILITY insert ordinal, as logic_list_inserts numbers them; required when the same plugin occupies several slots. NOT the Mackie insert_slot the logic_mcu_* tools take."],
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
                description: "Close the plugin window of one insert on the named (selected) track by toggling the insert's open button, verifying that a window disappeared. Precise even when several plugin windows share the same title. If the plugin was not open, the accidentally opened window is closed again and precondition_failed is returned.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "plugin_name": ["type": "string"],
                        "insert_index": ["type": "integer", "description": "1-based ACCESSIBILITY insert ordinal (logic_list_inserts); required when the same plugin occupies several slots. NOT the Mackie insert_slot."]
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
                description: "Close one plugin window by pressing its close button and verifying it disappeared. Refuses to close project windows (any window with a document) and fails with ambiguous when several windows share the title.",
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
                description: "List the parameters an open Logic plugin window exposes to Accessibility, with each one's current formatted value. `ax_writable` says whether logic_set_plugin_parameter can WRITE that parameter: Logic reads a plugin through its sliders and writes it through its editable \"knob and field\" controls, and knob-only plugins publish sliders but no field at all (Channel EQ 26 sliders / 0 fields, Limiter 4 / 0, measured 2026-08-28). When everything comes back `ax_writable: false` the plugin is read-only from this plane — write it with logic_mcu_set_plugin_parameter over the control surface instead.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "window_title": ["type": "string", "description": "Exact Logic plugin window title, usually the track name."]
                    ],
                    "required": ["window_title"],
                    "additionalProperties": false
                ],
                safety: .readOnly,
                idempotent: true,
                handler: MCPServer.handleListPluginParameters
            ),
            Tool(
                name: "logic_list_events",
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
                idempotent: true,
                handler: MCPServer.handleListEvents
            ),
            Tool(
                name: "logic_markers",
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
                handler: MCPServer.handleMarkers
            ),
            Tool(
                name: "logic_list_signatures",
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
                description: "Bypass or un-bypass one insert — the fastest honest A/B in mixing, and the write side of the bypass state logic_list_inserts has always been able to READ. Address the insert by plugin_name, by insert_index, or both (both is safest: a name that does not match the slot at that index is refused). insert_index is the ACCESSIBILITY ordinal from logic_list_inserts, NOT the Mackie insert_slot the logic_mcu_* tools take. Compare-and-set with expected_current_bypassed; an insert already in the requested state is a verified no-op (already_bypassed / already_active) rather than a blind toggle, because this control publishes only AXPress and no absolute write. Verified by re-reading the same checkbox. LIVE-VERIFIED 2026-08-28: the press works and is confirmed by logic_list_inserts - a Channel EQ on a track went active -> bypassed -> active, with the no-op path (already_bypassed) taking the middle call. Pass expected_current_bypassed anyway; it is what turns a stale idea of the state into a refusal instead of a wrong toggle."
                    + Tool.stripAddressingAXNote,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer", "description": "Disambiguates duplicate track names; tracks only."],
                        "plugin_name": ["type": "string", "description": "Plugin display name as logic_list_inserts shows it; truncated names such as 'Space D' match by prefix."],
                        "insert_index": ["type": "integer", "description": "1-based ACCESSIBILITY insert ordinal from logic_list_inserts."],
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
                description: "Open or close Logic's Mixer window (Window > Open Mixer), verified against the window list. WHAT THE MIXER DOES AND DOES NOT DO (measured live 2026-08-28, so this is observation, not hope): the Mixer window publishes EVERY channel strip to Accessibility - the result lists them in `mixer_strips`, Master, Stereo Out and the auxes included - but they are NOT inspector strips, and the Accessibility strip tools (logic_list_inserts, logic_survey_plugins, logic_open_plugin, logic_plugin_preset, logic_set_insert_bypass) still cannot address them: with the Mixer open, logic_list_inserts on Master fails exactly as it does with the Mixer closed. `inspector_strips` is the list those tools CAN reach (the selected track and its output). For Master, an aux or a bus, use the logic_mcu_* tools, which never needed a window. AND IT COSTS SOMETHING: the Mixer is a second document window carrying the same project, so it can shadow the project window - while Logic is in the background it may be the only window Accessibility publishes, and then every track-header read fails. This server skips Mixer windows when it resolves the project window, but close the Mixer when you are done anyway. What it is genuinely good for: putting the Mixer in front of a HUMAN, and reading the complete strip census out of the window.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "open": ["type": "boolean", "description": "true opens the Mixer, false closes it."]
                    ],
                    "required": ["open"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleSetMixer
            ),
            Tool(
                name: "logic_set_plugin_parameter",
                description: "Set one accessible plugin parameter through its formatted text field, then read it back. Restores the prior value on verification failure. Only parameters logic_list_plugin_parameters marks `ax_writable` can be set this way — a knob-only plugin (Channel EQ, Limiter) is refused with not_exposed naming logic_mcu_set_plugin_parameter, which reaches every plugin over the control surface.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "window_title": ["type": "string"],
                        "parameter": ["type": "string"],
                        "expected_current_value": ["type": "string"],
                        "target_value": ["type": "string"]
                    ],
                    "required": ["window_title", "parameter", "expected_current_value", "target_value"],
                    "additionalProperties": false
                ],
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleSetPluginParameter
            ),
            Tool(
                name: "logic_list_strips",
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
                description: "The whole mixer in ONE call, off Logic's own control-surface feedback: per strip the fader value in dB, pan, mute/solo/select/record-arm state and the raw 14-bit fader echo. volume_db is the dB string Logic paints in its channel-strip Volume view — the same readout logic_set_track_volume converges against — NOT a conversion of the fader position, which is reported separately and raw as fader_14bit; a cell that does not parse comes back null with the LCD text beside it, never interpolated. record_armed is sampled across a full blink cycle because Logic FLASHES an armed strip's record LED (~640 ms on / 640 ms off, measured), so a single instant would report half the armed strips as unarmed. Two bank walks (names and pan, then dB and LEDs), about 16 s on a 25-strip project; the surface is left in the pan view at the leftmost bank."
                    + " Strip identity is established by a fresh scan, never from the cached bank map, and follows the same track_name/'unresolved' rule as logic_list_strips.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                // Not read-only: banks the surface and switches its view.
                safety: .write,
                idempotent: true,
                handler: MCPServer.handleMixerSnapshot
            ),
            Tool(
                name: "logic_set_track_record_arm",
                description: "Arm or disarm a track for recording — the control surface's rec/ready button (MCU note 0x00-0x07), verified by Logic's own record LED AND, independently, by the track header's Record Enable checkbox. Compare-and-set: a track already in the requested state is reported as already_armed/already_disarmed and nothing is pressed. Logic FLASHES the record LED of an armed strip (~640 ms on / 640 ms off), so the LED evidence is a window rather than an instant: seen lit once means armed, and only a whole quiet window is read as disarmed. Several tracks can be armed at once, so arming one does NOT disarm another — read logic_mixer_snapshot before rolling if that matters. Output, aux, bus and master strips have no record enable and are refused before anything is pressed. Needs the MCU bridge: there is no Accessibility-only route.",
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
                idempotent: true,
                handler: MCPServer.handleSetTrackRecordArm
            ),
            Tool(
                name: "logic_set_metronome",
                description: "Turn the metronome click on or off via the control surface's click button, verified by reading the control bar's own Metronome Click checkbox back (the same field logic_get_transport reports), with the surface's click LED as a second source. Compare-and-set: already-correct is reported and nothing is pressed; a press that does not land is undone. Count-in is a separate setting and is not touched.",
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
                handler: MCPServer.handleSetMetronome
            ),
            Tool(
                name: "logic_load_instrument",
                description: "Load a software instrument into a track's INSTRUMENT slot — mouse-free via the control surface's instrument browser (the IN bank view's vpot), the slot logic_add_plugin cannot reach because it fills an insert instead. One vpot tick per browser entry, the shown entry re-verified after settling, and a vpot press instantiates; leaving the view cancels a browse without loading anything. Entries carry Logic's channel format ('Drum Kit Designer Stereo', 'Drum Kit Designer Multi-Output', 'Abbey Road Saturator (m) Mono'), so instrument may be given bare or with the format, or the format passed separately; matching is case-insensitive and exact on the name — a near miss is refused with the entries seen, never guessed at. Verified by the instrument slot's own name in the IN bank view; read the loaded instrument's parameters with logic_mcu_instrument_parameters as an independent second look. REPLACES any instrument already on the track, settings and all — Logic's Undo is the only way back.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Software-instrument track to load onto."],
                        "instrument": ["type": "string", "description": "Instrument name as Logic's browser shows it, e.g. 'Drum Kit Designer', 'Sampler', 'Analog Lab V'. May include the format ('Drum Kit Designer Stereo')."],
                        "format": ["type": "string", "description": "Channel format to pick when a plugin offers several: 'Stereo', 'Mono' or 'Multi-Output'. Default: the first entry whose name matches, and the result reports which format that was."],
                        "max_steps": ["type": "integer", "description": "How many browser entries to step through before giving up, default 1200 (~0.11 s each, so a full sweep of a large plug-in library can take a couple of minutes). The list holds every installed instrument in every channel format and is NOT alphabetical, so a 'never showed' refusal at a low cap usually means the browse had not reached it yet, not that the name is wrong."],
                        "expected_project_path": ["type": "string", "description": "Refuse unless this is the open project."]
                    ],
                    "required": ["track_name", "instrument"],
                    "additionalProperties": false
                ],
                // Replaces whatever instrument the track had, with its settings.
                safety: .destructive,
                idempotent: true,
                changesSound: true,
                handler: MCPServer.handleLoadInstrument
            ),
            Tool(
                name: "logic_read_automation",
                description: "READ an existing automation curve before you overwrite it — volume, pan, a send level or any plugin parameter — over a bar range. Read-only: no automation mode is changed, no fader or vpot is moved, and the playhead is returned to where it started. Mechanism: park the playhead at each sampled position and read the value Logic chases the lane to, which is the verification pass logic_record_automation already runs, with the writing half removed. HONESTY: these are SAMPLES, not the lane's breakpoints — a move that happens entirely between two samples is invisible, so lower resolution_beats when the shape matters — and an unautomated lane reads as a flat line at the track's static value, which the result says rather than implying a curve exists. Positions run from start_bar beat 1 to end_bar beat 1 inclusive; if the grid would exceed max_points the step is widened rather than the range truncated. Costs roughly a second per sampled position.",
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
                        "insert_slot": ["type": "integer", "minimum": 1, "maximum": 8, "description": "MCU physical insert slot 1-8, required when parameter is 'plugin' (list with logic_mcu_plugin_inserts)."],
                        "plugin_parameter": ["type": "string", "description": "Parameter name as shown on the MCU, required when parameter is 'plugin'."],
                        "start_bar": ["type": "integer", "minimum": 1],
                        "end_bar": ["type": "integer", "description": "Inclusive: the last sampled position is this bar's beat 1."],
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
        "description": "Attach the rendered audio as MCP audio content blocks (default true). Pass false ONLY if your client does not forward audio blocks to the model: the result then carries the file paths alone (a few hundred KB of base64 that your client would have turned into text is skipped), and you listen by opening those paths with your client's file viewer."
    ] }

    /// What `tools/list` puts on the wire, derived from the registry —
    /// never a second list that could drift from it.
    func toolDefinitions() -> [[String: Any]] {
        toolRegistry().map(\.definition)
    }
}
