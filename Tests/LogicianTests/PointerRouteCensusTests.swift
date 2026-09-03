import XCTest
@testable import Logician

/// THE CENSUS OF POINTER ROUTES. Every file in `Sources/` that synthesizes a
/// mouse event, counted, so a fourth one cannot appear quietly.
///
/// Why a test and not a grep: the server's promise is that it drives Logic
/// through its data plane — the control surface, key commands, Accessibility —
/// and *"no coordinate-driven UI scripting"* is the first line of the agent
/// guide. Two routes are exceptions the guide names and both say so in their
/// result's `write_route`. The way that promise decays is one more `CGEvent`
/// added in a hurry, in a file nobody thought to re-read, with no line in the
/// guide. This makes that a failing test instead.
final class PointerRouteCensusTests: XCTestCase {

    /// The files allowed to synthesize pointer input, as of the merge on
    /// 2026-09-03:
    ///
    /// - `AXTracks.swift` — `logic_set_track_stack`'s hit-tested click on the
    ///   disclosure triangle, the only route Logic leaves for folding a stack;
    /// - `AXPlugins.swift` — the explicit `allow_mouse: true` fallback, off by
    ///   default.
    ///
    /// `AXTransport.swift` was the third until this commit: `setCycleRange`
    /// dragged the ruler to change a cycle's LENGTH, and scrolled it with a
    /// synthetic wheel event to recover from its own drag. Both are gone — the
    /// range is written as numbers into the LCD's locator cells — which is why
    /// the file is named in `testTheCycleRangeNoLongerTakesThePointer` below
    /// rather than merely absent from this list.
    ///
    /// SHRINKING this set is fine and does not fail (the stack-fold work may
    /// yet remove `AXTracks.swift`'s click); GROWING it fails, and the fix is
    /// to justify the new route here, in the tool's description, and in the
    /// agent guide's opening paragraph.
    private let allowed: Set<String> = ["AXTracks.swift", "AXPlugins.swift"]

    /// What counts as synthesizing pointer input.
    private let pointerAPIs = ["mouseEventSource:", "scrollWheelEvent2Source:"]

    func testNoFileOutsideTheCensusSynthesizesAMouseEvent() throws {
        let (found, scanned) = try pointerRouteFiles()
        XCTAssertGreaterThan(scanned, 40, "the scan found almost no source files — it is vacuous")
        let unexpected = found.subtracting(allowed).sorted()
        XCTAssertTrue(
            unexpected.isEmpty,
            "these files synthesize pointer input and are not in the census: "
                + unexpected.joined(separator: ", ")
                + ". A pointer route needs a line in this test, in the tool's description, and in "
                + "the agent guide's opening paragraph — the server's promise is no coordinate-driven "
                + "UI scripting."
        )
    }

    /// The regression this commit exists to prevent. `logic_set_cycle_range`
    /// took the user's pointer to change a cycle's length, ungated and
    /// undocumented — and by 2026-09-03 the drag had stopped working anyway
    /// (three consecutive length changes refused: the hit test landed on an
    /// `AXTable`). It writes numbers now.
    func testTheCycleRangeNoLongerTakesThePointer() throws {
        let (found, _) = try pointerRouteFiles()
        XCTAssertFalse(
            found.contains("AXTransport.swift"),
            "AXTransport.swift is synthesizing mouse events again — the cycle range is written "
                + "through the control bar LCD's locator cells, which needs no pointer at all"
        )
        XCTAssertFalse(
            found.contains("AXCycleRange.swift"),
            "AXCycleRange.swift is synthesizing mouse events — the whole point of the LCD locator "
                + "route is that setting a cycle range needs no pointer"
        )
    }

    /// The files that synthesize pointer input, and how many were scanned.
    /// Whole-line comments are dropped first, so the paragraphs that EXPLAIN a
    /// deleted mouse route (this file's own history is full of them) are not
    /// counted as one.
    private func pointerRouteFiles() throws -> (Set<String>, Int) {
        let sources = repositoryRoot.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        )
        var found: Set<String> = []
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            scanned += 1
            if pointerAPIs.contains(where: { code.contains($0) }) {
                found.insert(url.lastPathComponent)
            }
        }
        return (found, scanned)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LogicianTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }
}
