import XCTest

@testable import Logician

/// `logic_find_tool`: the search, and the promise that it ranks the way
/// `scripts/retrieval_probe.py` says the surface ranks.
///
/// The probe is the only measurement we have of whether a description edit
/// helps or hurts discovery, and it has scored this surface since the
/// retrieval-quality pass. Now that the server does the same search itself,
/// the two must not drift: `testTheProbesScoredQueriesAllHitTopFive` runs the
/// probe's 53 scored queries through the real tool and asserts the same
/// verdict the probe prints, so a Swift-side change that improves one query
/// and quietly breaks another fails here, and a Python-side change that stops
/// describing the shipped behaviour fails here too.
///
/// Verified against the shipped binary while this was written: over the 55
/// probe queries, the tool's top five agreed with the probe's on every name
/// AND every score to two decimal places, 55 out of 55.
final class ToolSearchTests: XCTestCase {
    private var server = MCPServer()

    override func setUp() {
        super.setUp()
        server = MCPServer()
        MCPServer.activeToolsets = Toolset.all
    }

    override func tearDown() {
        // Process-global, like every other test that narrows the surface.
        MCPServer.activeToolsets = Toolset.all
        super.tearDown()
    }

    // MARK: - Driving the tool

    private func find(
        _ query: String, limit: Int? = nil, schemas: Bool? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        var arguments: [String: Any] = ["query": query]
        if let limit { arguments["limit"] = limit }
        if let schemas { arguments["schemas"] = schemas }
        let result = try server.handleFindTool(arguments)
        return try XCTUnwrap(result as? [String: Any], file: file, line: line)
    }

    private func matches(
        _ query: String, limit: Int? = nil, schemas: Bool? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [[String: Any]] {
        let result = try find(query, limit: limit, schemas: schemas, file: file, line: line)
        return try XCTUnwrap(result["matches"] as? [[String: Any]], file: file, line: line)
    }

    private func names(
        _ query: String, limit: Int? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String] {
        try matches(query, limit: limit, schemas: false, file: file, line: line)
            .compactMap { $0["name"] as? String }
    }

    // MARK: - Agreement with the probe

    /// `scripts/retrieval_probe.py`'s QUERIES, minus the two it holds out as
    /// known-unwinnable (`what is in this project`, one content word against
    /// forty tools that mention a project; and `freeze a track to save cpu`,
    /// which asks for a capability this server does not have). Those two are
    /// deliberately absent rather than asserted as misses: their reasons are
    /// documented in the probe, and pinning a MISS here would make an honest
    /// future improvement fail a test.
    ///
    /// The expectations are SETS because several intents have more than one
    /// right first move — surfacing either `logic_list_events` or
    /// `logic_edit_event` gets an agent to the flubbed note.
    private static let probeQueries: [(query: String, expected: Set<String>, intent: String)] = [
        ("bounce bar range master", ["logic_bounce_range"], "bounce a range"),
        ("render the mix offline to an audio file", ["logic_bounce_range"], "bounce a range"),
        ("listen to bars of the song", ["logic_bounce_range", "logic_get_audio_clip"], "bounce a range"),
        ("eq band gain frequency adjust", ["logic_set_plugin_parameter"], "nudge an EQ band"),
        ("set plugin parameter value on a track", ["logic_set_plugin_parameter"], "nudge an EQ band"),
        ("list the parameters of an eq plugin", ["logic_list_plugin_parameters"], "nudge an EQ band"),
        ("add an eq plugin to a channel strip", ["logic_add_plugin"], "nudge an EQ band"),
        ("quantize swing region", ["logic_set_region_params"], "quantize with swing"),
        ("region playback quantize strength groove", ["logic_set_region_params"], "quantize with swing"),
        ("a/b compare a plugin change by ear", ["logic_evaluate_change"], "A/B a setting"),
        ("compressor threshold parameter", ["logic_mcu_set_instrument_parameter", "logic_set_plugin_parameter"], "A/B a setting"),
        ("print the mix before and after a change", ["logic_evaluate_change"], "A/B a setting"),
        ("fix wrong note pitch midi", ["logic_edit_event", "logic_list_events"], "fix one note"),
        ("edit a midi note velocity in a region", ["logic_edit_event"], "fix one note"),
        ("list the midi notes in a region", ["logic_list_events"], "fix one note"),
        ("volume automation ride", ["logic_record_automation"], "ride a fader"),
        ("record an automation pass over bars", ["logic_record_automation"], "ride a fader"),
        ("read back the automation curve", ["logic_read_automation"], "ride a fader"),
        ("delete the automation on a track", ["logic_remove_automation"], "remove automation"),
        ("remove an automation curve i recorded", ["logic_remove_automation"], "remove automation"),
        ("export stems", ["logic_export_stems"], "stems"),
        ("bounce every track separately aligned", ["logic_export_stems"], "stems"),
        ("project overview tracks", ["logic_list_tracks", "logic_project_snapshot"], "survey a project"),
        ("snapshot the whole project state to diff later", ["logic_project_snapshot"], "survey a project"),
        ("which plugins are on which tracks", ["logic_survey_plugins"], "survey a project"),
        ("start and stop playback", ["logic_set_playing"], "transport"),
        ("move the playhead to a bar", ["logic_set_playhead"], "transport"),
        ("set the cycle loop range", ["logic_set_cycle", "logic_set_cycle_range"], "transport"),
        ("where is the playhead right now", ["logic_get_transport"], "transport"),
        ("create a marker at the playhead", ["logic_markers"], "markers"),
        ("list the arrangement markers", ["logic_markers"], "markers"),
        ("change the tempo at a bar tempo map", ["logic_tempo_events"], "tempo events"),
        ("set the project tempo bpm", ["logic_set_tempo"], "tempo events"),
        ("time signature list", ["logic_list_signatures"], "tempo events"),
        ("load a plugin preset patch", ["logic_plugin_preset"], "presets"),
        ("load a software instrument on a track", ["logic_load_instrument"], "instrument load"),
        ("bypass an insert plugin", ["logic_set_insert_bypass"], "insert bypass"),
        ("change a track output routing to a bus", ["logic_set_track_routing"], "routing"),
        ("reset the project back to a clean state", ["logic_reset_to"], "reset"),
        ("mixer snapshot of every fader", ["logic_mixer_snapshot"], "snapshot"),
        ("split a region at the playhead", ["logic_split_region"], "split region"),
        ("strip silence from an audio region", ["logic_remove_silence"], "remove silence"),
        ("add a send to a reverb bus", ["logic_add_send"], "sends"),
        ("set the send level to an aux", ["logic_add_send", "logic_mcu_set_send"], "sends"),
        ("turn off the click metronome", ["logic_set_metronome"], "metronome"),
        ("trigger a keyboard shortcut key command", ["logic_trigger_key_command"], "key commands"),
        ("register logic key commands during onboarding", ["logic_setup_key_commands"], "key commands"),
        ("open the event list editor", ["logic_list_events"], "event list"),
        ("record arm a track", ["logic_set_track_record_arm"], "record arm"),
        ("mute and solo a track", ["logic_set_track_mix"], "mute/solo"),
        ("set the track volume fader to a db value", ["logic_set_track_mix"], "fader"),
        ("select every region on a track", ["logic_select_regions"], "select regions"),
        ("freeze a track and render it offline", ["logic_render_track"], "freeze"),
        ("bounce a region in place", ["logic_bounce_in_place"], "bounce in place"),
        ("list the mixer channel strips buses and auxes", ["logic_list_strips"], "strips"),
        ("record midi from a controller", ["logic_record_midi"], "record midi"),
        ("check that logic is ready and set up", ["logic_health"], "readiness")
    ]

    func testTheProbesScoredQuerySetIsTheOneTheProbeScores() {
        // A guard on the table above, not on the search: a query deleted here
        // to make the score look better would otherwise pass silently.
        XCTAssertEqual(ToolSearchTests.probeQueries.count, 57)
    }

    func testTheProbesScoredQueriesAllHitTopFive() throws {
        var misses: [String] = []
        for (query, expected, intent) in ToolSearchTests.probeQueries {
            let ranked = try names(query, limit: 5)
            if !ranked.contains(where: expected.contains) {
                misses.append("[\(intent)] '\(query)' wanted one of "
                    + "\(expected.sorted().joined(separator: "/")), got "
                    + ranked.joined(separator: ", "))
            }
        }
        XCTAssertTrue(
            misses.isEmpty,
            "retrieval regressed against scripts/retrieval_probe.py:\n" + misses.joined(separator: "\n")
        )
    }

    /// The tokenizer is the probe's, down to the crude suffix strip that lets
    /// `stems` reach `stem`. Both forms are kept, never substituted.
    func testTheTokenizerMatchesTheProbes() {
        XCTAssertEqual(ToolSearch.tokenize("Bounce-in-place!"), ["bounce", "in", "place"])
        XCTAssertEqual(ToolSearch.tokenize("stems"), ["stems", "stem"])
        XCTAssertEqual(ToolSearch.tokenize("quantize"), ["quantize"])
        XCTAssertEqual(ToolSearch.tokenize("bypasses"), ["bypasses", "bypass"])
        XCTAssertEqual(ToolSearch.tokenize("recording"), ["recording", "record"])
        // Too short for the rule (len > len(suffix) + 2), exactly as in Python.
        XCTAssertEqual(ToolSearch.tokenize("les"), ["les"])
        XCTAssertEqual(ToolSearch.tokenize("logic_set_track_mix"),
                       ["logic", "set", "track", "mix"])
        XCTAssertEqual(ToolSearch.tokenize("  "), [])
    }

    /// `scripts/retrieval_probe.py`'s tokenizer, written out the way Python
    /// writes it: lowercase the whole string (Unicode, `str.lower()`), then
    /// keep the a-z0-9 CODE POINTS and treat everything else as a separator.
    ///
    /// The shipped `ToolSearch.tokenize` is a UTF-8 byte scan instead, for the
    /// 10 ms an index build costs when it walks Swift `Character`s. What it
    /// owes the probe is the token multiset, not the line shape, so the rule
    /// is written here once and checked against the real corpus below.
    private static func probeTokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        func flush() {
            defer { word = "" }
            guard !word.isEmpty else { return }
            tokens.append(word)
            for suffix in ["ing", "ies", "es", "ed", "s"] where word.count > suffix.count + 2 {
                if word.hasSuffix(suffix) {
                    tokens.append(String(word.dropLast(suffix.count)))
                    break
                }
            }
        }
        for scalar in text.lowercased().unicodeScalars {
            if (97...122).contains(scalar.value) || (48...57).contains(scalar.value) {
                word.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// Every document in the REAL corpus, plus every probe query, tokenized
    /// both ways and asserted identical — the same tokens, in the same order,
    /// with the same repeats, which is everything BM25 reads. This is the
    /// promise the header makes in place of "it is a line-by-line port".
    func testTheByteTokenizerAgreesWithTheProbesRuleOverTheWholeCorpus() {
        for tool in server.toolRegistry() {
            let text = ToolSearch.corpusText(for: tool.definition)
            XCTAssertEqual(ToolSearch.tokenize(text), Self.probeTokenize(text), tool.name)
        }
        for (query, _, _) in ToolSearchTests.probeQueries {
            XCTAssertEqual(ToolSearch.tokenize(query), Self.probeTokenize(query), query)
        }
        // Non-ASCII is in the corpus (em dashes, ×, ø) and has to fall out as a
        // separator on both sides.
        for text in ["bounce — in — place", "0 dB × 2", "Sørensen's aux"] {
            XCTAssertEqual(ToolSearch.tokenize(text), Self.probeTokenize(text), text)
        }
    }

    /// The one deliberate divergence, pinned so it is a known edge rather than
    /// a surprise: U+0130 (İ) and U+212A (K) are the only two characters in
    /// Unicode whose lowercase contains an ASCII letter, and a byte scan
    /// cannot see that. Neither appears anywhere in this surface's text, so
    /// nothing the probe measures can reach it.
    func testTheTwoCharactersTheByteScanDeliberatelyDropsAreKnownAndAbsent() {
        XCTAssertEqual(ToolSearch.tokenize("\u{0130}"), [])
        XCTAssertEqual(Self.probeTokenize("\u{0130}"), ["i"])
        XCTAssertEqual(ToolSearch.tokenize("\u{212A}"), [])
        XCTAssertEqual(Self.probeTokenize("\u{212A}"), ["k"])
        for tool in server.toolRegistry() {
            // By SCALAR, not `String.contains`: U+212A is canonically
            // equivalent to plain "K", so a string comparison finds it in
            // every description that mentions kHz.
            let scalars = ToolSearch.corpusText(for: tool.definition).unicodeScalars
            XCTAssertFalse(scalars.contains { $0.value == 0x130 || $0.value == 0x212A }, tool.name)
        }
    }

    /// The corpus is name + description + argument names + argument
    /// descriptions + enum values, at every nesting depth — and NOT the
    /// annotations, which are client display metadata rather than definition
    /// text. The probe excludes them; so must this.
    func testTheCorpusReadsTheSameFieldsAsTheProbe() {
        let text = ToolSearch.corpusText(for: [
            "name": "logic_example",
            "description": "A described thing.",
            "annotations": ["title": "Zebedee"],
            "inputSchema": [
                "type": "object",
                "properties": [
                    "mode": ["type": "string", "description": "Which way.", "enum": ["fastly", 3]],
                    "nested": [
                        "type": "object",
                        "properties": ["inner": ["type": "string", "description": "Deep."]]
                    ],
                    "many": [
                        "type": "array",
                        "items": ["type": "object", "properties": ["leaf": ["type": "number"]]]
                    ]
                ]
            ]
        ])
        let tokens = Set(ToolSearch.tokenize(text))
        for expected in ["logic", "example", "described", "mode", "way", "fastly",
                         "nested", "inner", "deep", "many", "leaf"] {
            XCTAssertTrue(tokens.contains(expected), "corpus lost '\(expected)'")
        }
        XCTAssertFalse(tokens.contains("zebedee"), "annotations must not be in the corpus")
    }

    /// The advertised description, warning note included — the corpus has to
    /// be the text a client would actually have read.
    func testTheCorpusUsesTheAdvertisedDescriptionNotTheRawOne() throws {
        let warner = try XCTUnwrap(server.toolRegistry().first(where: \.mayWarn))
        let text = ToolSearch.corpusText(for: warner.definition)
        XCTAssertTrue(text.contains(Tool.warningNote), warner.name)
    }

    // MARK: - Exact names, and why there is no second tool

    /// Every tool's own name finds that tool FIRST. This is the test that
    /// makes a separate `logic_tool_schema` unnecessary: the lookup-by-name
    /// job it would have done is done here, and a name that turns out not to
    /// exist degrades into search results rather than a not-found error.
    ///
    /// Pure BM25 could not carry this — over this corpus a tool's own name
    /// ranks it first for only 59 of the 82, and `logic_list_inserts` comes
    /// back NINTH behind its own family.
    func testEveryToolsOwnNameRanksItFirst() throws {
        for tool in server.toolRegistry() {
            let ranked = try names(tool.name, limit: 1)
            XCTAssertEqual(ranked.first, tool.name)
        }
    }

    func testABareNameWithoutThePrefixAlsoResolves() throws {
        XCTAssertEqual(try names("list_inserts", limit: 1).first, "logic_list_inserts")
        XCTAssertEqual(try names("  BOUNCE_RANGE ", limit: 1).first, "logic_bounce_range")
    }

    /// A name inside a sentence still resolves, but only in the prefixed form
    /// — the bare form is accepted only when it is the WHOLE query, so that a
    /// natural-language search containing a word like `markers` is ranked by
    /// the search rather than pinned by an accident of naming.
    func testANameInsideASentenceResolvesOnlyInThePrefixedForm() throws {
        let sentence = try matches("what arguments does logic_list_inserts take?", schemas: false)
        XCTAssertEqual(sentence.first?["name"] as? String, "logic_list_inserts")
        XCTAssertEqual(sentence.first?["matched_by"] as? String, "name")
        // `markers` is a real tool name AND an ordinary English word here.
        let english = try matches("list the arrangement markers", schemas: false)
        XCTAssertEqual(english.first?["matched_by"] as? String, "keyword")
    }

    func testAnUnknownNameFallsBackToSearchRatherThanFailing() throws {
        let result = try find("logic_make_it_punchier", limit: 5, schemas: false)
        XCTAssertEqual(result["success"] as? Bool, true)
        XCTAssertFalse(try names("logic_make_it_punchier").isEmpty)
    }

    // MARK: - What a hit carries

    func testAHitCarriesTheFullTypedDefinitionByDefault() throws {
        let hit = try XCTUnwrap(try matches("logic_record_automation").first)
        XCTAssertEqual(hit["name"] as? String, "logic_record_automation")
        let tool = try XCTUnwrap(server.toolRegistry().first { $0.name == "logic_record_automation" })
        XCTAssertEqual(hit["title"] as? String, tool.title)
        XCTAssertEqual(hit["description"] as? String, tool.definition["description"] as? String)
        let schema = try XCTUnwrap(hit["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertNotNil(schema["properties"])
        let annotations = try XCTUnwrap(hit["annotations"] as? [String: Any])
        XCTAssertEqual(annotations["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(annotations["destructiveHint"] as? Bool, true)
        XCTAssertNotNil(hit["score"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(try find("bounce a range")))
    }

    /// The cheap first pass: names, titles, descriptions and toolsets, no
    /// schemas. It has to be materially smaller or it is not a mode.
    func testSchemasFalseDropsTheSchemasAndTheAnnotations() throws {
        let lean = try matches("bounce a bar range", schemas: false)
        for hit in lean {
            XCTAssertNil(hit["inputSchema"], hit["name"] as? String ?? "?")
            XCTAssertNil(hit["annotations"])
            XCTAssertNotNil(hit["description"])
            XCTAssertNotNil(hit["toolsets"])
        }
        let full = try matches("bounce a bar range")
        XCTAssertEqual(full.count, lean.count)
        let size: ([[String: Any]]) throws -> Int = {
            try JSONSerialization.data(withJSONObject: $0).count
        }
        XCTAssertLessThan(try size(lean), try size(full) * 2 / 3)
    }

    // MARK: - Toolset awareness

    func testEveryHitNamesTheToolsetsThatHoldIt() throws {
        for hit in try matches("split a region at the playhead", schemas: false) {
            let name = try XCTUnwrap(hit["name"] as? String)
            let sets = try XCTUnwrap(hit["toolsets"] as? [String])
            XCTAssertEqual(Set(sets), Set(Toolset.membership[name]?.map(\.rawValue) ?? []))
            XCTAssertFalse(sets.isEmpty, name)
        }
    }

    /// The whole point of the tool for a narrowed session: it searches the
    /// FULL registry, says the hit is not active, and names the flag.
    func testAHitOutsideTheActiveSetsSaysSoAndNamesTheFlag() throws {
        MCPServer.activeToolsets = [.core]
        let hit = try XCTUnwrap(try matches("export stems", schemas: false).first)
        XCTAssertEqual(hit["name"] as? String, "logic_export_stems")
        XCTAssertEqual(hit["active"] as? Bool, false)
        let note = try XCTUnwrap(hit["not_offered"] as? String)
        XCTAssertTrue(note.contains("delivery"), note)
        XCTAssertTrue(note.contains(MCPServer.toolsetsFlag), note)
        XCTAssertTrue(note.contains(MCPServer.toolsetsEnvironmentVariable), note)
        // The same sentence the refusal gives, from the same place.
        let refusal = try XCTUnwrap(server.unknownToolMessage(name: "logic_export_stems"))
        XCTAssertTrue(refusal.contains(note), refusal)
    }

    func testAnActiveHitCarriesNoFlagNoise() throws {
        MCPServer.activeToolsets = [.core]
        let hit = try XCTUnwrap(try matches("logic_bounce_range", schemas: false).first)
        XCTAssertEqual(hit["active"] as? Bool, true)
        XCTAssertNil(hit["not_offered"])
    }

    func testTheSearchCoversTheWholeRegistryHoweverNarrowTheSessionIs() throws {
        MCPServer.activeToolsets = [.core]
        let result = try find("split a region at the playhead", schemas: false)
        XCTAssertEqual(result["searched_tools"] as? Int, server.toolRegistry().count)
        XCTAssertEqual(result["active_toolsets"] as? [String], ["core"])
        XCTAssertTrue(try names("split a region at the playhead").contains("logic_split_region"))
        // And the whole probe set still works from inside a narrowed session.
        for (query, expected, intent) in ToolSearchTests.probeQueries {
            XCTAssertTrue(
                try names(query, limit: 5).contains(where: expected.contains),
                "[\(intent)] '\(query)' missed with --toolsets=core"
            )
        }
    }

    /// The map has to be in every set: the session most likely to need a tool
    /// it cannot see is the narrowest one.
    func testTheFinderItselfIsOfferedByEveryToolset() {
        XCTAssertEqual(Toolset.membership["logic_find_tool"], Set(Toolset.allCases))
        for set in Toolset.allCases {
            MCPServer.activeToolsets = [set]
            XCTAssertTrue(
                server.activeTools().contains { $0.name == "logic_find_tool" },
                "\(set.rawValue) does not offer logic_find_tool"
            )
        }
    }

    /// It reads a constant, so it must be `readOnly` — and its description has
    /// to stay short, because it exists for exactly the contexts where bytes
    /// are the problem.
    func testTheFinderIsReadOnlyAndCheapToAdvertise() throws {
        let tool = try XCTUnwrap(server.toolRegistry().first { $0.name == "logic_find_tool" })
        XCTAssertTrue(tool.safety == .readOnly)
        XCTAssertTrue(tool.idempotent)
        XCTAssertFalse(tool.mayWarn)
        XCTAssertNil(tool.listenNoteText)
        let advertised = try JSONSerialization.data(withJSONObject: tool.definition).count
        XCTAssertLessThan(advertised, 1600, "the map is not supposed to cost a kilobyte of prose")
    }

    // MARK: - The cap, and the edges

    func testTheDefaultIsFiveAndTenIsTheCeiling() throws {
        XCTAssertEqual(try names("track").count, 5)
        XCTAssertEqual(try names("track", limit: 10).count, 10)
        XCTAssertEqual(try names("track", limit: 1).count, 1)
    }

    /// Refused, not clamped: an agent that asked for 40 and got 10 would
    /// believe it had seen the whole ranking.
    func testAnOutOfRangeLimitIsRefusedRatherThanClamped() {
        for limit in [0, -1, 11, 40] {
            XCTAssertThrowsError(try server.handleFindTool(["query": "track", "limit": limit])) {
                XCTAssertTrue("\($0)".contains("1-10"), "\($0)")
            }
        }
    }

    /// A number a JSON parser may hand over as a Double is still a limit.
    func testAFloatingPointLimitIsAccepted() throws {
        let result = try server.handleFindTool(["query": "track", "limit": 3.0, "schemas": false])
        let matches = try XCTUnwrap((result as? [String: Any])?["matches"] as? [[String: Any]])
        XCTAssertEqual(matches.count, 3)
    }

    func testAQueryThatMatchesNothingIsAnEmptyResultWithAReasonNotAnError() throws {
        let result = try find("zzzz qqqq wwww", schemas: false)
        XCTAssertEqual(result["success"] as? Bool, true)
        XCTAssertEqual(result["state"] as? String, "searched")
        XCTAssertEqual((result["matches"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(result["match_count"] as? Int, 0)
        let note = try XCTUnwrap(result["note"] as? String)
        XCTAssertTrue(note.contains("KEYWORD"), note)
        XCTAssertTrue(note.contains("keycommands"), note)
    }

    /// Nothing to search for is a caller bug, and it is refused as one. The
    /// empty-result note says no tool shares a WORD with the query, which
    /// would be a lie about a query that has no words in it.
    func testAQueryWithNoSearchableWordsIsRefused() {
        for query in ["", "   ", "\n", "... ??? ---"] {
            XCTAssertThrowsError(try server.handleFindTool(["query": query])) {
                XCTAssertTrue("\($0)".contains("query"), "\($0)")
            }
        }
        XCTAssertThrowsError(try server.handleFindTool([:]))
    }

    /// Stop words are not filtered — BM25's IDF already makes them worthless —
    /// so a stop-word-only query returns a shrug, not a crash.
    func testAStopWordOnlyQueryStillAnswers() throws {
        for hit in try matches("the a of", schemas: false) {
            XCTAssertNotNil(hit["name"])
            XCTAssertLessThan(try XCTUnwrap(hit["score"] as? Double), 2.0)
        }
    }

    // MARK: - The failure paths point here

    func testTheUnknownToolErrorNamesTheFinder() throws {
        let message = try XCTUnwrap(server.unknownToolMessage(name: "logic_make_it_better"))
        XCTAssertTrue(message.contains("logic_find_tool"), message)
    }

    func testTheToolsetExcludedErrorAlsoNamesTheFinder() throws {
        MCPServer.activeToolsets = [.core]
        let message = try XCTUnwrap(server.unknownToolMessage(name: "logic_export_stems"))
        XCTAssertTrue(message.contains("not in this session's active toolsets"), message)
        XCTAssertTrue(message.contains("logic_find_tool"), message)
    }

    /// The finder is always callable, so the hint it prints can never point at
    /// a tool the caller cannot reach.
    func testTheFinderIsNeverItselfAnUnknownTool() {
        for set in Toolset.allCases {
            MCPServer.activeToolsets = [set]
            XCTAssertNil(server.unknownToolMessage(name: "logic_find_tool"), set.rawValue)
        }
    }

    // MARK: - Built once, over the registry it claims to describe

    /// The index is a process-wide `static let`, so the ONLY thing that could
    /// make it wrong is describing a different registry from the one the
    /// handler subscripts with its document indices. Same count, and every
    /// tool's own name scores its own document — which no shifted alignment
    /// could satisfy for all 85.
    func testTheSharedIndexStaysAlignedWithTheRegistry() {
        let registry = server.toolRegistry()
        XCTAssertEqual(ToolSearch.advertisedSurface.documentCount, registry.count)
        for (position, tool) in registry.enumerated() {
            let scores = ToolSearch.advertisedSurface.scores(for: tool.name)
            XCTAssertGreaterThan(scores[position], 0, tool.name)
        }
    }

    /// The registry is an array literal over string literals, so it is built
    /// once per process however many searches run and however many matches
    /// each one returns. It used to be built 3 times per call PLUS once per
    /// match, because `toolsetExclusionNote` asked it "is this a real tool"
    /// for every hit — 13 constructions of all 85 tools for one `limit: 10`
    /// answer.
    func testTheRegistryIsBuiltOncePerProcessNotOncePerMatch() throws {
        MCPServer.activeToolsets = [.core]
        for _ in 0..<3 {
            XCTAssertEqual(try names("track", limit: 10).count, 10)
            _ = try names("export stems bounce region plugin send marker tempo", limit: 10)
        }
        XCTAssertEqual(MCPServer.toolRegistryBuilds, 1)
    }

    /// Reordering that guard must not change WHO gets the sentence: exactly
    /// the matches this session cannot call, and no one else.
    func testANarrowedSessionMarksExactlyTheMatchesItCannotCall() throws {
        MCPServer.activeToolsets = [.core]
        var sawBoth = (offered: false, withheld: false)
        for query in ["export stems", "track", "region", "bounce a bar range", "plugin"] {
            for hit in try matches(query, limit: 10, schemas: false) {
                let name = try XCTUnwrap(hit["name"] as? String)
                let active = try XCTUnwrap(hit["active"] as? Bool)
                XCTAssertEqual(active, hit["not_offered"] == nil, name)
                if active { sawBoth.offered = true } else { sawBoth.withheld = true }
            }
        }
        XCTAssertTrue(sawBoth.offered && sawBoth.withheld, "\(sawBoth)")
    }

    // MARK: - Determinism

    func testTheSameQueryAlwaysReturnsTheSameOrder() throws {
        // Dictionary iteration order is arbitrary in Swift, and the corpus is
        // built by walking dictionaries: BM25 reads a bag of words, so the
        // ranking must not depend on it. Ties break by registry order.
        let first = try names("plugin parameter", limit: 10)
        for _ in 0..<8 {
            XCTAssertEqual(try names("plugin parameter", limit: 10), first)
        }
    }
}
