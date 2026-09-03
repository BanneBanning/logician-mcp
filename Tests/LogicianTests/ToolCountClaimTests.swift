import Foundation
import XCTest

@testable import Logician

/// The tool-count DRIFT GUARD.
///
/// Three user-visible strings used to say "85 tools" while the registry held
/// 81 (found by an external reviewer, 2026-09-04): the server instructions
/// every session reads before its first call, and two paragraphs of the agent
/// guide. A number written by hand in prose has no compiler behind it, so it
/// rots the moment a tool is added, folded or retired - and it rots in the one
/// place a model is most likely to believe it.
///
/// Two answers. Where the count is user-visible it is now DERIVED
/// (`ServerInstructions` interpolates `MCPServer.wholeRegistry.count`); where
/// it is only a comment the number was deleted rather than restated. This test
/// covers what neither can: the guide is markdown, it cannot interpolate, and
/// its counts have to be maintained by hand. So every count claim in a string
/// the user or the model actually receives is parsed back out and checked
/// against the registry itself.
final class ToolCountClaimTests: XCTestCase {

    /// Every phrasing this project uses to assert the size of the whole tool
    /// surface: "81 tools", "the 81 tool NAMES", "all 81 definitions". Add a
    /// phrasing here rather than inventing one the guard cannot see.
    private static let claimPattern =
        #"\b([0-9]+)[ -](?:tools?\b|tool NAMES|tool definitions|definitions\b)"#

    /// Sentences that count a SUBSET on purpose and must not be read as a
    /// claim about the whole surface. Each one is exempt by its exact wording,
    /// so a rewrite re-enters the guard instead of silently staying out of it.
    private static let exemptions = [
        // The tools that may return a `warning`, not the tools that exist.
        "28 tools can carry one"
    ]

    /// The strings a session actually receives: the instructions sent with
    /// every `initialize`, and the guide served as `logician://guide`.
    /// `MCPResourceTests` already pins `agentGuideMarkdown` to
    /// docs/AGENT-GUIDE.md byte for byte, so checking the constant checks the
    /// file.
    private var userVisibleTexts: [(label: String, text: String)] {
        [
            ("the server instructions (Sources/Logician/ServerInstructions.swift)", MCPServer.instructions),
            ("docs/AGENT-GUIDE.md, compiled in as `agentGuideMarkdown`", agentGuideMarkdown)
        ]
    }

    /// A literal tool count in a string the model reads must equal the number
    /// of tools the registry holds. Nothing else is acceptable: a model that
    /// is told there are more tools than exist goes looking for tools that are
    /// not there, and one told there are fewer never searches for the rest.
    func testUserVisibleToolCountsMatchTheRegistry() throws {
        let registryCount = MCPServer.wholeRegistry.count
        let regex = try NSRegularExpression(pattern: Self.claimPattern)
        var claimsChecked = 0

        for (label, text) in userVisibleTexts {
            let whole = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: whole) {
                guard let claimRange = Range(match.range, in: text),
                    let numberRange = Range(match.range(at: 1), in: text),
                    let claimed = Int(text[numberRange])
                else { continue }

                let claim = String(text[claimRange])
                // Widen to the sentence around the match so an exemption can
                // be recognised by the words it is actually written with.
                let contextStart = text.index(
                    claimRange.lowerBound, offsetBy: -40,
                    limitedBy: text.startIndex) ?? text.startIndex
                let contextEnd = text.index(
                    claimRange.upperBound, offsetBy: 40,
                    limitedBy: text.endIndex) ?? text.endIndex
                let context = String(text[contextStart..<contextEnd])
                if Self.exemptions.contains(where: context.contains) { continue }

                claimsChecked += 1
                XCTAssertEqual(
                    claimed, registryCount,
                    "\(label) says \"\(claim)\" but the registry holds \(registryCount) tools. "
                        + "Update the sentence (…\(context.replacingOccurrences(of: "\n", with: " "))…), "
                        + "or add its exact wording to ToolCountClaimTests.exemptions if it deliberately "
                        + "counts a subset."
                )
            }
        }

        // A guard that finds nothing passes for the wrong reason. Five claims
        // stand today (three in the guide's prose, one in its generated tool
        // reference, one in the instructions); if a rewrite drops below four,
        // the phrasing has moved out from under `claimPattern`.
        XCTAssertGreaterThanOrEqual(
            claimsChecked, 4,
            "ToolCountClaimTests matched only \(claimsChecked) tool-count claims - the wording "
                + "has changed and `claimPattern` no longer sees it, which means the guard is no "
                + "longer guarding anything."
        )
    }

    /// The guide also quotes the size of the `core` set, as the reason to
    /// reach for `--toolsets`. Same failure mode, same guard - against
    /// `Toolset.membership` this time, which is what the flag actually reads.
    func testTheGuidesCoreToolsetCountMatchesMembership() throws {
        let coreCount = Toolset.membership.values.filter { $0.contains(.core) }.count
        let regex = try NSRegularExpression(pattern: #"`core` alone is ([0-9]+)"#)
        let text = agentGuideMarkdown
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: whole)

        XCTAssertEqual(
            matches.count, 1,
            "docs/AGENT-GUIDE.md should state the `core` toolset's size exactly once "
                + "(\"`core` alone is N\"); found \(matches.count)"
        )
        for match in matches {
            guard let numberRange = Range(match.range(at: 1), in: text),
                let claimed = Int(text[numberRange])
            else { continue }
            XCTAssertEqual(
                claimed, coreCount,
                "docs/AGENT-GUIDE.md says `core` alone is \(claimed) tools; Toolset.membership "
                    + "puts \(coreCount) tools in `core`"
            )
        }
    }
}
