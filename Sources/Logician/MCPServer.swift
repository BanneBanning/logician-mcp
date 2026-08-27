import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

final class MCPServer {
    let logic = LogicAccessibility()

    func run() {
        log("starting \(serverName) \(serverVersion)")
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let message: Any
            do {
                message = try JSONSerialization.jsonObject(with: Data(line.utf8))
            } catch {
                write(jsonRPCError(id: NSNull(), code: -32700, message: error.localizedDescription))
                continue
            }
            do {
                if let request = message as? [String: Any] {
                    if let response = try handle(request) {
                        write(response)
                    }
                } else if let batch = message as? [Any] {
                    // A JSON-RPC batch. Legal in the versions this server
                    // negotiates down to (2024-11-05 and 2025-03-26 inherit
                    // batching from JSON-RPC 2.0; only 2025-06-18 removes
                    // it), and it used to fail the object cast and come back
                    // as a parse error with a null id.
                    if let responses = handleBatch(batch) {
                        writeJSON(responses)
                    }
                } else {
                    write(jsonRPCError(
                        id: NSNull(), code: -32600,
                        message: "Invalid Request: a JSON-RPC message must be an object, or an array of them"
                    ))
                }
            } catch {
                write(jsonRPCError(id: NSNull(), code: -32603, message: error.localizedDescription))
            }
        }
        // stdin closed: the client is gone. Leave the control surface in the
        // neutral Pan view — a leaked hot plugin/instrument view otherwise
        // makes Logic auto-open plugin windows on every later track selection.
        MCUController.exitToPan()
        log("stdin closed; surface returned to Pan view")
    }

    func handle(_ request: [String: Any]) throws -> [String: Any]? {
        let method = request["method"] as? String ?? ""
        let id = request["id"] ?? NSNull()
        // A notification (no id) must NEVER get a response - answering one,
        // even with an error, is invalid JSON-RPC and strict clients
        // (Antigravity's Go MCP layer) close the connection over it.
        //
        // Checked BEFORE the switch, not inside `default:` where it used to
        // live: an id-less `tools/call`, `tools/list` or `ping` matched a
        // case, never reached the guard, and was answered with `"id": null` -
        // exactly the reply the guard exists to prevent.
        //
        // A REQUEST method arriving without an id is a client bug, and it is
        // deliberately NOT dispatched: performing a Logic write whose result
        // could never be reported back is worse than dropping the message.
        // The drop is logged so it is diagnosable rather than silent.
        if request["id"] == nil {
            if !method.hasPrefix("notifications/") && method != "initialized" {
                log("dropped '\(method)' sent without an id: a notification gets no response, so its result could never reach the caller")
            }
            return nil
        }

        switch method {
        case "initialize":
            // Echo the client's protocol version when we know it - strict
            // clients disconnect on a version they did not offer.
            let requested = (request["params"] as? [String: Any])?["protocolVersion"] as? String
            let known = ["2024-11-05", "2025-03-26", protocolVersion]
            let negotiated = (requested.flatMap { known.contains($0) ? $0 : nil }) ?? protocolVersion
            return response(id: id, result: [
                "protocolVersion": negotiated,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": serverName, "version": serverVersion],
                "instructions": "Controls Logic Pro on this Mac through its control-surface protocol (no UI clicking). Requires: Logic running with a project open, Accessibility granted, and a Mackie Control configured with ports 'Logic MCP MCU' (one-time). Full agent guide with workflows and the complete tool reference: docs/AGENT-GUIDE.md in the Logician repository. Run logic_health FIRST — it starts the bridge daemon, verifies every setup step, and tells you the fix for anything missing. Run logic_setup_key_commands ONCE during onboarding — it opens Logic's Key Commands window briefly and binds all needed commands; skipping it means the same window flashes unannounced the first time a tool needs a missing command (lazy learning). Writes are compare-and-set with readback: pass expected_current_value and read values before changing them. English Logic UI assumed (v1). LISTENING PROTOCOL: to hear audio, open the preview_path/clip_path files with your client's FILE VIEWER (real multimodal audio in most clients), or logic_get_audio_clip when your client forwards MCP audio blocks - if its result reaches you without an audio block, your client drops them: use the file viewer, and never claim to have heard something you did not receive. NEVER read audio files as text/bash. HONESTY: results carry metrics and warnings (silent file, soloed tracks) - trust them over expectations, act on warnings before proceeding, and report blocked steps instead of improvising. MIX BY EAR: fader and parameter VALUES are not loudness or quality - recordings and plugins differ, so a lower fader can still be the louder track. Diagnose by listening BEFORE changing, judge by listening AFTER changing; use numbers only to verify what your ears found."
            ])

        case "notifications/initialized", "initialized":
            return nil

        case "ping":
            return response(id: id, result: [:])

        case "tools/list":
            return response(id: id, result: ["tools": toolDefinitions()])

        case "tools/call":
            let params = request["params"] as? [String: Any] ?? [:]
            let toolName = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            // An unknown NAME is an invalid `params.name`, not a tool that ran
            // and failed. MCP reserves `isError` for EXECUTION failures, so
            // returning one told a strict client "the call succeeded, the tool
            // reported a problem" - the wrong half of the protocol.
            if let unknown = unknownToolMessage(name: toolName) {
                return jsonRPCError(id: id, code: -32602, message: unknown)
            }
            return response(id: id, result: callTool(name: toolName, arguments: arguments))

        default:
            // Real notifications already returned above. An unknown
            // `notifications/*` that carries an id anyway is still a
            // notification by name, and gets no "method not found" either.
            if method.hasPrefix("notifications/") { return nil }
            return jsonRPCError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// The `CallToolResult` wire shape.
    ///
    /// `includeAudio: false` is the `include_audio` opt-out: the audio keys
    /// are still stripped from the text payload (they are transport, never
    /// content), but no audio block is attached and the note that promised
    /// one is rewritten - a result that says "this CARRIES the audio" while
    /// carrying nothing is exactly the dishonesty this server refuses.
    func toolResult(payload: Any, isError: Bool, includeAudio: Bool = true) -> [String: Any] {
        // A payload carrying "_audio" {data, mimeType} becomes an MCP audio
        // content block so multimodal clients can LISTEN instead of being
        // tempted to read raw audio files into their context.
        var textPayload = payload
        var audioBlocks: [[String: Any]] = []
        if var object = payload as? [String: Any] {
            if let audio = object["_audio"] as? [String: String],
               let data = audio["data"], let mime = audio["mimeType"] {
                audioBlocks.append(["type": "audio", "data": data, "mimeType": mime])
                object.removeValue(forKey: "_audio")
            }
            if let list = object["_audio_list"] as? [[String: String]] {
                for audio in list {
                    guard let data = audio["data"], let mime = audio["mimeType"] else { continue }
                    audioBlocks.append(["type": "audio", "data": data, "mimeType": mime])
                }
                object.removeValue(forKey: "_audio_list")
            }
            if !includeAudio && !audioBlocks.isEmpty {
                audioBlocks = []
                // Correct the standing promise in place. No key is added or
                // removed - only the value of the note that would otherwise
                // tell the agent to listen to blocks that are not there.
                let omitted = "Audio blocks were OMITTED because you passed include_audio: false. Nothing was heard. To listen, open the audio paths in this result (preview_path / clip_path / baseline_audio / after_audio) with your client's file viewer, or call again with include_audio: true. NEVER read audio files as text/bash."
                if object["listen_note"] != nil {
                    object["listen_note"] = omitted
                } else if object["note"] != nil {
                    object["note"] = omitted
                }
            }
            textPayload = object
        }
        let text: String
        if JSONSerialization.isValidJSONObject(textPayload),
           let data = try? JSONSerialization.data(withJSONObject: textPayload, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            text = json
        } else {
            text = String(describing: textPayload)
        }

        var content: [[String: Any]] = [["type": "text", "text": text]]
        content.append(contentsOf: audioBlocks)
        // NO `structuredContent`. It used to carry a second copy of the same
        // dictionary the text block already holds, which doubled the tokens of
        // every call in any client that renders both - and it was unvalidated:
        // the spec pairs structured content with an `outputSchema`, and these
        // 57 results are heterogeneous, branch-dependent dictionaries (an
        // optional `warning`, an optional `slice`, `metrics` only when the
        // file could be measured, a completely different error shape) that no
        // honest schema describes. A permissive `{"type": "object"}` would
        // validate nothing while keeping the duplicate; a specific one would
        // eventually reject a truthful result, which is the worst outcome this
        // server can produce. The serialized-JSON text block is what the spec
        // prescribes without an output schema, and it is also the ONLY form
        // the 2024-11-05 and 2025-03-26 clients this server negotiates down to
        // understand - structured content did not exist before 2025-06-18.
        return [
            "content": content,
            "isError": isError
        ]
    }

    func response(id: Any, result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    func jsonRPCError(id: Any, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message]
        ]
    }

    /// One JSON-RPC batch: every member is processed in order, and only the
    /// members that carry an id produce a response. nil means "write NOTHING"
    /// - the required answer when every member was a notification, and the
    /// same rule that keeps a strict client from closing the connection over
    /// a reply it never asked for.
    func handleBatch(_ members: [Any]) -> [[String: Any]]? {
        guard !members.isEmpty else {
            return [jsonRPCError(
                id: NSNull(), code: -32600, message: "Invalid Request: the batch is empty"
            )]
        }
        var responses: [[String: Any]] = []
        for member in members {
            guard let request = member as? [String: Any] else {
                responses.append(jsonRPCError(
                    id: NSNull(), code: -32600,
                    message: "Invalid Request: every member of a batch must be a JSON object"
                ))
                continue
            }
            do {
                if let response = try handle(request) {
                    responses.append(response)
                }
            } catch {
                // One bad member must not lose the rest of the batch.
                responses.append(jsonRPCError(
                    id: request["id"] ?? NSNull(), code: -32603,
                    message: error.localizedDescription
                ))
            }
        }
        return responses.isEmpty ? nil : responses
    }

    func write(_ object: [String: Any]) {
        writeJSON(object)
    }

    /// Writes one newline-delimited JSON message: an object for a single
    /// response, an array for a batch.
    func writeJSON(_ message: Any) {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else {
            log("failed to serialize response")
            return
        }
        line.append("\n")
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    func log(_ message: String) {
        let line = "[\(serverName)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
