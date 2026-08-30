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

    /// A batch whose answer is the usual ARRAY of responses. `handleBatch`
    /// returns `Any?` because exactly one case answers with a bare object (the
    /// empty batch); every other test wants the array.
    private func batch(_ members: [Any]) throws -> [[String: Any]]? {
        guard let output = server.handleBatch(members) else { return nil }
        return try XCTUnwrap(output as? [[String: Any]], "expected an array of responses")
    }

    /// A modern (2026-07-28) request: version and capabilities in `_meta`,
    /// no handshake anywhere.
    private func modern(
        _ method: String, id: Any = 1, version: String = "2026-07-28",
        capabilities: [String: Any]? = [:], extra: [String: Any] = [:]
    ) -> [String: Any] {
        var meta: [String: Any] = ["io.modelcontextprotocol/protocolVersion": version]
        if let capabilities { meta["io.modelcontextprotocol/clientCapabilities"] = capabilities }
        var params = extra
        params["_meta"] = meta
        return request(method, id: id, params: params)
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
        // (It used to be `resources/list` that stood in for "a method this
        // server does not have". That one is implemented now, so the example
        // has to be a method MCP itself does not define.)
        let response = try XCTUnwrap(server.handle(request("resources/frobnicate", id: 3)))
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    /// `resources/subscribe` is deliberately absent: the capability declares
    /// neither `subscribe` nor `listChanged`, and answering a subscription this
    /// server will never honour would be a promise, not a courtesy.
    func testSubscribeIsNotOfferedBecauseTheCapabilityDoesNotClaimIt() throws {
        let response = try XCTUnwrap(server.handle(
            request("resources/subscribe", id: 4, params: ["uri": guideResourceURI])
        ))
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    // MARK: - The supported range

    /// `2024-11-05` is gone on purpose, and it must stay gone. Every result
    /// this server can produce may contain an `audio` content block, and every
    /// tool it advertises carries `annotations`; neither existed before
    /// `2025-03-26`, so answering "yes, 2024-11-05" was a promise the server
    /// broke with its very next message.
    func testTheSupportedRangeExcludes20241105AndFloorsAt20250326() {
        XCTAssertFalse(supportedProtocolVersions.contains("2024-11-05"))
        XCTAssertEqual(legacyProtocolVersions.last, "2025-03-26")
        XCTAssertEqual(modernProtocolVersions, ["2026-07-28"])
        // Newest first: the order is what `server/discover` advertises and what
        // an UnsupportedProtocolVersionError offers back.
        XCTAssertEqual(supportedProtocolVersions.first, "2026-07-28")
    }

    func testInitializeEchoesAKnownProtocolVersionAndFallsBackOtherwise() throws {
        for version in ["2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"] {
            let response = try XCTUnwrap(MCPServer().handle(
                request("initialize", id: 1, params: ["protocolVersion": version])
            ))
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["protocolVersion"] as? String, version)
        }
        for refused in ["2024-11-05", "1999-01-01"] {
            let response = try XCTUnwrap(MCPServer().handle(
                request("initialize", id: 1, params: ["protocolVersion": refused])
            ))
            XCTAssertEqual(
                (response["result"] as? [String: Any])?["protocolVersion"] as? String,
                protocolVersion,
                "\(refused) must fall back, never be echoed"
            )
        }
    }

    /// The negotiated revision used to be a local that the response echoed and
    /// then threw away, so the server could not tell afterwards what it had
    /// promised. Nothing could vary by era while that was true.
    func testInitializeSTORESTheNegotiatedVersion() throws {
        let server = MCPServer()
        XCTAssertNil(server.negotiatedLegacyVersion)
        _ = try server.handle(request("initialize", id: 1, params: ["protocolVersion": "2025-03-26"]))
        XCTAssertEqual(server.negotiatedLegacyVersion, "2025-03-26")
    }

    /// A second `initialize` is a client bug, not a hang-up offence: it is
    /// answered again and simply re-negotiates.
    func testASecondInitializeIsAnsweredAndRenegotiates() throws {
        let server = MCPServer()
        _ = try server.handle(request("initialize", id: 1, params: ["protocolVersion": "2025-03-26"]))
        let second = try XCTUnwrap(server.handle(
            request("initialize", id: 2, params: ["protocolVersion": "2025-06-18"])
        ))
        XCTAssertEqual(
            (second["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18"
        )
        XCTAssertEqual(server.negotiatedLegacyVersion, "2025-06-18")
    }

    /// Real clients skip the handshake, and so does every piped smoke test in
    /// this repo. The 2026-07-28 spec expects exactly this leniency of legacy
    /// servers and tells clients to probe with `server/discover` when they want
    /// a deterministic answer instead.
    func testToolsAreServedBeforeInitialize() throws {
        let server = MCPServer()
        XCTAssertNotNil(try server.handle(request("tools/list", id: 1))?["result"])
        // A tools/call still reaches its -32602 for the unknown NAME, which
        // proves it was dispatched rather than refused for being early.
        let call = try XCTUnwrap(server.handle(
            request("tools/call", id: 2, params: ["name": "logic_nope", "arguments": [:]])
        ))
        XCTAssertEqual((call["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    // MARK: - JSON-RPC strictness

    private func errorCode(_ response: [String: Any]?) throws -> Int {
        let response = try XCTUnwrap(response)
        XCTAssertNil(response["result"], "a rejected request must not also carry a result")
        return try XCTUnwrap((response["error"] as? [String: Any])?["code"] as? Int)
    }

    /// `{"id": null}` used to be ANSWERED. A JSON null decodes to `NSNull`,
    /// which is not Swift `nil`, so the notification guard's `== nil` was false
    /// and the request sailed through - and was replied to with `"id": null`,
    /// the exact message the guard exists to prevent.
    func testANullIdIsInvalidRequestAndNotANotification() throws {
        for method in ["ping", "tools/list", "initialize", "tools/call"] {
            var message = request(method, params: ["name": "logic_nope"])
            message["id"] = NSNull()
            let response = try XCTUnwrap(server.handle(message), "\(method) with a null id")
            XCTAssertEqual(try errorCode(response), -32600, method)
            // No id could be read, so JSON-RPC's own null goes back.
            XCTAssertTrue(response["id"] is NSNull, method)
            let text = try XCTUnwrap((response["error"] as? [String: Any])?["message"] as? String)
            XCTAssertTrue(text.contains("must not be null"), text)
        }
    }

    /// A fractional id cannot survive the round trip: it comes back through a
    /// binary double as a different number and the client can never match it to
    /// its request. Rejecting is the only honest answer.
    func testAFractionalIdIsRejectedRatherThanEchoedThroughADouble() throws {
        var message = request("ping")
        message["id"] = 3.7
        XCTAssertEqual(try errorCode(server.handle(message)), -32600)
    }

    func testAnIntegralIdSurvivesInEveryFormAJSONParserCanProduce() throws {
        for id in [7 as Any, "seven" as Any, 3.0 as Any, -1 as Any, 0 as Any] {
            var message = request("ping")
            message["id"] = id
            let response = try XCTUnwrap(server.handle(message), "\(id)")
            XCTAssertNotNil(response["result"], "\(id) is a legal id and must be answered")
        }
    }

    /// JSON `true` decodes to an NSNumber like any other number, so a boolean
    /// id would otherwise pass an "is it a number?" check.
    func testABooleanOrStructuredIdIsRejected() throws {
        for id in [true as Any, [1, 2] as Any, ["a": 1] as Any] {
            var message = request("ping")
            message["id"] = id
            XCTAssertEqual(try errorCode(server.handle(message)), -32600, "\(id)")
        }
    }

    func testAMissingOrWrongJSONRPCMemberIsInvalidRequest() throws {
        var message: [String: Any] = ["method": "ping", "id": 1]
        XCTAssertEqual(try errorCode(server.handle(message)), -32600)
        message["jsonrpc"] = "1.0"
        XCTAssertEqual(try errorCode(server.handle(message)), -32600)
        message["jsonrpc"] = 2.0
        XCTAssertEqual(try errorCode(server.handle(message)), -32600)
        // And the id it CAN read is echoed, so the client can correlate.
        message["jsonrpc"] = "2.0"
        XCTAssertNotNil(try XCTUnwrap(server.handle(message))["result"])
    }

    /// A malformed envelope on a NOTIFICATION still gets no reply: it has no
    /// id, and answering one is the failure the whole guard exists for.
    func testABadEnvelopeOnANotificationIsStillNotAnswered() throws {
        XCTAssertNil(try server.handle(["method": "notifications/initialized"]))
    }

    /// This server returns all 84 tools in one page and never issues a
    /// `nextCursor`, so no cursor value can be one it handed out. Silently
    /// returning page one again to a client that believes it is paging forward
    /// is the failure -32602 exists to prevent.
    func testAnUnrecognizedToolsListCursorIsInvalidParams() throws {
        XCTAssertEqual(
            try errorCode(server.handle(request("tools/list", id: 1, params: ["cursor": "page2"]))),
            -32602
        )
        // No cursor, and an explicit null cursor, are both "give me everything".
        XCTAssertNotNil(try XCTUnwrap(server.handle(request("tools/list", id: 1)))["result"])
        XCTAssertNotNil(try XCTUnwrap(
            server.handle(request("tools/list", id: 1, params: ["cursor": NSNull()]))
        )["result"])
    }

    /// Deterministic ordering is a `SHOULD` in 2026-07-28: it is what lets a
    /// client cache the list and keeps an LLM's prompt cache warm.
    func testToolsListOrderIsDeterministic() throws {
        func names() throws -> [String] {
            let response = try XCTUnwrap(server.handle(request("tools/list", id: 1)))
            let tools = try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
            return tools.compactMap { $0["name"] as? String }
        }
        XCTAssertEqual(try names(), try names())
    }

    // MARK: - The two eras

    /// `server/discover` is mandatory in 2026-07-28 and is the whole handshake:
    /// versions, capabilities, identity and instructions in one stateless call.
    func testServerDiscoverAdvertisesTheRangeAndTheModernResultShape() throws {
        let response = try XCTUnwrap(server.handle(modern("server/discover", id: "d1")))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["supportedVersions"] as? [String], supportedProtocolVersions)
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertFalse((result["instructions"] as? String ?? "").isEmpty)
        // CacheableResult, and the modern result envelope.
        XCTAssertEqual(result["cacheScope"] as? String, "public")
        XCTAssertEqual(result["ttlMs"] as? Int, toolListCacheTTLMs)
        XCTAssertEqual(result["resultType"] as? String, "complete")
        let info = try XCTUnwrap(
            (result["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"] as? [String: Any]
        )
        XCTAssertEqual(info["name"] as? String, serverName)
        XCTAssertEqual(info["version"] as? String, serverVersion)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(response))
    }

    /// The stdio backward-compatibility probe reads ANY non-modern error as
    /// "this is a legacy server" and falls back to `initialize`. Refusing a
    /// discovery probe over a capabilities map that discovery does not need
    /// would therefore talk a modern client out of the modern path.
    func testServerDiscoverAnswersEvenWithoutTheRequiredMetaFields() throws {
        let bare = try XCTUnwrap(server.handle(request("server/discover", id: 1)))
        XCTAssertNotNil(bare["result"])
        let noCapabilities = try XCTUnwrap(
            server.handle(modern("server/discover", id: 2, capabilities: nil))
        )
        XCTAssertNotNil(noCapabilities["result"])
    }

    func testAModernRequestGetsResultTypeAndTheCachingHints() throws {
        let response = try XCTUnwrap(server.handle(modern("tools/list")))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertEqual(result["ttlMs"] as? Int, toolListCacheTTLMs)
        XCTAssertEqual(result["cacheScope"] as? String, "public")
        XCTAssertNotNil((result["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"])
        XCTAssertEqual((result["tools"] as? [[String: Any]])?.count, 83)
    }

    /// A legacy client has no schema for `resultType` or the caching hints, so
    /// it is never sent them.
    func testALegacyRequestGetsNeitherResultTypeNorCachingHints() throws {
        let result = try XCTUnwrap(
            try XCTUnwrap(server.handle(request("tools/list", id: 1)))["result"] as? [String: Any]
        )
        XCTAssertNil(result["resultType"])
        XCTAssertNil(result["ttlMs"])
        XCTAssertNil(result["cacheScope"])
        XCTAssertNil(result["_meta"])
    }

    func testAnUnsupportedPerRequestVersionIsUnsupportedProtocolVersion() throws {
        for method in ["tools/list", "server/discover", "ping"] {
            let response = try XCTUnwrap(server.handle(modern(method, version: "2024-11-05")))
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32022, method)
            let data = try XCTUnwrap(error["data"] as? [String: Any], method)
            XCTAssertEqual(data["supported"] as? [String], supportedProtocolVersions, method)
            XCTAssertEqual(data["requested"] as? String, "2024-11-05", method)
        }
    }

    /// `clientCapabilities` is required on every modern request - there is no
    /// handshake left to carry it - and a request missing a required `_meta`
    /// field is malformed.
    func testAModernRequestWithoutClientCapabilitiesIsInvalidParams() throws {
        XCTAssertEqual(
            try errorCode(server.handle(modern("tools/list", capabilities: nil))), -32602
        )
    }

    /// `_meta` is not a modernity signal by itself: `progressToken` has lived
    /// there since 2025-03-26, and reading it as "this client is modern" would
    /// have started rejecting every legacy call that asks for progress.
    func testAMetaCarryingOnlyAProgressTokenIsStillLegacy() throws {
        let response = try XCTUnwrap(server.handle(
            request("tools/list", id: 1, params: ["_meta": ["progressToken": "abc"]])
        ))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertNil(result["resultType"], "a progressToken must not promote a client to modern")
    }

    /// A legacy revision named through the modern `_meta` slot is served in the
    /// dialect it asked for, not the one it used to ask.
    func testALegacyVersionInTheModernSlotIsServedAsLegacy() throws {
        let response = try XCTUnwrap(server.handle(modern("tools/list", version: "2025-06-18")))
        XCTAssertNil((response["result"] as? [String: Any])?["resultType"])
    }

    /// Removed from the protocol in 2026-07-28 and still answered, in both
    /// eras: it is a stateless no-op, and refusing a client's keepalive to make
    /// a point about a revision it may not have read breaks sessions.
    func testPingIsStillAnsweredInBothEras() throws {
        XCTAssertNotNil(try XCTUnwrap(server.handle(request("ping", id: 1)))["result"])
        let modernPing = try XCTUnwrap(server.handle(modern("ping")))
        XCTAssertEqual(
            (modernPing["result"] as? [String: Any])?["resultType"] as? String, "complete"
        )
    }

    func testDiscoverAndCancelAreStillNeverAnsweredWithoutAnId() throws {
        for method in ["server/discover", "notifications/cancelled", "notifications/progress"] {
            XCTAssertNil(try server.handle(request(method)), method)
        }
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
        let responses = try XCTUnwrap(batch([
            request("ping", id: 1),
            request("notifications/initialized"),
            request("tools/list", id: "two")
        ]))
        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(responses[0]["id"] as? Int, 1)
        XCTAssertEqual(responses[1]["id"] as? String, "two")
    }

    func testABatchOfNotificationsProducesNoOutputAtAll() throws {
        XCTAssertNil(try batch([
            request("notifications/initialized"),
            request("notifications/cancelled"),
            request("ping")
        ]))
    }

    /// An empty batch is answered with a single error OBJECT, never an array
    /// holding one. It used to come back wrapped, which made a client look for
    /// a batch member to correlate the error with and find none.
    func testAnEmptyBatchIsOneInvalidRequestOBJECTNotAnArray() throws {
        let output = try XCTUnwrap(server.handleBatch([]))
        XCTAssertNil(output as? [[String: Any]], "an empty batch must not answer with an array")
        let response = try XCTUnwrap(output as? [String: Any])
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertTrue(response["id"] is NSNull)
        XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
    }

    func testANonObjectMemberIsRejectedWithoutLosingTheRestOfTheBatch() throws {
        let responses = try XCTUnwrap(batch(["not a request", 42, request("ping", id: 5)]))
        XCTAssertEqual(responses.count, 3)
        XCTAssertEqual((responses[0]["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertEqual((responses[1]["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertEqual(responses[2]["id"] as? Int, 5)
        XCTAssertNotNil(responses[2]["result"])
    }

    func testABatchErrorAndAToolErrorKeepTheirOwnShapes() throws {
        let responses = try XCTUnwrap(batch([
            request("tools/call", id: 1, params: ["name": "logic_nope", "arguments": [:]]),
            request("frobnicate", id: 2)
        ]))
        XCTAssertEqual((responses[0]["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual((responses[1]["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testABatchIsSerializableAsOneJSONArray() throws {
        let responses = try XCTUnwrap(batch([request("ping", id: 1)]))
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
        XCTAssertEqual(tools.count, 83)
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

    /// Every tool carries a short human name, and every one is distinct.
    ///
    /// The point is the approval prompt: a client that renders
    /// `logic_set_track_volume` is showing a person a snake_case identifier at
    /// the moment they have to decide whether to allow it. Distinct because a
    /// picker that lists "Set a plugin parameter" twice cannot be read, and
    /// terse because a label that wraps is a description in the wrong field —
    /// the whole set costs 2,373 bytes of `tools/list`, and it stays that cheap
    /// only if nobody writes a sentence here.
    func testEveryToolHasAShortDistinctTitle() throws {
        var titles: Set<String> = []
        for tool in server.toolRegistry() {
            XCTAssertFalse(tool.title.isEmpty, tool.name)
            XCTAssertLessThanOrEqual(tool.title.count, 32, "\(tool.name): '\(tool.title)' is a sentence")
            XCTAssertFalse(tool.title.hasSuffix("."), "\(tool.name): a label is not a sentence")
            XCTAssertFalse(tool.title.contains("logic_"), "\(tool.name): the title is the HUMAN name")
            XCTAssertTrue(titles.insert(tool.title).inserted, "duplicate title '\(tool.title)'")
        }
        // And it reaches the wire where a client looks for it.
        for definition in server.toolDefinitions() {
            let annotations = try XCTUnwrap(definition["annotations"] as? [String: Any])
            XCTAssertNotNil(annotations["title"] as? String, "\(definition["name"] ?? "?")")
        }
    }

    // MARK: - The result contract, as the surface advertises it

    /// `mayWarn` and the advertised description cannot disagree: the note is
    /// appended by `definition`, so a tool that can warn says so exactly once
    /// and one that cannot never claims it.
    func testTheWarningNoteIsAdvertisedExactlyOncePerFlaggedTool() throws {
        let byName = Dictionary(uniqueKeysWithValues: server.toolRegistry().map { ($0.name, $0) })
        for definition in server.toolDefinitions() {
            let name = try XCTUnwrap(definition["name"] as? String)
            let described = try XCTUnwrap(definition["description"] as? String)
            let tool = try XCTUnwrap(byName[name])
            let occurrences = described.components(separatedBy: Tool.warningNote).count - 1
            XCTAssertEqual(occurrences, tool.mayWarn ? 1 : 0, name)
        }
    }

    /// The census the result-key inventory produced: 29 tools can put a
    /// top-level `warning` in their result. A new emitter that forgets the flag
    /// (or a flag on a tool that cannot warn) fails here rather than shipping a
    /// key no description mentions.
    func testEveryToolThatCanWarnIsFlagged() {
        let expected: Set<String> = [
            "logic_add_plugin", "logic_add_send", "logic_bounce_in_place", "logic_bounce_range",
            "logic_duplicate_project", "logic_edit_event", "logic_evaluate_change",
            "logic_export_stems", "logic_import_midi", "logic_learn_key_command",
            "logic_list_events",
            "logic_load_instrument", "logic_markers", "logic_mixer_snapshot", "logic_plugin_preset",
            "logic_project_snapshot", "logic_read_automation", "logic_record_automation",
            "logic_record_midi", "logic_remove_plugin", "logic_remove_silence", "logic_render_track",
            "logic_reset_to", "logic_set_metronome", "logic_set_mixer", "logic_set_tempo",
            "logic_set_track_record_arm", "logic_split_region", "logic_tempo_events"
        ]
        let flagged = Set(server.toolRegistry().filter(\.mayWarn).map(\.name))
        XCTAssertEqual(flagged, expected)
    }

    /// The two numberings are the single most damaging confusion on this
    /// surface (an output strip had them REVERSED), so every argument that
    /// names one must say which it is not.
    func testEveryInsertOrdinalArgumentSaysWhichNumberingItIsNot() throws {
        for tool in server.toolRegistry() {
            let properties = tool.inputSchema["properties"] as? [String: Any] ?? [:]
            for key in ["insert_index", "insert_slot"] {
                guard let property = properties[key] as? [String: Any] else { continue }
                let text = try XCTUnwrap(property["description"] as? String, "\(tool.name).\(key)")
                XCTAssertTrue(
                    text.contains("NOT the"),
                    "\(tool.name).\(key) does not say which numbering it is NOT"
                )
            }
        }
    }

    /// `db` stopped being required when `relative_db` arrived; the handler
    /// enforces "exactly one of them", which a JSON Schema `required` cannot.
    func testVolumeTakesEitherAnAbsoluteOrARelativeTargetAndSaysSo() throws {
        let tool = try XCTUnwrap(
            server.toolRegistry().first { $0.name == "logic_set_track_volume" }
        )
        XCTAssertEqual(tool.inputSchema["required"] as? [String], ["track_name"])
        let properties = try XCTUnwrap(tool.inputSchema["properties"] as? [String: Any])
        for key in ["db", "relative_db", "expected_current_db"] {
            XCTAssertNotNil(properties[key], key)
        }
        XCTAssertTrue(tool.description.contains("ABSOLUTE"))
    }
}
