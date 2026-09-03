---
name: MCP client or audio problem
about: A specific MCP client, protocol/connection issue, or an audio result (render, bounce, listening) that's wrong or missing
title: ''
labels: client-or-audio
assignees: ''
---

## Diagnostics

Run `logician doctor --redact` and paste the **whole** output here.

> **Do not paste raw `logic_health` output here or anywhere public.**
> Unredacted, it contains your open project's file path and name.
> `logician doctor --redact` strips that; use it instead.

```

```

## Versions

- **Logic Pro:**
- **macOS:**
- **Logician:**
- **MCP client:** (name and version — Claude Code, Claude Desktop, Gemini CLI, Cursor, Antigravity, …)

## What happened

For a client/protocol issue: connection errors, tool list problems,
disconnects, or anything the client's own logs show about the MCP
handshake.

For an audio issue: which tool (`logic_bounce_range`, `logic_render_track`,
`logic_get_audio_clip`, `logic_evaluate_change`, …), what you expected to
hear versus what you got, and whether the result included an audio content
block, a `preview_path`, or a `logician://captures/` resource link.

## What you expected instead

## Anything else

If it's an audio issue, whether the model actually played/listened to the
audio or only read the surrounding metrics.
