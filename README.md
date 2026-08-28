<div align="center">

<img src="docs/assets/banner.svg" alt="Logician — hands and ears for AI agents in Logic Pro" width="880"/>

# Logician

**Give your AI agent hands and ears in Logic Pro.**

[![macOS](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](Package.swift)
[![MCP](https://img.shields.io/badge/MCP-83_tools-4be37a)](docs/AGENT-GUIDE.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

[Install](#install) · [What it can do](#what-it-can-do-measured) · [Agent guide](docs/AGENT-GUIDE.md) · [Architecture](docs/ARCHITECTURE.md)

</div>

An MCP server that gives Claude, Gemini, Cursor — any MCP client — real, verified control over Logic Pro on macOS: every plugin parameter (third-party included), mixing, MIDI composition, arrangement editing, automation, and dialog-free audio export. Results that produce sound **carry the sound**: bounces and A/B evaluations return the audio itself, so a multimodal agent hears what it just did in the same reply it decides from. No UI scripting, no synthetic keypresses, no mouse takeover.

## Install

> [!NOTE]
> **You need:** macOS 13+ · Logic Pro · Apple's command-line tools — if `swift --version` fails, run `xcode-select --install` first.

### 1 · Download & build

Paste into Terminal — the compile takes a minute or two:

```bash
git clone https://github.com/BanneBanning/logician-mcp.git
cd logician-mcp && swift build -c release
```

**You should see** `Build complete!` on the last line.

### 2 · Connect your AI

From inside that same folder — `$(pwd)` fills in the path so you never copy one by hand. One line for your client, then **restart the client**:

**Antigravity + Gemini** &nbsp;*(recommended — the agent can actually hear your mix)*

```bash
agy mcp add logician "$(pwd)/.build/release/logician"
```

**Claude Code**

```bash
claude mcp add logician -- "$(pwd)/.build/release/logician"
```

<details>
<summary><b>Other clients — Cursor · VS Code · LM Studio · Gemini CLI · anything MCP</b></summary>
<br>

One-click registration for these clients — **after** step 1 above:

[<img src="https://cursor.com/deeplink/mcp-install-dark.svg" alt="Add Logician to Cursor" height="32">](https://cursor.com/install-mcp?name=logician&config=eyJjb21tYW5kIjoiL2Jpbi9zaCIsImFyZ3MiOlsiLWMiLCJleGVjIFwiJEhPTUUvbG9naWNpYW4tbWNwLy5idWlsZC9yZWxlYXNlL2xvZ2ljaWFuXCIiXX0%3D) &nbsp; [<img src="https://img.shields.io/badge/VS_Code-Install_Logician-0098FF" alt="Install Logician in VS Code" height="32">](https://vscode.dev/redirect/mcp/install?name=logician&config=%7B%22command%22%3A%22%2Fbin%2Fsh%22%2C%22args%22%3A%5B%22-c%22%2C%22exec%20%5C%22%24HOME%2Flogician-mcp%2F.build%2Frelease%2Flogician%5C%22%22%5D%7D) &nbsp; [<img src="https://files.lmstudio.ai/deeplink/mcp-install-dark.svg" alt="Add Logician to LM Studio" height="32">](https://lmstudio.ai/install-mcp?name=logician&config=eyJjb21tYW5kIjoiL2Jpbi9zaCIsImFyZ3MiOlsiLWMiLCJleGVjIFwiJEhPTUUvbG9naWNpYW4tbWNwLy5idWlsZC9yZWxlYXNlL2xvZ2ljaWFuXCIiXX0%3D)

Straight talk about what these buttons do: they **only** register the server in the client — the one step they replace is the command in step 2. No button can compile Swift or click through Logic's Control Surfaces window, so steps 1, 3 and 4 are still yours. They also assume you cloned into your home folder (`~/logician-mcp` — where step 1 lands if you pasted it into a fresh Terminal). Cloned somewhere else? Use the JSON below instead.

**Gemini CLI** — installs as an extension (this repo ships a `gemini-extension.json`), then build inside it:

```bash
gemini extensions install https://github.com/BanneBanning/logician-mcp
cd ~/.gemini/extensions/logician && swift build -c release
```

**Any other MCP client** — point it at the binary. Print the exact path with `echo "$(pwd)/.build/release/logician"`, then:

```json
{ "mcpServers": { "logician": { "command": "/ABSOLUTE/PATH/TO/logician-mcp/.build/release/logician" } } }
```

</details>

### 3 · Let Logic see it *(one-time, ~5 clicks)*

First, ask your agent to **"Run logic_health"** once — that wakes Logician's helper and creates the MIDI port Logic is about to look for. Then, in Logic:

> [!IMPORTANT]
> **Logic Pro → Control Surfaces → Setup… → New ▾ → Install… → Mackie Control → Add**, then set **Input Port** *and* **Output Port** to **`Logic MCP MCU`**.

And grant **Accessibility** to your client when macOS asks (or: System Settings → Privacy & Security → Accessibility → switch on your client).

### 4 · Check it

Ask your agent one more time:

> **"Run logic_health"**

**You should see** `mcu_connected: true` and `accessibility_trusted: true` — it verifies every step above and names the exact fix for anything still missing. Then try the fun one:

> *"Bounce bars 1–4 and tell me what you hear."* 🎧

📖 **First time setting up an MCP server?** The [**step-by-step Installation Guide**](docs/INSTALL.md) walks every single click, with a troubleshooting table.

---

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

## Requirements

- macOS 13+, Logic Pro (tested on 12.x, English UI — v1 assumption)
- Swift toolchain (to build from source)
- One-time: Accessibility permission for your MCP client, and a Mackie Control device in Logic pointing at the `Logic MCP MCU` ports (Logic Pro → Control Surfaces → Setup → New → Mackie Control — `logic_health` walks you through it)

## Tool overview (83 tools)

- **Diagnostics** — `logic_health` (doctor with fixes), `logic_setup_key_commands` (incl. `relearn` repair)
- **Project lifecycle** — open/close/save/duplicate projects; new projects from a bundled template; `logic_reset_to` (verified episode reset: close without saving, reopen a fixture — built for eval harnesses)
- **Reading & orientation** — tracks, regions, windows, inserts, sends, plugin parameter survey (third-party included); `logic_list_strips` (the full mixer census incl. auxes/buses/outputs), `logic_mixer_snapshot` (every strip's dB/mute/solo/arm/pan in one call), `logic_track_info` (type/instrument/routing/groups), `logic_list_events` (read a region's MIDI), `logic_markers`, `logic_list_signatures`, `logic_read_automation`, `logic_project_snapshot` (the whole project as one structured truth document)
- **Transport** — play/stop, playhead, cycle range, metronome, verified via MCU LEDs and timecode
- **Mixing** — volume (dB-converged), pan, mute, solo, record-arm, sends (level + destination), insert bypass, output/group routing (`logic_set_track_routing`); **the master chain and buses address by name** (`Stereo Out`, auxes)
- **Plugins** — add/remove (data-driven, no mouse), open/close windows, read/write **any** parameter, preset browsing (`list`/`select`/`step`/`undo`), `logic_load_instrument`
- **Tracks** — create, rename, duplicate, delete, stacks
- **Regions** — select (incl. multi-select), move, copy, delete, split (dialog-aware), nudge, remove silence
- **Composition** — `logic_record_midi`: notes/CC/pitch-bend streamed with CoreMIDI timestamps while Logic records, render-verified; **tempo and meter maps are read, integrated and editable** (`logic_tempo_events` creates/edits/deletes tempo-map events; signature changes followed); Smart Tempo mode read before recording so an Adapt-mode project is refused, never rewritten
- **Automation** — read existing curves; record volume/pan/send/plugin curves in any mode, playhead-chase verified
- **Audio out & evaluation** — bounce (format/depth/dither options), bounce-in-place, stem export, freeze render with bar slicing, `logic_evaluate_change` (render / bounce / solo_bounce), `logic_get_audio_clip`
- **Key commands** — trigger any learned Logic key command over MIDI; learn new ones by name (`logic_learn_key_command`, consent-recorded)

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

- The biggest limitation is the models themselves: today's multimodal agents — Gemini's included — are not yet the mixing engineers you might wish for. That is exactly why Logician exists: give them real hands and ears in Logic, and you can *measure* how good they actually are instead of guessing.
- English Logic UI assumed (Accessibility string matching; locale tables are future work)
- Tempo and meter maps are read from Logic's own lists and integrated into all bar math; tempo *curves* are approximated as steps (the Tempo List does not expose them) with the uncertainty quantified. MIDI recording takes real time.
- Track stacks cannot be freeze-rendered (Logic limitation — `solo_bounce` covers their subtracks)
- **[docs/ROADMAP.md](docs/ROADMAP.md)** is the plan and the log: items 1–4 (tempo guards, master-chain addressing, variable tempo, preset browsing) largely shipped and live-verified 2026-08-27/28; **[docs/COVERAGE.md](docs/COVERAGE.md)** is the black-box producer audit that feeds what comes next

---

<div align="center">
<sub>Built by <a href="https://www.linkedin.com/in/alexander-banning-663788205/"><b>Alexander Banning</b></a> — say hi on LinkedIn · Released under the <a href="LICENSE">MIT license</a></sub>
</div>
