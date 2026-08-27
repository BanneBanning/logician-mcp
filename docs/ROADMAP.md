# Roadmap

The concrete plan for the four items the README's roadmap line has been promising, ordered by value-per-effort. Each section states the ground truth in the current code (with file references), what will change, and — in this project's tradition — which experiments have to be run against Logic before the design is trusted. Nothing here is speculative about the *current* code; everything about *Logic's* behavior that has not yet been observed is marked as an experiment.

Status legend: 🎯 planned · 🔬 needs a research session against Logic first · ⏸ parked.

| # | Item | Size | Status |
|---|------|------|--------|
| 1 | [Tempo honesty guards](#1-tempo-honesty-guards) | small | 🎯 |
| 2 | [Stereo Out / master-chain addressing](#2-stereo-out--master-chain-addressing) | medium | 🎯🔬 |
| 3 | [Variable tempo (tempo track / Smart Tempo)](#3-variable-tempo-tempo-track--smart-tempo) | large | 🎯🔬 |
| 4 | [Plugin preset browsing](#4-plugin-preset-browsing) | medium | 🔬 |
| 5 | [Homebrew packaging](#5-homebrew-packaging) | small | ⏸ blocked on the repo going public |
| — | [Deliberately parked](#parked) (localization, track-stack freeze) | — | ⏸ |

---

## 1. Tempo honesty guards

**Ground truth.** Every bar→seconds conversion flows through one primitive, `barRangeSeconds` (`Sources/Logician/ToolHandlers.swift:92`), which does `(bar − 1) × beatsPerBar × 60 / tempo` with the tempo read once from the control bar (`Sources/Logician/AXTransport.swift:82`). The tools that *hand Logic bar numbers* — `logic_bounce_range`, `logic_set_cycle_range`, region tools, `logic_evaluate_change` methods `bounce`/`solo_bounce` — are already correct under any tempo map, because Logic does the interpretation. The tools that *slice audio themselves* — `logic_render_track`, `logic_evaluate_change` method `render`, `logic_record_midi`'s verification render — are silently wrong from the first tempo change onward. That asymmetry (a correct bounce next to an incorrect freeze-slice of the same bars) is the sharpest inconsistency in the current behavior, and today nothing warns about it.

**Smart Tempo raises the stakes.** Logic's [Smart Tempo](https://support.apple.com/guide/logicpro/smart-tempo-lgcp4e829ea1/mac) has a project tempo mode — **Keep** (recordings follow the project tempo, the classic behavior), **Adapt** (the *project tempo map is rewritten* to follow the recording), and **Auto** (picks one, leaning Adapt when the metronome is off and no tempo reference exists). Since Logic 10.4.2 this applies to **MIDI recordings too**. `logic_record_midi` streams a performance while Logic records — so on a project sitting in Adapt (or Auto that resolves to Adapt), the tool doesn't just *misplace notes*, it can **rewrite the user's tempo track** as a side effect, today, on a constant-tempo project. That is a destructive write no result currently mentions.

**Plan** (no new capabilities, pure honesty — ship before anything else):

- **Smart Tempo write-protection.** Before `logic_record_midi` arms, read the project tempo mode and refuse under Adapt — and under Auto unless it verifiably resolves to Keep — naming the fix ("set the project tempo mode to KEEP: click the tempo display in the LCD, or File → Project Settings → Smart Tempo"). 🔬 The mode is shown in the LCD's tempo display, so the first experiment is whether it is AX-readable next to the control-bar `Tempo` element `logic_health`-style (`AXTransport.swift:82` already walks that group); second experiment is whether it is AX-*settable* there, which would upgrade the refusal to a guarded set-and-restore. `logic_get_transport` should surface the mode either way.
- **Detect a non-constant tempo cheaply.** The control bar shows the tempo *at the playhead* (`AXTransport.swift:82` reads whatever is displayed). Sampling it at the range's start bar and end bar (park playhead, read, restore) turns "is the tempo constant across this range?" into two reads. On mismatch: `warning` on every seconds-sliced result naming the two readings and pointing at the tempo-safe alternative (`method: "bounce"` / `logic_bounce_range`).
- **Prefer the tempo-safe path when it exists.** `logic_evaluate_change` method `render` can refuse with the structural cause and name `solo_bounce`/`bounce` as the working alternative — the same pattern freeze already uses for stacks.
- **Guard the MCU timecode parse.** `timecodeBar()` (`Sources/Logician/MCUMIDIRecording.swift:9`) assumes the 10-digit display is in beats mode; in SMPTE mode it silently reads hours as bars. The bridge already maps the `smpte_beats` button (`Sources/LogicMCUBridge/Bridge.swift:447`) but never tracks the mode. Add a plausibility check (a beats display matches `^\d{3} \d{2}` with bar ≈ control-bar playhead bar) and fail loudly — or press `smpte_beats` and re-check — instead of syncing MIDI recording against nonsense.
- **Fix the meter-blind `* 4` hardcodes** in `logic_record_midi`'s end-of-take math (`Sources/Logician/ToolHandlersTransport.swift:122–126`) — the verification render already uses the real meter; the take-length guess should too.
- **`logic_set_tempo` under a tempo track**: the compare-and-set reads a position-dependent value (`Sources/Logician/ToolHandlersMixing.swift:120`). Same two-point sampling → refuse with a warning instead of editing an arbitrary tempo node.

**Definition of done:** on a project with one mid-song tempo change, no tool returns silently wrong audio or writes to the tempo track — every affected result either refuses with the alternative named or carries a `warning`, `logic_health`-style. And `logic_record_midi` on an Adapt-mode project refuses instead of rewriting the tempo map.

## 2. Stereo Out / master-chain addressing

**Ground truth.** The research is better than the roadmap line implied: Stereo Out, auxes, and bus channels **are ordinary MCU bank channels** (docs/FINDINGS.md:531 — the master chain sweeps like any track; the LCD shows `St Out`, and `lcdNameMatches` already matches it). The bridge even plumbs the MCU master fader end-to-end (`fader` accepts channel 0–8, state mirrors 9 faders — `Sources/LogicMCUBridge/Protocol.swift:355`), unused by the server. What blocks everything is one habit: every mixing/plugin tool calls AX `selectTrack(trackName)` first, which resolves against *track headers* — and output/aux strips have no track header, so they throw `trackNotFound` before the MCU is ever asked. `logic_survey_plugins` is the proof it can work: it alone falls back to the inspector strip (`Sources/Logician/AXPlugins.swift:305`) and surveys Stereo Out today.

**Plan:**

1. **Mixing first** (volume/mute/solo/sends): route output/aux/bus strips through `findChannel` → MCU without the AX `selectTrack` precondition; AX fallback goes through `anyInspectorStrip` (`Sources/Logician/AXHelpers.swift:11`) instead of the track-header path. Pan is AX-only today and follows the inspector-strip route.
2. **Plugins on the master chain**: replace the unconditional `logic.selectTrack` in the plugin tools (`Sources/Logician/ToolHandlersPlugins.swift:20, 50, 125, 234, 256`) with MCU channel selection (`selectFoundChannel`) when the name resolves to a headerless strip. The known wrong-channel failure (FINDINGS.md:1393 — plugins once landed on Stereo Out *by accident*) becomes the safety test: LCD-verify the PL view is showing the intended strip before any write, both directions.
3. 🔬 **Experiments before trusting the design**: (a) does MCU *selection* of an output-bank channel behave identically to a track channel (PL view, vpot pages, fader echo)? (b) is the dB calibration curve (`Sources/Logician/MCUAutomation.swift:96`) valid on the Stereo Out fader? (c) what exactly does the dedicated master fader (index 8) control vs. the Stereo Out strip fader — same object or not? (d) does Logic's `global_view`/Outputs view (button exists at `Bridge.swift:447`, never pressed by the server) give a more stable bank for outputs than scanning?
4. **Verification story**: A/B on the master chain already has a tempo-safe, master-safe path — `logic_evaluate_change` method `bounce` captures the full mix. Wire the new addressing into it and the "mix bus compressor A/B" workflow falls out for free.

**Definition of done:** `logic_set_volume`, mute/solo, and the four plugin parameter/add/remove/preset tools accept `Stereo Out` (and aux/bus names), verified by LCD echo, with the same compare-and-set semantics as tracks — and an agent can A/B a limiter setting on the master bus end to end.

## 3. Variable tempo (tempo track / Smart Tempo)

**Ground truth.** FINDINGS.md:712 already names the shape: *"tempo-track following in the bar math: read tempo changes, piecewise integration."* All the damage concentrates in the one primitive plus the two recording paths: `barRangeSeconds` and its four callers; `logic_record_midi`'s single linear ms ramp (`ToolHandlersTransport.swift:138`); automation recording's single `msPerBeat` (`Sources/Logician/MCUAutomation.swift:114, 399`). The bridge itself is tempo-agnostic (offsets arrive as ms) — no bridge changes needed.

**What Logic exposes on its side** (per [Apple's tempo documentation](https://support.apple.com/guide/logicpro/tempo-track-overview-lgcpc0ba44af/mac)): the tempo map lives in the **tempo track** (a global track) as tempo points, and two adjacent points can be joined into a **tempo curve** — a continuous ramp, not a step — so the integration below must handle both from day one. The same map is editable as rows in the **Tempo List** (openable as a floating window, default ⌥⇧T, and as the Tempo tab of the List Editors), and generated in bulk by the **Tempo Operations** window (Edit → Tempo → Tempo Operations, with a nameable *Open Tempo Operations* key command). Smart Tempo sits on top as the write-side: an Adapt-mode recording or import regenerates this map, which is exactly why the item-1 guard must land first.

**Plan, in dependency order:**

1. 🔬 **Tempo-map acquisition** — the load-bearing research question. Three candidate routes, to be tried in this order:
   - **Tempo List window via AX**: the floating Tempo List (⌥⇧T; exact key-command name to be confirmed in the Key Commands window — the learning machinery in `Sources/Logician/KeyCommandRegistry.swift` is the established way in) shows every tempo event as a row: position + BPM. If those rows expose their text via AX the way the region lists do (`Sources/Logician/AXRegions.swift:45`), one read yields the whole map. This is the preferred route: complete, no playhead motion. Open question for curves: whether a curve appears as its two endpoints plus a curve flag or as densified intermediate rows — determines whether curve subdivision happens on our side or is read out directly.
   - **Playhead sampling**: park the playhead at candidate bars and read the control-bar tempo (`AXTransport.swift:82` is position-dependent — the bug becomes the sensor). Complete but O(bars) slow; fine as a verification cross-check, or a fallback bisection when only the range endpoints matter.
   - **MCU beats-display cross-check**: play through the range once and correlate wall-clock against bar/beat from the timecode display — measures the *integrated* map directly. Slow (real time) but ground truth; use it to validate the other two in the research session, not in production.
2. **Piecewise integration**: `barRangeSeconds` grows a tempo-map parameter — seconds = Σ over segments, exact for step changes; tempo *curves* get segment subdivision with a documented error bound. One-entry map ≡ today's formula, so constant-tempo projects take the exact same path. All four callers become correct at once. Cache the map per project with the same delete-on-mismatch discipline as the bank cache (`Sources/Logician/MCUTransportLCD.swift:174`) — and treat any recording made while the project tempo mode is not Keep as a cache invalidation, since Adapt rewrites the map behind our back.
3. **MIDI recording**: per-event offsets integrate the map instead of multiplying one `msPerBeat`. `speed` mode is *disabled* when the map is non-constant — it works by overwriting the control-bar tempo and restoring one value, which against a tempo track is destructive (`ToolHandlersTransport.swift:190, 211`); the result says so and records at 1× instead.
4. **Automation recording**: same substitution for point placement, pre-roll, and convergence budgets (`MCUAutomation.swift:114–117, 399–402, 447`). The playhead-chase verification is already bar-based — it becomes the built-in proof the new math landed points on the right beats.
5. **Docs + guide**: AGENT-GUIDE's "constant tempo assumed" lines (`docs/AGENT-GUIDE.md:19, 172, 290, 408, 491`) flip to describing the map behavior and the one remaining rule (MIDI recording still takes real time).

The item-1 honesty guards are the safety net while this lands: worst case during rollout is a refused operation, never a wrong slice.

**Definition of done:** on a project with tempo changes (step and ramp), `logic_render_track` slices land sample-accurately on the same bars `logic_bounce_range` produces, `logic_record_midi` places notes on-grid across a tempo change, and FINDINGS gains the verified figures the same way the 120 BPM calibration did (FINDINGS.md:634).

## 4. Plugin preset browsing

**Ground truth.** Today's `logic_plugin_preset` is relative-only stepping via the *"Next/Previous Plug-in Setting for topmost Plug-in Window"* key commands, verified by an AX popup label that opaque plugin UIs don't expose (`Sources/Logician/ToolHandlersPlugins.swift:117`). The vpot-browse-and-press primitive the roadmap line dreamed about already exists **twice** — the plugin browser (`Sources/Logician/MCUPluginBrowser.swift:14`) and the send-destination browser (`Sources/Logician/MCUSends.swift`) — with settle/reverify/wrap-detection solved. What does *not* exist is any recorded observation of an MCU view that lists presets: no LCD grammar, no assignment code, nothing in FINDINGS.

**Plan:**

1. 🔬 **Research session first** — two questions against Logic: (a) does the MCU plugin-edit view expose a preset/Setting item anywhere (vpot page, NAME/VALUE toggle)? Log the LCD grammar if so. (b) The AX route we *know* exists: the plugin window header's preset popup menu (FINDINGS.md:906 observed prev/next buttons and a menu) — can the menu be opened and its items enumerated the way other AX menus are (`Sources/Logician/AXBounce.swift:190` does exactly this for the Bounce menu)?
2. **Ship whichever is real** (AX menu route is the likely winner; the vpot route only if (a) pans out): `logic_plugin_preset` grows `list` (enumerate names) and `name:` (jump directly, verified by the label read that already exists). Relative stepping stays as the fallback for plugins whose preset UI is opaque — with today's honest `stepped: false` when nothing can be verified.
3. Master-chain presets come along for free once item 2 lands, since the blocker is the same `selectTrack` gate.

**Definition of done:** an agent can ask "what presets does this compressor have?", jump to one by name, and get an honest failure on plugins that expose nothing — no blind stepping loops.

## 5. Homebrew packaging

**Blocked on the repo going public** — a formula needs a public URL to fetch. When that happens, the shape is standard and small:

1. Tag releases (`v0.50.0` — the version already lives in `Sources/Logician/Support.swift`).
2. A tap repo (`BanneBanning/homebrew-logician`) with a formula that fetches the release tarball and runs `swift build -c release` (build-from-source; `depends_on :macos` ≥ 13 and the Xcode CLT).
3. README install step 1 gains the alternative: `brew install bannebanning/logician/logician`.

Honesty note, same as the install badges: Homebrew replaces the *download & build* step only. The Mackie Control setup and the Accessibility grant are Logic- and macOS-side by nature — no package manager reaches them; `logic_health` remains the doctor.

Not planned: npx/uvx/Docker distribution — Logician is a native Swift binary that must talk to CoreMIDI and Accessibility on the host; a container cannot.

## Parked

- **Localization** (English Logic UI). Scoped during this planning round so the parking is a decision, not an oversight: there are *three* independent English-string surfaces — the centralized key-command table (24 entries, plus 14 leaked inline literals), ~70 scattered Accessibility literals across 10 files, and ~25 MCU LCD literals across 7 files that the old "Accessibility string matching" framing didn't even count — plus locale-sensitive formats (`"Track N “Name”"` parsing, `"dB"` suffixes, `-oo`). Real support means two string tables and a test pass per language against a live localized Logic. Parked until there's a second-language user to test with; the v1 assumption stays in the README.
- **Track-stack freeze rendering** — a Logic limitation, not ours; `solo_bounce` covers stack subtracks and the freeze refusal already names it. Stays a documented limitation.
