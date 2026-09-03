# Provenance

Where Logician's Mackie Control support came from, and how to check the claim
yourself.

## The short version

Logician drives Logic Pro's Control Surfaces plane by installing a Mackie
Control device (`Sources/LogicMCUBridge/`) and reading the MIDI Logic sends
back — LED states, LCD text, fader echoes, timecode. No confidential Mackie
specification was used to build it. No GPL or otherwise-licensed source code,
tables, or documentation were copied into this project. The implementation
was derived from two things: observing the protocol live, on the maintainer's
own machine, against the maintainer's own copy of Logic Pro; and the general,
widely-published conventions of the Mackie Control Universal protocol — the
same de facto standard that dozens of independent controllers and DAWs
already speak, and that Logic Pro itself lists by name in its own Control
Surfaces setup ("Mackie Designs" / "Mackie Control").

This project has no relationship with LOUD Audio, LLC (owner of the Mackie
and Mackie Control trademarks) or with Apple Inc. See `NOTICE.md`.

## What "observation" means here, concretely

The bridge (`Sources/LogicMCUBridge/Bridge.swift`) opens virtual CoreMIDI
ports, Logic Pro is configured to treat them as a Mackie Control surface, and
the bridge logs and reacts to whatever bytes Logic actually sends. Almost
every constant in this module's tables was pinned down by trying something on
that live connection and reading Logic's own echo back — not by reading a
specification document. Examples, each still visible in the code:

- **LCD banners and mode markers** (`MCULCDStrings.swift`) — the assignment
  codes (`PN`, `IN`, `SE`, `CS`), the `--`/`-` placeholders, the `*` bypass
  marker, the parameter-mode banners. The file's own header records a
  cross-check against a **French** Logic UI (2026-08-30): the protocol-level
  tokens (assignment codes, banners) held unchanged, confirming they come
  from the Mackie Control display grammar rather than from Logic's localized
  string catalogue — while other LCD pages do draw from Logic's own,
  locale-sensitive text, which the same file documents as a hazard for future
  locale work.
- **The bank/page/mode state graph** (assign_track / assign_plugin /
  assign_instrument, page indicators, the plugin-browser trap where turning a
  V-Pot in a bank view opens Logic's plugin browser instead of editing a
  parameter) — mapped by pressing buttons and turning V-Pots against a real
  session and recording what Logic's LCD and LEDs did in response. None of
  this is externally documented anywhere the maintainer found; it was learned
  by using the surface.
- **The fader/V-Pot/LED wire format** (note on/off for buttons and LEDs, CC
  for V-Pots and 7-segment digits, pitch bend for faders, channel pressure
  for meters) uses the Mackie Control Universal convention that is, at this
  point, public common knowledge in the control-surface world — published in
  countless MIDI implementation charts, DAW manuals, and forum write-ups
  across many unrelated vendors and projects, not sourced from any single
  proprietary document. `MCUMeter.swift`'s header names this explicitly as
  "the Mackie Control convention" and documents that the meter *grammar* was
  implemented from that public convention and unit-tested against synthetic
  bytes, but was **never confirmed against live meter data** — a live test on
  2026-08-28 found that Logic's virtual surface does not emit meter bytes
  under its default Control Surfaces configuration, so that code path is
  honestly labeled as decoded-but-unconfirmed in the tool's own output
  (`meter_feed: unavailable`).
- **The virtual MIDI port unique IDs** (`0x4C4D4330`–`0x4C4D4333`, ASCII
  `"LMC0"`–`"LMC3"`) are not a protocol constant at all — they are arbitrary
  values the maintainer chose for this project's own ports, fixed so a port
  recreated after a crash keeps the identity Logic's key-command bindings are
  scoped to. They carry no Mackie provenance question.

## The Mackie Control note and message layout

The button, LED and display numbers Logician speaks are the Mackie Control
Universal layout — the de facto standard that controllers, DAWs and open
implementations across the industry have shared for two decades, and that
Logic Pro itself offers by name in its own Control Surfaces setup. Logician
implements that convention; it does not reproduce anyone's document or code.
What Logic actually does with each message was established on the live
connection described above, and every tool built on top of it verifies its
own writes by reading Logic's echo back before reporting success.

## How to check this yourself

- `Sources/LogicMCUBridge/` is the entire Mackie Control implementation.
  Every non-obvious constant carries a doc comment; most name a date and what
  was observed.
- `CHANGELOG.md` records, dated, what was verified live at each step, from
  the first MCU bridge (v0.12.0, 2026-08-25) onward.
- `Package.swift` declares no third-party dependencies — nothing was vendored
  in from another control-surface project.
