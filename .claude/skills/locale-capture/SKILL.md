---
name: locale-capture
description: Capture one Logic Pro UI language's strings for Logician's locale tables. Run once per language after switching Logic's language and relaunching it — the results land in Logician-archive/locales/<code>/ and are merged into the match tables afterwards.
---

# Locale capture — one pass per Logic language

You are capturing what a non-English Logic Pro actually says, so Logician's string
tables can gain this language later. One invocation = one language. The user has
already switched Logic's UI language (System Settings → General → Language & Region →
Applications → Logic Pro) and relaunched Logic with the sandbox project open.

## Ground rules (identical to every live session)

Never save the project. No blind Undo. Never start a second `logician --bridge`
(check `pgrep -fl logician`; talk to the running daemon or start one only if none
exists). Probe for modals after every UI-raising action; a dialog you cannot
confidently identify gets Cancel/`AXCancelButton`, never a guess. Breakage is the
point: an English-built code path failing under this language is a FINDING to record
with its localized evidence — never something to fight or hot-fix mid-capture.
Bash calls that touch AX need `dangerouslyDisableSandbox: true`. Machine sleep kills
AX system-wide — stop and report if the tree goes dark.

## Procedure

Spawn ONE Opus agent with this mission (or do it inline if the session is dedicated):

**0 · Identify.** Run `logic_health` via the in-process harness. Record the full
`logic_ui_language` payload. The `language` code names the output directory:
the archive's `locales/<code>/` directory (a sibling of this repo).
If it reports `en`, stop and tell the user the switch did not take (Logic keeps the
language it launched with — quit and relaunch).

**1 · The AX sample.** The manifest is `Sources/Logician/LogicUIStrings.swift` —
every entry, section by section (`Identifier` entries are locale-independent by
design: verify a handful still match, do not re-capture). For each English literal,
read the live element the entry's doc comment names (safe reads only: control bar,
track headers, inspector strips, menus walked read-only) and record what this
language publishes. Entries whose element cannot be reached safely are recorded as
`"unreached"` with the reason.

**2 · The LCD sample.** Manifest: the LOCALE-RISK section of
`Sources/LogicMCUBridge/MCULCDStrings.swift` and its per-locale re-measurement notes
(volume banner, `parameter:` fragment, `Ins1Pl` cell, send prefixes, the Page
indicator's form and separator, instrument-format suffixes, `-oo`). These need the
MCU plane: enter the views, read `lcd_top`/`lcd_bottom`, restore PN view. Expect most
to be English regardless of UI language (measured for French) — confirming that is
also a capture.

**3 · Key commands.** Open Logic's Key Commands window (⌥K — an advertised
shortcut) read-only. For every name in `KeyCommandRegistry.Name.all`, search and
record this language's row name, and whether the ENGLISH search term still finds it.
Close the window. Learn/bind NOTHING.

**4 · Dialog grammars, safe routes only.** Bounce dialog: open → record title,
button titles, `AXDefaultButton`/`AXCancelButton`, pop-up values → Cancel. Tempo
prompt: import a tempo-bearing scratch `.mid` (SMFWriter fixtures) → record the
localized text and that `action-button-1/2/3` + `supression-checkbox` identifiers
hold → answer button-1 (No) → clean up the imported track. Skip every dialog without
an established safe route; list them as uncaptured.

**5 · Formats.** `logic_list_regions` raw help text (the region-position sentence —
the largest known exposure), a dB readout, the decimal separator, quote characters
around track names (typographic vs guillemets vs other).

**6 · Qualification.** Run the 18-call pass from
`Logician-archive/R4-LOCALE-SESSION-CHECKLIST.md`; classify each call
works / honest-error / **silent-failure** (the only bad class — report those
prominently).

## Output

- `locales/<code>/capture.json` — structured: `{ "<TableSection.entryName>":
  {"english": "...", "observed": "...", "status": "captured|unreached|english-invariant",
  "note": "word order / NBSP / etc."} }` for every manifest entry, plus
  `key_commands`, `dialogs`, `formats`, `qualification` sections. Every observed
  string from a LIVE read — never from translation.
- `locales/<code>/notes.md` — surprises, breakage, and anything the match-strategy
  work must know (reversed word order, moved capture groups, NBSP, new separators).
- Leave the project as found; remind the user to switch Logic back (or on to the
  next language) and that `logic_health` confirms the active one.

## After all languages are captured

The table-fill is a SEPARATE implementation pass (not part of this skill): it
consumes every `capture.json` and extends the match tables per the `UIText` schema
proposed in R4-LOCALE-SESSION-CHECKLIST.md §10 — per-entry strategies (exact,
any-of, reshaped pattern), never blind OR-lists for entries whose structure moved.
