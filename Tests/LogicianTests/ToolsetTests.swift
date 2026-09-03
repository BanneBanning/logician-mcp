import XCTest

@testable import Logician

/// The toolset flag decides what is OFFERED. These tests hold the two lines
/// that must not move: the registry is complete no matter what the flag says,
/// and no tool can fall out of every set.
final class ToolsetTests: XCTestCase {
    private var server = MCPServer()

    override func setUp() {
        super.setUp()
        server = MCPServer()
        MCPServer.activeToolsets = Toolset.all
    }

    override func tearDown() {
        // The active sets are process-global (one launch flag, one server), so
        // a test that narrows them must put them back or it narrows every test
        // that runs after it.
        MCPServer.activeToolsets = Toolset.all
        super.tearDown()
    }

    // MARK: - Completeness

    /// The rule that makes the flag safe: every registered tool is reachable
    /// through at least one set, so no combination hides it from every session.
    func testEveryRegisteredToolBelongsToASet() {
        for tool in server.toolRegistry() {
            XCTAssertNotNil(
                Toolset.membership[tool.name],
                "\(tool.name) is in no toolset — add it to Toolset.membership"
            )
        }
    }

    /// And the other direction: a membership entry for a tool that no longer
    /// exists is a rename nobody finished.
    func testNoToolsetNamesAToolThatDoesNotExist() {
        let registered = Set(server.toolRegistry().map(\.name))
        for name in Toolset.membership.keys {
            XCTAssertTrue(registered.contains(name), "\(name) is in a toolset but not in the registry")
        }
    }

    /// The registry is the server's description of itself and does not depend
    /// on how this process was launched. Only the OFFER narrows.
    func testTheRegistryIsCompleteWhateverTheFlagSays() {
        let whole = server.toolRegistry().count
        MCPServer.activeToolsets = [.core]
        XCTAssertEqual(server.toolRegistry().count, whole)
        XCTAssertLessThan(server.activeTools().count, whole)
    }

    /// Every set actually has tools in it, and each one's members really are
    /// the ones the map assigns — a set that silently emptied would advertise
    /// a narrowing that does nothing.
    func testEverySetOffersExactlyItsOwnTools() {
        for set in Toolset.allCases {
            MCPServer.activeToolsets = [set]
            let offered = Set(server.activeTools().map(\.name))
            let expected = Set(Toolset.membership.filter { $0.value.contains(set) }.map(\.key))
            XCTAssertFalse(offered.isEmpty, "\(set.rawValue) offers nothing")
            XCTAssertEqual(offered, expected, set.rawValue)
        }
    }

    /// The union of the sets is the whole surface: `--toolsets=all` and no flag
    /// at all are the same list.
    func testTheUnionOfEverySetIsTheWholeRegistry() {
        MCPServer.activeToolsets = Toolset.all
        let everything = Set(server.activeTools().map(\.name))
        var union: Set<String> = []
        for set in Toolset.allCases {
            MCPServer.activeToolsets = [set]
            union.formUnion(server.activeTools().map(\.name))
        }
        XCTAssertEqual(union, everything)
    }

    /// `core` is the set the narrowing exists for, so it has to be a real cut
    /// AND still carry the tools a mixing session cannot start without.
    func testCoreIsASmallerSurfaceThatCanStillRunAMixingSession() {
        MCPServer.activeToolsets = [.core]
        let offered = Set(server.activeTools().map(\.name))
        XCTAssertLessThan(offered.count, server.toolRegistry().count)
        for essential in [
            "logic_health", "logic_list_tracks", "logic_track_info", "logic_mixer_snapshot",
            "logic_set_track_mix", "logic_list_inserts", "logic_set_plugin_parameter",
            "logic_bounce_range", "logic_evaluate_change", "logic_setup_key_commands"
        ] {
            XCTAssertTrue(offered.contains(essential), "core is missing \(essential)")
        }
        // And it really is narrower: the delivery and lifecycle tools are out.
        for excluded in ["logic_export_stems", "logic_reset_to", "logic_record_midi"] {
            XCTAssertFalse(offered.contains(excluded), "core should not offer \(excluded)")
        }
    }

    // MARK: - What tools/list and tools/call do about it

    func testToolsListReflectsTheActiveSets() throws {
        MCPServer.activeToolsets = [.regions]
        let response = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0", "id": 1, "method": "tools/list"
        ]))
        let tools = try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("logic_split_region"))
        XCTAssertFalse(names.contains("logic_export_stems"))
    }

    /// A tool outside the active sets is the unknown-tool error — the protocol
    /// has no other answer for a name it will not dispatch — but it says WHY,
    /// and names the flag that would bring it back. Anything less sends the
    /// agent hunting for a spelling that was already correct.
    func testCallingAToolOutsideTheActiveSetsNamesTheFlag() throws {
        MCPServer.activeToolsets = [.core]
        let message = try XCTUnwrap(server.unknownToolMessage(name: "logic_export_stems"))
        XCTAssertTrue(message.contains("not in this session's active toolsets"), message)
        XCTAssertTrue(message.contains(MCPServer.toolsetsFlag), message)
        XCTAssertTrue(message.contains(MCPServer.toolsetsEnvironmentVariable), message)
        XCTAssertTrue(message.contains("delivery"), message)
        // Still an invalid-params error at the protocol level, not an isError
        // result: the tool did not run and fail, it was never dispatched.
        let response = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "logic_export_stems", "arguments": [:]]
        ]))
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    /// A name that is not a tool at all gets the plain message: no flag hint,
    /// because the flag is not the problem.
    func testATrulyUnknownNameGetsNoToolsetHint() throws {
        MCPServer.activeToolsets = [.core]
        let message = try XCTUnwrap(server.unknownToolMessage(name: "logic_make_it_better"))
        XCTAssertFalse(message.contains("active toolsets"), message)
    }

    // MARK: - Parsing the flag

    private func parse(_ arguments: [String], environment: [String: String] = [:]) -> Set<Toolset> {
        MCPServer.activeToolsets = Toolset.all
        MCPServer.configureToolsets(
            arguments: ["logician"] + arguments, environment: environment, log: { _ in }
        )
        return MCPServer.activeToolsets
    }

    func testTheFlagParsesAListAndTolerantSpacing() {
        XCTAssertEqual(parse(["--toolsets=core"]), [.core])
        XCTAssertEqual(parse(["--toolsets=core,regions"]), [.core, .regions])
        XCTAssertEqual(parse(["--toolsets= core , REGIONS "]), [.core, .regions])
        XCTAssertEqual(parse(["--toolsets=all"]), Toolset.all)
    }

    func testTheEnvironmentVariableWorksAndTheFlagWins() {
        XCTAssertEqual(parse([], environment: ["LOGICIAN_TOOLSETS": "delivery"]), [.delivery])
        XCTAssertEqual(
            parse(["--toolsets=core"], environment: ["LOGICIAN_TOOLSETS": "delivery"]),
            [.core]
        )
    }

    func testNoFlagAndNoVariableLeavesTheWholeSurface() {
        XCTAssertEqual(parse([]), Toolset.all)
    }

    /// A typo must not produce a surprising surface. The known names are
    /// honoured, the unknown one is reported on stderr, and a value that names
    /// nothing at all leaves the default alone rather than serving zero tools
    /// to a client that could never ask why.
    func testUnknownNamesAreIgnoredAndAnEmptyResultKeepsEverything() {
        var logged: [String] = []
        MCPServer.activeToolsets = Toolset.all
        MCPServer.configureToolsets(
            arguments: ["logician", "--toolsets=core,mastering"], environment: [:],
            log: { logged.append($0) }
        )
        XCTAssertEqual(MCPServer.activeToolsets, [.core])
        XCTAssertTrue(logged.contains { $0.contains("mastering") }, "\(logged)")

        XCTAssertEqual(parse(["--toolsets=mastering"]), Toolset.all)
        XCTAssertEqual(parse(["--toolsets="]), Toolset.all)
    }
}
