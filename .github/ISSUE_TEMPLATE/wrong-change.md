---
name: Wrong change made in Logic
about: Logician wrote or changed something in a project that should not have happened
title: ''
labels: wrong-change
assignees: ''
---

**If this is still happening and you have unsaved work you care about:**
close the project without saving, or set it aside, before troubleshooting
further — this template is for reporting the bug, not undoing it live.

## What was asked

The exact instruction given to the agent, as close to verbatim as you can
get it (copy-paste from the chat if possible).

## What happened instead

What Logician actually did or changed in the project — the track, region,
parameter, or setting affected, and how it differs from what should have
happened.

## The tool result

Paste the **exact JSON** the tool call returned, if you have it (most MCP
clients let you expand or copy the tool call/result). This matters more than
a description — the `write_route`, `verified`, and `warning` fields usually
say more about what actually happened than the visible symptom does.

```json

```

## Diagnostics

Run `logician doctor --redact` and paste the output.

> **Do not paste raw `logic_health` output here or anywhere public.**
> Unredacted, it contains your open project's file path and name.
> `logician doctor --redact` strips that; use it instead.

```

```

## Versions

- **Logic Pro:**
- **macOS:**
- **Logician:**
- **MCP client:**

## Anything else

Whether you were able to undo the change in Logic, and whether the project
had been saved since the change happened.
