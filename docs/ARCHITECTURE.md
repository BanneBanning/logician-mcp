# Logician — Architecture

How you control a DAW that has no automation API, and how you make that control trustworthy enough to hand to an AI agent. This is the English distillation of the full research log ([FINDINGS.md](FINDINGS.md), Swedish, versioned per discovery).

## Design philosophy

Three rules shaped every mechanism in this codebase:

1. **Data plane over UI.** Logic Pro exposes no scripting API, but it *does* implement Mackie Control — a documented, bidirectional control-surface protocol. A control surface is a first-class citizen: Logic echoes every state change back to it (LCD text, LED states, motorized fader positions). Speak that protocol and you get machine-readable ground truth; scrape the UI and you get pixels and race conditions. UI automation is the last resort, and when used it is always *semantic* (Accessibility elements addressed by role and description) — never coordinates, never synthetic keystrokes into windows, never the user's mouse.

2. **Compare-and-set with readback.** Every write reads the current value first, refuses on mismatch (`precondition_failed`), converges toward the target, then reads Logic's echo back. The reported "after" value *is* Logic's own feedback, not the intention. Failed operations roll back and say so (`restored: true/false`).

3. **Assume the agent is fallible.** Results that produce sound carry the sound (MCP audio content blocks). Silent bounces warn. Leftover solos are named. Every sound-changing write returns a standing instruction to judge by ear, not by parameter value. A blocked step must be reportable as blocked — so error messages name what was observed and what the working alternative is.

## Process model

```
MCP client ── stdio/JSON-RPC ── logician (server process)
                                   │ spawns & health-checks
                                   ▼
                                logician --bridge (daemon, single instance)
                                   │ unix socket: ~/Library/Application Support/LogicMCPMCU/command.sock
                                   │
                                   ├─ virtual CoreMIDI ports (FIXED unique IDs 'LMC0'–'LMC3'):
                                   │    "Logic MCP MCU"       Mackie Control ⇄ Logic
                                   │    "Logic MCP Commands"  key commands → Logic
                                   │    "Logic MCP MIDI In"   performance MIDI → Logic
                                   └─ state mirror: LCD text, LEDs, 14-bit fader echoes,
                                      timecode, event counter (3 ms poll loop)
```

One distributable binary. The MCP server self-spawns the bridge daemon; users never start anything. The bridge holds the virtual MIDI ports and mirrors Logic's control-surface output continuously.

**Socket framing.** One JSON command per connection: the client writes it in full and half-closes (`shutdown(SHUT_WR)`), the bridge reads to EOF, replies, and closes — so "read until the peer is done" is well-defined in both directions and needs no length prefix. Both sides use the same `writeAll`/`readToEOF` implementation, which lives in the shared module precisely so there is one of it. This matters more than it sounds: the original code did a single `write()` and a single `read()` of a 64 KB buffer with the return values discarded, and macOS gives a unix socket an 8 KB receive buffer — so every command past that was silently truncated, parsed as a prefix, and answered "invalid JSON". `logic_record_midi` failed above roughly 130 notes with an error that pointed at nothing.

**One daemon, or none.** The daemon takes an exclusive `flock` before it unlinks and rebinds the socket, and it verifies every `kMIDIPropertyUniqueID` write. Without both, two MCP clients starting at once (which the README invites) each spawned a daemon: the second stole the socket while its endpoints silently kept CoreMIDI's random IDs — the exact orphaning failure the fixed IDs exist to prevent, with everything still looking connected. A bridge that cannot claim its identity now refuses to run. A `bridge_protocol` version in the ping (defined once, in the shared module) lets a newer server detect and replace an outdated daemon.

**Fixed MIDI unique IDs matter more than they look.** CoreMIDI assigns random unique IDs by default, and *two* things bind to port identity, not port name: Logic's control-surface device setup, and — much less obviously — every key-command MIDI assignment. Recreating ports with new IDs silently orphans all of them (they still *display* in Logic's UI but never fire). Fixed IDs (`'LMC0'`–`'LMC3'` as `kMIDIPropertyUniqueID`) make port identity survive restarts; `logic_setup_key_commands {relearn: true}` repairs installations that predate the fix (it wipes each command's stale controller assignments via the Key Commands window before re-learning — repeated repairs never stack duplicates).

## Control plane 1: Mackie Control (the workhorse)

Logic's MCU implementation multiplexes everything through 8 channel strips, a 2×56-character LCD, vpots (rotary encoders), and motorized faders. The bridge mirrors all of it; the server drives it by pressing (virtual) buttons and turning (virtual) encoders, then reading the mirrored echo.

**Views.** The assignment buttons switch the strip into views, each with its own LCD grammar:
- `PN` (pan) — top line shows track names: the neutral home view and the track-bank map.
- `CS` (channel strip) — volume on vpots.
- `PL` — the selected track's insert list (`Ins1Pl`, `Ins2Pl`, …); pressing a vpot enters a plugin's parameter pages.
- `SE` — sends for the selected track, four fields per send (destination, level, position, mute).
- `IN` — instrument parameters.
- Multi-channel plugin views exist (each vpot = one *channel's* insert N) and are dangerous — a write in the wrong view edits eight different tracks' plugins. View state is always verified from the LCD before writing.

**Convergence.** Vpot parameters have no absolute-position protocol — only relative ticks, with per-parameter, per-plugin step sizes. The bridge implements an in-process `converge` command: an adaptive tick-ratio loop that measures value-change per tick from the LCD echo (3 ms polls) and homes in on the target. Volume is the exception: motorized faders echo 14-bit absolute positions, so dB targets go through a calibrated dB→14-bit curve and land exactly.

**Hot views.** Entering a plugin's parameter pages costs over a second (view switch, page search). Consecutive writes to the same plugin keep the view "hot" and skip setup — with the page-cache key carried along, since losing it silently degrades to a per-page linear search. The server exits to the neutral pan view when the client disconnects: a leaked hot plugin view makes Logic auto-open plugin windows on every later track selection.

**Plugin add/remove without a mouse.** Turning a vpot on an *empty* insert slot in `PL` view steps through Logic's plugin list (one entry per two ticks); pressing instantiates. The `--` boundary entry removes. Drift is corrected by settle-and-reverify with back-steps, and a named-track Accessibility cross-check protects against wrong-channel edits. (An Accessibility-driven chooser exists as a fallback but is gated behind `allow_mouse: true`, off by default.)

## Control plane 2: key commands over MIDI

Logic can bind any key command to an incoming MIDI event. Logician maintains a registry (`~/Library/Application Support/LogicMCPMCU/keycmd-registry.json`) of note-number assignments on a dedicated port, learned **through Logic's own Key Commands window** via Accessibility: search the command, select the row, toggle *Learn New Assignment*, send the note, verify the row now shows it. Collisions get alternate notes automatically. Learning is lazy (first tool that needs a missing command learns it, with a one-time disclosure) or batched via `logic_setup_key_commands`.

Hard-won details of that window: deletions re-render the panel and silently invalidate every previously fetched element reference *and* drop the command row's selection (learning then assigns to nothing); some notes display symbolically (e.g. note 109 shows as `F2 (Modifiers ▶︎ Cmd/Alt)` because it maps to a named MCU control), so verification accepts "the row's assignment display changed", not just the literal `Note N`.

This plane carries: Save, Undo/Redo, Cut/Copy/Paste/Delete, nudges, track create/duplicate/delete/rename, Toggle Track Freeze, split, markers, plugin preset stepping.

## Control plane 3: Accessibility (semantic reads, surgical writes)

Used where the surface protocol has no vocabulary — always element-addressed:

- **Track headers** are `AXLayoutArea`s described `Track N "Name"`, with checkboxes (Mute/Solo/Freeze/…) as children. Selection is written via `AXSelectedChildren` with a Has-Focus-button fallback.
- **Regions** are `AXLayoutItem`s whose `AXHelp` string carries their musical position ("Region starts at X bars … and ends at Y bars, MIDI region"). `AXSelected` is writable, but deletion silently no-ops unless `AXFocused` is also set — and with duplicate region names, verification counts name *occurrences*, never absence.
- **The bounce dialog**'s Start/End fields are groups of four `AXSlider`s mirroring one raw tick value (16,492,674,416,640 ticks/bar). Writing a value steps the field *one unit toward it* per write. Crucially, the field **clamps exactly to its minimum**, which erases any sub-bar remainder — a position carrying beats/divisions/fractional ticks can never reach a bar-aligned target by bar-stepping (it oscillates around it forever), so the algorithm is: bar-aligned values step straight to the target; anything else is clamped down to `1 1 1 1` first, then stepped up exactly.
- **Modal dialogs freeze everything** (the MCU mirror included, visible as `ALERT` in the timecode), so every dialog-opening path cancels its dialog on every error branch.

## Audio pipeline

**Dialog-free track export** rides on Track Freeze: arm freeze (key command), verify the header checkbox flipped *before* pressing play (arming is instant; a refusal means the track structurally can't freeze — stacks, buses, shared channel strips — and fails in ~2 s with the alternative named), play, watch `Media/Freeze Files` for the lock file to disappear, copy the render out, un-freeze. Bar-range slicing is done by Logician's own PCM slicer (afconvert has no offset support).

**Bars are only as good as the tempo they were converted with.** One primitive turns bars into seconds, and it does it with a single tempo reading — which the control bar publishes *for the playhead position*, so a project with a tempo map makes every self-cut slice wrong from its first tempo change onward. The same position-dependence is the sensor: park the playhead at a range's first bar, read, park at the last, read, restore, and two reads say whether the range has one tempo (`sampleTempo`, epsilon 0.05 BPM, measured at ~0.13 s per bar of playhead travel). Tools that hand Logic bar numbers (bounce, cycle range, region tools) are correct under any map and are never sampled. Tools that slice seconds themselves either refuse with the working alternative named — `evaluate_change` method `render`, whose whole job is a trustworthy A/B, and `record_midi`'s tempo-overwriting speed mode — or carry a `warning` with both readings. A sample that cannot run warns rather than refusing; the playhead is never moved when there is nothing to restore it to, and a restore that failed is reported instead of assumed.

**Master export** drives the bounce dialog (offline). `solo_bounce` covers what freeze refuses: solo the track (Accessibility strip toggle is authoritative when a track number is given — duplicate names make MCU name-matching ambiguous), bounce A, apply the verified change, bounce B, roll back, un-solo — with solo restoration on every error path.

**The agent hears its work.** Every bounce/render result attaches the rendered audio as an MCP audio content block (stereo AAC 64 kbps — forcing mono via `afconvert -c 1` fails on AIFFs with explicit stereo layouts). Evaluations attach *both* versions in order (first = baseline, second = after). Clients that drop audio blocks (verified: Antigravity CLI) are redirected by the result text to a persisted preview file their file viewer can pass to the model as native audio — the result self-diagnoses at exactly the moment it matters. RMS/peak metrics are computed straight from the PCM on disk; a silent file or a leftover solo produces a `warning` in the result.

**MIDI composition** streams note/CC/pitch-bend events with CoreMIDI host-time stamps through the performance port while Logic records: beat-edge synchronization, count-in roll detection, and a measured ~45 ms sync compensation put notes on the grid (quantization-friendly but not required). An opt-in speed mode records at up to 8× by converging the tempo slider around the take.

**Automation recording** presses the MCU automation-mode buttons (Read/Write/Touch/Latch, verified from the strip's Accessibility label), schedules parameter movements against the rolling transport (roll-start anchoring, first-point lead time, touch wiggle), and verifies by *playhead chase*: park the playhead across the lane in Read mode and read back what Logic reports — exact for faders and plugin parameters, ±0.2 dB for sends.

## Logic quirks catalog (the expensive lessons)

- AppleScript's standard suite mostly works (documents, names, paths, `close saving yes/no`) — but `save` is a stub that times out, and `make new document` creates windowless ghosts. Save goes through the key command, verified by the modified flag clearing *or* the project package's `ProjectData` mtime advancing (Logic sometimes keeps a dirty flag for view-only state).
- Key-command MIDI bindings are scoped to the *port's unique identity*. They survive in the UI and die silently when ports are recreated. (See fixed IDs above.)
- A strict JSON-RPC client (Antigravity's Go MCP layer) closes the connection if the server responds to a *notification* — even with a well-formed error. Notifications get silence; unknown *requests* get `-32601`; `initialize` echoes the client's protocol version when it is a known one.
- New-project templates must not contain `Alternatives/*/Autosave` or Logic shows a recovery prompt on open. Project duplication strips them.
- File names arrive NFD from the filesystem/AppleScript and NFC from JSON clients; every comparison normalizes.
- Bounce settings persist between invocations — including the destination-format checkboxes and the position fields, which is why position writes must handle arbitrary leftover states.
- Freeze arming can be structurally refused with the checkbox present but inert (tracks sharing a channel strip). Only the pre-play arming check catches this cheaply.

## Code structure

`Sources/Logician/` is organised by control plane, so a file's prefix tells you which mechanism it speaks:

- `Support.swift` — errors, shared types, version constants, the scoped-cache envelope, filename sanitisation
- `LogicAccessibility.swift` + `AX*.swift` — the Accessibility plane (bounce dialog, regions, projects, tracks, transport, plugins, freeze, key-command learning)
- `MCUController.swift` + `MCU*.swift` — the Mackie Control plane (transport/LCD, mixing, sends, render, plugin browser, automation, MIDI recording, parameters, instrument)
- `MCUBridgeClient.swift`, `KeyCommandRegistry.swift` — the daemon client and the key-command consent record
- `MCPServer.swift`, `Tool.swift`, `ToolRegistry.swift`, `ToolHandlers*.swift` — the MCP plane

**Tools are descriptors, not switch cases.** Each tool declares its name, schema, handler, and whether it changes sound or arrangement, in one array that both `tools/list` and dispatch read. A `Tool` cannot be constructed without a handler, so the schema/handler correspondence is a compile-time property. The `listen_note` honesty guards read those flags — they were once two hand-maintained sets of tool names, which meant adding a sound-changing tool could silently lose the guard.

**Caches are scoped or absent.** `bank-cache.json` and `param-names-cache.json` carry a stamp of the build version and the project path; a file that does not match reads as absent rather than as data, and a cache is not written at all when the scope cannot be established. The parameter-name cache additionally verifies one live page against the cached row before any cheap read is trusted — it pairs cached names with fresh values positionally, so a plugin update that inserts a parameter would otherwise produce confidently wrong pairs.

**Tests** (`swift test`, ~0.04 s, no Logic required) cover the pure logic: socket framing under real concurrency, the MIDI running-status parser including malformed and pseudorandom input, LCD field slicing, the dB parser, filename sanitisation, cache scoping, formatted-value comparison, the bars→seconds and end-of-take arithmetic, and the tempo-map guards' epsilon and message construction. Everything else needs Logic running and is verified by hand against a real project.

## Error taxonomy

Uniform across all 59 tools: `not_found` / `not_exposed` (with what *is* visible), `precondition_failed` (your expected value didn't match; nothing written), `ambiguous` (candidates listed; disambiguate), `verification_failed` (write happened, echo didn't confirm; restoration state reported), `invalid_arguments`. Messages are written for agents: they name the observed state and the concrete next step.

## Threat model (for the open-source release)

Trust model: the AI agent already acts with the user's authority, and its only channel to the machine is this tool set, scoped to controlling Logic Pro. The line that matters is *scope escape* — an agent (possibly prompt-injected) running arbitrary code or touching files unrelated to Logic.

Hardened accordingly: AppleScript is never built by string interpolation (runtime values, e.g. agent-chosen project names, pass through `argv` so they can never become code); tool labels are sanitized to a single filename component before they reach an output path (no traversal out of the captures directory); `logic_mcu_command`'s `keycmd` is routed through the registry consent gate rather than firing raw MIDI notes; the command socket is `chmod 0600`; and the outdated-daemon replacement kills by exact process name / absolute path, not a broad substring match.

Accepted, by design: `logic_get_audio_clip` takes an arbitrary path and returns it as an audio block. It is not a general file-read primitive (only files macOS's audio stack decodes succeed), and fetching audio for the user is the tool's purpose — but a prompt-injected agent could read the audio content of any decodable media file it can name. This is consistent with the trust model (the agent already has the user's authority); it is called out here so downstream users can decide whether to confine readable roots.
