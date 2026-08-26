import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCPServer {
    func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "logic_health",
                "description": "Read Logic Pro process and Accessibility readiness without changing Logic.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
            ],
            [
                "name": "logic_list_windows",
                "description": "List Logic windows with subrole and project document path, read-only. Windows whose document is set are project windows; dialogs without a document are plugin or auxiliary windows.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
            ],
            [
                "name": "logic_list_tracks",
                "description": "List the track headers currently rendered in the Tracks area (track number, name, selected), read-only. Scrolled-out or hidden tracks are not exposed by Logic.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
            ],
            [
                "name": "logic_list_inserts",
                "description": "List audio-effect insert slots (index, plugin display name, bypass state) of the named track's channel strip, read-only. The track must be selected so its strip is shown in the left inspector; otherwise the error not_exposed reports which track is currently shown.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Exact track name as shown in the track header."]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_bounce_range",
                "description": "Offline-bounce a bar range of the master output to an audio file, many times faster than realtime playback. Drives Logic's bounce dialog and its XPC save panel entirely through verified accessibility (no playback). Temporarily switches the bounce destination to Uncompressed and restores the user's selection afterwards. Returns the file path.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "start_bar": ["type": "integer"],
                        "end_bar": ["type": "integer"],
                        "label": ["type": "string", "description": "Filename label, e.g. 'A' or 'baseline'."],
                        "expected_project_path": ["type": "string"]
                    ],
                    "required": ["start_bar", "end_bar"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_evaluate_change",
                "description": "Run one complete closed-loop mix evaluation around exactly one verified plugin-parameter change, on a bar range. Three methods: 'render' (two dialog-free freeze renders of the SINGLE track, compared on the sliced bar range — fastest and most isolated; needs insert_slot, the MCU physical slot, and works for all plugins including third-party), 'bounce' (two offline MASTER renders via the bounce dialog, needs plugin_name), and 'solo_bounce' (two offline bounces with ONLY this track soloed, solo restored after; needs insert_slot like 'render' — use for tracks freeze refuses: stack subtracks and tracks sharing a channel strip). All methods roll the change back by default, return baseline/after audio paths, metrics and dB deltas, and CARRY both versions as audio content blocks.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "plugin_name": ["type": "string", "description": "Plugin window title; required for methods 'realtime' and 'bounce'."],
                        "insert_index": ["type": "integer"],
                        "insert_slot": ["type": "integer", "description": "MCU physical insert slot 1-8; required for methods 'render' and 'solo_bounce' (list with logic_mcu_plugin_inserts)."],
                        "parameter": ["type": "string"],
                        "expected_current_value": ["type": "string"],
                        "target_value": ["type": "string"],
                        "start_bar": ["type": "integer"],
                        "end_bar": ["type": "integer", "description": "Exclusive: the range ends where this bar begins."],
                        "method": ["type": "string", "description": "REQUIRED: 'render' (dialog-free single-track freeze A/B on the sliced bar range), 'bounce' (offline master A/B) or 'solo_bounce' (soloed offline A/B for tracks freeze refuses: stack subtracks, shared-channel tracks)."],
                        "tempo": ["type": "number", "description": "Override BPM for bar math (method 'render'); default reads the control bar. Constant tempo assumed."],
                        "beats_per_bar": ["type": "number", "description": "Override meter for bar math; default reads the control bar's time signature."],
                        "keep_change": ["type": "boolean", "description": "true keeps the change after measuring; default false rolls it back."],
                        "verify_rollback": ["type": "boolean", "description": "Measure a third control window after rollback (default false; rollback accuracy has been verified at ~0.0 dB residual repeatedly)."],
                        "settle_seconds": ["type": "number", "description": "Extra settle time after each phase, default 2."],
                        "expected_project_path": ["type": "string"]
                    ],
                    "required": ["track_name", "parameter", "expected_current_value", "target_value", "start_bar", "end_bar"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_mcu_plugin_inserts",
                "description": "List a track's insert slots as the Mackie Control sees them (physical slot numbers 1-8 with plugin names), via the selected track's MCU plugin list. Works for ALL plugins including custom-UI third-party ones. Selects the track first.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_mcu_plugin_parameters",
                "description": "Read ALL of a plugin's parameter names and formatted values (every MCU page) via host automation — works for plugins whose UI exposes nothing to Accessibility (Decapitator, Trilian, ...). insert_slot is the MCU physical slot from logic_mcu_plugin_inserts.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "max_pages": ["type": "integer", "description": "Page cap, default 12 (each uncached page costs ~1.7 s; large instruments have 80+). pages_total and truncated report what was left out."],
                        "track_number": ["type": "integer"],
                        "insert_slot": ["type": "integer"]
                    ],
                    "required": ["track_name", "insert_slot"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_mcu_set_plugin_parameter",
                "description": "Set one plugin parameter through host automation (MCU vpot) with the LCD value echo as verified readback — the data-plane route that reaches every plugin. Numeric targets converge adaptively; text targets (e.g. 'On', 'B') step until exact match. Optional expected_current_value enforces compare-and-set; failed verification rolls back. Parameter is matched against the MCU's abbreviated names (e.g. 'Thrs' matches 'Threshold').",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "insert_slot": ["type": "integer"],
                        "parameter": ["type": "string"],
                        "target_value": ["type": "string"],
                        "expected_current_value": ["type": "string"],
                        "tolerance": ["type": "number"]
                    ],
                    "required": ["track_name", "insert_slot", "parameter", "target_value"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_mcu_instrument_parameters",
                "description": "Read the INSTRUMENT slot's parameter names and formatted values (all MCU pages) for a track via host automation — reaches software instruments whose UIs expose nothing to Accessibility (Q-Sampler, Trilian, ...).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "max_pages": ["type": "integer", "description": "Page cap, default 12 (each uncached page costs ~1.7 s; large instruments have 80+). pages_total and truncated report what was left out."],
                        "track_number": ["type": "integer"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_mcu_set_instrument_parameter",
                "description": "Set one INSTRUMENT parameter through host automation (MCU vpot) with LCD echo readback, same converge/step semantics and compare-and-set contract as logic_mcu_set_plugin_parameter.",
                "inputSchema": [
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
                ]
            ],
            [
                "name": "logic_mcu_status",
                "description": "Read the Mackie Control bridge's mirrored state: LCD text (track names/values as data), fader positions, transport LEDs, timecode display, online status. This is Logic's documented control-surface feedback channel — no UI, no focus, no windows involved. Requires logic-mcu-bridge running and a Mackie Control configured in Logic pointing at the 'Logic MCP MCU' ports.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
            ],
            [
                "name": "logic_mcu_sends",
                "description": "List a track's sends as data via the Mackie Control channel send view: slot number, destination bus, level in dB, position (pre/post fader) and status. UI-independent; competitors' MCPs do not expose sends at all.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "expected_project_path": ["type": "string"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_mcu_set_send",
                "description": "Set one send's level in dB on a track, verified through the MCU LCD echo (compare-and-set with expected_current_value, readback, same discipline as plugin parameters). Only the level vpot is touched — never the destination. List sends first with logic_mcu_sends.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "send": ["type": "integer", "description": "Send slot 1-8."],
                        "level_db": ["type": "number", "description": "Target level in dB, e.g. -9.0."],
                        "expected_current_value": ["type": "string", "description": "Abort unless the current LCD value matches (e.g. '-9.0dB' or '-9.0')."],
                        "expected_project_path": ["type": "string"]
                    ],
                    "required": ["track_name", "send", "level_db"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_record_automation",
                "description": "Write an automation curve on a track — volume (absolute fader), pan, a send level (send: 1-8) or ANY plugin parameter (insert_slot + plugin_parameter) — with no mouse and no automation-lane clicking. The value scale follows the parameter: dB for volume/sends, -64..63 for pan, the plugin's own units otherwise. Mechanism: calibrate the control near the working range, switch the track to Latch over the control surface, roll playback placing calibrated moves at each musical moment, return to Read, restore the original value, and verify by REPLAYING the range while sampling Logic's own echo at every point. ramp (default true) interpolates between points. Points need bar >= 2. Takes real time (the automated range, twice with verify)",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "parameter": ["type": "string", "description": "v1: 'volume' only."],
                        "points": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "bar": ["type": "integer"],
                                    "beat": ["type": "number", "description": "1-based, fractions allowed. Default 1."],
                                    "db": ["type": "number", "description": "Target volume in dB, e.g. -12.0."]
                                ],
                                "required": ["bar", "db"]
                            ]
                        ],
                        "ramp": ["type": "boolean", "description": "Default true: smooth linear ramps between points."],
                        "verify": ["type": "boolean", "description": "Default true: replay the range in Read and sample the fader echo per point."]
                    ],
                    "required": ["track_name", "points"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_record_midi",
                "description": "Compose MIDI into the project with ZERO dialogs and no files: notes are streamed in real time over the dedicated 'Logic MCP MIDI In' port while Logic records them onto the selected software-instrument track (playhead parked one bar early; the stream starts on the observed MCU-timecode crossing into start_bar, so count-in settings do not matter). Creates a normal recorded region. By default the result is verified with a dialog-free freeze render of the recorded bars (non-silent metrics prove the notes landed and sound through the instrument). Recording takes real time: bars x beats x 60/BPM seconds. The region can be removed with Undo in Logic.",
                "inputSchema": [
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
                                    "pitch": ["description": "MIDI number 0-127 or a name like 'C3' (= MIDI 60, Logic convention), 'F#1', 'Bb2'."],
                                    "bar": ["type": "integer", "description": "Absolute bar position (1 = project start)."],
                                    "beat": ["type": "number", "description": "Beat within the bar, 1-based; fractions allowed (1.5 = offbeat). Default 1."],
                                    "duration_beats": ["type": "number", "description": "Length in beats. Default 1."],
                                    "velocity": ["type": "integer", "description": "1-127, default 100."],
                                    "channel": ["type": "integer", "description": "MIDI channel 1-16, default 1."]
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
                                    "cc": ["type": "integer", "description": "Controller number 0-127."],
                                    "value": ["type": "integer", "description": "0-127."],
                                    "channel": ["type": "integer", "description": "1-16, default 1."]
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
                                    "value": ["type": "integer"],
                                    "channel": ["type": "integer"]
                                ],
                                "required": ["bar", "value"]
                            ]
                        ],
                        "start_bar": ["type": "integer", "description": "Recording start bar (>= 2); default = the earliest event's bar."],
                        "tempo": ["type": "number", "description": "Override BPM; default reads the control bar."],
                        "beats_per_bar": ["type": "number", "description": "Override meter; default reads the control bar."],
                        "verify_render": ["type": "boolean", "description": "Default true: freeze-render the recorded bars afterwards and return slice metrics as proof."],
                        "speed": ["type": "number", "description": "Optional fast mode: record at speed x tempo (1-8, default 1) and scale event times — same bar positions in a fraction of the wall time. Default 1 keeps real-time recording so the take is audible as it happens; higher speeds trade timing precision (jitter scales with speed) and chipmunked monitoring."],
                        "sync_compensation_ms": ["type": "number", "description": "Timecode display latency compensated in the beat-edge sync, default 45 ms (measured). Raise if notes land early, lower if late."],
                        "expected_project_path": ["type": "string"]
                    ],
                    "required": ["track_name", "notes"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_plugin_preset",
                "description": "Step a plugin's factory/user preset (next/previous, N steps) via Logic's topmost-plugin-window key command: the plugin window is opened (and closed again if this call opened it), the command fired, and the change verified against the window's preset label. Preset before/after names are returned.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "plugin_name": ["type": "string"],
                        "insert_index": ["type": "integer"],
                        "track_number": ["type": "integer"],
                        "direction": ["type": "string", "description": "'next' (default) or 'previous'."],
                        "steps": ["type": "integer", "description": "How many presets to step, default 1."]
                    ],
                    "required": ["track_name", "plugin_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_rename_track",
                "description": "Rename a track by writing the channel strip's name field (element-addressed AX). Verified against the track headers.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "new_name": ["type": "string"]
                    ],
                    "required": ["track_name", "new_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_duplicate_track",
                "description": "Duplicate a track via Logic's Duplicate Track key command (learned automatically). Verified by the track count increasing.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_delete_track",
                "description": "DESTRUCTIVE: delete a track via the Delete Track key command. The selection is re-verified to be the named track immediately before firing, and the result is verified against the track list. Undo restores.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer", "description": "Recommended for duplicate names."]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_add_send",
                "description": "Create a send on a track to a bus/output — mouse-free via the control surface's send-destination browser (first empty slot, browsed to the named destination, settle-verified, confirmed). New sends start at -oo dB; set the level with logic_mcu_set_send. Destination names as Logic shows them, e.g. 'Bus 1', 'Bus 2'.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "destination": ["type": "string", "description": "e.g. 'Bus 3'."]
                    ],
                    "required": ["track_name", "destination"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_create_track",
                "description": "Create a new track (software_instrument or audio) via Logic's key command, answering the Create New Track dialog automatically. Verified by the track count increasing.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "type": ["type": "string", "description": "'software_instrument' (default) or 'audio'."]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_list_regions",
                "description": "The arrangement map: every region on every visible track row, with name, start/end bar (and beat when off the barline), type (midi/audio) and selection state — parsed from Logic's own accessibility descriptions. Read-only. Optionally filter to one track.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Optional: only this track's regions."]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_select_region",
                "description": "Select exactly one region (by track + region_name and/or start_bar; ambiguity is refused with candidates listed). exclusive (default true) clears all other region selections first, so a following edit key command (cut/copy/delete/nudge) touches only this region. Verified via the element's selection state.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "region_name": ["type": "string"],
                        "start_bar": ["type": "integer"],
                        "exclusive": ["type": "boolean", "description": "Default true: clear other selections first."]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_delete_region",
                "description": "DESTRUCTIVE: delete one region (selected exclusively first; refuses unless exactly ONE region is selected project-wide right before Delete fires). Verified against the arrangement map; Undo restores.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "region_name": ["type": "string"],
                        "start_bar": ["type": "integer"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_move_region",
                "description": "Move one region by whole bars and/or beats via Logic's nudge key commands (no dragging, no mouse). Whole-bar moves are verified exactly against the arrangement map.",
                "inputSchema": [
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
                ]
            ],
            [
                "name": "logic_copy_region",
                "description": "Copy (or move, with move: true = Cut) one region to a target bar, optionally onto another track: exclusive select, Copy/Cut, select destination track, park playhead, Paste. Verified by the region appearing at the target bar in the arrangement map.",
                "inputSchema": [
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
                ]
            ],
            [
                "name": "logic_set_tempo",
                "description": "Set the project tempo in BPM via the control bar's tempo display (rapid-fire stepwise converge, ~1.3 s per 120 BPM of distance). Whole-BPM resolution. Compare-and-set with expected_current_bpm. Assumes constant project tempo.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "bpm": ["type": "number", "description": "Target tempo, 5-990."],
                        "expected_current_bpm": ["type": "number", "description": "Abort unless the current tempo matches."]
                    ],
                    "required": ["bpm"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_save_project",
                "description": "Save the open Logic project — the ONLY way this server ever saves; no other tool saves as a side effect. Fires the Save key command and verifies via the document's modified flag. Refuses when more than one project is open, when the project has never been saved, or when expected_project_path does not match. Returns already_saved when there is nothing to save.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "expected_project_path": ["type": "string", "description": "Recommended: absolute .logicx path that must match the open project."]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_new_project",
                "description": "Create a NEW Logic project at the given .logicx path — dialog-free, from a bundled empty project template — and open it. Logic runs single-project: if the current project has unsaved changes the call fails unless if_current_modified explicitly chooses 'save' or 'dont_save'. The created project is already saved on disk.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute destination path ending in .logicx; must not already exist."],
                        "if_current_modified": ["type": "string", "description": "'fail' (default), 'save' or 'dont_save' — what to do with the currently open project's unsaved changes."]
                    ],
                    "required": ["path"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_open_project",
                "description": "Open an existing .logicx project. Single-project semantics as logic_new_project: unsaved changes in the current project require an explicit if_current_modified decision.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path to an existing .logicx."],
                        "if_current_modified": ["type": "string", "description": "'fail' (default), 'save' or 'dont_save'."]
                    ],
                    "required": ["path"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_duplicate_project",
                "description": "Duplicate the OPEN project on disk and (by default) open the copy — the safe sandbox for destructive experiments: the original stays untouched. The copy is the on-disk state; pass save_first: true to save unsaved changes into it first. Default destination: '<name> Copy.logicx' next to the original. Opening the copy closes the current project (single-project mode; if_current_modified defaults to 'save' here since the original is the project being closed).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "destination_path": ["type": "string", "description": "Optional .logicx path for the copy."],
                        "save_first": ["type": "boolean", "description": "Save the open project before copying so the copy includes unsaved changes. Default false."],
                        "open_copy": ["type": "boolean", "description": "Open the copy after duplicating. Default true."],
                        "if_current_modified": ["type": "string", "description": "'save' (default here) or 'dont_save' for closing the original when opening the copy."]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_close_project",
                "description": "Close the open project via AppleScript. 'saving' must be an explicit 'yes' or 'no' — there is no default, because discarding versus persisting changes is always the caller's decision.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "saving": ["type": "string", "description": "'yes' saves before closing; 'no' discards unsaved changes."],
                        "expected_project_path": ["type": "string"]
                    ],
                    "required": ["saving"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_setup_key_commands",
                "description": "One-time onboarding: learn MIDI-note assignments for all standard key commands (Toggle Track Freeze, Undo, Redo, Flashback Capture as Recording, Split at Playhead, Create Marker) into the user's Logic via the Key Commands window automation. Additive to the user's key command set and removable there; collisions with existing assignments get alternate notes automatically. Idempotent — already-learned commands are verified and skipped. Runs automatically the first time a tool needs a missing command, so calling this explicitly is optional. Pass relearn: true to force re-learning even for commands that look bound — the repair when key commands silently stopped firing (e.g. after the MIDI ports were recreated: Logic scopes the assignments to the port identity).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "relearn": ["type": "boolean", "description": "Force re-learning of every standard command even when an assignment is already shown. Repairs bindings orphaned by MIDI-port changes. Default false."],
                        "commands": ["type": "array", "items": ["type": "string"], "description": "Limit to these standard command names (default: all)."]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_trigger_key_command",
                "description": "Fire a Logic key command that was learned onto the dedicated 'Logic MCP Commands' MIDI port. Pass name (e.g. 'Toggle Track Freeze', 'Undo') or note+channel. Standard commands missing from the registry are learned automatically first; unknown notes are refused because they could be bound to anything. CAUTION with Undo: the menu shows no operation name, so only fire it right after a known edit.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Registered command name, e.g. 'Toggle Track Freeze'."],
                        "note": ["type": "integer", "description": "MIDI note of a registered command."],
                        "channel": ["type": "integer", "description": "MIDI channel, default 16."]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_render_track",
                "description": "Render ONE track offline to an audio file with ZERO dialogs, via Track Freeze: selects the track, toggles freeze over the 'Logic MCP Commands' MIDI port, presses play (Logic then renders the whole track offline, typically seconds), copies the 32-bit float AIFF out of Media/Freeze Files to the captures folder, and unfreezes again. Requires 'Toggle Track Freeze' in the key command registry and the MCU bridge running. Renders the full track from project start including all plugins and automation (freeze mode Pre Fader). If the track is already frozen the call fails safely and restores state.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Track to render, matched against MCU LCD names or AX track headers."],
                        "track_number": ["type": "integer", "description": "Optional AX row number to disambiguate duplicates."],
                        "label": ["type": "string", "description": "Filename label; default is derived from the track name."],
                        "start_bar": ["type": "integer", "description": "With end_bar: also cut this bar range out of the render as a separate 32-bit float WAV with its own metrics (bar 1 = project start)."],
                        "end_bar": ["type": "integer", "description": "Exclusive: the slice ends where this bar begins."],
                        "tempo": ["type": "number", "description": "Override BPM for the bar math; default reads the control bar. Constant tempo assumed."],
                        "beats_per_bar": ["type": "number", "description": "Override meter; default reads the control bar's time signature."],
                        "expected_project_path": ["type": "string", "description": "Absolute .logicx path; when given, the open project's AXDocument must match before anything is changed."]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_mcu_command",
                "description": "Send a command to Logic through the Mackie Control bridge (UI-independent). cmd is one of: press {button: play|stop|record|rewind|forward|cycle|click|bank_left|bank_right|channel_left|channel_right|flip|name_value|assign_track|assign_send|assign_pan|assign_plugin|assign_eq|assign_instrument|...}, select/mute/solo {channel: 0-7}, fader {channel: 0-8, value: 0-16383}, vpot {index: 0-7, delta: +-n}, vpot_press {index}, raw {bytes: [..]}, ping. Read logic_mcu_status afterwards to verify via Logic's feedback.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "cmd": ["type": "string"],
                        "button": ["type": "string"],
                        "channel": ["type": "integer"],
                        "index": ["type": "integer"],
                        "value": ["type": "integer"],
                        "delta": ["type": "integer"],
                        "note": ["type": "integer"],
                        "bytes": ["type": "array", "items": ["type": "integer"]]
                    ],
                    "required": ["cmd"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_get_audio_clip",
                "description": "LISTEN to rendered audio: returns a short clip (default 8 s, max 20 s) of a local audio file as an MCP audio content block (mono AAC, roughly 64 KB per 8 s) that multimodal models can hear. Use this on the file paths returned by logic_render_track / logic_bounce_range / logic_evaluate_change. NEVER read raw audio files with a text/file tool - megabytes of binary will overflow the model context and can crash the client. Also writes the clip to disk (clip_path in the result): if the audio block does NOT reach you, your client drops MCP audio - open clip_path with your client's file viewer instead, which most clients pass to the model as real audio.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path to a local audio file (AIFF/WAV/etc)."],
                        "start_seconds": ["type": "number", "description": "Offset into the file, default 0."],
                        "duration_seconds": ["type": "number", "description": "Clip length, default 8, max 20."]
                    ],
                    "required": ["path"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_get_transport",
                "description": "Read the transport state from the control bar: playing, recording, cycle, playhead bar/beat, tempo, time signature, key signature, metronome, count-in. Read-only. Fields whose control bar element is missing are null.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
            ],
            [
                "name": "logic_set_cycle",
                "description": "Turn cycle (loop) mode on or off via the control bar Cycle button and verify the new state.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "enabled": ["type": "boolean"]
                    ],
                    "required": ["enabled"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_playing",
                "description": "Start or stop playback via the control bar Play button and verify the new state. Starting plays from the current playhead position (or the cycle range when cycle is on).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "playing": ["type": "boolean"]
                    ],
                    "required": ["playing"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_playhead",
                "description": "Move the playhead to a 1-based bar (and optional beat) by stepping the control bar position display, then verify. Requires the control bar display mode that exposes bar/beat (Beats & Project).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "bar": ["type": "integer"],
                        "beat": ["type": "integer"]
                    ],
                    "required": ["bar"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_cycle_range",
                "description": "Set the cycle (loop) locators to a whole-bar range, e.g. bars 5-9. Anchors the ruler's grid-snapped cycle region to a bar line via the playhead thumb, moves the region start by writing its AXPosition, adjusts the length by dragging its right edge (hit-test guarded), verifies via the region's bar-denominated size description, and restores the playhead. The target range must be visible in the ruler. Optionally turns cycle on/off afterwards via 'enabled'.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "start_bar": ["type": "integer", "description": "1-based bar where the cycle starts."],
                        "end_bar": ["type": "integer", "description": "Bar where the cycle ends (exclusive right locator, as shown in Logic)."],
                        "enabled": ["type": "boolean", "description": "When given, turn cycle mode on or off after setting the range."]
                    ],
                    "required": ["start_bar", "end_bar"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_select_track",
                "description": "Select a track by name (and optional 1-based track number) so its channel strip is exposed in the inspector. Writes AXSelectedChildren on the Tracks header group, falls back to the header's Has Focus button, and verifies through both the header's selected state and the inspector strip. Fails with ambiguous when several visible tracks share the name, and restores the previous selection if verification fails. Only tracks whose headers are currently rendered can be selected.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Exact track name as shown in the track header."],
                        "track_number": ["type": "integer", "description": "1-based track number; required when several visible tracks share the name."],
                        "expected_project_path": ["type": "string", "description": "Absolute .logicx path; when given, the open project's AXDocument must match before anything is changed."]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_track_stack",
                "description": "Expand or collapse a track stack by pressing its disclosure triangle, verifying the new state, and reporting which subtracks were revealed or hidden. Fails with not_exposed if the track is not a stack. Subtracks of a collapsed stack are otherwise invisible to logic_list_tracks and logic_select_track.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string", "description": "Exact name of the stack's main track."],
                        "track_number": ["type": "integer", "description": "1-based track number; required when several visible tracks share the name."],
                        "expanded": ["type": "boolean", "description": "true to show the stack's subtracks, false to hide them."],
                        "expected_project_path": ["type": "string", "description": "Absolute .logicx path; when given, the open project's AXDocument must match before anything is changed."]
                    ],
                    "required": ["track_name", "expanded"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_survey_plugins",
                "description": "Inventory every insert on a track: open each plugin window, list its accessible parameters (name, raw range, writability), classify the exposure, and close windows that were opened. Takes a few seconds per insert. Use to map which plugins are controllable through this MCP.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"]
                    ],
                    "required": ["track_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_add_plugin",
                "description": "Add a plugin to a track's first empty insert slot — mouse-free via the Mackie Control plugin browser (vpot-stepped, LCD-verified, vpot-press instantiates). Works for every plugin in Logic's browser including third-party. If the MCU bridge is down, the AX chooser fallback requires allow_mouse: true because it briefly takes over the pointer.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "plugin_name": ["type": "string", "description": "Menu title of the plugin, e.g. 'Gain', 'Channel EQ', 'Decapitator'."],
                        "format": ["type": "string", "description": "Channel format submenu item when offered, default 'Stereo'."]
                    ],
                    "required": ["track_name", "plugin_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_remove_plugin",
                "description": "Remove a plugin from a track — mouse-free via the Mackie Control plugin browser's No Plug-in entry (can take up to ~60 s of vpot stepping; verified via LCD and an AX cross-check on the named track). If the MCU bridge is down, the AX chooser fallback requires allow_mouse: true because it briefly takes over the pointer.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "plugin_name": ["type": "string"],
                        "insert_index": ["type": "integer"]
                    ],
                    "required": ["track_name", "plugin_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_track_mute",
                "description": "Mute or unmute a track via its inspector channel strip mute button, verified by readback. Selects the track first.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "enabled": ["type": "boolean"]
                    ],
                    "required": ["track_name", "enabled"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_track_solo",
                "description": "Solo or unsolo a track via its inspector channel strip solo button, verified by readback. Selects the track first.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "enabled": ["type": "boolean"]
                    ],
                    "required": ["track_name", "enabled"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_track_volume",
                "description": "Set a track's volume fader to a target dB value (e.g. -14.2, 0.0) by converging the inspector strip fader against its dB readout. Reports before/after dB. Fader steps are about 0.1-0.3 dB apart; default tolerance 0.15 dB.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "db": ["type": "number"],
                        "tolerance_db": ["type": "number"]
                    ],
                    "required": ["track_name", "db"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_track_pan",
                "description": "Set a track's pan/balance knob position (integer, typically -64..63 where 0 is center) via the inspector strip, verified by readback.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "track_number": ["type": "integer"],
                        "position": ["type": "integer"]
                    ],
                    "required": ["track_name", "position"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_open_plugin",
                "description": "Open the plugin window for one insert on the named (selected) track by pressing the insert's open button, then verify that the window appeared. If the window was already open it is identified via its toggle behaviour and restored. Fails closed on not_found, ambiguous (two inserts with the same plugin), not_exposed and verification_failed.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "plugin_name": ["type": "string", "description": "Plugin display name; truncated slot names such as 'Space D' match by prefix."],
                        "insert_index": ["type": "integer", "description": "1-based insert slot index; required when the same plugin occupies several slots."],
                        "expected_project_path": ["type": "string", "description": "Absolute .logicx path; when given, the open project's AXDocument must match before anything is pressed."]
                    ],
                    "required": ["track_name", "plugin_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_close_plugin",
                "description": "Close the plugin window of one insert on the named (selected) track by toggling the insert's open button, verifying that a window disappeared. Precise even when several plugin windows share the same title. If the plugin was not open, the accidentally opened window is closed again and precondition_failed is returned.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "track_name": ["type": "string"],
                        "plugin_name": ["type": "string"],
                        "insert_index": ["type": "integer", "description": "1-based insert slot index; required when the same plugin occupies several slots."]
                    ],
                    "required": ["track_name", "plugin_name"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_close_plugin_window",
                "description": "Close one plugin window by pressing its close button and verifying it disappeared. Refuses to close project windows (any window with a document) and fails with ambiguous when several windows share the title.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "window_title": ["type": "string"]
                    ],
                    "required": ["window_title"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_list_plugin_parameters",
                "description": "List semantically exposed, writable parameters in an open Logic plugin window.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "window_title": ["type": "string", "description": "Exact Logic plugin window title, usually the track name."]
                    ],
                    "required": ["window_title"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "logic_set_plugin_parameter",
                "description": "Set one accessible plugin parameter through its formatted text field, then read it back. Restores the prior value on verification failure.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "window_title": ["type": "string"],
                        "parameter": ["type": "string"],
                        "expected_current_value": ["type": "string"],
                        "target_value": ["type": "string"]
                    ],
                    "required": ["window_title", "parameter", "expected_current_value", "target_value"],
                    "additionalProperties": false
                ]
            ]
        ]
    }

    func response(id: Any, result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    func jsonRPCError(id: Any, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message]
        ]
    }

    func write(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else {
            log("failed to serialize response")
            return
        }
        line.append("\n")
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    func log(_ message: String) {
        let line = "[\(serverName)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
