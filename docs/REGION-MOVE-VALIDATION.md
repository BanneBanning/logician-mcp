# Clipboard move validation — 2026-09-11–12

These checks exercised the local MCP server against an explicitly authorized
duplicate project in Logic Pro 12.3.1 (build 6682), English UI. A separate copy
of the on-disk project was made before editing; that backup does not capture
unsaved changes. No project was saved by the test harness. Live probes ran
outside the automated test suite.

## Observed results

- Moved one MIDI region from bar 41 to bar 48 on its own track. Copy/Paste
  was verified before Delete. The rendered region total stayed at 54, and
  the region ended at bar 51 beat 3, as predicted by the signature map.
- Moved it to another instrument track at bar 48. The MIDI Event List cells
  matched the preceding reading exactly.
- Moved it back to the original track and bar 41. Its Event List cells and
  every published Region inspector row matched their pre-test readings exactly.
- Tried a move onto the source's occupied interval: refused before Paste.
- Tried a MIDI region whose boundary included divisions/ticks: refused before
  Paste. The ordinary bar/beat reader alone would have hidden this distinction.
- Tried an audio-region move: refused before Paste.

The project contains 4/4 and 5/4 sections and a collapsed track stack. Its ten
hidden rows remained outside the arrangement witness, and the results reported
that coverage limit. Project-wide Deselect All established selection exclusivity.
The MIDI note's displayed position and length changed with the meter at the new
location; this was not treated as a byte-for-byte event comparison across meters.

## Independent content verification

The automatic witness now also compares Note events independently of the
clipboard: positions and absolute note ends relative to the region, attack and
release velocities, articulation, and the other published event columns. Published
Region inspector rows must match, and the original is reread before Delete.
All event filters are enabled for the read, with Content link mode and complete
columns; the original display settings are restored afterwards. A stale clipboard
with different notes cannot pass on matching region metadata alone.

The content witness passed a same-track move from bar 41 to bar 48 and a
cross-track move at bar 48. The latter started with the Notes filter disabled:
the tool exposed the notes for comparison and restored the disabled filter
afterwards. This exercises a view that would otherwise hide the very contents
being verified.

On September 12 the region was returned to its original track at bar 41 through
the content-verifying path. With the original Event List columns restored, every
raw event cell matched the pre-test reading. All originally read named region
parameter values matched too. The inspector also exposed Flex set to off
and additional placeholder rows, so the complete inspector row arrays were not
identical to the earlier baseline. The temporary event-view options were reset
and List Editors was closed. No save command was sent.

## Limits

This is not a binary comparison of Logic's internal region representation. Aliases,
embedded automation and other undisplayed properties, plus rendered sound, remain
outside the witness. Non-Note events currently refuse rather than being ignored.

Audio moves, fractional source boundaries, non-quarter-note meters and unreadable
signature maps currently refuse. Ordinary Copy and the separate relative Nudge
tool retain their documented overlap risks. Copy/Paste and Delete are separate
undo steps; no automatic Undo or command replay is attempted after failure.

## Regression checks

`RegionTransferTests` inject failures at Copy, project checks, copy verification,
source selection, cancellation and Delete. They also check overlaps, ambiguous
sources, same-count boundary changes and variable-meter length calculations.
`BoundedProcessTests` exercise blocked output, cancellation and forced child
cleanup. Socket deadline tests use local sockets without operating Logic.

`MIDIRegionWitnessTests` cover changed notes with identical arrangement metadata,
absolute note ends across changing meter, separate attack/release velocities,
row reordering, duplicate notes, unread rows and unsupported event types.
Audio, non-Note MIDI and sub-beat support need equivalent compatibility checks
before the current refusal boundaries can be relaxed.

## Final local validation — September 12

- Targeted process, socket, transfer and MIDI-witness checks passed (20 tests).
  After adding the required frontmost guard, the affected menu and transfer
  checks passed (16 tests).
- `swift test`: 2,394 tests, zero failures, 19.419 seconds of test execution.
  The preceding full run caught the missing frontmost guard and its call-site
  expectation; both were corrected before this final run.
- `swift build -c release -Xswiftc -warnings-as-errors`: passed, 94.91 seconds.
- Installer shell syntax and Homebrew Ruby syntax passed. Five isolated checks
  of the installer's link helper passed, including existing-file protection.
- The bridge wire-format harness matched 32 commands and `state.json` against
  HEAD, with MIDI endpoints replaced by stubs.
- Packaging/version and embedded-guide checks passed in the full suite.
  Release MCP initialization and tool enumeration passed without operating Logic.
- All 35 local README/INSTALL links and anchors resolved; `git diff --check`
  passed. These checks do not constitute a clean-machine Homebrew install or
  establish the availability of external web links.
