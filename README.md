<div align="center">

<img src="docs/assets/banner.svg" alt="Logician — hands and ears for AI agents in Logic Pro" width="880"/>

# Logician

**Give your AI agent hands and ears in Logic Pro.**

[![macOS](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](#requirements)
[![CI](https://github.com/BanneBanning/logician-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/BanneBanning/logician-mcp/actions/workflows/ci.yml)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](Package.swift)
[![MCP](https://img.shields.io/badge/MCP-84_tools-4be37a)](docs/AGENT-GUIDE.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

[What you can say](#what-you-can-say) · [Install](#install) · [How fast](#how-fast-is-it) · [Agent guide](docs/AGENT-GUIDE.md)

</div>

Logic Pro has no API, so every AI assistant could talk about your mix without being able to touch it. That always bugged me, so I built Logician. It gives Claude, Gemini, Cursor — any MCP client — hands and ears inside a real Logic project: it mixes, edits, composes and bounces, and it **hears the result**, because every render comes back as audio the agent actually listens to. Ask a multimodal agent to listen through your session and it returns with concrete moves it can execute itself the moment you say yes. Today's models already make a sharp assistant, and the ones coming will make a producer — this is the instrument I want waiting for them.

## What you can say

| You say | The agent does |
|---|---|
| *"Bounce bars 1–4 and tell me what you hear."* | Renders the master offline (no dialogs, session untouched), listens, and tells you what is actually in the audio. |
| *"More bass around 500 Hz, about 2 dB."* | Finds the bass track → finds the EQ (or adds one) → nudges the band → confirms the change against Logic's own readout. About a second. |
| *"The hats are too stiff — quantize them, but keep some feel."* | Sets the region's quantize with swing. The notes you played stay yours. |
| *"A/B that compressor setting on the master."* | Prints the mix twice — before and after — and hands you both versions, so the call is made with ears. |
| *"Fix the flubbed note in bar 3."* | Reads the region's MIDI, corrects the one note, leaves the take alone. |
| *"Lay down drums, bass and keys from bar 9."* | Writes the MIDI and imports the whole arrangement in one pass — onto your existing tracks if you name them — then verifies it note for note. |
| *"Ride the vocal up in the chorus."* | Records a volume automation pass over those bars and verifies the curve landed. |
| *"Give me stems of the chorus."* | Solo-bounces every track over the same bars — aligned, same length, ready to send. |
| *"Listen to the whole song. What would you change?"* | Bounces the mix and reads the whole project — levels, plugins, arrangement — then comes back with moves it can actually make. Say yes, and it makes them. |

Every change is checked against Logic's own readouts and rolled back on a mismatch. Nothing is ever saved without you asking.

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

## How fast is it?

Fast enough that you stop noticing. I stopwatch everything against a live reference project (25 mixer strips, 54 regions); these are the numbers on a warm session.

| You ask for | It takes |
|---|---|
| Any plugin parameter, set and confirmed — third-party plugins included | **~1 s** |
| A new plugin on a track | **~2.5 s** |
| A new track (or a track gone) | **under 1 s** |
| A bounce of any bar range, audio attached, zero dialogs | **~2 s** |
| A before/after A/B of a change, both versions as audio | **~5 s** |
| A whole MIDI arrangement composed by import, verified note for note | **~3–4 s** |
| The entire project read — tracks, regions, markers, transport | **well under a second** |
| A marker set, moved to, or removed | **under 1 s** |
| A send created with its level, or removed | **~4–6 s** |
| Stems of any range | **~4 s per track** |

Every one of those numbers includes the verification: Logician reads Logic's own readout back before it tells you anything happened.

## Requirements

- macOS 13+ and Logic Pro (tested on 12.x, English UI)
- Swift toolchain, to build from source
- One-time: Accessibility permission for your client, and a Mackie Control device in Logic on the `Logic MCP MCU` ports — `logic_health` walks you through both

## What's inside (84 tools)

**See** the project: tracks, regions, markers, the whole mixer, any region's MIDI, any plugin's parameters, or all of it as one snapshot. **Mix**: volume, pan, mute, solo, sends, routing, insert bypass — the master chain and buses by name. **Plugins**: add, remove, read and write any parameter, browse presets, load instruments. **Edit**: select, move, copy, split, nudge, rename, quantize, transpose, fades, single notes. **Compose**: whole arrangements by MIDI import in seconds, or performed live through the track's instrument. **Automate**: read and record curves. **Hear**: bounce, bounce in place, stems, freeze renders, A/B — audio comes back inline and as a link, and a listen-first mode holds the metrics back until the agent has actually listened.

The full reference, with every tool's contract, is the [Agent guide](docs/AGENT-GUIDE.md).

## Under the hood

Logic Pro has no automation API, so most tools that try to drive it fake a user: keypresses, dialog clicks, mouse moves. Logician speaks **Mackie Control** instead — Logic's own bidirectional control-surface protocol — over virtual MIDI ports, and reads Logic's LCD, LED and fader echoes back as proof. Where the surface protocol ends, it uses macOS Accessibility and a dedicated MIDI port bound to Logic's key commands.

That buys three things:

1. **Any plugin, any parameter.** Third-party plugins with custom UIs expose nothing to Accessibility — but everything to the control-surface layer.
2. **Ground truth.** Every write is read back from Logic before it is reported. The agent cannot make a value up; the echo *is* the value.
3. **Your mouse stays yours.** Nothing needs to be open or visible. You can keep working while the agent mixes.

<details>
<summary><b>Architecture</b></summary>

```
MCP client (Claude, Gemini, Cursor, …)
        │ stdio / JSON-RPC (results carry audio content blocks)
logician  ──spawns──▶  logician --bridge (daemon)
   │        │                    │  virtual CoreMIDI ports (fixed IDs):
   │        │ unix socket        │   "Logic MCP MCU"      (Mackie Control ⇄ Logic)
   │        └────────────────────┤   "Logic MCP Commands" (key commands → Logic)
   │                             │   "Logic MCP MIDI In"  (performance MIDI → Logic)
   └─ macOS Accessibility (element-addressed reads, track selection,
      region editing, dialogs)
```

Safety model: read before write, abort on ambiguity, verify by readback, roll back on mismatch, never save without being asked, duplicate before destructive experiments.

</details>

## Known limitations

- The biggest one is the models themselves: today's multimodal agents are a sharp assistant, not yet a producer. Half the reason I built this was to find out exactly how good they are. The tool is ready for the day that changes.
- English Logic UI is the fully supported one for now. Logician detects the language and says plainly what degrades on others; more locales land as they are captured.
- Tempo *curves* are read as steps (Logic's Tempo List does not expose them), with the uncertainty stated.
- Automation can be recorded on tracks, not on `Stereo Out`, auxes or buses — their volume, pan, sends and plugins are still fully writable.
- Roadmap: Homebrew and a one-click installer for musicians who have never met a terminal, as soon as the repo is public.

---

<div align="center">
<sub>Built by <a href="https://www.linkedin.com/in/alexander-banning-663788205/"><b>Alexander Banning</b></a> — say hi on LinkedIn · Released under the <a href="LICENSE">MIT license</a></sub>
</div>
