#!/usr/bin/env python3
"""Start the logician binary, speak MCP initialize + tools/list, and dump the
advertised surface to a canonical JSON file.

Used to prove that a refactor did not move a single byte of what agents see:

    swift build -c release
    python3 scripts/dump_tools.py .build/release/logician /tmp/after.json
    diff /tmp/before.json /tmp/after.json

Neither request touches Logic Pro, so this runs anywhere.
"""
import json
import subprocess
import sys

binary, out_path = sys.argv[1], sys.argv[2]
requests = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize",
     "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "dump", "version": "0"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
]
stdin = "".join(json.dumps(request) + "\n" for request in requests)
proc = subprocess.run([binary], input=stdin, capture_output=True, text=True, timeout=120)

initialize = None
tools = None
for line in proc.stdout.splitlines():
    line = line.strip()
    if not line:
        continue
    message = json.loads(line)
    if message.get("id") == 1:
        initialize = message["result"]
    if message.get("id") == 2:
        tools = message["result"]["tools"]

if tools is None:
    sys.exit("no tools/list response; stderr:\n" + proc.stderr)

with open(out_path, "w") as handle:
    json.dump({"initialize": initialize, "tools": tools}, handle,
              indent=2, sort_keys=True, ensure_ascii=False)
    handle.write("\n")
print(f"{len(tools)} tools -> {out_path}")
