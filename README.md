# Logician

**Control Logic Pro from AI agents — through the data plane, not the UI.**

An MCP (Model Context Protocol) server that gives Claude, Cursor, and other MCP clients real, verified control over Logic Pro on macOS: transport, mixing, every plugin parameter (third-party included), dialog-free audio export, closed-loop A/B evaluation of mix changes, and MIDI composition recorded straight onto your tracks.

> **Logician** = Logic + musician (+ a reasoning logician). License and distribution channel are not final; currently a private repo — build from source.

## Why this one is different

Logic Pro has no automation API. Every other Logic MCP drives the UI: synthetic keypresses, dialog clicking, window scraping. This server instead speaks **Mackie Control** — Logic's documented, bidirectional control-surface protocol — over virtual MIDI ports, and reads Logic's own LCD/LED/fader echoes back as verification. Where the surface protocol ends, it uses macOS Accessibility semantics (element-addressed, never coordinate clicking), and a dedicated MIDI port bound to Logic key commands.

What that buys, measured on a real project:

| Capability | Measured |
|---|---|
| Export one track to a file, **zero dialogs** (via Track Freeze) | ~6 s for 2 min of audio |
| A/B a plugin-parameter change on one track, metrics from files, auto-rollback | ~15 s |
| A/B against the master bus (offline bounce) | ~20 s |
| Set any plugin parameter, verified via LCD echo, incl. third-party (Trilian, Decapitator…) | ~1.5–2.5 s |
| Compose MIDI notes and record them through the track's instrument, render-verified | ~16 s for a 6-note phrase |
| Play/stop, faders, mute/solo, sends — all with hardware-level feedback | ~0.1–2 s |

Every write is **compare-and-set**: the tool reads the current value, refuses on mismatch, converges toward the target, reads the echo back, and reports exactly what happened. Failed operations roll back and say so.

## Requirements

- macOS 13+, Logic Pro (tested on 12.x, English UI — v1 assumption)
- Swift toolchain (to build from source)
- One-time: Accessibility permission for your MCP client, and a Mackie Control device in Logic pointing at the ports `Logic MCP MCU` (Logic Pro → Control Surfaces → Setup → New → Mackie Control)

## Install

```bash
swift build -c release
```

Then register the single binary with your MCP client, e.g. for Claude Code:

```bash
claude mcp add logic -- /path/to/.build/release/logician
```

Everything else is self-serve: the server starts its own bridge daemon, `logic_health` diagnoses every setup step with a concrete fix, and the Logic key commands the tools rely on (freeze render, undo, …) are learned into your Logic automatically on first use — additively, removable in the Key Commands window, with collision handling.

## Tool overview (40 tools)

- **Diagnostics** — `logic_health` (doctor: checks and fixes for every setup step), `logic_setup_key_commands`
- **Project reading** — tracks, windows, inserts, plugin parameter survey
- **Transport** — play/stop, playhead, cycle range, all verified via MCU LEDs and timecode
- **Mixing** — volume (dB-converged), pan, mute, solo, **sends** (level per send slot, read + write)
- **Plugins** — add/remove, open/close windows, read/write **any** parameter via MCU host automation (works for custom-UI third-party plugins that expose nothing to Accessibility)
- **Audio out** — `logic_render_track` (dialog-free freeze render with bar-range slicing to WAV), `logic_bounce_range` (offline master bounce)
- **Evaluation** — `logic_evaluate_change` with three methods: `render` (single-track A/B, fastest), `bounce` (master A/B), `realtime` (loop playback with the optional sensor)
- **Composition** — `logic_record_midi`: notes (names or MIDI numbers, bars/beats/durations/velocities) streamed over a virtual MIDI port with CoreMIDI timestamps while Logic records; verified by rendering the recorded bars
- **Key commands** — trigger any learned Logic key command (Undo, Redo, Flashback Capture, Split, Create Marker, …) over MIDI
- **Sensor (optional add-on)** — a bundled Audio Unit that publishes live RMS/peak and captures listenable WAV of what any insert point hears; not required by any bounce/render tool

## Architecture

```
MCP client (Claude, Cursor, …)
        │ stdio / JSON-RPC
logician  ──spawns──▶  logician --bridge (daemon)
   │        │                    │  virtual CoreMIDI ports:
   │        │ unix socket        │   "Logic MCP MCU"      (Mackie Control ⇄ Logic)
   │        └────────────────────┤   "Logic MCP Commands" (key commands → Logic)
   │                             │   "Logic MCP MIDI In"  (performance MIDI → Logic)
   └─ macOS Accessibility (element-addressed reads, track selection,
      freeze-state checkboxes, dialogs) — fallback, never coordinates
```

Safety model: read before write, abort on ambiguity, verify by readback, roll back on mismatch, never save the project, ask before destructive operations. See [docs/FINDINGS.md](docs/FINDINGS.md) for the full research log (Swedish) — every mechanism above was empirically verified and versioned there.

## Known limitations

- English Logic UI assumed (Accessibility string matching; locale tables are future work)
- The Mackie Control device in Logic is a one-time manual setup (guided by `logic_health`)
- MIDI recording takes real time (bars × beats × 60/BPM); constant tempo assumed for bar math
- Track stacks cannot be freeze-rendered (Logic limitation; the tools refuse cleanly)
