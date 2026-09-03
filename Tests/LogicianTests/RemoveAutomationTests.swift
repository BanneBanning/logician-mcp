import XCTest
@testable import Logician

/// The pure half of `logic_remove_automation`: which scopes it serves, what a
/// lane read proved, and what the two reads say about the press between them.
///
/// All of it is decided on a SAMPLED reading whose blind spot is documented —
/// flat is what an empty lane and a flat curve both look like — so every
/// branch that rests on that blind spot is pinned here rather than discovered
/// on a track someone cared about.
final class RemoveAutomationTests: XCTestCase {

    // MARK: - Scope

    func testTheTrackScopeIsTheOneThisRouteServes() {
        XCTAssertNil(AutomationRemoval.scopeRefusal("track", parameterGiven: nil))
        XCTAssertNil(AutomationRemoval.scopeRefusal("track", parameterGiven: "volume"))
    }

    func testALaneScopeIsRefusedBecauseTheVisibleLaneCannotBeRead() throws {
        let refusal = try XCTUnwrap(AutomationRemoval.scopeRefusal("lane", parameterGiven: "pan"))
        XCTAssertTrue(refusal.contains("VISIBLE"))
        // The alternatives, both of them: clear the track, or aim it by hand.
        XCTAssertTrue(refusal.contains("scope 'track'"))
        XCTAssertTrue(refusal.contains("Show"))
    }

    func testABarRangeIsRefusedAndNamesTheOverwriteThatReplacesIt() throws {
        for scope in ["range", "bars"] {
            let refusal = try XCTUnwrap(AutomationRemoval.scopeRefusal(scope, parameterGiven: nil))
            XCTAssertTrue(refusal.contains("logic_record_automation"), scope)
            XCTAssertTrue(refusal.contains("OVERWRITES"), scope)
        }
    }

    func testTheProjectScopeIsRefusedBecauseNothingCouldVerifyIt() throws {
        let refusal = try XCTUnwrap(AutomationRemoval.scopeRefusal("project", parameterGiven: nil))
        XCTAssertTrue(refusal.contains("Delete All Track Automation"))
        XCTAssertTrue(refusal.contains("scope 'track'"))
    }

    /// A caller who passes `parameter` and expects a lane filter is the most
    /// likely misreading of this tool, so an unknown scope says what
    /// `parameter` actually does rather than only listing the legal values.
    func testAnUnknownScopeExplainsWhatTheParameterArgumentIsFor() throws {
        let refusal = try XCTUnwrap(AutomationRemoval.scopeRefusal("lane_only", parameterGiven: "send"))
        XCTAssertTrue(refusal.contains("scope must be 'track'"))
        XCTAssertTrue(refusal.contains("'send'"))
        XCTAssertTrue(refusal.contains("READS"))
    }

    // MARK: - Evidence

    func testEvidenceCountsWhatWasReadableAndSpansOnlyThat() {
        let evidence = AutomationRemoval.evidence(values: [-14.0, nil, -17.2, -20.0])
        XCTAssertEqual(evidence.sampled, 4)
        XCTAssertEqual(evidence.readable, 3)
        XCTAssertEqual(evidence.low, -20.0)
        XCTAssertEqual(evidence.high, -14.0)
        XCTAssertEqual(try XCTUnwrap(evidence.spread), 6.0, accuracy: 0.0001)
        XCTAssertTrue(evidence.isCurve(tolerance: 0.05))
        XCTAssertFalse(evidence.isFlat(tolerance: 0.05))
    }

    /// Nothing readable is NOT a spread of zero. A `0` here would make an
    /// unreadable lane look perfectly flat, which is the reading that would
    /// send a destructive press down the `already_empty` path — or, worse,
    /// call a removal verified.
    func testAnUnreadableLaneHasNoSpreadRatherThanZero() {
        let evidence = AutomationRemoval.evidence(values: [nil, nil])
        XCTAssertEqual(evidence.readable, 0)
        XCTAssertNil(evidence.spread)
        XCTAssertFalse(evidence.isFlat(tolerance: 0.05))
        XCTAssertFalse(evidence.isCurve(tolerance: 0.05))
    }

    func testToleranceDecidesWhereFlatEnds() {
        let evidence = AutomationRemoval.evidence(values: [-6.0, -6.04])
        XCTAssertTrue(evidence.isFlat(tolerance: 0.05))
        XCTAssertFalse(evidence.isCurve(tolerance: 0.05))
        XCTAssertTrue(evidence.isCurve(tolerance: 0.01))
    }

    // MARK: - Whether to press

    func testACurveIsTheEvidenceThatEarnsThePress() {
        let before = AutomationRemoval.evidence(values: [-14.0, -17.0, -20.0])
        XCTAssertEqual(
            AutomationRemoval.decide(before: before, tolerance: 0.05, force: false), .press
        )
    }

    func testAFlatLaneIsAlreadyEmptyAndNothingIsPressed() throws {
        let before = AutomationRemoval.evidence(values: [-6.0, -6.0, -6.0])
        guard case .alreadyEmpty(let note) = AutomationRemoval.decide(
            before: before, tolerance: 0.05, force: false
        ) else { return XCTFail("a flat lane must not be pressed") }
        XCTAssertTrue(note.contains("nothing was pressed"))
        // The caveat travels WITH the verdict: flat is not proof of empty.
        XCTAssertTrue(note.contains(AutomationRemoval.flatCaveat))
        XCTAssertTrue(note.contains("force: true"))
    }

    func testAnUnreadableLaneRefusesAndNamesTheWayPast() throws {
        let before = AutomationRemoval.evidence(values: [nil, nil, nil])
        guard case .refuse(let why) = AutomationRemoval.decide(
            before: before, tolerance: 0.05, force: false
        ) else { return XCTFail("an unreadable lane cannot prove a removal") }
        XCTAssertTrue(why.contains("nothing was pressed"))
        XCTAssertTrue(why.contains("logic_read_automation"))
        XCTAssertTrue(why.contains("force: true"))
    }

    func testForcePressesOnAnyEvidenceAtAll() {
        for values in [[-6.0, -6.0], [nil, nil], [-14.0, -20.0]] as [[Double?]] {
            XCTAssertEqual(
                AutomationRemoval.decide(
                    before: AutomationRemoval.evidence(values: values),
                    tolerance: 0.05, force: true
                ),
                .press
            )
        }
    }

    // MARK: - What the two reads say

    func testACurveThatReadsFlatAfterwardsIsARemovalProven() {
        let verdict = AutomationRemoval.verdict(
            before: AutomationRemoval.evidence(values: [-14.0, -17.0, -20.0]),
            after: AutomationRemoval.evidence(values: [-6.0, -6.0, -6.0]),
            tolerance: 0.05, forced: false
        )
        XCTAssertEqual(verdict.state, "removed")
        XCTAssertTrue(verdict.verified)
        XCTAssertNil(verdict.warning)
    }

    /// The press answers `.success` from the background and does nothing
    /// (measured 2026-09-03), so an unchanged curve must never read as done.
    func testACurveThatSurvivesThePressIsNotConfirmedAndNamesTheLikelyCause() throws {
        let verdict = AutomationRemoval.verdict(
            before: AutomationRemoval.evidence(values: [-14.0, -20.0]),
            after: AutomationRemoval.evidence(values: [-14.0, -20.0]),
            tolerance: 0.05, forced: false
        )
        XCTAssertEqual(verdict.state, "removal_not_confirmed")
        XCTAssertFalse(verdict.verified)
        let warning = try XCTUnwrap(verdict.warning)
        XCTAssertTrue(warning.contains("frontmost"))
    }

    func testAnUnreadableAfterReadProvesNothingEitherWay() throws {
        let verdict = AutomationRemoval.verdict(
            before: AutomationRemoval.evidence(values: [-14.0, -20.0]),
            after: AutomationRemoval.evidence(values: [nil, nil]),
            tolerance: 0.05, forced: false
        )
        XCTAssertEqual(verdict.state, "removal_not_confirmed")
        XCTAssertFalse(verdict.verified)
        XCTAssertTrue(try XCTUnwrap(verdict.warning).contains("cannot say"))
    }

    /// Flat before, flat after, pressed anyway: the readback agrees with
    /// itself and proves nothing. `verified` stays false rather than
    /// borrowing confidence from a lane that never moved.
    func testAForcedPressOnAFlatLaneIsReportedUnproven() throws {
        let verdict = AutomationRemoval.verdict(
            before: AutomationRemoval.evidence(values: [-6.0, -6.0]),
            after: AutomationRemoval.evidence(values: [-6.0, -6.0]),
            tolerance: 0.05, forced: true
        )
        XCTAssertEqual(verdict.state, "removed_unproven")
        XCTAssertFalse(verdict.verified)
        XCTAssertTrue(try XCTUnwrap(verdict.warning).contains(AutomationRemoval.flatCaveat))
    }

    // MARK: - Dialogs

    func testAnUnknownDialogIsCancelledAndQuotedBack() {
        let refusal = AutomationRemoval.unknownDialogRefusal(
            titles: ["Delete Automation"], texts: ["Delete all automation?", "This cannot be undone"]
        )
        XCTAssertTrue(refusal.contains("CANCELLED"))
        XCTAssertTrue(refusal.contains("Delete all automation?"))
        XCTAssertTrue(refusal.contains("This cannot be undone"))
    }

    func testATitlelessDialogStillReportsSomething() {
        let refusal = AutomationRemoval.unknownDialogRefusal(titles: [], texts: [])
        XCTAssertTrue(refusal.contains("no title"))
        XCTAssertTrue(refusal.contains("CANCELLED"))
    }

    // MARK: - The registration

    func testTheToolIsRegisteredAsADestructiveCompositionTool() throws {
        let server = MCPServer()
        let tool = try XCTUnwrap(
            server.toolRegistry().first { $0.name == "logic_remove_automation" }
        )
        XCTAssertEqual(tool.safety, .destructive)
        XCTAssertTrue(tool.mayWarn)
        XCTAssertTrue(tool.changesSound)
        XCTAssertEqual(Toolset.membership["logic_remove_automation"], [Toolset.composition])
        // The description has to say the removal is wider than the lane it
        // reads back, or the tool is a trap.
        XCTAssertTrue(tool.description.contains("TRACK-WIDE"))
        XCTAssertTrue(tool.description.contains("logic_read_automation"))
    }
}
