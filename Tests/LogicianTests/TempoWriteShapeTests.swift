import XCTest
@testable import Logician

/// The shape of the tempo WRITE path, pinned where Logic is not running.
///
/// Every rule here was a measured cost or a live failure, and each of them is
/// one careless edit away from coming back: the pane cycles that made a no-op
/// `set` cost 3.3 s, the unconditional transport press that refused a create
/// outright, and the meter cache a tempo write used to throw away. None of it
/// can be reached without Logic, so what a pure test CAN check is that the call
/// still goes through the mechanisms that fixed them — the same discipline
/// `LocalizationSurfaceTests` uses to keep the localized strings honest.
final class TempoWriteShapeTests: XCTestCase {

    /// K1, measured live 2026-09-03: `editTempoEvent` opened and closed the List
    /// Editors pane three or four separate times per write (before-read, the
    /// action, the BPM stepper, the after-read), and the phase sums matched wall
    /// time to within 10 ms — the cycles WERE the cost. One hold around the
    /// whole edit is what halved it.
    func testTheWholeTempoEditRunsInsideOneHeldPane() throws {
        let source = try read("Sources/Logician/AXTempoEvents.swift")
        XCTAssertTrue(
            source.contains("withListEditorsPaneHeld"),
            "the tempo edit must hold the List Editors pane across its phases"
        )
        XCTAssertEqual(
            occurrences(of: "withListEditorsPaneHeld {", in: source), 1,
            "exactly one hold: nested holds are a no-op, but two scopes means two pane cycles"
        )
        // The hold has to wrap the phases, not sit inside one of them.
        let hold = try XCTUnwrap(source.range(of: "withListEditorsPaneHeld {"))
        for phase in ["readTempoMap()", "convergeRowTempo", "performListEditorRowDelete"] {
            let site = try XCTUnwrap(
                source.range(of: phase, range: hold.upperBound..<source.endIndex),
                "\(phase) should run under the hold"
            )
            XCTAssertTrue(site.lowerBound > hold.upperBound)
        }
    }

    /// D1, live-reproduced 2026-09-03: `create` pressed "Go to Beginning"
    /// unconditionally and with no retry, and one of two attempts was refused
    /// with "'Go to Beginning' button in the control bar" while the identical
    /// call moments later worked. `parkPlayheadOnGrid` is the conditional,
    /// witness-checked shape four other call sites already use.
    func testTheCreatePlayheadZeroGoesThroughTheConditionalPark() throws {
        let source = try read("Sources/Logician/AXTempoEvents.swift")
        XCTAssertTrue(
            source.contains("parkPlayheadOnGrid(bar: bar, beat: beat)"),
            "create must park through the conditional, grid-verified path"
        )
        XCTAssertFalse(
            source.contains("pressControlBarButton"),
            "no raw, unconditional transport press belongs in the tempo write path"
        )
    }

    /// The same lookup that failed must now look again before it refuses.
    func testTheControlBarPressLooksMoreThanOnceBeforeRefusing() throws {
        let source = try read("Sources/Logician/AXTransport.swift")
        let signature = try XCTUnwrap(
            source.range(of: "func pressControlBarButton(")
        )
        let body = String(source[signature.lowerBound...].prefix(1600))
        XCTAssertTrue(
            body.contains("for attempt in 0..<max(1, attempts)"),
            "the press must re-walk the control bar rather than give up on one empty scan"
        )
        XCTAssertTrue(
            body.contains("looked \\(max(1, attempts)) times"),
            "the refusal should say how hard it looked"
        )
    }

    /// N1, live-confirmed 2026-09-03: a `logic_list_signatures` cache hit of
    /// 10.3 ms became a 1 120.4 ms fresh Signature List read purely because a
    /// no-op tempo `set` had run in between. A tempo event is not a signature.
    func testATempoWriteLeavesTheMeterCacheAlone() throws {
        let source = try read("Sources/Logician/ToolHandlersTransport.swift")
        let handler = try XCTUnwrap(source.range(of: "func handleTempoEvents("))
        let end = source.range(of: "func handleSetPlaying(", range: handler.upperBound..<source.endIndex)
        let body = String(source[handler.upperBound..<(end?.lowerBound ?? source.endIndex)])
        XCTAssertTrue(
            body.contains("invalidateTempoMapCache()"),
            "the tempo cache still goes, even when the write throws"
        )
        XCTAssertFalse(
            body.contains("invalidateMeterMapCache"),
            "a tempo write never touches the Signature List and must not cost the next reader one"
        )
    }

    /// N1 (the other half): a successful `logic_set_tempo` on a single-event map
    /// knows the map it leaves behind, so it corrects the cache instead of
    /// emptying it — measured ~780 ms saved for whoever reads next.
    func testASuccessfulSetTempoCorrectsTheCacheInsteadOfEmptyingIt() throws {
        let source = try read("Sources/Logician/ToolHandlersMixing.swift")
        let handler = try XCTUnwrap(source.range(of: "func handleSetTempo("))
        let body = String(source[handler.upperBound...])
        let patch = try XCTUnwrap(body.range(of: "rememberTempoMap("))
        let sample = try XCTUnwrap(body.range(of: "sampleTempoAgainstProjectStart()"))
        XCTAssertTrue(
            patch.lowerBound < sample.lowerBound,
            "the read-map branch patches; the two-point sample fallback has no map and still forgets"
        )
        XCTAssertTrue(
            body[sample.lowerBound...].contains("invalidateTempoMapCache()"),
            "the fallback branch must keep the blind invalidate"
        )
    }

    // MARK: -

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var index = haystack.startIndex
        while let found = haystack.range(of: needle, range: index..<haystack.endIndex) {
            count += 1
            index = found.upperBound
        }
        return count
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LogicianTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }
}
