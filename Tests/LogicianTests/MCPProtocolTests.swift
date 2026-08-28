import Foundation
import XCTest
@testable import Logician

/// The JSON-RPC/MCP envelope, which is pure and therefore testable without
/// Logic Pro: what gets a response and what must not, what an unknown tool
/// name is, how a batch is answered, and what a tool result carries. Every
/// case here has cost a real client session - a strict client closes the
/// connection over an answered notification, and a doubled payload is paid
/// for in tokens on every single call.
///
/// Nothing in this file may dispatch a real tool: `tools/call` cases use a
/// name that does not exist, so no handler ever reaches Logic.
final class MCPProtocolTests: XCTestCase {

    private let server = MCPServer()

    private func request(_ method: String, id: Any? = nil, params: [String: Any]? = nil) -> [String: Any] {
        var request: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { request["id"] = id }
        if let params { request["params"] = params }
        return request
    }

    // MARK: - Notifications get no response, whatever the method

    func testNoMethodAnswersARequestSentWithoutAnId() throws {
        // The guard used to live in `default:` only, so everything with a
        // matching case answered a notification with `"id": null`.
        for method in ["initialize", "ping", "tools/list", "tools/call",
                       "notifications/initialized", "initialized",
                       "notifications/cancelled", "resources/list", ""] {
            let response = try server.handle(request(method))
            XCTAssertNil(response, "\(method) answered a notification")
        }
    }

    func testATooCallNotificationIsDroppedBeforeTheUnknownToolError() throws {
        // Same request that WITH an id is a -32602: proof the notification
        // guard runs first, and that nothing is dispatched.
        let response = try server.handle(
            request("tools/call", params: ["name": "logic_does_not_exist", "arguments": [:]])
        )
        XCTAssertNil(response)
    }

    func testAnIdOfZeroIsAnIdAndIsAnswered() throws {
        // `0` is falsy in several client languages; it is still a request.
        let zero = try XCTUnwrap(server.handle(request("ping", id: 0)))
        XCTAssertEqual(zero["id"] as? Int, 0)
        XCTAssertNotNil(zero["result"])
    }

    func testRequestsWithAnIdStillGetTheirResponse() throws {
        for method in ["initialize", "ping", "tools/list"] {
            let response = try XCTUnwrap(server.handle(request(method, id: 7)))
            XCTAssertEqual(response["id"] as? Int, 7, "\(method)")
            XCTAssertNotNil(response["result"], "\(method)")
            XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
        }
    }

    func testAnUnknownMethodWithAnIdIsMethodNotFound() throws {
        let response = try XCTUnwrap(server.handle(request("resources/list", id: 3)))
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    // MARK: - Version negotiation (unchanged, guarded)

    func testInitializeEchoesAKnownProtocolVersionAndFallsBackOtherwise() throws {
        for version in ["2024-11-05", "2025-03-26", "2025-06-18"] {
            let response = try XCTUnwrap(server.handle(
                request("initialize", id: 1, params: ["protocolVersion": version])
            ))
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["protocolVersion"] as? String, version)
        }
        let unknown = try XCTUnwrap(server.handle(
            request("initialize", id: 1, params: ["protocolVersion": "1999-01-01"])
        ))
        XCTAssertEqual(
            (unknown["result"] as? [String: Any])?["protocolVersion"] as? String, protocolVersion
        )
    }

    // MARK: - An unknown tool NAME is a protocol error, not a failed tool

    func testUnknownToolIsInvalidParamsAndNotAnIsErrorResult() throws {
        let response = try XCTUnwrap(server.handle(
            request("tools/call", id: 9, params: ["name": "logic_nope", "arguments": [:]])
        ))
        XCTAssertNil(response["result"], "an unknown name must not look like a successful call")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertTrue(message.contains("logic_nope"))
        // Still helpful: the usual cause is a stale tool list.
        XCTAssertTrue(message.contains("logic_health"))
        XCTAssertTrue(message.contains("logic_bounce_range"))
    }

    func testAMissingToolNameIsAlsoInvalidParams() throws {
        let response = try XCTUnwrap(server.handle(request("tools/call", id: 9, params: [:])))
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testUnknownToolMessageIsNilForEveryAdvertisedTool() {
        for tool in server.toolRegistry() {
            XCTAssertNil(server.unknownToolMessage(name: tool.name), tool.name)
        }
    }

    // MARK: - Batches

    func testABatchAnswersOnlyTheMembersThatCarryAnId() throws {
        let responses = try XCTUnwrap(server.handleBatch([
            request("ping", id: 1),
            request("notifications/initialized"),
            request("tools/list", id: "two")
        ]))
        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(responses[0]["id"] as? Int, 1)
        XCTAssertEqual(responses[1]["id"] as? String, "two")
    }

    func testABatchOfNotificationsProducesNoOutputAtAll() {
        XCTAssertNil(server.handleBatch([
            request("notifications/initialized"),
            request("notifications/cancelled"),
            request("ping")
        ]))
    }

    func testAnEmptyBatchIsOneInvalidRequest() throws {
        let responses = try XCTUnwrap(server.handleBatch([]))
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual((responses[0]["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertTrue(responses[0]["id"] is NSNull)
    }

    func testANonObjectMemberIsRejectedWithoutLosingTheRestOfTheBatch() throws {
        let responses = try XCTUnwrap(server.handleBatch(["not a request", 42, request("ping", id: 5)]))
        XCTAssertEqual(responses.count, 3)
        XCTAssertEqual((responses[0]["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertEqual((responses[1]["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertEqual(responses[2]["id"] as? Int, 5)
        XCTAssertNotNil(responses[2]["result"])
    }

    func testABatchErrorAndAToolErrorKeepTheirOwnShapes() throws {
        let responses = try XCTUnwrap(server.handleBatch([
            request("tools/call", id: 1, params: ["name": "logic_nope", "arguments": [:]]),
            request("frobnicate", id: 2)
        ]))
        XCTAssertEqual((responses[0]["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual((responses[1]["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testABatchIsSerializableAsOneJSONArray() throws {
        let responses = try XCTUnwrap(server.handleBatch([request("ping", id: 1)]))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(responses))
    }

    // MARK: - Tool result shape

    private func textBlock(of result: [String: Any]) throws -> String {
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first)
        XCTAssertEqual(text["type"] as? String, "text")
        return try XCTUnwrap(text["text"] as? String)
    }

    func testAResultCarriesTheJSONOnceAndNeverAsStructuredContent() throws {
        let result = server.toolResult(payload: ["success": true, "track": "Bass"], isError: false)
        XCTAssertNil(
            result["structuredContent"],
            "the payload must not be transmitted twice; no tool declares an outputSchema"
        )
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertTrue(try textBlock(of: result).contains("\"track\":\"Bass\""))
    }

    func testNoToolDeclaresAnOutputSchemaThatWouldPromiseStructuredContent() {
        for definition in server.toolDefinitions() {
            XCTAssertNil(definition["outputSchema"], definition["name"] as? String ?? "?")
        }
    }

    func testAudioIsAttachedAsABlockAndStrippedFromTheText() throws {
        let result = server.toolResult(
            payload: [
                "success": true,
                "listen_note": "This result CARRIES the rendered audio",
                "_audio": ["data": "QUJD", "mimeType": "audio/mp4"]
            ],
            isError: false
        )
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[1]["type"] as? String, "audio")
        XCTAssertEqual(content[1]["data"] as? String, "QUJD")
        XCTAssertFalse(try textBlock(of: result).contains("QUJD"), "base64 must not also be text")
    }

    func testOrderedAudioListBecomesOrderedBlocks() throws {
        let result = server.toolResult(
            payload: ["_audio_list": [
                ["data": "QQ==", "mimeType": "audio/mp4"],
                ["data": "Qg==", "mimeType": "audio/mp4"]
            ]],
            isError: false
        )
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 3)
        XCTAssertEqual(content[1]["data"] as? String, "QQ==")
        XCTAssertEqual(content[2]["data"] as? String, "Qg==")
    }

    // MARK: - include_audio

    func testIncludeAudioFalseDropsTheBlocksAndCorrectsThePromise() throws {
        let result = server.toolResult(
            payload: [
                "success": true,
                "preview_path": "/tmp/x.m4a",
                "listen_note": "This result CARRIES the rendered audio as an MCP audio block",
                "_audio": ["data": "QUJD", "mimeType": "audio/mp4"]
            ],
            isError: false,
            includeAudio: false
        )
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1, "no audio block may be attached")
        let text = try textBlock(of: result)
        XCTAssertFalse(text.contains("QUJD"))
        XCTAssertFalse(text.contains("CARRIES"), "the result must not claim audio it did not send")
        XCTAssertTrue(text.contains("OMITTED"))
        // (JSONSerialization escapes the slashes, so match the leaf.)
        XCTAssertTrue(text.contains("x.m4a"), "the paths are the whole point of the opt-out")
    }

    func testIncludeAudioFalseCorrectsAPlainNoteWhenThereIsNoListenNote() throws {
        let result = server.toolResult(
            payload: [
                "success": true,
                "note": "An MCP AUDIO content block accompanies this text",
                "_audio": ["data": "QUJD", "mimeType": "audio/mp4"]
            ],
            isError: false,
            includeAudio: false
        )
        XCTAssertTrue(try textBlock(of: result).contains("OMITTED"))
    }

    func testIncludeAudioFalseChangesNothingForAResultWithoutAudio() throws {
        let payload: [String: Any] = ["success": true, "note": "nothing to hear here"]
        let with = try textBlock(of: server.toolResult(payload: payload, isError: false))
        let without = try textBlock(
            of: server.toolResult(payload: payload, isError: false, includeAudio: false)
        )
        XCTAssertEqual(with, without)
    }

    func testEveryToolThatCanAttachAudioDeclaresTheOptOut() throws {
        let audioTools = ["logic_bounce_range", "logic_render_track",
                          "logic_evaluate_change", "logic_get_audio_clip"]
        for name in audioTools {
            let tool = try XCTUnwrap(server.toolRegistry().first { $0.name == name })
            let properties = try XCTUnwrap(tool.inputSchema["properties"] as? [String: Any])
            let property = try XCTUnwrap(properties["include_audio"] as? [String: Any], name)
            XCTAssertEqual(property["type"] as? String, "boolean", name)
            // Never required, and never in a way that changes the default.
            XCTAssertFalse((tool.inputSchema["required"] as? [String] ?? []).contains("include_audio"), name)
        }
        // And nowhere else: an opt-out on a tool that has no audio to omit
        // would only mislead.
        for tool in server.toolRegistry() where !audioTools.contains(tool.name) {
            let properties = tool.inputSchema["properties"] as? [String: Any] ?? [:]
            XCTAssertNil(properties["include_audio"], tool.name)
        }
    }

    // MARK: - The advertised list

    func testToolsListIsWellFormedAndComplete() throws {
        let response = try XCTUnwrap(server.handle(request("tools/list", id: 1)))
        let tools = try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 69)
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names).count, tools.count, "duplicate tool name")
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("logic_") })
        for tool in tools {
            XCTAssertNotNil(tool["description"] as? String)
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object")
            XCTAssertNotNil(tool["annotations"] as? [String: Any])
        }
        XCTAssertTrue(JSONSerialization.isValidJSONObject(response))
    }
}
