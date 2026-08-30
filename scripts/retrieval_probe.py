#!/usr/bin/env python3
"""Score the advertised surface the way a client-side tool search scores it.

Claude Code (v2.1.221+) hands the model NOTHING but tool NAMES for every MCP
tool -- `formatDeferredToolLine` in the shipped client is literally `e.name` --
and the model gets a schema back only by asking `ToolSearch` for one. The
match that decides whether `logic_record_automation` is ever seen is a
keyword/BM25 ranking over the tool's name, its description and its argument
names and descriptions, run on Anthropic's side over the definitions the client
uploaded. Retrieval quality is therefore a property of THIS TEXT, and it is the
one property no test in the suite was measuring.

So: a plain BM25 (k1=1.2, b=0.75, no dependencies) over the same corpus, and a
fixed query set written the way an agent actually searches -- the technical
vocabulary it translates a musician's sentence into, not the sentence. Each
query names the tool it must surface; the probe reports the top five and a
verdict. It is re-runnable forever, so a description edit that helps one query
and breaks another cannot land unnoticed.

    python3 scripts/retrieval_probe.py                     # runs .build/release/logician
    python3 scripts/retrieval_probe.py --tools dump.json   # scores a saved dump_tools.py file
    python3 scripts/retrieval_probe.py --query "ride the fader"

Exit status is 1 when any query misses, so it can gate a change.

It talks to the binary itself rather than parsing Swift, and it KILLS that
process instead of closing its stdin: a clean EOF makes the server run its
`exitToPan()` shutdown, which would reach into the control surface of whatever
Logic Pro session the developer has open while running this.
"""
import argparse
import json
import math
import re
import signal
import subprocess
import sys
from collections import Counter

DEFAULT_BINARY = ".build/release/logician"
TOP_N = 5
K1 = 1.2
B = 0.75

# --- the query set --------------------------------------------------------
#
# (query, {tools that would be a correct top-5 hit}, intent label) or a fourth
# element: a reason this query is EXPECTED to miss.
#
# The first eight intents are README's "What you can say" table, each asked
# two or three ways; the rest walk the six toolsets. Expectations are SETS
# because several intents have more than one right first move -- surfacing
# either `logic_list_events` or `logic_edit_event` gets an agent to the flubbed
# note, and insisting on one of them would be measuring taste, not retrieval.
#
# The two queries carrying a reason stay in the set as a watch-list rather than
# being quietly deleted to make the score look better. Neither is fixable by
# editing a description, and both would take a dishonest one to fix.
QUERIES = [
    # 1. "Bounce bars 1-4 and tell me what you hear."
    ("bounce bar range master", {"logic_bounce_range"}, "bounce a range"),
    ("render the mix offline to an audio file", {"logic_bounce_range"}, "bounce a range"),
    ("listen to bars of the song", {"logic_bounce_range", "logic_get_audio_clip"}, "bounce a range"),
    # 2. "More bass around 500 Hz, about 2 dB."
    ("eq band gain frequency adjust", {"logic_set_plugin_parameter"}, "nudge an EQ band"),
    ("set plugin parameter value on a track", {"logic_set_plugin_parameter"}, "nudge an EQ band"),
    ("list the parameters of an eq plugin", {"logic_list_plugin_parameters"}, "nudge an EQ band"),
    ("add an eq plugin to a channel strip", {"logic_add_plugin"}, "nudge an EQ band"),
    # 3. "The hats are too stiff -- quantize them, but keep some feel."
    ("quantize swing region", {"logic_set_region_params"}, "quantize with swing"),
    ("region playback quantize strength groove", {"logic_set_region_params"}, "quantize with swing"),
    # 4. "A/B that compressor setting on the master."
    ("a/b compare a plugin change by ear", {"logic_evaluate_change"}, "A/B a setting"),
    ("compressor threshold parameter", {"logic_set_plugin_parameter",
                                        "logic_mcu_set_instrument_parameter"}, "A/B a setting"),
    ("print the mix before and after a change", {"logic_evaluate_change"}, "A/B a setting"),
    # 5. "Fix the flubbed note in bar 3."
    ("fix wrong note pitch midi", {"logic_edit_event", "logic_list_events"}, "fix one note"),
    ("edit a midi note velocity in a region", {"logic_edit_event"}, "fix one note"),
    ("list the midi notes in a region", {"logic_list_events"}, "fix one note"),
    # 6. "Ride the vocal up in the chorus."
    ("volume automation ride", {"logic_record_automation"}, "ride a fader"),
    ("record an automation pass over bars", {"logic_record_automation"}, "ride a fader"),
    ("read back the automation curve", {"logic_read_automation"}, "ride a fader"),
    # 7. "Give me stems of the chorus."
    ("export stems", {"logic_export_stems"}, "stems"),
    ("bounce every track separately aligned", {"logic_export_stems"}, "stems"),
    # 8. "Listen to the whole song. What would you change?"
    ("project overview tracks", {"logic_list_tracks", "logic_project_snapshot"}, "survey a project"),
    ("what is in this project", {"logic_list_tracks", "logic_project_snapshot"}, "survey a project",
     "one content word, and forty tools mention a project: nothing a description "
     "can say makes 'project' discriminating. This is the query the SERVER "
     "INSTRUCTIONS have to answer, which is why they name the six toolsets."),
    ("snapshot the whole project state to diff later", {"logic_project_snapshot"}, "survey a project"),
    ("which plugins are on which tracks", {"logic_survey_plugins"}, "survey a project"),
    # --- the six toolsets -------------------------------------------------
    ("start and stop playback", {"logic_set_playing"}, "transport"),
    ("move the playhead to a bar", {"logic_set_playhead"}, "transport"),
    ("set the cycle loop range", {"logic_set_cycle_range", "logic_set_cycle"}, "transport"),
    ("where is the playhead right now", {"logic_get_transport"}, "transport"),
    ("create a marker at the playhead", {"logic_markers"}, "markers"),
    ("list the arrangement markers", {"logic_markers"}, "markers"),
    ("change the tempo at a bar tempo map", {"logic_tempo_events"}, "tempo events"),
    ("set the project tempo bpm", {"logic_set_tempo"}, "tempo events"),
    ("time signature list", {"logic_list_signatures"}, "tempo events"),
    ("load a plugin preset patch", {"logic_plugin_preset"}, "presets"),
    ("load a software instrument on a track", {"logic_load_instrument"}, "instrument load"),
    ("bypass an insert plugin", {"logic_set_insert_bypass"}, "insert bypass"),
    ("change a track output routing to a bus", {"logic_set_track_routing"}, "routing"),
    ("reset the project back to a clean state", {"logic_reset_to"}, "reset"),
    ("mixer snapshot of every fader", {"logic_mixer_snapshot"}, "snapshot"),
    ("split a region at the playhead", {"logic_split_region"}, "split region"),
    ("strip silence from an audio region", {"logic_remove_silence"}, "remove silence"),
    ("add a send to a reverb bus", {"logic_add_send"}, "sends"),
    ("set the send level to an aux", {"logic_mcu_set_send", "logic_add_send"}, "sends"),
    ("turn off the click metronome", {"logic_set_metronome"}, "metronome"),
    ("trigger a keyboard shortcut key command", {"logic_trigger_key_command"}, "key commands"),
    ("register logic key commands during onboarding", {"logic_setup_key_commands"}, "key commands"),
    ("open the event list editor", {"logic_list_events"}, "event list"),
    ("record arm a track", {"logic_set_track_record_arm"}, "record arm"),
    ("mute and solo a track", {"logic_set_track_mute", "logic_set_track_solo"}, "mute/solo"),
    ("freeze a track and render it offline", {"logic_render_track"}, "freeze"),
    ("freeze a track to save cpu", {"logic_render_track"}, "freeze",
     "asks for a capability this server does not have: logic_render_track "
     "freezes to get a FILE and unfreezes again, so it never saves anyone CPU. "
     "Putting 'cpu' in its description to win this query would be a lie."),
    ("bounce a region in place", {"logic_bounce_in_place"}, "bounce in place"),
    ("list the mixer channel strips buses and auxes", {"logic_list_strips"}, "strips"),
    ("record midi from a controller", {"logic_record_midi"}, "record midi"),
    ("check that logic is ready and set up", {"logic_health"}, "readiness"),
]


def tokenize(text):
    """Lowercase, split on anything that is not a letter or digit, then strip
    the plural/participle endings that make `stems` miss `stem`. Crude on
    purpose: the point is to model a keyword matcher, not to out-linguist one.
    """
    tokens = []
    for word in re.split(r"[^a-z0-9]+", text.lower()):
        if not word:
            continue
        tokens.append(word)
        for suffix in ("ing", "ies", "es", "ed", "s"):
            if len(word) > len(suffix) + 2 and word.endswith(suffix):
                tokens.append(word[: -len(suffix)])
                break
    return tokens


def corpus_text(tool):
    """Everything a keyword matcher gets to see: the name, the description, and
    every argument's name and description, at every nesting level a schema
    reaches. Annotations (including `title`) are deliberately excluded -- they
    are client display metadata, not part of the definition text a search
    ranks."""
    parts = [tool["name"], tool.get("description", "")]

    def walk(schema):
        if not isinstance(schema, dict):
            return
        for key, value in (schema.get("properties") or {}).items():
            parts.append(key)
            if isinstance(value, dict):
                parts.append(value.get("description", ""))
                for option in value.get("enum") or []:
                    if isinstance(option, str):
                        parts.append(option)
                walk(value)
                walk(value.get("items") or {})

    walk(tool.get("inputSchema") or {})
    return " ".join(parts)


class BM25:
    """Textbook Okapi BM25. Written out rather than imported so the probe has
    no dependency that could drift, and so the ranking it reports is the one
    printed here."""

    def __init__(self, documents, k1=K1, b=B):
        self.k1, self.b = k1, b
        self.docs = [Counter(tokenize(text)) for text in documents]
        self.lengths = [sum(doc.values()) for doc in self.docs]
        self.average_length = sum(self.lengths) / max(1, len(self.docs))
        frequencies = Counter()
        for doc in self.docs:
            frequencies.update(doc.keys())
        total = len(self.docs)
        self.idf = {
            term: math.log(1 + (total - count + 0.5) / (count + 0.5))
            for term, count in frequencies.items()
        }

    def scores(self, query):
        terms = tokenize(query)
        out = []
        for index, doc in enumerate(self.docs):
            length = self.lengths[index]
            score = 0.0
            for term in terms:
                frequency = doc.get(term, 0)
                if not frequency:
                    continue
                denominator = frequency + self.k1 * (
                    1 - self.b + self.b * length / self.average_length
                )
                score += self.idf[term] * frequency * (self.k1 + 1) / denominator
            out.append(score)
        return out


def load_tools(binary=None, dump=None):
    if dump:
        with open(dump) as handle:
            return json.load(handle)["tools"]
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                    "clientInfo": {"name": "retrieval_probe", "version": "0"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    ]
    process = subprocess.Popen([binary], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    process.stdin.write("".join(json.dumps(r) + "\n" for r in requests).encode())
    process.stdin.flush()
    tools = None
    while tools is None:
        line = process.stdout.readline()
        if not line:
            break
        message = json.loads(line)
        if message.get("id") == 2:
            tools = message["result"]["tools"]
    process.send_signal(signal.SIGKILL)  # never a clean EOF; see the module docstring
    process.wait()
    if tools is None:
        sys.exit("no tools/list response from " + binary)
    return tools


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("binary", nargs="?", default=DEFAULT_BINARY,
                        help="logician binary to ask for tools/list")
    parser.add_argument("--tools", help="score a saved dump_tools.py JSON file instead")
    parser.add_argument("--query", help="score one ad-hoc query and exit 0")
    parser.add_argument("--top", type=int, default=TOP_N)
    arguments = parser.parse_args()

    tools = load_tools(arguments.binary, arguments.tools)
    names = [tool["name"] for tool in tools]
    index = BM25([corpus_text(tool) for tool in tools])

    def top(query, count):
        ranked = sorted(zip(names, index.scores(query)), key=lambda pair: -pair[1])
        return ranked[:count]

    if arguments.query:
        print("query: %s" % arguments.query)
        for rank, (name, score) in enumerate(top(arguments.query, arguments.top), 1):
            print("  %d. %-36s %6.2f" % (rank, name, score))
        return 0

    print("BM25 retrieval probe over %d tools, top-%d\n" % (len(tools), arguments.top))
    misses, surprises, scored = [], [], 0
    by_intent = {}
    for entry in QUERIES:
        query, expected, intent = entry[:3]
        reason = entry[3] if len(entry) > 3 else None
        ranked = top(query, arguments.top)
        hit = any(name in expected for name, _ in ranked)
        rank = next((i for i, (name, _) in enumerate(ranked, 1) if name in expected), None)
        if reason is None:
            scored += 1
            by_intent.setdefault(intent, []).append(hit)
            label = "HIT " if hit else "MISS"
        else:
            label = "hit?" if hit else "known"
        print("%s  %-52s  [%s]" % (label, query, intent))
        for position, (name, score) in enumerate(ranked, 1):
            mark = "*" if name in expected else " "
            print("      %s%d. %-36s %6.2f" % (mark, position, name, score))
        if hit:
            print("      -> rank %d of %s" % (rank, "/".join(sorted(expected))))
        else:
            print("      -> MISSING: %s" % "/".join(sorted(expected)))
        if reason:
            print("      -> expected to miss: %s" % reason)
            if hit:
                surprises.append(query)
        elif not hit:
            misses.append((query, expected, intent))
        print()

    hits = scored - len(misses)
    print("=" * 72)
    print("%d/%d scored queries hit top-%d (%.0f%%); %d known-unwinnable held out"
          % (hits, scored, arguments.top, 100 * hits / scored, len(QUERIES) - scored))
    weak = [intent for intent, results in by_intent.items() if not all(results)]
    if weak:
        print("intents with a miss: %s" % ", ".join(sorted(weak)))
    for query, expected, intent in misses:
        print("  MISS  %-52s expected %s" % (query, "/".join(sorted(expected))))
    for query in surprises:
        print("  NOTE  a held-out query now hits; revisit its reason: %s" % query)
    return 1 if misses else 0


if __name__ == "__main__":
    sys.exit(main())
