# Logician Agent Guide

**This document is written for the AI agent using Logician.** Read the Core concepts and Workflows sections before your first tool call; consult the Tool reference as needed. Everything here was empirically verified against Logic Pro 12.

Logician controls Logic Pro through its **data plane**: the Mackie Control surface protocol over virtual MIDI (with Logic's own LCD/LED/fader echoes as verification), MIDI-note-bound key commands, timed MIDI streams for recording, and element-addressed macOS Accessibility for reading structure. It never uses synthetic keystrokes and takes the pointer only if you explicitly pass `allow_mouse: true` to the two tools that support it.

## First call, always

Run `logic_health` first. It starts the bridge daemon, checks every setup requirement, and returns a concrete fix string for anything missing. Requirements: Logic Pro running with a project open, Accessibility granted, a Mackie Control device in Logic bound to the "Logic MCP MCU" ports (one-time manual setup), and learned key commands (learned automatically on first use — the Key Commands window flashes briefly; run `logic_setup_key_commands` once to do all learning up front instead).

## Core concepts

**1. Compare-and-set discipline.** Write tools accept `expected_current_value` (or `expected_current_bpm` etc.). Pass it whenever you know the current value: the tool reads the control, REFUSES with `precondition_failed` if reality disagrees, converges, reads Logic's echo back, and reports `before`/`after`. Read before you write.

**2. Everything is verified — trust the report.** `verified: true` means Logic's own feedback (LCD echo, motorized fader, arrangement map, document flags) confirmed the result. `verified: false` or `success: false` with an `error` string means exactly what it says; nothing is silently retried into a lie.

**3. Track names: use what `logic_list_tracks` shows.** Tools take the full Accessibility names ("Lofi Pad"), not the MCU's 7-char truncations ("LofPad"). Duplicate names: pass `track_number` too.

**3b. The master chain and the buses are strips too — address them by name.** `Stereo Out`, `Master`, `Aux 1`, bus channels: `logic_list_tracks` does NOT list them (they have no track header in the Tracks area), but the mixing, send and plugin tools take their names anyway. Pass the name Logic shows in the Mixer (`"Stereo Out"`), never the 6-character LCD abbreviation (`St Out`). What differs from a track:

  - **Which plane resolves them.** A track is selected through Accessibility; a headerless strip is resolved and selected on the control surface, so those calls need the MCU bridge. Results say which was used in `selection_route` (`ax_track_header` / `mcu_channel`).
  - **`track_number` is for tracks only.** Passing one pins the call to the track-header plane, so a number plus an output name is an error, not a reroute.
  - **The Accessibility-only tools need the strip on screen.** `logic_list_inserts` and `logic_survey_plugins` read an *inspector* strip, and an inspector only shows the selected track's own strip and its output. `Stereo Out` is usually reachable that way; `Master` and the auxes usually are not. The `logic_mcu_*` tools have no such limit.
  - **Insert numbering can differ between the planes, and on an output it was observed REVERSED**: on `Stereo Out`, Accessibility listed `Sensor, Limiter, Channel EQ` while MCU slots 1-3 read `Channel EQ, Limiter, Sensor`. Never translate an AX `insert_index` into an MCU `insert_slot`; list with the tool you are about to use (`logic_mcu_plugin_inserts` for the MCU tools).
  - **Ambiguity refuses.** Two strips whose names abbreviate to the same six LCD characters produce `ambiguous` with the cells listed, and nothing is written.

**4. Bars and beats are 1-based; end bars are exclusive.** `start_bar: 5, end_bar: 9` = bars 5–8 (the range ends where bar 9 begins). Beats accept fractions (`beat: 2.5` = the off-beat after 2). Bar 1 = project start. Tempo **changes are followed** (the tempo map is read and integrated, see 4b); the project **meter** is still assumed constant for all bar math — signature changes are not read. Read tempo and meter with `logic_get_transport`.

**4b. Tempo maps are read and integrated; the fallback still warns.** Two families of tools take bars:

  - **Logic interprets the bars** — `logic_bounce_range`, `logic_evaluate_change` methods `bounce`/`solo_bounce`, `logic_set_cycle_range`, the region tools. Correct under any tempo map, always. Nothing to read, nothing to warn about.
  - **Logician converts bars to seconds itself** — `logic_render_track`'s bar-range slice, `logic_evaluate_change` method `render`, `logic_record_midi`'s note placement and verification slice, `logic_record_automation`'s point placement. These now read the project's **tempo map** out of Logic's Tempo List (`View > List Editors > Tempo`: one row per tempo event, position + BPM) and **integrate it piecewise** — exact for step tempo changes, and reported back in a `tempo_map` block. The read costs ~2 s, moves **no** playhead, and is cached per project (invalidated by `logic_set_tempo`, by any recording whose Smart Tempo mode was not verifiably Keep, and whenever the control bar reports a tempo the cached map cannot account for — so editing a tempo in Logic between calls does not leave a stale map behind).

Two honest limits remain on the read. **Tempo curves** (two points joined by a continuous ramp) are not distinguishable in the Tempo List — it publishes only Position, Tempo and SMPTE Position — so a curve is integrated as a step; when a range could be affected the `warning` says by how many ms. And the **meter** is still one number.

When the Tempo List cannot be read at all, the pre-map behavior is the fallback: the tool parks the playhead at the range's first bar, reads the control-bar tempo, parks at the last bar, reads again, and restores (~0.13 s per bar of travel). Differing readings then give a `warning` naming both, or a `precondition_failed` refusal where a warning would not be enough (`method: "render"`, and `speed > 1` on `logic_record_midi`). Two agreeing readings are evidence, not proof: a map that returns to its old value between the sample points reads as constant.

**5. Single-project mode.** Opening/creating a project closes the current one. If the current project has unsaved changes you MUST pass `if_current_modified: "save"` or `"dont_save"` — an explicit decision, otherwise the call refuses. Nothing ever saves except `logic_save_project` (and lifecycle calls where you explicitly chose saving).

**6. MCU physical insert slots ≠ Accessibility ordinals.** Plugin parameter tools take `insert_slot` (1–8, the Mackie physical slot). List them with `logic_mcu_plugin_inserts` first; empty slots show `--`.

**7. Destructive operations have guards but Undo is your friend.** `logic_delete_region` refuses unless exactly ONE region is selected project-wide at the moment Delete fires; `logic_delete_track` re-verifies the selection immediately before firing. Both are restorable with `logic_trigger_key_command {name: "Undo"}` — but ONLY fire Undo right after a known edit (the menu shows no operation name; a blind Undo can revert something else).

**8. Values follow the control's own units.** Volume/sends in dB; pan −64..+63 (0 center); plugin parameters in whatever the LCD shows (read them first). New sends start at −∞ dB — set a level after creating one. Numeric convergence lands within the control's step size (typically ±0.1 dB, ratios ±0.1).

**9. Real time is real.** MIDI recording and automation recording play through the actual timeline (bars × beats × 60/BPM seconds, roughly doubled with verification). `logic_record_midi` accepts `speed: 2..8` to record at raised tempo (auto-restored) when you don't need to hear the take — still refused on a non-constant tempo, because restoring one BPM cannot restore a map (that refusal does not soften with a readable map; the map tells us the take's timing, not how to put a slider write back). Renders/bounces are offline and fast, and near-constant in length: a master bounce ~6–7 s, a single-track freeze render ~9–13 s (measured on a 19-track project).

**10. Warm paths are faster.** Consecutive `logic_mcu_set_plugin_parameter` calls on the same track+slot skip setup (~1.6 s vs ~4 s cold). Batch your parameter work per plugin.

## Workflows (recipes)

**Understand a project:**
`logic_health` → `logic_list_tracks` → `logic_list_regions` (the arrangement map: every region's name, bars, type) → `logic_get_transport` (tempo/meter) → per interesting track: `logic_mcu_plugin_inserts` + `logic_mcu_sends`.

**Compose a part:**
`logic_create_track {type: "software_instrument"}` → `logic_record_midi {track_name, notes: [{pitch: "C3", bar: 5, beat: 1, duration_beats: 1, velocity: 100}, ...], cc_events: [...], pitch_bends: [...]}`. Verification renders the recorded bars and returns metrics + a listenable WAV path. Notes: pitch as MIDI number or name (Logic convention: C3 = 60). start_bar must be ≥ 2 (one pre-roll bar).

**Shape a sound:**
`logic_add_plugin {track_name, plugin_name}` (mouse-free via the control-surface browser; exact catalog names like "Compressor", "Channel EQ") → `logic_mcu_plugin_parameters {insert_slot}` to read (page-capped; pass `max_pages` for giants) → `logic_mcu_set_plugin_parameter` per change → or browse factory settings with `logic_plugin_preset` (`action: "list"` to see the names, `action: "select"` with `name` to load one).

**Mix moves:**
`logic_set_track_volume {db}` / `logic_set_track_pan {position}` / mute/solo `{enabled}` / `logic_add_send {destination: "Bus 1"}` + `logic_mcu_set_send {send, level_db}`.

**Work on the master chain (or a bus):**
Use the strip name directly — `logic_mcu_plugin_inserts {track_name: "Stereo Out"}` to see the MCU slots → `logic_mcu_plugin_parameters {track_name: "Stereo Out", insert_slot}` → `logic_mcu_set_plugin_parameter {...}`. `logic_list_tracks` will not mention `Stereo Out`; that is expected (see concept 3b). A/B a master change with `logic_evaluate_change` method `bounce`, which captures the whole mix and needs no solo.

**Automate:**
`logic_record_automation {track_name, parameter: "volume"|"pan"|"send"|"plugin", points: [{bar, beat?, value}], ramp: true}` — for sends add `send: N`, for plugins add `insert_slot` + `plugin_parameter`. Values: dB for volume/send, −64..63 for pan, the parameter's own units for plugins. Verification replays or playhead-chases each point and reports expected vs observed. First point needs bar ≥ 2.

**Edit the arrangement:**
`logic_list_regions` → `logic_select_region {track_name, start_bar}` → `logic_move_region {by_bars, by_beats}` / `logic_copy_region {to_bar, to_track?, move?}` / `logic_delete_region` / `logic_split_region {at_bar}`. Split is one call, not the old three-step recipe — it parks the playhead EXACTLY (see caution below), checks that the point is inside the region, fires the command and proves the result against the arrangement map.

**Edit many regions at once:**
`logic_select_regions {mode, track_name, start_bar}` extends a selection the way Logic does — `track` (the whole track), `following` (everything after the anchor, all tracks), `following_same_track`, `all`, `none` — and reports how many regions ended up selected. Then fire ONE edit across all of them (`logic_trigger_key_command {name: "Delete"}`, a nudge, `Cut`). This is the difference between one call and a thousand round trips on a podcast edit. The count only sees VISIBLE track rows; the selection itself is project-wide, so an edit can reach more than the number you were shown.

**Strip the silence out of a speech take:**
`logic_remove_silence {track_name, start_bar}` first — with `apply: false` (the default) it opens Logic's Remove Silence window, reads its LIVE preview ("this would leave 9 regions") and closes it again, changing nothing. If the number looks right, call again with `apply: true`.

**Resample — print audio back INTO the project:**
`logic_bounce_in_place {track_name, region_name, start_bar, bypass_effect_plugins: false}`. This is NOT `logic_render_track`, which writes a file to disk: this creates a new audio REGION you can chop, move and bounce again. Watch the `warning` — Logic's own "Bypass Effect Plug-ins" setting may be on, and a dry print is rarely what "print that" means.

**Experiment safely on a copy:**
`logic_duplicate_project {save_first: true}` — copies the open project on disk and opens the COPY as the active project; the original is untouched. Do this FIRST whenever you intend to make changes the user has not individually approved. Tell the user which file you are working in.

**Judge a change with evidence (the killer feature):**
`logic_evaluate_change {track_name, insert_slot, parameter, expected_current_value, target_value, start_bar, end_bar, method: "render"}` — renders A, applies the change, renders B, ROLLS BACK (unless `keep_change: true`), and returns dB deltas plus listenable audio for both. ~35–50 s (it is two freeze renders). `method: "bounce"` A/Bs against the master bus instead. `method: "solo_bounce"` solos the track around two offline bounces (solo restored after) — use it when `render` fails with "refuses to arm Freeze": subtracks inside stacks and tracks sharing a channel strip cannot be frozen, but they CAN be solo-bounced (~30 s — two offline bounces). A near-zero delta is a real answer (e.g. a compressor's AutoGain compensating) — report it as such.

All three methods return the **same keys**, so you can read a result without knowing which method produced it: `decision` (`kept` / `rolled_back` / `rollback_failed`), `change` (track, parameter, `before`, `applied`), `range`, `deltas`, `baseline_metrics` / `after_metrics`, and four audio paths — `baseline_audio` / `after_audio` plus `baseline_full_audio` / `after_full_audio` and `baseline_preview` / `after_preview`. A key a method genuinely has nothing for is present and **null** (a freeze render has no compressed preview sibling), never missing. The two versions also ride along as MCP audio blocks in order: **first block = baseline, second = after**.

**Deliver audio:**
`logic_render_track {track_name, start_bar?, end_bar?}` — dialog-free track export (32-bit float AIFF + optional bar-sliced WAV with RMS/peak metrics), ~9–13 s. `logic_bounce_range` for the master, now with the delivery options the dialog actually has: `file_type` (AIFF/WAVE/CAF), `bit_depth`, `sample_rate` (`"48 kHz"`, `"48k"` and `48000` all work), `dithering`, `normalize`, `include_audio_tail`. Whatever you do not pass is left as the user set it, and the result's `delivered_as` says what the file really is. Those are the user's own settings and Logic keeps them — `options_changed` lists what you moved, and nothing puts it back.

**Stems for a mixer or a picture editor:**
`logic_export_stems {tracks: [...], start_bar, end_bar}` — one offline bounce per track over the SAME range, each with only that track soloed, and the frame counts compared afterwards so `aligned` is an observation. Read the contents note before you promise anything about them: a stem here is the full master output heard one track at a time (post-fader, post-pan, with that track's send returns and the master chain), so summing them reproduces the mix only while the master chain is linear.

## Listening to audio (IMPORTANT)

**The sound comes to you.** Every `logic_bounce_range` and `logic_render_track` result CARRIES its audio as an MCP audio content block — and `logic_evaluate_change` carries BOTH versions (first block = baseline A, second = after B), so you hear the A/B in the same result you decide from. First-run handshake: after your first bounce, check whether an audio block reached you. If yes — listen, always. If the result arrived as text only, your client drops audio blocks: from then on open the returned `preview_path`/`clip_path` files with your client's FILE VIEWER (read-file capability), which most clients pass to the model as real multimodal audio (verified in Antigravity CLI). Never claim to have heard something you did not receive.

**Mix by ear, verify by numbers.** Fader and parameter values are NOT loudness or quality: recordings differ in level, plugins differ in character, so a track at -1.6 dB can be far louder than one at 0.0 dB. Never diagnose a balance problem from fader positions, and never judge a reverb/EQ amount from its printed value. The loop is: LISTEN (bounce, open the preview with your file viewer) → hypothesize → change → LISTEN again → only then look at metrics to confirm what you heard. A change you have not listened to is not verified, whatever the deltas say.

**NEVER read an audio file with a text/file tool.** Render and bounce results return file paths to multi-megabyte binary files; reading one into your context will overflow it and can crash your client outright. Instead:

- Judge objectively with the returned `metrics` (RMS/peak per channel) and `deltas` from `logic_evaluate_change`.
- **To actually HEAR audio, the reliable route is your client's FILE VIEWER on the `preview_path`** — the compressed stereo `.m4a` sibling every render/bounce result includes. Many client harnesses (verified: Antigravity CLI) pass a viewed audio file to the model as real multimodal audio even though they DROP MCP audio content blocks. Use the viewer/read-file capability, never bash/cat.
- `logic_get_audio_clip {path, start_seconds?, duration_seconds?}` returns a short mono AAC clip as a native MCP audio content block — use it when your client forwards audio blocks (test once: if the tool result reaches you as text only, your client drops them; switch to the file-viewer route). Pick the interesting window (e.g. where the regions are) rather than second 0, which may be silence.
- **If your client mangles audio blocks, turn them off.** `logic_bounce_range`, `logic_render_track`, `logic_evaluate_change` and `logic_get_audio_clip` take `include_audio` (default `true`). A client that stringifies unknown content blocks turns a ~300 KB block into a context-overflow event; passing `include_audio: false` gives you the same result with the file paths only, and the note says so rather than claiming audio it did not send. Use the file-viewer route on those paths instead.
- **Sanity-check what you hear against the numbers**: bounce results now include `metrics` and a `warning` when the file is SILENT or when tracks are left SOLOED. A leftover solo silently empties every master bounce — if the warning names soloed tracks, unsolo before trusting any bounce.

## Reading a result

Every successful result carries the same four fields, and they mean different things — do not collapse them:

- **`success`** — the operation did what it was asked to do. `false` means it did not; look at `error` and `error_code`.
- **`verified`** — Logic's own feedback confirmed the new state (an LCD echo, a readback, a header checkbox). `success: true, verified: false` means the write went out but could not be confirmed: treat the value as unknown and re-read before building on it.
  - **`verified` never reports on a separate *observation*.** `logic_record_midi` is the case to know: `verified` describes the recording (the transport rolled, the stream went out, the restore completed), while the proof render is reported apart from it as **`verification_render`** — `ok`, `silent`, `unreadable` or `failed`. A `silent` or `failed` render does **not** mean the notes are missing; it commonly means the instrument made no sound (muted, no patch, notes out of range). Do not re-record a take on that alone — bounce the range and listen first.
- **`state`** — what happened, as a word you can branch on (below).
- **`write_route`** — which mechanism did it (`bridge_converge`, `mcu_vpot_converge`, `midi_key_command_save`, `ax_value_stepwise_db_converge`, …). Useful when something is slow or a fallback fired: an `ax_*` route means the MCU path was unavailable.

**The `state` vocabulary.** The stem names the operation's outcome — `saved`, `bounced`, `evaluated`, `renamed`, `deleted`, `moved`, `duplicated`, `closed`, `recorded`, `volume_set`, `pan_set`, `plugin_added`, `plugin_removed`, `cycle_range_set`, `on`/`off`, `stopped`, `confirmed`, `failed`.

**An `already_` prefix means nothing was changed** — the target was already in the requested state (`already_saved`, `already_selected`, `already_on`, `already_expanded`, `already_open`, `already_stopped`, `already_cycle_on`, …). This is the signal worth branching on: it is a successful no-op, so it is not a reason to retry, and in an A/B loop it means your "before" and "after" are the same thing. If you expected a change and got `already_*`, your model of the project is wrong — re-read before continuing.

**Restoration.** When a write fails after partially landing, the error carries `restored: true/false`. `false` means the project is in an in-between state and you must re-read; the tools never guess this flag — an unverifiable restoration reports `false`.

## Error taxonomy

- `not_found` / `not_exposed` — the target does not exist or is not reachable; the message lists what IS visible. Check names/slots.
- `precondition_failed` — a precondition for the write was not met; nothing was written. Usually your `expected_current_value` did not match reality — re-read and decide. It is also the code for the project-state guards: an Adapt/Auto Smart Tempo mode (`logic_record_midi`), a non-constant tempo where it cannot be worked around (`logic_set_tempo`, `logic_record_midi` with `speed > 1`, and `logic_evaluate_change` method `render` *only when the tempo map could not be read*), and an MCU display left in SMPTE mode. Those messages name the fix or the alternative tool; that is the next step, not a retry.
- `ambiguous` — multiple candidates matched; the message lists them. Disambiguate (track_number, start_bar). For a headerless strip there is no number to pass: the message lists the LCD cells that matched, and the fix is a rename.
- `verification_failed` — the write happened but Logic's feedback did not confirm; the message says what was observed and whether state was restored. Treat the operation as suspect, re-read before continuing.
- `invalid_arguments` — schema-level problem; fix the call.

## Cautions

- Track stacks cannot be freeze-rendered or MIDI-recorded onto; tools refuse cleanly — use subtracks.
- On a headerless strip (`Stereo Out`, an aux, a bus) the independent Accessibility cross-check that `logic_add_plugin` / `logic_remove_plugin` normally run can be UNAVAILABLE — no inspector is showing that strip. The write then stands on the control surface's own echo alone and the result carries a `warning` plus `cross_check: "unavailable"`. Open the Mixer (or select a track routed to the strip) and re-read the inserts if you want a second source.
- Logic sometimes SUBSTITUTES words when it abbreviates a name onto the LCD (the track "Ivan Effect" appears as `IvanFx`). Such a name cannot be resolved on the control surface at all: you get `not_found` with the visible strips listed — never a write on the wrong strip. Rename the track, or reach it via a track-plane tool.
- A rendered file that is honestly EMPTY (a track with no regions, or MIDI with no instrument) comes back with a `warning`, not fake success.
- Modal dialogs freeze most operations; tools detect and answer their own dialogs, and `logic_health` flags Logic's state. If something looks stuck, check for a dialog in Logic. **The symptom is worth memorising**: while a modal is up, key commands sent over MIDI are swallowed, so every tool that uses one reports "the command fired and nothing happened" — several calls in a row failing that way means a dialog, not a broken tool. `logic_split_region` raises exactly such a modal on a MIDI region ("Notes Crossing Split Point") and answers it for you.
- **Learning a key command writes into the user's own Logic.** `logic_learn_key_command` binds a MIDI note to a command in the user's active key command set — additive (their keyboard shortcut is untouched), removable in Logic's Key Commands window under Delete Assignment, and recorded in the registry with the tool that bound it and when (`logic_list_key_commands` reads it back; the registry is also the consent record `logic_trigger_key_command` checks before firing anything). Three habits follow. **Say what you are binding** before you bind a batch of them — this is the user's editing environment, not a scratch space. **Look first** with `dry_run: true` when you are unsure of a name: Logic 12.3.1 spells things its own way (there is no "Strip Silence" — the command is `Remove Silence from Audio Region…`; the selection command is `Select All Following of Same Track/Pitch`), and the dry run lists the real rows without binding anything. And **know which tools learn on their own**: `logic_select_regions` and `logic_remove_silence` learn the one command they need if it is missing, and say so in the result (`learned_key_command`, `consent_note`).
- **A blind Undo is worse than it looks.** `logic_trigger_key_command {name: "Undo"}` undoes whatever is on top of Logic's stack, which is not necessarily yours — in one session an Undo fired after a tool had *failed* removed an empty track someone else had just made, and nothing could tell it apart from a no-op. Fire Undo only when a tool reported `success: true` for the edit you want back, and re-read the arrangement map afterwards. To remove something you created, address it (`logic_delete_region`) instead.
- The `logic_set_plugin_parameter` / `logic_list_plugin_parameters` (Accessibility window) variants exist for stock-plugin windows; PREFER the `logic_mcu_*` variants, which work for every plugin including custom-UI third-party ones.

## Tool reference

All 64 tools, generated from the live server schemas (v0.49.0), with the strip-addressing notes added by hand in v0.51.0, the `logic_plugin_preset` section rewritten by hand in v0.52.0, and the key-command / region / delivery tools added by hand in v0.54.0 — where an entry and the live schema differ in wording, the schema is authoritative. Every write is compare-and-set with readback; every failure names what was observed.

#### `logic_health`

Read Logic Pro process and Accessibility readiness without changing Logic.

Parameters:

  - (no parameters)

#### `logic_list_windows`

List Logic windows with subrole and project document path, read-only. Windows whose document is set are project windows; dialogs without a document are plugin or auxiliary windows.

Parameters:

  - (no parameters)

#### `logic_list_tracks`

List the track headers currently rendered in the Tracks area (track number, name, selected), read-only. Scrolled-out or hidden tracks are not exposed by Logic.

Parameters:

  - (no parameters)

#### `logic_list_inserts`

List audio-effect insert slots (index, plugin display name, bypass state) of the named track's channel strip, read-only. The track must be selected so its strip is shown in the left inspector; otherwise the error not_exposed reports which track is currently shown. **Strips without a track header** (`Stereo Out`, aux, bus) work only while an inspector is SHOWING that strip (select a track routed to it, or open the Mixer); otherwise use the `logic_mcu_*` tools, which reach every strip.

Parameters:

  - `track_name` (string) **(required)**: Exact track name as shown in the track header.

#### `logic_bounce_range`

Offline-bounce a bar range of the master output to an audio file, many times faster than realtime playback. Drives Logic's bounce dialog and its XPC save panel entirely through verified accessibility (no playback). Switches the bounce destination to Uncompressed. Returns the file path.

Parameters:

  - `end_bar` (integer) **(required)**
  - `expected_project_path` (string)
  - `label` (string): Filename label, e.g. 'A' or 'baseline'.
  - `start_bar` (integer) **(required)**
  - `file_type` (string): AIFF, WAVE or CAF.
  - `bit_depth` (string): 8-bit, 16-bit, 24-bit or 32-bit float.
  - `sample_rate` (string or number): `"48 kHz"`, `"48k"` and `48000` all reach 48 kHz; 11.025 through 192 kHz.
  - `dithering` (string): None, POW-r #1 (Dithering), POW-r #2/#3 (Noise Shaping), UV22HR. Only meaningful when reducing bit depth.
  - `normalize` (string): Off, Overload Protection Only, On. `On` changes the delivered level — say so when you report the result.
  - `include_audio_tail` (boolean): let reverb/delay tails ring past the end bar into the file.

**The delivery options are the user's own settings.** Anything you do not pass is left exactly as it was; anything you do pass is verified by reading the pop-up back, and an unknown value is refused with the real list BEFORE the dialog does anything. The result's `delivered_as` is the whole delivery state read off the dialog just before OK — that, not your arguments, is what the file is. Logic keeps these settings for the next bounce: `options_changed` lists what moved and nothing puts it back. MP3 and M4A destinations exist in the dialog with their own option set and are not implemented here.

#### `logic_bounce_in_place`

PRINT a region (or a whole track) back INTO the project as audio — the resampling verb, and the one `logic_render_track` is not: that writes a file to disk, this creates a new audio REGION you can chop and re-bounce. Drives `File > Bounce > Regions in Place…` (`scope: "region"`, default) or `Tracks in Place…` and answers the sheet. Every sheet control is left as the user set it unless you pass the matching argument, and the whole sheet state comes back in the result. Verified against the arrangement map; Undo removes the print.

Parameters:

  - `scope` (`region` | `track`), `track_name`, `region_name`, `start_bar`
  - `name` (string): name for the printed region (Logic's default is `<region>_bip`).
  - `destination` (`new_track` | `selected_track`), `source` (`mute` | `leave` | `delete`)
  - `normalize` (string), `bypass_effect_plugins`, `include_volume_pan_automation`, `include_audio_tail_in_region`, `include_audio_tail_in_file`, `bounce_second_loop_pass`, `include_instrument_multi_outputs` (booleans)

**`Bypass Effect Plug-ins` is the trap.** It is a real Logic setting that may be ON in the user's project, and a print made with it on is DRY — the inserts are not rendered. The result warns when it was on; pass `bypass_effect_plugins: false` to print the sound as you hear it.

#### `logic_export_stems`

One offline bounce per named track over the SAME bar range, each with only that track soloed, solo restored after every one. The shared range is what makes them stems rather than a loop of renders, and the tool verifies it: the files' frame counts are compared and `aligned` says whether they really line up. Refuses before the first render if any track is already soloed. Costs one full bounce per track; 16 tracks per call.

Parameters:

  - `tracks` (array of strings) **(required)**: names as `logic_list_tracks` reports them; duplicates refused.
  - `start_bar`, `end_bar` (integers) **(required)**
  - `label` (string): filename prefix; the track name is appended per stem.
  - `expected_project_path` (string)

**What a stem here contains**: the full master output with one track audible — post-fader, post-pan, post-insert, WITH that track's send returns, and through the master chain. Two consequences to plan around: summing the stems reproduces the mix only while the master chain is LINEAR (a master limiter reacts to the whole mix and cannot react to one stem), and a bus fed by several of these tracks is counted once per stem. `logic_render_track` is the other kind of file — a pre-fader freeze of the track alone — and it is not a stem.

#### `logic_evaluate_change`

Run one complete closed-loop mix evaluation around exactly one verified plugin-parameter change, on a bar range. Three methods: 'render' (two dialog-free freeze renders of the SINGLE track, compared on the sliced bar range — fastest and most isolated; needs insert_slot, the MCU physical slot, and works for all plugins including third-party), 'bounce' (two offline MASTER renders via the bounce dialog, needs plugin_name), and 'solo_bounce' (two offline bounces with ONLY this track soloed, solo restored after; needs insert_slot like 'render' — use for tracks freeze refuses: stack subtracks and tracks sharing a channel strip). All methods roll the change back by default, return baseline/after audio paths, metrics and dB deltas, and CARRY both versions as audio content blocks.

**Tempo (method `render` only).** `render` cuts both compared slices out of a freeze render itself, so under a tempo map constant-tempo math would make the baseline slice and the changed slice cover *different music* — and the dB delta would report that difference as if the plugin had caused it. So the tool reads the project's tempo map out of the Tempo List first and **integrates** it: both slices then cover the same bars and the A/B is sound on a mapped project (the result reports the map in `tempo_map`, and a `warning` if a tempo curve could have moved the boundaries). Only when the Tempo List cannot be read does it fall back to sampling the tempo at both ends of the range and **refusing with `precondition_failed`** if the readings differ, naming `bounce` (offline master A/B) and `solo_bounce` (soloed offline A/B) as the alternatives. Those two hand Logic the bar numbers, so they are correct under any tempo map and read no tempo at all. When the sample itself cannot run, the A/B proceeds and the result carries a `warning` saying the check went unverified: a failed check must not break an evaluation that works.

Parameters:

  - `beats_per_bar` (number): Override meter for bar math; default reads the control bar's time signature.
  - `end_bar` (integer) **(required)**: Exclusive: the range ends where this bar begins.
  - `expected_current_value` (string) **(required)**
  - `expected_project_path` (string)
  - `insert_index` (integer)
  - `insert_slot` (integer): MCU physical insert slot 1-8; required for methods 'render' and 'solo_bounce' (list with logic_mcu_plugin_inserts).
  - `keep_change` (boolean): true keeps the change after measuring; default false rolls it back.
  - `method` (string): REQUIRED: 'render' (dialog-free single-track freeze A/B on the sliced bar range), 'bounce' (offline master A/B) or 'solo_bounce' (soloed offline A/B for tracks freeze refuses: stack subtracks, shared-channel tracks).
  - `parameter` (string) **(required)**
  - `plugin_name` (string): Plugin window title; required for methods 'realtime' and 'bounce'.
  - `settle_seconds` (number): Extra settle time after each phase, default 2.
  - `start_bar` (integer) **(required)**
  - `target_value` (string) **(required)**
  - `tempo` (number): Override BPM for bar math (method 'render'); default reads the control bar. Used only when the tempo map cannot be read (see the tempo section above); constant *meter* is still assumed.
  - `track_name` (string) **(required)**
  - `verify_rollback` (boolean): Measure a third control window after rollback (default false; rollback accuracy has been verified at ~0.0 dB residual repeatedly).

#### `logic_mcu_plugin_inserts`

List a track's insert slots as the Mackie Control sees them (physical slot numbers 1-8 with plugin names), via the selected track's MCU plugin list. Works for ALL plugins including custom-UI third-party ones. Selects the track first. **Strips without a track header** (`Stereo Out`, `Master`, aux and bus channels) are accepted: they resolve on the control surface (LCD name + SELECT LED verified before any write). Use the Mixer name, not the 6-character LCD abbreviation.

Parameters:

  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_mcu_plugin_parameters`

Read ALL of a plugin's parameter names and formatted values (every MCU page) via host automation — works for plugins whose UI exposes nothing to Accessibility (Decapitator, Trilian, ...). insert_slot is the MCU physical slot from logic_mcu_plugin_inserts. **Strips without a track header** (`Stereo Out`, `Master`, aux and bus channels) are accepted: they resolve on the control surface (LCD name + SELECT LED verified before any write). Use the Mixer name, not the 6-character LCD abbreviation.

Parameters:

  - `insert_slot` (integer) **(required)**
  - `max_pages` (integer): Page cap, default 12 (each uncached page costs ~1.7 s; large instruments have 80+). pages_total and truncated report what was left out.
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_mcu_set_plugin_parameter`

Set one plugin parameter through host automation (MCU vpot) with the LCD value echo as verified readback — the data-plane route that reaches every plugin. Numeric targets converge adaptively; text targets (e.g. 'On', 'B') step until exact match. Optional expected_current_value enforces compare-and-set; failed verification rolls back. Parameter is matched against the MCU's abbreviated names (e.g. 'Thrs' matches 'Threshold'). **Strips without a track header** (`Stereo Out`, `Master`, aux and bus channels) are accepted: they resolve on the control surface (LCD name + SELECT LED verified before any write). Use the Mixer name, not the 6-character LCD abbreviation.

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

#### `logic_mcu_status`

Read the Mackie Control bridge's mirrored state: LCD text (track names/values as data), fader positions, transport LEDs, timecode display, online status. This is Logic's documented control-surface feedback channel — no UI, no focus, no windows involved. Requires logic-mcu-bridge running and a Mackie Control configured in Logic pointing at the 'Logic MCP MCU' ports.

Parameters:

  - (no parameters)

#### `logic_mcu_sends`

List a track's sends as data via the Mackie Control channel send view: slot number, destination bus, level in dB, position (pre/post fader) and status. UI-independent; competitors' MCPs do not expose sends at all. **Strips without a track header** (`Stereo Out`, `Master`, aux and bus channels) are accepted: they resolve on the control surface (LCD name + SELECT LED verified before any write). Use the Mixer name, not the 6-character LCD abbreviation.

Parameters:

  - `expected_project_path` (string)
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_mcu_set_send`

Set one send's level in dB on a track, verified through the MCU LCD echo (compare-and-set with expected_current_value, readback, same discipline as plugin parameters). Only the level vpot is touched — never the destination. List sends first with logic_mcu_sends. **Strips without a track header** (`Stereo Out`, `Master`, aux and bus channels) are accepted: they resolve on the control surface (LCD name + SELECT LED verified before any write). Use the Mixer name, not the 6-character LCD abbreviation.

Parameters:

  - `expected_current_value` (string): Abort unless the current LCD value matches (e.g. '-9.0dB' or '-9.0').
  - `expected_project_path` (string)
  - `level_db` (number) **(required)**: Target level in dB, e.g. -9.0.
  - `send` (integer) **(required)**: Send slot 1-8.
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_record_automation`

Write an automation curve on a track — volume (absolute fader), pan, a send level (send: 1-8) or ANY plugin parameter (insert_slot + plugin_parameter) — with no mouse and no automation-lane clicking. The value scale follows the parameter: dB for volume/sends, -64..63 for pan, the plugin's own units otherwise. Mechanism: calibrate the control near the working range, switch the track to Latch over the control surface, roll playback placing calibrated moves at each musical moment, return to Read, restore the original value, and verify by REPLAYING the range while sampling Logic's own echo at every point. ramp (default true) interpolates between points. Points need bar >= 2. Takes real time (the automated range, twice with verify)

**Tempo map.** Each point's musical moment, the pre-roll bar's length and the per-point convergence budgets are integrated over the project's tempo map (read from Logic's Tempo List, cached, no playhead movement; reported in `tempo_map`), so a curve that crosses a tempo change lands on the beats you asked for. Without a readable map it falls back to one `msPerBeat` from the control bar. The verification is bar-based either way — it chases the playhead — so it is the proof the points landed, not a restatement of the same math.

Parameters:

  - `parameter` (string): v1: 'volume' only.
  - `points` (array of object) **(required)**
  - `ramp` (boolean): Default true: smooth linear ramps between points.
  - `track_name` (string) **(required)**
  - `verify` (boolean): Default true: replay the range in Read and sample the fader echo per point.

#### `logic_record_midi`

Compose MIDI into the project with ZERO dialogs and no files: notes are streamed in real time over the dedicated 'Logic MCP MIDI In' port while Logic records them onto the selected software-instrument track (playhead parked one bar early; the stream starts on the observed MCU-timecode crossing into start_bar, so count-in settings do not matter). Creates a normal recorded region. By default the result is verified with a dialog-free freeze render of the recorded bars (non-silent metrics prove the notes landed and sound through the instrument). Recording takes real time: bars x beats x 60/BPM seconds. The region can be removed with Undo in Logic.

**Smart Tempo guard.** Logic's project tempo mode decides what a recording does to the project's *tempo map*: **Keep** leaves it alone, **Adapt** rewrites it to follow the recording, **Auto** picks one (leaning Adapt when the metronome is off). Since Logic 10.4.2 this applies to MIDI recordings too — so on an Adapt-mode project this tool would silently overwrite the user's tempo track. It therefore reads the mode before arming and:

  - **ADAPT** → refuses with `precondition_failed`, nothing recorded.
  - **AUTO** → refuses the same way: Auto can resolve to Adapt and which one Logic picked is not verifiable from here.
  - **KEEP** → records; the result carries `project_tempo_mode: "keep"`.
  - **mode not readable** → records, and the result carries a `warning` saying the check went unverified. Logic's control bar does expose the Project Tempo pop-up button but publishes no *value* on it through Accessibility (probed 2026-08-27, Logic Pro 12.3.1), so this is the normal case today, not an edge case. Read the mode yourself in the LCD's tempo display, or in File → Project Settings → Smart Tempo.

The fix the refusal names: set the project tempo mode to KEEP — click the tempo display in the LCD (the small Project Tempo pop-up under the tempo), or File → Project Settings → Smart Tempo. `logic_get_transport` reports `project_tempo_mode` when it is readable, and `project_tempo_mode_note` explaining why when it is not.

**Tempo map handling.** Separate from Smart Tempo, and about *reading* the tempo rather than Logic rewriting it. Every note's ms offset is the **integral of the project's tempo map** from the take's first bar line to that note, with the map read out of Logic's Tempo List (once per call — the verification render shares the same answer, and no playhead is moved). A take that crosses a tempo change therefore lands on the grid, and the result reports the map in `tempo_map`. When the Tempo List cannot be read, the pre-map behavior is the fallback — one `msPerBeat` from one control-bar reading, plus the two-point sample:

  - **map read, more than one tempo** → records at speed 1 with the offsets integrated; the `warning` names the map and, if a tempo *curve* could have moved the timing, by how much.
  - **`speed` > 1 on a non-constant tempo** → refuses with `precondition_failed`, nothing recorded — with or without a readable map. Speed mode raises the control bar's tempo slider for the take and writes a *single* BPM back afterwards, which cannot restore a tempo map. Re-run without `speed`.
  - **map unreadable, sampled readings differ** → records anyway at speed 1, with a `warning` naming both readings and why the map could not be read; the notes are on the timeline but their positions drift from the first tempo change onward. Quantize, or record shorter takes between tempo changes.
  - **map unreadable and the sample could not run** → records, with a `warning` saying the tempo went unverified.

Both guards can fire at once, and then the result's `warning` carries both, joined by `ALSO:`.

Parameters:

  - `beats_per_bar` (number): Override meter; default reads the control bar.
  - `cc_events` (array of object): MIDI CC events recorded alongside the notes — e.g. mod-wheel sweeps (cc 1), expression (cc 11). Emit many points for smooth curves.
  - `expected_project_path` (string)
  - `notes` (array of object) **(required)**: The notes to record.
  - `pitch_bends` (array of object): Pitch-bend events: value -8192..8191 (0 = center). Emit many points for smooth bends, and return to 0 at the end.
  - `speed` (number): Optional fast mode: record at speed x tempo (1-8, default 1) and scale event times — same bar positions in a fraction of the wall time. Default 1 keeps real-time recording so the take is audible as it happens; higher speeds trade timing precision (jitter scales with speed) and chipmunked monitoring.
  - `start_bar` (integer): Recording start bar (>= 2); default = the earliest event's bar.
  - `sync_compensation_ms` (number): Timecode display latency compensated in the beat-edge sync, default 45 ms (measured). Raise if notes land early, lower if late.
  - `tempo` (number): Override BPM; default reads the control bar. Used only when the tempo map cannot be read, and it never switches the tempo checks off.
  - `track_name` (string) **(required)**: Software instrument track to record onto (not a track stack).
  - `track_number` (integer)
  - `verify_render` (boolean): Default true: freeze-render the recorded bars afterwards and return slice metrics as proof.

#### `logic_plugin_preset`

Browse and load a plugin's settings (what Logic's own menu calls *settings* and everyone else calls presets). Three actions:

  - **`list`** — read-only enumeration of the plugin window's setting menu: every name, the category it sits in, and which one Logic marks as loaded. Changes nothing.
  - **`select`** — load one by name, verified against the window's setting label. `name` takes the bare name (`"Rock Bass"`) or a qualified path (`"03 Guitars/Rock Bass"`, also `>` or ` - `) when two categories of the same plugin share a name. Case- and diacritic-insensitive, and **never fuzzy**: a near miss is refused with the available names rather than guessed at, because loading the wrong setting overwrites the plugin.
  - **`step`** — the v1 behaviour, unchanged: walk next/previous N settings via Logic's topmost-plugin-window key command. The only route that needs no readable menu, so it is the fallback for plugins whose UI hides everything.

The default action is `step`, or `select` when `name` is given — so every call that worked before this tool grew actions still means exactly what it did. The plugin window is opened and closed again if the call opened it. Reading the menu brings Logic frontmost for a moment: a macOS menu cannot open in a background app.

**⚠️ Loading a setting overwrites EVERY parameter of the plugin, and a setting *name* is not a promise about the current *state*.** A plugin whose header reads `FET Electric Bass` may hold that setting with tweaks on top; loading any setting throws those away, and re-selecting the old name does **not** bring them back (measured 2026-08-27: one of eleven Compressor parameters did not return). Logic's own Compare button is not a reliable modified-indicator across sessions. The way back is the plugin window's own **Setting ▸ Undo**. This applies to `step` as much as to `select` — both carry the warning in their result.

**Honest failures.** `list` returns `presets: null` plus a `reason` when the plugin exposes no Logic setting pop-up at all (a fully custom UI — `step` is then the only route), and `presets: []` — an empty list, which is a *result*, not a failure — for plugins that genuinely ship no factory settings (observed on Sensor and on third-party instruments). `select` refuses with `not_found` (available names listed) or `ambiguous` (qualified paths listed) without pressing anything. `step` reports `success: false` when the label did not move (end of the list, or nothing readable).

**Strips without a track header** (`Stereo Out`, `Master`, aux and bus channels) are accepted: they resolve on the control surface (LCD name + SELECT LED verified before any write). Use the Mixer name, not the 6-character LCD abbreviation. One limit worth knowing: the setting menu lives in the plugin **window**, which is an Accessibility object, so a headerless strip also has to be *showing in an inspector* for the window to open — verified working on `Stereo Out` (its Channel EQ enumerated 114 settings in 7 categories), but `Master` and `Aux 1` are only reachable while an inspector shows them.

Parameters:

  - `action` (string): `'list'`, `'select'` or `'step'`. Default: `'step'`, or `'select'` when `name` is given.
  - `direction` (string): For `step`: 'next' (default) or 'previous'.
  - `insert_index` (integer)
  - `name` (string): For `select`: the setting to load, as `list` reports it.
  - `plugin_name` (string) **(required)**
  - `steps` (integer): For `step`: how many settings to step, default 1.
  - `track_name` (string) **(required)**
  - `track_number` (integer)

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

#### `logic_add_send`

Create a send on a track to a bus/output — mouse-free via the control surface's send-destination browser (first empty slot, browsed to the named destination, settle-verified, confirmed). New sends start at -oo dB; set the level with logic_mcu_set_send. Destination names as Logic shows them, e.g. 'Bus 1', 'Bus 2'. **Strips without a track header** (`Stereo Out`, `Master`, aux and bus channels) are accepted: they resolve on the control surface (LCD name + SELECT LED verified before any write). Use the Mixer name, not the 6-character LCD abbreviation.

Parameters:

  - `destination` (string) **(required)**: e.g. 'Bus 3'.
  - `track_name` (string) **(required)**

#### `logic_create_track`

Create a new track (software_instrument or audio) via Logic's key command, answering the Create New Track dialog automatically. Verified by the track count increasing.

Parameters:

  - `type` (string): 'software_instrument' (default) or 'audio'.

#### `logic_list_regions`

The arrangement map: every region on every visible track row, with name, start/end bar (and beat when off the barline), type (midi/audio) and selection state — parsed from Logic's own accessibility descriptions. Read-only. Optionally filter to one track.

Parameters:

  - `track_name` (string): Optional: only this track's regions.

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

#### `logic_split_region`

Split ONE region at a bar (and optional beat) — the three-call recipe as a single call with one verdict. Three failure modes, checked in order, the first two before anything is written: the split point is outside the region (refused with the region's own span), the playhead did not land where it was asked (this parks it exactly — see the note below), or the command fired and the arrangement map still shows one region. Success is proven by the map. On a MIDI region whose notes cross the cut Logic raises a modal and this answers it with `notes_crossing`; on a failure path any leftover dialog is cancelled. Undo restores the single region — and the halves are NEW regions, so re-read `logic_list_regions` before addressing either.

Parameters:

  - `track_name` (string) **(required)**
  - `region_name` (string), `start_bar` (integer): which region.
  - `at_bar` (integer) **(required)**, `at_beat` (integer): where to cut. Must be inside the region.
  - `notes_crossing` (`keep` | `shorten` | `split`): what happens to a note that straddles the cut. Default `split`, Logic's own pre-selection. Audio regions raise no dialog and report `notes_crossing: "not_asked"`.

**Why this parks the playhead itself.** The control bar publishes only `bar` and `beat`, and both are RELATIVE steppers: a sub-beat offset already in the playhead is carried along by every step, so a *verified* "bar 5, beat 1" can sit 0.96 beats late while the display reads `5 bars 1 beat` (measured). This presses `Go to Beginning` first when the MCU position display shows an offset, which is the one absolute move Logic offers, and reports `playhead.on_grid` from the MCU's division/tick fields — `null`, never `true`, when the surface cannot be read.

#### `logic_select_regions`

Select MANY regions — what `logic_select_region` deliberately cannot do. Modes: `track` (every region on the anchor's track), `following` (the anchor and everything after it, on every track), `following_same_track`, `all`, `none`. The relative modes need an anchor (`track_name`, plus `region_name`/`start_bar` when the track holds more than one region), which is selected exclusively first. The selected count is read before and after off the arrangement map; a mode that moved nothing comes back `success: false`. Counts see visible rows only, while the selection is project-wide.

Parameters:

  - `mode` (string) **(required)**: `track` | `following` | `following_same_track` | `all` | `none`.
  - `track_name` (string): the anchor's track; required for everything except `all` and `none`.
  - `region_name` (string), `start_bar` (integer): which region is the anchor.

#### `logic_remove_silence`

Cut the silence out of ONE audio region (what other DAWs call strip silence; Logic 12.3.1's command is `Remove Silence from Audio Region…`). `apply: false` — the default — opens the window, reads Logic's LIVE preview of how many regions the current settings would leave, closes it and changes nothing. `apply: true` commits and verifies against the arrangement map. Refuses on a MIDI region. The window's four numeric fields (threshold, minimum silence, pre-attack, post-release) are per-digit steppers this server does not write; their current values are reported.

Parameters:

  - `track_name` (string) **(required)**
  - `region_name` (string), `start_bar` (integer)
  - `apply` (boolean): default false (preview only).

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

#### `logic_set_tempo`

Set the project tempo in BPM via the control bar's tempo display (rapid-fire stepwise converge, ~1.3 s per 120 BPM of distance). Whole-BPM resolution. Compare-and-set with expected_current_bpm.

**Tempo map guard.** The display this tool writes shows and sets the tempo **at the playhead**. On a project with a tempo track, a single write to it therefore edits whichever tempo node the playhead happens to sit on — an edit to the user's tempo map that no result would have mentioned. So the tool reads the project's tempo map out of Logic's Tempo List and **refuses with `precondition_failed`** when it holds more than one tempo. That read costs ~2 s, moves **no playhead**, and is exact: it names how many tempo events the project has.

When the Tempo List cannot be read, the fallback is the two-point sample: the tempo at the playhead and at **bar 1** (the project's first tempo node, the one point every project has), refusing the same way when they differ. `tempo_sampled_at_bars` in the result then says which two bars were compared, and when even that check cannot run the write proceeds with a `warning` telling you to check the tempo track. The sample costs roughly 0.13 s per bar of playhead travel, both ways, so a playhead far from bar 1 makes that path take several seconds.

There is deliberately **no override argument**, and "park the playhead somewhere deliberate and pass `expected_current_bpm`" is *not* offered as a workaround: which node Logic edits — or whether it creates a new one — has not been verified from here, so it would be a guess dressed as consent. Edit a tempo map where it lives: Logic's tempo track, or the Tempo List (`View > List Editors > Tempo`), where every tempo event is an editable row.

Parameters:

  - `bpm` (number) **(required)**: Target tempo, 5-990.
  - `expected_current_bpm` (number): Abort unless the current tempo matches. Compared against the tempo at the playhead — which is the only tempo the control bar has.

#### `logic_save_project`

Save the open Logic project — the ONLY way this server ever saves; no other tool saves as a side effect. Fires the Save key command and verifies via the document's modified flag. Refuses when more than one project is open, when the project has never been saved, or when expected_project_path does not match. Returns already_saved when there is nothing to save.

Parameters:

  - `expected_project_path` (string): Recommended: absolute .logicx path that must match the open project.

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

#### `logic_duplicate_project`

Duplicate the OPEN project on disk and (by default) open the copy — the safe sandbox for destructive experiments: the original stays untouched. The copy is the on-disk state; pass save_first: true to save unsaved changes into it first. Default destination: '<name> Copy.logicx' next to the original. Opening the copy closes the current project (single-project mode; if_current_modified defaults to 'save' here since the original is the project being closed).

Parameters:

  - `destination_path` (string): Optional .logicx path for the copy.
  - `if_current_modified` (string): 'save' (default here) or 'dont_save' for closing the original when opening the copy.
  - `open_copy` (boolean): Open the copy after duplicating. Default true.
  - `save_first` (boolean): Save the open project before copying so the copy includes unsaved changes. Default false.

#### `logic_close_project`

Close the open project via AppleScript. 'saving' must be an explicit 'yes' or 'no' — there is no default, because discarding versus persisting changes is always the caller's decision.

Parameters:

  - `expected_project_path` (string)
  - `saving` (string) **(required)**: 'yes' saves before closing; 'no' discards unsaved changes.

#### `logic_setup_key_commands`

One-time onboarding: learn MIDI-note assignments for all standard key commands (Toggle Track Freeze, Undo, Redo, Flashback Capture as Recording, Split at Playhead, Create Marker) into the user's Logic via the Key Commands window automation. Additive to the user's key command set and removable there; collisions with existing assignments get alternate notes automatically. Idempotent — already-learned commands are verified and skipped. Runs automatically the first time a tool needs a missing command, so calling this explicitly is optional. Pass relearn: true to force re-learning even for commands that look bound — the repair when key commands silently stopped firing (e.g. after the MIDI ports were recreated: Logic scopes the assignments to the port identity).

Parameters:

  - `commands` (array of string): Limit to these standard command names (default: all).
  - `relearn` (boolean): Force re-learning of every standard command even when an assignment is already shown. Repairs bindings orphaned by MIDI-port changes. Default false.

#### `logic_learn_key_command`

Learn ANY command in Logic's Key Commands window onto a MIDI note, so `logic_trigger_key_command` can fire it — not just the 22 standard ones. Give the name EXACTLY as the window spells it. **This writes into the user's own Logic key command set** (additive, removable there); the note is picked from the range reserved for learned commands (60–99, then 122–127, then 21–59), and the registry records the name, note, timestamp, search term and that this tool bound it. Already-registered commands answer immediately without opening the window. A name that matches no row fails `not_found` and LISTS the rows the panel was showing, because command names differ between Logic versions.

Parameters:

  - `name` (string) **(required)**: the command name as Logic's Key Commands window shows it (case-insensitive; Logic's spelling is what gets registered).
  - `search` (string): search term for the window's filter (default: the first words of `name`).
  - `note` (integer 0–127): force a specific note instead of the next free one; refused when another registered command holds it.
  - `relearn` (boolean): bind again even when the registry already lists it, wiping the command's existing controller assignments first.
  - `dry_run` (boolean): look, do not bind — returns every command name the filter shows with the assignment it already carries.

#### `logic_list_key_commands`

List what the key command registry holds: name, note, channel, when it was learned and which tool bound it, plus which standard commands are still unlearned. Read-only and Logic-free (it reads the registry FILE), so an entry it lists can still have been orphaned inside Logic by recreated MIDI ports — `logic_setup_key_commands` with `relearn: true` is the repair.

Parameters: none.

#### `logic_trigger_key_command`

Fire a Logic key command that was learned onto the dedicated 'Logic MCP Commands' MIDI port. Pass name (e.g. 'Toggle Track Freeze', 'Undo') or note+channel. Standard commands missing from the registry are learned automatically first; unknown notes are refused because they could be bound to anything. CAUTION with Undo: the menu shows no operation name, so only fire it right after a known edit.

Parameters:

  - `channel` (integer): MIDI channel, default 16.
  - `name` (string): Registered command name, e.g. 'Toggle Track Freeze'.
  - `note` (integer): MIDI note of a registered command.

#### `logic_render_track`

Render ONE track offline to an audio file with ZERO dialogs, via Track Freeze: selects the track, toggles freeze over the 'Logic MCP Commands' MIDI port, presses play (Logic then renders the whole track offline, typically seconds), copies the 32-bit float AIFF out of Media/Freeze Files to the captures folder, and unfreezes again. Requires 'Toggle Track Freeze' in the key command registry and the MCU bridge running. Renders the full track from project start including all plugins and automation (freeze mode Pre Fader). If the track is already frozen the call fails safely and restores state.

**Tempo (only with `start_bar`/`end_bar`).** The full render is a freeze from project start and needs no tempo at all — it is correct under any tempo map. The optional bar-range *slice* has boundaries **integrated over the project's tempo map**, read out of Logic's Tempo List (~2 s, no playhead movement, cached; reported in `tempo_map`), so a slice across a tempo change lands on the bars you asked for. When the Tempo List cannot be read the slice falls back to constant-tempo math and the tempo is sampled at both ends of the range instead, with a `warning` naming both readings if they differ — the render and the file are still valid, it is only the slice's boundaries that are not. For a tempo-accurate range in that case, bounce it instead (`logic_bounce_range`).

Parameters:

  - `beats_per_bar` (number): Override meter; default reads the control bar's time signature.
  - `end_bar` (integer): Exclusive: the slice ends where this bar begins.
  - `expected_project_path` (string): Absolute .logicx path; when given, the open project's AXDocument must match before anything is changed.
  - `label` (string): Filename label; default is derived from the track name.
  - `start_bar` (integer): With end_bar: also cut this bar range out of the render as a separate 32-bit float WAV with its own metrics (bar 1 = project start).
  - `tempo` (number): Override BPM for the bar math; default reads the control bar. Used only when the tempo map cannot be read; constant *meter* is still assumed.
  - `track_name` (string) **(required)**: Track to render, matched against MCU LCD names or AX track headers.
  - `track_number` (integer): Optional AX row number to disambiguate duplicates.

#### `logic_mcu_command`

Send a command to Logic through the Mackie Control bridge (UI-independent). cmd is one of: press {button: play|stop|record|rewind|forward|cycle|click|bank_left|bank_right|channel_left|channel_right|flip|name_value|assign_track|assign_send|assign_pan|assign_plugin|assign_eq|assign_instrument|...}, select/mute/solo {channel: 0-7}, fader {channel: 0-8, value: 0-16383}, vpot {index: 0-7, delta: +-n}, vpot_press {index}, raw {bytes: [..]}, ping. Read logic_mcu_status afterwards to verify via Logic's feedback.

Parameters:

  - `button` (string)
  - `bytes` (array of integer)
  - `channel` (integer)
  - `cmd` (string) **(required)**
  - `delta` (integer)
  - `index` (integer)
  - `note` (integer)
  - `value` (integer)

#### `logic_get_audio_clip`

LISTEN to rendered audio: returns a short clip (default 8 s, max 20 s) of a local audio file as an MCP audio content block (mono AAC, roughly 64 KB per 8 s) that multimodal models can hear. Use this on the file paths returned by logic_render_track / logic_bounce_range / logic_evaluate_change. NEVER read raw audio files with a text/file tool - megabytes of binary will overflow the model context and can crash the client. Also writes the clip to disk (clip_path in the result): if the audio block does NOT reach you, your client drops MCP audio - open clip_path with your client's file viewer instead, which most clients pass to the model as real audio.

Parameters:

  - `duration_seconds` (number): Clip length, default 8, max 20.
  - `path` (string) **(required)**: Absolute path to a local audio file (AIFF/WAV/etc).
  - `start_seconds` (number): Offset into the file, default 0.

#### `logic_get_transport`

Read the transport state from the control bar: playing, recording, cycle, playhead bar/beat, tempo, time signature, key signature, metronome, count-in. Read-only. Fields whose control bar element is missing are null.

Smart Tempo: `project_tempo_mode` ("keep"/"adapt"/"auto") is present only when the mode is actually readable. When it is not, the key is absent and `project_tempo_mode_note` says why and where to look instead — an unreadable mode is never reported as a value, because a missing value would read as "keep" and Adapt is the mode that rewrites the tempo track. See the Smart Tempo guard under `logic_record_midi`.

Parameters:

  - (no parameters)

#### `logic_set_cycle`

Turn cycle (loop) mode on or off via the control bar Cycle button and verify the new state.

Parameters:

  - `enabled` (boolean) **(required)**

#### `logic_set_playing`

Start or stop playback via the control bar Play button and verify the new state. Starting plays from the current playhead position (or the cycle range when cycle is on).

Parameters:

  - `playing` (boolean) **(required)**

#### `logic_set_playhead`

Move the playhead to a 1-based bar (and optional beat) by stepping the control bar position display, then verify. Requires the control bar display mode that exposes bar/beat (Beats & Project).

Parameters:

  - `bar` (integer) **(required)**
  - `beat` (integer)

#### `logic_set_cycle_range`

Set the cycle (loop) locators to a whole-bar range, e.g. bars 5-9. Anchors the ruler's grid-snapped cycle region to a bar line via the playhead thumb, moves the region start by writing its AXPosition, adjusts the length by dragging its right edge (hit-test guarded), verifies via the region's bar-denominated size description, and restores the playhead. The target range must be visible in the ruler. Optionally turns cycle on/off afterwards via 'enabled'.

Parameters:

  - `enabled` (boolean): When given, turn cycle mode on or off after setting the range.
  - `end_bar` (integer) **(required)**: Bar where the cycle ends (exclusive right locator, as shown in Logic).
  - `start_bar` (integer) **(required)**: 1-based bar where the cycle starts.

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

#### `logic_survey_plugins`

Inventory every insert on a track: open each plugin window, list its accessible parameters (name, raw range, writability), classify the exposure, and close windows that were opened. Takes a few seconds per insert. Use to map which plugins are controllable through this MCP. **Strips without a track header** (`Stereo Out`, aux, bus) work only while an inspector is SHOWING that strip (select a track routed to it, or open the Mixer); otherwise use the `logic_mcu_*` tools, which reach every strip.

Parameters:

  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_add_plugin`

Add a plugin to a track's first empty insert slot — mouse-free via the Mackie Control plugin browser (vpot-stepped, LCD-verified, vpot-press instantiates). Works for every plugin in Logic's browser including third-party. If the MCU bridge is down, the AX chooser fallback requires allow_mouse: true because it briefly takes over the pointer. **Strips without a track header** (`Stereo Out`, `Master`, aux and bus channels) are accepted: they resolve on the control surface (LCD name + SELECT LED verified before any write). Use the Mixer name, not the 6-character LCD abbreviation.

Parameters:

  - `format` (string): Channel format submenu item when offered, default 'Stereo'.
  - `plugin_name` (string) **(required)**: Menu title of the plugin, e.g. 'Gain', 'Channel EQ', 'Decapitator'.
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_remove_plugin`

Remove a plugin from a track — mouse-free via the Mackie Control plugin browser's No Plug-in entry (can take up to ~60 s of vpot stepping; verified via LCD and an AX cross-check on the named track). If the MCU bridge is down, the AX chooser fallback requires allow_mouse: true because it briefly takes over the pointer. **Strips without a track header** (`Stereo Out`, `Master`, aux and bus channels) are accepted: they resolve on the control surface (LCD name + SELECT LED verified before any write). Use the Mixer name, not the 6-character LCD abbreviation.

Parameters:

  - `insert_index` (integer)
  - `plugin_name` (string) **(required)**
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_set_track_mute`

Mute or unmute a track via its inspector channel strip mute button, verified by readback. Selects the track first. **Strips without a track header** (`Stereo Out`, `Master`, aux and bus channels) are accepted: they resolve on the control surface (LCD name + SELECT LED verified before any write). Use the Mixer name, not the 6-character LCD abbreviation.

Parameters:

  - `enabled` (boolean) **(required)**
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_set_track_solo`

Solo or unsolo a track via its inspector channel strip solo button, verified by readback. Selects the track first. **Strips without a track header** (`Stereo Out`, `Master`, aux and bus channels) are accepted: they resolve on the control surface (LCD name + SELECT LED verified before any write). Use the Mixer name, not the 6-character LCD abbreviation.

Parameters:

  - `enabled` (boolean) **(required)**
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_set_track_volume`

Set a track's volume fader to a target dB value (e.g. -14.2, 0.0) by converging the inspector strip fader against its dB readout. Reports before/after dB. Fader steps are about 0.1-0.3 dB apart; default tolerance 0.15 dB. **Strips without a track header** (`Stereo Out`, `Master`, aux and bus channels) are accepted: they resolve on the control surface (LCD name + SELECT LED verified before any write). Use the Mixer name, not the 6-character LCD abbreviation.

Parameters:

  - `db` (number) **(required)**
  - `tolerance_db` (number)
  - `track_name` (string) **(required)**
  - `track_number` (integer)

#### `logic_set_track_pan`

Set a track's pan/balance knob position (integer, typically -64..63 where 0 is center) via the inspector strip, verified by readback. **Strips without a track header** (`Stereo Out`, `Master`, aux and bus channels) are accepted: they resolve on the control surface (LCD name + SELECT LED verified before any write). Use the Mixer name, not the 6-character LCD abbreviation.

Parameters:

  - `position` (integer) **(required)**
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

