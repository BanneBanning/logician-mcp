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

## What is genuinely uncertain, for the maintainer to answer

This document deliberately does not paper over gaps. The following could not
be attributed with confidence from the repository's history alone:

1. **The button-name-to-note-number table**
   (`Sources/LogicMCUBridge/Bridge.swift`, `public let buttonNames`) already
   existed, complete, in the earliest commit that carries fine-grained
   history (`e95e55a`, "Snapshot: research state at v0.26.0" — itself a
   squashed snapshot of earlier, untracked work). The project's research log
   documents live verification for *some* of these entries against Logic's
   own state — for example `click` (note `0x59`) was cross-checked against
   Logic's Metronome Click checkbox and LED, and the transport buttons
   (`play`/`stop`) were confirmed via the play LED and a moving timecode
   display — but it does not show a session where every single entry in the
   table (`rewind`, `forward`, `nudge`, `drop`, `replace`, `flip`,
   `name_value`, `smpte_beats`, the `assign_*` codes, and others) was
   individually pressed and its effect on Logic observed and logged. The
   Mackie Control Universal note-number layout this table matches is itself
   extremely widely published and reimplemented across the industry, which
   is consistent with "typed in from common knowledge, verified where it
   mattered for a shipped tool" — but the repository's own history does not
   let this document say that with certainty for every entry. **Open
   question for the maintainer:** were any of these note numbers copied or
   adapted from a specific external document, project, or piece of code
   (rather than typed from memory of the public convention, or measured
   live)? If so, that source needs to be named here, and its license checked
   against this project's MIT license before v1.0.0 ships.
2. **Any earlier, untracked research** that predates `e95e55a`. That commit
   is explicitly a snapshot ("research state... before productization
   restructure"), so whatever informed the pre-snapshot exploration is not
   reconstructable from `git log` alone. If the maintainer consulted any
   specific external reference during that period — a forum thread, another
   project's source, a leaked or published Mackie document — it should be
   named here even if it was only used for orientation and nothing was
   copied.

Nothing else in the Mackie Control implementation surveyed for this document
carries an unattributed origin: the LCD string tables, the mode/page state
machine, the bank-scanning and channel-lookup logic, the send-view layout,
and the plugin/instrument parameter paging were all established through
logged, dated, live experiments against the maintainer's own running Logic
Pro, recorded (at the time) in the project's research log and, since,
in `CHANGELOG.md` and in the doc comments of the files listed above.

## How to check this yourself

- `Sources/LogicMCUBridge/` is the entire Mackie Control implementation.
  Every non-obvious constant carries a doc comment; most name a date and what
  was observed.
- `CHANGELOG.md` records, dated, what was verified live at each step, from
  the first MCU bridge (v0.12.0, 2026-08-25) onward.
- `Package.swift` declares no third-party dependencies — nothing was vendored
  in from another control-surface project.
