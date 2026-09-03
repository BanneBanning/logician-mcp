import ApplicationServices
import XCTest
@testable import Logician

/// A hidden Inspector is ordinary user state (View > Inspector, or the I key),
/// and until 2026-09-03 it made `logic_select_track` refuse after 15.7 s while
/// naming the very row it had just selected, `logic_track_info` cost 29.9 s for
/// the same reason, and `logic_record_automation` fail outright.
///
/// The repair is three decisions and they are all decidable without an
/// inspector, which is why they are pinned here: what a strips walk means,
/// what a selection proved when only one plane could answer, and what one tool
/// call is allowed to do about it.
final class InspectorVisibilityTests: XCTestCase {

    // MARK: What a strips walk means

    func testStripsFoundMeansTheInspectorIsShown() {
        XCTAssertEqual(InspectorPresence.verdict(stripNames: ["Bas"]), .shown)
        XCTAssertEqual(InspectorPresence.verdict(stripNames: ["Bas", "Stereo Out"]), .shown)
    }

    /// The walk succeeded and found nothing. That is the hidden Inspector.
    func testAWalkThatFoundNoStripsMeansHidden() {
        XCTAssertEqual(InspectorPresence.verdict(stripNames: []), .hidden)
    }

    /// The walk could not be taken at all — no project window, no trust. This
    /// must never be reported as `hidden`, which reads as "the user hid it"
    /// and sends them to a menu item that will not help.
    func testAWalkThatCouldNotBeTakenIsUnavailableNotHidden() {
        XCTAssertEqual(InspectorPresence.verdict(stripNames: nil), .unavailable)
        XCTAssertNotEqual(InspectorPresence.verdict(stripNames: nil), .hidden)
    }

    // MARK: What an inspector-PANE look means

    /// The Region inspector reads the pane, not a strip, and asks its own
    /// question — the same three answers off a different look.
    func testAPublishedInspectorPaneMeansShown() {
        XCTAssertEqual(InspectorPresence.verdict(inspectorPanePublished: true), .shown)
        XCTAssertEqual(InspectorPresence.verdict(inspectorPanePublished: false), .hidden)
    }

    func testAPaneLookThatCouldNotBeTakenIsUnavailableNotHidden() {
        XCTAssertEqual(InspectorPresence.verdict(inspectorPanePublished: nil), .unavailable)
        XCTAssertNotEqual(InspectorPresence.verdict(inspectorPanePublished: nil), .hidden)
    }

    /// The two looks are allowed to DISAGREE, and that is the point: an
    /// Inspector on screen with its Channel Strip section collapsed publishes
    /// no strip and a perfectly readable 'Region:' panel. Deriving the Region
    /// inspector's precondition from the strips walk would have pressed
    /// `View > Inspector` at a pane that was already open — hiding it.
    func testACollapsedStripSectionIsHiddenToOneReaderAndShownToTheOther() {
        XCTAssertEqual(InspectorPresence.verdict(stripNames: []), .hidden)
        XCTAssertEqual(InspectorPresence.verdict(inspectorPanePublished: true), .shown)
    }

    /// The three verdicts are what the result publishes, verbatim.
    func testTheVerdictsAreTheirOwnResultValues() {
        XCTAssertEqual(InspectorPresence.shown.rawValue, "shown")
        XCTAssertEqual(InspectorPresence.hidden.rawValue, "hidden")
        XCTAssertEqual(InspectorPresence.unavailable.rawValue, "unavailable")
    }

    // MARK: What a selection proved

    private var anyElement: AXUIElement { AXUIElementCreateApplication(0) }

    /// The fix itself: a header row that says selected, with no inspector
    /// plane to cross-check it, is a VERIFIED selection. The old code had no
    /// case for it and polled the whole budget out instead.
    func testAHeaderOnlyVerificationIsVerified() {
        XCTAssertTrue(LogicAccessibility.SelectionVerification.verifiedHeaderOnly.isVerified)
    }

    /// …and it hands back no strip, because there is none. A caller that
    /// wanted one must go looking rather than be handed a guess — the rule
    /// `verifiedStaleName` already established.
    func testAHeaderOnlyVerificationHandsBackNoStrip() {
        XCTAssertNil(LogicAccessibility.SelectionVerification.verifiedHeaderOnly.strip)
        XCTAssertNil(LogicAccessibility.SelectionVerification.verifiedStaleName.strip)
        XCTAssertNotNil(LogicAccessibility.SelectionVerification.verified(strip: anyElement).strip)
    }

    /// Everything the old verification rejected, it still rejects.
    func testNotSelectedIsStillNotVerified() {
        XCTAssertFalse(LogicAccessibility.SelectionVerification.notSelected.isVerified)
    }

    /// A selection proved off the header row alone must not publish a route
    /// claiming the inspector confirmed it. That field is how an agent sees
    /// which planes agreed.
    func testTheReadbackRouteNamesTheHeaderRowWhenThatIsAllThereWas() {
        XCTAssertEqual(
            LogicAccessibility.SelectionVerification.verifiedHeaderOnly.readbackRoute,
            "ax_selected_header_row"
        )
    }

    func testTheReadbackRouteIsUnchangedWhereverTheInspectorAnswered() {
        XCTAssertEqual(
            LogicAccessibility.SelectionVerification.verified(strip: anyElement).readbackRoute,
            "ax_selected_and_inspector_strip"
        )
        XCTAssertEqual(
            LogicAccessibility.SelectionVerification.verifiedStaleName.readbackRoute,
            "ax_selected_and_inspector_strip"
        )
    }

    /// A look that never asked the inspector says so with `nil`, which is a
    /// different fact from an inspector that was asked and had nothing to say.
    func testAnUnselectedHeaderRowAsksTheInspectorNothing() {
        let evidence = LogicAccessibility.SelectionEvidence.headerNotSelected
        XCTAssertFalse(evidence.isVerified)
        XCTAssertNil(evidence.inspector)
        XCTAssertNil(evidence.strip)
    }

    // MARK: What one call is allowed to do about it

    /// The state the call FOUND, not the state it left behind: after this hold
    /// shows the Inspector every later walk says `shown`, and reporting that
    /// would hide the very condition the field exists to surface.
    func testTheHoldRemembersTheFirstObservationOnly() {
        let hold = InspectorHold()
        hold.observe(.hidden)
        hold.observe(.shown)
        hold.observe(.shown)
        XCTAssertEqual(hold.observed, .hidden)
    }

    /// A call that never walked the inspector plane reports nothing about it.
    /// An absent `inspector` means the question was not asked; it must never
    /// default to `shown`.
    func testACallThatNeverLookedReportsNothing() {
        XCTAssertTrue(InspectorHold().resultFields.isEmpty)
    }

    func testACallThatOnlyLookedReportsWhatItSaw() {
        let hold = InspectorHold()
        hold.observe(.shown)
        XCTAssertEqual(hold.resultFields["inspector"] as? String, "shown")
        XCTAssertNil(hold.resultFields["inspector_shown_for_call"])
        XCTAssertNil(hold.resultFields["inspector_restored"])
    }

    /// A call that showed the Inspector says so, and says whether it got it
    /// back — an unconfirmed restore is reported false, never omitted, because
    /// that line is how the user learns their Inspector is standing open.
    func testACallThatShowedTheInspectorReportsTheRestore() {
        let hold = InspectorHold()
        hold.observe(.hidden)
        hold.noteAttempt()
        hold.noteOpened(for: .channelStrip)
        hold.noteRestored(true)
        XCTAssertEqual(hold.resultFields["inspector"] as? String, "hidden")
        XCTAssertEqual(hold.resultFields["inspector_shown_for_call"] as? Bool, true)
        XCTAssertEqual(hold.resultFields["inspector_restored"] as? Bool, true)
    }

    func testARestoreThatWasNeverConfirmedIsReportedFalse() {
        let hold = InspectorHold()
        hold.observe(.hidden)
        hold.noteAttempt()
        hold.noteOpened(for: .channelStrip)
        XCTAssertEqual(hold.resultFields["inspector_restored"] as? Bool, false)
    }

    /// A press that produced no strip leaves nothing owed: the show undoes
    /// itself, so there is no restore to report and no second press to make.
    func testAnAttemptThatDidNotOpenAnythingOwesNoRestore() {
        let hold = InspectorHold()
        hold.observe(.hidden)
        hold.noteAttempt()
        XCTAssertFalse(hold.openedByUs)
        XCTAssertNil(hold.resultFields["inspector_shown_for_call"])
        XCTAssertNil(hold.resultFields["inspector_restored"])
    }

    /// A show is proved by ONE plane, and the restore has to be confirmed
    /// against the same one: a Region-inspector call confirmed against the
    /// strips walk would believe any press at all, because a pane whose
    /// Channel Strip section is collapsed publishes no strip either way.
    func testTheHoldRemembersWhichPlaneProvedTheShow() {
        let strip = InspectorHold()
        strip.noteAttempt()
        strip.noteOpened(for: .channelStrip)
        XCTAssertEqual(strip.shownFor, .channelStrip)

        let pane = InspectorHold()
        pane.observe(.hidden)
        pane.noteAttempt()
        pane.noteOpened(for: .inspectorPane)
        XCTAssertEqual(pane.shownFor, .inspectorPane)
        XCTAssertEqual(pane.resultFields["inspector_shown_for_call"] as? Bool, true)
    }

    /// A call that showed nothing names no plane — there is no press to
    /// confirm, so there is nothing to confirm it against.
    func testAHoldThatShowedNothingNamesNoPlane() {
        let hold = InspectorHold()
        XCTAssertNil(hold.shownFor)
        hold.noteAttempt()
        XCTAssertNil(hold.shownFor)
    }

    /// One press per call. The alternative is a tool that drums on Logic's
    /// View menu every time a strip read misses.
    func testTheAttemptIsRecordedSoItIsNotRepeated() {
        let hold = InspectorHold()
        XCTAssertFalse(hold.attempted)
        hold.noteAttempt()
        XCTAssertTrue(hold.attempted)
    }

    // MARK: The refusal, when showing it did not work

    func testTheRefusalNamesTheMenuItemAndTheKey() {
        let message = LogicAccessibility
            .hiddenInspectorRefusal(requested: "the channel strip for 'Bas'", showAttempted: false)
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("View > Inspector"), message)
        XCTAssertTrue(message.contains("I key"), message)
        XCTAssertTrue(message.contains("Bas"), message)
        XCTAssertTrue(message.contains("Nothing was read or written"), message)
    }

    /// A user who is told to press a menu item this call already pressed
    /// deserves to hear that it was pressed.
    func testTheRefusalSaysWhenTheShowWasAlreadyTried() {
        let tried = LogicAccessibility
            .hiddenInspectorRefusal(requested: "the channel strip for 'Bas'", showAttempted: true)
            .errorDescription ?? ""
        XCTAssertTrue(tried.contains("pressed View > Inspector"), tried)
        let untried = LogicAccessibility
            .hiddenInspectorRefusal(requested: "the channel strip for 'Bas'", showAttempted: false)
            .errorDescription ?? ""
        XCTAssertFalse(untried.contains("pressed View > Inspector"), untried)
    }

    /// The collapsed-Channel-Strip case is the same fact from Accessibility's
    /// side, and the refusal must not send someone hunting for a hidden
    /// Inspector that is plainly on screen.
    func testTheRefusalCoversACollapsedChannelStripSection() {
        let message = LogicAccessibility
            .hiddenInspectorRefusal(requested: "the channel strip for 'Bas'", showAttempted: true)
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("Channel Strip section is collapsed"), message)
    }

    // MARK: When Logic itself refuses the press

    /// `View > Inspector` is GREYED OUT while a plug-in window is Logic's key
    /// window (measured 2026-09-03 — and Accessibility named the project
    /// window as focused throughout, so no focus comparison could have caught
    /// it). A press Logic refuses leaves the Inspector standing open, which is
    /// a state the user can fix the moment they are told what is holding it —
    /// so the reason travels on the result.
    func testAPressLogicRefusedIsReportedWithItsReason() {
        let hold = InspectorHold()
        hold.observe(.hidden)
        hold.noteAttempt()
        hold.noteOpened(for: .channelStrip)
        hold.noteObstacle("the menu item is DISABLED right now")
        hold.noteRestored(false)
        XCTAssertEqual(hold.resultFields["inspector_restored"] as? Bool, false)
        XCTAssertEqual(
            hold.resultFields["inspector_note"] as? String, "the menu item is DISABLED right now"
        )
    }

    /// The FIRST reason, not the last: a failed show presses back, and that
    /// second refusal would otherwise overwrite the explanation for the first.
    func testOnlyTheFirstObstacleIsKept() {
        let hold = InspectorHold()
        hold.observe(.hidden)
        hold.noteObstacle("first")
        hold.noteObstacle("second")
        XCTAssertEqual(hold.resultFields["inspector_note"] as? String, "first")
    }

    /// A call Logic never refused says nothing about obstacles — an absent
    /// note is not an empty one.
    func testACallWithNoObstacleReportsNoNote() {
        let hold = InspectorHold()
        hold.observe(.shown)
        XCTAssertNil(hold.resultFields["inspector_note"])
    }

    // MARK: The Region inspector's own refusal

    /// The pane is the Region inspector's whole precondition, so its refusal
    /// names the same way out — and it is only ever reached with the pane
    /// genuinely absent.
    func testTheRegionRefusalNamesTheMenuItemAndTheKey() {
        let message = LogicAccessibility
            .hiddenInspectorRegionRefusal(showAttempted: false)
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("View > Inspector"), message)
        XCTAssertTrue(message.contains("I key"), message)
        XCTAssertTrue(message.contains("Region:"), message)
        XCTAssertTrue(message.contains("Nothing was read or written"), message)
    }

    func testTheRegionRefusalSaysWhenTheShowWasAlreadyTried() {
        let tried = LogicAccessibility
            .hiddenInspectorRegionRefusal(showAttempted: true)
            .errorDescription ?? ""
        XCTAssertTrue(tried.contains("pressed View > Inspector"), tried)
        let untried = LogicAccessibility
            .hiddenInspectorRegionRefusal(showAttempted: false)
            .errorDescription ?? ""
        XCTAssertFalse(untried.contains("pressed View > Inspector"), untried)
    }

    /// It must NOT borrow the strip refusal's collapsed-section theory: the
    /// Region panel is published whenever the pane is, so "your Channel Strip
    /// section is collapsed" would send someone to fix an unrelated triangle.
    func testTheRegionRefusalDoesNotBlameTheChannelStripSection() {
        let message = LogicAccessibility
            .hiddenInspectorRegionRefusal(showAttempted: true)
            .errorDescription ?? ""
        XCTAssertFalse(message.contains("Channel Strip"), message)
        XCTAssertFalse(message.contains("channel strip"), message)
    }
}
