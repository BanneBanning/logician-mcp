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
        let names = toolRegistry().map(\.name)
        guard !names.contains(name) else { return nil }
        return "Unknown tool: '\(name)'. Nothing was executed. Available tools: "
            + names.sorted().joined(separator: ", ")
    }

    func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            guard let tool = toolRegistry().first(where: { $0.name == name }) else {
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

    /// Bar positions → seconds from project start (freeze renders begin at
    /// bar 1). Tempo and meter come from the control bar unless overridden;
    /// constant tempo is assumed (tempo-track changes are not followed).
    func barRangeSeconds(
        logic: LogicAccessibility, startBar: Int, endBar: Int, arguments: [String: Any]
    ) throws -> (start: Double, end: Double, tempo: Double, beatsPerBar: Double) {
        guard startBar >= 1, endBar > startBar else {
            throw LogicianError.invalidArguments("need start_bar >= 1 and end_bar > start_bar")
        }
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
        let secondsPerBar = beatsPerBar * 60.0 / tempo
        return (
            Double(startBar - 1) * secondsPerBar,
            Double(endBar - 1) * secondsPerBar,
            tempo, beatsPerBar
        )
    }
}
