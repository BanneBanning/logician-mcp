<div align="center">

<img src="docs/assets/banner.svg" alt="Logician — hands and ears for AI agents in Logic Pro" width="880"/>

# Logician

**Give your AI agent hands and ears in Logic Pro.**

[![macOS](https://img.shields.io/badge/macOS-14.5%2B-black?logo=apple)](#quick-start)
[![Release](https://img.shields.io/badge/release-v1.0.0--beta.1-f5a623)](CHANGELOG.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

[See what it can do](#what-you-can-ask) · [Install](#quick-start) · [Agent guide](docs/AGENT-GUIDE.md)

</div>

Logician connects **multimodal AI agents** to Apple Logic Pro. Ask an audio-capable agent to listen to a chorus, inspect the tracks and plugins behind it, suggest improvements, make the changes you approve, and bounce a new version to compare.

**Listen → understand → propose → approve → change → listen again.**

Most AI assistants can talk about music. Logician lets them work with the actual session — hearing the audio, understanding the project around it and acting on what they find.

## What you can ask

| You say | What happens |
|---|---|
| *"Listen to the chorus. Why is the vocal getting lost?"* | The agent hears the audio, inspects the vocal chain and mix, and suggests concrete changes. |
| *"Try that compressor setting and let me hear before and after."* | Logician applies the approved change, confirms it in Logic and returns both versions as audio. |
| *"Fix the late note in bar 17."* | The agent finds and edits the note without replacing the performance. |
| *"Export chorus stems for the band."* | Logician creates aligned stems over the requested bars. |

## Built for multimodal AI

A text-only agent can read and control your Logic project. An audio-capable agent can also receive real renders, listen to them and compare versions — so its decisions can be based on what the music sounds like, not only names and numbers.

That creates a complete feedback loop:

- **Hear it:** Render any section of the song and return it as audio.
- **Understand it:** Read tracks, plugins, routing, regions, MIDI and automation.
- **Change it:** Mix, edit, compose, automate and export.
- **Check it:** Read important changes back from Logic and compare before and after.

The best experience comes from a multimodal model and an MCP client that passes audio to it. Other MCP clients can still use Logician to inspect and control Logic, but audio support depends on the client.

## Quick start

**You need:** macOS 14.5 or later, Logic Pro and Apple's command-line tools. If `swift --version` fails, run `xcode-select --install` first.

### 1. Install Logician

```bash
brew install bannebanning/logician/logician
```

The first installation compiles Logician locally and takes about two minutes. No Homebrew? See the [step-by-step installation guide](docs/INSTALL.md).

### 2. Connect your AI

For **Antigravity + Gemini**:

```bash
agy mcp add logician "$(command -v logician)"
```

For **Claude Code**:

```bash
claude mcp add logician -- "$(command -v logician)"
```

Restart the client after connecting it. Cursor, VS Code, LM Studio, Gemini CLI and other MCP clients are covered in the [installation guide](docs/INSTALL.md).

### 3. Let Logic see it

Ask your agent to run `logic_health` once. Then open:

> **Logic Pro → Control Surfaces → Setup… → New ▾ → Install…**

Choose **Mackie Control**, click **Add**, and set both **Input Port** and **Output Port** to **`Logic MCP MCU`**. Finally, grant Accessibility permission to your AI client when macOS asks.

### 4. Try it

Ask your agent:

> **"Run `logic_health`, then bounce bars 1–4 and tell me what you hear."**

If something is wrong, `logician doctor` checks the complete connection and prints a report with project names and file paths redacted.

## Fast enough for conversation

On the reference project and test Mac, common operations take roughly:

| Operation | Typical time |
|---|---:|
| Change and confirm a plugin parameter | **~1 second** |
| Create a track | **under 1 second** |
| Bounce a section and return the audio | **~2 seconds** |
| Render a before/after comparison | **~5 seconds** |

The timings include reading the result back from Logic. Larger projects, plugins and machines will vary.

## What it can do

- **Listen:** Bounce sections, render individual tracks and return before/after audio.
- **Mix:** Control levels, pan, mute, solo, routing, sends and plugin parameters — including buses and the master output.
- **Edit:** Work with regions, notes, timing, fades, markers and track structure.
- **Compose:** Record MIDI performances or build multi-track arrangements.
- **Automate:** Read, write and remove automation curves.
- **Deliver:** Export bounces, printed regions and aligned stems.

Underneath those workflows are 81 typed tools. Their complete reference and behavioral contracts live in the [Agent guide](docs/AGENT-GUIDE.md).

## You stay in control

Logician reads editing and mixing changes back from Logic and tells the agent what was confirmed. When a safe rollback is possible, it attempts one; complex operations may require Logic's Undo. Logician never invokes Save unless the requested operation explicitly allows it.

For destructive experiments, work on a duplicate project. Avoid making simultaneous changes in Logic while an agent operation is running.

## Local by design

Logician has no network connection, telemetry or account. It communicates locally with Logic and passes results to your chosen AI client. That client may send audio and project information to its model provider, according to the client's own settings and privacy terms.

## Beta and compatibility

This is **v1.0.0-beta.1**. Logician has more than 2,300 automated tests and every tool has been profiled against a live Logic session, but the first public release is still a compatibility test in the open.

- Verified on Logic Pro 12.3.1 with the English interface.
- Other Logic versions and languages are currently best-effort.
- Tempo curves are read as steps because Logic does not expose their shape.
- Automation can be recorded on tracks, but not yet on Stereo Out, auxes or buses. Their mix and plugin parameters remain controllable.

Logician is designed to refuse an operation when the evidence it expects is missing, but a Logic update may still change behavior. Please report regressions with the redacted output from `logician doctor`.

## How it works

Logician runs locally and connects to the same control-surface layer Logic uses for studio hardware, with macOS Accessibility filling the gaps. It reads Logic's own displays and controls back as evidence instead of assuming that an action worked.

For the implementation details, see the [Agent guide](docs/AGENT-GUIDE.md). For setup and troubleshooting, see the [Installation guide](docs/INSTALL.md).

---

<div align="center">
<sub>Built by <a href="https://www.linkedin.com/in/alexander-banning-663788205/"><b>Alexander Banning</b></a> · Released under the <a href="LICENSE">MIT license</a> · <a href="CONTRIBUTING.md">Contributing</a> · <a href="SECURITY.md">Security</a></sub>

<sub>Not affiliated with, endorsed by or sponsored by Apple Inc. or LOUD Audio, LLC. Logic Pro and Mackie Control are trademarks of their respective owners — see <a href="NOTICE.md">NOTICE.md</a>.</sub>
</div>
