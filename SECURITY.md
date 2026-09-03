# Security

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue:
email the maintainer or use GitHub's private vulnerability reporting
("Security" tab → "Report a vulnerability") on
[BanneBanning/logician-mcp](https://github.com/BanneBanning/logician-mcp).
Include what you found, how to reproduce it, and its impact if you can. This
is a one-person project maintained best-effort with no SLA, but security
reports get priority over everything else in the queue.

## What Logician actually does, network-wise

Logician itself has no network code: no sockets that reach the internet, no
telemetry, no update checker phoning home. What it does talk to, all of it
local to your Mac:

- **stdio** to whatever MCP client launched it (Claude, Gemini CLI, Cursor,
  …) — this is the whole interface.
- **CoreMIDI**, through virtual ports, to Logic Pro's Mackie Control surface.
- **A Unix domain socket** between the server process and its own bridge
  daemon.
- **macOS Accessibility**, to read and write Logic's UI as a fallback path.

None of that leaves the machine. `Package.swift` has zero third-party
dependencies, so there is no dependency supply chain to worry about either.

## Where the actual exposure is

Logician is a bridge between an MCP client and Logic Pro — it is not the
thing deciding what to do with what it reads. The MCP client on the other
end of stdio is typically backed by a cloud model, and depending on which
tools and settings you use it with, **that client may send project names,
track names, plugin names, file paths, and rendered audio to that model's
servers** as part of normal operation (tool results, audio content blocks,
conversation context). That is a property of the MCP client and the model
you've connected it to, not of Logician — but it is the honest answer to "is
anything about my project leaving this machine," so it belongs here rather
than left for you to discover later.

If that matters for a project (client confidentiality, unreleased music,
etc.), check what your specific MCP client and model provider do with tool
results and audio before pointing Logician at that project.

## Diagnostics and your project's identity

`logic_health` (and other diagnostic tool results) can include your open
project's file path and name. When reporting a bug, prefer
`logician doctor --redact` and check the redacted output before pasting it
anywhere public — see the issue templates under `.github/ISSUE_TEMPLATE/`.
