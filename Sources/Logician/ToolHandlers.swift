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
            "\(tool.name) does not accept: \(unknown.joined(separator: ", ")). "
                + "Accepted: \(properties.keys.sorted().joined(separator: ", ")). "
                + "The argument was NOT applied - do not assume it took effect."
        )
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
        // A tool that EXISTS but is not offered is a configuration answer, not
        // a spelling one. Saying "unknown tool" and stopping would send an
        // agent hunting for a name it already had right.
        if let sets = Toolset.membership[name], toolRegistry().contains(where: { $0.name == name }) {
            message += " That tool exists but is not in this session's active toolsets"
                + " (\(MCPServer.activeToolsets.map(\.rawValue).sorted().joined(separator: ", ")))."
                + " It is in \(sets.map(\.rawValue).sorted().joined(separator: ", ")):"
                + " relaunch the server with \(MCPServer.toolsetsFlag)=<comma list>"
                + " (or the \(MCPServer.toolsetsEnvironmentVariable) environment variable,"
                + " or \(MCPServer.toolsetsFlag)=\(Toolset.everything)) to offer it."
        }
        return message + " Available tools: " + offered.sorted().joined(separator: ", ")
    }

    func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
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
            let payload = try tool.handler(self)(arguments)
            // Every write that changes how the song SOUNDS carries a standing
            // instruction to judge it by ear. Parameter and fader numbers say
            // nothing about how loud or good something IS (recordings differ,
            // plugins differ) - only listening does. This lives in the result
            // so every future agent gets it at exactly the right moment.
            // Which tools get it is declared per tool in ToolRegistry.swift,
            // so a new sound-changing tool cannot quietly miss out.
            if let note = tool.listenNoteText,
               var successPayload = payload as? [String: Any],
               successPayload["success"] as? Bool == true,
               successPayload["listen_note"] == nil {
                successPayload["listen_note"] = note
                return toolResult(payload: successPayload, isError: false, includeAudio: includeAudio)
            }
            return toolResult(payload: payload, isError: false, includeAudio: includeAudio)
        } catch {
            return toolResult(
                payload: [
                    "success": false,
                    "verified": false,
                    "state": "failed",
                    "error_code": (error as? LogicianError)?.code ?? "failed",
                    "error": error.localizedDescription
                ],
                isError: true
            )
        }
    }

    func requiredString(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else {
            throw LogicianError.invalidArguments("missing non-empty string: \(key)")
        }
        return value
    }

    /// A JSON number argument, whichever way the client typed it. `-12` and
    /// `-12.0` are the same dB value and a schema that says `"type": "number"`
    /// accepts both, so a handler that only reads `as? Double` silently ignores
    /// the integer form.
    func doubleArgument(_ key: String, in arguments: [String: Any]) -> Double? {
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
    func resolveTempoMap() -> (map: TempoMap?, failure: TempoListFailure?) {
        let projectPath = try? logic.projectDocumentPath()
        if let cached = loadScopedCache(
            MCPServer.tempoMapCacheURL, projectPath: projectPath, as: TempoMap.self
        ) {
            let live = logic.controlBarTempo()
            if live == nil || cached.couldProduceTempo(live ?? 0) {
                return (cached, nil)
            }
            invalidateTempoMapCache()
        }
        let read = logic.readTempoMap()
        if let map = read.map {
            saveScopedCache(map, to: MCPServer.tempoMapCacheURL, projectPath: projectPath)
        }
        return (read.map, read.failure)
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
    func resolveMeterMap() -> (map: MeterMap?, failure: ListEditorFailure?) {
        let projectPath = try? logic.projectDocumentPath()
        if let cached = loadScopedCache(
            MCPServer.meterMapCacheURL, projectPath: projectPath, as: MeterMap.self
        ) {
            let live = (try? logic.getTransport())?["time_signature"] as? String
            let liveSignature = live.flatMap(MeterMap.parseSignature)
            if liveSignature == nil || cached.events.contains(where: {
                $0.numerator == liveSignature?.numerator
                    && $0.denominator == liveSignature?.denominator
            }) {
                return (cached, nil)
            }
            invalidateMeterMapCache()
        }
        let read = logic.readMeterMap()
        if let map = read.map {
            saveScopedCache(map, to: MCPServer.meterMapCacheURL, projectPath: projectPath)
        }
        return (read.map, read.failure)
    }

    /// The meter map, the payload block that reports it, and the warning a
    /// VARYING one obliges a seconds-slicing result to carry.
    ///
    /// A constant map says nothing, exactly as a constant tempo map does: the
    /// boundaries are simply right and there is no caveat to carry. Nor does an
    /// unreadable one warn — that is the assumption this server has always made,
    /// and it is documented in every affected tool's description; the payload
    /// block still names the reason so an agent can see the read was attempted.
    func resolveMeterKnowledge() -> MeterKnowledge {
        let resolved = resolveMeterMap()
        return MeterKnowledge(map: resolved.map, failure: resolved.failure)
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
