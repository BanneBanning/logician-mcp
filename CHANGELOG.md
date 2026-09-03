# Changelog

## 1.0.0 — unreleased

The first public release, staged and waiting on the go-public decision.

Logician gives any MCP client verified control of Logic Pro: 81 typed tools across
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
- **A refused new project no longer leaves one behind.** `logic_new_project` copied its
  template to your path and only then noticed the open project had unsaved changes — so
  the call refused, and the empty project was already sitting where you asked for one.
  The obvious retry, carrying the very decision the refusal asked for, then bounced off
  "already exists". The decision now happens before a byte is written: a refused call
  leaves the path free and the retry just works. `logic_duplicate_project` learned the
  same lesson for its copy, and gained it for `save_first` too — a bad or occupied
  `destination_path` is refused before the original is written to disk, not after.

- **Saving a project is a third faster.** The save verified itself on a 250 ms timer that
  started before it had looked even once, and the save is already provable the moment the
  key command returns — measured live, both success signals (Logic's modified flag and the
  project file's mtime) were true at zero wait, on every run. The loop looks first now:
  ~725 ms down to ~475 ms, with the verification untouched. Duplicating with
  `save_first: true` also stopped asking Logic for the same document list twice.

- **A close stopped reporting dialogs that were not dialogs.** Any Logic window with a
  blank-titled control counted as an unknown alert, so a perfectly clean close of a real
  project came back saying it had walked past a dialog it did not understand — and a
  verified reset could have failed its "no dialog left on screen" check on the strength of
  it. A blank title is not a button an alert offers.
- **`logic_get_audio_clip` cuts the window it reports, on every format, and does it in
  half the time.** Asking for eight seconds at 0:30 of a WAV, CAF or `.m4a` used to
  return either the WHOLE file from second 0 while the result reported the window asked
  for, or nothing at all: the trimmer understood AIFF only, and the encoder behind it
  refused (`'cclo'` -66564) every source carrying a channel layout — which is every
  `.m4a` preview this server writes and every raw Logic AIFF, so both documented
  recovery routes for an oversized file pointed at a guaranteed failure. Windowing and
  encoding are one in-process pass now: the clip is SEEKED to and only the window is
  decoded, the mono mixdown is ours rather than an encoder flag's, and the audio comes
  out byte-identical to what the old path produced when it worked (50,476 B for the same
  8 s clip, same AAC payload hash). Measured 2026-09-02 on a 50 MB master: 8 s
  125 ms → 51 ms, 20 s 238 ms → 96 ms, and the `.m4a` preview 8 s went from a hard
  failure to 57 ms. Two clips can no longer collide — the path carries milliseconds and
  a random suffix, where four calls inside one second used to write one file and
  overwrite it three times — a window the file ends inside comes back shortened with a
  warning instead of an overstated length, a start past the end says so with the file's
  real duration instead of blaming the file, a refused call no longer leaves an orphan
  clip in the captures directory, and the tool description now states what a clip
  actually costs on the wire (~70 KB for the default 8 s, ~179 KB at 20 s, ~1.3 KB with
  `include_audio: false`).

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

- **`logic_evaluate_change` answers a quarter faster, refuses the wrong project on every
  method, and stops calling a shared bounce a solo one.** An A/B by ear used to spend
  three quarters of a second asleep in each of its parameter writes: the Accessibility
  write is synchronous and reads back in a few milliseconds, but the code waited a flat
  0.35 s after confirming and another 0.20 s in each of the two value reads. Those are
  bounded polls on the very values the next line compares now, so nothing is verified
  less and the answer arrives when it is ready — a `method: "bounce"` A/B went
  **6 316 ms → 4 687 ms** on the reference project, and because the sleeping helper is
  the one every Accessibility parameter write in the server goes through, every one of
  them got the same 0.75 s back. `expected_project_path` is honoured by all three
  methods now: it was checked on `bounce` and silently ignored by `render` and
  `solo_bounce`, so an agent that switched projects and defended itself with the
  argument had the parameter written into the wrong project and was told
  `success: true` — the check runs once, before the method's own shape checks, before
  the tempo map is read and long before anything is written (measured: the old `render`
  spent 8.0 s reading maps in the wrong project before failing on something else; the
  refusal now lands in 1 ms). And `solo_bounce` stopped promising what it could not
  see: a track that was already soloed somewhere else is not refused — both bounces
  carry it, so the deltas stay honest — but the result now says so in `warning` and
  `solo_context` instead of insisting the bounces held "only this track soloed", and a
  solo the tool could not switch off again finally warns in the same words
  `logic_export_stems` uses, rather than only flipping `solo_restored` to false. With
  `include_audio: false` the two ear copies are no longer transcoded for the transport
  to throw away (134–289 ms), and the result reads exactly as it did before.

- **Reading a region's parameters stopped paying 630 ms to open a panel that opens in
  100.** Logic keeps the Region inspector's parameter panel collapsed by default, so every
  `logic_get_region_params` opened it, opened its "More" section, read, and shut both
  again — four presses whose cost was almost entirely a poll loop that slept a tenth of a
  second before its first look. Measured live: all eight toggles had already settled by
  then. The loop looks first now, and what it opened is left OPEN rather than shut for the
  next call to reopen: the panel phase went from 681–712 ms to 51–63 ms once it is up, and
  a chain of region calls pays the opening once instead of once each. `panel_state` says
  what was found and what was left, this server closes the triangles again when the session
  ends, and closing them yourself in Logic is safe — the deferred close reads each triangle
  before it presses it.

- **Logic's quantize vocabulary is learned once instead of every time.** The 36-item
  Quantize menu `logic_get_region_params include_quantize_values` returns is the same 36
  items for every region in every project — it is a property of the Logic install, not the
  song — and re-walking it cost 715 ms a call. It is now cached per Logic version and UI
  language (and retired the moment either changes), the write path banks the copy it
  already has open instead of dropping it, and `quantize_values_source` says whether you
  got the menu or the cache. The pop-up's own blind waits became positive checks with the
  same patience: the menu is still proven open before it is read and proven gone before the
  call returns.

- **A stem set now sees every soloed track, and takes 42% less time to make.**
  `logic_export_stems` refuses to run when anything is already soloed, because every
  stem would quietly contain that track — but it asked Logic's track headers, which
  publish only the rows currently on screen. A track soloed inside a collapsed stack
  was invisible to it: the run went ahead, the track landed in all three files, and
  the result still said `verified: true`. It asks the control surface's project-wide
  solo indicator as well now — that one sees the whole project, hidden rows included —
  and refuses with the reason named; if the surface cannot be read, the stems still
  render and `verified` comes back false rather than claiming a cleanliness nobody
  could check. And a stem that both failed to unsolo and came back silent reports
  both, instead of the second sentence overwriting the first.
  The speed came out of the same file: Logic paints the word `Solo` over the strip's
  name on the control-surface display and leaves it there, and the "am I already on
  this bank?" test read that as the wrong bank — so every solo re-walked the surface
  back to the bank it was already standing on, eight blind button presses that Logic
  answers with silence, 1.9 s each. The check tolerates the banner and proves the
  strip by name instead. Three stems over two bars: **10.5 s → 6.1 s**, and each
  bounce also stopped re-reading the track list to rediscover the solo the export had
  just written.
- **Creating and removing a send stopped taking eleven seconds.** A person adds a send in
  two or three; `logic_add_send` took ~11 s and `logic_remove_send` ~10 s, and profiling
  them phase by phase (2026-09-02, live on the reference project) found almost none of it
  in the writing. One add now lands in **6.0 s** from a neutral surface and a removal in
  **~4 s**; back to back, an add-read-remove-read round trip is **21 s where it was 31**,
  and `logic_mcu_sends` — the read a mix flow starts with — is **1.3 s where it was 5.0**.
  Five measured waits went, and no verification with them. The send tools stop walking the
  surface home to the Pan view at the end of every call (1.3–3.4 s each): the restore is
  recorded as a debt and paid by the next tool that actually needs that view, exactly as the
  plug-in tools have done since the first efficiency package. The walk to the send view's
  first page reads the page's own labels and steps back exactly that far — a row saying
  `Sen5In` is two cursor-lefts from home — instead of pressing four blind ones (~1.0 s, and
  every call paid it two or three times, including on pages it was already standing on
  because Logic's browse banner hides the first cell's label). A removal jumps the whole way
  back to the No-Send entry instead of stopping eight entries short and walking the rest
  (2.0 s on a near bus, 0.8 s on a deep one; the catalog clamps at that end, and the paced
  walk still finds the boundary when a jump lands short). The flat second after the removing
  press became a check on the row Logic repaints to answer it (measured at 46–60 ms in four
  removals). And the two 0.3 s settles before the confirming presses became a proof of
  silence, ~155 ms: the entry did not drift once in twelve measured browses, and the drift
  check that would catch it if it ever does is untouched — as are the settle-verified name,
  the view gate on every message, and the send-list readback that has the last word.
  Two things stayed, on the evidence: the silence proof between the jump's 63-entry chunks
  (it already returns in ~180 ms, so the 1.5 s it is allowed is a deadline nobody meets),
  and the per-step settle inside the browse. And one thing got slower on purpose — a send
  list read within ~2 s of a level write now waits for Logic's own post-write overlay to
  fade instead of reading through it, because that overlay paints the destination's aux
  name over the position label and lets the dB value spill into the cell underneath, which
  is how a send at `PosPan` could be reported as sitting at `B`.
- **`logic_get_transport` keeps every key it promises, and says the tempo it reports is
  the one at the playhead.** The description has always promised that a field whose
  control bar element is missing comes back `null`, but the playhead position and the
  tempo/signature/key trio were only ever written into the result INSIDE the `if let`
  that found their group — so a control bar this server cannot read (a non-English Logic
  UI, a collapsed window) dropped five keys instead of nulling them, and
  `logic_project_snapshot`, which serves this payload as its `transport` section, would
  have shown a diff reading "the tempo was removed" where the truth was "the tempo could
  not be read". Every documented field is now present on every call, and the payload
  builder is pure, so that contract is a unit test rather than a hope. The other half is
  honesty about what those three fields ARE: `tempo`, `time_signature` and `key_signature`
  are the values in force AT THE PLAYHEAD, not project constants — the same project, four
  seconds apart, nothing edited, answers 120 BPM in 4/4 with the playhead at bar 1 and 121
  BPM in 5/4 at bar 51. The tool description and the guide now say so and point at
  `logic_tempo_events` and `logic_list_signatures` for the whole maps.

- **The transport read got 40% faster, and the Smart Tempo look 15%.** One control bar,
  walked once: the six transport checkboxes, the playhead LCD, the tempo, the signature,
  the key and the Smart Tempo pop-up each used to re-fetch the same sibling array and
  re-read the descriptions ahead of them — 98 of the call's 129 Accessibility reads — and
  the project window was resolved twice, once for the control bar and again for the
  document path it already had. Measured warm on the reference project: **8.2–9.4 ms →
  4.9–6.1 ms**, byte-identical payload. That is ten internal callers cheaper, including
  the metronome poll that runs this whole read once per tick. And
  `read_smart_tempo_mode: true` dropped two blind sleeps a zero-wait probe had already
  disproved — 120 ms spent before the appear loop's first look at a window
  `pressMenuItem(settled:)` had just proven was there, and 250 ms after a close press that
  had already landed: **0.85–0.87 s → 0.72–0.74 s** per call, 0.20 s for the first visit
  in a process.
- **Every region tool got about a second faster by looking before it writes.** Addressing a
  region by name selects it first, and that step used to write `AXSelected = true` without
  ever asking whether the region was already selected. Writing it onto a region Logic
  already had selected makes Logic republish the row, so the readback 300 ms later reported
  "not selected" and a 500 ms "stale-element" retry fired — every time. It was the
  *idempotent* case that paid: reading a region twice, or reading it and then writing to it,
  cost 800 ms more than moving the selection to a different region did. The selection is now
  READ first: an already-selected region is a verified no-op (`state: "already_selected"`,
  nothing written to it), while `exclusive` still clears every other selected region and
  `deselected` counts them — and because that clear touches the same rows, the no-op is
  re-proved by a second read rather than assumed. A selection that genuinely moves polls its
  readback instead of sleeping through a flat 300 ms, and the retry stays for a write that
  really does not stick. Measured live 2026-09-02 on the sandbox project, warm:
  `logic_get_region_params` on an already-selected region 1 990–1 997 ms → 866–873 ms, and
  1 943 ms → 805 ms with two more regions on the track still selected; the same read on a
  region that was NOT selected 1 158–1 174 ms → 857–866 ms; `logic_select_region` itself
  402–465 ms → 90–163 ms. Same saving on every tool that addresses a region by name —
  `logic_set_region_params`, `logic_rename_region`, `logic_move_region`, `logic_copy_region`,
  `logic_delete_region`, `logic_split_region`, `logic_edit_event`, `logic_bounce_in_place`,
  `logic_list_events` and `logic_remove_silence`. The exclusivity was proven the hard way:
  with all three regions of a track selected and the target among them, the call came back
  `already_selected` with `deselected: 2` and the arrangement map showed exactly one region
  selected on that track.
- **Asking how things are stopped moving the control surface, and says a third as
  much.** `logic_health` is the tool the guide tells every session to run first, and it
  was ending that session by pressing PAN: its liveness probe counted as a write, so the
  server's shutdown restored a surface nothing had touched — 145 ms of it measured, and a
  real view change on a surface the user had left in a Send or insert view. Which bridge
  commands can move the surface is now a property of the command vocabulary itself,
  answered by an exhaustive switch that will not compile until a newly added command says
  which side it is on, rather than by a list that had drifted to one entry. Measured live
  in alternating pairs against the sandbox project: the doctor's exit went from 137–140 ms
  and "surface returned to Pan view" to 1.6 ms and "the control surface was never
  touched", and the surface's own event counter did not move once across the whole run.
  `logic_get_transport` reads the surface through the same probe and is fixed by the same
  change. The pass also took the doctor's own cost down: one socket round trip where there
  were two once the bridge daemon is on this build (its `status` reply now carries the
  protocol version the ping was sent for) and never more than the two it always cost
  before then, one Logic-process lookup where there were three, one window walk where a
  second was about to be added, and no Launch Services lookup on the branch that discards
  it — 3.4 ms to 3.1 ms warm. And the report itself went from 2 139 to 638 bytes on a
  healthy Mac, 2 432 to 791 on the wire, **70% smaller** — because 22 key commands all
  reading `registered: true` are now a count, the 381-byte "this is an inference"
  paragraph moved into the tool description where it is paid once per session instead of
  once per call, and the 1 371-character non-English warning is carried once in full with
  a one-line pointer at the top level instead of being shipped twice.
- **The doctor can tell a modal apart from a dead surface.** A Logic sitting on an
  unanswered alert stops feeding the control surface entirely, which reads as
  `mcu_connected: false` — so the one tool people run *because* something is stuck was
  answering "go and re-pick your MIDI ports" at someone whose only problem was a dialog on
  screen. `logic_health` already reads Logic's window list; when the surface is silent and
  a window is open it now names that window in the fix and lists it in `open_dialogs`, and
  when no window is open it says so, so the MIDI-port remedy is only offered to the people
  it is actually for.
- **`logic_select_region {exclusive: false}` now actually ADDS a region to the selection.**
  The schema has advertised additive selection since it was written and it never worked:
  three non-exclusive selects in a row left exactly one region selected — the last — on
  MIDI and audio regions alike, each call reporting `success: true, verified: true`,
  because the only thing verified was the region named in that call. The cause was one
  line at the end of the write: an unconditional keyboard-focus write, added as a
  best-effort extra for key commands. Measured on the sandbox, that write ALONE — with no
  selection write anywhere in the call — took a four-region selection spread across four
  tracks down to the one focused region; Logic reads focus as a plain click. Selection
  writes on their own are genuinely additive (1 → 2 → 3 → 4 over four consecutive writes),
  so the focus write is now sent on the exclusive path only, where collapsing onto the
  target is what was asked for anyway. Additive selection is PROVEN, not assumed: the
  arrangement is counted again after the write and the result carries `selected_before`
  and `selected_count`, so a selection that did not grow comes back with a warning naming
  what was lost and pointing at `logic_select_regions`, instead of a silent success. Live,
  after: `exclusive: true` then three `exclusive: false` calls across three tracks read
  `selected_count` 2, 3, 4 and `logic_list_regions` showed all four selected; adding a
  region that was already in the selection is a no-op (`already_selected`, count
  unchanged); and one `exclusive: true` cleared all four (`deselected: 4`) for a single
  selected region, exactly as before. 90–181 ms per call.

- **Importing an arrangement is two and a half times faster, and its note check now reads the
  region it just imported.** `logic_import_midi` spent 65% of every call looking for four
  buttons. Logic's import panel publishes its Go-to-Folder sheet, its path field and its
  Import button within three levels of the window, but the window's first child is the file
  browser — the user's own filesystem, thousands of elements deep — and the search walked all
  of that first, 1.3–2.0 s per lookup. It now searches breadth-first, nearest the panel
  first, exactly as the bounce save panel already did. Proving a dialog CLOSED was the other
  half: re-searching the tree for something already gone cannot stop early, so it walked
  everything, twice a call; the panel and the sheet are now asked directly whether they still
  exist, with the search kept as the authority that gets the last word. Measured live
  2026-09-02 on the sandbox project, before and after, same arrangement: **one track
  8 814 ms → 3 285 ms, four tracks 8 249 ms → 4 020 ms**, and a `to_track` import onto an
  existing track 5 837 ms all in. The failure path was run too — a panel that refuses the
  path is still closed, sheet first, with `dialog_left_standing: false` and the census
  unchanged. Separately, `verify: "events"` was reading the WRONG region: every unrouted
  import leaves behind a track Logic names after its default patch, so the second one makes
  two tracks called `Studio Grand`, and the read addressed them by name — it resolved the
  earlier import's region, surfaced a plugin-parameter error out of a region resolver, and
  then warned that "the NOTES do not all match" having read none of them. It now addresses
  the row by NUMBER (with six `Studio Grand` tracks in the project, the check read track 35
  and matched 4 of 4 notes), and a region whose notes could not be read comes back
  `verification: "unverified"` with the reason instead of being called a mismatch. Two dead
  two-second sleeps between track deletes are gone (twelve consecutive deletes this session,
  no gap, 868–1 640 ms each, 12/12), the `.mid` each call generates is now removed again
  rather than accumulating one file per call in the captures directory, and the documented
  costs were corrected against measurement: the note diff is +3.9 s for one region rather
  than "+~2 s", and a routed track ~2.6 s rather than 5.9 s.
- **Key-command learning stops trusting things it never checked.** Learning writes into the
  user's own Logic key command set — state that lives outside every project, that no Undo
  reaches and that no copy restores — and five of its steps were taken on faith. The MIDI
  note Logic is armed to capture was sent with the answer thrown away, so a bridge that was
  down or refusing produced "all candidate notes collided" after 4.5 s of waiting for a note
  nobody sent; the reply is read now, the failure names the bridge rather than Logic, and the
  daemon start it used to hide (up to 3 s) is started deliberately and reported as
  `bridge_start_ms`. `relearn`'s Delete-Assignment loop aimed at "the first table in the
  window" while the code elsewhere allows the ~1400-row COMMAND list to be a table too — it
  now has to prove the assignments table is a different element than the command list, and
  refuses rather than risk deleting the user's real key commands. A command that already
  carries a different note is refused instead of quietly given a second assignment
  (`relearn: true` replaces it). Collision fallbacks used to be `note + 20` and `note + 40`,
  which for every note the picker can choose landed inside the 100-121 block reserved for the
  product's own commands; they come from the same free-note allocator as the first choice now,
  and the registry refuses to record a note another command already answers to instead of
  silently holding two entries for it. An explicit `note:` belonging to another command is
  refused on the repair path too, not only the first-learn path. Both learning tools also run
  the 0.8 ms orphaned-twin-port audit first and refuse while one is present — Logic binds key
  commands to a port's unique ID, so that is the one way to produce a registry entry that can
  never fire — and every new entry records the port identity it was learned against, which
  `logic_list_key_commands` reads back and warns about when it has changed. Two blind sleeps
  whose outcome the code already reads (0.5 s after selecting the row, 0.4 s after arming
  Learn) became polls with those numbers as caps, and the Learn checkbox is found once per
  command instead of three times; the 1.0 s search settle and the 1.0 s after the note stay,
  because one is Logic re-filtering 1400 rows and the other is the MIDI plane. Unit-tested,
  not live-verified: this flow rewrites persisted key bindings, so it was fixed by review and
  23 new tests rather than by running it.
- **The event and marker lists never lose a note in silence again — and they are a
  quarter faster.** Logic's List Editors draw only the rows in VIEW: everything scrolled
  out of the pane, and the newest row of a list that has just grown, is published and
  counted while its cells stay empty. The readers mapped every published row anyway, so a
  region that had just gained a note came back as 26 events of which one was blank, a real
  note (`12 4 2 1 Note D♯3`) was simply gone, and both counts said 26 — nothing in the
  result hinted that anything was missing (reproduced 3/3). A 54-note region was worse
  still: 26 real notes, 28 blanks, reported as 54. Now `logic_list_events` and
  `logic_markers` report every row they can read, state the count Logic itself declares,
  and name the row numbers they could not read in a warning that says how to get them
  (scroll the list) — the same census, in the same words, that the Event List's WRITES
  have used since the day before. The meter map, where a lost row would place every later
  bar confidently wrong rather than merely misreport it, now REFUSES a Signature List with
  an undrawn row instead of quietly reading it as a key change, and that refusal keeps the
  bad map out of the session cache. `logic_list_signatures` also reports the key-signature
  rows it skipped (`key_signature_rows`), and a map served from cache now says so —
  `read_route: signature_list_cache`, `verified: false` and a SERVED FROM CACHE warning,
  exactly as `logic_tempo_events` has always done. The same pass stopped both List Editors
  tree walks from descending into the table's rows for things that sit beside it, and
  replaced two blind 0.6 s waits with a positive readiness check that keeps the 0.6 s as
  its deadline: measured live, `logic_list_events` went **1 150 → 816–891 ms** on a
  25-event region and **1 840 → 1 034–1 081 ms** on a 54-event one, and
  `logic_list_signatures`' cache miss **2 112 → 1 471 ms** (a cache hit stays 8 ms).

- **`logic_list_key_commands` says each fact once, and can no longer take the server down
  with it.** The listing answered 7 067 B, and 55% of that was the same text 22–27 times
  over: a 55-character apology for an unrecorded source on 22 rows, a `notes` string
  restating that source on 26, `channel: 16` on all 27. Each of those is now said once at
  the top level or not at all — `channel_default`, one `unrecorded_sources` count, and the
  learn timestamps and search terms left in the file the answer already names in
  `registry_path`. Same 27 commands, same notes to fire them with, **2 377 B — 66% smaller,
  around 1 170 tokens back on every call**, at the same 0.9 ms. Underneath it, the handler
  keyed the 22 standard command names through a dictionary that TRAPS on a duplicate key —
  it does not throw, it kills the whole MCP server process, on a read-only call that touches
  nothing — and those names are a translation surface where four entries differ by one word
  (`Nudge Region/Event Position Right by Bar`/`Beat`, …). It is a set now, a duplicate name
  costs a name listed once, and two new tests hold the line. The result also stopped
  claiming `verified: true`: this call reads a file and never speaks to Logic, so there was
  nothing for Logic to have confirmed, and the description now says the field is absent and
  why. The orphan warning it carries — an entry can look registered and never fire — stays.

- **A refusal for a tool that takes no arguments names the alternative.** Eight tools accept
  nothing at all, and passing one an argument used to be answered with `Accepted: .` — a
  sentence that looks truncated and helps nobody. It now reads "This tool takes no
  arguments."; tools that do take arguments still list them.

- **The strip census stops counting banks and starts proving them, and gets a second faster
  doing it.** The walk to the leftmost bank was eight blind `bank_left` presses and the walk
  right was ten iterations, neither with a branch for running out — so a project past 64
  strips had its census numbered from whatever bank eight presses happened to land on, and
  one past 80 strips was cut short, both reported as a plain success with the shifted map
  written to the bank cache every later write resolves through. Both ends are evidence now:
  the walk left stops when a press produces no MIDI at all AND leaves the name row
  byte-identical, confirmed by a second quiet window so a bank change Logic answers late
  cannot be mistaken for the edge; the walk right stops when the rightmost bank's clamp
  proves the list ended. When either proof cannot be had, the tool says which one and reads
  nothing, rather than caching a map that aims writes at the wrong channel. The proof is
  also the saving: `logic_list_strips` no longer pays 207 ms for each press Logic ignores,
  and the end-of-scan probe charges one 200 ms silence round instead of two when the press
  it is settling produced no event — **1.58 / 1.61 s standing at the leftmost bank against
  3.04 s before, and 1.54 / 1.76 s from the rightmost against 2.59 / 2.61 s** (measured
  2026-09-02 on a 25-strip project), with `logic_mixer_snapshot`, every `findChannel` and
  every control-surface write sharing the same walk. The old oddity where the census cost
  half a second MORE when the surface was already where it wanted to be is gone with it.

- **A `Solo` left over from the last press can no longer be published as a strip's name.**
  Logic paints the name of the control it just saw over that strip's LCD name cell, and
  that banner turns out to be a timed transient: **1.94 s and 1.99 s**, measured at 50 ms
  resolution across a solo and an unsolo. The old bank walk spent 1.7 s pressing blindly
  before it read anything and so outlasted it by accident — the walk above is fast enough
  to read it, and did: `Solo` came back as the name of three different strips and the
  census reported 32 strips for a 25-strip project, because the banner also hides the
  rightmost bank's re-shown tail from the overlap check. Every bank's row is now checked
  for a control name and the banner waited out; if one is still standing after three
  seconds the census says so and refuses to cache the map, because nothing on the surface
  can tell a stuck banner from a strip somebody really called `Solo`.
- **The arrangement map admits which rows it cannot see, and got faster doing it.**
  `logic_list_regions` returned three keys and a 165-byte footnote saying scrolled-out
  tracks are not exposed — while `logic_list_tracks`, called on the same 19 rendered rows
  seconds later, reported `partial: true` and `missing_track_numbers: [10…19]`. Two tools,
  one project, one of them silent about the other ten tracks. The map now carries the same
  contract as the track listing (`partial`, `completeness`, `partial_evidence`,
  `missing_track_numbers`, and `coverage_checked` naming which signals were read), computed
  from the row numbers the walk already had: **zero extra Accessibility reads**, and it now
  reports the same `[10…19]` `logic_list_tracks` does on the same project. The
  collapsed-stack and scroll-bar evidence is opt-in behind `check_hidden_rows` (+40–50 ms
  measured). `type` stops being promised for every region: it is parsed from Logic's help
  sentence, which was measured on all 54 regions of the reference project and, hours earlier
  the same day, on 2 of the same 54 — so one typed region now types its whole row (a track
  holds one kind of region) and an absent `type` is documented as UNKNOWN rather than
  "not audio". **And the same call got a third faster**: the walk reads each node's role
  before its description, which it needed on 22 of the 448 nodes it visits, so 426 discarded
  reads are gone — 175 ms → 104–119 ms warm, measured back to back on the same project,
  cold 299 ms → 186–205 ms, and it lands ×4 on every region WRITE, which walks the
  arrangement four times. `selected: false` is omitted like `start_beat` already was (52 of
  54 regions), and the project window is resolved once instead of twice. The payload carries
  the whole completeness contract for +150 bytes on 54 regions (6 511 → 6 661).
- **Loading an instrument takes seconds instead of twelve of them, and it stops failing loads
  that worked.** `logic_load_instrument` was `logic_add_plugin` as it stood before round 2:
  no pacing, two walks home to the Pan view, four blind sleeps and an abbreviation test
  calibrated for track names. Profiled 2026-09-02, a warm load was **11.3-12.4 s**, of which
  46% was the surface walking home twice — once immediately before pressing its way back into
  the view it had just left — 27% was blind sleeping and 0.5% was the write. The same loads now
  take **1.4-4.6 s**: the middle walk home is gone (the IN bank view is re-entered from the
  parameter page and proven by its own top row, a stronger check than the assignment code it
  replaces), the walk home at the end is a deferred `SurfaceDebt` like the plug-in and send
  tools', the browse advances by waiting for the cell to CHANGE rather than firing ticks into
  unfinished repaints, and three of the four sleeps became positive checks. Four things it no
  longer gets wrong. **A load that worked is no longer reported as a failure**: `ARP 2600 V3`
  loaded, the slot read `ARPV3`, and the call came back `verification_failed` with
  `restored: false` on a destructive tool — the readback now accepts both shapes of
  abbreviation Logic uses on that row, and the same load verifies in 1.4 s. **An instrument
  whose name is too long for the shared browse row can be loaded at all**: `Drum Kit Designer
  Multi-Output` is 30 characters into strip 5's 27, so Logic paints it shifted left and it
  reads `m Kit Designer Multi-Output` — it is now identified by its tail, exactly, and the
  result says the row was too narrow and what it read. **The track already holding it is a
  verified no-op**, `already_loaded` off the slot cell without touching the browser, where the
  repeat call used to browse, drift and fail in 4.9 s; naming a `format` always browses,
  because a six-character slot cell cannot say which channel format it holds. And **asking for
  something the browser will not show refuses in seconds**: an entry-counted cap with a
  wall-clock budget that scales with `max_steps`, instead of about two minutes of vpot turning,
  reporting the entries it actually looked at rather than the number of times a name changed.
  The press is now gated on two agreeing reads taken with the surface quiet, and any correction
  is proven the same way: the browse row's mirror can hand back a frame the cursor has already
  left, and answering that by turning the vpot back until some read agrees put an `Abbey Road`
  plug-in on a track that had asked for `ARP 2600 V3`. `edit_page_after_confirm` also stopped
  passing off a row of dashes, or the channel-names row, as the parameter page it advertises.
- **The control surface reads live, and says how old it is when it cannot.** `logic_mcu_status`
  read the bridge's state FILE and nothing else. That file is rewritten only when Logic sends
  something, and its `online` flag is computed the moment it is written — so a written file
  says `online: true` by construction and keeps saying it after Logic goes quiet. Measured
  2026-09-02: mirrors 117 s, 177 s and 197 s old, served in silence, all claiming the surface
  was online while the daemon's live answer to the same question, seconds later in the same
  session, was no. The tool now asks the daemon's socket first, exactly as the server does for
  its own reads, and that costs nothing (0.36–0.60 ms socket against 0.35–2.42 ms file). Every
  result names the plane that answered (`source`) and how old the snapshot is (`age_seconds`),
  `online` is recomputed at read time from when Logic actually last spoke, and a mirror served
  because the daemon went missing carries a warning with its age in seconds and a fix. The
  assignment display comes decoded — `assignment_view` in words, plus the leaked-plugin-edit
  and send-view flags the two standing hazards are about — instead of a two-letter code the
  agent had to look up. And `bridge_running` means what it means in `logic_health`: a daemon
  that answered just now. It used to be satisfied by a leftover `command.sock` FILE, which the
  daemon unlinks only at startup, so it read `true` permanently after any daemon death.
- **`logic_list_tracks` stopped paying a quarter of its cost for a signal Logic never
  publishes, and now joins the two facts it already knew.** The completeness probe asked
  the Tracks area whether it can scroll — and to ask, it re-resolved the track header
  group the header read had just finished with: a second depth-12 walk over ~172 nodes,
  **25.4 ms of an 86.7 ms warm call and 379 of its 1 002 Accessibility reads**, for an
  answer that never reached the result. The question itself takes 0.17 ms and two reads;
  it is asked of the group the caller already holds now, and the project window is
  resolved once instead of three times. Measured live on the sandbox, before and after in
  the same session: **58.5–58.8 → 38.3–39.5 ms warm, a third of the call gone**, with the
  same 19 rows and the same verdict. Cold is unchanged (~124 ms) because cold is macOS's
  first Accessibility handshake, not this code. The probe stays, because it is the
  only signal that can catch rows scrolled BELOW the viewport — but on this Logic it has
  never fired: no vertical scroll bar is published on the Tracks area at all. That silence
  used to look exactly like "everything fits", so the result now says
  `scroll_signal: {state: "unavailable", reason: …}` in as many words. And where the
  answer used to hand an agent two unrelated sentences — "tracks 10…19 are missing" and
  "stack 9 “Drum Synth Kit” is collapsed" — it now says they are the same fact whenever
  the rows in hand prove it: the gap begins at the row immediately after the only
  collapsed stack, so `hidden_by` names that stack and the evidence sentence reads
  "expand it". No extra Accessibility read, one fewer guess for the agent. The response
  got **smaller while gaining both of those fields — 2 606 → 2 317 B, -11%**: the
  570-byte standing note says everything it said in 399, and `selected` and `is_stack` are
  omitted when false, the way `expanded` always has been.

- **`logic_list_windows` no longer calls the Mixer a project window.** The tool is the
  server's own window-identification oracle — the one a refusal points at by name — and it
  derived `kind` from whether the window carried the project document, which is neither
  necessary nor sufficient. With the Mixer open it reported TWO windows, both
  `kind: "project"`, one of them the very window `projectWindow()` filters out and
  `logic_set_mixer` warns can shadow the real one; a Drum Machine Designer dialog carries
  the document too, and came back "project" while `logic_close_plugin_window` would close
  it happily. `kind` is derived from the SUBROLE now — the same rule the close tools
  enforce — and the Mixer is its own kind: `project`, `mixer`, `standard`,
  `plugin_or_auxiliary` (AXDialog, document or not) and `other`. The description was the
  last place in the repo still teaching the document rule. `AXDocument` is also read once
  per window instead of twice.
- **A new project arrives ready to work in, and a fresh project starts with fresh caches.**
  Logic puts its "Create New Track" sheet over every empty project, so `logic_new_project`
  — which creates from a bundled empty template — handed back `success: true,
  verified: true` with a modal standing on the screen it had just made, on every single
  call, and never mentioned it: the next tool call met a dialog it could not name, and
  `logic_reset_to` into an empty template would have failed its own "no dialog left on
  screen" check on a reset that worked. The sheet is now answered, the dismissal PROVEN
  rather than assumed, and the answer reported in `dialogs_answered`. Which button took
  measuring: **Cancel does not dismiss that sheet, it abandons the project** — three times
  out of three it left Logic with no window, no open document and its own template chooser
  on screen, because Logic will not show a project with no tracks. So the open answers
  **Create** and says so: a new project arrives with ONE track of the kind the sheet
  offered, named by `logic_list_tracks`, which beats the alternative of no project at all.
  A close answers Cancel — the project is on its way out anyway. `logic_close_project` and
  `logic_reset_to` know the grammar too, so it is no longer logged as "UNKNOWN dialog
  grammar", and the poll that proves the open does not sit behind it: the sheet is measured
  not to block Apple Events (the document-list read returned in 264–400 ms underneath it,
  6 creates out of 6), so recognising it costs nothing. Alongside it, `logic_new_project` and `logic_open_project`
  now clear the four per-project caches and report `caches_cleared`, as the close and the
  reset already did — their scope stamp is version-plus-path, which cannot tell a project
  from a different project created at a path you deleted, and that is exactly what an eval
  loop does. And the open stopped paying for an answer nobody reads: with
  `if_current_modified: 'save'` or `'dont_save'` the decision is already made, so the
  document-list read in front of it is skipped — **~265 ms off every create, open,
  `logic_reset_to` and `logic_duplicate_project {open_copy: true}` that carries a decision,
  13% of a warm call** — and kept exactly where it still decides something, the default
  `'fail'`, where it is also the early diagnosis for a list that will not answer.
- **Every button press on the control surface got 50 ms faster.** Pressing an MCU button
  meant holding it down for 50 ms, and that hold was **99.4% of what a press cost the whole
  server** — 51–56 ms of a 51–56 ms round trip, paid by `press`, `select`, `mute`, `solo`
  and `vpot_press` alike, twelve times in a single mixer census, while the bridge's global
  command lock kept every other client off the surface for the duration. It was swept live
  against Logic: holds of ~0.2, 1, 2, 5, 10, 25 and 50 ms all changed the view, **16
  transitions out of 16**, with Logic's echo landing 102–106 ms after the press at every one
  of them. The hold bought nothing. What Logic does need is both note edges — a press with
  no release left the display half-changed for 1.3 s of polling — so both are still sent,
  with nothing between them. `hold_ms` is a real argument now for the handful of Logic
  Control behaviours that depend on how long a button is down (held SEND opens the submode
  chooser); those were not swept, and the one press in the server that relies on one asks
  for its 50 ms by name. The saving arrives the next time the bridge daemon is started from
  this build; an older daemon simply ignores the new field and keeps its 50 ms, which is why
  this needed no protocol change.

- **`logic_mcu_command` stopped advertising doors that were bricked up.** Its description
  told callers to pass `verify: true` for the daemon's `final_value`/`followed` readback and
  the schema refused the argument, so the tool's **only** readback was unreachable and every
  fader write through it was blind. Three of the fifteen commands it lists — `converge`,
  `midi_stream` and a parameterised `await` — were in the same position, advertised with
  none of their arguments declared; one measurement in the profiling ledger had already been
  abandoned over exactly that. Every field the bridge can read is a declared argument now,
  and a test holds the two lists equal so they cannot drift apart again. The result gained
  the contract the rest of the server speaks — `success`, `state`, and `verified` only where
  something actually read Logic back — because `ok: true` promised far less than it looked:
  an MCU note Logic has nothing bound to answered `ok: true` six times with the surface
  byte-identical before and after. `state: "sent"` says that out loud, and the description
  now points at `{"cmd": "status"}` on the same tool — the daemon's live snapshot, 0.4–0.7 ms
  — instead of `logic_mcu_status`, which reads a state file that can be minutes old. It also
  honours `expected_project_path` at last: the guard was written, forbidden by the schema and
  therefore dead, on the one destructive tool that had no project check at all. And the
  refusal for an unregistered key-command note stopped pasting the entire registry into an
  error string — 1 159 B of prose to say one thing — for the count and the name of the tool
  that lists them.
- **`logic_markers` goes to the marker, not to its bar — and every action is one pane
  cycle instead of three.** `goto` on a marker at `33 4 1 1` parked the playhead on bar 33
  BEAT 1, three beats early, and handed back `after: {bar: 33, beat: 1}` next to
  `marker: {beat: 4}` in the same payload without noticing the two disagreed: it read only
  the bar and passed `beat: nil`, which does not mean beat 1 — it means the beat slider is
  never touched, so the playhead kept whatever beat it already had. It now parks on the
  marker's bar AND beat, on the grid, with the landing read back off the control surface's
  own position display; a marker that sits between beats gets the beat line before it and a
  warning that says so. `create` parks the same way — it was the last writer in the server
  still stepping blind, which is how a marker asked for at bar 9 could land at `9 1 4 201`.
  Underneath, the whole tool stopped re-opening Logic's List Editors pane between the steps
  of one call: `create` and `delete` opened, settled and closed it three times at ~1.55 s
  each to read a table that takes 5–12 ms, and the two blind sleeps they slept (0.5 s after
  a button press, 0.4 s after a row action that measures 13.9 ms) are now positive checks on
  the list's own count. And the pane's opening settle was waiting for the target tab to be
  drawn while Logic opens the pane on the tab it was last on — a question that could not be
  true before the press that makes it true, so it burned its whole deadline 15/15
  (610–1 094 ms) on every pane cycle. It waits for the tab strip now, which is what comes
  next, and hands the strip to the caller instead of walking the window for it again; every
  List Editors tool pays that cycle, `logic_list_signatures`, `logic_tempo_events`,
  `logic_edit_event` and `logic_project_snapshot`'s three pane visits included. **Measured
  live 2026-09-02, warm: `list` 1 532–2 255 ms → 457–491 ms, `create` at two bars' distance
  6 053 ms → 907 ms, `delete` 5 733–6 499 ms → 559–638 ms** — the pane cycle itself is
  ~460 ms where it was ~1 550. `goto` is unchanged at ~5 s across 32 bars, because 73% of it
  is the playhead stepping bar by bar and that is a separate problem. Marker NAMES are
  read-only on Logic Pro 12.3.1 (no cell in a Marker List row publishes a settable value,
  measured every row, every cell), so `create` now refuses a `name` argument up front with
  the manual route instead of creating the marker and spending another 1.9 s to fail at it;
  the description says markers keep Logic's default names, and that `create` presses the
  Marker tab's own button with the key command as the fallback, which is what it has always
  actually done.
- **Opening a second plugin on a track works, and says which plugin you are looking at.**
  Logic reuses ONE plugin window per channel and swaps the plugin into it in place — same
  window, same title, same spot on screen — so `logic_open_plugin` verifying by "did a
  window appear?" saw nothing happen and reported `verification_failed` on a press that had
  worked, every time, after 2.5 s. It reads the window's own header now: `window_shows`
  carries the plugin name Logic paints there, `state` is `swapped_in` with
  `replaced_plugin` when the channel's window was reused. Asking that same header BEFORE
  pressing also settles "is it already open?" for free — 2 570 ms and 2.4 s of the window
  flickering off screen becomes ~150 ms and no press at all — and dropping a 100 ms sleep
  that sat in front of the first look takes a normal open from ~307 ms to ~200 ms.
  `logic_survey_plugins`, which opens every insert in a loop, was failing from the second
  insert onwards for the same reason.

- **The instrument slot's parameters are as quick as an insert's, and a big instrument
  finally gets cheaper the second time you look.** Reading `808`'s Quick Sampler went from
  8.2 s to **3.6 s**, and asking again in the same session from 8.2 s to **3.8 s**; setting one
  of its parameters right after reading it went from 4.3 s to **0.95 s**. The surface is no
  longer walked all the way home to the Pan view at the end of every call and then walked
  straight back in at the start of the next one — it is left where it is, recorded as a debt,
  and the next call on the same track reuses the view it finds (re-proved against the LCD
  first, so a surface that moved in between costs a re-entry, never a write to the wrong
  instrument). **A capped read now caches the pages it read**: `Bas`'s Trilian is 64 pages, the
  default look at 12 of them cost 30.7 s *every single time* because a capped read stored
  nothing, and the second identical call is now **4.5 s**. A parameter sitting in one of the
  last two encoder cells no longer costs an extra 1.9 s per write — those cells hide behind
  Logic's own "Page x/y" indicator, and the indicator's own page number is accepted as the
  proof of where the surface is instead of waiting 2.1 s for it to fade (`FilRes`: 6.2 s →
  2.5 s, the same as a cell-2 parameter). **A track with an empty instrument slot says so**:
  six different failures used to share the sentence "no instrument in the slot, or the edit
  mode could not be entered", and an empty slot now comes back as a precondition naming
  `logic_load_instrument` rather than as something to retry. The reader also reports the
  instrument's real name (`Trilian`, `Quick Sampler`) instead of the six-character LCD
  abbreviation it uses as a cache key, carries the same `success` / `verified` / route and
  selection evidence its plug-in twin does, and both tools now take `expected_project_path`.

- **Every region tool can now say WHICH ROW it means, and the three list readers say how much
  of the list they could see.** An imported arrangement is a stack of identically named tracks
  — Logic names each track an import creates after the default patch it loaded, so `Studio
  Grand` is three rows — and the region tools were the ones that could not tell them apart:
  `logic_delete_region` refused `track_number` outright while `logic_delete_track` accepted it,
  and a region addressed by name alone landed on whichever row Logic had rendered first.
  Thirteen tools (delete/copy/move/split/rename/select, the two region-parameter tools,
  `logic_list_events`, `logic_edit_event`, `logic_remove_silence`, `logic_bounce_in_place`)
  now take `track_number` — cross-checked against `track_name` by the same rule the track
  tools have always used, so a stale pair refuses before anything is written — and a name
  matching two rendered rows is refused as ambiguous instead of resolved to the first of them.
  `logic_copy_region` takes `to_track_number` for the destination as well, and
  `logic_select_region` reports the row it landed on. A region that could not be picked out on
  the row also stops borrowing the plug-in vocabulary: "Accessible plugin parameter is
  ambiguous: region on 'Crash'" is now a sentence about regions that lists the candidates and
  names both ways out (`start_bar`, `track_number`), and a request matching NO region is a
  not-found rather than an ambiguity that matched zero. Finally, the List Editors readers say
  in their own descriptions what they have reported in fields since 2026-09-01: Logic draws
  only the rows IN VIEW, so `logic_list_events` and `logic_markers` answer with the list's own
  count plus `events_read`/`markers_read` and the row numbers they could not read, while
  `logic_list_signatures` refuses outright — a meter map that dropped a signature change would
  place every later bar confidently wrong.

- **The mixer read no longer mistakes a blinking light for a state — and it is twice as
  fast.** Solo one track in a project where nothing is muted, ask `logic_mixer_snapshot`,
  and six strips used to come back `"muted": true`: Logic FLASHES the mute LED of every
  channel a solo silences, and the tool read one instantaneous frame of that flashing.
  An agent asked to unmute everything after a solo pass would have muted six channels
  that were never muted. Every LED answer is now taken across a sampled window and
  classified by counting edges, so a steady mute LED is a mute, a blinking one is
  reported `muted: false` and marked `mute_led_blinking` ("silent right now because
  something is soloed, but not muted"), and a record LED that blinks still means armed —
  the same samples, opposite rules, because that is what the two lights mean. The result
  also carries `any_soloed`, Logic's whole-project solo indicator, which sees a soloed
  channel that has no strip on the surface at all. On the reference project the call
  went from **12.3 s to 8.5–10.1 s, and to 5.5 s** when the mix read is about levels and
  pan: `include_record_arm: false` drops the one question that
  needs the 1.6 s-per-bank blink window (the field is then ABSENT, never false), the
  return to the pan view is deferred to whichever tool next needs it instead of being
  charged to a call that had already read every byte it reports, and the restore itself
  stopped paying two full-second silence proofs for a view it already knew. Two smaller
  truths came with it: `assignment_after` is read after the restore decision rather than
  before it, so it describes the surface the caller is actually handed; and ten minutes
  of an untouched Logic no longer takes the whole control-surface plane down with "the
  bridge is not running or Logic has never talked to it" while the bridge is running and
  Logic is fine — an idle surface is woken with one probe press, and the four faults that
  shared that one sentence now each name what was found and the repair for it.
- **A snapshot stops calling itself complete when it knows it is not — and it is 30% faster on
  the first one of a session.** `logic_project_snapshot` is the truth document you diff a
  BEFORE against an AFTER with, and `complete` is the field that says whether it is the whole
  project. It counted only sections whose reader crashed, so on the reference project every
  single call returned `complete: true` with no warning while carrying, inside the same
  document, `tracks.partial: true` and `missing_track_numbers: [10…19]` — ten track rows and
  every region on them hidden behind a collapsed stack, in a document that called itself whole.
  `complete` now answers the question it is named after: false when a section failed
  (`unavailable_sections`, unchanged — those two conditions are different and both stay
  visible) and false when a section that DID read can prove there is more (`partial_sections`,
  with the numbers in `missing_track_numbers`), with the sections and their evidence in the
  top-level `warning`. The same promotion reaches the map caches: a `tempo_map` or `meter_map`
  served out of this server's earlier read is named in `cached_sections`, drops `verified` to
  false and carries its SERVED-FROM-CACHE caveat at the top level instead of one level down —
  and `tempo_map` now reports its `read_route` and cross-check verdict the way
  `logic_tempo_events` does. It also got quicker while it got honester: the three list-editor
  sections now share ONE List Editors pane cycle instead of opening and closing the pane three
  times, so the first snapshot of a session — the one that actually reads both maps — went from
  **2.62 s to 1.60 s** (measured live 2026-09-02), a warm repeat call is unchanged at ~1 s, and
  the meter map's cache check stops re-reading a transport the same call already has.
- **A preset change stops sitting out an Accessibility timeout twice, and says what
  `already loaded` really means.** Loading a plugin setting was a 6.1 s call in which
  0.5% of the time was the tool's actual job. Half of it was two Accessibility presses
  waiting for a reply Logic never sends: a press that opens a menu is not answered until
  the menu is DOWN again, so each one sat out the full messaging timeout (measured
  1 500–1 510 ms, 8 of 8) and then reported failure on a press that had already opened
  the menu ~30 ms in. The press is now bounded and the menu itself remains the only proof,
  the plugin chooser behind `logic_add_plugin` and `logic_remove_plugin` gets the same
  treatment, and `select` reads, matches and presses inside ONE menu cycle instead of
  opening the identical menu a second time to find the leaf it had just read. Three blind
  sleeps that were waiting for things already true became polls that look first. Measured
  end to end on the same Channel EQ, same project, same day: `select` 6.1 s → **1.1-1.3 s**,
  `list` 3.4 s → **1.2-1.9 s**, `step` 1.7 s → **0.33 s**, with the same verification and
  the same retry ladders behind it. The honesty half: a `select` of the setting
  the header already names pressed nothing and called it `already_loaded` — a NAME match
  sold as a state match. On the profiled Channel EQ that header (with Logic's own tick on
  it) sat over 3 of 26 parameters that were away from the factory values, so a caller
  asking for those values kept the tweaks and was told `verified: true`. The no-op stays,
  because it is what protects those tweaks, but it now answers `already_loaded_by_name`
  with a warning that says what was and was not checked — and `reload: true` presses and
  verifies the load when the values are what you actually wanted. `action: "undo"` carries
  the measured rule with it: one undo per write, and diff `logic_list_plugin_parameters`
  against a capture taken before the first write, because the per-plugin history repeats
  states (the state after the third undo was identical to the state after the first) and
  nothing in the label can tell you where in it you are.

- **Muting a track no longer depends on whether some other track is soloed.**
  `logic_set_track_mute` decided whether to press mute from ONE instantaneous frame of the
  mute light, and Logic flashes that light on every channel a standing solo silences. So
  with any solo up, "unmute this" could catch the lit half of the flash, conclude the track
  was muted, press mute — and **mute a track that was playing**, while reporting a verified
  success; and "mute this" could catch the same flash and report a verified no-op having
  done nothing. Both directions were silent wrongness on a tool that changes what the song
  sounds like. The state now comes from a sampled window classified by counting edges, the
  same rule and the same code the mixer read uses: a steady light is a mute, a flashing one
  is a solo, and the result says which window it paid (`led_evidence`), whether anything is
  soloed (`any_soloed`), and — when the light is flashing — `mute_led_blinking` with a
  sentence saying the track is silent right now but not muted. Unmuting a genuinely muted
  track under a solo ends with the light flashing rather than dark, which is now read as the
  success it is instead of a failed write. Proven live 2026-09-02 with `Bas` soloed: unmute
  on an unmuted, flashing strip is `already_off` with nothing pressed and the mixer census
  still reads it unmuted; mute really mutes it (and reads back steady while nineteen strips
  flash); unmute really unmutes it. The evidence costs 1.6 s each way, and only while a solo
  stands — Logic's whole-project solo light answers that in one steady read, so with nothing
  soloed the call pays a 0.3 s settle instead (measured 470 ms for a no-op, 0.8–0.9 s for a
  write) and that settle is itself new protection: it catches a light that repaints late
  after the surface banks, which the single instant never did. The mute flash was also
  MEASURED rather than assumed — 733 ms per phase, not the record light's 640 ms, so a
  window shorter than 1.5 s would have read a flash as a state on roughly one attempt in
  eleven. `logic_set_track_solo` shares the window (its light has never been measured
  flashing, and a flashing one is now refused rather than guessed at) and
  `logic_set_insert_bypass` never had the problem: it reads a checkbox, not a light.
- **An automation read now reports the position it actually sampled — and a one-point read
  costs 1.8 s instead of 5.8 s.** `logic_read_automation` used to park the playhead with a
  `try?` and throw the failure away: the loop then read whatever the lane said wherever the
  playhead really stood and filed it under the bar/beat that had been ASKED for. Measured on
  the reference project: `{bar 2, beat 5, value -18.6}` came back — counted as readable, no
  warning, `playhead_restored: true` — with the playhead standing at bar 4 beat 1. The
  grid asked for a fifth beat of a four-beat bar because `beats_per_bar` came from the
  control bar, which publishes the signature AT THE PLAYHEAD; the playhead sat 39 bars away
  in a 5/4 bar, so where it happened to rest decided which positions the caller was given.
  Both halves are fixed. Bar lengths come from the project's Signature List, per bar, so a
  read across the 4/4→5/4 boundary asks for four beats in bar 40 and five in bar 41 and gets
  all ten positions (proven live), with `meter_route` and `meter_changes_in_range` saying
  where the lengths came from. And every point's bar/beat is now the position the park
  VERIFIED on the control bar and the MCU display CONFIRMED — a park that fails puts the
  position in `omitted_positions` with its reason instead of lending its value to a
  neighbour, a park that lands elsewhere is reported where it landed, and a first position
  that cannot be reached refuses the whole call rather than sampling a grid that does not
  exist. `end_bar` is always sampled too: `{start 2, end 3, resolution 5}` returned ONE
  point at bar 2 and never touched bar 3, which also meant the flat-line warning could not
  fire; it now returns bar 2 and bar 3 with `final_interval_beats` naming the short last
  hop. `automation_mode: null` stopped being a riddle — the label is re-read up to four
  times (three of them at moments the call was already waiting, so the retries cost
  nothing), and a null that survives travels with `automation_mode_unavailable` saying the
  mode is UNKNOWN and not `Off`; `Stereo Out` reports `"Read"`, so the guide's claim that a
  headerless strip always reads null is corrected. The speed came from the same place it
  did for the plugin tools: the surface is handed over in the view the read used instead of
  walking home to Pan, which was **77 % of a one-point call** (1 764 ms against 5 757 ms
  measured, same project, same day) and also stops leaving a mode banner for the next
  tool's `findChannel` to wait out (105 / 506 / 2 017 ms across three identical calls
  before). A dense 17-point read is unchanged at 21.9 s: it is 62 % per-point settling, and
  that wait is still doing its job.
- **A nudge by beats is verified like a nudge by bars — and every nudge is a little
  faster.** `logic_move_region` checked where the region landed only when `by_beats` was
  0, and never checked the beat at all: a `{by_beats: -1}` nudge that moved nothing came
  back `success: true, verified: true, state: "moved"` — reproduced live 2026-09-02 on a
  region already sitting at bar 1, which Logic cannot nudge any further left — and one
  beat in a `{by_bars: 16, by_beats: 1}` request switched the exact bar comparison off
  with it. Both terms are now checked on every call against Logic's own arrangement map,
  the result publishes `from_beat` beside `from_bar` so the caller can check the
  displacement too, and a nudge that did not move names the keyboard focus and any open
  dialog instead of reporting success. The meter is not read to do it: the request and the
  two positions already say which meter would explain a beat carrying across a bar line,
  and a carry that no meter explains is a failure. The overlay backstop grew the eye it
  was missing as well. It compared the region TOTAL, which can only ever see a neighbour
  swallowed WHOLE, while Logic TRIMS what a nudged region is laid over — a trim moves a
  neighbour's start or end and leaves the count exactly where it was — so the target row's
  regions are now compared span for span either side of the nudge, and a trimmed neighbour
  (or a moved region whose own end did not travel with its start) is a named failure. That
  costs nothing: both span lists were already in hand. And the two blind sleeps the region
  family's earlier fixes missed are gone the same way `logic_copy_region`'s paste wait and
  `logic_delete_region`'s delete wait went: the 0.4 s before the verification census is
  now the census itself looking first (measured 8 of 8, the region was already at its new
  bar before the sleep began), and the 0.15 s after every nudge is now a positional read
  that fires the next nudge the moment the last one lands — 15 of 15 steps confirmed live.
  Measured back to back on one region, minutes apart, in the same Logic: a 1-bar nudge
  3.20 s → 2.61 s, a 4-bar move 3.80 s → 3.07 s, 201 ms → 154 ms per step (that hour's
  Logic was slow; the same 1-bar call profiled at 1.14 s earlier the same day, of which
  the tail sleep was 411 ms). The anchor selection also stops re-walking the arrangement
  the call has just walked, which is another ~60 ms.

- **A recorded automation curve now carries the point it was asked for, and it costs ten
  seconds less.** `logic_record_automation`'s Latch pass could not write the range's FIRST
  instant: the schedule's own start could only be sent once the crossing into that bar had
  been seen, so bar N beat 1 kept whatever the lane held before — measured on a lane
  holding −0.5 dB, where `logic_read_automation` read −0.5 dB back after a pass that asked
  for −14 dB there — and the verification, which samples that same moment, called correct
  passes failures twice in three runs and, when the old value happened to be close, called
  a point that had not landed verified. The first value is now armed a tenth of a second
  before the range (Latch records from the touch, and the arming point is read off Logic's
  own beat-and-tick display so a park's sub-beat residue cannot make it miss), and the same
  curve reads back −14.2 dB at bar 2 beat 1 with both points verified to the unit. Two more
  things that could have written a whole curve in the wrong bar are closed: the roll anchor
  now has to SEE a bar before the range before it accepts a crossing (`logic_set_playing`
  was measured starting at bar 40 with the playhead reading 51 — the old one-sided test
  would have anchored there, written the curve there, and had its own replay confirm it),
  and every verification park is read back so a sample is filed under the position the
  playhead reached, never under the one that was requested. **Faster with it**: the dB →
  fader translation that used to run per call — 10 003 ms of a 26 523 ms pass, and the
  reason a curve tool moved the track's static volume — is cached per project and Logic
  build, cross-checked against the strip's own dB and Logic's fader echo before any of it
  is reused, and retired outright when it disagrees; a 2-bar curve measured 20 629 ms with
  the playhead 38 bars away against 30 739 ms before, and 6 049 ms for a one-bar pass that
  moved no fader at all. A strip with no track header — an aux, a bus, Master — is refused
  in ~1 s with the cause named and nothing written, where it used to spend 10 364 ms,
  write and restore the strip's fader, and report a "readback mismatch" that reads like
  something worth retrying. Point placement also stopped taking its beats-per-bar from the
  control bar's signature AT THE PLAYHEAD: it comes from the project's Signature List at
  the first point's own bar, which also makes 6/8 three beats a bar instead of six.
- **A rename now proves itself in both channels, and takes 0.18 s doing it.**
  `logic_rename_region`'s description promised the rename was verified twice over; the
  inspector readback was taken and thrown away, and the one comparison that ran was
  case-insensitive — so `Crash` → `CRASH` went down the write path and could not be
  verified by the only check present. Both channels are now compared exactly, case
  included: the arrangement map has to show the new name on the region at that position
  AND Logic's own inspector has to read it back, and the two disagreeing is a
  `verification_failed` naming both values. Two names are refused before anything is
  written — `2 selected` and `... Defaults`, the strings Logic prints in that same name
  field for itself — because a region carrying one reads as a selection STATE to every
  Region-inspector tool: the rename path reads the panel before it writes, so the region
  could never have been renamed back, and its quantize, transpose, gain and fades would
  have become unwritable too. A region that already carries such a name (Logic's own UI
  will make one) is still renamed back normally, because the panel's subject is now
  settled by the arrangement — one region selected, and the map's name for it — instead of
  by sniffing a field the user can write. **Faster, and everything that was cut was a
  wait**: the 0.5 s blind sleep after the confirm is gone (both channels already carried
  the new name on the first look, 7 of 7), three arrangement walks before the write became
  one, and a warm rename measured **159–197 ms against 816 ms**, the region family's first
  sub-200 ms verified write; the no-op repeat is **70 ms against 209 ms**, a compare-and-set
  refusal **78 ms against 224 ms**, and a reserved name is refused in **0.3 ms** without
  touching Logic at all. The response lost the copy/paste groove note it never should have
  carried — a rename changes metadata, and that note was sending agents off to bounce a
  range and hunt a displaced snare a name change cannot cause — taking a successful call
  from **890 B to 434 B** and the no-op from 709 B to 259 B. Also new in the payload: the
  `track_number` the call resolved, so a rename on a project with two rows of one name says
  which row it wrote.
- **Taking a plugin off a track is as quick as putting one on.** `logic_remove_plugin` was
  8 553 ms and is 4 354 ms warm, measured over five removals on 2026-09-02 — the mouse-free
  removal was still running the browse loop the insertion side replaced two days earlier, and
  every mechanism it was missing is now shared rather than copied: the backward walk to the
  No Plug-in boundary is paced on the display actually changing, it jumps most of the distance
  using the catalog position a previous insertion already learned (the boundary sits at
  ordinal 0, so the distance IS that position), the blind second after the confirming press
  and the two blind settle sleeps are positive readbacks, and the surface is left on the
  insert list for the next plugin call instead of walking home to Pan. Every proof stayed:
  the LCD name before the press, the SELECT LED, the plug-in-list cross-check against
  Accessibility, the slot readback, and the duplicate-aware count check. Two refusals also
  got honest. The step bound used to be 400 MIDI MESSAGES, of which 15-23% were being
  swallowed, so it reached only ~330 entries of a catalog running past 590 and a plug-in
  deeper than that could not be removed at all; it is now counted in catalog ENTRIES with a
  wall-clock budget, and a browse that gives up says how many entries it saw and reads the
  last ones back. And the message for a browse that drifted off the boundary used to restore
  the surface BEFORE reading the display it was quoting, so it reported a pan value ('0',
  live) as the catalog entry it had drifted to — it now reports the cell it actually saw.

- **Strip silence tells you which number is which, and can no longer walk away from
  its own modal.** `logic_remove_silence` now reports each of the Remove Silence
  window's four numeric fields WITH the label Logic printed beside it, plus stable
  keys (`threshold_db`, `minimum_silence_seconds`, `pre_attack_seconds`,
  `post_release_seconds`) and the value parsed for you — Logic prints these in the
  system's locale, so the reference Mac's `-28` threshold arrives beside `0,1000`
  and a caller running `Double()` over the string gets nothing. The result note and
  the tool description used to name those four in an order that was not the order
  they came in, so an agent read the −28 dB threshold as a post-release TIME; both
  now match what the window publishes, and the zero-crossing flag is keyed
  `zero_crossing` instead of by Logic's own English label. **The window is found by
  APPEARANCE, not by its English title.** It is modal (measured), so a translated
  title used to leave it standing — swallowing Logic's keyboard and every later tool
  call — while the source comment claimed the failure was safe; the tool now takes
  the window that opened when the command fired, corroborates the title or the
  shape, and Cancel-and-refuses anything else rather than pressing OK on a dialog it
  does not recognise. The Cancel is now PROVEN: the modal is watched out of Logic's
  window list instead of being followed by a 0.3 s sleep that checked nothing —
  measured 2026-09-02, it leaves at once on about half of calls (60 ms) and lingers
  half a second on the rest, which the old sleep was returning through. **And it is
  the sixth region command to get the guard the other five share**: `apply: true`
  clears the project-wide selection with Logic's own Deselect All, proves it landed,
  selects the target back and checks the region total across EVERY rendered row —
  so a strip that also cut a region on one of the ten unrendered rows of the
  reference project is now a loud failure instead of `success: true, verified: true`.
  The result says `selection_scope`, names the regions Logic made in
  `produced_regions` and warns that all of them come back SELECTED. Measured on the
  sandbox: preview 187–1 245 ms (best 187 ms against a flat 505 ms before — one
  arrangement walk instead of two, and no blind sleeps), apply 1 245 ms against
  733 ms, the difference being the project-wide clear that makes the exclusivity
  claim true. A preview that changes nothing also stopped shipping "You changed the
  ARRANGEMENT" beside its own "NOTHING WAS CHANGED": the listen note is gated on the
  payload now, so every preview and every verified `already_*` no-op across the
  server is quiet.

- **A long render comes back audible, or says why not — and puts the playhead back.**
  `logic_render_track` promised its sound rode along and, on a full-track render,
  delivered nothing: the ear copy encoded the WHOLE file at 64 kbps and was thrown away
  above the 400 KB an audio block may hold, so a 136.7 s freeze render arrived with no
  audio block and no note (2/2 measured), after spending 933–1 004 ms producing it. The
  length now decides before anything is encoded: a short render is carried whole, a long
  one carries a bounded WINDOW of its first ~42 s — seeked and decoded like
  `logic_get_audio_clip`, so only the window is read — named in `listen_note` and
  `audio_window`, with the whole file at `path` and any other stretch one clip call away.
  When no block can be made at all, the note says why and where to listen instead. The
  render also stopped moving the user's playhead behind their back: a freeze jumps it to
  the project start and rolls from there, so where it was is read first and restored
  afterwards, verified against Logic's control bar and reported in `playhead` (a failed
  restore warns and names the position it was left at). And the captures folder is no
  longer unbounded — it had grown to 169 files / 1.2 GB, a render being the whole project
  length whatever bars are asked for — so every tool that writes there now keeps the
  newest 200 captures within 2 GB and reports anything it removed in `captures_pruned`;
  the budgets sit above what any existing folder holds, so updating deletes nothing you
  already have. **Faster with it**: the render's own work is ~1.3 s cheaper — the 0.4 s
  blind settle is replaced by the track-header read that was already on the next line,
  and the 0.9 s three-round flush floor by the AIFF's own declared size and frame count.
  A bar-range render saves another ~1.2 s, because the AAC preview is now of the SLICE
  rather than of the whole track, and that preview IS the audio block: measured
  7.86–7.95 s before, **7.03–7.11 s** after (5.30 s on one call whose playhead restore
  was skipped). A whole-track render spends its saving on putting the playhead back and
  comes out level, 8.29 s before against **8.13–8.55 s** after, now WITH the audio
  actually attached; the restore costs ~0.08 s per bar of distance, so a playhead 55 bars
  from the project start makes it 11.8 s. `include_audio: false` now skips the encode
  instead of paying for a block that gets dropped, and the A/B's two renders skip both
  the block and the preview.
- **Renaming a track is instant, and the track answers to its new name straight away.**
  `logic_rename_track` was 1 386–1 615 ms and is 263–479 ms, measured old binary against new
  in one session on 2026-09-02 — 76% of the old call was three blind sleeps waiting for
  things that were already there (the inline editor is focused and pre-filled within a
  millisecond of the key command; the header column carries the new name before the first
  sleep began; the "lingering rename popover" the third sleep guarded has never once
  appeared). The waits are gone, the popover close now rides on the verification poll's miss
  path, and every proof is stronger than before. The big one is not the speed: after a
  rename, the renamed track used to be unreachable by EVERY tool that selects a track first
  — Logic does not repaint the inspector strip's name while the renamed track stays
  selected, so a perfectly correct follow-up call spent 8.5 s and then refused, quoting the
  very row it had been asked for. Measured on the same track, same session: 8 480 ms refusal
  before, 396 ms success after, with no selection bounce. The readback that caught the
  wrong-strip bug is kept; it now tells an unrepainted name from a different track. Renaming
  also VERIFIES the row you addressed rather than looking for the new name anywhere in the
  list, so `Inst 2` → `INST 2` is a real rename that is proven as one, and renaming a track
  to the name it already has fires nothing at all and says `already_named` in 50 ms instead
  of writing and charging 1.4 s for a "rename" that never happened. The result now names the
  row afterwards (`renamed_track`, `previous_name`), a row scrolled out of view comes back
  `renamed_not_visible` instead of a failure claim about a rename that landed, `track_number`
  addresses one of two rows sharing a name — the state `logic_duplicate_track` leaves behind,
  and this is the way out of it — and a name another row already carries is refused rather
  than turned into a pair no name-addressed tool can reach. And the control surface's bank
  map, whose cells ARE track names, is finally forgotten after a rename: this was the only
  track mutation that left it stale, and the staleness was invisible (the bank match tolerates
  exactly one differing cell, which is exactly what a rename produces), so it survived a whole
  session. The next surface call rescans instead, measured at 1 378 ms on the reference
  project.
- **A recorded take contains only what was played.** `logic_record_midi` wrote sixteen
  spurious `Control 64 = Sustain, 0` events into every region it made: the cleanup fired
  the stream's stuck-note all-notes-off BEFORE it stopped the transport, and that blast
  goes into the very "Logic MCP MIDI In" port Logic is recording from. A two-note take read
  back through `logic_list_events` as **eighteen** events, twice, while the result claimed
  four. The transport is stopped first now, out of record is CONFIRMED on the MCU record
  LED, and only then is the stream silenced — and where that confirmation fails the blast is
  withheld and named in a `warning`, because a stuck note is a sound the user can stop and
  sixteen controller events in their region are not. A two-note take now reads back as
  exactly two notes, 4/4 takes, and `events_streamed` counts events the way Logic's Event
  List does so it can be diffed against it (the wire count lives on as
  `midi_messages_streamed`).
- **The take lands on the beat instead of somewhere in a 46 ms band.** The sync waits for
  the pre-roll bar's last beat and used to assume exactly one beat of lead remained —
  but the edge is seen when Logic next repaints the position display, not when it happens,
  and five measured takes landed anywhere from 22.9 ms early to 23.4 ms late on identical
  arguments. The same repaint publishes the sub-beat digits, so the lead is now READ off
  the position (`sync_lead_route`, `sync_position`) rather than assumed: three takes with
  no compensation at all then landed 16.1, 17.2 and 20.3 ms late — a **4.2 ms** band where
  the assumed beat gave 46 — so 18 ms, the mean of those three, is what the default
  subtracts, and two takes at it landed **0.0, 1.0, 2.6 and 2.6 ms** off the beat. Where Logic blanks those digits the lead is the nominal beat again and the
  route's own measured latency is subtracted instead (46 ms inside Logic's count-in bar,
  23 ms inside a pre-roll bar the tool parked; the single 45 ms default that shipped put
  the latter 21.5 ms early), which centres the band rather than removing it, and the note
  says so. Which branch ran is in the result:
  `bar_line` means the edge was missed, there is no lead to schedule into,
  `sync_compensation_ms` does not apply — it silently did nothing there before — and the
  notes land ~39 ms late.
- **A take at bar 2 no longer times differently because the playhead was left in a 5/4
  bar.** The pre-roll bar's beat count came from the control bar, which publishes the
  signature AT THE PLAYHEAD: with the playhead 39 bars away in the project's 5/4 stretch,
  the sync waited for a fifth beat of a four-beat bar, never saw it, and fell into the
  uncompensated branch. It reads the Signature List at that bar now (`sync_meter_route`),
  the same map the notes are placed by, and the beat edge fires from anywhere in the
  project. `tempo` in the result is likewise the tempo the take RAN at rather than the one
  in force wherever the playhead was parked (121 was reported for a take at 120).
- **The result names the region it made.** `created_region` carries the track number, the
  start bar, `recorded_end_bar` and the `logic_delete_region` call that removes it —
  measured 0.7 s with `regions_before`/`regions_after` as evidence — instead of a
  description telling the caller to reach for Undo. `recorded_end_bar` is past `end_bar` on
  purpose: Logic keeps recording for the 600 ms tail after the last event.
- **A MIDI take costs a third less wall clock.** Measured end to end on the same two-note
  take with the playhead 39 bars away: **26.5 s before, 18.3 s after**. `setPlaying(true)`
  before a freeze render waited out its full 2.25 s budget for a play LED Logic never
  lights during an offline render — 2 487 / 2 487 / 2 474 ms, three values inside 13 ms of
  each other, with the throw swallowed by a `try?` and the render's own proof (the `.aif`
  and `FreezeInProgress.lock`) found 0.2 ms later — so it is a press now, and that lands on
  `logic_render_track` and `logic_evaluate_change` as well. Logic's own count-in bar is
  read rather than paid for blind: it is a whole extra bar of real time that nothing in the
  tool looked at although `logic_get_transport` has always reported the flag, so with
  count-in on the playhead parks ON `start_bar` and the count-in bar leads in — one bar of
  wall clock instead of two, −2.0 s at 120 BPM 4/4. And the 0.6 s blind sleep before the
  record press became the decisive display read that was already written eight lines below
  it, which costs 0.4–1.3 ms and catches strictly more.
- **A take can no longer start at the wrong bar and call itself verified.** The sync
  accepted the first position at or past `start_bar` once the timecode had visibly moved,
  which proves motion and not position; the pre-roll bar must be observed first now, and a
  transport already past it refuses instead of streaming the whole take somewhere else.
- **The playhead comes back where you left it, or the result says so.** The cleanup
  `defer` restored `barNumber: bar, beat: nil` — the beat was never even captured, let
  alone put back — and threw the outcome away either way with a bare `try?`. Measured
  live: a take from bar 1 with the playhead found at bar 56 came back at bar 56 beat 3
  (only the bar converged), and once the verification render's own playhead jump (freeze
  moves it to the project start and rolls from there) landed on top of that with nothing
  restoring it afterward, at bar 5 beat 4 — nowhere near 56 — both times `verified: true`
  with no warning. Both bar and beat are captured and restored now, the verification
  render restores its own move too since it is the last thing to touch the control bar, and
  either attempt's outcome is reported in `playhead {restored | already_at_baseline |
  not_restored, bar, beat, left_at}` with a top-level `warning` naming the position it was
  actually left at when the restore fails — the same contract `logic_render_track` reports.
- **The metronome toggle is fast now: 172-181 ms down to 4-20 ms warm, 8.9 ms down to
  1.4 ms already-set.** Its verification used to sleep 150 ms BEFORE every look — up to
  twelve times — although the press's own event wait had already confirmed the LED landed
  in 0.3-7.4 ms; the loop now checks that result first and sleeps only on an actual miss,
  the way the rest of the surface's wait loops do. It also used to read the control bar's
  Metronome Click checkbox through a full Accessibility walk FIRST on every call, including
  the already-set fast path, even though the free, always-populated click LED is the
  fallback of record and — on the project this was measured against — the only one that
  ever resolves; the LED is asked first now, and the checkbox is a fallback for when the
  LED itself cannot be read.
- **`logic_set_cycle` and `logic_set_playing` no longer downshift to the slow
  Accessibility fallback just because Logic has been quiet for a while.** Both gated on a
  bare in-memory mirror read that returns nothing once it is older than ten minutes, where
  every other control-surface tool wakes an idle-but-live surface with one probe press
  first; an agent that came back to an idle session would see cycle and play/stop toggles
  silently get slower and lose their control-surface verification story instead of just
  working. They use the same wake-aware gate as the rest of the surface now.

- **Plug-ins work on a Drum Machine Designer track, and a plug-in the surface cannot find
  says why.** Every plug-in write on the main track of a summing track stack was refused —
  `logic_add_plugin`, `logic_remove_plugin` and `logic_set_insert_bypass` all answered "the
  PL view is pointed at another channel" for a strip that was correctly selected, and a
  stray insert on such a track could only be got off it by closing the project without
  saving. Two independent reasons, both measured live on 2026-09-02 and both now fixed.
  Logic hosts the stack's instrument on an AUX-shaped strip — no Input slot and, unlike
  every other instrument track, no MIDI Effect slot — so `Drum Machine Designer` was
  counted as an eighth insert against a surface showing seven; the instrument is now found
  by the insert column's own top edge, which the column marks with its empty slots and
  dividers, and an output strip or a bus aux still gets no instrument invented for it.
  And a BYPASSED insert spends one of its six LCD characters on the bypass marker, so
  `Overdrive` arrives as `*Ovrdr` and the six-character plausibility floor threw out all
  five bypassed inserts of that strip; the floor now knows what the marker cost.
  **A search that comes back empty-handed also stopped being a dead end**: the same
  `logic_add_plugin {plugin_name: "Parametric EQ"}` finds it at catalog entry 1 on a stereo
  strip and walked 226 entries in 15 s on a mono one, because the strip's channel format
  chooses which catalog Logic offers — the refusal now names that catalog, quotes the
  entries the browse opened on and the ones it stopped at, and says the plug-in may be a
  strip of the other format away. And when the mouse-free route bows out, the refusal says
  what actually happened instead of "the MCU bridge is unavailable" — which live was false
  three times out of three, the real cause being the insert list needing one more press.
  **The browse also stopped counting Logic's own answer to it as a plug-in**: selecting the
  strip paints the channel's NAME across the cells the browse field spans, it stays there
  until the browse repaints the row, and a walk that counted it as catalog entry 1 shifted
  every ordinal after it — which is how `Gain`, `LoPass ParEQ` and
  `Cha EQ Cha EQ Cha EQ Cha EQ` came to sit at position 1 of the learned catalog. It is
  recognised for what it is now, on both the insertion and the removal side.

- **The insert list comes up when it is asked for.** `logic_list_inserts {route: "mcu"}`,
  `logic_add_plugin` and `logic_remove_plugin` all open by putting the surface's eight-slot
  plug-in view on screen, and roughly one call in fifteen used to give up one press short —
  writing nothing, reporting the bridge unavailable, and leaving the surface parked in a
  per-insert parameter bank (which is the state that makes Logic auto-open a plug-in window
  on the next track selection). Measured: the surface's PLUG-IN button ALTERNATES between
  that bank and the list, and the bank paints the same top row as the neutral view, so the
  loop could not see which half it was in and each press went into the previous press's
  unfinished repaint, which Logic swallows. Each press now waits for Logic's own answer
  before the next one, a browse someone left standing on a slot is recognised for what it
  is rather than read as slot contents, and a loop that still cannot get there says what it
  saw and hands the surface back to the neutral Pan view.

- **Selecting many regions is twice as fast, says which way the selection moved, and no
  longer fires blind.** `logic_select_regions` slept 0.25 s before it ever looked at the
  count it was waiting for, and the count had already moved on the first look in 8 of 8
  measured calls; it looks first now, keeping a 0.4 s budget for the genuinely slow case,
  and the anchored modes walk the arrangement once instead of twice. Warm, measured on
  the same project minutes apart: `none` 442–470 → **202–204 ms**, `all` 443–453 →
  **199–207 ms**, `track` 632–650 → **278–291 ms**; cold 573 / 558 / 731 → **337 / 337 /
  406 ms**. The two calls with nothing to do were the worst of all — a `none` on an empty
  selection and an `all` on an already fully selected project each burned the full eight
  sleeps, 2 766 ms and 2 788 ms, and now cost **211 ms** and **197 ms**. A clear also says
  it cleared: `mode: "none"` used to report `state: "selected"` on every successful
  deselection (6 of 6 live, each with `selected_count: 0`), so a caller reading `state`
  rather than the count read a clear as a selection; it reports `cleared` now, or
  `already_clear` when nothing was selected to begin with. And `all` and `none` were the
  only two paths in the region family with no Tracks-area keyboard focus probe — the
  precondition that makes one of these commands do nothing at all, silently, when it is
  missing. They now take the same probe as every sibling, repaired against whatever track
  is already selected so nothing else moves, and carry `key_focus` in the result: live,
  with a plug-in window standing open, `mode: "none"` cleared its three regions and said
  `key_focus: unverified (AXWindow 'dialog')` where it used to say nothing at all, and a
  failure in that state now names the focus as its first suspect.
- **A duplicate that did not happen says so.** `logic_duplicate_track` used to answer
  `duplicated_not_visible` — *"the copy may be off-screen, scroll and re-read"* — whenever the
  rendered rows had not changed, on any project that renders part of its track list, which is
  most of them. So a key command Logic silently declined came back looking like a copy the
  agent simply could not see: measured 2026-09-03 on the reference project, duplicating the
  `Drums` stack took 4 415 ms to say exactly that about a project where nothing at all had
  happened. Now the two are told apart by evidence. A copy lands directly BELOW its source and
  renumbers every row under it, so rendered rows below the source that kept their numbers
  REFUTE the insertion, and the result is `state: "unchanged"`, `insertion_refuted: true`, and
  a sentence naming the cause — including the one this found: **Logic does not duplicate the
  main track of a folder or summing stack**, while the subtracks inside it duplicate normally
  (`Fill` in 463 ms, a plain `Crash` in 563 ms, minutes apart on the same project). No
  `duplicated_` state can be claimed over a census that did not move by one character, and the
  same rule now guards `logic_create_track`.
- **A track hidden behind a collapsed stack is no longer refused like a typo.** Ten of the
  reference project's twenty-nine tracks live inside one collapsed stack and are not rendered
  at all, and asking for one by name got the same sentence a misspelling gets. The refusal now
  says the list is provably short of the project, names the track numbers that exist and are
  not in it, and names the stack and the exact call that opens it —
  `logic_set_track_stack {track_name: "Drum Synth Kit", track_number: 9, expanded: true}`. The
  evidence was already being computed for `logic_list_tracks`; only the refusal was not
  carrying it. A name that nothing proves missing still gets the plain refusal, so the two
  messages differ exactly where the two situations do.
- **A region's parameters are that region's parameters.** `logic_get_region_params` was
  reading the wrong region and saying nothing about it. It selects the region you name and
  then reads Logic's Region inspector — but Logic repaints that panel a few milliseconds
  later than it moves the selection, so the read landed on the region the PREVIOUS call had
  been looking at and reported its twenty-two rows under the name of the one you asked for.
  Measured live on 2026-09-02, reading two regions alternately: **5 of 6 reads came back
  with another region's values** (a read of `Latin` at bar 13 answered with `Crash`'s panel),
  and nothing in the payload said so. The tool now waits for the inspector to name the
  region it addressed — a 7 ms look, repeated only while it disagrees, against a 0.3 s
  budget — and refuses rather than answers if it never does. Same alternation after the fix:
  **6 of 6 correct**, at a cost of 6–27 ms. `logic_set_region_params` was hiding the same
  race behind a 72 ms arrangement walk it took for an unrelated reason; the walk is gone and
  the explicit wait is in its place, so a write is **533–569 ms against 623–637 ms** and a
  no-op **151 ms against 228 ms**. Both tools also stopped deciding whose parameters are on
  screen by sniffing a text field the user can write: a region genuinely named `2 selected`
  or `MIDI Defaults` — Logic's own UI makes them — used to read as a selection state and was
  locked out of its own quantize, transpose, gain and fades for ever. The arrangement now
  breaks the tie, exactly as `logic_rename_region` already did, and a genuine
  multi-selection still reports itself honestly (`subject: multiple`, two regions selected,
  49 ms).
- **`logic_add_plugin` stops refusing writes Logic actually abbreviates further.**
  The `ParEQ`/`Parametric EQ` fix only tolerated an abbreviation that kept its first
  three characters verbatim, which is not what Logic does whenever it drops a
  character inside them: `Low Pass Filter` arrives as `LoPass` (`Low` loses its
  trailing `w`) and `Overdrive` arrives as `Ovrdr` (drops the interior `e`), so
  adding either landed correctly and the cross-check refused it anyway —
  `verification_failed`, `restored: false`, with the plug-in left in place because
  the tool believed its own write had failed. Measured twice live on `Crash`. The
  match is now the word-by-word walk Logic's own truncation follows: a word, once
  used, keeps its own first letter and then may drop interior vowels or close
  early, never a consonant skipped outright — which is also what stops two real
  plug-ins that share every word but their first (`Bass Amp Designer` /
  `Guitar Amp Designer`, both plausibly `AmpDes`) from ever both answering to the
  same abbreviated name: a collision comes back `false` on both sides rather than
  a wrong `verified: true`, leaving the slot-index proof to settle it.
- **`logic_list_inserts {route: "ax"}` now flags the instrument's own row.** An
  occupied INSTRUMENT slot has the identical bypass/open shape as a real insert, so
  this route always listed it as one more insert with nothing marking it — while
  `logic_track_info`, reading the same strip, already reported that row
  `is_instrument_slot: true`. The two now agree: measured live on `Drum Synth Kit`,
  8 rows here (one flagged) reconcile against route `mcu`'s 7 inserts, which never
  counted the instrument at all and is unchanged.

- **Stopping playback no longer moves the playhead.** `logic_set_playing` decided both
  "is Logic playing?" and "did my press land?" from a single lamp on the control surface —
  the play LED — and that lamp can get stuck and stay stuck. Live on 2026-09-03, racing a
  few play and stop presses left BOTH transport lamps lit at once while Logic itself read
  stopped, and from then on the tool was wrong in both directions: `playing: true` came back
  `already_playing` in 3.8 ms with nothing pressed and Logic standing still, and
  `playing: false` pressed stop at an already-stopped Logic — which is Logic's rewind, not a
  stop, so **the playhead jumped from bar 40 to bar 1** — and then spent 2 581 ms waiting for
  a lamp change that a no-op press can never produce before throwing `verification_failed` at
  a caller whose transport was exactly where it had asked for. Three tools stop through this
  same call (`logic_record_midi`, `logic_record_automation`, `logic_render_track`), all of
  them discarding the error, so the cost landed silently. Now the state is settled by three
  independent witnesses — the play/stop lamps read as a PAIR, Logic's own Play button, and
  whether the position display is advancing (measured: 125 repaints in 2 s while playing,
  none at all in 1 s while stopped) — and a stop is pressed only when they agree the
  transport is really rolling. The same desynced surface now answers `already_stopped` in
  268-314 ms with `led_desync: true`, a warning naming what each witness read, no press and
  the playhead where it was; asking to play presses for real, which is also what resyncs the
  lamps. The healthy path is unchanged (start 41-92 ms, stop 21-35 ms, verified no-op 4.5 ms),
  and a press whose lamp echo never arrives is now verified by the other two witnesses instead
  of failing — with the poll budget it does keep honoured to the millisecond (a stated 2.25 s
  used to run to 2.48-2.56 s because the deadline was only checked between rounds).

- **A new project now says which track it came with — and lets you choose it.** Logic will
  not show a project with no tracks, so its Create New Track sheet stands over every
  `logic_new_project` and every create therefore makes one track. The tool answered that sheet
  but described the result only in prose, in a dialog log, never naming the track or its kind.
  The result now carries `initial_track`: the kind as the sheet itself spells it
  (`MIDI/Software Instrument`, `Audio/Mic or Line`), `category` and `variant` separately, and
  the `track_number` and `track_name` read back from Logic's own track list — one call instead
  of two. Pass `initial_track: "audio"` (or `"software_instrument"`, or any label the result's
  `offered` lists) and that is the kind you get instead of whichever was last used on that Mac:
  live 2026-09-03, `"audio"` produced `Audio 1` and `"software_instrument"` produced `Inst 1`,
  in 2.35 s and 3.67 s against 2.10 s for opening a project that already has a track. The
  chooser is read the way the sheet is really built — four category groups, each over its own
  radio group, only one of them marked selected — because the obvious flat reading of it
  reported `Software Instrument` for a create that made `Audio 1`, and what the press achieved
  is read back off the sheet rather than assumed. A kind this Logic does not offer is not a
  refusal: by then the project exists and cancelling that sheet would close it, so it opens
  with the sheet's own selection and a warning lists the real vocabulary.
- **A freshly created project no longer starts life with a plug-in window standing over it.**
  Logic opens the new track's own instrument window unasked whenever `initial_track` is a
  software instrument — measured 2026-09-03, `Inst 1` as an `AXDialog`; an `audio` create opens
  none, 5/5 — and `logic_new_project` neither reported nor closed it, so the very first call an
  agent made against a new project could land on the window every region tool's
  `key_focus: unverified` already names as the cause. The tool now detects it the way
  `logic_list_windows` does (the subrole, never a guess) and closes it the way
  `logic_close_plugin_window` does — one mechanism, not two — reporting the outcome in
  `dialogs_closed` (always present, empty when there was nothing to close). **The window is not
  there yet when the track is**: Logic opens it asynchronously, 1.13–1.60 s and 1.25–1.83 s after
  the old call would already have returned, on two independently timed live creates — a look
  taken the instant the track exists finds nothing, 5/5 — so a software-instrument create now
  waits up to 2.5 s (look-first, no blind sleep) for the window it expects before returning; an
  audio create, measured to never raise one, pays a single ~1 ms look instead. Live proof
  2026-09-03: two software-instrument creates at 5.69 s and 4.75 s each closed their own `Inst 1`
  window (`logic_list_windows` showing the project window alone afterwards), one audio create at
  2.63 s reported `dialogs_closed: []` honestly with no window ever appearing over 5.7 s of
  watching. A window that will not close carries a `warning` naming `logic_close_plugin_window`
  as the way out rather than going silent about it.
- **With a plug-in window or the Mixer in front, the region tools stop stalling and start
  telling you why.** Every region tool checks that Logic's Tracks area has the keyboard
  focus before it fires a key command, and repairs it if it does not — a real cure, when the
  focus is somewhere in the project window. But when the front window belongs to somebody
  else, no repair is possible: an Accessibility write cannot take the key window away from
  another window. The tools spent about a second and a quarter discovering that, every call,
  and then said only that the focus was unverified. They now look at which window holds the
  focus first, and if it is not the project window they skip the repair they cannot make and
  name the window and the one call that closes it — `logic_close_plugin_window`, or
  `logic_set_mixer {open: false}`. Measured live on 2026-09-03 with a Space Designer window
  open: `logic_select_regions` **1 565 → 214 ms** (`mode: "none"`) and **3 274 → 499 ms**
  (`mode: "track"`), `logic_copy_region` **6 547 → 2 173 ms**, `logic_delete_region`
  **2 567 → 969 ms**; with the Mixer up, `logic_select_regions` **1 916 → 742 ms**. Every
  one of those calls still did its work and still verified it — only the waiting is gone.
  Nothing changed where the repair does work: right after a List Editors read the focus is
  outside the Tracks area, and it is still put back (320–327 ms, unchanged), and a healthy
  call is untouched (`logic_select_regions` 168–256 ms before, 169–268 ms after).
- **The three tools that stop through `logic_set_playing` on their way out now say what the
  stop found.** The fix above settled the press itself; `logic_record_midi`,
  `logic_record_automation` and `logic_render_track` still called it from their own cleanup
  through `try?` and threw the verdict away — a stop verified through a fallback witness
  because the LED never echoed, or refused outright because no witness could say Logic was
  rolling, came back indistinguishable from a clean, silent stop, and a `led_desync` warning
  had nowhere to surface. Each of the three now reports the cleanup stop's own verdict as
  `transport_stop` (`state`, `transport_witnesses`, `led_desync`), plus a top-level `warning`
  when the LEDs disagreed or the stop was refused. The cleanup order itself is unchanged —
  stop, then confirm out of record, then silence.
- **Moving the playhead is instant now, and every tool that parks one got faster with it.**
  The shared stepper behind `logic_set_playhead` slept a flat 0.12 s after each write to the
  control bar's position display — one write per bar, so a locate cost 125–132 ms per bar of
  distance. Measured per write on that slider (69 steps, 2–23 bars, both directions): the
  write itself takes 0.7–1.9 ms and the display lands **0.05–1.4 ms later, median 0.08 ms**.
  The sleep was 99% of the cost of every playhead move in the server. It now watches the
  slider instead, with the old 0.12 s left as the deadline so a stuck display gets exactly as
  long as before to prove it. Same session, old binary then new: `logic_set_playhead`
  **266 → 21 ms** (2 bars), **1 281 → 20 ms** (10 bars), **2 982 → 72 ms** (23 bars),
  **6 660 → 62 ms** (53 bars); `logic_set_cycle_range` **14 393 → 1 467 ms** (same length)
  and **12 268 → 2 040 ms** (length change, which drags); `logic_copy_region`
  **2 506 → 918 ms**; `logic_delete_region` **702 → 563 ms**. Sixteen call sites inherit it:
  every region tool that parks, tempo sampling, automation read and record, MIDI record,
  marker parking and `logic_import_midi`.
- **A playhead move no longer changes a beat nobody asked about.** Logic shifts the sub-bar
  position on longer bar moves — measured this session on the old binary: `bar: 33` from bar
  56 landed on beat 4 having started on beat 1, silently, and the same happened at the
  project's last bar (beat 3 → 1). `logic_set_playhead` now reads the beat before and after,
  puts it back when the call passed no `beat`, and says so in `warning` — including when it
  cannot put it back, which happens at the final bar. A locate that fails also returns the
  playhead to where it found it instead of abandoning it mid-climb: asking for bar 93 on a
  64-bar project used to cost 1 585 ms and leave the playhead at 64, and now costs 146 ms and
  leaves it where it started (`Restored: true`).
- **Setting the cycle range leaves Cycle mode exactly as it found it, and reaches ranges that
  are scrolled out of view.** The drag that resizes the locators engages Cycle the way it
  would for a human: a call with no `enabled` argument turned it on and nothing turned it
  back (reproduced live). Both routes now read the button before anything is written, undo an
  unrequested flip, and report `cycle_enabled_before` alongside `cycle_enabled`. And a range
  outside the visible ruler used to be a dead end — the refusal said "scroll or zoom Logic",
  which nothing in this server could do. It now scrolls the ruler itself, measures the shift
  against the ruler's own Start marker until the range is in view, and only refuses if the
  ruler will not move — naming the pixels it managed and the pixels it needed.
- **The cycle range lands on the bar you asked for, on a project that changes meter — and a
  write that misses puts the locators back.** A bar's width on Logic's timeline follows its
  meter, and this tool used to place both locators by multiplying out the ruler's single
  average slope: on a project that goes 4/4 to 5/4 at bar 41, that was **0.30 to 1.01 bars
  wrong** at every target measured this session, which is most of the way to the wrong bar.
  It now MEASURES the two bar lines it is about to write to, by parking the playhead on them
  and reading the ruler — the same evidence its anchor has always used, and cheap since the
  playhead stepper got its look-first poll — and holds them as offsets from the ruler's own
  Start marker so they survive Logic scrolling underneath. The result reports the route and
  how far the old straight-line ruler would have missed. Same session, old binary then new:
  bars 20-24 went from a refusal (`start is 0.97 bars off`) to a verified write, and bars
  43-47, 39-43 and a 6-bar drag all landed verified where the old binary could not even find
  the region. **The search that identifies the region's own bar was measuring in average
  bars too**, so a region parked past the meter change read as a bar away from itself and
  the tool refused every call for the rest of the session — the sandbox reached a state
  neither binary could leave. It now measures the bar's real width from the neighbouring bar
  line, converges from any distance instead of only from one bar out, and recovered that
  stuck project on the first call. And a write that fails verification is returned to the
  range the call read first, verified, and says `Restored: true` — proven by a fault-injected
  build that deliberately wrote two bars late: `start is 2.04 bars off ... Restored: true`,
  with the next call reading the original range back unchanged.

- **Touching the same track twice in a row is three times faster, and an idle Logic is no
  longer mistaken for a dead one.** Two shared control-surface defects, both hit live. First:
  Logic answers a mute or solo press by painting the word `Mute`/`Solo` over that strip's own
  name on the surface display for about two seconds, and the bank cache read its own echo as a
  sign that it was standing on the wrong bank — so mute-then-unmute, the compare-and-set idiom
  the tools themselves recommend, walked the whole surface back to the left edge and rescanned
  it for a bank it had never left. The cache now recognises a banner it caused itself, on the
  strip it touched, inside the banner's measured life, and accepts the bank; anything else —
  a renamed strip, a second changed cell, another bank — still pays the full rescan. Measured
  A/B live: five same-strip repeats **2 382-2 457 ms → 784-813 ms**. Moving to a DIFFERENT
  bank got faster too, for a related reason: the surface used to have to reproduce the cached
  row byte for byte before the arrival counted, so a banner standing anywhere in it — even one
  the cache itself had captured as a name — meant waiting out a match that could never happen.
  Arrival is now judged by the same rule, and a cross-bank write fell **2 405 → 1 170 ms**, a
  cross-bank verified no-op **2 037 → 805 ms**. And the map the surface writes down no longer
  records those banners as names: a scan that meets one lets it fade first, and a map that
  still carries one is not saved at all. Live, muting a track and then forcing a fresh scan
  wrote `Mute` into **all four** banks of the sandbox project's saved map before, and none
  after — where a poisoned map cost a measured 4.3 s on the next write to that bank. Second:
  after ten
  idle minutes the surface is woken with a probe press before anything refuses, and that probe
  was always `bank_left` — which moves nothing when the surface is already at the leftmost
  bank, where it most often rests. Logic sends nothing back for a press that changes nothing,
  so a completely healthy session was refused as unreachable (measured: 15 idle minutes, zero
  events across 3 s, every control-surface tool down). The probe now steps whichever way it
  can, and puts the bank back: at the leftmost bank `bank_right` answers in 25 ms where
  `bank_left` answered not at all, at the rightmost bank the fallback direction answers, and
  the surface is handed back on the row it was standing on.
- **Folding a track stack is fast now, and a no-op call barely touches Logic at all.**
  `logic_set_track_stack` fired a documented dead write on every real toggle — `AXPress`
  on the disclosure triangle, verified 2026-08-24 to be a silent no-op on Logic's track
  header controls — then polled it 5 times before falling back to the click that actually
  works: 730-786 ms, 55-57% of the call, spent on a route that could never succeed
  (profiles/logic_set_track_stack.md §5). It also ran the scroll-insurance `selectTrack`
  call unconditionally, before checking whether anything needed to change at all — 73-74%
  of a no-op call, for a scroll that stack 9 never needed once in 8 live toggles. The dead
  branch is gone, the state is read first so a no-op returns immediately, the scroll
  insurance runs only when the header genuinely is not on screen, and the header is walked
  once before a toggle and once after instead of three times. Measured 2026-09-03, same
  session, old binary against new: a real toggle **1 527-1 557 ms → 331-374 ms**; a no-op
  **403-444 ms → 41-54 ms**. The refusal → expand → select hidden row → collapse round trip
  still works exactly as before, live, both directions.
- **A track routed to `No Output` can be routed back.** It could not:
  `logic_set_track_routing` set that value happily and then refused every attempt to leave
  it, in either direction, three times over, ~21 s each, ending in "the routing slot's menu
  did not open" — a one-way door the tool itself made, and the only way out was leaving the
  tool for an Undo (profiles/logic_set_track_routing.md §3). The menu had opened every time.
  Measured live 2026-09-03: on a strip with no output Logic parents the slot's menu under a
  pop-up-button proxy that the inspector does not list among its own children, so no walk
  down Logic's tree can ever see it. The tool now also asks the window server what is drawn
  over the slot — one call, ~2 ms — and finds the menu there. `No Output` → `Stereo Output`
  now lands **verified in ~2.0-2.2 s, 4 times out of 4**, where the old binary failed in
  25.1 s on the same strip in the same session. Every routing write is faster with it: a real
  output change **3 659 ms → 1 967 ms**, back again **3 635 ms → 2 004 ms**, because the press
  that opens the menu no longer waits out a 1 504 ms reply Logic never sends and the blind
  0.45 s settle after the item press is gone (the verified readback that followed it already
  proved the same thing). The result now says which of the three looks found the menu in
  `menu_route`.
- **`output: "Mono"` is refused in 1.9 s instead of failing in 12.7 s.** It is a CATEGORY in
  Logic's menu — an empty submenu over the physical outputs — so pressing it opened a submenu
  and routed nothing; the tool then polled the slot 25 times over 6.7 s and reported a
  readback mismatch that also claimed `Restored: false` for a restore it had never attempted.
  Categories are now refused before anything is pressed, naming what to use instead, and a
  failure that attempted no restore says "No restore was attempted." A confirm-poll keeps its
  full 25-look budget but stops early when the slot has answered the same wrong label five
  times in a row: it has settled, and the rest of the budget only says so later.

- **A soloed or muted track no longer makes the region tools refuse their own answers.** Logic
  writes a track row's live state into the row's own description — `Track 26 “Crash”, solo` — and
  the arrangement map read that tail as part of the NAME while the track list read the same row as
  plain `Crash`. Every region tool addresses a row by name, so with one track soloed
  `logic_copy_region`, `logic_delete_region` and `logic_select_region` all refused the name the
  server itself had just reported: *"Track 26 is named 'Crash, solo', not 'Crash'"* — reproduced
  live, 5 of 5 calls, on a project whose only unusual feature was one soloed track. The two
  readers now share one parse, which takes the name from between Logic's quotes and lets the state
  outside them go: measured live on the same track, `, solo` (3/3 reads) and `, mute` (2/2) are
  gone from the name, a record-armed track turns out to publish no annotation at all (2/2), and
  the same select-copy-delete chain runs clean with each of the three flags set. The rule is
  structural rather than a list of English words, so a frozen or hidden row — and a translated
  Logic — drop their annotations the same way.
- **Checking before you press stops being the slow way to do it.** The three mixing writes
  all paid for evidence they then threw away. `logic_set_track_record_arm` watched the
  strip's record LED across a full blink cycle on EVERY call and discarded the answer
  whenever the track header's own Record Enable checkbox had already spoken — which is
  every call on a track you can see: a defensive "is it already disarmed?" cost
  **2 303 → 225 ms** and arming a track **1 952 → 203 ms**, both verified against the same
  checkbox as before, with the LED window still there for the tracks Accessibility cannot
  see. `logic_set_track_pan` moved the knob one raw step per 30 ms sleep, so the price was
  the DISTANCE: a hard-left-to-hard-right move cost **2 812 → 442 ms** and a small nudge
  **522 → 384 ms**, by looking at the knob first instead of sleeping at it. And
  `logic_set_track_volume` now answers `already_set` without turning anything when the fader
  is already where you asked (**2 965 → 713 ms**) and hands the mixer view to the next call
  the way the send and plug-in tools already do, which took the worst of nine consecutive
  writes from **4 483 to 2 481 ms**.
- **A strip that only exists in the last bank can be written to.** With a strip count that
  is not a multiple of eight, the control surface's final bank overlaps the one before it,
  and the walk out to it counted the presses it SENT rather than the bank steps that
  actually happened — Logic drops a press sent into an unfinished repaint, so `Master` on a
  25-strip project could report `not_exposed` for a strip sitting right there. The walk now
  counts what the surface shows: a swallowed press costs one retry instead of the whole
  navigation, and a genuinely stale map still gives up after the distance it was told,
  rather than walking the project. `Master` and `Stereo Out` volume reads, writes and
  restores verified live.
- **Arming a track and disarming it again is instant.** Logic answers a rec/ready press by
  painting `Record Enable` over the strip's name on the control surface — thirteen
  characters, so it covers the touched strip's cell AND its neighbour's, for about two
  seconds. The surface could already recognise its own one-word `Mute` and `Solo` echoes
  and carry on, but not a two-cell one, so the second half of every arm-on → arm-off pair
  read a bank map it could not match and rescanned the whole project: **6 230–6 732 ms,
  five times out of five**. It now knows how wide its own banner is and stays on the bank
  it never left — **164–321 ms**, with the track header's Record Enable checkbox
  confirming every one. Mute and solo are unchanged at **826–842 ms**, a cross-bank write
  still pays its real navigation, and a full scan run while the banner stands still
  refuses to write `Record` into the bank cache as if it were a track's name.

- **Two tracks with the same name are two tracks again, and reading them is twice as fast.**
  `logic_track_info` addressed rows by NAME, and Logic lets two tracks share one. The
  reference project has two called `Ivan Vocals`: asked for every track, the tool found the
  second one's name equal to the name it was already showing, skipped the re-selection, and
  reported the FIRST one's fader, pan and routing under the second one's track number —
  identical payloads, `success: true`, no note. Live proof of the fix on those exact rows:
  track 22 now comes back at **-14.6 dB, pan 0** against track 21's **0 dB, pan +9**, which is
  what the control surface independently reads off both strips; before, both said 0 dB and
  pan +9. Rows are addressed by number throughout now, `track_number` disambiguates a
  `track_name` the way it does everywhere else in the track family, and a name carried by two
  rows is refused with their numbers instead of resolved to the first of them. A strip that
  cannot be proved to be the row that was asked for is reported as `null` with a note, never
  read off whichever strip happens to be standing. The same pass took out what the reads were
  waiting for: a fixed third-of-a-second pause after a selection Logic had already confirmed,
  and a second full walk of the inspector tree for an element the confirmation was already
  holding. Measured live, 19 tracks: **24.6 s → 13.1 s**; three named tracks **6.4 s → 3.1 s**.
  `logic_survey_plugins` lost the same kind of pause after each plugin window — it now reads
  the parameters, reads them again 50 ms later and takes them when the two agree, instead of
  waiting 300 ms and reading once — and it walks for the track's channel strip once per
  survey rather than twice per insert, re-checking on every re-use that the strip it kept is
  still the strip it wants. Each insert now says in `open_state` whether its window really
  opened, so a window Logic never put up can no longer read as a plugin with no controls.

- **Tempo edits take about half the time, and changing the tempo no longer costs the next
  tool a second of re-reading.** Every `logic_tempo_events` write opened and closed Logic's
  List Editors pane three or four separate times — one cycle for the before-read, one for the
  action, one for the BPM stepper, one for the verifying re-read — and those cycles WERE the
  cost: a `set` that wrote no BPM at all (121 → 121, nothing to converge) still took **3.5 s**.
  The whole edit now runs inside ONE held pane, with every read and every verification still
  there. Measured live on the same project within one session: that no-op `set`
  **3 504 ms → 1 757 ms**, a delete **~4.2 s → 2 485 ms**, a create at bar 60 **5.8 s →
  3 185 ms**. A create also stopped rewinding a playhead that was already exactly on the grid,
  and stopped refusing outright when it did need to rewind: the control bar's "Go to Beginning"
  was pressed after a single scan of the bar's direct children with no second look, which
  refused **two of two** live creates that day with "'Go to Beginning' button in the control
  bar" — the same press, conditional and looked up again before it gives up, went through and
  landed the event at `60 1 1 1`. Two caches got more honest as well. A tempo write no longer
  drops the METER map it never touched (one no-op tempo `set` turned a `logic_list_signatures`
  cache hit of **10 ms** into a **1 186 ms** re-read of the Signature List, for nothing), and a
  successful `logic_set_tempo` on a single-tempo project now CORRECTS the cached tempo map
  instead of emptying it: the map afterwards is known exactly — same event, the BPM read back
  off the slider — so the next tool that needs bars→seconds gets it in **6 ms** instead of
  **1 243 ms**. That patch was checked against a forced fresh read of Logic's Tempo List, which
  agreed with it exactly; a map with more than one event is still forgotten rather than guessed.

- **A soloed track no longer renames every region in the project.** Logic writes a
  region's live state into the same string it publishes the name in, so a region reads
  `808 Mutation Bass, muted` while it is muted *or* while any other track is soloed — and
  the arrangement map handed that whole string back as the region's `name`. Measured on
  the reference project with ONE track soloed: **53 of its 54 regions were renamed by the
  reader**, across 14 of the 19 rendered rows, and `logic_select_region`,
  `logic_get_region_params` and `logic_delete_region` then refused the names
  `logic_list_regions` had just printed (`not_exposed`, 3 of 3). Every region reader now
  reports the region's OWN name with **`muted` beside it** — `true`, `false`, or
  `"unavailable"` where the name ends in a `, …` this build cannot read as a state word,
  which is what a localized Logic gets instead of a confidently wrong `false`. `muted:
  true` covers both causes because the element does not distinguish them. Both spellings
  of a name are accepted wherever a `region_name` is taken, so a name copied out of an
  older answer still lands. Verified live: the same three calls refuse on the old binary
  and succeed on the new one; muting a region reads back `{name: "Crash", muted: true}`
  and unmuting it — addressed by the annotated spelling — reads back `muted: false`; with
  the solo off, 0 of 54 regions report muted. The one name that cannot round-trip is a
  region literally called `Kick, muted`, which publishes the same bytes as a muted `Kick`;
  the guide says so.

- **Automation can be taken back off a track.** `logic_remove_automation` closes the last
  coverage gap the profiling campaign found: `logic_record_automation` could write a curve
  and `logic_read_automation` could see it, but nothing could remove one except a blind
  `Undo`. It drives Logic's own `Mix > Delete Automation > Delete All Automation on
  Selected Tracks`, which is TRACK-WIDE — every lane on the addressed row — and it proves
  the result rather than claiming it: the nominated lane is read before the press and read
  again after, and the result carries `points_before`, `points_after` and `verified`. A
  lane that already reads flat answers `already_empty` with nothing pressed, because a flat
  reading is what an unautomated lane and a perfectly flat curve both look like from here.
  A single lane and a bar range are refused with the alternative named: Logic's per-lane
  command deletes whichever lane the automation view is SHOWING, and with that view closed
  no track header publishes which one, so the press could not be aimed. Two guards stand in
  front of it — the selection is narrowed to ONE row (the menu item says *Selected Tracks*
  and means it), and Logic is brought to the front, because a menu press from the background
  answers `.success` and does nothing (measured 2026-09-03, three of six toggles). Verified
  live the same day on the sandbox: `Audio 9`'s leftover volume ramp (0 / −8.7 / −18.6 dB
  across bars 2–4) read back flat at −20 dB after one call, a fresh two-bar pass recorded
  and removed round trip, and a second call on the cleared lane answered `already_empty`.
  9.1 s for a verified removal at three sampled positions (the press itself is 0 ms; the two
  reads are the cost), 3.6 s for `already_empty`. It needs a track ROW, so a mixer-only aux
  or bus is out of reach and says so, and it leaves the control where the automation last
  put it rather than where it stood before the pass.
- **A recorded curve lands in the bars you asked for, or the call refuses and writes
  nothing.** `logic_record_automation` timed its schedule from the first bar it saw the
  transport reach, and the first thing a sync loop sees 10 ms after pressing play is the
  display Logic has not repainted yet — the bar the playhead was parked at. That one stale
  reading satisfied the "a pre-roll bar was seen" guard, so the NEXT reading was accepted as
  the crossing whatever bar it showed. Measured 2026-09-03 on the sandbox: the playhead
  parked and verified at bar 1 on both planes, a volume curve asked for at bars 2–4, and
  `logic_read_automation` then found it at bars 9–11 (−18.4 / −11.6 / −7.9 / −5.1 / −2.1 dB)
  with bars 2–4 still flat at the track's static −5.1 dB — and the verification replay,
  anchored the same wrong way, could report `verified: true` over it. The cause is Logic's,
  not the surface's: playback begins at Logic's own last play-start position, which was
  bar 9 five times out of five from three different verified parkings, one of them through a
  `Go to Beginning` locate. The crossing must now be INTO the first point's bar and must come
  from a display that has MOVED off the park; anything else refuses with nothing written and
  names the one thing that shifts Logic's play-start position (click the ruler there, or play
  and stop once from there). `roll_anchor` in the result says which bar the schedule was
  timed from, and a replay that could not run comes back as `recorded_unverified` instead of
  claiming the curve was written. `logic_read_automation` was right throughout — it parks the
  playhead and never rolls — so it is the way to check a lane while a project is in this state.

- **Refusal and survey messages stop claiming more than they know.** A ruler refusal
  (`logic_set_cycle_range`'s anchor search, its drag-clear step, and the pixels-per-bar
  guard) no longer renders as "the plugin window state changed as requested" — a template
  meant for plugin windows that used to answer for every non-plugin site sharing the same
  error case; it now names its own subject (`stateVerificationFailed`), and every genuine
  plugin refusal keeps its exact old wording. `logic_remove_plugin`'s not-found list is now
  read off the channel strip inspector, never the raw MCU browse cells, which could still
  be showing a stale catalog-scroll entry one cell had not yet repainted over after an
  earlier aborted add. `logic_survey_plugins` reports `{"unavailable": "<reason>"}` instead
  of the false `no_semantic_sliders` when a plugin's open could not be verified — an empty
  parameter list on an `unverified` open proved nothing about the plugin, only about a
  window that never appeared. And `logic_trigger_key_command`'s description now says
  plainly what its own profile proved live: a `success: true` means only that the bridge
  accepted the MIDI send, never that Logic acted on it — two identical `{name: 'Create
  Marker'}` calls returned byte-identical success while the marker count went 4 → 5 → 5,
  the second a silent no-op indistinguishable from the first without a readback. Several
  tool descriptions also lose their last stale timing literals: the Tempo/Signature List's
  flat "~2 s" becomes the measured 0.38-0.79 s / 0.23-0.66 s cold and ~7 ms cached, and the
  playhead-travel costs quoted by `logic_record_midi`, `logic_render_track` and
  `logic_read_automation` drop from the old ~0.13 s/bar to the 1-2.5 ms/bar fast locate
  `logic_set_playhead` already shipped (7ddf884).

- **A duplicate track name can be told apart on the control surface, by number.**
  `resolveChannel`'s LCD-name scan had no row numbers to weigh against a collision, so
  two strips that legitimately abbreviate alike — the sandbox's two `Ivan Vocals` rows,
  21 and 22, both read `IvnVoc` — could never be told apart, and a `track_number`
  argument had nowhere to plug in even where a tool accepted one. The AX track list's own
  numbering now breaks the tie: the Nth header carrying the name (by number) is matched to
  the Nth live cell (by bank position), so `track_number: 21` and `track_number: 22` land
  on different strips, proven by `logic_list_strips`; with no number and the AX list itself
  carrying the collision, the refusal names the numbers rather than guessing one, the same
  shape `track_info` already refuses a duplicate header with. A control-press banner
  standing over a neighbour's cell is dropped before it is ever counted as a second strip,
  and a match that is the SAME strip's row read twice — the shape behind a live, once-only
  failure (`'Audio 9' matches 2 control-surface strips (Audio9, Audio9)`, gone on the
  immediate retry) — gets one settled re-read before it is condemned as ambiguous, the same
  pattern the empty-bank-scan retry already uses. `logic_read_automation` and
  `logic_record_automation` both gain `track_number` for this — the read path also threads
  it into `logic_remove_automation`'s own two internal reads, so removing a lane on one of
  two identically-named rows no longer risks reading (and reporting) the other one's curve.
- **The tools/list surface a client pays for on every connect is smaller, and can no
  longer drift apart tool by tool.** A token audit measured 26 sentences repeated
  verbatim across the schema — the `track_number` disambiguation on 13 params, the
  `region_name` mute-state note on 13 params, the `insert_slot`/`insert_index`
  numbering caveat on 13 params, the `warning` and STRIP ADDRESSING pointers, the
  `blind`/`include_audio`/`expected_project_path` boilerplate — costing 16,762 B of
  pure repetition, none of it new information: the full explanation of each already
  lived in the server instructions every session reads once. Every inline copy is now
  the shortest pointer that still tells an agent where to look (`track_number`: "Row
  number when several tracks share the name — see TRACK ADDRESSING in the server
  instructions"), and the instructions gained two paragraphs — TRACK ADDRESSING and
  REGION NAMES — to hold what moved out. `tools/list` drops from 238,211 to 230,343
  bytes (52,837 → 50,992 tokens, cl100k_base); the server instructions grow by 955 B
  for what they now hold instead; the net per-connect cost (`tools/list` +
  `initialize.instructions`) falls from 247,596 to 240,683 bytes (54,894 → 53,257
  tokens), a 2.8% cut with no caveat dropped and no schema or behavior changed. The two
  `expected_project_path` compare-and-set wordings, still hand-typed on 10 tools, are
  now shared Swift constants too, so a future edit can no longer land on some copies
  and miss the rest.
- **A hidden Inspector no longer costs you the track tools.** Logic's Inspector is a pane
  the user can close (View > Inspector, or the `I` key), and with it closed every track
  tool crawled and then refused work that had already landed: `logic_select_track` took
  15.7 s to answer "Requested 'Bas', selection is 'Track 2 “Bas”'", `logic_track_info`
  29.9 s, `logic_record_automation` failed outright. The cause was the readback, not the
  write — the selection is cross-checked against the left inspector channel strip, and a
  strip that does not exist is not a strip that disagrees. It is now told apart from one:
  with no inspector plane to ask, the selected header row's own name is the verification,
  and the same three calls take 0.26-0.6 s, 1.1 s and a working automation gate. Tools
  whose payload IS the strip show the Inspector for the length of the call and put it back
  — `logic_track_info` reads 1.17 s against 30.1 s, with a payload byte-identical to the
  one it returns with the Inspector open, and `logic_list_inserts` reads the real chain in
  1.0 s. Every result that looked at the plane now says what it found (`inspector`:
  `shown` / `hidden` / `unavailable`), a call that showed it says so and whether it got it
  back (`inspector_shown_for_call`, `inspector_restored`), and a selection proved on the
  header row alone reports `readback_route: "ax_selected_header_row"` rather than claiming
  a strip confirmed it. A strip that still cannot be reached is refused in under a second
  naming View > Inspector, never by polling for half a minute. Showing the Inspector
  brings Logic to the front for the press: measured the same day, `View > Inspector`
  answers success and does nothing at all while Logic is in the background.
- **The key-command plane's hold is a parameter now, not a bare `usleep`.** Every
  `keycmd` fire — `logic_trigger_key_command` and 17 tools that ride the same plane —
  held its note on for a fixed 40 ms between note-on and note-off, unnamed and
  unconfigurable, ~96% of `logic_trigger_key_command`'s 50–52 ms wall clock. It is the
  UNSWEPT sibling of the MCU button press hold above, which dropped to a measured 0 ms
  after its own live sweep (`bf511e5`) — this one has had no equivalent sweep yet, so
  the default stays exactly where it was: **40 ms, unchanged.** What changed is that the
  hold can now be asked for: `logic_mcu_command`'s `keycmd` route takes the same
  `hold_ms` the press family does, an environment override lets the next live sweep
  change the daemon's default without touching every message, and a scratch harness
  (`keycmd_hold_sweep.py`) is ready to fire `Create Marker` across a range of holds and
  count markers the way the press sweep counted transitions. No speed claim ships with
  this change — it is the plumbing the measurement needs, not the measurement.
- **The key-command plane's hold dropped to the same measured 0 ms as the MCU button
  press.** `keycmd_hold_sweep.py` ran live 2026-09-03 (sandbox "Testlåt Copy", daemon
  restarted from `1e393a7`): firing `Create Marker` through `logic_mcu_command`'s
  `keycmd` route at `hold_ms` 0, 1, 5, 10, 20 and 40, then ten more fires at 0, with the
  playhead parked on an unmarked bar and every marker counted and deleted afterwards.
  Sixteen fires at a 0 ms hold made sixteen markers — zero duplicates, zero drops — the
  same 16/16 result the MCU button sweep got the day before (`bf511e5`) on the same
  dedicated "Logic MCP Commands" port. The compiled default
  (`resolveKeycmdDefaultHoldMs`) moves from the historical 40 ms to that measured 0 ms;
  `logic_trigger_key_command` and the 18 other tools riding this plane — the Inspector-
  visibility guard's own `Deselect All` included — inherit the saving the next time the
  bridge daemon starts from this build, expected to bring `logic_trigger_key_command`'s
  50–52 ms wall clock down to roughly 1–3 ms, the same order of magnitude the button
  sweep found. The ~0.2 ms point the button sweep also cleared is not reachable through
  `hold_ms` (an integer count of milliseconds) and was not measured here, so the honest
  claim is "0–40 ms all work," not "anything smaller would too." The environment override
  and per-message `hold_ms` this plumbing added are unchanged, for whichever surface gets
  swept next.

- **First-run setup asks for far less of your time, and writes three fewer rows into
  your Logic.** `logic_setup_key_commands` teaches Logic a MIDI note for each command
  the tools fire, once per machine — and it was slow: 223 s for 22 commands, measured
  live, of which only 3.3-4.1 s per command was accounted for by the waits in the code.
  The rest was Logic's Key Commands panel being re-read up to six times per command,
  plus a walk over every one of Logic's windows — the project window included — after
  every MIDI note, to prove that no "already assigned" alert had appeared. The panel is
  now read ONCE per command and that one reading carries through the select, the arm
  and the verification; the alert is looked for only where an alert can be (a window
  that was not there a moment ago, a sheet, a dialog), and always looked for once more
  before moving on, so a modal can never be left standing; and every remaining wait —
  the search re-filter, the row select, the Learn arm, the second after the note, the
  0.6 s per deleted assignment on the repair path — became a poll that ends the moment
  Logic answers instead of a fixed sleep that ends when the clock says so. Estimated
  60-110 s for the round, not measured: these two tools rewrite your persisted key
  command set, which no Undo reaches, so they are re-clocked on a scratch account
  rather than on anyone's real one. The set itself shrank from 22 commands to 19:
  Undo, Redo and Flashback Capture as Recording are in nobody's code path (a tool that
  has to put something back does it with the inverse operation and a readback that
  proves it, never a blind Undo), so they are no longer written into your Logic up
  front — each is still spelled, still holds its reserved note, and is learned on the
  spot the first time anything genuinely asks for it.
- **A Logic drawing in another language now gets a straight answer instead of nineteen
  dead ends.** Firing an already-learned key command never cared what language Logic is
  in — it is a MIDI note, and that was proven on a French Logic. LEARNING one did care:
  it types an English command name into Logic's own Key Commands search field. That now
  fails once, before anything is opened or written, naming the language, naming the
  commands it cannot spell, and naming what still works and what to do instead (bind by
  the name your Logic shows — a name this server does not itself spell is passed
  straight through and never refused). The row names moved into the same table the rest
  of Logic's UI words live in, so capturing a language fills them in one place; nothing
  was translated by guesswork.
- **Every menu bar press now brings Logic to the front first, not just Inspector and
  Delete Automation.** The background-press hazard those two fixes found is not
  particular to either menu: `View > List Editors` had the same shape and no guard,
  so `logic_tempo_events`, `logic_list_signatures`, `logic_list_events` and
  `logic_markers` could answer `.success` on the open press while Logic sat in the
  background and then misreport the pane as open with the wrong tab showing, rather
  than never having opened at all. The guard now lives in `pressMenuItem` itself —
  the one function every title-path menu press in the server goes through — so no
  future caller can leave it out by forgetting to add it at its own call site, which
  is exactly how this one slipped through the first two fixes. Free when Logic is
  already frontmost, on the order of the same near-zero cost `View > Inspector`
  measured.
- **A hidden Inspector no longer costs you the region tools either.** With Logic's
  Inspector closed, `logic_get_region_params`, `logic_set_region_params` and
  `logic_rename_region` refused outright — *"the left inspector is not showing"* — while
  every track tool had learned to show it on demand. They read and write Logic's Region
  panel, which lives in that pane, so they now show it for the length of the call and
  press it back: **1.5 / 1.1 s of real rows and 1.5 s of verified write where there was a
  refusal, and a rename round trip in 0.88 + 0.91 s.** With the Inspector already showing,
  nothing moved (0.78 / 0.26 s reads, 0.76 / 0.68 s writes, 0.55 + 0.39 s rename, against
  0.64 / 0.34, 0.74 / 0.78, 0.50 + 0.47 before). The one thing that did have to change is
  the panel's own disclosure: it is normally left OPEN so the next region call does not
  spend ~0.6 s re-opening it, but Logic remembers that triangle across a hide, so a debt
  left behind a pane this server is about to close would be an invisible change nothing
  could ever settle. On that path the disclosures are therefore closed before the pane
  goes, and `panel_state.restore` says `settled` rather than `deferred`. All three tools
  now report `inspector` (`shown` / `hidden` / `unavailable`) like the track family, plus
  `inspector_shown_for_call` and a confirmed `inspector_restored`; an Inspector that
  genuinely cannot be reached is refused in under a second naming View > Inspector and
  the `I` key.
- **And the Inspector no longer gets stranded open by a plug-in window.**
  `logic_open_plugin` on a track whose Inspector this server had shown came back
  `inspector_restored: false` and left the pane standing open for the rest of the
  session — every later call in that session saw a changed window layout nobody asked
  for. Measured cause: Logic **disables** View > Inspector while a plug-in window is its
  key window, and answers a press on the greyed-out item with success anyway; worse,
  Accessibility named the project window as focused the whole time, so no amount of
  comparing focus could have caught it. The Inspector press now raises the project
  window first (two attribute writes, free when it is already the key window) and refuses
  a disabled item instead of pressing it, so a press that cannot work is reported rather
  than believed: three plug-ins opened and closed from a hidden Inspector now report
  `inspector_restored: true` six times out of six, where the first call alone used to
  fail. When Logic does refuse the press, the result carries `inspector_note` saying
  which window is holding the Inspector open and how to let go of it.

- **A strip's level, pan, mute and solo are ONE call, and one tool.** `logic_set_track_mix`
  takes any subset of the four — `{volume_db: -3, pan: 12, mute: false}` is a single round
  trip where it used to be three — and writes them in a fixed order (volume, pan, mute,
  then solo: mute before solo, because Logic flashes the mute LED of every channel a
  standing solo silences and a mute written after this call's own solo would have to be
  read through that 1.4 s blink window). Every write is verified exactly as its own tool
  verified it and keeps its own section of the result, with its own state and readback;
  the top-level `success`/`verified` are the AND of them, and `written`/`unchanged`/`refused`
  say which parameter went which way. Compare-and-set stays PER PARAMETER
  (`expected_current_volume_db`, `expected_current_pan`, `expected_current_mute`,
  `expected_current_solo`), so a stale belief about the fader refuses the fader and lets
  the pan land — never one overloaded `expected_current` standing for a dB, a knob
  position and two booleans. Region selection folded the same way: `logic_select_regions`
  now selects ONE region (`mode: "region"`, the default, with the arguments the old tool
  took) as well as a track's worth, everything after a point, all, or none. Five tool
  names became two, and what the fold buys every session is 2,448 bytes / 499 tokens of
  `tools/list` that four descriptions used to spend repeating one set of addressing,
  verification and compare-and-set rules four times. The removed names —
  `logic_set_track_volume`, `logic_set_track_pan`, `logic_set_track_mute`,
  `logic_set_track_solo`, `logic_select_region` — are listed with their replacements
  under "Renamed and removed" in the agent guide.
- **Every tool now says what it is for in its first sentence, and the machinery moved
  to the guide.** The twenty-one biggest tool descriptions were rewritten to open with
  one plain sentence an agent can pick the tool by — `logic_record_midi` starts with
  "PERFORM a MIDI part onto an existing software-instrument track", not with its timing
  model; `logic_set_region_params` with "Shape how a region PLAYS BACK without touching
  what was recorded" — and then keep only what changes what an agent DOES: the
  destructive warning, the refusals, the one non-obvious argument rule, and the result
  keys the tool promises. Nothing was dropped. Every measured number, sweep and Logic
  quirk those descriptions carried is now in a new "Mechanism and measured costs"
  section of the agent guide, one entry per tool, with its date — and the guide is
  fetched on demand, so it costs nothing at connect. `tools/list` is 21,268 bytes /
  5,119 tokens smaller in every session (232,297 → 211,029 B; 51,559 → 46,440 tokens,
  −9.9%), the guide grew 3,771 B, and the retrieval probe still surfaces all 57 of its
  scored queries in the top five, because a shorter description ranks its own keywords
  higher rather than lower.

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
