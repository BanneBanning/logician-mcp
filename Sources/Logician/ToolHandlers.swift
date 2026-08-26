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
        throw DemoError.invalidArguments(
            "\(tool.name) does not accept: \(unknown.joined(separator: ", ")). "
                + "Accepted: \(properties.keys.sorted().joined(separator: ", ")). "
                + "The argument was NOT applied - do not assume it took effect."
        )
    }

    func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            guard let tool = toolRegistry().first(where: { $0.name == name }) else {
                throw DemoError.invalidArguments("unknown tool: \(name)")
            }
            try rejectUnknownArguments(tool: tool, arguments: arguments)
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
                return toolResult(payload: successPayload, isError: false)
            }
            return toolResult(payload: payload, isError: false)
        } catch {
            return toolResult(
                payload: [
                    "success": false,
                    "verified": false,
                    "state": "failed",
                    "error_code": (error as? DemoError)?.code ?? "failed",
                    "error": error.localizedDescription
                ],
                isError: true
            )
        }
    }

    func requiredString(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else {
            throw DemoError.invalidArguments("missing non-empty string: \(key)")
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
            throw DemoError.invalidArguments("need start_bar >= 1 and end_bar > start_bar")
        }
        var tempo = (arguments["tempo"] as? Double)
            ?? (arguments["tempo"] as? Int).map(Double.init) ?? 0
        var beatsPerBar = (arguments["beats_per_bar"] as? Double)
            ?? (arguments["beats_per_bar"] as? Int).map(Double.init) ?? 0
        if tempo <= 0 || beatsPerBar <= 0 {
            let transport = try logic.getTransport()
            if tempo <= 0 {
                guard let read = transport["tempo"] as? Double else {
                    throw DemoError.trackNotExposed(
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
