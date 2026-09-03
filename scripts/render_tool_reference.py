#!/usr/bin/env python3
"""Regenerate docs/AGENT-GUIDE.md's "## Tool reference" section from the live
server schemas, so it cannot drift from what `tools/list` advertises.

    swift build -c release
    python3 scripts/dump_tools.py .build/release/logician /tmp/tools.json
    python3 scripts/render_tool_reference.py /tmp/tools.json docs/AGENT-GUIDE.md

The dump is the input rather than the binary: `dump_tools.py` already speaks
the protocol, and one source of truth for "what the server says" is the point
of both scripts. Everything before the section heading is left untouched — the
prose above it is written by hand and stays that way.
"""
import json
import re
import sys

HEADING = "## Tool reference"


def type_name(schema):
    raw = schema.get("type")
    if isinstance(raw, list):
        return " or ".join(raw)
    if raw == "array":
        items = schema.get("items") or {}
        inner = items.get("type")
        if isinstance(inner, list):
            inner = " or ".join(inner)
        return "array of %s" % inner if inner else "array"
    return raw or "any"


def parameter_line(name, schema, required):
    line = "  - `%s` (%s)" % (name, type_name(schema))
    if required:
        line += " **(required)**"
    description = schema.get("description", "")
    if schema.get("enum"):
        options = ", ".join("`%s`" % value for value in schema["enum"])
        description = (description + " " if description else "") + "One of: %s." % options
    if description:
        line += ": " + description
    return line


def render(tools, count_note):
    out = [HEADING, "", count_note, ""]
    for tool in tools:
        out.append("#### `%s`" % tool["name"])
        out.append("")
        out.append(tool["description"])
        out.append("")
        out.append("Parameters:")
        out.append("")
        schema = tool.get("inputSchema") or {}
        properties = schema.get("properties") or {}
        required = set(schema.get("required") or [])
        if not properties:
            out.append("  - (no parameters)")
        else:
            for name in sorted(properties):
                out.append(parameter_line(name, properties[name], name in required))
        out.append("")
    return "\n".join(out).rstrip("\n") + "\n"


def main():
    dump_path, guide_path = sys.argv[1], sys.argv[2]
    with open(dump_path) as handle:
        dump = json.load(handle)
    tools = dump["tools"]
    # The version the note quotes comes from the same handshake the schemas
    # did, so a release bump cannot leave a stale `(vX.Y.Z)` behind: the guide
    # said v0.61.0 for the 1.0.0-beta.1 release until this line existed.
    version = (dump.get("initialize") or {}).get("serverInfo", {}).get("version")

    with open(guide_path) as handle:
        guide = handle.read()
    head, marker, tail = guide.partition("\n" + HEADING + "\n")
    if not marker:
        sys.exit("no '%s' section in %s" % (HEADING, guide_path))

    # The standing note under the heading, with its count kept current.
    old_note = tail.split("\n\n", 1)[0].strip()
    count_note = re.sub(r"^All \d+ tools", "All %d tools" % len(tools), old_note)
    if count_note == old_note and not old_note.startswith("All "):
        sys.exit("the note under '%s' no longer starts with 'All N tools'" % HEADING)
    if version:
        count_note = re.sub(r"\(v[^)]*\)", "(v%s)" % version, count_note, count=1)

    with open(guide_path, "w") as handle:
        handle.write(head + "\n" + render(tools, count_note))
    print("%d tools rendered into %s" % (len(tools), guide_path))


if __name__ == "__main__":
    main()
