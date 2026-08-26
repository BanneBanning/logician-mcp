#!/usr/bin/env python3
"""Behaviour probe: drive tools/call down every error path the refactor
touched (dispatch, unknown-argument rejection, the split mute/solo case, the
evaluate_change method fallthrough) and dump the raw results.

Every request here throws before the handler reaches Logic Pro or CoreMIDI,
so nothing on the machine is touched.
"""
import json
import subprocess
import sys

binary, out_path = sys.argv[1], sys.argv[2]
calls = [
    ("nope_not_a_tool", {}),
    ("logic_list_windows", {"bogus": 1}),
    ("logic_list_inserts", {}),
    ("logic_list_inserts", {"track_name": "X", "expected_current_value": "y"}),
    ("logic_set_track_volume", {"track_name": "X"}),
    ("logic_set_track_mute", {"track_name": "X"}),
    ("logic_set_track_solo", {"track_name": "X"}),
    ("logic_set_track_pan", {"track_name": "X"}),
    ("logic_bounce_range", {"start_bar": 1}),
    ("logic_evaluate_change", {"start_bar": 1, "end_bar": 2, "method": "nope"}),
    ("logic_evaluate_change", {"start_bar": 1, "end_bar": 2, "method": "render"}),
    ("logic_evaluate_change", {"start_bar": 1, "end_bar": 2, "method": "solo_bounce"}),
    ("logic_evaluate_change", {}),
    ("logic_setup_key_commands", {"bogus": True}),
    ("logic_set_plugin_parameter", {"window_title": "W"}),
    ("logic_move_region", {}),
    ("logic_copy_region", {}),
    ("logic_delete_region", {}),
    ("logic_mcu_set_send", {}),
    ("logic_mcu_set_plugin_parameter", {}),
    ("logic_mcu_set_instrument_parameter", {}),
    ("logic_close_plugin_window", {}),
    ("logic_list_plugin_parameters", {}),
    ("logic_open_plugin", {}),
    ("logic_close_plugin", {}),
    ("logic_select_region", {}),
    ("logic_rename_track", {}),
    ("logic_add_send", {}),
    ("logic_add_plugin", {}),
    ("logic_remove_plugin", {}),
    ("logic_set_track_stack", {}),
    # NOTE: logic_create_track, logic_duplicate_project, logic_mcu_command and
    # logic_trigger_key_command are deliberately absent - their handlers reach
    # Logic before any argument check, so probing them would act on the app.
    ("logic_set_cycle", {}),
    ("logic_set_playing", {}),
    ("logic_set_playhead", {}),
    ("logic_set_cycle_range", {}),
    ("logic_set_tempo", {}),
    ("logic_render_track", {}),
    ("logic_get_audio_clip", {}),
    ("logic_plugin_preset", {}),
    ("logic_duplicate_track", {}),
    ("logic_delete_track", {}),
    ("logic_open_project", {}),
    ("logic_new_project", {"unexpected": 1}),
]

lines = [json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                     "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "probe", "version": "0"}}})]
for n, (tool, args) in enumerate(calls, start=100):
    lines.append(json.dumps({"jsonrpc": "2.0", "id": n, "method": "tools/call",
                             "params": {"name": tool, "arguments": args}}))
stdin = "".join(l + "\n" for l in lines)
proc = subprocess.run([binary], input=stdin, capture_output=True, text=True, timeout=300)

results = {}
for line in proc.stdout.splitlines():
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    if isinstance(msg.get("id"), int) and msg["id"] >= 100:
        tool, args = calls[msg["id"] - 100]
        results[f"{msg['id']} {tool} {json.dumps(args, sort_keys=True)}"] = msg.get("result")

with open(out_path, "w") as fh:
    json.dump(results, fh, indent=2, sort_keys=True, ensure_ascii=False)
    fh.write("\n")
print(f"{len(results)}/{len(calls)} results -> {out_path}")
