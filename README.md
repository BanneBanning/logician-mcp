<div align="center">

<img src="docs/assets/banner.svg" alt="Logician — hands and ears for AI agents in Logic Pro" width="880"/>

# Logician

**Give your AI agent hands and ears in Logic Pro.**

[![macOS](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](Package.swift)
[![MCP](https://img.shields.io/badge/MCP-57_tools-4be37a)](docs/AGENT-GUIDE.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

[Install](#install) · [What it can do](#what-it-can-do-measured) · [Agent guide](docs/AGENT-GUIDE.md) · [Architecture](docs/ARCHITECTURE.md)

</div>

An MCP server that gives Claude, Gemini, Cursor — any MCP client — real, verified control over Logic Pro on macOS: every plugin parameter (third-party included), mixing, MIDI composition, arrangement editing, automation, and dialog-free audio export. Results that produce sound **carry the sound**: bounces and A/B evaluations return the audio itself, so a multimodal agent hears what it just did in the same reply it decides from. No UI scripting, no synthetic keypresses, no mouse takeover.

## Why this one is different

Logic Pro has no automation API. Every other Logic MCP drives the UI: synthetic keypresses, dialog clicking, coordinate mouse moves, window scraping. Logician instead speaks **Mackie Control** — Logic's documented, bidirectional control-surface protocol — over virtual MIDI ports, and reads Logic's own LCD/LED/fader echoes back as verification. Where the surface protocol ends it uses macOS Accessibility *semantics* (element-addressed, never coordinates) and a dedicated MIDI port bound to Logic key commands.

That buys three things UI automation can't give you:

1. **Universal plugin control.** Third-party plugins with fully custom UIs (Trilian, Decapitator, …) expose nothing to Accessibility — but everything to the control-surface host automation layer. Logician reads and writes any parameter of any plugin.
2. **Hardware-level ground truth.** Every write is compare-and-set: read the current value, refuse on mismatch, converge to the target, read Logic's echo back, report exactly what happened. The agent cannot hallucinate a parameter value — the LCD echo is the value.
3. **Your mouse stays yours.** Nothing moves the pointer, nothing types into your windows, no dialog-clicking races. You can keep working while the agent mixes.

## Built for agents that lie (so they can't)

Logician assumes the model on the other end is fallible and designs for it:

- **Results carry their audio.** `logic_bounce_range` and `logic_render_track` attach the rendered sound as an MCP audio content block. `logic_evaluate_change` attaches **both** versions — first block baseline, second after — so the A/B is heard in the same result the keep/rollback decision is made from. Clients that drop audio blocks are redirected to a file the model's file viewer can play.
- **Honesty guards.** A bounce that comes out silent says so (`warning`, measured from the file). Tracks left soloed are named. A freeze that refuses to arm fails in 2 seconds with the structural cause and the working alternative.
- **Mix by ear, verify by numbers.** Every sound-changing write returns a standing instruction to judge the result by listening — a fader value is not loudness. Arrangement edits warn about the classic groove-displacement failure that model ears miss.
- **Self-repair.** Key-command bindings orphaned by MIDI-port changes are detected and re-learned (`logic_setup_key_commands {relearn: true}`), with duplicate-assignment cleanup. `logic_health` is a doctor that names the concrete fix for every broken setup step.

## What it can do, measured

| Capability | Measured |
|---|---|
| Bounce any bar range of the master, zero dialogs, audio attached | ~7 s |
| Render one track to a file via Track Freeze, sliced to bars | ~8–15 s |
| A/B a parameter change on one track, metrics + both audio versions, auto-rollback | ~15 s |
| A/B on tracks freeze refuses (stack subtracks, shared channels) via `solo_bounce` | ~50 s |
| Set any plugin parameter, verified via LCD echo, incl. third-party | ~1.5–2.5 s |
| Compose MIDI (notes, CC, pitch bend) recorded through the track's instrument, render-verified | real time + ~8 s |
| Automation curves (volume/pan/sends/plugin params, all modes), playhead-chase verified | ~10–30 s |
| Duplicate the project to a safe sandbox copy | ~2 s |

## Install

```bash
swift build -c release
```

Then register the single binary with your MCP client:

**Claude Code**

```bash
claude mcp add logician -- /path/to/.build/release/logician
```

**Antigravity CLI** — use the CLI's own registration (hand-editing settings.json is not picked up reliably):

```bash
agy mcp add logician /path/to/.build/release/logician
```

Restart the session (MCP servers load at session start) and verify with `agy mcp list`. Have the agent confirm it sees the `logic_*` tools before starting work.

**Gemini CLI** — add to `~/.gemini/settings.json`:

```json
{ "mcpServers": { "logician": { "command": "/path/to/.build/release/logician" } } }
```

**Other MCP clients:** the same `mcpServers` JSON shape, or the client's own `mcp add` command where one exists (prefer it).

Everything else is self-serve: the server spawns its own bridge daemon, `logic_health` diagnoses every setup step with a concrete fix, and the Logic key commands the tools rely on are learned into your Logic automatically on first use — additively, removable in the Key Commands window, with collision handling.

**Point the agent at [docs/AGENT-GUIDE.md](docs/AGENT-GUIDE.md)** — core concepts, workflows, error taxonomy, and the complete tool reference generated from the live schemas.

## Requirements

- macOS 13+, Logic Pro (tested on 12.x, English UI — v1 assumption)
- Swift toolchain (to build from source)
- One-time: Accessibility permission for your MCP client, and a Mackie Control device in Logic pointing at the `Logic MCP MCU` ports (Logic Pro → Control Surfaces → Setup → New → Mackie Control — `logic_health` walks you through it)

## Tool overview (57 tools)

- **Diagnostics** — `logic_health` (doctor with fixes), `logic_setup_key_commands` (incl. `relearn` repair)
- **Project lifecycle** — open/close/save/duplicate projects; new projects from a bundled template
- **Reading** — tracks, regions, windows, inserts, sends, plugin parameter survey (third-party included)
- **Transport** — play/stop, playhead, cycle range, verified via MCU LEDs and timecode
- **Mixing** — volume (dB-converged), pan, mute, solo, sends (level + destination)
- **Plugins** — add/remove (data-driven, no mouse), open/close windows, read/write **any** parameter, preset stepping
- **Tracks** — create, rename, duplicate, delete, stacks
- **Regions** — select, move, copy, delete; split/nudge via key commands
- **Composition** — `logic_record_midi`: notes/CC/pitch-bend streamed with CoreMIDI timestamps while Logic records, render-verified
- **Automation** — record volume/pan/send/plugin curves in any mode, playhead-chase verified
- **Audio out & evaluation** — bounce, freeze render with bar slicing, `logic_evaluate_change` (render / bounce / solo_bounce), `logic_get_audio_clip`
- **Key commands** — trigger any learned Logic key command over MIDI

## Architecture

```
MCP client (Claude, Gemini, Cursor, …)
        │ stdio / JSON-RPC (results carry audio content blocks)
logician  ──spawns──▶  logician --bridge (daemon)
   │        │                    │  virtual CoreMIDI ports (fixed IDs):
   │        │ unix socket        │   "Logic MCP MCU"      (Mackie Control ⇄ Logic)
   │        └────────────────────┤   "Logic MCP Commands" (key commands → Logic)
   │                             │   "Logic MCP MIDI In"  (performance MIDI → Logic)
   └─ macOS Accessibility (element-addressed reads, track selection,
      region editing, dialogs) — semantic, never coordinates
```

Safety model: read before write, abort on ambiguity, verify by readback, roll back on mismatch, never save without being asked, duplicate before destructive experiments. **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** explains how every mechanism works — the MCU convergence loops, the key-command learning, the bounce-dialog semantics, and the Logic quirks catalog. [docs/FINDINGS.md](docs/FINDINGS.md) is the full research log (Swedish), versioned per discovery.

## Known limitations & roadmap

- English Logic UI assumed (Accessibility string matching; locale tables are future work)
- Constant tempo assumed for bar math; MIDI recording takes real time
- Track stacks cannot be freeze-rendered (Logic limitation — `solo_bounce` covers their subtracks)
- Roadmap: Stereo Out / master-chain addressing, plugin preset browsing via vpot, Homebrew packaging, localization
