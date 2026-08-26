# Logician Agent Guide

**This document is written for the AI agent using Logician.** Read the Core concepts and Workflows sections before your first tool call; consult the Tool reference as needed. Everything here was empirically verified against Logic Pro 12.

Logician controls Logic Pro through its **data plane**: the Mackie Control surface protocol over virtual MIDI (with Logic's own LCD/LED/fader echoes as verification), MIDI-note-bound key commands, timed MIDI streams for recording, and element-addressed macOS Accessibility for reading structure. It never uses synthetic keystrokes and takes the pointer only if you explicitly pass `allow_mouse: true` to the two tools that support it.

## First call, always

Run `logic_health` first. It starts the bridge daemon, checks every setup requirement, and returns a concrete fix string for anything missing. Requirements: Logic Pro running with a project open, Accessibility granted, a Mackie Control device in Logic bound to the "Logic MCP MCU" ports (one-time manual setup), and learned key commands (learned automatically on first use — the Key Commands window flashes briefly; run `logic_setup_key_commands` once to do all learning up front instead).

## Core concepts

**1. Compare-and-set discipline.** Write tools accept `expected_current_value` (or `expected_current_bpm` etc.). Pass it whenever you know the current value: the tool reads the control, REFUSES with `precondition_failed` if reality disagrees, converges, reads Logic's echo back, and reports `before`/`after`. Read before you write.

**2. Everything is verified — trust the report.** `verified: true` means Logic's own feedback (LCD echo, motorized fader, arrangement map, document flags) confirmed the result. `verified: false` or `success: false` with an `error` string means exactly what it says; nothing is silently retried into a lie.

**3. Track names: use what `logic_list_tracks` shows.** Tools take the full Accessibility names ("Lofi Pad"), not the MCU's 7-char truncations ("LofPad"). Duplicate names: pass `track_number` too.

**4. Bars and beats are 1-based; end bars are exclusive.** `start_bar: 5, end_bar: 9` = bars 5–8 (the range ends where bar 9 begins). Beats accept fractions (`beat: 2.5` = the off-beat after 2). Bar 1 = project start. Constant project tempo is assumed for all bar math; read it with `logic_get_transport`.

**5. Single-project mode.** Opening/creating a project closes the current one. If the current project has unsaved changes you MUST pass `if_current_modified: "save"` or `"dont_save"` — an explicit decision, otherwise the call refuses. Nothing ever saves except `logic_save_project` (and lifecycle calls where you explicitly chose saving).

**6. MCU physical insert slots ≠ Accessibility ordinals.** Plugin parameter tools take `insert_slot` (1–8, the Mackie physical slot). List them with `logic_mcu_plugin_inserts` first; empty slots show `--`.

**7. Destructive operations have guards but Undo is your friend.** `logic_delete_region` refuses unless exactly ONE region is selected project-wide at the moment Delete fires; `logic_delete_track` re-verifies the selection immediately before firing. Both are restorable with `logic_trigger_key_command {name: "Undo"}` — but ONLY fire Undo right after a known edit (the menu shows no operation name; a blind Undo can revert something else).

**8. Values follow the control's own units.** Volume/sends in dB; pan −64..+63 (0 center); plugin parameters in whatever the LCD shows (read them first). New sends start at −∞ dB — set a level after creating one. Numeric convergence lands within the control's step size (typically ±0.1 dB, ratios ±0.1).

**9. Real time is real.** MIDI recording and automation recording play through the actual timeline (bars × beats × 60/BPM seconds, roughly doubled with verification). `logic_record_midi` accepts `speed: 2..8` to record at raised tempo (auto-restored) when you don't need to hear the take. Renders/bounces are offline and fast (~4–6 s regardless of length).

**10. Warm paths are faster.** Consecutive `logic_mcu_set_plugin_parameter` calls on the same track+slot skip setup (~1.6 s vs ~4 s cold). Batch your parameter work per plugin.

## Workflows (recipes)

**Understand a project:**
`logic_health` → `logic_list_tracks` → `logic_list_regions` (the arrangement map: every region's name, bars, type) → `logic_get_transport` (tempo/meter) → per interesting track: `logic_mcu_plugin_inserts` + `logic_mcu_sends`.

**Compose a part:**
`logic_create_track {type: "software_instrument"}` → `logic_record_midi {track_name, notes: [{pitch: "C3", bar: 5, beat: 1, duration_beats: 1, velocity: 100}, ...], cc_events: [...], pitch_bends: [...]}`. Verification renders the recorded bars and returns metrics + a listenable WAV path. Notes: pitch as MIDI number or name (Logic convention: C3 = 60). start_bar must be ≥ 2 (one pre-roll bar).

**Shape a sound:**
`logic_add_plugin {track_name, plugin_name}` (mouse-free via the control-surface browser; exact catalog names like "Compressor", "Channel EQ") → `logic_mcu_plugin_parameters {insert_slot}` to read (page-capped; pass `max_pages` for giants) → `logic_mcu_set_plugin_parameter` per change → or step factory presets with `logic_plugin_preset`.

**Mix moves:**
`logic_set_track_volume {db}` / `logic_set_track_pan {position}` / mute/solo `{enabled}` / `logic_add_send {destination: "Bus 1"}` + `logic_mcu_set_send {send, level_db}`.

**Automate:**
`logic_record_automation {track_name, parameter: "volume"|"pan"|"send"|"plugin", points: [{bar, beat?, value}], ramp: true}` — for sends add `send: N`, for plugins add `insert_slot` + `plugin_parameter`. Values: dB for volume/send, −64..63 for pan, the parameter's own units for plugins. Verification replays or playhead-chases each point and reports expected vs observed. First point needs bar ≥ 2.

**Edit the arrangement:**
`logic_list_regions` → `logic_select_region {track_name, start_bar}` → `logic_move_region {by_bars, by_beats}` / `logic_copy_region {to_bar, to_track?, move?}` / `logic_delete_region`. Split at a position: `logic_set_playhead {bar}` + select + `logic_trigger_key_command {name: "Split Regions/Events at Playhead Position"}`.

**Experiment safely on a copy:**
`logic_duplicate_project {save_first: true}` — copies the open project on disk and opens the COPY as the active project; the original is untouched. Do this FIRST whenever you intend to make changes the user has not individually approved. Tell the user which file you are working in.

**Judge a change with evidence (the killer feature):**
`logic_evaluate_change {track_name, insert_slot, parameter, expected_current_value, target_value, start_bar, end_bar, method: "render"}` — renders A, applies the change, renders B, ROLLS BACK (unless `keep_change: true`), and returns dB deltas plus listenable audio for both. ~15 s. `method: "bounce"` A/Bs against the master bus instead. `method: "solo_bounce"` solos the track around two offline bounces (solo restored after) — use it when `render` fails with "refuses to arm Freeze": subtracks inside stacks and tracks sharing a channel strip cannot be frozen, but they CAN be solo-bounced (slower, ~2-3 min). A near-zero delta is a real answer (e.g. a compressor's AutoGain compensating) — report it as such.

**Deliver audio:**
`logic_render_track {track_name, start_bar?, end_bar?}` — dialog-free track export (32-bit float AIFF + optional bar-sliced WAV with RMS/peak metrics), ~6 s. `logic_bounce_range` for the master.

## Listening to audio (IMPORTANT)

**NEVER read an audio file with a text/file tool.** Render and bounce results return file paths to multi-megabyte binary files; reading one into your context will overflow it and can crash your client outright. Instead:

- Judge objectively with the returned `metrics` (RMS/peak per channel) and `deltas` from `logic_evaluate_change`.
- **To actually HEAR audio, the reliable route is your client's FILE VIEWER on the `preview_path`** — the compressed stereo `.m4a` sibling every render/bounce result includes. Many client harnesses (verified: Antigravity CLI) pass a viewed audio file to the model as real multimodal audio even though they DROP MCP audio content blocks. Use the viewer/read-file capability, never bash/cat.
- `logic_get_audio_clip {path, start_seconds?, duration_seconds?}` returns a short mono AAC clip as a native MCP audio content block — use it when your client forwards audio blocks (test once: if the tool result reaches you as text only, your client drops them; switch to the file-viewer route). Pick the interesting window (e.g. where the regions are) rather than second 0, which may be silence.
- **Sanity-check what you hear against the numbers**: bounce results now include `metrics` and a `warning` when the file is SILENT or when tracks are left SOLOED. A leftover solo silently empties every master bounce — if the warning names soloed tracks, unsolo before trusting any bounce.

## Error taxonomy

- `not_found` / `not_exposed` — the target does not exist or is not reachable; the message lists what IS visible. Check names/slots.
- `precondition_failed` — your `expected_current_value` did not match reality; nothing was written. Re-read and decide.
- `ambiguous` — multiple candidates matched; the message lists them. Disambiguate (track_number, start_bar).
- `verification_failed` — the write happened but Logic's feedback did not confirm; the message says what was observed and whether state was restored. Treat the operation as suspect, re-read before continuing.
- `invalid_arguments` — schema-level problem; fix the call.

## Cautions

- Track stacks cannot be freeze-rendered or MIDI-recorded onto; tools refuse cleanly — use subtracks.
- A rendered file that is honestly EMPTY (a track with no regions, or MIDI with no instrument) comes back with a `warning`, not fake success.
- Modal dialogs freeze most operations; tools detect and answer their own dialogs, and `logic_health` flags Logic's state. If something looks stuck, check for a dialog in Logic.
- The `logic_set_plugin_parameter` / `logic_list_plugin_parameters` (Accessibility window) variants exist for stock-plugin windows; PREFER the `logic_mcu_*` variants, which work for every plugin including custom-UI third-party ones.
- The sensor tools require the optional LogicMCPSensor Audio Unit; every render/bounce tool works without it.

## Tool reference

### Setup & diagnostics

#### `logic_health`

Read Logic Pro process and Accessibility readiness without changing Logic.

Parameters:

  - (no parameters)

#### `logic_setup_key_commands`

One-time onboarding: learn MIDI-note assignments for all standard key commands (Toggle Track Freeze, Undo, Redo, Flashback Capture as Recording, Split at Playhead, Create Marker) into the user's Logic via the Key Commands window automation. Additive to the user's key command set and removable there; collisions with existing assignments get alternate notes automatically. Idempotent — already-learned commands are verified and skipped. Runs automatically the first time a tool needs a missing command, so calling this explicitly is optional. Pass `relearn: true` to force re-learning even for commands that look bound — this is the repair when key commands silently stop firing (Logic scopes the bindings to the MIDI port identity, so recreated ports orphan them); it first deletes the command's existing controller assignments, so repeated repairs never stack duplicates.

Parameters:

  - `relearn` (boolean): Force re-learning of every standard command even when an assignment is already shown. Repairs bindings orphaned by MIDI-port changes. Default false.
  - `commands` (array of string): Limit to these standard command names (default: all).

#### `logic_mcu_status`

Read the Mackie Control bridge's mirrored state: LCD text (track names/values as data), fader positions, transport LEDs, timecode display, online status. This is Logic's documented control-surface feedback channel — no UI, no focus, no windows involved. Requires logic-mcu-bridge running and a Mackie Control configured in Logic pointing at the 'Logic MCP MCU' ports.

Parameters:

  - (no parameters)

#### `logic_mcu_command`

Send a command to Logic through the Mackie Control bridge (UI-independent). cmd is one of: press {button: play|stop|record|rewind|forward|cycle|click|bank_left|bank_right|channel_left|channel_right|flip|name_value|assign_track|assign_send|assign_pan|assign_plugin|assign_eq|assign_instrument|...}, select/mute/solo {channel: 0-7}, fader {channel: 0-8, value: 0-16383}, vpot {index: 0-7, delta: +-n}, vpot_press {index}, raw {bytes: [..]}, ping. Read logic_mcu_status afterwards to verify via Logic's feedback.

Parameters:

  - `button` (string)
  - `bytes` (array)
  - `channel` (integer)
  - `cmd` (string) **(required)**
  - `delta` (integer)
  - `index` (integer)
  - `note` (integer)
  - `value` (integer)

#### `logic_trigger_key_command`

Fire a Logic key command that was learned onto the dedicated 'Logic MCP Commands' MIDI port. Pass name (e.g. 'Toggle Track Freeze', 'Undo') or note+channel. Standard commands missing from the registry are learned automatically first; unknown notes are refused because they could be bound to anything. CAUTION with Undo: the menu shows no operation name, so only fire it right after a known edit.

Parameters:

  - `channel` (integer): MIDI channel, default 16.
  - `name` (string): Registered command name, e.g. 'Toggle Track Freeze'.
  - `note` (integer): MIDI note of a registered command.


### Project lifecycle

#### `logic_new_project`

Create a NEW Logic project at the given .logicx path — dialog-free, from a bundled empty project template — and open it. Logic runs single-project: if the current project has unsaved changes the call fails unless if_current_modified explicitly chooses 'save' or 'dont_save'. The created project is already saved on disk.

Parameters:

  - `if_current_modified` (string): 'fail' (default), 'save' or 'dont_save' — what to do with the currently open project's unsaved changes.
  - `path` (string) **(required)**: Absolute destination path ending in .logicx; must not already exist.

#### `logic_open_project`

Open an existing .logicx project. Single-project semantics as logic_new_project: unsaved changes in the current project require an explicit if_current_modified decision.

Parameters:

  - `if_current_modified` (string): 'fail' (default), 'save' or 'dont_save'.
  - `path` (string) **(required)**: Absolute path to an existing .logicx.

#### `logic_save_project`

Save the open Logic project — the ONLY way this server ever saves; no other tool saves as a side effect. Fires the Save key command and verifies via the document's modified flag. Refuses when more than one project is open, when the project has never been saved, or when expected_project_path does not match. Returns already_saved when there is nothing to save.

Parameters:

  - `expected_project_path` (string): Recommended: absolute .logicx path that must match the open project.

#### `logic_close_project`

Close the open project via AppleScript. 'saving' must be an explicit 'yes' or 'no' — there is no default, because discarding versus persisting changes is always the caller's decision.

Parameters:

  - `expected_project_path` (string)
  - `saving` (string) **(required)**: 'yes' saves before closing; 'no' discards unsaved changes.


### Reading the project

#### `logic_list_tracks`

List the track headers currently rendered in the Tracks area (track number, name, selected), read-only. Scrolled-out or hidden tracks are not exposed by Logic.

Parameters:

  - (no parameters)

#### `logic_list_regions`

The arrangement map: every region on every visible track row, with name, start/end bar (and beat when off the barline), type (midi/audio) and selection state — parsed from Logic's own accessibility descriptions. Read-only. Optionally filter to one track.

Parameters:

  - `track_name` (string): Optional: only this track's regions.

#### `logic_list_windows`

List Logic windows with subrole and project document path, read-only. Windows whose document is set are project windows; dialogs without a document are plugin or auxiliary windows.

Parameters:

  - (no parameters)

#### `logic_list_inserts`

List audio-effect insert slots (index, plugin display name, bypass state) of the named track's channel strip, read-only. The track must be selected so its strip is shown in the left inspector; otherwise the error not_exposed reports which track is currently shown.

Parameters:

  - `track_name` (string) **(required)**: Exact track name as shown in the track header.

#### `logic_mcu_plugin_inserts`

List a track's insert slots as the Mackie Control sees them (physical slot numbers 1-8 with plugin names), via the selected track's MCU plugin list. Works for ALL plugins including custom-UI third-party ones. Selects the track first.

Parameters:

  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_mcu_sends`

List a track's sends as data via the Mackie Control channel send view: slot number, destination bus, level in dB, position (pre/post fader) and status. UI-independent; competitors' MCPs do not expose sends at all.

Parameters:

  - `expected_project_path` (string)
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_get_transport`

Read the transport state from the control bar: playing, recording, cycle, playhead bar/beat, tempo, time signature, key signature, metronome, count-in. Read-only. Fields whose control bar element is missing are null.

Parameters:

  - (no parameters)

#### `logic_survey_plugins`

Inventory every insert on a track: open each plugin window, list its accessible parameters (name, raw range, writability), classify the exposure, and close windows that were opened. Takes a few seconds per insert. Use to map which plugins are controllable through this MCP.

Parameters:

  - `track_name` (string) **(required)**
  - `track_number` (integer)


### Tracks

#### `logic_create_track`

Create a new track (software_instrument or audio) via Logic's key command, answering the Create New Track dialog automatically. Verified by the track count increasing.

Parameters:

  - `type` (string): 'software_instrument' (default) or 'audio'.

#### `logic_rename_track`

Rename a track by writing the channel strip's name field (element-addressed AX). Verified against the track headers.

Parameters:

  - `new_name` (string) **(required)**
  - `track_name` (string) **(required)**

#### `logic_duplicate_track`

Duplicate a track via Logic's Duplicate Track key command (learned automatically). Verified by the track count increasing.

Parameters:

  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_delete_track`

DESTRUCTIVE: delete a track via the Delete Track key command. The selection is re-verified to be the named track immediately before firing, and the result is verified against the track list. Undo restores.

Parameters:

  - `track_name` (string) **(required)**
  - `track_number` (integer): Recommended for duplicate names.

#### `logic_select_track`

Select a track by name (and optional 1-based track number) so its channel strip is exposed in the inspector. Writes AXSelectedChildren on the Tracks header group, falls back to the header's Has Focus button, and verifies through both the header's selected state and the inspector strip. Fails with ambiguous when several visible tracks share the name, and restores the previous selection if verification fails. Only tracks whose headers are currently rendered can be selected.

Parameters:

  - `expected_project_path` (string): Absolute .logicx path; when given, the open project's AXDocument must match before anything is changed.
  - `track_name` (string) **(required)**: Exact track name as shown in the track header.
  - `track_number` (integer): 1-based track number; required when several visible tracks share the name.

#### `logic_set_track_stack`

Expand or collapse a track stack by pressing its disclosure triangle, verifying the new state, and reporting which subtracks were revealed or hidden. Fails with not_exposed if the track is not a stack. Subtracks of a collapsed stack are otherwise invisible to logic_list_tracks and logic_select_track.

Parameters:

  - `expanded` (boolean) **(required)**: true to show the stack's subtracks, false to hide them.
  - `expected_project_path` (string): Absolute .logicx path; when given, the open project's AXDocument must match before anything is changed.
  - `track_name` (string) **(required)**: Exact name of the stack's main track.
  - `track_number` (integer): 1-based track number; required when several visible tracks share the name.


### Transport

#### `logic_set_playing`

Start or stop playback via the control bar Play button and verify the new state. Starting plays from the current playhead position (or the cycle range when cycle is on).

Parameters:

  - `playing` (boolean) **(required)**

#### `logic_set_playhead`

Move the playhead to a 1-based bar (and optional beat) by stepping the control bar position display, then verify. Requires the control bar display mode that exposes bar/beat (Beats & Project).

Parameters:

  - `bar` (integer) **(required)**
  - `beat` (integer)

#### `logic_set_cycle`

Turn cycle (loop) mode on or off via the control bar Cycle button and verify the new state.

Parameters:

  - `enabled` (boolean) **(required)**

#### `logic_set_cycle_range`

Set the cycle (loop) locators to a whole-bar range, e.g. bars 5-9. Anchors the ruler's grid-snapped cycle region to a bar line via the playhead thumb, moves the region start by writing its AXPosition, adjusts the length by dragging its right edge (hit-test guarded), verifies via the region's bar-denominated size description, and restores the playhead. The target range must be visible in the ruler. Optionally turns cycle on/off afterwards via 'enabled'.

Parameters:

  - `enabled` (boolean): When given, turn cycle mode on or off after setting the range.
  - `end_bar` (integer) **(required)**: Bar where the cycle ends (exclusive right locator, as shown in Logic).
  - `start_bar` (integer) **(required)**: 1-based bar where the cycle starts.

#### `logic_set_tempo`

Set the project tempo in BPM via the control bar's tempo display (rapid-fire stepwise converge, ~1.3 s per 120 BPM of distance). Whole-BPM resolution. Compare-and-set with expected_current_bpm. Assumes constant project tempo.

Parameters:

  - `bpm` (number) **(required)**: Target tempo, 5-990.
  - `expected_current_bpm` (number): Abort unless the current tempo matches.


### Mixing

#### `logic_set_track_volume`

Set a track's volume fader to a target dB value (e.g. -14.2, 0.0) by converging the inspector strip fader against its dB readout. Reports before/after dB. Fader steps are about 0.1-0.3 dB apart; default tolerance 0.15 dB.

Parameters:

  - `db` (number) **(required)**
  - `tolerance_db` (number)
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_set_track_pan`

Set a track's pan/balance knob position (integer, typically -64..63 where 0 is center) via the inspector strip, verified by readback.

Parameters:

  - `position` (integer) **(required)**
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_set_track_mute`

Mute or unmute a track via its inspector channel strip mute button, verified by readback. Selects the track first.

Parameters:

  - `enabled` (boolean) **(required)**
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_set_track_solo`

Solo or unsolo a track via its inspector channel strip solo button, verified by readback. Selects the track first.

Parameters:

  - `enabled` (boolean) **(required)**
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_add_send`

Create a send on a track to a bus/output — mouse-free via the control surface's send-destination browser (first empty slot, browsed to the named destination, settle-verified, confirmed). New sends start at -oo dB; set the level with logic_mcu_set_send. Destination names as Logic shows them, e.g. 'Bus 1', 'Bus 2'.

Parameters:

  - `destination` (string) **(required)**: e.g. 'Bus 3'.
  - `track_name` (string) **(required)**

#### `logic_mcu_set_send`

Set one send's level in dB on a track, verified through the MCU LCD echo (compare-and-set with expected_current_value, readback, same discipline as plugin parameters). Only the level vpot is touched — never the destination. List sends first with logic_mcu_sends.

Parameters:

  - `expected_current_value` (string): Abort unless the current LCD value matches (e.g. '-9.0dB' or '-9.0').
  - `expected_project_path` (string)
  - `level_db` (number) **(required)**: Target level in dB, e.g. -9.0.
  - `send` (integer) **(required)**: Send slot 1-8.
  - `track_name` (string) **(required)**
  - `track_number` (integer)


### Plugins & instruments

#### `logic_add_plugin`

Add a plugin to a track's first empty insert slot — mouse-free via the Mackie Control plugin browser (vpot-stepped, LCD-verified, vpot-press instantiates). Works for every plugin in Logic's browser including third-party. If the MCU bridge is down, the AX chooser fallback requires allow_mouse: true because it briefly takes over the pointer.

Parameters:

  - `format` (string): Channel format submenu item when offered, default 'Stereo'.
  - `plugin_name` (string) **(required)**: Menu title of the plugin, e.g. 'Gain', 'Channel EQ', 'Decapitator'.
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_remove_plugin`

Remove a plugin from a track — mouse-free via the Mackie Control plugin browser's No Plug-in entry (can take up to ~60 s of vpot stepping; verified via LCD and an AX cross-check on the named track). If the MCU bridge is down, the AX chooser fallback requires allow_mouse: true because it briefly takes over the pointer.

Parameters:

  - `insert_index` (integer)
  - `plugin_name` (string) **(required)**
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_mcu_plugin_parameters`

Read ALL of a plugin's parameter names and formatted values (every MCU page) via host automation — works for plugins whose UI exposes nothing to Accessibility (Decapitator, Trilian, ...). insert_slot is the MCU physical slot from logic_mcu_plugin_inserts.

Parameters:

  - `insert_slot` (integer) **(required)**
  - `max_pages` (integer): Page cap, default 12 (each uncached page costs ~1.7 s; large instruments have 80+). pages_total and truncated report what was left out.
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_mcu_set_plugin_parameter`

Set one plugin parameter through host automation (MCU vpot) with the LCD value echo as verified readback — the data-plane route that reaches every plugin. Numeric targets converge adaptively; text targets (e.g. 'On', 'B') step until exact match. Optional expected_current_value enforces compare-and-set; failed verification rolls back. Parameter is matched against the MCU's abbreviated names (e.g. 'Thrs' matches 'Threshold').

Parameters:

  - `expected_current_value` (string)
  - `insert_slot` (integer) **(required)**
  - `parameter` (string) **(required)**
  - `target_value` (string) **(required)**
  - `tolerance` (number)
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_mcu_instrument_parameters`

Read the INSTRUMENT slot's parameter names and formatted values (all MCU pages) for a track via host automation — reaches software instruments whose UIs expose nothing to Accessibility (Q-Sampler, Trilian, ...).

Parameters:

  - `max_pages` (integer): Page cap, default 12 (each uncached page costs ~1.7 s; large instruments have 80+). pages_total and truncated report what was left out.
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_mcu_set_instrument_parameter`

Set one INSTRUMENT parameter through host automation (MCU vpot) with LCD echo readback, same converge/step semantics and compare-and-set contract as logic_mcu_set_plugin_parameter.

Parameters:

  - `expected_current_value` (string)
  - `parameter` (string) **(required)**
  - `target_value` (string) **(required)**
  - `tolerance` (number)
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_plugin_preset`

Step a plugin's factory/user preset (next/previous, N steps) via Logic's topmost-plugin-window key command: the plugin window is opened (and closed again if this call opened it), the command fired, and the change verified against the window's preset label. Preset before/after names are returned.

Parameters:

  - `direction` (string): 'next' (default) or 'previous'.
  - `insert_index` (integer)
  - `plugin_name` (string) **(required)**
  - `steps` (integer): How many presets to step, default 1.
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_open_plugin`

Open the plugin window for one insert on the named (selected) track by pressing the insert's open button, then verify that the window appeared. If the window was already open it is identified via its toggle behaviour and restored. Fails closed on not_found, ambiguous (two inserts with the same plugin), not_exposed and verification_failed.

Parameters:

  - `expected_project_path` (string): Absolute .logicx path; when given, the open project's AXDocument must match before anything is pressed.
  - `insert_index` (integer): 1-based insert slot index; required when the same plugin occupies several slots.
  - `plugin_name` (string) **(required)**: Plugin display name; truncated slot names such as 'Space D' match by prefix.
  - `track_name` (string) **(required)**

#### `logic_close_plugin`

Close the plugin window of one insert on the named (selected) track by toggling the insert's open button, verifying that a window disappeared. Precise even when several plugin windows share the same title. If the plugin was not open, the accidentally opened window is closed again and precondition_failed is returned.

Parameters:

  - `insert_index` (integer): 1-based insert slot index; required when the same plugin occupies several slots.
  - `plugin_name` (string) **(required)**
  - `track_name` (string) **(required)**

#### `logic_close_plugin_window`

Close one plugin window by pressing its close button and verifying it disappeared. Refuses to close project windows (any window with a document) and fails with ambiguous when several windows share the title.

Parameters:

  - `window_title` (string) **(required)**

#### `logic_list_plugin_parameters`

List semantically exposed, writable parameters in an open Logic plugin window.

Parameters:

  - `window_title` (string) **(required)**: Exact Logic plugin window title, usually the track name.

#### `logic_set_plugin_parameter`

Set one accessible plugin parameter through its formatted text field, then read it back. Restores the prior value on verification failure.

Parameters:

  - `expected_current_value` (string) **(required)**
  - `parameter` (string) **(required)**
  - `target_value` (string) **(required)**
  - `window_title` (string) **(required)**


### Regions & editing

#### `logic_select_region`

Select exactly one region (by track + region_name and/or start_bar; ambiguity is refused with candidates listed). exclusive (default true) clears all other region selections first, so a following edit key command (cut/copy/delete/nudge) touches only this region. Verified via the element's selection state.

Parameters:

  - `exclusive` (boolean): Default true: clear other selections first.
  - `region_name` (string)
  - `start_bar` (integer)
  - `track_name` (string) **(required)**

#### `logic_delete_region`

DESTRUCTIVE: delete one region (selected exclusively first; refuses unless exactly ONE region is selected project-wide right before Delete fires). Verified against the arrangement map; Undo restores.

Parameters:

  - `region_name` (string)
  - `start_bar` (integer)
  - `track_name` (string) **(required)**

#### `logic_move_region`

Move one region by whole bars and/or beats via Logic's nudge key commands (no dragging, no mouse). Whole-bar moves are verified exactly against the arrangement map.

Parameters:

  - `by_bars` (integer): Positive = right, negative = left.
  - `by_beats` (integer)
  - `region_name` (string)
  - `start_bar` (integer): Which region (its current start bar).
  - `track_name` (string) **(required)**

#### `logic_copy_region`

Copy (or move, with move: true = Cut) one region to a target bar, optionally onto another track: exclusive select, Copy/Cut, select destination track, park playhead, Paste. Verified by the region appearing at the target bar in the arrangement map.

Parameters:

  - `move` (boolean): true uses Cut instead of Copy (moves across tracks).
  - `region_name` (string)
  - `start_bar` (integer)
  - `to_bar` (integer) **(required)**
  - `to_track` (string): Destination track; default same track.
  - `track_name` (string) **(required)**


### Composition

#### `logic_record_midi`

Compose MIDI into the project with ZERO dialogs and no files: notes are streamed in real time over the dedicated 'Logic MCP MIDI In' port while Logic records them onto the selected software-instrument track (playhead parked one bar early; the stream starts on the observed MCU-timecode crossing into start_bar, so count-in settings do not matter). Creates a normal recorded region. By default the result is verified with a dialog-free freeze render of the recorded bars (non-silent metrics prove the notes landed and sound through the instrument). Recording takes real time: bars x beats x 60/BPM seconds. The region can be removed with Undo in Logic.

Parameters:

  - `beats_per_bar` (number): Override meter; default reads the control bar.
  - `cc_events` (array): MIDI CC events recorded alongside the notes — e.g. mod-wheel sweeps (cc 1), expression (cc 11). Emit many points for smooth curves.
    - `bar` (required)
    - `beat`: 1-based, fractions allowed.
    - `cc` (required): Controller number 0-127.
    - `channel`: 1-16, default 1.
    - `value` (required): 0-127.
  - `expected_project_path` (string)
  - `notes` (array) **(required)**: The notes to record.
    - `bar` (required): Absolute bar position (1 = project start).
    - `beat`: Beat within the bar, 1-based; fractions allowed (1.5 = offbeat). Default 1.
    - `channel`: MIDI channel 1-16, default 1.
    - `duration_beats`: Length in beats. Default 1.
    - `pitch` (required): MIDI number 0-127 or a name like 'C3' (= MIDI 60, Logic convention), 'F#1', 'Bb2'.
    - `velocity`: 1-127, default 100.
  - `pitch_bends` (array): Pitch-bend events: value -8192..8191 (0 = center). Emit many points for smooth bends, and return to 0 at the end.
    - `bar` (required)
    - `beat`
    - `channel`
    - `value` (required)
  - `speed` (number): Optional fast mode: record at speed x tempo (1-8, default 1) and scale event times — same bar positions in a fraction of the wall time. Default 1 keeps real-time recording so the take is audible as it happens; higher speeds trade timing precision (jitter scales with speed) and chipmunked monitoring.
  - `start_bar` (integer): Recording start bar (>= 2); default = the earliest event's bar.
  - `sync_compensation_ms` (number): Timecode display latency compensated in the beat-edge sync, default 45 ms (measured). Raise if notes land early, lower if late.
  - `tempo` (number): Override BPM; default reads the control bar.
  - `track_name` (string) **(required)**: Software instrument track to record onto (not a track stack).
  - `track_number` (integer)
  - `verify_render` (boolean): Default true: freeze-render the recorded bars afterwards and return slice metrics as proof.


### Automation

#### `logic_record_automation`

Write an automation curve on a track — volume (absolute fader), pan, a send level (send: 1-8) or ANY plugin parameter (insert_slot + plugin_parameter) — with no mouse and no automation-lane clicking. The value scale follows the parameter: dB for volume/sends, -64..63 for pan, the plugin's own units otherwise. Mechanism: calibrate the control near the working range, switch the track to Latch over the control surface, roll playback placing calibrated moves at each musical moment, return to Read, restore the original value, and verify by REPLAYING the range while sampling Logic's own echo at every point. ramp (default true) interpolates between points. Points need bar >= 2. Takes real time (the automated range, twice with verify)

Parameters:

  - `parameter` (string): v1: 'volume' only.
  - `points` (array) **(required)**
    - `bar` (required)
    - `beat`: 1-based, fractions allowed. Default 1.
    - `db` (required): Target volume in dB, e.g. -12.0.
  - `ramp` (boolean): Default true: smooth linear ramps between points.
  - `track_name` (string) **(required)**
  - `verify` (boolean): Default true: replay the range in Read and sample the fader echo per point.


### Audio out & evaluation

#### `logic_render_track`

Render ONE track offline to an audio file with ZERO dialogs, via Track Freeze: selects the track, toggles freeze over the 'Logic MCP Commands' MIDI port, presses play (Logic then renders the whole track offline, typically seconds), copies the 32-bit float AIFF out of Media/Freeze Files to the captures folder, and unfreezes again. Requires 'Toggle Track Freeze' in the key command registry and the MCU bridge running. Renders the full track from project start including all plugins and automation (freeze mode Pre Fader). If the track is already frozen the call fails safely and restores state.

Parameters:

  - `beats_per_bar` (number): Override meter; default reads the control bar's time signature.
  - `end_bar` (integer): Exclusive: the slice ends where this bar begins.
  - `expected_project_path` (string): Absolute .logicx path; when given, the open project's AXDocument must match before anything is changed.
  - `label` (string): Filename label; default is derived from the track name.
  - `start_bar` (integer): With end_bar: also cut this bar range out of the render as a separate 32-bit float WAV with its own metrics (bar 1 = project start).
  - `tempo` (number): Override BPM for the bar math; default reads the control bar. Constant tempo assumed.
  - `track_name` (string) **(required)**: Track to render, matched against MCU LCD names or AX track headers.
  - `track_number` (integer): Optional AX row number to disambiguate duplicates.

#### `logic_bounce_range`

Offline-bounce a bar range of the master output to an audio file, many times faster than realtime playback. Drives Logic's bounce dialog and its XPC save panel entirely through verified accessibility (no playback, no sensor needed). Temporarily switches the bounce destination to Uncompressed and restores the user's selection afterwards. Returns the file path.

Parameters:

  - `end_bar` (integer) **(required)**
  - `expected_project_path` (string)
  - `label` (string): Filename label, e.g. 'A' or 'baseline'.
  - `start_bar` (integer) **(required)**

#### `logic_evaluate_change`

Run one complete closed-loop mix evaluation around exactly one verified plugin-parameter change, on a bar range. Four methods: 'realtime' (default; loop playback + sensor windows, needs plugin_name + active sensor), 'bounce' (two offline MASTER renders via the bounce dialog, needs plugin_name), 'render' (two dialog-free freeze renders of the SINGLE track, compared on the sliced bar range — fastest and most isolated; needs insert_slot, the MCU physical slot, and works for all plugins including third-party), and 'solo_bounce' (two offline bounces with ONLY this track soloed, solo restored after; needs insert_slot like 'render' — use it for tracks freeze refuses: subtracks inside stacks and tracks sharing a channel strip). All methods roll the change back by default and return baseline/after audio paths, metrics and dB deltas.

Parameters:

  - `beats_per_bar` (number): Override meter for bar math; default reads the control bar's time signature.
  - `end_bar` (integer) **(required)**: Exclusive: the range ends where this bar begins.
  - `expected_current_value` (string) **(required)**
  - `expected_project_path` (string)
  - `insert_index` (integer)
  - `insert_slot` (integer): MCU physical insert slot 1-8; required for method 'render' (list with logic_mcu_plugin_inserts).
  - `keep_change` (boolean): true keeps the change after measuring; default false rolls it back.
  - `method` (string): 'realtime' (default), 'bounce' (offline master A/B) or 'render' (dialog-free single-track freeze A/B on the sliced bar range).
  - `parameter` (string) **(required)**
  - `plugin_name` (string): Plugin window title; required for methods 'realtime' and 'bounce'.
  - `settle_seconds` (number): Extra settle time after each phase, default 2.
  - `start_bar` (integer) **(required)**
  - `target_value` (string) **(required)**
  - `tempo` (number): Override BPM for bar math (method 'render'); default reads the control bar. Constant tempo assumed.
  - `track_name` (string) **(required)**
  - `verify_rollback` (boolean): Measure a third control window after rollback (default false; rollback accuracy has been verified at ~0.0 dB residual repeatedly).


### Sensor (optional add-on)

#### `logic_sensor_read`

OPTIONAL ADD-ON (requires the LogicMCPSensor AU; bounce/render tools do not). Read live audio feature frames (peak/RMS in dBFS, host beat, tempo, transport state) published by LogicMCPSensor Audio Unit instances inserted in Logic. Returns the latest frame plus aggregates over window_seconds per sensor instance, with a stale flag when a sensor has stopped publishing. Read-only; requires the sensor AU to be inserted on a track, bus or output in Logic.

Parameters:

  - `window_seconds` (number): Aggregation window, default 3 seconds.

#### `logic_sensor_capture`

OPTIONAL ADD-ON (requires the LogicMCPSensor AU; bounce/render tools do not). Bounce the most recent audio heard at each active LogicMCPSensor insert point to a 16-bit WAV file (up to 45 seconds back), so a human or an audio-capable model can LISTEN to the mix rather than only read meter values. Returns file paths. Read-only with respect to Logic.

Parameters:

  - `label` (string): Filename label, e.g. 'baseline'.
  - `seconds` (number): How far back to capture, default 8, max 45.
