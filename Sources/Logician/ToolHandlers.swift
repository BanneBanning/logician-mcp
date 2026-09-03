import Foundation

// One function per tool, reached only through that tool's `Tool` descriptor
// in ToolRegistry.swift. There is no name-matching switch left that could
// fall out of sync with the advertised list. The handlers themselves live
// in the ToolHandlers<Domain>.swift files; this one keeps the dispatch,
// the argument validation and the helpers they share.
extension MCPServer {
    /// Enforces the `additionalProperties: false` every schema declares. An
    /// argument a tool does not read must be an ERROR, never silently
    /// dropped: an agent that passes expected_current_value to a setter
    /// without compare-and-set support would otherwise be told the write
    /// succeeded and believe a precondition was checked that never was.
    private func rejectUnknownArguments(tool: Tool, arguments: [String: Any]) throws {
        guard (tool.inputSchema["additionalProperties"] as? Bool) == false,
              let properties = tool.inputSchema["properties"] as? [String: Any] else { return }
        let unknown = arguments.keys.filter { properties[$0] == nil }.sorted()
        guard !unknown.isEmpty else { return }
        throw LogicianError.invalidArguments(
            MCPServer.unknownArgumentRefusal(
                tool: tool.name, unknown: unknown, accepted: Array(properties.keys)
            )
        )
    }

    /// The refusal text for arguments a tool does not declare. Pure and
    /// `static` so both of its branches can be pinned by a test.
    ///
    /// The empty-`accepted` branch exists because eight tools declare
    /// `properties: [:]` — they take nothing at all — and for those the text
    /// used to render a bare "Accepted: .", a sentence that looks truncated
    /// and names no alternative. Measured on `logic_list_key_commands`
    /// (2026-09-02): `{"foo": 1}` was refused with *"Accepted: ."*. A refusal
    /// has one job beyond saying no, which is to say what to call instead;
    /// "this tool takes no arguments" is that answer when the list is empty.
    static func unknownArgumentRefusal(
        tool: String, unknown: [String], accepted: [String]
    ) -> String {
        let alternative = accepted.isEmpty
            ? "This tool takes no arguments."
            : "Accepted: \(accepted.sorted().joined(separator: ", "))."
        return "\(tool) does not accept: \(unknown.sorted().joined(separator: ", ")). "
            + alternative
            + " The argument was NOT applied - do not assume it took effect."
    }

    /// nil when this server has a tool called `name`; otherwise the message
    /// for the -32602 that `tools/call` answers with. An unknown name is a
    /// PROTOCOL error (bad `params.name`), not a tool that ran and failed, so
    /// it never reaches `callTool` from the request path - and the reply still
    /// names every tool that does exist, because the usual cause is a client
    /// or agent working from a stale list.
    func unknownToolMessage(name: String) -> String? {
        let offered = activeTools().map(\.name)
        guard !offered.contains(name) else { return nil }
        var message = "Unknown tool: '\(name)'. Nothing was executed."
        if let excluded = toolsetExclusionNote(name: name) { message += " " + excluded }
        message += " " + MCPServer.findToolHint
        return message + " Available tools: " + offered.sorted().joined(separator: ", ")
    }

    /// Why a tool that EXISTS is not callable here, and the flag that would
    /// make it callable — or nil when the flag is not the problem (the name is
    /// not a tool at all, or it is one this session already offers).
    ///
    /// A configuration answer, not a spelling one: saying "unknown tool" and
    /// stopping would send an agent hunting for a name it already had right.
    /// Lives on its own because two paths owe the caller this sentence —
    /// `tools/call` refusing a name, and `logic_find_tool` returning a hit the
    /// session cannot call. One sentence, one place, no way for the two to
    /// give different accounts of the same configuration.
    ///
    /// Guard order is deliberate and measured: the two dictionary/set tests
    /// come FIRST and the registry scan last, because the scan is the only
    /// expensive one and it answers a question the cheap tests have almost
    /// always already settled. `logic_find_tool` calls this once per match, so
    /// with the old order a `limit: 10` answer walked the registry ten extra
    /// times (2026-09-01: 1.7 ms of a 22 ms call, back when each walk also
    /// rebuilt it).
    func toolsetExclusionNote(name: String) -> String? {
        guard let sets = Toolset.membership[name],
              sets.isDisjoint(with: MCPServer.activeToolsets),
              toolRegistry().contains(where: { $0.name == name }) else { return nil }
        return "That tool exists but is not in this session's active toolsets"
            + " (\(MCPServer.activeToolsets.map(\.rawValue).sorted().joined(separator: ", ")))."
            + " It is in \(sets.map(\.rawValue).sorted().joined(separator: ", ")):"
            + " relaunch the server with \(MCPServer.toolsetsFlag)=<comma list>"
            + " (or the \(MCPServer.toolsetsEnvironmentVariable) environment variable,"
            + " or \(MCPServer.toolsetsFlag)=\(Toolset.everything)) to offer it."
    }

    /// Appended to every unknown-tool refusal. The name list that follows it
    /// answers "what may I call"; this answers "how do I find the right one",
    /// which is the question an agent that just guessed a name actually has.
    /// `logic_find_tool` is in every toolset, so this can never point at a
    /// tool the session does not offer.
    static let findToolHint = "To find the right tool instead of guessing, call"
        + " logic_find_tool with a few words for what you are trying to do: it searches every"
        + " tool's name, description and arguments — including the ones this session does not"
        + " offer — and returns full typed schemas."

    /// `era` is carried all the way down to `toolResult` for one reason: the
    /// `resource_link` blocks it attaches to an audio result do not exist
    /// before 2025-06-18, and a 2025-03-26 client must never see one.
    func callTool(
        name: String, arguments: [String: Any], era: MCPEra = .legacy(protocolVersion)
    ) -> [String: Any] {
        // Logic's Inspector, for the length of this call. Nothing is read and
        // nothing is pressed until a tool actually walks the inspector plane,
        // so a call that never touches it pays nothing and reports nothing —
        // see `InspectorHold`. Installed here rather than per tool because
        // "does this tool need a channel strip" is decided by the code path
        // taken, not by the tool's name: `logic_set_insert_bypass` needs one
        // for a track and none for a bus.
        logic.inspectorHold = InspectorHold()
        defer { logic.inspectorHold = nil }
        do {
            guard let tool = activeTools().first(where: { $0.name == name }) else {
                // Unreachable from `tools/call` (see unknownToolMessage), kept
                // so a direct caller cannot dispatch a name that does not exist.
                throw LogicianError.invalidArguments(unknownToolMessage(name: name) ?? "unknown tool: \(name)")
            }
            try rejectUnknownArguments(tool: tool, arguments: arguments)
            // Opt-out for the four tools that can attach ~300-800 KB of base64
            // audio. Default TRUE: a client that forwards audio blocks is the
            // reason those tools exist. A client that stringifies unknown
            // content blocks instead can now ask for the paths alone.
            let includeAudio = arguments["include_audio"] as? Bool ?? true
            var payload = try tool.handler(self)(arguments)
            // The Inspector goes back BEFORE the result is built, so
            // `inspector_restored` reports a press that has already been
            // confirmed rather than one that is still owed.
            logic.restoreInspectorAfterCall()
            payload = inspectorReported(payload)
            // `blind: true` — withhold the describable metadata so the audio
            // in this same result is the only thing left to describe it from.
            // Applied HERE, centrally, for the same reason the listen note is:
            // the withholding must not depend on which of a tool's three
            // methods produced the payload. Before the listen note, so the
            // note the agent reads is the one attached to the blind result.
            if arguments["blind"] as? Bool == true {
                payload = Blind.applied(toolName: name, payload: payload)
            }
            // Every write that changes how the song SOUNDS carries a standing
            // instruction to judge it by ear. Parameter and fader numbers say
            // nothing about how loud or good something IS (recordings differ,
            // plugins differ) - only listening does. This lives in the result
            // so every future agent gets it at exactly the right moment.
            // Which tools get it is declared per tool in ToolRegistry.swift,
            // so a new sound-changing tool cannot quietly miss out.
            // Gated on the PAYLOAD as well as the tool: a preview mode that
            // changed nothing must not ship "You changed the ARRANGEMENT"
            // beside its own "NOTHING WAS CHANGED" (see `Tool.changedNothing`).
            if let note = tool.listenNoteText,
               var successPayload = payload as? [String: Any],
               successPayload["success"] as? Bool == true,
               successPayload["listen_note"] == nil,
               !Tool.changedNothing(successPayload) {
                successPayload["listen_note"] = note
                return toolResult(
                    payload: successPayload, isError: false, includeAudio: includeAudio, era: era
                )
            }
            return toolResult(payload: payload, isError: false, includeAudio: includeAudio, era: era)
        } catch {
            logic.restoreInspectorAfterCall()
            var failure: [String: Any] = [
                "success": false,
                "verified": false,
                "state": "failed",
                "error_code": (error as? LogicianError)?.code ?? "failed",
                "error": error.localizedDescription
            ]
            // The structured half of a refusal that names an alternative —
            // `resolved_slots` on an ambiguous insert, today. Merged rather
            // than assigned so a future case cannot overwrite the five fields
            // above.
            if let details = (error as? LogicianError)?.details, !details.isEmpty {
                failure.merge(details) { current, _ in current }
            }
            return toolResult(payload: inspectorReported(failure), isError: true)
        }
    }

    /// Stamps what this call saw of Logic's Inspector onto the result — the
    /// state it FOUND, not the state it left behind, and only when it looked
    /// at all. A refusal gets it too: "the inspector is hidden" is the single
    /// most useful thing a failed strip read can say.
    ///
    /// Never overwrites a field a tool set itself, and never invents one: a
    /// missing `inspector` means this call never asked, which is a different
    /// fact from `shown`.
    private func inspectorReported(_ payload: Any) -> Any {
        guard let fields = logic.inspectorHold?.resultFields, !fields.isEmpty,
              var dictionary = payload as? [String: Any] else { return payload }
        for (key, value) in fields where dictionary[key] == nil {
            dictionary[key] = value
        }
        return dictionary
    }

    func requiredString(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else {
            throw LogicianError.invalidArguments("missing non-empty string: \(key)")
        }
        return value
    }

    /// The `track_number` of a REGION call, refused when it arrives alone.
    ///
    /// The number's value is that it is CHECKED against `track_name`
    /// (`resolveRegionRow`); on its own it would have to be trusted instead,
    /// and a row number the caller read before an edit is exactly the kind of
    /// stale handle this argument exists to catch. So the tools whose
    /// `track_name` is optional refuse the pairing rather than quietly
    /// ignoring a number they cannot use.
    func regionTrackNumber(in arguments: [String: Any]) throws -> Int? {
        guard let number = arguments["track_number"] as? Int else { return nil }
        guard arguments["track_name"] is String else {
            throw LogicianError.invalidArguments(
                "track_number needs track_name as well — the two are cross-checked against each"
                    + " other, which is the whole point of passing the number. Nothing was read"
                    + " or written."
            )
        }
        return number
    }

    /// A JSON number argument, whichever way the client typed it. `-12` and
    /// `-12.0` are the same dB value and a schema that says `"type": "number"`
    /// accepts both, so a handler that only reads `as? Double` silently ignores
    /// the integer form.
    func doubleArgument(_ key: String, in arguments: [String: Any]) -> Double? {
        MCPServer.doubleArgument(key, in: arguments)
    }

    /// The same rule, reachable from the pure argument PARSERS that have no
    /// server to hang off (`TrackMixPlan`). One implementation, so a handler
    /// and a parser cannot read the same JSON number two different ways.
    static func doubleArgument(_ key: String, in arguments: [String: Any]) -> Double? {
        (arguments[key] as? Double) ?? (arguments[key] as? Int).map(Double.init)
    }

    /// Tempo and meter for bar math: the explicit arguments when they are given,
    /// otherwise the control bar.
    ///
    /// The control bar's tempo is the tempo AT THE PLAYHEAD POSITION, so this
    /// one number describes the whole range only on a constant-tempo project.
    /// Whether it does is a separate, answerable question — see
    /// `LogicAccessibility.sampleTempoAcross`, which every caller that slices
    /// seconds asks before trusting the boundaries it computes here.
    func resolveTempoAndMeter(
        logic: LogicAccessibility, arguments: [String: Any]
    ) throws -> (tempo: Double, beatsPerBar: Double) {
        var tempo = (arguments["tempo"] as? Double)
            ?? (arguments["tempo"] as? Int).map(Double.init) ?? 0
        var beatsPerBar = (arguments["beats_per_bar"] as? Double)
            ?? (arguments["beats_per_bar"] as? Int).map(Double.init) ?? 0
        if tempo <= 0 || beatsPerBar <= 0 {
            let transport = try logic.getTransport()
            if tempo <= 0 {
                guard let read = transport["tempo"] as? Double else {
                    throw LogicianError.trackNotExposed(
                        requested: "tempo from the control bar",
                        exposed: "no tempo readable; pass an explicit 'tempo' argument"
                    )
                }
                tempo = read
            }
            if beatsPerBar <= 0 {
                beatsPerBar = Double((transport["time_signature"] as? String)?
                    .split(separator: "/").first.flatMap { Int($0) } ?? 4)
            }
        }
        return (tempo, beatsPerBar)
    }

    /// Bar positions → seconds from project start (freeze renders begin at
    /// bar 1), from an already-resolved tempo and meter. Pure and unit-tested.
    ///
    /// With a `map` READ from Logic's Tempo List this integrates the map
    /// piecewise and is correct under a tempo track. Without one it is the
    /// constant-tempo formula that has always been here — the same arithmetic,
    /// down to the operation order, so a project with no readable map takes
    /// bit-for-bit the same path it did before tempo maps existed.
    ///
    /// With a `meterMap` READ from Logic's Signature List, and only when that map
    /// actually VARIES, the bar→beat half of the conversion is integrated too:
    /// a range that spans a 4/4 → 3/4 change no longer assumes every bar in it
    /// is the same length. A nil map, a map that could not be read, and a
    /// constant one all take the single multiplication that has always been
    /// here — see the constant-meter contract on `MeterMap`, which is what keeps
    /// the common case bit-for-bit unchanged.
    static func barRangeSeconds(
        startBar: Int, endBar: Int, tempo: Double, beatsPerBar: Double,
        map: TempoMap? = nil, meterMap: MeterMap? = nil
    ) throws -> (start: Double, end: Double, tempo: Double, beatsPerBar: Double) {
        guard startBar >= 1, endBar > startBar else {
            throw LogicianError.invalidArguments("need start_bar >= 1 and end_bar > start_bar")
        }
        guard tempo > 0, beatsPerBar > 0 else {
            throw LogicianError.invalidArguments(
                "need a positive tempo and beats_per_bar for bar math (got \(tempo) BPM, \(beatsPerBar) beats/bar)"
            )
        }
        let meter = (meterMap?.isVariable == true) ? meterMap : nil
        if let map, map.source == .tempoList {
            let integrated = map.rangeSeconds(
                startBar: startBar, endBar: endBar, beatsPerBar: beatsPerBar, meter: meter
            )
            return (integrated.start, integrated.end, tempo, beatsPerBar)
        }
        // A varying meter under an UNREAD tempo map still has to be integrated:
        // the one tempo we have is expressed as a one-event map so the two halves
        // compose through the same code path instead of a second formula here.
        if let meter, let constant = TempoMap.constant(tempo) {
            let integrated = constant.rangeSeconds(
                startBar: startBar, endBar: endBar, beatsPerBar: beatsPerBar, meter: meter
            )
            return (integrated.start, integrated.end, tempo, beatsPerBar)
        }
        let secondsPerBar = beatsPerBar * 60.0 / tempo
        return (
            Double(startBar - 1) * secondsPerBar,
            Double(endBar - 1) * secondsPerBar,
            tempo, beatsPerBar
        )
    }

    // MARK: - Tempo map: acquisition, caching, and what one invocation knows

    /// Where the read tempo map is cached, per project.
    static var tempoMapCacheURL: URL {
        MCUBridge.directory.appendingPathComponent("tempo-map-cache.json")
    }

    /// Forgets the cached tempo map. Called after anything that can rewrite the
    /// map behind our back: a `logic_set_tempo` write (the slider edits whichever
    /// tempo node the playhead sits on), and any recording made while the Smart
    /// Tempo project mode was not verifiably Keep (Adapt REWRITES the map). A
    /// cache that outlives the map it describes is worse than no cache: it is
    /// confidently wrong, which is the one failure mode this server exists to
    /// prevent.
    func invalidateTempoMapCache() {
        try? FileManager.default.removeItem(at: MCPServer.tempoMapCacheURL)
    }

    /// The map a SINGLE-EVENT project has after `logic_set_tempo` moved its one
    /// tempo — or nil when the write's aftermath is not knowable without a
    /// re-read, which is the caller's cue to forget the cache instead.
    ///
    /// Why this is safe for one event and nothing else: the tool refuses on any
    /// map it did not read out of the Tempo List, and refuses again on a map
    /// that is not constant, so the only write that gets through with a map in
    /// hand is one slider move against one event. Its bar, beat and sub-beat
    /// disclosure are unchanged by a BPM write, and `landedBPM` is not the
    /// requested value but the one `setTempo` READ BACK off the slider after
    /// converging. Everything the map has is therefore known, exactly.
    ///
    /// An `isConstant` map with SEVERAL equal-BPM events is deliberately not
    /// patched: which of them Logic's position-dependent slider actually edited
    /// is not knowable from here, and a cache that guesses is worse than none.
    static func tempoMapAfterConstantWrite(
        _ before: TempoMap, landedBPM: Double
    ) -> TempoMap? {
        guard before.source == .tempoList, before.events.count == 1,
              landedBPM > 0, let event = before.events.first else { return nil }
        return TempoMap(
            events: [TempoEvent(
                bar: event.bar, beatInBar: event.beatInBar,
                bpm: landedBPM, rampToNext: event.rampToNext
            )],
            source: .tempoList,
            subBeatPositions: before.subBeatPositions
        )
    }

    /// Puts the tempo cache back in step with a write this server just made,
    /// without paying the Tempo List for the privilege.
    ///
    /// The old shape dropped the cache after every successful `logic_set_tempo`,
    /// which is correct but costs the NEXT reader (a render, a MIDI record, an
    /// automation pass, a `logic_tempo_events {list}`) a full fresh Tempo List
    /// read — measured 765–790 ms against a ~7 ms cache hit. When the post-write
    /// map is fully known (see `tempoMapAfterConstantWrite`) it is written
    /// straight into the cache instead; when it is not, the blind invalidate
    /// stands, unchanged.
    func rememberTempoMap(
        after write: TempoMap, landedBPM: Double, projectPath: String?
    ) -> String {
        // No project path is no scope, and `saveScopedCache` would silently
        // write nothing — leaving the PRE-write file in place, which is the one
        // outcome worse than no cache at all.
        guard let projectPath,
              let patched = MCPServer.tempoMapAfterConstantWrite(write, landedBPM: landedBPM)
        else {
            invalidateTempoMapCache()
            return "invalidated"
        }
        saveScopedCache(patched, to: MCPServer.tempoMapCacheURL, projectPath: projectPath)
        return "patched_in_place"
    }

    /// What serving a cached tempo map is allowed to claim about itself.
    enum CachedTempoMapVerdict: Equatable {
        /// The control bar's live tempo is one the cached map could produce —
        /// the cross-check ran and passed.
        case serveCrossChecked
        /// The control bar could not be read at all (a non-English Logic, a
        /// hidden control bar), so the cross-check NEVER RAN. The cache may
        /// still be served — it is the best answer available — but nothing
        /// this call did verified it against the live project.
        case serveUnverified
        /// The live tempo is one the map cannot account for: the map is stale.
        case discard
    }

    /// Whether a cached tempo map may be served, and what the result may say
    /// about it. Pure, so all three outcomes can be pinned by tests — the
    /// previous inline guard (`live == nil || cached.couldProduceTempo(...)`)
    /// collapsed "the cross-check passed" and "the cross-check could not run"
    /// into one branch, and on a French Logic (R4, measured 2026-08-30) that
    /// served a cache as `verified: true` when nothing had verified anything.
    static func cachedTempoMapVerdict(
        _ cached: TempoMap, liveTempo: Double?
    ) -> CachedTempoMapVerdict {
        guard let liveTempo else { return .serveUnverified }
        return cached.couldProduceTempo(liveTempo) ? .serveCrossChecked : .discard
    }

    /// The project's tempo map, read from the Tempo List and cached per project.
    ///
    /// Only SUCCESS is cached: a read that failed (pane not found, rows
    /// unreadable, a row count that disagreed with the list's own item count)
    /// must be retried next time rather than remembered as "this project has no
    /// map". The cache exists because the read costs ~2 s of UI toggling and one
    /// tool invocation can want the answer more than once.
    /// A cached map is only used when the control bar still agrees with it.
    ///
    /// The cache's real risk is not our own writes (those invalidate it
    /// explicitly) but the USER editing the tempo track in Logic between two
    /// tool calls — a stale map would integrate confidently wrong boundaries,
    /// which is the one failure mode this server exists to prevent. The control
    /// bar publishes the tempo at the playhead for free (no playhead motion, no
    /// pane to open), so every cache hit is checked against it and a tempo the
    /// map cannot account for discards the cache. What that catches and what it
    /// cannot is documented on `TempoMap.couldProduceTempo`.
    ///
    /// `liveCrossChecked` is false in exactly one case: the map came from the
    /// cache AND the control bar could not be read, so the staleness check
    /// never ran. A fresh Tempo List read is its own evidence and reports true.
    ///
    /// `projectPath`, when the caller already has it, saves this reader the
    /// document resolution it would otherwise make for the cache scope —
    /// measured 1.2–6.1 ms, and up to 60 ms on a cold process (2026-09-02).
    /// Nil means "not supplied", so a caller that could not resolve it loses
    /// nothing but the saving.
    func resolveTempoMap(projectPath: String? = nil) -> (
        map: TempoMap?, failure: TempoListFailure?, liveCrossChecked: Bool
    ) {
        let projectPath = projectPath ?? (try? logic.projectDocumentPath())
        if let cached = loadScopedCache(
            MCPServer.tempoMapCacheURL, projectPath: projectPath, as: TempoMap.self
        ) {
            switch MCPServer.cachedTempoMapVerdict(cached, liveTempo: logic.controlBarTempo()) {
            case .serveCrossChecked:
                return (cached, nil, true)
            case .serveUnverified:
                return (cached, nil, false)
            case .discard:
                invalidateTempoMapCache()
            }
        }
        let read = logic.readTempoMap()
        if let map = read.map {
            saveScopedCache(map, to: MCPServer.tempoMapCacheURL, projectPath: projectPath)
        }
        return (read.map, read.failure, true)
    }

    // MARK: - Meter map: acquisition, caching, and the one thing it changes

    /// Where the read meter map is cached, per project.
    static var meterMapCacheURL: URL {
        MCUBridge.directory.appendingPathComponent("meter-map-cache.json")
    }

    /// Forgets the cached meter map. Called for the same reason the tempo cache
    /// is forgotten: a recording made while the Smart Tempo project mode was not
    /// verifiably Keep can rewrite the project's musical grid behind us.
    func invalidateMeterMapCache() {
        try? FileManager.default.removeItem(at: MCPServer.meterMapCacheURL)
    }

    /// The project's meter map, read from the Signature List and cached per
    /// project — the same shape, and the same honesty rules, as
    /// `resolveTempoMap()`.
    ///
    /// Only SUCCESS is cached: "the Signature List could not be read" must never
    /// harden into "this project has one meter". There is no cheap live
    /// cross-check for the cache the way the control bar's tempo validates the
    /// tempo map — the control bar publishes the time signature AT THE PLAYHEAD,
    /// so it can only ever contradict the map, never confirm it; a signature the
    /// map cannot account for at any bar therefore discards the cache, and a
    /// signature it can does not prove the map is current.
    ///
    /// `projectPath` and `liveSignature` are values the CALLER may already
    /// hold: the document path (same saving as the tempo twin's) and the
    /// control bar's time signature, which is one field of a `getTransport()`
    /// walk this reader otherwise pays for twice over in a call that read the
    /// transport anyway — 5.5–9.1 ms warm, 109–132 ms when it is the call's
    /// first AX walk (2026-09-02, `logic_project_snapshot` profile K4). Nil
    /// means "not supplied", never "there is none": the read happens here as it
    /// always did.
    func resolveMeterMap(
        projectPath: String? = nil, liveSignature: String? = nil
    ) -> (
        map: MeterMap?, failure: ListEditorFailure?, servedFromCache: Bool,
        keySignatureRows: Int?
    ) {
        let projectPath = projectPath ?? (try? logic.projectDocumentPath())
        if let cached = loadScopedCache(
            MCPServer.meterMapCacheURL, projectPath: projectPath, as: MeterMap.self
        ) {
            let live = liveSignature ?? (try? logic.getTransport())?["time_signature"] as? String
            let liveSignature = live.flatMap(MeterMap.parseSignature)
            if liveSignature == nil || cached.events.contains(where: {
                $0.numerator == liveSignature?.numerator
                    && $0.denominator == liveSignature?.denominator
            }) {
                // Served, and SAID to be served: this check can only ever
                // contradict the map, so a pass is not a confirmation, and the
                // caller reports the route and the caveat rather than dressing
                // a cached map as a live read (the tempo twin's rule, applied
                // to the cache that needs it more — it has no TTL).
                return (cached, nil, true, nil)
            }
            invalidateMeterMapCache()
        }
        let read = logic.readMeterMap()
        // ONLY a successful read is cached, and that is what keeps a partially
        // drawn Signature List out of the cache: `parseSignatureList` refuses a
        // list holding a row Logic has published and not drawn, so the map that
        // would have been missing a time signature is never written here and
        // never served for the rest of the session (2026-09-02).
        if let map = read.map {
            saveScopedCache(map, to: MCPServer.meterMapCacheURL, projectPath: projectPath)
        }
        return (read.map, read.failure, false, read.map == nil ? nil : read.keySignatureRows)
    }

    /// The meter map, the payload block that reports it, and the warning a
    /// VARYING one obliges a seconds-slicing result to carry.
    ///
    /// A constant map says nothing, exactly as a constant tempo map does: the
    /// boundaries are simply right and there is no caveat to carry. Nor does an
    /// unreadable one warn — that is the assumption this server has always made,
    /// and it is documented in every affected tool's description; the payload
    /// block still names the reason so an agent can see the read was attempted.
    func resolveMeterKnowledge(
        projectPath: String? = nil, liveSignature: String? = nil
    ) -> MeterKnowledge {
        let resolved = resolveMeterMap(projectPath: projectPath, liveSignature: liveSignature)
        return MeterKnowledge(
            map: resolved.map, failure: resolved.failure,
            servedFromCache: resolved.servedFromCache,
            keySignatureRows: resolved.keySignatureRows
        )
    }

    /// What this invocation knows about the tempo across `startBar`–`endBar`:
    /// the map when the Tempo List can be read, the two-point sample when it
    /// cannot. AT MOST ONE of the two is paid for — the sample's playhead travel
    /// (~0.13 s per bar) is skipped entirely once the map is known, which also
    /// means the playhead is not touched at all on a project with a readable map.
    func resolveTempoKnowledge(
        startBar: Int, endBar: Int, beatsPerBar: Double
    ) -> TempoKnowledge {
        let resolved = resolveTempoMap()
        if resolved.map != nil {
            return TempoKnowledge(
                startBar: startBar, endBar: endBar, beatsPerBar: beatsPerBar,
                map: resolved.map, mapFailure: nil, sample: nil
            )
        }
        return TempoKnowledge(
            startBar: startBar, endBar: endBar, beatsPerBar: beatsPerBar,
            map: nil, mapFailure: resolved.failure,
            sample: logic.sampleTempoAcross(startBar: startBar, endBar: endBar)
        )
    }

    /// Where a composed take ends: the last beat any event occupies (counted
    /// from the first beat of `startBar`) and the bar that beat falls in.
    ///
    /// The meter is a PARAMETER here, and that is the entire point. It used to be
    /// the literal 4, three times, inside `logic_record_midi` — while the
    /// verification render right below already used the project's real
    /// beats-per-bar. In 3/4 the two disagreed about where the take ends (a
    /// four-bar take measured as three), and the hardcoded one decided which
    /// range the tempo was read for and how long the recording was expected to
    /// be. Pure and unit-tested for the same reason: it is arithmetic, and
    /// arithmetic should not need Logic running to be trusted.
    static func takeEnd(
        startBar: Int,
        beatsPerBar: Double,
        notes: [(bar: Int, beat: Double, durationBeats: Double)],
        extraEventBars: [Int],
        meterMap: MeterMap? = nil
    ) -> (lastBeat: Double, endBar: Int) {
        let meter = beatsPerBar > 0 ? beatsPerBar : 4
        let map = (meterMap?.isVariable == true) ? meterMap : nil
        /// Beats from `startBar`'s bar line to a position, under the meter map
        /// when there is one to honour and the single multiplication when not.
        func offset(bar: Int, beat: Double) -> Double {
            map?.beatOffset(fromBar: startBar, toBar: bar, beat: beat)
                ?? (Double(bar - startBar) * meter + (beat - 1))
        }
        // A CC or pitch-bend event carries no duration, so it claims the bar it
        // sits in: one full bar past its own start.
        let lastExtraBeats = extraEventBars.map { offset(bar: $0 + 1, beat: 1) }.max() ?? 0
        let lastBeat = max(
            notes.map { offset(bar: $0.bar, beat: $0.beat) + $0.durationBeats }.max()
                ?? (map?.beatsPerBar(atBar: startBar) ?? meter),
            lastExtraBeats
        )
        // At least one bar: a take shorter than a bar still occupies one, and
        // the bar math downstream requires end > start.
        guard let map else {
            return (lastBeat, max(startBar + Int((lastBeat / meter).rounded(.up)), startBar + 1))
        }
        // Under a changing meter "how many bars is this many beats" is a walk,
        // not a division: the same beat count is a different number of bars
        // depending on which bars it lands in.
        let end = map.position(atBeatOffset: map.beatOffset(bar: startBar) + lastBeat)
        let endBar = end.beatInBar > 1 + 1e-9 ? end.bar + 1 : end.bar
        return (lastBeat, max(endBar, startBar + 1))
    }

}
// The "resolve tempo and meter, then convert" convenience that used to live
// here is gone: every caller now resolves the tempo and meter ITSELF, because
// it needs them for `resolveTempoKnowledge` in the same breath, and calling
// the convenience afterwards read the control bar a second time.
