---
name: profile-tool
description: Profile one Logician tool phase-by-phase with wall-clock timing against live Logic, rank its optimizations, ship the safe ones, and record it all in the optimization ledger. Pass the tool name as the argument, e.g. /profile-tool logic_mixer_snapshot.
---

# Profile one tool — the efficiency campaign's unit of work

You are profiling ONE tool of the Logician MCP server (the repo you are in), the way
the EQ-write flow was profiled (see the reference report
`/Users/dev/Desktop/Progg/Random Projekt/Logician-archive/PROFILING-EQ-WRITE.md`
and the ledger `TOOL-OPTIMIZATION-LEDGER.md` beside it). The tool name is the skill's
argument; refuse politely if it is not in the registry.

## The doctrine (read before profiling)

- **Target: human parity.** A person performs the common version of most of these
  intents in 1–2 s. A warm call should land in that class. Call count matters as much
  as call speed — if this tool is usually one link in a multi-call chain, folding the
  chain into one call is a first-class finding.
- **Cut WAITS, not VERIFICATION.** Everything cacheable gets cached (with the house
  ScopedCache discipline — per build, per project, delete-on-mismatch). Sleeps and
  quiescence windows that buy the last 10% of certainty are replaced by fast POSITIVE
  checks (does the LCD/element already show the expected content?) with honest
  fallback: one retry, or `verified: false` with the reason. 99% certain and 90%
  faster beats 110% certain. What remains forbidden is SILENT wrongness — a fast
  path that can misread must be caught by the existing readback/compare-and-set and
  reported, never papered over.
- **Constants are lowered by MEASUREMENT, never by guess.** A timing constant that
  encodes real Logic repaint behavior (the comments say which) may only shrink after
  its underlying distribution is measured (log the real gaps/latencies across many
  samples; threshold = observed max + margin).

## Procedure

1. **Map the path**: read the tool's handler and every internal call it makes; list
   the phases with file:line. Note every `Thread.sleep`/poll/quiescence wait on the
   path and every cache it reads or fails to read.
2. **Instrument temporarily**: Date()-bracket the phases (stderr or in-memory log).
   The shipped tree must be byte-identical afterwards (`git status` clean) — same
   rule as the temp-XCTest pattern.
3. **Run the matrix live** (sandbox project "Testlåt Copy"; standing rules:
   never save, no blind Undo, no second `logician --bridge`, probe for modals, leave
   the surface in PN view and the project at baseline; restore anything you write;
   Bash with AX/socket needs dangerouslyDisableSandbox: true): ≥3 warm runs + 1 cold
   (relevant caches cleared — note which caches this tool even touches), plus the
   tool's meaningful variants (routes, scopes, sizes). Mean + spread per phase.
4. **Analyze**: phase table (phase → file:line → ms warm/cold → % of total) and a
   RANKED optimization list — mechanism, estimated saving, risk (LOW/MEDIUM/HIGH),
   and whether it is tool-local or cross-tool (cross-tool candidates go to the
   ledger's standing list instead of being half-fixed locally).
5. **Ship the obviously safe ones** (waits that never fire, missing cache
   populations, redundant re-reads) with tests; everything else is report-only.
   `swift build -c release -Xswiftc -warnings-as-errors` + `swift test` green.
   Commit on main, do NOT push (the orchestrator reviews).
6. **Record**: write the full report to
   `Logician-archive/profiles/<tool>.md`, then update the tool's row in
   `TOOL-OPTIMIZATION-LEDGER.md` — measured cost, check the Profiled box, note what
   shipped and what is pending. If the profile re-measured a number the README's
   "How fast is it?" table states, flag the discrepancy in your report (do not edit
   the README — the user owns its voice).

## Report back

The phase table, the totals (warm/cold, per variant), the ranked list with savings
and risks, what shipped, and the one-line ledger update you made.
