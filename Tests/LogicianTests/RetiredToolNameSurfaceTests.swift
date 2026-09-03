import Foundation
import XCTest
@testable import Logician

/// Guards every `logic_[a-z_]+`-shaped token in the server's user-facing text
/// against the one list that cannot drift out from under it: the tool
/// registry itself, read fresh each run rather than copied into a constant
/// here.
///
/// A fold or removal (2026-09-03: `logic_select_region` into
/// `logic_select_regions`, four `logic_set_track_*` writes into
/// `logic_set_track_mix`) leaves `tools/list` refusing the old name with
/// `Unknown tool` — but a description, a refusal message, or the guide can
/// keep spelling it for a long time after, because nothing forces those
/// strings to agree with the registry. `logic_set_send_level` (a name that
/// never existed — the real tool is `logic_mcu_set_send`) sat in exactly this
/// shape in a headerless-strip automation refusal until this pass.
final class RetiredToolNameSurfaceTests: XCTestCase {

    /// Every registered tool name, read from the live registry at test time
    /// so a future fold or addition never has to touch this file.
    private static var registeredToolNames: Set<String> {
        Set(MCPServer.wholeRegistry.map { $0.name })
    }

    /// `logic_`-shaped tokens that are not tool names, each documented where
    /// it actually lives so a future reader does not have to re-derive why
    /// it is exempt. None of these are call sites — they are JSON result
    /// keys, internal route tags, a wildcard reference to a tool FAMILY, or
    /// prose that reads like a name but names no callable tool.
    private static let allowedNonToolTokens: Set<String> = [
        // Result/health keys
        "logic_ui_language",  // health + track-info result key (ToolHandlersDiagnostics.swift)
        "logic_running",      // health result key (LogicAccessibility.swift, ProjectReset.swift)
        "logic_fix",          // logic_health's fixes dictionary key (ToolHandlersDiagnostics.swift)
        "logic_pid",          // logic_health's process-id key (LogicAccessibility.swift)
        // Internal route/identifier tags (string literals, never advertised)
        "logic_count_in",     // MIDI pre-roll route tag (MCUMIDIRecording.swift)
        "logic_default",      // "Notes Crossing Split Point" dialog route tag (AXRegions.swift)
        "logic_menu",         // quantize-list source tag, as opposed to a cached copy (AXRegionInspector.swift)
        // A wildcard family reference: "logic_mcu_*" reads as "logic_mcu_"
        // once the trailing `*` falls outside this pattern's character class
        // (StripAddressing.swift, AXInsertBypass.swift, AXMixerWindow.swift).
        "logic_mcu_",
        // Prose shorthand for "the transport", not a tool invocation
        // (MCUMIDIRecording.swift's stuck-note warning).
        "logic_transport",
        // Named only inside doc comments (ToolSearch.swift, ToolSearchTests.swift)
        // and a doc-comment line wrap of `logic_setup_key_commands`
        // (AXKeyCommandLearning.swift) — both already excluded by the
        // comment strip below; kept here too so this list matches the
        // census this test was built from.
        "logic_tool_schema",
        "logic_setup_key"
    ]

    /// Files with their own precise, table-aware test below; excluded from
    /// the wider handler sweep so the "Renamed and removed" table's old
    /// names — its entire reason to exist — are not re-flagged there.
    private static let separatelyCheckedFiles: Set<String> = [
        "ToolRegistry.swift", "ServerInstructions.swift", "AgentGuideText.swift"
    ]

    private static let tokenPattern = try! NSRegularExpression(pattern: "logic_[a-z_]+")

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LogicianTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }

    /// Whole-line comments dropped first, same rule `LocalizationSurfaceTests`
    /// uses: doc comments quote retired names ON PURPOSE (measured numbers,
    /// dated profiles, the fold history) and are not the surface this test
    /// guards — only what a caller actually reads back is.
    private func stripWholeLineComments(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func logicTokens(in text: String) -> Set<String> {
        let range = NSRange(text.startIndex..., in: text)
        let matches = Self.tokenPattern.matches(in: text, range: range)
        return Set(matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } })
    }

    /// Fails once per unknown token so a hit reads as a punch list, not one
    /// opaque assertion.
    private func assertNamesOnlyRealToolsOrAllowedKeys(
        _ text: String, describedAs label: String, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let code = stripWholeLineComments(text)
        let known = Self.registeredToolNames.union(Self.allowedNonToolTokens)
        for token in logicTokens(in: code).subtracting(known) {
            XCTFail(
                "\(label) names '\(token)', which is neither a registered tool nor on the"
                    + " allow-list — it reads like a tool that was folded or removed",
                file: file, line: line
            )
        }
    }

    // MARK: - The guaranteed user-facing surfaces

    func testToolRegistryDescriptionsNameOnlyRealToolsOrAllowedKeys() throws {
        let url = repositoryRoot.appendingPathComponent("Sources/Logician/ToolRegistry.swift")
        try assertNamesOnlyRealToolsOrAllowedKeys(
            String(contentsOf: url, encoding: .utf8), describedAs: "ToolRegistry.swift"
        )
    }

    func testServerInstructionsNameOnlyRealToolsOrAllowedKeys() throws {
        let url = repositoryRoot.appendingPathComponent("Sources/Logician/ServerInstructions.swift")
        try assertNamesOnlyRealToolsOrAllowedKeys(
            String(contentsOf: url, encoding: .utf8), describedAs: "ServerInstructions.swift"
        )
    }

    /// Both copies of the guide — the hand-authored source
    /// `docs/AGENT-GUIDE.md` and `AgentGuideText.swift`, which
    /// `embed_agent_guide.py` regenerates from it verbatim — minus the
    /// "Renamed and removed" table, whose entire job is to keep naming the
    /// old tools next to their replacements.
    func testAgentGuideNamesOnlyRealToolsOrAllowedKeysOutsideTheRenamedTable() throws {
        for relativePath in ["Sources/Logician/AgentGuideText.swift", "docs/AGENT-GUIDE.md"] {
            let url = repositoryRoot.appendingPathComponent(relativePath)
            let full = try String(contentsOf: url, encoding: .utf8)
            guard let tableStart = full.range(of: "## Renamed and removed"),
                let tableEnd = full.range(of: "## Mechanism and measured costs"),
                tableStart.upperBound <= tableEnd.lowerBound
            else {
                XCTFail("\(relativePath) no longer has the 'Renamed and removed' table markers")
                continue
            }
            let outsideTable = full[..<tableStart.lowerBound] + full[tableEnd.lowerBound...]
            assertNamesOnlyRealToolsOrAllowedKeys(String(outsideTable), describedAs: relativePath)
        }
    }

    // MARK: - Result notes scattered across the handlers

    /// The wider net named in the fix spec: every other `.swift` file under
    /// `Sources/Logician` (the three above have their own precise checks),
    /// string content only, comments stripped the same way. This is where a
    /// refusal or a `warning` built inside one handler can quietly keep
    /// naming a tool `tools/list` no longer answers to.
    func testNoHandlerFileNamesARetiredTool() throws {
        let logicianSources = repositoryRoot.appendingPathComponent("Sources/Logician")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: logicianSources, includingPropertiesForKeys: nil)
        )
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            guard !Self.separatelyCheckedFiles.contains(name) else { continue }
            scanned += 1
            try assertNamesOnlyRealToolsOrAllowedKeys(
                String(contentsOf: url, encoding: .utf8), describedAs: name
            )
        }
        XCTAssertGreaterThan(scanned, 50, "the source scan found almost nothing — wrong root?")
    }

    // MARK: - The allow-list and the registry stay honest

    func testNoAllowedNonToolTokenIsActuallyARegisteredTool() {
        for token in Self.allowedNonToolTokens {
            XCTAssertFalse(
                Self.registeredToolNames.contains(token),
                "'\(token)' is on the non-tool allow-list but is a real, registered tool name"
            )
        }
    }

    func testTheRegistryReadsAsMoreThanAHandful() {
        // A guard against the two ways this whole file could pass for the
        // wrong reason: an empty registry (every token would look "unknown"
        // and every string test above would already be failing loudly) or,
        // the quieter risk, wholeRegistry silently returning nothing and
        // every unknown-token check above going vacuously green.
        XCTAssertGreaterThan(Self.registeredToolNames.count, 50, "the registry read as empty")
    }
}
