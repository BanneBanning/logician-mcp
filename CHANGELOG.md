# Changelog

## 1.0.0 — unreleased

The first public release, staged and waiting on the go-public decision.

Logician gives any MCP client verified control of Logic Pro: 84 typed tools across
mixing, plugins (third-party parameters included), regions, MIDI composition and
editing, tempo and meter maps, automation, markers, and dialog-free audio export —
with every render coming back as audio the agent can listen to.

### Highlights

- **Verified writes everywhere.** Compare-and-set with readback against Logic's own
  control-surface echoes; refusals name the fix or the working alternative; results
  carry `success` / `verified` / `state` / `warning` under one documented contract.
- **The master chain is addressable.** `Stereo Out`, auxes and buses work by name for
  volume, mute/solo, sends, insert bypass, plugin parameters and preset browsing.
- **Sends are a round trip.** `logic_add_send` creates and levels a send in one verified
  call, and `logic_remove_send` takes one out the same way — the slot read first, a
  mismatch with what the caller named refused before anything moves, the removal proven
  by re-reading the send list — so undoing a send no longer means a blind `Undo`.
- **Tempo and meter maps are read, integrated and editable** — bar math follows the
  project's actual tempo track and signature list; Smart Tempo mode is checked before
  recording so an Adapt-mode project is refused rather than rewritten.
- **Audio-carrying results**, inline for multimodal clients and as fetchable MCP
  resource links for everyone else; renders live under `logician://captures/`.
- **Blind listening.** `logic_bounce_range`, `logic_render_track` and `logic_evaluate_change`
  take `blind: true`: the result keeps its audio, its paths and every safety field and defers
  its measurements of that audio into a `sealed_metrics_path` you read after saying what you
  heard — so a multimodal model describes the sound instead of paraphrasing the metrics.
- **Modern protocol**: 2026-07-28 era (`server/discover`, per-request versioning,
  cache hints) with legacy `initialize` down to 2025-03-26; progress notifications and
  cancellation on every long-running tool; the server is inert until first use.
- **A whole arrangement in one call.** `logic_import_midi` writes many named tracks as a
  byte-exact Standard MIDI File and drives Logic's own importer - seconds instead of the
  music's own length, no Smart Tempo hazard, verified by a track/region census diff and
  optionally note for note out of the Event List. Per-track `to_track` composes onto the
  tracks the user already has, so the material plays through their instruments instead of
  the default patches Logic's importer would pick: destinations are resolved before the
  import runs, each routed region is moved off its temp track and the emptied temp track
  removed, and a move that does not finish is reported as `partial` with `restored: false`
  and every leftover named.
- **Typed discovery.** `logic_find_tool` searches every tool by keyword (BM25 over names,
  descriptions and argument text) and answers with the full typed definitions — schemas and
  safety annotations included — naming the toolset that holds any match this session does
  not offer. In every toolset, never touches Logic.
- **`--toolsets`** launch flag for clients with hard tool caps (`core` = 42 tools);
  the full surface is designed for client-side tool search.
- **Plugin writes at human speed.** "More bass around 500 Hz" is now ONE call —
  `logic_set_plugin_parameter {track_name, plugin_name, parameter, target_value}` finds
  the insert itself and reports it as `resolved_slot` — and the call lands in well under a
  second warm instead of the three calls and 15.8 s it used to take (measured on the
  reference project: 15 773 ms → 4 785 ms for the old three-call chain, 4 651 ms → 934 ms
  for a standalone write, 3 866 ms → 474 ms for a second write on the same plugin). The
  time came out of WAITING, not out of checking: the surface is no longer walked back to
  its neutral view between plugin calls (the restore is deferred and settled before the
  first thing that needs it, or at shutdown), the parameter's page and encoder are
  resolved from the cached name rows instead of by paging through the plugin twice, the
  Pan-view wait exits early when the display already shows what it is waiting for, and the
  write path now saves the parameter names it reads — so a cold write stops costing six
  indicator fades every single time. Every verification is where it was: the cell under
  the encoder is matched against the live LCD before it turns, a disagreement drops the
  cache and walks the pages for real, and an ambiguous `plugin_name` or parameter is
  reported rather than guessed.
- **Adding a plugin works on instrument tracks, and is 41% faster.** `logic_add_plugin`
  used to refuse every software-instrument track carrying an instrument — it compared the
  surface's plug-in list against an Accessibility reading that counts the INSTRUMENT slot
  as one more insert, and reported the mismatch as "the PL view is pointed at another
  channel" for a strip that was correctly selected. It also failed correct writes whenever
  Logic abbreviates the name it publishes (`ParEQ` for `Parametric EQ`), leaving the plugin
  in place while saying it may have landed elsewhere. Both are fixed at the source: the
  comparison now reads the strip's audio-effect inserts with the instrument separated out
  by geometry, and names are matched the way Logic actually abbreviates them. In the same
  pass the surface stops walking home after an insertion (the deferred restore the read
  tools already use) and the blind one-second wait after the confirming press became a
  positive check — the surface reaches the edit view in under a millisecond, and what that
  second really insured against, a plugin still instantiating, now waits for the slot to
  name it rather than for a duration to elapse. 8.8 s → 5.2 s warm, with every readback,
  LED proof and cross-check exactly where it was.
- **The focused channel is checked, not assumed.** Selecting a track HEADER and Logic's
  focused CHANNEL are two different selections, and the surface's plugin and send views
  follow the channel: after a headerless strip (`Stereo Out`, an aux, a bus) is addressed,
  the channel stays there while the previously selected track's header stays selected —
  which once let `logic_list_inserts` return Stereo Out's chain attributed to the selected
  track, `verified: true` (observed live 2026-08-31), and would have let a write land on
  the wrong plugin. The already-selected fast path now consults the surface mirror (the
  SELECT LED plus the pan-view name cell) and the process's own record of the last
  verified selection; a divergence is realigned with a real track reselection — a surface
  channel select provably moves the selection while the plugin-list view stays latched to
  the strip it last showed, so the realign is the reselection the manual repair uses —
  reported in results as `selection_readback_route: "realigned_ax_reselect"`, and a
  divergence that cannot be realigned is refused with both halves named, never read
  through.

- **The bridge daemon shrugs off misbehaving clients.** Every connection to the
  command socket is served on its own deadlined thread: a client that connects and
  never finishes its command is dropped after ten seconds instead of wedging the
  daemon for every later caller (the failure that silently took a long-running
  daemon out mid-session on 2026-08-31), and a client that vanishes before its
  reply arrives costs one closed connection rather than the whole process, which
  previously died on the unhandled SIGPIPE. Commands still run one at a time, so
  control-surface writes never interleave.

- **The MCP server survives a vanishing bridge daemon.** The server's side of the
  command socket now suppresses SIGPIPE on the connection itself, so a daemon that
  restarts, crashes, or cuts the connection while a command is still being written
  costs one clearly-reported failed call — not the whole MCP server, which
  previously died on the unhandled signal.

- **The send list proves which page it is reading.** `readSends` walked the send
  view's pages by pressing page-right blind, so a press Logic swallowed left it
  re-reading one page under three different numbers (sends 1, 3, 5) — and a
  mid-repaint frame could hide an occupied slot 1 entirely. Removals compared that
  garbage `before` list against a good `after` and reported `verification_failed`
  on removals that had succeeded. Every page read is now settled and must name its
  own first slot (`Sen3In` is the second page, and nothing else is) before it is
  believed, a swallowed press is retried once and then reported, and the same
  proven advance drives paging for send levels and the surface view tool.

- **Bouncing a bar range costs ~2.2 s, whatever the bars.** The bounce dialog's
  position fields turned out to be text elements in disguise: focusing one and
  typing the bar number is a true absolute jump (41→12 in 53 ms, beat and tick
  zeroed for free), where the old route stepped a slider one bar per write and
  paid for the distance — 53–68% of every call, and more the longer the project.
  Typing into a modal dialog carries its own proof: focus is written and read
  back before any key is posted, only digits are typed, the commit key is Tab
  (never Return), the landing is verified against Logic's own display, and any
  failure falls through to the slider route, which now paces on the field's
  repaint instead of a fixed sleep. 8.4–11.8 s → 2.1–2.4 s measured, byte- and
  frame-identical output, and `logic_export_stems`/`logic_evaluate_change`
  inherit the same jump on every bounce they make.

- **Closing the project stops vouching for a close it could not read back.**
  `logic_close_project` computed `verified` from Logic's document list coming back
  empty — and an AppleScript read that FAILED returned the same empty list as a
  project that had really gone, under a `success: true` that no failure path could
  change. A close attempted while Logic was modal, wedged, or merely too busy to
  answer an Apple Event therefore reported `verified: true, remaining_documents: []`
  for a project that was still open. The reader now says which of the two it hit, and
  every project tool that shares it — save, open, duplicate, reset — refuses instead
  of reading silence as an empty Logic. The close itself is now `logic_reset_to`'s
  close rather than a second, dialog-blind copy of it: issued off-thread while an
  Accessibility loop walks whatever Logic puts on screen, so a dialog is either
  answered from the measured table (**Don't Save**, and only when you asked for
  `saving: 'no'` — with `saving: 'yes'` that alert is reported and never pressed) or
  reported verbatim, inside a `timeout_seconds` budget (5-300, default 30) instead of
  a deadlock that used to end at osascript's own ~120 s timeout with the dialog still
  up and every later tool locked out. The blind 1 s sleep goes with it: the reset's
  200 ms poll on the same signals replaces it, so a close slower than a second is
  waited out instead of reported unverified. `expected_project_path` is now honoured
  for a never-saved project, which used to skip the guard silently — precisely the
  project `saving: 'no'` destroys most — and the four per-project caches are cleared
  and listed in `caches_cleared` exactly as the reset does, because a close and
  reopen of the same path keeps the cache scope token identical and a bank map
  measured against tracks that only existed unsaved would otherwise survive and be
  trusted. The description now sends close-then-reopen to `logic_reset_to` or
  `logic_open_project`, which fold the close in and save a round-trip. Unit-tested
  (21 new pure tests for a tool that had none) and NOT live-verified: closing the
  only open project has no verified inverse, so it is never run against the sandbox.
- **Closing a plugin window proves that THAT window closed.** Both close tools
  verified a press by asking whether *any* window from a before-snapshot had gone
  away, so a press that silently failed while some unrelated Logic window closed
  inside the same 2 s poll returned `verified: true, state: "closed"` about a
  window still on screen. `logic_close_plugin_window` now checks the exact window
  it pressed — by element identity and by title — and a window still up afterwards
  comes back `success: false, verified: false` naming the window, never as closed;
  `logic_close_plugin`, which presses a toggle and can only name the window by the
  track's title, checks that one of THOSE windows went away. Both look before they
  wait: the close press already blocks until Logic has torn the window down (the
  window was gone on the first look 7 out of 7 profiled runs), so the 0.1 s sleep
  that ran before the first look is gone and a retry now costs 25 ms instead of
  100 ms, with the same 2 s deadline. `logic_close_plugin_window` measured
  125 ms → 27-32 ms warm against the live project, the honest floor being the
  one window enumeration that IS the verification.

- **`logic_close_plugin` no longer opens a plugin to tell you it was closed.** The
  insert's open button is a toggle, so calling it on an already-closed plugin used
  to open the window, leave it on screen for ~2.3 s and close it again before
  refusing — 2.63-2.79 s of visible side-effects from a tool that advertises itself
  as idempotent. It now reads the window list first (1 ms, a read it was already
  making) and returns a verified `already_closed` no-op without pressing anything:
  2.63-2.79 s → 98 ms measured live, all of what is left being the inspector walk
  the tool needs to name the insert at all, and no window appears on screen. When
  a press IS needed, one poll now watches for both of its possible outcomes
  instead of waiting out a full 2 s disappearance before asking whether a window
  appeared, and a real close measured 261 ms → 125 ms.

- **The refusal rule for `logic_close_plugin_window` is the rule it applies.** The
  tool description, the agent guide and the error all said it refuses "any window
  with a document", while the code has only ever tested the window's Accessibility
  subrole: a plugin window is closable even when it carries the project document
  (Drum Machine Designer does), and the project window and Mixer are refused
  because they are `AXStandardWindow`. All three now say that, and the refusal
  names the subrole it found.

- **Making a track takes a third of a second, not nine.** `logic_create_track`
  spent 8.9 s of a 9.3 s call looking fifty times for a *Create New Track* dialog
  that Logic 12.3.1 never raises for the *New Software Instrument Track* and *New
  Audio Track* commands — 200 looks out of 200 came back empty while the track was
  created anyway. There is one poll now, over the track list the tool already
  verifies against, and it looks before it sleeps: the new row is there on the
  first read (Logic blocks that read while it builds the track), so nothing is
  waited for at all. The dialog question rides along on the miss path, so a Logic
  that does prompt is still answered — within milliseconds instead of after a fixed
  sleep. Measured live: **9 262 ms → 276-300 ms for a software-instrument track,
  9 119 ms → 295 ms for an audio track.**

- **The create result names the track it made.** The next call in the recipe is
  `logic_load_instrument {track_name}`, and the result used to hand back only the
  whole track list and two counts — so the agent diffed two listings or guessed
  Logic's auto-name. `created_track {track_number, track_name}` now comes back,
  read off the row Logic selects, which is also the row that proves the create:
  measured against a project where the new track landed at position 2 rather than
  at the end, so "the last row" would have been the wrong answer.

- **A created track that is off-screen is no longer reported as a failure.** Only
  rendered track rows can be counted (19 of 29 on the reference project), so a
  project scrolled away from the insertion point could answer *"No new track
  appeared"* about a track Logic had just made — and the obvious next move on that
  answer leaves two tracks behind. The verification compares the named row set the
  way `logic_delete_track` always has, so an insertion that pushes another row out
  of the viewport is still seen; and when the count has not moved while the listing
  admits it is partial, the result says `created_not_visible` with `verified: false`
  and asks you to scroll, which is the strongest true statement this plane can make.

- **Deleting an empty track is under a second.** `logic_delete_track` waited out the
  full 2.5 s timeout of the "Delete Track and Regions?" alert on every delete, to
  prove an alert that only ever appears when the track still holds regions: 2.6 s of
  a 3.3 s call, 7 runs out of 7. The alert question now rides inside the loop that is
  already watching for the row to disappear, so the wait ends when the deletion lands
  and the full deadline is only spent while the row is still listed — which is the
  one state a modal could explain. A track that does hold regions is answered exactly
  as before, Cancel on any doubt. Measured live: **3 230-3 399 ms → 406-656 ms.**

- **Creating, duplicating or deleting a track forgets the control surface's bank
  map.** `bank-cache.json` is a picture of which track sits in which bank of eight,
  and it is scoped by project path and Logic version — neither of which moves when
  the track ORDER does. Nothing was ever mis-addressed (a cached bank is checked
  against its expected top row before it is trusted), but the discovery came later,
  inside whichever surface call happened to be next, which then paid a full ten-bank
  rescan — on top of banking to the stale entry to disprove it first. The file is
  deleted at the moment the order changes instead, which is the cheaper answer as
  well as the honest one: the first surface call after a create measured
  **11 854 ms with the stale map still in place against 6 796 ms without it**.
- **A duplicate proves it opened the COPY, and proves it by path.** `logic_duplicate_project`
  verified its open by document NAME against the destination's basename, so duplicating into
  another folder — `destination_path: "~/Desktop/Sandbox/Song.logicx"`, which is exactly what
  that parameter is for — matched the still-open ORIGINAL on the first poll tick and answered
  `verified: true` about a copy Logic had not opened, sending the agent's destructive
  experiments into the user's own project. The shared open now matches Logic's document list
  by PATH, so `logic_open_project`, `logic_new_project` and `logic_reset_to` are fixed by the
  same two lines. That poll also stopped spawning an AppleScript document-list read every
  500 ms while WAITING for the save-changes modal: AppleScript is the one plane that blocks
  while Logic is modal (~120 s, far past the loop's own 30 s deadline) and the loop that
  answers the modal was stuck inside the read. It now looks on the Accessibility plane first
  (one window walk plus one document path, 1–2 ms) and spends the round trip only once those
  cheap signals allow it — the rule `logic_close_project` was rebuilt around — which also
  retires the blind 500 ms sleep that ran BEFORE the loop's first look, in favour of the
  close's measured 200 ms pacing.

- **Duplicating a project stops writing the user's project behind them.** `if_current_modified`
  defaulted to `"save"` here, so duplicating a modified project committed the in-progress edits
  to the original — while the same result said the original was untouched — on the one tool the
  guide tells an agent to reach for BEFORE making changes nobody approved. The default is now
  `"fail"`, as `logic_open_project` and `logic_new_project` have always been, and the refusal is
  made from the document list the tool has already read, BEFORE the copy is written: it used to
  be made inside the open, after the copy was on disk, and the throw discarded the result
  carrying the copy's path, so the obvious retry hit `'…' already exists` on a file nobody had
  been told about. The result now says what actually happened to the original —
  `original_written_to_disk`, `original_unsaved_changes_discarded`, and the `dialogs_answered`
  receipt the open builds and the duplicate used to drop, which is how a caller learns Logic
  asked and what was answered. A `destination_path` whose folder does not exist yet is created,
  as the new-project path already did; an open that fails with the copy already on disk names
  the copy's path and says the copy was made and the open was not. Unit-tested (35 new pure
  tests for a tool that had none) and NOT live-verified: it writes a project copy to disk and
  changes which project is open, so it is never run against the sandbox.
- **Region edits establish the keyboard focus they need, so a copy is a copy.** Logic's
  Cut/Copy/Paste/Nudge/Delete/Select-All act on whichever area holds the keyboard focus,
  and with the focus off the Tracks area they do nothing at all — silently. Measured:
  three copies in a row fired Copy and Paste, changed nothing, and refused after 5.7 s
  blaming a modal dialog that was not open. `logic_copy_region`, `logic_move_region`,
  `logic_split_region`, `logic_select_regions` and `logic_delete_region` now prove the
  Tracks area holds the focus before the command goes out — a probe of Logic's focused
  element first, and only when it is elsewhere a track-header write to bring it back
  (the result says which, under `key_focus`). When a command still does nothing, the
  refusal names what the focus actually was and reads Logic's window list, so "check
  for a modal" is an observation instead of a guess.

- **A copied region lands on the bar line, not a third of a beat past it.** Paste lands
  at the playhead exactly, while the control bar's position display publishes whole bars
  and beats — so a park that reported `verified: true` sat at `N 1 3 81` in 8 of 8
  measured calls, and a marker created at that playhead came out a whole beat late.
  `logic_copy_region` now parks with the same rewind-and-step routine
  `logic_split_region` and `logic_import_midi` use, reads the sub-beat position back off
  the control surface, and refuses BEFORE Paste when it cannot prove the playhead is on
  the grid. The park costs stepping from the project start (~126 ms per bar); two blind
  waits paid part of that back — the 0.4 s sleep after Copy is gone (the 0.9-5 s of
  Accessibility work that follows it was always the real wait), and both the paste and
  the delete verification now look before they sleep instead of after: the pasted region
  was already in the arrangement map on the first look in 5 of 5 runs, the deleted one
  gone on the first look in 3 of 3, and a command that really did nothing is refused in
  ~2 s instead of 5.7. Measured live after the change: a cross-track copy onto the bar
  line in 2.8 s, a delete in 0.8-0.9 s.

- **`logic_delete_region`'s refusal stopped over-promising.** Its "more than one region
  selected" guard counted the selection twice — quoting a number that had never gated
  anything — and claimed `restored: true` although the call had already cleared every
  other region's selection. One count now, the tested value in the message, and a
  `restored` flag that matches what the call actually left behind.

- **A duplicated track tells you which row is the copy.** `logic_duplicate_track` used
  to report only the name you passed in, and that name does not address the copy in
  either direction: keep it and the project has two rows answering to it, so the very
  next call comes back *"Track name 'Crash' is ambiguous; it matches track numbers 26,
  27"*; let Logic auto-increment it — `Audio 9` copies to **`Audio 10`** — and the name
  you passed in now belongs to a different track. `duplicate {track_number,
  track_name}` now comes back, read off the row Logic selects, along with the before and
  after counts. Proved live: duplicating `Crash` and then `Audio 9`, the copy was deleted
  again using nothing but the two fields the result had just reported, first try, both
  times.

- **A copy that lands off-screen is no longer reported as a failure.** Success was the
  visible row count rising, and this project renders 19 of its 29 rows — so a duplicate
  inserted outside the viewport came back `success: false` on a track that exists and
  carries a full copy of the source's regions. It is judged on the named row set now,
  the same way `logic_create_track` is, and the honest answer when the listing has proved
  itself partial is state `duplicated_not_visible` with a warning to scroll and re-read,
  never "nothing happened".

- **Duplicating a track takes three quarters of a second, not one and a bit.** The
  verification slept 300 ms before its first look, then found the copy on that first look
  every single time, and a full track-list walk was made purely to count rows that the
  selection one line earlier had already read. Both are gone: it looks first, and reuses
  the walk. Measured live, same machine, same track, old shape against new: **1 036–1 187
  ms → 703–816 ms** (mean 1 088 → 753, −31%), with the verify loop down from 445–458 ms
  to 253–270 ms and still exiting on its first look, 6 runs out of 6.

- **`logic_delete_track`'s pre-fire guard checks the number too.** It re-read the
  selection and compared its NAME to the requested one — which decides nothing on the
  state a duplicate creates, where two rows share a name. It now also compares the track
  number the selection just resolved, so "the right row is selected" means the right row.
- **`logic_find_tool` answers in about a millisecond instead of twenty-two.** The search
  built its whole BM25 index from scratch on every call — 19.3 ms of a 22 ms call spent
  re-deriving a constant, because the tool surface is an array literal that nothing at
  runtime can change — and the registry itself was constructed three times per call plus
  once per match, since the "that tool exists but is not in this session's toolsets"
  sentence asked it "is this a real tool?" for every hit (13 constructions of all 84
  tools for one `limit: 10` answer). Index and registry are now each built once per
  process, the tokenizer scans UTF-8 bytes instead of walking Swift `Character`s, and the
  exclusion note tries its two cheap set tests before the registry scan. Measured over
  stdio across seven fresh processes: the first search in a process 7.1-8.6 ms (was
  22.4-24.9), every search after it 0.4-1.0 ms (was 20.6-23.6), a `limit: 10` search with
  full schemas 0.9 ms (was 23.0). The ranking is unchanged to the digit —
  `scripts/retrieval_probe.py` still 53/53, and a 60-query parity run against it reports
  zero order and zero score differences — and a new test tokenizes every document in the
  real corpus both the probe's way and the byte scan's, so the two cannot drift apart
  quietly. Three size claims that were never measured are now measured: the corpus is 84
  documents and 132 KB (not 82 and ~145 KB), ten full definitions are 26.7-52.6 KB of a
  171.6 KB surface (not ~15 KB of ~145 KB), and `schemas: false` saves 33-52%, mean 44%,
  rather than the guide's "about half".
- **`logic_delete_region` now makes the selection exclusive instead of hoping it is.**
  Logic's Delete takes every selected region in the PROJECT, and this server's
  arrangement map holds only the track rows Logic has RENDERED — on the reference
  project that is ten hidden subtracks under a collapsed stack. The old guard counted
  the selection over those rendered rows and called the answer "project-wide", the
  exclusive-clear reached no further, and the after-check compared region counts on the
  target track alone, so a Delete that also took regions off hidden rows passed all
  three and came back `success: true, verified: true`. Now Logic's own project-wide
  `Deselect All` fires first and has to be PROVEN — the rendered selection is watched
  falling to zero — before the one named region is selected back, and the result carries
  `selection_scope: "project"` with that receipt. Without that command in the key
  command registry the tool refuses when any row is provably hidden, naming the rows and
  both ways to fix it, and says `selection_scope: "rendered_rows"` with a warning when
  nothing proved a row hidden. The after-check now compares the region total across
  EVERY rendered row, so collateral damage is a loud failure instead of an invisible
  one. Measured live after the change (sandbox project, 19 rendered rows, 54 regions, ten
  rows hidden): a delete of a region copied in for the purpose took 2.78 s cold and
  2.87 s warm — ~0.8 s more than before, all of it the clear, its receipt and the
  re-selection — and the refusal, taken before any write, came back in 0.39-0.42 s
  naming rows 10-19.
- **`logic_edit_event` counts the Event List once, and cleans up after itself.** Adding
  or deleting one note used to come back `verification_failed` on a write that had
  LANDED — and a failed `create` left the note it had just made sitting in the region
  while telling the agent nothing had happened. The cause was two counts of one list:
  when the list grows, Logic publishes the new size straight away and leaves the newest
  row undrawn, with every cell but its Status empty, so the row count and the parsed
  rows disagreed by exactly one. There is one count now — Logic's own `Number of Items`,
  cross-checked against the rows it published — an undrawn row is counted and reported
  as unreadable rather than silently dropped, and a `create` that cannot be verified
  deletes the note it made (found by its own content, never "whatever is selected") and
  says so in `restored`. In the same pass the tool got **twice as fast**: five blind
  sleeps became positive checks against the things they were insuring against (a
  stepper's effect is readable in 0-4 ms, not 90; a row's selection in 0 ms, not 350),
  and the write loop asks the table for the one row it is editing instead of re-reading
  all of them — which is also what makes the cost of a note edit independent of how many
  notes the region holds. Measured live on the same 25-note region as before:
  a velocity move 4 256 ms → 1 908 ms, a transpose 2 580 ms → 1 763 ms, a delete
  2 646 ms → 2 129 ms, and an add 7 752 ms → 4 898 ms — the last two of which used to
  report failure on work that had landed. A note can also be moved anywhere in Logic's
  own 1-240 tick range now: the position steppers turn out to take the same ten-unit
  coarse gear pitch and velocity do (100 ticks in 10 writes), and the step budget is the
  distance to travel, where a flat 80 used to spend ~21 s stepping before refusing a
  legitimate move. And a call with a bad argument is refused before the tool selects
  anything, instead of changing the user's region selection on its way to saying no.

- **`logic_copy_region`, `logic_move_region` and `logic_split_region` stopped guarding on
  rows they cannot see.** Cut removes every selected region in the PROJECT, Copy puts
  every one of them on the clipboard for Paste to put down, Nudge moves all of them and
  Split cuts all of them at the playhead — while the arrangement map this server reads
  holds only the track rows Logic has RENDERED, which on the reference project is 19 of
  29 with ten subtracks hidden under a collapsed stack. All three counted the selection
  over those rendered rows and called it exclusive, and all three checked their work
  against the target track's region count alone, so an edit that also reached four
  regions off screen came back `success: true, verified: true`. They now do what
  `logic_delete_region` started doing: Logic's own project-wide `Deselect All` fires
  before the destructive command and has to be PROVEN — the rendered selection is watched
  falling to zero — before the one named region is selected back, and the result says
  `selection_scope: "project"` with that receipt. Without that command in the key command
  registry they refuse when any row is provably hidden, naming the rows and both ways to
  fix it, and otherwise proceed with `selection_scope: "rendered_rows"` and a warning.
  The after-checks count the whole project too: a split must raise the rendered region
  total by exactly 1, a nudge and a cut-paste must leave it alone, a copy must add
  exactly 1 — so a region swallowed by an overlay, or one that a Cut took and the Paste
  never brought back, is a loud failure instead of a silent one. Two `restored: true`
  flags that were fictions — both claimed after the call had already cleared every other
  region's selection — now say `false`. Measured live on the sandbox project (19 rendered
  rows, 54 regions, rows 10–19 hidden), warm: a copy onto a bar line 2.3 s, a one-bar
  nudge 2.6–2.7 s, a split 3.9 s. The clear costs about 0.9 s of that in every call, and
  it was measured as its own two parts on the same project: Logic's `Deselect All` with
  its proof 464–487 ms, the re-selection pass 388–440 ms. There is no fast path that
  skips it, and that is deliberate: the coverage verdict is `partial` or `unknown` and
  can never be `complete`, because Accessibility publishes what is rendered and says
  nothing at all about what is not — spending that silence as a guarantee in front of a
  destructive command is the exact bug being fixed.

### Known limitations (honest by design)

- English Logic UI assumed (v1); tested against Logic Pro 12.3.1 on macOS 15.
- Tempo curves are integrated as steps (Logic's Tempo List does not expose them);
  the uncertainty is quantified in results.
- Track stacks cannot be freeze-rendered (Logic limitation; `solo_bounce` covers it).
- Recorded automation cannot target headerless strips (`Stereo Out`, auxes, buses).
- MIDI recording runs in real time.

### Deferred, deliberately

- Homebrew formula ships alongside this release; a simpler installer for musicians
  without a terminal is planned.
- Offline audio analysis (spectrum/LUFS) is a non-goal: Logician's job is verified
  interaction, and real audio to multimodal ears is the analysis story.
