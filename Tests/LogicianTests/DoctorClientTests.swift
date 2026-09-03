import XCTest

@testable import Logician

/// "Is Logician registered with the app you are actually using?" — pinned
/// against the real config shapes, because every client nests its servers
/// somewhere slightly different and the scan is deliberately shape-agnostic.
final class DoctorClientTests: XCTestCase {
    private func parse(_ json: String) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [:]
    }

    /// The shape `mcp-config.example.json` ships and every client understands.
    func testTopLevelMcpServersTable() {
        let registration = DoctorClients.registration(in: parse("""
            {"mcpServers": {"logician": {"command": "/Users/anna/bin/logician"}}}
            """))
        XCTAssertEqual(registration.serverNames, ["logician"])
        XCTAssertEqual(registration.command, "/Users/anna/bin/logician")
        XCTAssertTrue(registration.isRegistered)
    }

    /// Claude Code keeps a table per project as well as a global one, so the
    /// scan has to recurse rather than read one known key.
    func testNestedPerProjectTableIsFound() {
        let registration = DoctorClients.registration(in: parse("""
            {"projects": {"/Users/anna/song": {"mcpServers":
              {"logician": {"command": "/Users/anna/bin/logician"}}}}}
            """))
        XCTAssertEqual(registration.serverNames, ["logician"])
    }

    /// VS Code spells the table `servers`.
    func testServersSpellingIsAlsoATable() {
        let registration = DoctorClients.registration(in: parse("""
            {"servers": {"logician": {"command": "/opt/logician"}}}
            """))
        XCTAssertTrue(registration.isRegistered)
    }

    /// A user who named the entry something else is still registered — the
    /// command is what actually runs, so the command is also matched.
    func testAnEntryNamedSomethingElseIsFoundByItsCommand() {
        let registration = DoctorClients.registration(in: parse("""
            {"mcpServers": {"logic": {"command": "/Users/anna/logician-mcp/.build/release/logician"}}}
            """))
        XCTAssertEqual(registration.serverNames, ["logic"])
    }

    /// A config with other servers in it and none of ours is NOT registered.
    /// A false positive here would send a user hunting a Logic fault when
    /// their client has simply never heard of us.
    func testOtherServersAreNotUs() {
        let registration = DoctorClients.registration(in: parse("""
            {"mcpServers": {"github": {"command": "/usr/local/bin/github-mcp"},
                            "filesystem": {"command": "npx"}}}
            """))
        XCTAssertFalse(registration.isRegistered)
        XCTAssertNil(registration.command)
    }

    /// Two registrations with different paths is a real support case — one of
    /// them is stale — so both names are reported rather than the first.
    func testTwoRegistrationsAreBothReported() {
        let registration = DoctorClients.registration(in: parse("""
            {"mcpServers": {"logician": {"command": "/a/logician"},
                            "logician-dev": {"command": "/b/logician"}}}
            """))
        XCTAssertEqual(registration.serverNames, ["logician", "logician-dev"])
    }

    /// The commonest "why can't my agent see that tool?" answer, read back out
    /// of the config that causes it.
    func testToolsetsFlagInArgsIsReported() {
        let registration = DoctorClients.registration(in: parse("""
            {"mcpServers": {"logician": {"command": "/a/logician",
                                         "args": ["--toolsets=core,regions"]}}}
            """))
        XCTAssertEqual(registration.toolsets, "--toolsets=core,regions")
    }

    func testToolsetsEnvironmentVariableIsReported() {
        let registration = DoctorClients.registration(in: parse("""
            {"mcpServers": {"logician": {"command": "/a/logician",
                                         "env": {"LOGICIAN_TOOLSETS": "core"}}}}
            """))
        XCTAssertEqual(registration.toolsets, "LOGICIAN_TOOLSETS=core")
    }

    func testNoToolsetsFlagIsReportedAsNone() {
        let registration = DoctorClients.registration(in: parse("""
            {"mcpServers": {"logician": {"command": "/a/logician", "args": ["--verbose"]}}}
            """))
        XCTAssertNil(registration.toolsets)
    }

    /// The repo's own extension manifest has to be recognised, or a Gemini
    /// user installed through `gemini extensions install` reads as
    /// unregistered.
    func testTheShippedGeminiExtensionManifestIsRecognised() {
        let registration = DoctorClients.registration(in: parse("""
            {"name": "logician", "version": "0.61.0",
             "mcpServers": {"logician": {"command": "${extensionPath}${/}.build${/}release${/}logician"}}}
            """))
        XCTAssertTrue(registration.isRegistered)
    }

    /// Junk in, no crash out: a config whose server table is a string, or
    /// whose entries are not objects, is skipped rather than guessed at.
    func testMalformedTablesAreSkippedNotGuessedAt() {
        XCTAssertFalse(DoctorClients.registration(in: parse(#"{"mcpServers": "yes"}"#)).isRegistered)
        XCTAssertFalse(
            DoctorClients.registration(in: parse(#"{"mcpServers": {"logician": 3}}"#)).isRegistered
        )
        XCTAssertFalse(DoctorClients.registration(in: parse("[]")).isRegistered)
    }

    /// An EMPTY config file is the state VS Code leaves behind the moment you
    /// open its MCP view, and calling it "not readable JSON" would send a user
    /// to fix a file that is merely unused.
    func testAnEmptyFileIsToldApartFromABrokenOne() {
        XCTAssertEqual(DoctorClients.reading(of: Data()).0, .empty)
        XCTAssertEqual(DoctorClients.reading(of: Data("\n  \n".utf8)).0, .empty)
    }

    /// VS Code and Cursor both accept `//` comments, which `JSONSerialization`
    /// refuses. A config that mentions us is reported as probably-fine rather
    /// than unreadable — and NOT parsed further, because guessing at JSONC is
    /// how a doctor starts inventing facts.
    func testACommentedConfigThatMentionsUsIsRecognised() {
        let jsonc = Data("""
            {
              // the Logic Pro server
              "servers": {"logician": {"command": "/a/logician"}}
            }
            """.utf8)
        XCTAssertEqual(DoctorClients.reading(of: jsonc).0, .commentedMentioningUs)
        XCTAssertNil(DoctorClients.reading(of: jsonc).1)
    }

    func testGarbageIsUnreadable() {
        XCTAssertEqual(DoctorClients.reading(of: Data("not json at all".utf8)).0, .unreadable)
    }

    func testGoodJSONIsParsedAndHandedBack() {
        let (reading, object) = DoctorClients.reading(of: Data(#"{"a": 1}"#.utf8))
        XCTAssertEqual(reading, .parsed)
        XCTAssertNotNil(object)
    }

    /// Every path this doctor looks in is relative to the home directory —
    /// nothing here may reach outside it, and nothing may be absolute.
    func testEveryKnownConfigPathIsInsideTheHomeDirectory() {
        for config in DoctorClients.known {
            XCTAssertFalse(config.relativePath.hasPrefix("/"), config.relativePath)
            XCTAssertFalse(config.relativePath.contains(".."), config.relativePath)
            XCTAssertFalse(config.client.isEmpty)
        }
    }
}
