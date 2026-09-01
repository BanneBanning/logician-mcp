import XCTest
@testable import Logician

/// The pure half of the Tracks-area keyboard focus guard: which elements count
/// as "the focus is where Cut/Copy/Paste/Nudge/Delete can see it", and what a
/// Paste that changed nothing is allowed to blame.
///
/// Real `AXUIElement`s cannot be built in a test, so the probe is split: the
/// live half reads three attributes per element and hands them here as
/// `ElementFacts`, and every decision made on them is pinned below.
///
/// The DISCRIMINATING property, and the reason this file exists: a wrong "yes"
/// lets a silent no-op copy through (the tool fires Copy and Paste into
/// nowhere and reports a modal that is not there), and a wrong "no" would make
/// the guard write to the track header column on every single call.
final class TracksAreaFocusTests: XCTestCase {

    private func facts(
        role: String, description: String = "", roleDescription: String = ""
    ) -> TracksAreaFocus.ElementFacts {
        TracksAreaFocus.ElementFacts(
            role: role, description: description, roleDescription: roleDescription
        )
    }

    // Logic's own descriptions, as `regionRows()` and `trackHeaderGroup()`
    // read them.
    private let regionRow = "Track 3 \u{201C}Crash\u{201D}"

    // MARK: - What counts as the Tracks area

    func testARegionItemIsTheTracksArea() {
        // A region publishes its type in AXRoleDescription; that is how
        // `regionRows()` tells regions from automation lanes.
        XCTAssertTrue(
            TracksAreaFocus.isTracksArea(
                facts(role: "AXLayoutItem", description: "Crash", roleDescription: "Region")
            )
        )
    }

    func testARegionRowIsTheTracksArea() {
        XCTAssertTrue(
            TracksAreaFocus.isTracksArea(facts(role: "AXLayoutArea", description: regionRow))
        )
    }

    func testATrackHeaderItemIsTheTracksArea() {
        // The header column's rows carry the same description with a different
        // role — the focus lands here after a header write.
        XCTAssertTrue(
            TracksAreaFocus.isTracksArea(facts(role: "AXLayoutItem", description: regionRow))
        )
    }

    func testTheTrackHeaderColumnIsTheTracksArea() {
        XCTAssertTrue(
            TracksAreaFocus.isTracksArea(facts(role: "AXGroup", description: "Tracks header"))
        )
    }

    func testAControlBarButtonIsNot() {
        // The state all three measured failures were in: the focus on a
        // control-bar button, every region key command a silent no-op.
        XCTAssertFalse(TracksAreaFocus.isTracksArea(facts(role: "AXButton", description: "Play")))
    }

    func testTheRulerAndAnUnnamedGroupAreNot() {
        XCTAssertFalse(
            TracksAreaFocus.isTracksArea(
                facts(role: "AXLayoutArea", description: "Tracks time ruler")
            )
        )
        XCTAssertFalse(TracksAreaFocus.isTracksArea(facts(role: "AXGroup")))
        XCTAssertFalse(
            TracksAreaFocus.isTracksArea(facts(role: "AXTextField", description: "Tempo"))
        )
    }

    func testATrackNamedLikeARowButWithoutQuotesIsNot() {
        // "Track " is a prefix a plugin parameter could carry ("Track Gain");
        // the quotes are what make it Logic's row description.
        XCTAssertFalse(
            TracksAreaFocus.isTracksArea(facts(role: "AXLayoutArea", description: "Track Gain"))
        )
    }

    func testALocalizedRowIsRecognizedWhenTheStringsAre() {
        // French: `Piste 1 « Lofi Pad »` with guillemets. The signature takes
        // its constants from LogicUIStrings, so a locale pass moves them in
        // one place.
        XCTAssertTrue(
            TracksAreaFocus.isTracksArea(
                facts(role: "AXLayoutArea", description: "Piste 1 \u{00AB}\u{00A0}Lofi Pad\u{00A0}\u{00BB}"),
                trackPrefix: "Piste ",
                openQuote: "\u{00AB}"
            )
        )
    }

    // MARK: - The ancestor walk

    func testAFocusedHasFocusButtonCountsThroughItsParentRow() {
        // Pressing a header's "Has Focus" radio leaves the BUTTON focused, and
        // a button alone is not the Tracks area — its parent row is. Without
        // the ancestor walk this repair route would report itself as failed.
        let chain = [
            facts(role: "AXRadioButton", description: "Has Focus"),
            facts(role: "AXLayoutItem", description: regionRow),
            facts(role: "AXGroup", description: "Tracks header")
        ]
        XCTAssertFalse(TracksAreaFocus.isTracksArea(chain[0]))
        XCTAssertTrue(TracksAreaFocus.chainIsTracksArea(chain))
    }

    func testAControlBarChainStaysOutside() {
        let chain = [
            facts(role: "AXButton", description: "Play"),
            facts(role: "AXGroup", description: "Control Bar"),
            facts(role: "AXWindow", description: "")
        ]
        XCTAssertFalse(TracksAreaFocus.chainIsTracksArea(chain))
    }

    func testAnEmptyChainIsNotTheTracksArea() {
        XCTAssertFalse(TracksAreaFocus.chainIsTracksArea([]))
    }

    // MARK: - Labels

    func testTheLabelNamesRoleAndName() {
        XCTAssertEqual(
            TracksAreaFocus.label(facts(role: "AXButton", description: "Play")),
            "AXButton 'Play'"
        )
        XCTAssertEqual(
            TracksAreaFocus.label(
                facts(role: "AXLayoutItem", description: "", roleDescription: "Region")
            ),
            "AXLayoutItem 'Region'"
        )
        XCTAssertEqual(TracksAreaFocus.label(facts(role: "AXButton")), "AXButton")
        XCTAssertEqual(TracksAreaFocus.label(nil), "unreadable")
    }

    // MARK: - The outcome contract

    func testStatesAndRoutes() {
        XCTAssertEqual(TracksAreaFocus.Outcome.alreadyFocused(element: "x").state, "already_focused")
        XCTAssertEqual(TracksAreaFocus.Outcome.alreadyFocused(element: "x").route, "none")
        let restored = TracksAreaFocus.Outcome.restored(route: "ax_selected_children", element: "y")
        XCTAssertEqual(restored.state, "restored")
        XCTAssertEqual(restored.route, "ax_selected_children")
        XCTAssertEqual(TracksAreaFocus.Outcome.unverified(element: nil).state, "unverified")
    }

    func testAnUnverifiedFocusPublishesNullRatherThanAnEmptyString() {
        // `{}` where `{"unavailable": reason}` belongs is the house's own
        // standing complaint; an unreadable focused element is NSNull, never "".
        let dictionary = TracksAreaFocus.Outcome.unverified(element: nil).dictionary
        XCTAssertTrue(dictionary["focused_element"] is NSNull)
        XCTAssertEqual(dictionary["state"] as? String, "unverified")
        XCTAssertEqual(dictionary["write_route"] as? String, "none")
        XCTAssertNotNil(dictionary["note"] as? String)
    }

    func testTheRestoredSummaryNamesTheRouteAndTheCommands() {
        let summary = TracksAreaFocus.Outcome
            .restored(route: "has_focus_press", element: "AXLayoutItem 'Track 3 “Crash”'").summary
        XCTAssertTrue(summary.contains("has_focus_press"))
        XCTAssertTrue(summary.contains("Cut/Copy/Paste"))
    }

    // MARK: - The refusal text (defect D1's second half)

    private let noFocus = TracksAreaFocus.Outcome.unverified(element: "AXButton 'Play'")
    private let goodFocus = TracksAreaFocus.Outcome
        .alreadyFocused(element: "AXLayoutItem 'Region'")

    func testAPasteThatDidNothingWithNoDialogOpenBlamesFocusAndSaysTheDialogListWasRead() {
        let reason = TracksAreaFocus.pasteFailedReason(
            toBar: 20, barAlreadyOccupied: false, focus: noFocus, dialogTitles: []
        )
        XCTAssertTrue(reason.contains("FIRST SUSPECT"), reason)
        XCTAssertTrue(reason.lowercased().contains("keyboard focus"), reason)
        XCTAssertTrue(reason.contains("AXButton 'Play'"), reason)
        // The message this replaces sent the profiling agent hunting for a
        // modal three times over while logic_list_windows showed none.
        XCTAssertTrue(reason.contains("No dialog or floating window is open"), reason)
        XCTAssertFalse(reason.contains("check Logic for one"), reason)
    }

    func testADialogThatIsUpIsNamedAndFocusIsClearedOfBlame() {
        let reason = TracksAreaFocus.pasteFailedReason(
            toBar: 20, barAlreadyOccupied: false, focus: goodFocus,
            dialogTitles: ["Notes Crossing Split Point"]
        )
        XCTAssertTrue(reason.contains("Notes Crossing Split Point"), reason)
        XCTAssertTrue(reason.contains("Keyboard focus is not the cause"), reason)
    }

    func testAnOccupiedTargetBarIsStillReportedAsSuch() {
        let reason = TracksAreaFocus.pasteFailedReason(
            toBar: 52, barAlreadyOccupied: true, focus: goodFocus, dialogTitles: []
        )
        XCTAssertTrue(reason.contains("bar 52 already held a region"), reason)
        XCTAssertTrue(reason.hasSuffix("Clipboard state uncertain"), reason)
    }

    func testEveryReasonEndsWithTheClipboardCaveat() {
        for occupied in [true, false] {
            for focus in [noFocus, goodFocus] {
                for titles in [[], ["Bounce"]] {
                    let reason = TracksAreaFocus.pasteFailedReason(
                        toBar: 9, barAlreadyOccupied: occupied, focus: focus, dialogTitles: titles
                    )
                    XCTAssertTrue(reason.hasSuffix("Clipboard state uncertain"), reason)
                }
            }
        }
    }

    // MARK: - The dialog half of the same question (shared with Delete)

    func testAnEmptyWindowListIsReportedAsAnObservation() {
        let sentence = TracksAreaFocus.dialogSentence([])
        XCTAssertTrue(sentence.contains("window list was read"), sentence)
        XCTAssertTrue(sentence.contains("No dialog"), sentence)
    }

    func testEveryOpenDialogIsNamed() {
        let sentence = TracksAreaFocus.dialogSentence(["Bounce", "Notes Crossing Split Point"])
        XCTAssertTrue(sentence.contains("'Bounce'"), sentence)
        XCTAssertTrue(sentence.contains("'Notes Crossing Split Point'"), sentence)
    }

    // MARK: - Reading the record back out of a selection result

    func testTheSummaryComesOutOfASelectionResult() {
        let selection: [String: Any] = [
            "key_focus": TracksAreaFocus.Outcome
                .restored(route: "select_track", element: "AXLayoutItem 'Region'").dictionary
        ]
        XCTAssertTrue(
            TracksAreaFocus.summary(inSelectionResult: selection).contains("select_track")
        )
    }

    func testASelectionTakenWithoutTheGuardSaysSoRatherThanImplyingFocusWasFine() {
        let summary = TracksAreaFocus.summary(inSelectionResult: ["name": "Crash"])
        XCTAssertTrue(summary.contains("not checked"), summary)
        XCTAssertFalse(summary.contains("already"), summary)
    }
}
