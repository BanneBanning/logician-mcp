---
name: profile-tool
description: Profile one Logician tool phase-by-phase with wall-clock timing against live Logic and DOCUMENT its optimization candidates in the ledger — measurement only, no code changes. Pass the tool name as the argument, e.g. /profile-tool logic_mixer_snapshot.
---

# Profile one tool — measure and document, do not fix

You are profiling ONE tool of the Logician MCP server (the repo you are in). The
tool name is the skill's argument; refuse politely if it is not in the registry.

**This skill is measurement-only.** Earlier profiles (see
`Logician-archive/profiles/logic_add_plugin.md` and `logic_add_send.md`) shipped
their fixes too and took an hour+ per tool. That is over: the candidates repeat
across tools, so they are DOCUMENTED here and implemented later in batched
passes the user reviews. You change no source code except temporary
instrumentation, which you fully revert. No commits. Target: well under
30 minutes per tool.

## The doctrine (read before profiling)

- **Target: human parity** — a person does the common version of most intents in
  1–2 s; a warm call should be in that class. Call count is a first-class cost.
- **Cut WAITS, not VERIFICATION.** Silent wrongness stays forbidden.
- **Constants shrink only via measured distributions**, never by guess.

## The live lock (one Logic, many sessions)

Other sessions and subagents profile other tools concurrently. Every action that
touches Logic, the Accessibility tree, the bridge daemon socket or the control
surface — including running the server binary against Logic — requires holding
the shared lock, and must never happen without it:

    LOCK="/private/tmp/claude-501/logician-live.lock"
    n=0; until mkdir "$LOCK" 2>/dev/null; do n=$((n+1)); [ $n -gt 150 ] && { echo "LOCK TIMEOUT"; exit 1; }; sleep 20; done
    echo "<tool> $(date +%s)" > "$LOCK/holder"
    ...live work...
    rm -rf "$LOCK"      # ALWAYS, also on failure, after the surface is back in PN

Hold it as briefly as possible: do steps 1–2 (triage, instrumentation, build)
before acquiring; acquire once for the whole live matrix; release right after
restoring baseline. Re-acquire briefly for the single ledger edit (two sessions
must not read-modify-write TOOL-OPTIMIZATION-LEDGER.md at once). If you are the
only session and find a lock whose `holder` timestamp is older than 50 minutes
with no live session running, it is stale — remove it and say so in your report.

## Procedure

1. **Pattern triage first (code reading, no Logic).** Read the tool's handler
   and every internal call; list the phases with file:line. Then check the path
   against the ledger's "Proven patterns" section and standing cross-tool list
   (`Logician-archive/TOOL-OPTIMIZATION-LEDGER.md`). Known repeat offenders and
   their measured prices from earlier profiles: `exitToPan` walks home from a
   view the flow re-enters (1.3–3.4 s each), `sendViewLeftmost`/page
   normalisation without a positive early-exit (~1 s), blind `Thread.sleep`
   (its full duration), duplicate `ensurePanNames`/view entries, one-entry-at-a-
   time catalog walks (jump mechanism proven; note ticks-per-entry differs per
   browser), unpaced message streams (Logic swallows messages sent into an
   unfinished repaint), missing cache population on a computing path. Every hit
   goes straight into the candidate list with an estimated saving borrowed from
   the pattern's measured price — no experiment needed to re-prove a proven
   pattern.
2. **Instrument temporarily**: Date()-bracket the phases behind the usual env
   guard. The tree must be byte-identical afterwards — verify with `git status`
   / `git diff` yourself.
3. **Run a LIGHT matrix live, holding the lock** (sandbox project "Testlåt Copy"; standing
   rules: never save, no blind Undo, no second `logician --bridge`, probe for
   modals, unknown dialog → Cancel, leave the surface in PN view and the project
   at baseline, restore anything you write; Bash with AX/socket needs
   dangerouslyDisableSandbox: true): **2 warm runs + 1 cold** (note which caches
   the tool touches), plus extra variants ONLY when the phase table says cost
   depends on them. Do not run side experiments (jump proofs, catalog
   enumeration, distribution logging) — if one would be needed to size a
   candidate, write the candidate as "unsized, needs <experiment>" and move on.
4. **Document**: a compact report at `Logician-archive/profiles/<tool>.md` —
   the phase table (phase → file:line → ms warm/cold → %), the totals, and the
   candidate list where each entry is either a NAMED KNOWN PATTERN (with
   file:line and borrowed estimate) or a genuinely new finding (with mechanism,
   estimate, risk). Defects that make correct calls fail or lie are still gold:
   document them prominently and offer a background-task chip, but do not fix
   them. If the profile contradicts a README "How fast is it?" number, flag it
   in the report — never edit the README.
5. **Record**: update the tool's row in `TOOL-OPTIMIZATION-LEDGER.md` (measured
   cost, Profiled ☑, candidates by pattern name). Add genuinely new cross-tool
   patterns to the standing list.

## Report back

Totals (warm/cold), the phase table, the candidate list grouped as
known-pattern vs new, any defects found, and the one-line ledger update. The
optimizations themselves happen later, in batched passes across all profiled
tools — that is the user's call, not this session's.
