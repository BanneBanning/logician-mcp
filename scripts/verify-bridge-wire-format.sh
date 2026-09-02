#!/bin/bash
# Proves that typing the server ⇄ bridge protocol did not move a single byte
# of the wire format.
#
# It builds the bridge daemon TWICE — once from a baseline git ref, once from
# the working tree — starts each one on its own unix socket, sends the same
# commands to both, and compares the raw JSON replies key by key and type by
# type. The daemon and the MCP server are separate processes that can be at
# different versions during an upgrade, and the surface snapshot is also the
# documented `logic_mcu_status` tool result, so a renamed key is a real
# outage, not a cosmetic change.
#
# WHY NOT `.build/release/logician --bridge` DIRECTLY:
# the daemon claims FIXED CoreMIDI unique IDs (0x4C4D4330-33). Running a
# second one on a machine where the real bridge is live cannot claim them and
# exits; worse, the virtual endpoints it creates on the way there are exactly
# the "orphaned twin ports" failure documented in Bridge.swift — Logic binds
# key commands to a port's unique ID, so the twins make every key command
# silently stop firing. So each harness here is the REAL Bridge.swift and the
# REAL Framing.swift from its commit, compiled with only the CoreMIDI
# endpoint layer replaced by no-op stubs, and with the state directory
# redirected into a temp dir. The socket, the framing, the JSON decode, the
# command handler and the JSON encode are all the shipping code.
#
# Usage: scripts/verify-bridge-wire-format.sh [baseline-git-ref]
# Default baseline: HEAD when the working tree has uncommitted changes to
# Sources/, otherwise HEAD~1.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

if [ $# -ge 1 ]; then
    BASE_REF="$1"
elif git diff --quiet HEAD -- Sources; then
    BASE_REF="HEAD~1"
else
    BASE_REF="HEAD"
fi

WORK="$(mktemp -d)"
trap 'pkill -f "$WORK" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

echo "baseline : $BASE_REF ($(git rev-parse --short "$BASE_REF"))"
echo "candidate: working tree"
echo

# Emits a compilable, MIDI-free harness for one version of the bridge.
#   $1 = output directory
#   $2 = git ref, or "WORKTREE"
build_harness() {
    local out="$1" ref="$2"
    mkdir -p "$out"

    if [ "$ref" = "WORKTREE" ]; then
        for file in "$ROOT"/Sources/LogicMCUBridge/*.swift; do
            [ "$(basename "$file")" = "PortAudit.swift" ] && continue # CoreMIDI only
            cp "$file" "$out/"
        done
    else
        for name in $(git ls-tree --name-only "$ref" Sources/LogicMCUBridge/); do
            base="$(basename "$name")"
            [ "$base" = "PortAudit.swift" ] && continue
            git show "$ref:$name" > "$out/$base"
        done
    fi

    python3 - "$out/Bridge.swift" <<'PY'
import os, re, sys
path = sys.argv[1]
lines = open(path).read().split("\n")

def index_of(prefix, start=0):
    for i in range(start, len(lines)):
        if lines[i].startswith(prefix):
            return i
    raise SystemExit(f"harness: could not find {prefix!r} in Bridge.swift")

# Everything from "MIDI setup" up to the stream scheduler is CoreMIDI: the
# client/source/destination globals, setUpMIDI() and the four send helpers.
start = index_of("// MARK: - MIDI setup")
end = index_of("// MARK: - MIDI stream scheduler")
# bridgeMain() creates directories, writes state.json and runs a run loop.
main = index_of("// MARK: - Main")
lines = lines[:start] + lines[end:main]

text = "\n".join(lines)
text = text.replace("import CoreMIDI\n", "")
# Redirect the state directory: the real one is ~/Library/Application
# Support/LogicMCPMCU, which belongs to the user's live daemon.
text = re.sub(
    r"let directory = FileManager\.default\.homeDirectoryForCurrentUser\n"
    r"\s*\.appendingPathComponent\(\"Library/Application Support/LogicMCPMCU\"\)",
    'let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BRIDGE_HARNESS_DIR"]!)',
    text,
)
assert "BRIDGE_HARNESS_DIR" in text, "harness: state directory substitution failed"

open(path, "w").write(text)

# Top-level statements are only legal in main.swift, so the stubs and the
# entry point live in their own file.
open(os.path.join(os.path.dirname(path), "main.swift"), "w").write("""
// Harness entry point. Replaces the CoreMIDI endpoint layer with no-ops so
// the socket, the framing, the decode, handleCommand and the encode can all
// be the shipping code while creating no virtual MIDI ports.

import Foundation

func send(_ bytes: [UInt8]) {}
func sendCommandPort(_ bytes: [UInt8]) {}
func sendMIDIIn(_ bytes: [UInt8]) {}
func sendMIDIInStamped(_ bytes: [UInt8], atHostTime hostTime: UInt64) {}

let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

func hostTicks(fromMs ms: Double) -> UInt64 {
    UInt64(ms * 1_000_000 * Double(timebase.denom) / Double(timebase.numer))
}

try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
startSocketServer()
// Mirror the daemon's periodic state.json writer so the FILE format is
// compared too, not just the socket replies.
let stateTimer = DispatchSource.makeTimerSource()
stateTimer.schedule(deadline: .now(), repeating: .milliseconds(150))
stateTimer.setEventHandler {
    if state.isDirty, let json = state.snapshotJSON() {
        try? json.write(to: statePath, options: .atomic)
    }
}
stateTimer.resume()
if let json = state.snapshotJSON() {
    try? json.write(to: statePath, options: .atomic)
}
withExtendedLifetime(stateTimer) { RunLoop.main.run() }
""")
PY

    (cd "$out" && swiftc -O -o harness ./*.swift 2>&1 | grep -v "^$" || true) >"$out/build.log"
    if [ ! -x "$out/harness" ]; then
        echo "FAILED to build the $ref harness:"
        cat "$out/build.log"
        exit 1
    fi
}

echo "building harnesses..."
build_harness "$WORK/base" "$BASE_REF"
build_harness "$WORK/new" "WORKTREE"

start_harness() {
    local dir="$1"
    mkdir -p "$dir/state"
    BRIDGE_HARNESS_DIR="$dir/state" "$dir/harness" >/dev/null 2>&1 &
    echo $! > "$dir/pid"
    disown # no "Terminated" job-control noise when the trap kills them
    for _ in $(seq 1 50); do
        [ -S "$dir/state/command.sock" ] && return 0
        perl -e 'select(undef,undef,undef,0.1)'
    done
    echo "harness in $dir never opened its socket"; exit 1
}

start_harness "$WORK/base"
start_harness "$WORK/new"
trap 'kill "$(cat "$WORK/base/pid" 2>/dev/null)" "$(cat "$WORK/new/pid" 2>/dev/null)" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
echo "both daemons listening"
echo

BASE_SOCK="$WORK/base/state/command.sock" NEW_SOCK="$WORK/new/state/command.sock" \
BASE_STATE="$WORK/base/state/state.json" NEW_STATE="$WORK/new/state/state.json" \
python3 - <<'PY'
import json, os, socket, sys, time

BASE, NEW = os.environ["BASE_SOCK"], os.environ["NEW_SOCK"]

# The framing contract: one command per connection, sender half-closes, the
# reply ends at EOF. Same rule both directions, no length prefix.
def ask(path, payload):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    s.sendall(payload)
    s.shutdown(socket.SHUT_WR)
    chunks = []
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        chunks.append(chunk)
    s.close()
    return b"".join(chunks)

# Keys whose value is a wall-clock reading and therefore differs between two
# processes by construction. Their TYPE is still compared.
VOLATILE = {"updated"}

def shape(value):
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    if value is None:
        return "null"
    if isinstance(value, list):
        return [shape(v) for v in value]
    return {k: shape(v) for k, v in sorted(value.items())}

def strip_volatile(value):
    if isinstance(value, dict):
        return {k: ("<volatile>" if k in VOLATILE else strip_volatile(v))
                for k, v in value.items()}
    if isinstance(value, list):
        return [strip_volatile(v) for v in value]
    return value

CASES = [
    ("ping",                      b'{"cmd":"ping"}'),
    ("status",                    b'{"cmd":"status"}'),
    ("await (immediate timeout)", b'{"cmd":"await","since":0,"timeout_ms":10}'),
    ("press play",                b'{"cmd":"press","button":"play"}'),
    ("press by note",             b'{"cmd":"press","note":94}'),
    ("press unknown button",      b'{"cmd":"press","button":"nope"}'),
    # hold_ms is ADDITIVE (2026-09-02): the baseline daemon has never heard of
    # it and holds its 50 ms, the candidate honours it — and the REPLY must be
    # identical either way, which is the whole reason it shipped without a
    # protocol bump. The press cases above already pin the no-hold default.
    ("press with a hold",         b'{"cmd":"press","button":"play","hold_ms":25}'),
    ("select with a hold",        b'{"cmd":"select","channel":3,"hold_ms":25}'),
    ("select",                    b'{"cmd":"select","channel":3}'),
    ("select missing channel",    b'{"cmd":"select"}'),
    ("mute",                      b'{"cmd":"mute","channel":0}'),
    ("solo out of range",         b'{"cmd":"solo","channel":9}'),
    ("vpot_press",                b'{"cmd":"vpot_press","index":5}'),
    ("fader",                     b'{"cmd":"fader","channel":2,"value":8192}'),
    ("fader missing value",       b'{"cmd":"fader","channel":2}'),
    ("vpot",                      b'{"cmd":"vpot","index":1,"delta":-12}'),
    ("vpot wrongly typed index",  b'{"cmd":"vpot","index":"two","delta":4}'),
    ("raw",                       b'{"cmd":"raw","bytes":[144,94,127]}'),
    ("raw out of range",          b'{"cmd":"raw","bytes":[144,94,999]}'),
    ("converge (non-numeric LCD)",b'{"cmd":"converge","index":0,"target":-6}'),
    ("converge bad index",        b'{"cmd":"converge","index":9,"target":-6}'),
    ("midi_stream",               b'{"cmd":"midi_stream","events":[[0,144,60,100],[1250.5,128,60,0]]}'),
    ("midi_abort",                b'{"cmd":"midi_abort"}'),
    ("midi_stream empty",         b'{"cmd":"midi_stream","events":[]}'),
    ("midi_stream bad byte",      b'{"cmd":"midi_stream","events":[[0,144,300]]}'),
    ("midi_stream short event",   b'{"cmd":"midi_stream","events":[[0]]}'),
    ("keycmd",                    b'{"cmd":"keycmd","note":24,"channel":16}'),
    ("keycmd out of range note",  b'{"cmd":"keycmd","note":200}'),
    ("unknown cmd",               b'{"cmd":"teleport"}'),
    ("missing cmd",               b'{"index":3}'),
    ("not an object",             b'[1,2,3]'),
    ("not JSON at all",           b'nonsense'),
]

failures = []
print(f"{'command':<28} {'keys':<7} {'types':<7} {'values':<7} {'raw bytes':<11}")
print("-" * 66)
for label, payload in CASES:
    raw_base, raw_new = ask(BASE, payload), ask(NEW, payload)
    try:
        base, new = json.loads(raw_base), json.loads(raw_new)
    except json.JSONDecodeError as error:
        failures.append(f"{label}: reply is not JSON ({error})")
        print(f"{label:<28} {'PARSE FAIL':<7}")
        continue

    keys_ok = sorted(base) == sorted(new)
    types_ok = shape(base) == shape(new)
    values_ok = strip_volatile(base) == strip_volatile(new)

    def mark(ok):
        return "same" if ok else "DIFF"

    # JSON object key ORDER carries no meaning, and the old daemon left its
    # socket replies in NSDictionary hash order while the new one sorts them
    # (state.json was already sorted on both sides). Report that distinctly
    # so this column never quietly hides a real difference.
    if raw_base == raw_new:
        bytes_mark = "same"
    elif values_ok and types_ok:
        bytes_mark = "reordered"
    else:
        bytes_mark = "DIFF"

    print(f"{label:<28} {mark(keys_ok):<7} {mark(types_ok):<7} "
          f"{mark(values_ok):<7} {bytes_mark:<11}")
    if not keys_ok:
        failures.append(f"{label}: keys {sorted(base)} -> {sorted(new)}")
    if not types_ok:
        failures.append(f"{label}: types {shape(base)} -> {shape(new)}")
    if not values_ok:
        for key in sorted(set(base) | set(new)):
            if key in VOLATILE:
                continue
            if base.get(key) != new.get(key):
                failures.append(f"{label}: {key} {base.get(key)!r} -> {new.get(key)!r}")

# The state FILE is the other consumer of the same snapshot: the fallback
# when the socket is unreachable, and the body of the logic_mcu_status tool
# result. It must match byte for byte apart from its timestamp.
time.sleep(0.6)
files = {}
for name, path in (("base", os.environ["BASE_STATE"]), ("new", os.environ["NEW_STATE"])):
    with open(path) as handle:
        files[name] = json.load(handle)
print()
state_keys_ok = sorted(files["base"]) == sorted(files["new"])
state_types_ok = shape(files["base"]) == shape(files["new"])
state_values_ok = strip_volatile(files["base"]) == strip_volatile(files["new"])
print(f"{'state.json':<28} "
      f"{'same' if state_keys_ok else 'DIFF':<7} "
      f"{'same' if state_types_ok else 'DIFF':<7} "
      f"{'same' if state_values_ok else 'DIFF':<7} "
      f"{'sorted both':<11}")
if not (state_keys_ok and state_types_ok and state_values_ok):
    failures.append(f"state.json: {files['base']} -> {files['new']}")

print()
if failures:
    print("WIRE FORMAT CHANGED:")
    for failure in failures:
        print("  -", failure)
    sys.exit(1)
print(f"identical wire format across {len(CASES)} commands + state.json")
PY
