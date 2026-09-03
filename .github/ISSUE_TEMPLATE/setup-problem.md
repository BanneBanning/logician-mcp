---
name: Setup problem
about: Install, build, MCP client registration, Accessibility, or the Mackie Control surface won't come up
title: ''
labels: setup
assignees: ''
---

## Diagnostics

Run `logician doctor --redact` and paste the **whole** output here. It checks
the bridge, the MIDI ports, Accessibility, the key-command registry, and the
MCP client registration in one pass.

> **Do not paste raw `logic_health` output here or anywhere public.**
> Unredacted, it contains your open project's file path and name.
> `logician doctor --redact` strips that; use it instead.

```

```

## Versions

- **Logic Pro:** (Logic Pro → About Logic Pro)
- **macOS:** (Apple menu → About This Mac)
- **Logician:** (the `version` your client shows for the server, or the commit/tag you built)
- **Install method:** Homebrew / install script / built from source
- **MCP client:** (Claude Code, Claude Desktop, Gemini CLI, Cursor, Antigravity, …)

## What happened

What step failed (install, `logician setup`, granting Accessibility,
installing the Mackie Control surface in Logic's Control Surfaces setup,
the client not seeing the server, …), and the exact error text or behavior.

## What you expected instead

## Anything else

Whether this is a fresh machine or one that previously had an older
Logician, and whether any other MIDI control surface software is installed.
