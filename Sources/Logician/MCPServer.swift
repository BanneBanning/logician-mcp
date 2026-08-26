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
            do {
                guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    throw DemoError.invalidArguments("request must be a JSON object")
                }
                if let response = try handle(request) {
                    write(response)
                }
            } catch {
                write(jsonRPCError(id: NSNull(), code: -32700, message: error.localizedDescription))
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
        let isNotification = request["id"] == nil

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
            return response(id: id, result: callTool(name: toolName, arguments: arguments))

        default:
            if isNotification || method.hasPrefix("notifications/") { return nil }
            return jsonRPCError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    func toolResult(payload: Any, isError: Bool) -> [String: Any] {
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
        var result: [String: Any] = [
            "content": content,
            "isError": isError
        ]
        if let structured = textPayload as? [String: Any] {
            result["structuredContent"] = structured
        }
        return result
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

    func write(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
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
