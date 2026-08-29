import Foundation
import XCTest
@testable import Logician

/// The `resources` capability: the two families this server serves, the era
/// differences between them, and — the half that matters most — everything it
/// refuses to serve.
///
/// `resources/read` takes a client-supplied string and turns it into a path on
/// the user's disk, which makes it the widest attack surface in the server. The
/// traversal cases below are not hypothetical: the captures directory on the
/// development machine still contains a file called
/// `logicmcp-..-..-..-tmp-pwned-*.aif`, left there by the test that proved
/// filename sanitisation works on the WRITE side. This is the read side.
///
/// Nothing here touches the user's real captures directory:
/// `Captures.rootOverride` points the whole layer at a temporary one for the
/// duration of each test.
final class MCPResourceTests: XCTestCase {

    private var server = MCPServer()
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = MCPServer()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("logician-captures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Captures.rootOverride = root
    }

    override func tearDownWithError() throws {
        Captures.rootOverride = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    // MARK: Helpers

    @discardableResult
    private func writeCapture(_ name: String, bytes: Int = 32, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    private func request(_ method: String, id: Any = 1, params: [String: Any]? = nil) -> [String: Any] {
        var request: [String: Any] = ["jsonrpc": "2.0", "method": method, "id": id]
        if let params { request["params"] = params }
        return request
    }

    private func modern(_ method: String, params: [String: Any] = [:]) -> [String: Any] {
        var params = params
        params["_meta"] = [
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": [:]
        ]
        return request(method, params: params)
    }

    /// A request in one named LEGACY revision, announced through the modern
    /// `_meta` slot (which the server serves in the dialect it names).
    private func legacy(_ method: String, revision: String, params: [String: Any] = [:]) -> [String: Any] {
        var params = params
        params["_meta"] = [
            "io.modelcontextprotocol/protocolVersion": revision,
            "io.modelcontextprotocol/clientCapabilities": [:]
        ]
        return request(method, params: params)
    }

    private func result(_ response: [String: Any]?) throws -> [String: Any] {
        let response = try XCTUnwrap(response)
        XCTAssertNil(response["error"], "expected a result, got \(response["error"] ?? "?")")
        return try XCTUnwrap(response["result"] as? [String: Any])
    }

    private func error(_ response: [String: Any]?) throws -> [String: Any] {
        let response = try XCTUnwrap(response)
        XCTAssertNil(response["result"], "a refusal must not also carry a result")
        return try XCTUnwrap(response["error"] as? [String: Any])
    }

    private func resources(_ response: [String: Any]?) throws -> [[String: Any]] {
        try XCTUnwrap(try result(response)["resources"] as? [[String: Any]])
    }

    // MARK: - The capability, on both eras

    /// Resources have been in the spec since 2025-03-26, unchanged in shape, so
    /// there is no era this server speaks that cannot use them — and a
    /// capability declared on one handshake but not the other would leave the
    /// legacy half of the world unable to find the guide.
    func testBothHandshakesDeclareTheResourcesCapability() throws {
        for handshake in [try result(server.handle(request("initialize"))),
                          try result(server.handle(modern("server/discover")))] {
            let capabilities = try XCTUnwrap(handshake["capabilities"] as? [String: Any])
            let resources = try XCTUnwrap(
                capabilities["resources"] as? [String: Any], "no resources capability"
            )
            // Neither is claimed: there is no watcher on the captures directory
            // and no subscription machinery.
            XCTAssertEqual(resources["listChanged"] as? Bool, false)
            XCTAssertNil(resources["subscribe"])
            XCTAssertNotNil(capabilities["tools"])
        }
    }

    // MARK: - resources/list

    func testTheGuideIsListedWithItsSizeAndMarkdownType() throws {
        let listed = try resources(server.handle(request("resources/list")))
        let guide = try XCTUnwrap(listed.first { $0["uri"] as? String == guideResourceURI })
        XCTAssertEqual(guide["mimeType"] as? String, "text/markdown")
        XCTAssertEqual(guide["name"] as? String, "AGENT-GUIDE.md")
        XCTAssertEqual(guide["size"] as? Int, agentGuideMarkdown.utf8.count)
    }

    func testCapturesAreListedNewestFirstWithTheirSizes() throws {
        let now = Date()
        try writeCapture("old.wav", bytes: 2048, modified: now.addingTimeInterval(-600))
        try writeCapture("new.m4a", bytes: 1024, modified: now)
        try writeCapture("middle.aif", bytes: 4096, modified: now.addingTimeInterval(-60))

        let listed = try resources(server.handle(request("resources/list")))
        let captureNames = listed.compactMap { $0["uri"] as? String }
            .filter { $0.hasPrefix(capturesURIPrefix) }
        XCTAssertEqual(captureNames, [
            capturesURIPrefix + "new.m4a",
            capturesURIPrefix + "middle.aif",
            capturesURIPrefix + "old.wav"
        ])
        let newest = try XCTUnwrap(listed.first { $0["name"] as? String == "new.m4a" })
        XCTAssertEqual(newest["mimeType"] as? String, "audio/mp4")
        XCTAssertEqual(newest["size"] as? Int, 1024)
        // The size is in the description too, because that is the field a
        // picker actually shows a person.
        XCTAssertTrue(
            try XCTUnwrap(newest["description"] as? String).contains("1 KB"),
            "\(newest["description"] ?? "?")"
        )
    }

    /// The directory has hundreds of files and nothing prunes it (93 files /
    /// 738 MB after two weeks of real use). Listing all of them would put a
    /// megabyte of JSON in front of a model to describe audio it will fetch at
    /// most one of.
    func testTheListIsCappedAtTheMostRecentFifty() throws {
        let now = Date()
        for index in 0..<70 {
            try writeCapture(
                String(format: "take-%03d.wav", index),
                modified: now.addingTimeInterval(-Double(index))
            )
        }
        let listed = try resources(server.handle(request("resources/list")))
        let captures = listed.filter { ($0["uri"] as? String)?.hasPrefix(capturesURIPrefix) == true }
        XCTAssertEqual(captures.count, capturesListLimit)
        XCTAssertEqual(captures.first?["name"] as? String, "take-000.wav")
        XCTAssertEqual(captures.last?["name"] as? String, "take-049.wav")
        // And the guide is never crowded out by the cap.
        XCTAssertEqual(listed.count, capturesListLimit + 1)
    }

    /// A capture too big to read is still LISTED — with the refusal stated up
    /// front, so a client can pick the preview instead of discovering the cap
    /// by hitting it.
    func testAnOversizeCaptureIsListedWithTheRefusalInItsDescription() throws {
        try writeCapture("huge.wav", bytes: capturesReadByteCap + 1)
        let listed = try resources(server.handle(request("resources/list")))
        let huge = try XCTUnwrap(listed.first { $0["name"] as? String == "huge.wav" })
        XCTAssertTrue(try XCTUnwrap(huge["description"] as? String).contains("TOO LARGE"))
    }

    /// Only audio, and only regular files. The captures directory is where
    /// agent-named renders land; "serve whatever is in there" is a wider
    /// promise than this server can keep.
    func testNonAudioFilesAndDirectoriesAreNotResources() throws {
        try writeCapture("notes.txt")
        try writeCapture("secrets.json")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("folder.wav"), withIntermediateDirectories: true
        )
        let listed = try resources(server.handle(request("resources/list")))
        XCTAssertEqual(listed.count, 1, "only the guide should be listed")
        XCTAssertEqual(listed[0]["uri"] as? String, guideResourceURI)
    }

    func testAMissingCapturesDirectoryListsTheGuideAndIsNotCreated() throws {
        let absent = root.appendingPathComponent("never-rendered")
        Captures.rootOverride = absent
        let listed = try resources(server.handle(request("resources/list")))
        XCTAssertEqual(listed.count, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: absent.path),
            "listing must not create the directory as a side effect of reading"
        )
    }

    // MARK: - The era differences

    func testAModernListCarriesResultTypeAndTheShortCacheHints() throws {
        let result = try result(server.handle(modern("resources/list")))
        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertEqual(result["ttlMs"] as? Int, resourceListCacheTTLMs)
        // The captures family is THIS user's audio, so the listing is not
        // public the way `tools/list` is.
        XCTAssertEqual(result["cacheScope"] as? String, "private")
        XCTAssertLessThan(
            resourceListCacheTTLMs, toolListCacheTTLMs,
            "captures change while a session renders; the tool surface cannot"
        )
    }

    func testALegacyListCarriesNeitherResultTypeNorCacheHints() throws {
        let result = try result(server.handle(request("resources/list")))
        XCTAssertNil(result["resultType"])
        XCTAssertNil(result["ttlMs"])
        XCTAssertNil(result["cacheScope"])
    }

    /// The 2025-03-26 `Resource` is uri/name/description/mimeType/size and
    /// nothing else — no `title`, and no annotations section in that revision
    /// at all. Both arrive in 2025-06-18.
    func testTitleAndAnnotationsAreWithheldFrom20250326() throws {
        try writeCapture("take.wav")
        for entry in try resources(server.handle(legacy("resources/list", revision: "2025-03-26"))) {
            XCTAssertNil(entry["title"], "\(entry["uri"] ?? "?")")
            XCTAssertNil(entry["annotations"], "\(entry["uri"] ?? "?")")
            // The fields every supported revision does have are still there.
            XCTAssertNotNil(entry["uri"])
            XCTAssertNotNil(entry["name"])
            XCTAssertNotNil(entry["mimeType"])
            XCTAssertNotNil(entry["size"])
        }
        let newer = try resources(server.handle(legacy("resources/list", revision: "2025-06-18")))
        let guide = try XCTUnwrap(newer.first { $0["uri"] as? String == guideResourceURI })
        XCTAssertEqual(guide["title"] as? String, "Logician Agent Guide")
        XCTAssertNotNil(guide["annotations"])
    }

    // MARK: - resources/read: the guide

    func testReadingTheGuideReturnsTheWholeMarkdownAsText() throws {
        let result = try result(server.handle(
            request("resources/read", params: ["uri": guideResourceURI])
        ))
        let contents = try XCTUnwrap(result["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["uri"] as? String, guideResourceURI)
        XCTAssertEqual(contents[0]["mimeType"] as? String, "text/markdown")
        XCTAssertNil(contents[0]["blob"], "markdown is text, not a blob")
        XCTAssertEqual(contents[0]["text"] as? String, agentGuideMarkdown)
    }

    /// The guide is CACHEABLE for as long as the tool surface is, and for the
    /// same reason: both are compiled into the binary, so only a new build can
    /// change either.
    func testTheGuideReadIsPublicAndLongLivedWhileACaptureReadIsNeither() throws {
        try writeCapture("take.wav")
        let guide = try result(server.handle(
            modern("resources/read", params: ["uri": guideResourceURI])
        ))
        XCTAssertEqual(guide["resultType"] as? String, "complete")
        XCTAssertEqual(guide["ttlMs"] as? Int, toolListCacheTTLMs)
        XCTAssertEqual(guide["cacheScope"] as? String, "public")

        let capture = try result(server.handle(
            modern("resources/read", params: ["uri": capturesURIPrefix + "take.wav"])
        ))
        XCTAssertEqual(capture["ttlMs"] as? Int, resourceListCacheTTLMs)
        XCTAssertEqual(capture["cacheScope"] as? String, "private")
    }

    /// The DRIFT GUARD for the embed. `AgentGuideText.swift` is generated by
    /// `scripts/embed_agent_guide.py`, and the whole reason the guide is
    /// compiled in rather than read off disk is that an installed binary has no
    /// repo around it. That trade is only honest while the constant and the
    /// file still say the same thing — so editing docs/AGENT-GUIDE.md without
    /// re-running the script fails here rather than shipping a stale guide.
    func testTheEmbeddedGuideMatchesDocsAgentGuideByteForByte() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LogicianTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
        let onDisk = try String(
            contentsOf: repository.appendingPathComponent("docs/AGENT-GUIDE.md"), encoding: .utf8
        )
        XCTAssertEqual(
            agentGuideMarkdown, onDisk,
            "docs/AGENT-GUIDE.md changed without re-running scripts/embed_agent_guide.py"
        )
    }

    // MARK: - resources/read: captures

    func testReadingACaptureReturnsItsBytesAsABase64Blob() throws {
        let payload = Data("not really audio, but it is the bytes that matter".utf8)
        try payload.write(to: root.appendingPathComponent("take.m4a"))
        let result = try result(server.handle(
            request("resources/read", params: ["uri": capturesURIPrefix + "take.m4a"])
        ))
        let contents = try XCTUnwrap(result["contents"] as? [[String: Any]])
        XCTAssertEqual(contents[0]["mimeType"] as? String, "audio/mp4")
        XCTAssertNil(contents[0]["text"], "audio is a blob, not text")
        let blob = try XCTUnwrap(contents[0]["blob"] as? String)
        XCTAssertEqual(Data(base64Encoded: blob), payload)
    }

    func testAPercentEncodedFilenameResolves() throws {
        try writeCapture("bounce of the mix.wav")
        let result = try result(server.handle(request(
            "resources/read", params: ["uri": capturesURIPrefix + "bounce%20of%20the%20mix.wav"]
        )))
        XCTAssertNotNil((result["contents"] as? [[String: Any]])?.first?["blob"])
    }

    /// A `.wav` master out of a four-minute bounce is 40-80 MB, and base64
    /// makes it a third larger again. The refusal has to name the way out, and
    /// the way out is the AAC preview this server already writes beside every
    /// master under the same stem.
    func testAnOversizeCaptureIsRefusedAndPointsAtTheAACPreviewBesideIt() throws {
        try writeCapture("master.wav", bytes: capturesReadByteCap + 1)
        try writeCapture("master.m4a", bytes: 4096)
        let error = try error(server.handle(
            request("resources/read", params: ["uri": capturesURIPrefix + "master.wav"])
        ))
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertTrue(message.contains("master.m4a"), message)
        XCTAssertTrue(message.contains("NOTHING was returned"), message)
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["maxBytes"] as? Int, capturesReadByteCap)
        // The preview itself is under the cap and reads fine.
        XCTAssertNotNil(try result(server.handle(
            request("resources/read", params: ["uri": capturesURIPrefix + "master.m4a"])
        ))["contents"])
    }

    func testAnOversizeCaptureWithNoPreviewPointsAtTheClipToolInstead() throws {
        try writeCapture("lonely.wav", bytes: capturesReadByteCap + 1)
        let error = try error(server.handle(
            request("resources/read", params: ["uri": capturesURIPrefix + "lonely.wav"])
        ))
        XCTAssertTrue(
            try XCTUnwrap(error["message"] as? String).contains("logic_get_audio_clip")
        )
    }

    // MARK: - resources/read: everything it refuses

    /// The heart of the security case. Every one of these resolves to a real
    /// file on a developer machine, and not one of them may be served.
    func testTraversalAndAbsolutePathsAreRefusedRatherThanResolved() throws {
        try writeCapture("inside.wav")
        // A file that really exists, outside the captures directory.
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("logician-outside-\(UUID().uuidString).wav")
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let attempts = [
            "../" + outside.lastPathComponent,
            "..%2F" + outside.lastPathComponent,
            "%2e%2e%2f" + outside.lastPathComponent,
            "..\\" + outside.lastPathComponent,
            outside.path,                       // an absolute path as the "filename"
            "/etc/passwd",
            "..",
            ".",
            "",
            "subdirectory/inside.wav",
            "inside.wav/../../" + outside.lastPathComponent
        ]
        for attempt in attempts {
            let error = try error(server.handle(request(
                "resources/read", params: ["uri": capturesURIPrefix + attempt]
            )))
            XCTAssertEqual(
                error["code"] as? Int, -32002,
                "'\(attempt)' must be refused as not-found, not resolved"
            )
            XCTAssertTrue(
                try XCTUnwrap(error["message"] as? String).contains("Resource not found"),
                attempt
            )
        }
        // The control: the same reader serves the file that IS inside.
        XCTAssertNotNil(try result(server.handle(
            request("resources/read", params: ["uri": capturesURIPrefix + "inside.wav"])
        ))["contents"])
    }

    /// A symlink is a single filename with no separator in it, so every
    /// character-level check above passes it. Only resolving the real path and
    /// re-checking containment catches this one.
    func testASymlinkInsideTheCapturesDirectoryCannotReachOutsideIt() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("logician-secret-\(UUID().uuidString).wav")
        try Data("private".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("innocent.wav"), withDestinationURL: outside
        )
        let error = try error(server.handle(
            request("resources/read", params: ["uri": capturesURIPrefix + "innocent.wav"])
        ))
        XCTAssertEqual(error["code"] as? Int, -32002)
        // And it is not offered in the listing either.
        let listed = try resources(server.handle(request("resources/list")))
        XCTAssertFalse(listed.contains { $0["name"] as? String == "innocent.wav" })
    }

    /// A directory whose name ends in `.wav` is not audio, and a non-audio file
    /// that exists is still not a resource.
    func testOnlyExistingAudioFilesResolve() throws {
        try writeCapture("notes.txt")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("folder.wav"), withIntermediateDirectories: true
        )
        for name in ["notes.txt", "folder.wav", "never-rendered.wav"] {
            let error = try error(server.handle(
                request("resources/read", params: ["uri": capturesURIPrefix + name])
            ))
            XCTAssertEqual(error["code"] as? Int, -32002, name)
        }
    }

    func testAnUnknownSchemeIsNotFoundAndSaysWhatTheTwoFamiliesAre() throws {
        for uri in ["file:///etc/passwd", "logician://guides", "https://example.com/x.wav",
                    "logician://captures", "nonsense"] {
            let error = try error(server.handle(request("resources/read", params: ["uri": uri])))
            XCTAssertEqual(error["code"] as? Int, -32002, uri)
            let message = try XCTUnwrap(error["message"] as? String)
            XCTAssertTrue(message.contains(guideResourceURI), uri)
            XCTAssertTrue(message.contains(capturesURIPrefix), uri)
        }
    }

    /// 2026-07-28 retired `-32002` and requires `-32602` for a resource that
    /// does not exist; every older revision specifies `-32002`. Emitting the
    /// retired code to a modern client would be the same sort of quiet lie as
    /// answering `2024-11-05` and then sending it an audio block.
    func testNotFoundUsesTheCodeTheEraSpecifies() throws {
        let uri = capturesURIPrefix + "../escape.wav"
        XCTAssertEqual(
            try error(server.handle(modern("resources/read", params: ["uri": uri])))["code"] as? Int,
            -32602
        )
        for revision in ["2025-11-25", "2025-06-18", "2025-03-26"] {
            XCTAssertEqual(
                try error(server.handle(
                    legacy("resources/read", revision: revision, params: ["uri": uri])
                ))["code"] as? Int,
                -32002,
                revision
            )
        }
    }

    func testAReadWithoutAURIIsInvalidParams() throws {
        XCTAssertEqual(
            try error(server.handle(request("resources/read")))["code"] as? Int, -32602
        )
        XCTAssertEqual(
            try error(server.handle(request("resources/read", params: ["uri": 7])))["code"] as? Int,
            -32602
        )
    }

    // MARK: - Listing shape

    func testAnUnrecognizedListCursorIsInvalidParams() throws {
        let error = try error(server.handle(
            request("resources/list", params: ["cursor": "page2"])
        ))
        XCTAssertEqual(error["code"] as? Int, -32602)
        // A null cursor is "give me everything", exactly as on tools/list.
        XCTAssertNotNil(try result(server.handle(
            request("resources/list", params: ["cursor": NSNull()])
        ))["resources"])
    }

    func testTemplatesListIsAnsweredEmptyRatherThanMethodNotFound() throws {
        let result = try result(server.handle(request("resources/templates/list")))
        XCTAssertEqual((result["resourceTemplates"] as? [Any])?.count, 0)
    }

    func testEveryListedResourceIsSerializableAndReadable() throws {
        try writeCapture("take one.wav")
        try writeCapture("take-2.aif")
        let response = try XCTUnwrap(server.handle(request("resources/list")))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(response))
        for entry in try resources(response) {
            let uri = try XCTUnwrap(entry["uri"] as? String)
            XCTAssertNotNil(
                try result(server.handle(request("resources/read", params: ["uri": uri])))["contents"],
                "listed but not readable: \(uri)"
            )
        }
    }

    // MARK: - resource_link blocks on tool results

    private func blocks(_ result: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(result["content"] as? [[String: Any]])
    }

    private func links(_ result: [String: Any]) throws -> [[String: Any]] {
        try blocks(result).filter { $0["type"] as? String == "resource_link" }
    }

    private func renderPayload() throws -> [String: Any] {
        try writeCapture("render-bass-1787807004.aif", bytes: 4096)
        try writeCapture("render-bass-1787807004.m4a", bytes: 1024)
        return [
            "success": true,
            "path": root.appendingPathComponent("render-bass-1787807004.aif").path,
            "preview_path": root.appendingPathComponent("render-bass-1787807004.m4a").path,
            "listen_note": "This result CARRIES the rendered audio as an MCP audio block",
            "_audio": ["data": "QUJD", "mimeType": "audio/mp4"]
        ]
    }

    func testAnAudioResultCarriesALinkPerRenderedFileBesideTheAudioBlock() throws {
        let rendered = server.toolResult(
            payload: try renderPayload(), isError: false, era: .modern("2026-07-28")
        )
        let content = try blocks(rendered)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[1]["type"] as? String, "audio", "inline audio is unchanged")
        let links = try links(rendered)
        XCTAssertEqual(links.map { $0["uri"] as? String }, [
            capturesURIPrefix + "render-bass-1787807004.aif",
            capturesURIPrefix + "render-bass-1787807004.m4a"
        ])
        let master = links[0]
        XCTAssertEqual(master["name"] as? String, "render-bass-1787807004.aif")
        XCTAssertEqual(master["mimeType"] as? String, "audio/aiff")
        XCTAssertEqual(master["size"] as? Int, 4096)
        XCTAssertNotNil(master["description"])
        // And every link resolves through the reader that will be asked for it.
        for link in links {
            let uri = try XCTUnwrap(link["uri"] as? String)
            XCTAssertNotNil(
                try result(server.handle(request("resources/read", params: ["uri": uri])))["contents"],
                uri
            )
        }
    }

    /// The whole point of the link. `include_audio: false` exists for clients
    /// that stringify content blocks they do not understand — before this, that
    /// client got paths it could do nothing with over the protocol. Now it gets
    /// a link it can fetch when it decides it wants to.
    func testTheLinkSurvivesIncludeAudioFalseEvenThoughTheAudioDoesNot() throws {
        let result = server.toolResult(
            payload: try renderPayload(), isError: false, includeAudio: false,
            era: .modern("2026-07-28")
        )
        XCTAssertFalse(try blocks(result).contains { $0["type"] as? String == "audio" })
        XCTAssertEqual(try links(result).count, 2)
    }

    /// 2025-03-26 has four content types in a tool result — text, image, audio
    /// and the embedded `resource` — and `resource_link` is not one of them.
    /// This is the same rule that keeps `2024-11-05` out of the supported
    /// range: never put a block on the wire the negotiated schema cannot
    /// describe.
    func testNoLinkIsEverSentToA20250326Client() throws {
        let payload = try renderPayload()
        XCTAssertEqual(
            try links(server.toolResult(payload: payload, isError: false, era: .legacy("2025-03-26"))).count,
            0
        )
        for revision in ["2025-06-18", "2025-11-25"] {
            XCTAssertEqual(
                try links(server.toolResult(payload: payload, isError: false, era: .legacy(revision))).count,
                2, revision
            )
        }
    }

    /// A link this server would refuse to serve is worse than no link, so a
    /// path only earns one when it resolves inside the captures directory —
    /// which rules out every non-audio `path` the other 77 tools return.
    func testPathsOutsideTheCapturesDirectoryNeverBecomeLinks() throws {
        try writeCapture("decoy.wav")
        let payloads: [[String: Any]] = [
            ["path": "/tmp/somewhere-else/decoy.wav"],          // same NAME, other directory
            ["path": "/Users/someone/Music/Song.logicx"],       // a project, not audio
            ["preview_path": NSNull()],
            ["clip_path": root.appendingPathComponent("never-written.m4a").path]
        ]
        for payload in payloads {
            XCTAssertEqual(
                try links(server.toolResult(
                    payload: payload, isError: false, era: .modern("2026-07-28")
                )).count,
                0, "\(payload)"
            )
        }
    }

    func testTheSliceOfARenderGetsItsOwnLinkAndNothingIsLinkedTwice() throws {
        try writeCapture("render-1.aif")
        try writeCapture("render-1-slice.wav")
        let result = server.toolResult(
            payload: [
                "path": root.appendingPathComponent("render-1.aif").path,
                // Deliberately the SAME file again under another key.
                "clip_path": root.appendingPathComponent("render-1.aif").path,
                "slice": ["path": root.appendingPathComponent("render-1-slice.wav").path]
            ],
            isError: false, era: .modern("2026-07-28")
        )
        XCTAssertEqual(try links(result).map { $0["name"] as? String },
                       ["render-1.aif", "render-1-slice.wav"])
    }

    /// The A/B tools name their two renders with their own keys. A key that is
    /// not in the census gets no link, silently — so the census is asserted
    /// against the standing note that lists the same keys to the agent.
    func testTheAudioPathKeyCensusCoversEveryKeyTheOptOutNoteAdvertises() throws {
        try writeCapture("a.m4a")
        try writeCapture("b.m4a")
        let result = server.toolResult(
            payload: [
                "baseline_audio": root.appendingPathComponent("a.m4a").path,
                "after_audio": root.appendingPathComponent("b.m4a").path
            ],
            isError: false, era: .modern("2026-07-28")
        )
        XCTAssertEqual(try links(result).count, 2)
        // Every path key the include_audio note tells an agent to open must be
        // a key this server actually looks at.
        let note = MCPServer.instructions
        for key in ["preview_path", "clip_path"] {
            XCTAssertTrue(note.contains(key), "the instructions stopped naming \(key)")
            XCTAssertTrue(MCPServer.audioPathKeys.contains(key), key)
        }
        for key in ["baseline_audio", "after_audio"] {
            XCTAssertTrue(MCPServer.audioPathKeys.contains(key), key)
        }
    }

    /// A capture whose own name contains a percent sign. The listing has to
    /// escape it to `%25` and the reader has to decode exactly ONCE — decode
    /// twice, or decode a name that was never encoded, and the two halves
    /// disagree about which file they mean. Renders are named after
    /// agent-supplied labels, so this is a name a user can really produce.
    func testAPercentSignInACaptureNameSurvivesBothDirections() throws {
        try writeCapture("take 50%.wav")
        let listed = try resources(server.handle(request("resources/list")))
        let entry = try XCTUnwrap(listed.first { $0["name"] as? String == "take 50%.wav" })
        let uri = try XCTUnwrap(entry["uri"] as? String)
        XCTAssertEqual(uri, capturesURIPrefix + "take%2050%25.wav")
        XCTAssertNotNil(try result(server.handle(
            request("resources/read", params: ["uri": uri])
        ))["contents"])
        // And the link built from the raw PATH points at the same escaped URI.
        let linked = try links(server.toolResult(
            payload: ["path": root.appendingPathComponent("take 50%.wav").path],
            isError: false, era: .modern("2026-07-28")
        ))
        XCTAssertEqual(linked.first?["uri"] as? String, uri)
    }

    /// A failure result carries no paths, and must not gain a link from the
    /// `error` text or anything else in it.
    func testAnErrorResultCarriesNoLinks() throws {
        let result = server.toolResult(
            payload: ["success": false, "error": "no such track", "error_code": "not_found"],
            isError: true, era: .modern("2026-07-28")
        )
        XCTAssertEqual(try blocks(result).count, 1)
    }
}
