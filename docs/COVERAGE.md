# Producer coverage audit

**What this is.** A black-box usability test of Logician's tool surface. Seven producers were put in front of a session and asked what they want to do, in their own words. Only afterwards were those wants graded against the 57 tools that exist. The goal being measured is *heltäckande* — comprehensive: when the models get good enough, nothing a producer does in Logic should be out of the agent's reach.

**Method, and why it is in this order.** Each persona's intent stream was written **before** reading `ToolRegistry.swift`, so the wants are not shaped by the tools that happen to exist. The registry, the handlers, [AGENT-GUIDE.md](AGENT-GUIDE.md), [ARCHITECTURE.md](ARCHITECTURE.md), [ROADMAP.md](ROADMAP.md) and [FINDINGS.md](FINDINGS.md) were then read as the **grading key**. That order matters for the two findings this audit cares most about: intents with *no expression at all* in the tool surface, and intents whose expression exists but which an agent could not plausibly **discover or compose** — the naming, glue and choreography failures collected in [Composability](#composability-where-the-capability-exists-and-the-agent-still-misses-it).

**Scope.** Interaction capability only. This server's job is to be a complete, verified control surface so that an analyzing model *can* work in Logic — not to analyze on the model's behalf. Loudness metering, spectral analysis and audio comparison are therefore deliberately absent from this document, including from the gap table.

**Honesty.** Run 2026-08-28. **Logic Pro was never touched.** Statements about *this codebase* are read off the code and can be checked line by line. Statements about *Logic's* behaviour that FINDINGS has not already observed are inferences and are written as "to be verified". Every proposed mechanism names the existing tool that already proves the pattern; that is the difference between a plan and a wish.

**Classes.**

| Class | Meaning |
|---|---|
| **A** | Reachable with mechanisms this repo already runs — an MCU view, a learnable key command, an AX pattern proven somewhere else. Wiring and verification, not discovery. |
| **B** | Needs a research session against Logic first: the AX or MCU grammar is unknown. Each B row names the experiment. |
| **C** | Likely impossible by design — no control-surface or Accessibility semantics exist. The row says why, and names the honest workaround. |
| **D** | Out of scope: the only known route is a pointer drag or UI scripting, which this project does not do. |

Items already on [ROADMAP.md](ROADMAP.md) — the Smart Tempo mode read, tempo curves, automation on headerless strips, the meter map, localization, track-stack freeze — are referenced where a persona hits them and are **not** re-proposed as discoveries. Two rows are deliberately roadmap-*adjacent*: they propose a different route to a hole the roadmap has already named as open (G48, G52).

---

## The surface as it stands

Read as a toolkit rather than a list, the 57 tools cover: **deep, universal control of what is already in the project** (any parameter of any plugin including third-party, and of the instrument slot, written through the MCU with the LCD echo as proof; volume, pan, mute, solo, sends; plugin add/remove; preset browsing; the master chain and buses by name) · **composition and automation as performances** (MIDI notes, CC and pitch bend streamed into a real recording; automation ridden in Latch and verified by playhead chase) · **trustworthy audio out** (dialog-free freeze renders, offline bounces, bar slicing integrated over a real tempo map, A/B evaluation carrying both versions) · **structure at the coarse grain** (track create/rename/duplicate/delete, stacks, region select/move/copy/delete, project lifecycle with a duplicate-to-sandbox habit).

What the seven sessions below expose is not shallow depth but **narrow breadth of verbs**, and the pattern is consistent: *the project's mechanisms already reach further than its tools do.* The sharpest single instance is key-command learning. `setupKeyCommands` in `Sources/Logician/AXKeyCommandLearning.swift` takes an arbitrary `(search, name, preferredNote)` triple and learns it against Logic's ~1400-row Key Commands window. The only thing standing between an agent and every command in that window is the `enum` on `logic_setup_key_commands`'s `commands` argument, generated from the 22 entries in `KeyCommandRegistry.standardCommands`. That is **G00**, and it is the highest-leverage row in this document.

---

## Seven sessions

Each session is in two halves: **what the producer says**, written blind, and **how the surface answers**, written after reading the registry. Verdicts: **●** covered · **◐** partial, with the caveat named · **○** no expression in the surface · **✕** blocks the session.

### (a) Beatmaker — from nothing to a sketch

> "Fresh project, 92 BPM, F minor." · "Give me a drum kit — something dusty." · "Kick on 1 and 3, snare on 2 and 4, hats in sixteenths, swing them a bit." · "Now a sub bass under it." · "The hats are too stiff — quantize them 16ths but leave some feel." · "Loop that four-bar thing out to 32." · "Chords over the second half." · "Mark where the drop is." · "Filter sweep on the pad going into the drop." · "Mute the hats in the intro." · "Bounce me a rough for the car."

| Intent | Verdict | Route today | Gap |
|---|---|---|---|
| Fresh project, tempo, key | ◐ | `logic_new_project`, `logic_set_tempo` (whole BPM). Key signature is readable, not writable | G50 |
| "Give me a drum kit" | ✕ | Track creation works; **nothing loads an instrument**. `logic_add_plugin` fills the first empty *insert*; the instrument slot is the MCU `IN` view | **G16** |
| Program the beat | ● | `logic_record_midi` with notes, velocities, `beat: 1.5` for offbeats | — |
| "Swing them a bit" / "quantize but leave feel" | ○ | No quantize, no groove template, no humanize. The surface's answer is "record it right the first time" | G17 |
| Check what actually landed | ○ | The agent can write MIDI it cannot read back; its only evidence is a render's level | G04 |
| "Loop that out to 32" | ◐ | `logic_copy_region` per copy — seven calls for one intent. No region loop flag, no repeat-N | G27 |
| "Mark where the drop is" | ○ | No marker tool — although `Create Marker` is already a learned standard command with nothing behind it | **G46** |
| Filter sweep into the drop | ● | `logic_record_automation` on a plugin parameter, or CC in `logic_record_midi` | — |
| "Mute the hats in the intro" | ◐ | Track mute is global; region mute and muting *a range* are not exposed | G06 |
| Rough bounce | ● | `logic_bounce_range`, audio attached | — |

### (b) Mix engineer — 30 tracks arrive from someone else

> "What have I got here?" · "Everything's slamming — pull it all back and give me headroom." · "Group the drums to a bus." · "Set up a plate and a slap delay." · "Snare into the plate, about −12." · "The bass and the kick are fighting — sidechain the bass." · "Bypass that EQ, let me hear what it's doing." · "What's already automated in here? I don't want to wipe someone's work." · "Ride the vocal up in the chorus." · "Drums on one fader." · "How does it stack up against the reference?" · "Print me a mix."

| Intent | Verdict | Route today | Gap |
|---|---|---|---|
| "What have I got here?" | ✕ | `logic_list_tracks` returns only the headers Logic has **rendered** — FINDINGS records 13 of 27 on the reference project. A 30-track session is half-invisible, and the result looks complete | **G01** |
| Read the balance in one pass | ✕ | One call per track per property. Faders, lit LEDs and vpot rings for eight strips at a time are *already mirrored* in the bridge snapshot and nothing decodes them | **G02** |
| Know what each track is | ○ | No type, icon, colour, input, output or group membership | G03 |
| "Pull it all back" | ◐ | Per-track `logic_set_track_volume`; no relative move across a selection | G43 |
| "Group the drums to a bus" | ◐ | `logic_add_send` reaches a bus; changing a track's **output** to one, and creating/naming the aux, are not there | G38 |
| Plate and slap, snare at −12 | ◐ | `logic_add_send` then `logic_mcu_set_send` — two calls, because new sends start at −∞ | U5 |
| Sidechain the bass | ○ | The plugin's sidechain source pop-up is unreachable | G40 |
| "Bypass that EQ" | ✕ | `logic_list_inserts` **reads** the bypass checkbox; no tool writes it. The nearest substitute is a ~15 s `logic_evaluate_change` | **G36** |
| "What's already automated?" | ✕ | Automation is write-only. `logic_record_automation` is correctly declared *destructive* because a Latch pass overwrites the range — and the agent cannot see what it is about to overwrite | **G05** |
| Ride the vocal | ● | `logic_record_automation` with points and ramps — a genuine strength | — |
| "Drums on one fader" | ○ | No groups, no VCA | G39 |
| Against the reference | ○ | Getting a reference file into the project is not possible | G34 |
| Print the mix | ● | `logic_bounce_range` | — |

### (c) Vocal producer — a singer in the booth

> "New vocal track, mic on input 2, let her hear herself." · "Arm it, we're rolling." · "Three passes on the chorus." · "Take the first half of two and the back half of three." · "It's flat on the long note." · "Double the last line." · "Throw a delay on the last word of the verse." · "De-ess it." · "Print the vocal so the mixer gets one file."

| Intent | Verdict | Route today | Gap |
|---|---|---|---|
| New track, input 2, monitoring | ◐ | Track creation ●; input assignment and monitoring ○ | G11 |
| **"Arm it, we're rolling"** | ✕ | **Nothing arms a track for recording.** The session ends at intent two. MCU rec/ready buttons and their LED echoes are a protocol the bridge already speaks in both directions | **G10** |
| Three passes / cycle record | ○ | No record mode, no punch | G12 |
| "First half of two, back half of three" | ✕ | Take folders are invisible; quick-swipe comping is a pointer drag. Honest workaround: one pass per track, cut with the region tools | G13 |
| "It's flat on the long note" | ◐ | `Pitch Correction` and `Vocal Transformer` as inserts are fully controllable. Flex Pitch note editing is a graphic gesture | G14 |
| Double the last line | ● | `logic_duplicate_track` plus a second pass | — |
| Delay throw on one word | ● | `logic_record_automation` on a send level puts the throw exactly on a beat — one of the strongest things this surface does | — |
| De-ess | ● | Insert plus parameters | — |
| Print the vocal | ● | `logic_render_track` | — |

### (d) Film / game composer — to picture, and stems out

> "Drop the cut in and line up to timecode." · "The hit is at 1:12 — I need a tempo map that lands a downbeat there." · "Bar 40 goes to 5/4." · "Markers at every sync point." · "Write the cue." · "Name the sections so the director can talk to me." · "Stems: drums, strings, brass, perc, FX." · "48k 24-bit, and an MP3 for the email." · "Send the orchestrator a MIDI file."

| Intent | Verdict | Route today | Gap |
|---|---|---|---|
| Picture and timecode | ✕ | No movie import; the playhead is bar-addressed only | G34, G09 |
| **A tempo map that hits the cue** | ✕ | The map is *read* and integrated (roadmap item 3) and `logic_set_tempo` deliberately refuses a project that has one. **Nothing can create a tempo event** — although the Tempo List's own `Create new Tempo Event` button was observed during that research | **G49** |
| "Bar 40 goes to 5/4" | ✕ | All bar math assumes one meter; the roadmap names the Signature List as the follow-up | G48 |
| Markers at sync points | ✕ | — | **G46** |
| Write the cue | ● | `logic_record_midi`, tempo-map aware | — |
| Name the sections | ○ | Arrangement markers are unreachable | G47 |
| **Stems** | ✕ | No multitrack export. `logic_render_track` per track is not the same thing: pre-fader, refused on stacks and shared channel strips, one call each with no shared range contract | **G54** |
| 48k/24-bit and an MP3 | ○ | `logic_bounce_range` forces Uncompressed and restores the user's choice; depth, rate, dither and normalize are never the caller's | **G53** |
| MIDI file out | ○ | — | G55 |

### (e) Sound designer — a patch, then destroy it

> "Load a synth and show me what it can do." · "Walk me through the presets." · "Open the filter up and make it scream." · "Modulate the cutoff with the LFO, slowly." · "Print that — I want to chop it." · "Load the print into a sampler and pitch it down two octaves." · "Reverse it." · "Reverb, then distortion — no wait, distortion first." · "Save this patch so I can get back to it."

| Intent | Verdict | Route today | Gap |
|---|---|---|---|
| "Load a synth" | ✕ | Same wall as the beatmaker: the track exists, the instrument cannot be chosen | **G16** |
| Walk the presets | ● | `logic_plugin_preset` list/select/step, with the honest "a name is not a state" warning | — |
| Open the filter, make it scream | ● | `logic_mcu_set_instrument_parameter` plus a render to hear it | — |
| Modulate slowly | ● | `logic_record_automation` on the parameter | — |
| **"Print that — I want to chop it"** | ✕ | No bounce-in-place. `logic_render_track` writes a file to *disk*, not a region into the *project*, so make-print-mangle is a dead end | **G33** |
| Sampler, pitch down, reverse | ✕ | G16 for the sampler, G34 for the file, and reverse is a region function that is not exposed | G16, G34, G29 |
| Reorder the chain | ○ | Add/remove yes; **reordering inserts** no. Remove-and-re-add loses the plugin's state | G37 |
| Save the patch | ○ | Preset *loading* exists; saving a setting does not | G37 |

### (f) Mastering prep — the last mile

> "Put a limiter and a tape emulation across the master." · "A/B the limiter in and out." · "Automate the master EQ down half a dB in the loud section." · "Give me 24-bit WAV, 16-bit dithered, and an MP3." · "Keep this version so I can come back to it." · "One more with the vocal up a hair."

| Intent | Verdict | Route today | Gap |
|---|---|---|---|
| Master chain plugins | ◐ | Shipped in v0.51.0 and honestly flagged: **every write on a headerless strip is implemented and has never been run** (ROADMAP item 2). Reading is live-verified | (roadmap) |
| A/B the limiter | ◐ | `logic_evaluate_change` method `bounce` reaches it; also never run. A plain bypass A/B would be the natural move and does not exist | G36 |
| Automate the master EQ | ✕ | Roadmap item 2 names it: `setAutomationMode` reads the *track header's* label, which a headerless strip has not got | (roadmap) |
| Three delivery formats | ✕ | One format, chosen by the tool | **G53** |
| "Keep this version" | ◐ | `logic_duplicate_project` is the whole-project answer; Logic's own Alternatives are not reachable | G35 |
| Vocal up a hair, re-print | ● | Fader plus bounce | — |

### (g) Podcast / audio-post editor — volume, at speed

> "Three files: host, guest, room." · "Strip the silence out of all of them." · "Level them so nobody's twice as loud as anyone else." · "Kill the ums." · "Close the gaps." · "Crossfade every edit, this is speech." · "Chapter markers at each topic." · "One pass across everything: select all the guest's clips and drop them 2 dB." · "Export it."

| Intent | Verdict | Route today | Gap |
|---|---|---|---|
| Three files in | ✕ | No audio-file import; the session must arrive pre-assembled | G34 |
| **Strip silence** | ✕ | The opening move of every post session. A threshold dialog — the same species the bounce dialog automation already handles | **G30** |
| Level the clips | ○ | No region gain, no normalize | G29 |
| Kill the ums | ◐ | Split exists only as a raw `logic_trigger_key_command` with a literal command string; delete is a tool. No ranged delete, no ripple | G24 |
| Close the gaps | ○ | No cut-time at the locators | G31 |
| Crossfade every edit | ✕ | Fades are unreachable, and a hard cut in speech is audible | G28 |
| Chapter markers | ✕ | — | **G46** |
| "Select all the guest's clips" | ✕ | `logic_select_region` is deliberately exclusive and single. Every edit is a round trip | **G26** |
| Export | ◐ | Master bounce yes; format choice no | G53 |

---

## Composability: where the capability exists and the agent still misses it

The gap table below counts capabilities. This section counts *usability* — cases where the tool exists and a competent agent would still fail, get lost, or do the wrong thing confidently. These came out of the blind sessions, not out of the code.

**U1 · The most dangerous read in the surface looks like the safest.** `logic_list_tracks` returns `success: true` with a *partial* world: only the track headers Logic has currently rendered. The schema says so, and an agent that skims will still build its whole mental model on it and never learn that fourteen tracks exist. Every other honesty guard in this project is loud (`warning`, `precondition_failed`, `presets: null` plus a reason); this one is a footnote on a successful result. At minimum the result should carry how many rows it *could not* see, if that is knowable; better, G01 should make the complete answer the default one.

**U2 · Two numbering systems share one tool and one word.** `logic_evaluate_change` takes both `insert_index` (Accessibility ordinal) and `insert_slot` (MCU physical slot), they are not the same numbering, and on `Stereo Out` they were observed **reversed** (`Sensor, Limiter, Channel EQ` versus `Channel EQ, Limiter, Sensor`). The guide's rule — "never translate one into the other; list with the tool you are about to use" — is exactly right and is one prose sentence away from a wrong-plugin write. The names are the problem: nothing in `insert_index` says *Accessibility* and nothing in `insert_slot` says *Mackie*.

**U3 · The killer feature is one call; the everyday edit is a choreography.** Splitting a region takes `logic_set_playhead` → `logic_select_region` → `logic_trigger_key_command {name: "Split Regions/Events at Playhead Position"}`, with the literal command string as a magic constant, three independent failure modes, and no combined verification. That recipe lives in the guide's prose, so an agent that has not read that paragraph cannot compose it from the tool list. Contrast `logic_evaluate_change`, which choreographs a dozen steps behind one call. The line between "this deserves a tool" and "the agent can compose it" is currently drawn by which workflows happened to get built, not by how hard they are to compose. Split (G24), send-with-level (U5) and loop-a-region-N-times (G27) are all on the wrong side of it.

**U4 · The registry's contents are invisible.** `logic_trigger_key_command` is the escape hatch to a lot of Logic, and there is no tool that *lists* what the registry holds. An agent must already know a command's exact Logic 12 name — including the ones that surprise, such as `Flashback Capture as Recording`. A `logic_list_key_commands` read would cost almost nothing, and it becomes a prerequisite the day G00 lets an agent add to that registry.

**U5 · Intents that are one thought and two calls.** "Send the snare to the plate at −12" is `logic_add_send` (lands at −∞) then `logic_mcu_set_send`. Between the two, the mix is different from what the user asked for, and an agent that stops after the first call has silently created an inaudible send. An optional `level_db` on `logic_add_send` closes it.

**U6 · A composability cliff that looks like a plateau.** `logic_create_track {type: "software_instrument"}` succeeds, `logic_add_plugin` succeeds, and "add a bass" is still impossible — because `add_plugin` fills an *insert* and the instrument slot is a different mechanism (G16). Both halves report success; the intent fails. This is the single worst discoverability trap found, because nothing in either tool's description hints that the instrument slot is a separate world.

**U7 · "Render" means two different things.** `logic_render_track` renders to *disk*. A producer who says "render that track" usually means bounce-in-place — commit it into the project (G33). The tool is correctly named for what it does; the collision is worth a sentence in its description, because an agent asked to resample will reach for it and get a file it cannot then use.

**U8 · Regions have no stable identity.** They are addressed by `(track_name, region_name, start_bar)`, and `start_bar` is the thing edits change. A two-step edit — move, then trim — has to re-read the arrangement map in between, and duplicate names make verification count *occurrences* rather than identity (the code is careful about this, which is how we know it bites). Any future multi-region work (G26) will need a handle, or every batch becomes a re-read per item.

**U9 · Structural facts are learned by failing.** Choosing between `logic_evaluate_change`'s `render`, `bounce` and `solo_bounce` requires knowing whether the track is a stack subtrack or shares a channel strip. No read tool reports either. The refusal is fast (~2 s) and names the alternative, which is good design — but the agent still discovers the shape of the project by bumping into it. G03 would let it plan instead.

**U10 · The naming is honest about mechanism and quiet about intent.** `logic_evaluate_change` is the flagship and its name does not say *A/B a change and hear both*. `logic_record_midi` and `logic_record_automation` both mean "this takes real wall-clock time proportional to the music" — invisible from the names, disclosed only in the descriptions. And nine mixing/plugin tools say `track_name` while accepting `Stereo Out`, an aux or a bus (guide concept 3b); an agent reading names alone will not try.

---

## Master gap table

Rank is one ordering over the A and B rows by **producer value × feasibility**; C and D rows are unranked by definition. "Verification" is what the tool would read back as proof — no row is proposed without one, because this repo does not ship an unverified write.

| # | Gap | Session / intent it blocks | Class | Proposed tool / mechanism | Verification story | Rank |
|---|---|---|---|---|---|---|
| G00 | Only the 22 `standardCommands` can be learned; arbitrary Logic commands cannot | every session (split, takes, flex, normalize, select-all, move track, …) | **A** | `logic_learn_key_command {search, name}` — `setupKeyCommands` already takes an arbitrary triple; lift the schema `enum`, keep the registry as the consent record | The existing one: the Key Commands row's assignment display changes, and the registry records who bound it. Firing stays gated by `logic_trigger_key_command`'s registry check | **1** |
| G01 | No census of tracks/strips; only *rendered* headers are visible | (b) "what have I got here?" | **A** | `logic_list_strips` — surface the four-bank scan `resolveChannel` already runs and caches in `bank-cache.json` | Bank tops read off the LCD, de-duplicated by the clamp rule already unit-tested; cross-checked against `logic_list_tracks` where they overlap | **2** |
| G02 | No one-call mixer snapshot (fader dB, mute, solo, rec, pan per strip) | (b) read the balance | **A** | `logic_mixer_snapshot` — decode `faders14bit`, `ledsLit` (mute 0x10–0x17, solo 0x08–0x0F, rec 0x00–0x07) and `vpotRings` per bank | The mirror *is* Logic's echo; dB via the CS-view readout `logic_set_track_volume` already converges against | **2** |
| G03 | No track metadata: type, icon, colour, input, output, group | (b), U9 planning | **B** | Probe the track header's and inspector strip's children for these fields | Whatever publishes a value; report `null` rather than guess | 17 |
| G04 | An existing MIDI region's notes cannot be read | (a) "did that land?" | **A** | `logic_list_events` — the **Event** tab of the same List Editors panel `readTempoMap()` already drives (`AXRadioGroup`: Event / Marker / Tempo / Signature) | The tab's own `Number of Items` cross-check, exactly as the tempo read does; restore the tab and close the pane | **3** |
| G05 | Existing automation cannot be read | (b) "don't wipe someone's work" | **A** | `logic_read_automation {track, parameter, bars}` — park in Read and sample the echo per bar: `recordAutomation`'s verification pass with the write removed | Playhead-chase readings are Logic's own values; report the bars sampled, never an interpolation | **6** |
| G06 | Region detail stops at name/bars/type (no mute, loop, gain, fades, take status) | (a) mute a range, (g) | **B** | Probe a region `AXLayoutItem`'s other attributes and the Region inspector panel | Read-back of whichever fields prove writable | 12 |
| G07 | Undo history is opaque; `Undo` is documented as unsafe unless fired immediately | all destructive work | **B** | Enumerate Logic's Undo History window rows via AX — the same table pattern as the Tempo List | The row list itself: an undo target named rather than blind | 14 |
| G08 | The `.logicx` package is never inspected (alternatives, backups, unused media, sample rate) | (f) versioning, (b) triage | **A** | `logic_inspect_project` — a pure filesystem read of the bundle, as FINDINGS did by hand | File listing plus `ProjectData` mtime; no Logic interaction at all | 16 |
| G09 | No scroll, zoom or track show/hide for the agent's own orientation; playhead is bar-only | (b), (d) | **A** | Learned key commands (zoom to fit, show/hide all tracks) via G00 | `logic_list_tracks` sees more rows afterwards — the gap is its own proof | 11 |
| G10 | **No record-arm** | (c) intent two, and the whole session | **A** | `logic_set_track_record_arm` — MCU notes 0x00–0x07 (to be verified as Logic's rec/ready buttons) | The same note's LED echo in `ledsLit`, plus the track header's own arm checkbox as an independent AX cross-check | **4** |
| G11 | No input assignment or input monitoring | (c) | **B** | The strip's input slot is an AX element (insert enumeration already tells slots apart by their buttons); a pop-up press is the pattern `logic_plugin_preset` proved | The slot's displayed name after the press | 15 |
| G12 | No punch, cycle-record or take-recording mode | (c) | **B** | Recording modes live in project settings and the control bar | Read-back of whatever control carries the mode | 21 |
| G13 | Take folders: no list, no take switching, no comping | (c) "first half of two" | **C** (take switching **A** via G00; quick-swipe **D**) | `Select Next/Previous Take` as learned commands gives switching. Building a comp from swipes is a pointer gesture | For switching: the region name changes in `logic_list_regions`. Workaround: one take per track, cut with the region tools | — |
| G14 | Flex Time / Flex Pitch | (c) "it's flat", (b) timing | **C** (enabling flex **A**; graphic editing **D**) | Enable Flex / set a flex mode via learned commands; per-note dragging has no non-pointer route | Track header state for the enable. Workaround for tuning: `Pitch Correction` as an insert, fully controllable today | — |
| G15 | Metronome and count-in are readable, not writable | (a), (c) | **A** | The MCU `click` button (0x59) is already in `buttonNames` and never pressed by the server | `logic_get_transport` already reports `metronome` — read it back | 10 |
| G16 | **No instrument loading** into the instrument slot | (a) and (e), both at "pick a sound" | **A** | `logic_load_instrument` — vpot-browse in the `IN` bank view, which `MCUInstrument.swift:11` identifies as the instrument browser, reusing `MCUPluginBrowser`'s settle/reverify/wrap logic | The LCD name in the instrument slot, then `logic_mcu_instrument_parameters` as an independent second read | **5** |
| G17 | No quantize, transpose, velocity or note editing of recorded MIDI | (a) "leave some feel" | **B** (region-level quantize likely **A** via G00) | `logic_set_region_parameters` against the Region inspector (Quantize, Transpose, Velocity, Delay, Loop) — the same inspector plane the channel strip already uses | Read-back of the inspector fields; a render for the audible half | 8 |
| G18 | No event-level MIDI writes | (a) surgical fixes | **B** | The Event List's cells (the G04 route) — are they settable? | Re-read the row after the write | 19 |
| G19 | MIDI FX slot (Arpeggiator, Chord Trigger, Modifier) unreachable | (a), (e) | **B** | Is there an MCU view for MIDI FX, or only the strip's AX slot? | Slot name read-back; parameters would then ride the existing parameter tools | 18 |
| G20 | Articulation sets / articulation IDs | (d) orchestral | **C** | A dedicated editor with no control-surface vocabulary | Workaround: keyswitch notes through `logic_record_midi`, which works today | — |
| G21 | Drummer / Session Player regions | (a) | **B** (create) / **D** (the XY pad) | Creating the track is a menu item; editing the performance is a pointer gesture | Track count for the create. Workaround: `logic_record_midi` writes the same notes by hand | — |
| G22 | Live Loops (cells, scenes, grid) | (a) | **C** | A parallel non-linear surface with no MCU grammar recorded anywhere | Workaround: work in the linear arrangement | — |
| G23 | Smart Controls | (a), (e) | **B** | The Smart Controls pane is AX-visible (FINDINGS saw it while probing for tempo modes) | Parameter read-back. Low value while every underlying parameter is already reachable | 20 |
| G24 | Split has no tool — only a raw key-command fire (U3) | (g) "kill the ums" | **A** | `logic_split_region {track, at_bar}` wrapping playhead + exclusive select + the learned command | The arrangement map shows two regions where one was — the region tools' existing proof | 9 |
| G25 | Region rename | (g), (a) | **B** | Region inspector name field, or the rename dialog | The name in `logic_list_regions` | 17 |
| G26 | Only one region can be selected at a time | (g) "all the guest's clips" | **A** | `Select All Following` / `Select All in Track` as learned commands (G00), plus a selection-count read | `selectedRegionCount()` already exists and is what `logic_delete_region` guards on | **7** |
| G27 | No region loop, trim or length change | (a) "loop it out to 32", (g) | **B** | Region inspector (loop flag, length) | Inspector read-back plus the arrangement map's end bar | 12 |
| G28 | No fades or crossfades | (g) speech edits | **B** | Region inspector fade fields (the Fade *tool* is a pointer gesture and is not the route) | Inspector read-back; a render to hear the join | 13 |
| G29 | No region gain, normalize or reverse | (g) levelling, (e) | **B** | `Functions > Normalize Region Gain` and friends; the audio region's gain field | Gain field read-back; the arrangement map for destructive functions | 13 |
| G30 | Strip silence | (g), the first thing every post session does | **B** | `Edit > Strip Silence` is a threshold dialog — the same species as the bounce dialog, whose automation is proven | Region count and the arrangement map before/after | 8 |
| G31 | Cut/insert time at the locators | (g) "close the gaps" | **A** | Learned key commands (G00) plus the existing cycle-range tool | Every later region's start bar shifts by exactly the expected amount in the arrangement map | 15 |
| G32 | Tracks cannot be reordered | (b) session hygiene | **A** | Learned move-track commands (G00) | Track numbers in `logic_list_tracks` | 16 |
| G33 | **No bounce/freeze in place** | (e) "print that — I want to chop it" | **A**/**B** | `File > Bounce > Track in Place` via `pressMenuItem(containing:underMenu:)`, which `logic_bounce_range` already uses on that same menu; the dialog's controls need one look | A new audio region in the arrangement map, plus its render metrics | **9** |
| G34 | No import: audio files, movie, or content from another project | (b) reference, (e), (g) three files | **B** (`File > Import Audio File` dialog) / **D** (browser drag) | The import dialog is an AX file panel like the bounce save panel | A new region in the arrangement map. Cross-project import stays out of reach under single-project mode | 14 |
| G35 | Project alternatives and backups | (f) "keep this version" | **A** | `File > Alternatives` menu items on the proven menu path | The window title / document path changes; `logic_inspect_project` (G08) lists them | 18 |
| G36 | **Insert bypass cannot be written** — only read | (b) and (f), the fastest honest A/B in mixing | **A** | `logic_set_insert_bypass` — `logic_list_inserts` already enumerates each insert's `AXCheckBox desc='bypass'` child | The same checkbox read back; the MCU insert list as a second source | **3** |
| G37 | No insert reordering, no channel-strip setting copy/paste or save | (e) "distortion first", "save this patch" | **B** | Copy/Paste Channel Strip Setting exist as key commands (G00); reordering may need the Mixer's own affordances | `logic_mcu_plugin_inserts` before and after | 17 |
| G38 | No output routing, bus creation or naming, no I/O labels | (b) "group the drums to a bus" | **B** | Is the output slot reachable on the MCU (a track-view page), or only as an AX pop-up on the strip? | The slot's displayed destination; the send tools' destination grammar is the model | 11 |
| G39 | No groups or VCA | (b) "drums on one fader" | **B** | The strip's Group slot and the Group Settings window; MCU `group` (0x4F) is mapped and never pressed | Group membership read back off the strip | 19 |
| G40 | No sidechain source selection | (b) "sidechain the bass" | **B** | The sidechain pop-up in the plugin window header — the same header the setting menu was solved in (v0.52.0) | The pop-up's label, as `pluginPresetLabel` now reads correctly | 13 |
| G41 | Automation on headerless strips (master, buses) | (f) "automate the master EQ" | **B** | *Roadmap item 2, already named*: `setAutomationMode` reads the track header's label | — | (roadmap) |
| G42 | Automation mode is internal-only; no delete-automation | (b) | **A** | Expose `setAutomationMode` as a tool; `Delete Automation of Selected Track` via G00 | The strip's automation label, already read for verification today | 12 |
| G43 | No relative or multi-track gain move ("everything back 2 dB") | (b), (g) | **A** | A composition over `logic_set_track_volume` with a read-first-per-track loop | Each fader's own dB read-back | 20 |
| G44 | Surround / Dolby Atmos | (f) | **C** | A parallel panner and renderer with no MCU vocabulary and a large bespoke UI | Honest answer: out of reach; deliver stereo | — |
| G45 | Plugin latency, PDC, low-latency mode | (c) tracking through a heavy chain | **C** | Latency figures are shown in plugin headers and the Mixer, unlikely to be semantically addressable | Workaround: renders are offline, so latency does not affect the deliverable | — |
| G46 | **No markers at all** | (a) "mark the drop", (d) sync points, (g) chapters | **A** | `logic_markers {action: list \| create \| goto \| rename \| delete}` — `Create Marker` is already a learned standard command with no tool behind it, and the **Marker** tab is the same List Editors table the tempo read walks (`Navigate > Open Marker List` exists too) | Read the marker list back; the row is the proof | **6** |
| G47 | Arrangement markers (song sections) | (d) "name the sections" | **B** | A global track; are its markers AX-visible the way regions are? | The arrangement map, if they surface as layout items | 16 |
| G48 | Meter map: signature changes are not read; all bar math assumes one meter | (d) "bar 40 goes to 5/4" | **A** | *Roadmap-adjacent*: the roadmap names the Signature List as the follow-up, and the route is identical to `readTempoMap()` — one tab over in a panel the code already opens, restores and closes | The tempo read's discipline: row grammar plus the `Number of Items` cross-check; a bounced bar range as the independent check | **7** |
| G49 | Tempo events cannot be created or edited | (d) "land a downbeat on the hit" | **B** | The Tempo List's `Create new Tempo Event` button and its editable rows were both observed during the tempo research; writing to them has not been tried | Re-read the map with `readTempoMap()` and compare event counts and positions | 10 |
| G50 | Key signature is readable, not writable | (a) "F minor" | **B** | The control bar's Key Signature pop-up publishes its value (unlike the Project Tempo pop-up) | Its own `AXValue` | 21 |
| G51 | Varispeed | (e) | **B** | A control-bar element that may be hidden by default | Its displayed value | 22 |
| G52 | Smart Tempo mode still unreadable | (a), (c) — the `logic_record_midi` guard degrades to a warning | **B** | *Roadmap-adjacent, different route*: item 1 proposes opening the control-bar pop-up and reading `AXMenuItemMarkChar`. **`File > Project Settings > Smart Tempo…` is a real dialog** with (to be verified) a labelled control that publishes its value — a read that mutates no menu on a recording's arming path | The dialog's own control value, then cancel. Would upgrade the guard from a warning to a guarantee | 13 |
| G53 | **Bounce format is not the caller's choice** — Uncompressed only; no bit depth, sample rate, dither, normalize or tail | (d) and (f) delivery, (g) export | **A** | Extend `logic_bounce_range`: `destinationRows(in:)` already enumerates and toggles the destination checkboxes, and the rest of the dialog is the same AX surface (settings are already known to persist between invocations) | The dialog's own control states before Bounce is pressed, plus the produced file's format read off disk | **8** |
| G54 | **No stem / multitrack export** | (d) — the composer's actual deliverable | **A**/**B** | `File > Export > All Tracks as Audio Files` (a dialog on the proven menu path), or a stem loop over `logic_render_track` under one shared bar contract | File listing plus each file's own render verification; the shared range is what makes them stems rather than renders | **5** |
| G55 | No MIDI file export | (d) | **A** | `File > Export > Selection as MIDI File` — menu plus save panel, both proven paths | The written file's existence and size | 15 |
| G56 | Logic's own per-channel meter state is received and discarded | (b) gain staging, (c) input levels | **A** | `Bridge.swift` drops it: case `0xD0` advances the index and keeps nothing (case `0xA0` is commented "used for meters — ignore payload"). Mirror it into the snapshot as per-channel level plus the overload flag, exactly as fader and LED echoes are mirrored — a **state read** of what Logic publishes, not analysis | The meter *is* Logic's own feedback, the same class of evidence as a fader echo. Report it as Logic's value, never as a measurement of the audio | 10 |
| G57 | No window/screenset control | (f), and it gates other gaps | **A** | `Window > Open Mixer` and friends on the proven menu path; MCU F-keys may map to screensets (to be verified) | `logic_list_windows` already reports what is open. Worth more than it looks: an open Mixer is what makes `Master` and `Aux 1` reachable to the AX-only tools, a limitation the guide currently only documents | 11 |
| U1–U10 | Composability and naming failures (above) | all sessions | **A** | Schema/description edits, one `logic_list_key_commands` read, an optional `level_db` on `logic_add_send`, a `logic_split_region` wrapper | Each is verifiable by the tool it belongs to; none needs new Logic knowledge | 4–9 (with their gaps) |

**Counts.** 58 classified rows, by primary class: **A 24** · **A-or-B 2** · **B 26** · **C 6**. No row is purely **D** — D appears only as the closed half of a split row (quick-swipe comping, Flex Pitch dragging, the Drummer XY pad, browser drag-and-drop), each of which has a non-pointer half that is A or B. Six rows are split by sub-capability (G13, G14, G17, G21, G34, and G33's dialog half); one row (G41) is carried on the roadmap and counted in B for completeness. The headline is the ratio: **roughly half of everything missing needs no new Logic research at all** — it needs wiring to mechanisms this repo already runs.

---

## Top 10, and why

> **Status (2026-08-28, v0.54.0):** all ten items shipped in some form the same day this audit landed — 18 new tools, 57 → 75. Live-verified: `logic_learn_key_command`/`logic_list_key_commands`, `logic_list_strips`/`logic_mixer_snapshot`, `logic_list_events`, record-arm (`logic_set_track_record_arm`), the `logic_load_instrument` mechanism, `logic_read_automation`, `logic_markers`, `logic_select_regions`, `logic_list_signatures` + the meter map in the bar math, `logic_split_region` (dialog-aware), and the metronome. Shipped but not yet run live: `logic_set_insert_bypass`'s write, `logic_set_mixer`, the bounce delivery-option writes, `logic_bounce_in_place`'s OK, `logic_remove_silence` end-to-end, `logic_export_stems`. Composability: U1/U2/U5–U10 fixed, U3/U4 covered by the key-command tools. Details per item in FINDINGS (2026-08-28) and the tool reference.

**1 · `logic_learn_key_command` (G00).** Every "just learn the key command" answer in this document is blocked on one `enum` in one schema. The machinery is generic and already hardened — collision retries, panel-re-render traps, symbolic-note verification — and it already writes a consent record that gates firing. Lifting the restriction converts a dozen B-class guesses into A-class wiring: split, take switching, select-all-following, move track, cut/insert time, delete automation, normalize, new Drummer track. It is also the cheapest row here. The design question to answer first is consent, since learning writes into the user's own key-command set: the tool should say what it is about to bind, and the registry should keep saying who bound it. Pair it with `logic_list_key_commands` (U4), or the agent gains a power it cannot see.

**2 · `logic_list_strips` + `logic_mixer_snapshot` (G01, G02).** A mix engineer cannot mix a session they cannot see, and today the agent sees only the headers Logic happens to have rendered — 13 of 27 on the reference project, reported as a success. Both tools are mostly *decoding over data the bridge already holds*: the bank scan runs and caches its map, and the snapshot already carries faders, lit LED note numbers and vpot rings. This is the largest jump in "the agent knows what it is looking at" per line of new code, and it makes every later per-track call cheaper because the agent stops guessing at names.

**3 · `logic_set_insert_bypass` (G36) and `logic_list_events` (G04).** Two small tools closing two embarrassing asymmetries. Bypass state is already *read* by `logic_list_inserts` and cannot be *written* — even though bypass-and-listen is the fastest honest A/B in mixing and would cost a fraction of `logic_evaluate_change`'s fifteen seconds. And MIDI is write-only: `logic_record_midi` composes into a project whose existing notes the agent cannot read. The Event List sits on the exact panel, radio group and table grammar that `readTempoMap()` already opens, reads and restores.

**4 · Record-arm (G10).** Persona (c) ends at its second intent. Nothing arms a track, so an agent cannot record a singer, a guitar, or anything else with a human on the other end — the one workflow where the agent is an assistant rather than the operator. The MCU rec/ready buttons and their LED echoes are a protocol the bridge already speaks in both directions, and the track header carries an arm checkbox for an independent cross-check.

**5 · `logic_load_instrument` (G16) and stem export (G54).** Two ends of the pipeline, both open. An agent can create a software-instrument track and cannot choose the instrument on it: the beatmaker and the sound designer are both stopped at "pick a sound", and both halves of the attempt report success (U6). The browser is the `IN`-view vpot that `MCUInstrument.swift` already documents as off-limits precisely *because* it is the browser. At the other end, the composer's deliverable is stems, and per-track freeze renders are not stems — pre-fader, refused on stacks, and with no shared range contract.

**6 · `logic_read_automation` (G05) and `logic_markers` (G46).** Automation is the other write-only capability: an agent handed a mixed session cannot see a single existing ride, which makes every automation write a potential overwrite — `logic_record_automation` is correctly declared `destructive` for exactly that reason. The read mechanism already lives inside that tool's own verification pass. Markers are the cheapest orientation win in Logic — sections, cues, chapters, three of the seven sessions — and `Create Marker` has been sitting in the learned command set with nothing behind it since the key-command work landed.

**7 · Multi-region selection (G26) and the meter map (G48).** Post editing is a volume game, and one-region-at-a-time turns a two-hour podcast into a thousand round trips; the selection-count primitive that would make it safe already exists as `selectedRegionCount()`. The meter map is the last assumption left in the bar math and the roadmap already names the route; it is here because from a producer's seat "the bridge is in 5/4" is not an edge case.

**8 · Bounce delivery options (G53) and strip silence (G30).** `logic_bounce_range` forces Uncompressed and politely restores the user's setting — good manners, wrong ceiling. The dialog's destination rows are *already enumerated and toggled* by the current code, so format, depth, dither and normalize are an extension rather than an invention, and they are what turns a render into a deliverable. Strip silence is the same species of dialog and is the first thing every audio-post session does.

**9 · Bounce in place (G33) and split (G24).** Resampling is a whole school of production and needs exactly one verb: print this back into the project. `logic_render_track` writes to disk, not to the timeline, so make-print-mangle is a dead end and the tool's name invites the mistake (U7). Split deserves a tool rather than a three-call recipe documented in prose (U3) — three independent failure modes and a magic command string is not something an agent should have to compose from the tool list.

**10 · The composability pass (U1–U10), plus metronome (G15) and window control (G57).** The cheapest quality-per-hour on this list, and none of it needs Logic research: make the partial track list say it is partial, rename the two insert numberings so they cannot be confused, add `level_db` to `logic_add_send`, expose the key-command registry, and say in `logic_create_track`'s description that the instrument slot is a separate mechanism. Alongside them, the `click` button is already mapped in `buttonNames` and never pressed, and opening the Mixer is a menu press that would lift a limitation the guide currently only documents — `Master` and `Aux 1` are unreachable to the AX-only tools purely because no inspector is showing them.

*Just below the line:* the Region inspector experiment. If it reads and writes like the channel-strip inspector, one research session delivers quantize, transpose, loop, gain and fades at once (G17, G27, G28, G29) — the highest-payoff single experiment in this document, and it sits below the line only because it is a B and everything above it is an A.

---

## What this audit could not assess from documents alone

Each of these is a claim above that rests on inference rather than observation. The next audit, or the next research session, should treat them as open.

1. **Whether the MCU rec/ready buttons are notes 0x00–0x07 in Logic's implementation** (G10), and whether their LEDs echo. Read the LED mirror while a human arms a track, before pressing anything.
2. **Whether Logic actually sends meter data to this virtual surface** (G56). The parser drops it; that it *arrives* is inferred from the protocol and from the code's own comment. The experiment is read-only: log every `0xD0` byte for ten seconds of playback and see whether the nibbles move with the music.
3. **Whether the Event, Marker and Signature tabs of the List Editors panel publish rows the way the Tempo tab does** (G04, G46, G48). The Tempo tab's grammar is verified for exactly one row; the others are assumed identical because they share a panel. The `Number of Items` cross-check exists for precisely this doubt.
4. **Whether vpot turns in the `IN` bank view really open the instrument browser** (G16). `MCUInstrument.swift` says so in a comment written to *avoid* the behaviour, not to use it. That experiment is a write and belongs on a scratch project.
5. **The Region inspector's Accessibility surface** (G06, G17, G25, G27, G28, G29) — the highest-payoff unknown here. Whether it reads and writes like the channel-strip inspector decides the class of six rows at once.
6. **The bounce dialog's full control set** (G53): depth, sample rate, dither, normalize, tail. Only the destination checkbox rows are known, because those are the only ones the current code touches.
7. **Which exact command names exist in Logic 12.3.1's Key Commands window** for everything this document proposes learning. Names drift between versions — FINDINGS already records `Flashback Capture as Recording` rather than the expected `Capture as Recording` — and a wrong search string is a silent `not_found`.
8. **Whether `File > Project Settings > Smart Tempo…` publishes a readable mode** (G52). If it does, roadmap item 1's last open piece closes by a route that mutates no menu on the recording path.
9. **Whether take folders expose anything at all to Accessibility** (G13). This audit assumes not, from the absence of any observation in FINDINGS — an absence of evidence, which is why the row is C and not D.
10. **All Logic-side timings.** Every cost figure here is either copied from FINDINGS or absent. Nothing was measured.
11. **Whether the composability failures are real in practice** (U1–U10). They were derived by reading schemas and descriptions the way an agent would, not by watching an agent fail. The honest test is a fresh model given only `tools/list` and one of the seven intent streams above, with the transcript kept — which is also the cheapest way to find the failures this audit missed.
12. **The persona list itself.** Seven seats is not every seat: live performance, orchestral template management, remixing from stems, and collaborative hand-off were not walked. Live Loops in particular (G22) was assessed from the outside.
