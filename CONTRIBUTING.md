# Contributing to Logician

Thanks for taking a look. Logician is maintained by one person, in spare
time, with AI agents doing a lot of the typing under close review — so
contributions of any size are genuinely welcome, and so is patience: support
here is best-effort, with no SLA.

## The legal shape of a contribution

Logician is MIT-licensed (`LICENSE`). Inbound is outbound: by opening a pull
request, you agree your contribution is offered under the same MIT license,
with no separate CLA to sign.

Commits need a **Developer Certificate of Origin** sign-off — a statement
that you wrote the change or otherwise have the right to submit it under the
project's license. Add it with:

```
git commit -s
```

which appends a `Signed-off-by: Your Name <you@example.com>` trailer. A pull
request whose commits are missing it will be asked to add it (`git commit
--amend -s`, or `git rebase --exec 'git commit --amend --no-edit -s'` for a
whole branch) before it can be merged.

## Before you open a PR

1. **Read `docs/AGENT-GUIDE.md`** for the concepts (the control-surface data
   plane, the Accessibility fallback, the verified-write contract) — it is
   generated from the tool schemas, so it stays accurate.
2. **Run the gates locally**, exactly as CI does:

   ```bash
   swift build -c release -Xswiftc -warnings-as-errors
   swift test
   ```

   Both must be clean. Warnings fail the build on purpose; a silently
   accumulating warning is a bug report nobody filed.

## The house rules a change has to respect

These aren't style preferences — they're the difference between a tool an
agent can trust and one it can't.

- **Every write is verified by reading Logic back.** A tool that changes
  something in Logic does not get to report success on the strength of "the
  call didn't throw" — it re-reads the state it changed (a control-surface
  echo, an Accessibility attribute, a track/region census) and the result
  says what was actually observed afterward, not just what was requested.
- **A tool must never report success it did not prove.** If a write can't be
  verified, the honest result is a refusal, a `warning`, or an explicit
  `unavailable` — never a bare `{}` and never a `success: true` resting on
  hope. This is the whole reason an agent can act on Logician's results
  without double-checking them by hand.
- **Measured numbers in doc comments carry their date.** Timing numbers,
  "verified live on 2026-08-25", locale test results — Logic Pro, macOS, and
  the surrounding toolchain all move, so a number with no date attached
  quietly becomes a claim nobody can check.
- **The test suite is hermetic.** `Tests/` must never reach for a running
  Logic Pro, the Accessibility tree, or the MIDI bridge — no
  `LOGICIAN_LIVE`, no `LiveProbe`, no `NSWorkspace`, no
  `ProcessInfo.processInfo.environment` gate that opens a live escape hatch.
  CI greps for exactly these and fails the build if it finds one
  (`.github/workflows/ci.yml`). If a change needs live verification, do that
  by hand against your own Logic Pro and describe what you saw in the PR —
  it does not belong in the committed test suite.

## What a good PR looks like

- Pure logic changes come with unit tests that need neither Logic nor a
  bridge daemon running.
- If the change is user-visible, add a `CHANGELOG.md` bullet under
  `## 1.0.0 — unreleased` (or the next unreleased version), in the file's
  existing voice: the benefit first, the mechanism second, real measured
  numbers where you have them.
- If you touched a tool's description or schema, regenerate the generated
  docs rather than hand-editing them:

  ```bash
  python3 scripts/dump_tools.py .build/release/logician /tmp/tools.json
  python3 scripts/render_tool_reference.py /tmp/tools.json docs/AGENT-GUIDE.md
  python3 scripts/embed_agent_guide.py
  ```

- Keep the diff focused. A PR that fixes one thing is much easier for a
  one-person maintenance team to review and merge than one that also
  reformats unrelated files.

## Reporting a problem instead of fixing it

See the issue templates under `.github/ISSUE_TEMPLATE/` — pick the one that
matches what happened, and run `logician doctor --redact` for the
diagnostics section rather than pasting a raw `logic_health` result (which
contains your project's file path and name).
