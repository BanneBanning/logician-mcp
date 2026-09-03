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

    // MARK: - Rung 1b: the key window belongs to somebody else

    // The table below is the LIVE one, measured 2026-09-03 against the sandbox
    // `Testlåt Copy`: each state was induced for real and the full ladder
    // was run against it. `nil` here means "a rung won, keep climbing"; a
    // `ForeignKeyWindow` means "every rung wrote successfully and Logic's
    // focused element never moved".
    //
    //   plug-in window (AXDialog)     no rung wins   1 565 ms -> 214 ms
    //   Mixer window (channel strip)  no rung wins   1 916 ms -> 742 ms
    //   after a List Editors read     ax_selected_children wins, 320-327 ms
    //   Tracks area                   already focused, no probe cost at all

    private func foreign(
        identity: TracksAreaFocus.ProjectWindowIdentity = .isNotProjectWindow,
        subrole: String, title: String = "", hasDocument: Bool = false
    ) -> TracksAreaFocus.ForeignKeyWindow? {
        TracksAreaFocus.foreignKeyWindow(
            identity: identity, subrole: subrole, title: title, hasDocument: hasDocument
        )
    }

    func testAPluginWindowIsUnrepairableAndNamesTheToolThatClosesIt() {
        // Measured: plug-in window focused, all three rungs wrote, focus never
        // moved, 1 565 ms burnt for an `unverified` reached in one window read.
        let window = foreign(subrole: "AXDialog", title: "Crash")
        XCTAssertEqual(window?.kind, LogicWindowKind.pluginOrAuxiliary)
        XCTAssertEqual(window?.wayOut, "close it with logic_close_plugin_window")
        XCTAssertEqual(window?.label, "plugin_or_auxiliary 'Crash'")
    }

    func testTheMixerIsUnrepairableAndNamesItsOwnToggle() {
        // The Mixer is a SECOND standard window carrying the same document, so
        // the document alone cannot tell it from the project window — the
        // title's view segment does, exactly as `projectWindow()` filters it.
        // Measured 2026-09-03: opening it moves the key focus onto one of its
        // channel strips and every rung then loses (1 916 ms of them).
        let window = foreign(
            subrole: "AXStandardWindow", title: "Testlåt Copy - Mixer: Tracks",
            hasDocument: true
        )
        XCTAssertEqual(window?.kind, LogicWindowKind.mixer)
        XCTAssertEqual(window?.wayOut, "close it with logic_set_mixer {open: false}")
    }

    func testTheProjectWindowItselfAlwaysKeepsTheLadder() {
        // The focus on a control-bar button (2026-09-01) or just after a List
        // Editors read (2026-09-03, `ax_selected_children`, 2/2) is still
        // INSIDE the project window, and those are the states a rung has won
        // from. Identity decides it, with no title read at all.
        XCTAssertNil(
            foreign(
                identity: .isProjectWindow, subrole: "AXStandardWindow",
                title: "Testlåt Copy - Tracks", hasDocument: true
            )
        )
        // …even for a window that would otherwise classify as foreign: being
        // the element `projectWindow()` returns outranks every attribute.
        XCTAssertNil(foreign(identity: .isProjectWindow, subrole: "AXDialog", title: "Crash"))
    }

    func testAnUnidentifiableProjectWindowKeepsTheLadderForAProjectShapedWindow() {
        // "Cannot see" is not "the focus is elsewhere": with no project window
        // resolvable, a standard document window that is not the Mixer is
        // treated as the project window and the ladder runs.
        XCTAssertNil(
            foreign(
                identity: .unknown, subrole: "AXStandardWindow",
                title: "Testlåt Copy - Tracks", hasDocument: true
            )
        )
        XCTAssertEqual(
            foreign(identity: .unknown, subrole: "AXDialog", title: "Crash")?.kind,
            LogicWindowKind.pluginOrAuxiliary
        )
    }

    func testAFloatingOrDocumentlessWindowIsForeignAndSaysToComeBackToTheProjectWindow() {
        // Key Commands is an AXFloatingWindow; a document-less standard window
        // is a Logic window with no project in it. Neither has a close tool of
        // its own, so the way out is the honest generic one.
        XCTAssertEqual(
            foreign(subrole: "AXFloatingWindow", title: "Key Command Assignments")?.wayOut,
            "bring Logic's project (Tracks) window to the front"
        )
        XCTAssertEqual(
            foreign(subrole: "AXStandardWindow", title: "Loop Browser")?.kind,
            LogicWindowKind.standard
        )
    }

    func testAnUntitledForeignWindowStillReadsAsSomething() {
        // `AXWindow 'dialog'` with no title is exactly what the 2026-09-01
        // measurement saw; the label must never come back empty.
        XCTAssertEqual(foreign(subrole: "AXDialog")?.label, "plugin_or_auxiliary")
        XCTAssertTrue(foreign(subrole: "AXDialog")?.dictionary["window_title"] is NSNull)
    }

    func testTheForeignVerdictIsStillUnverifiedWithNoWriteRoute() {
        // The verdict does not change — only its price. Every consumer of
        // `state` keeps working, and nothing claims a focus it does not have.
        let outcome = TracksAreaFocus.Outcome.foreignKeyWindow(
            element: "AXWindow 'dialog'",
            window: TracksAreaFocus.ForeignKeyWindow(
                kind: LogicWindowKind.pluginOrAuxiliary, title: "Crash",
                wayOut: "close it with logic_close_plugin_window"
            )
        )
        XCTAssertEqual(outcome.state, "unverified")
        XCTAssertEqual(outcome.route, "none")
        XCTAssertEqual(outcome.focusedElement, "AXWindow 'dialog'")
    }

    func testTheForeignSummaryNamesTheWindowAndTheWayOut() {
        let outcome = TracksAreaFocus.Outcome.foreignKeyWindow(
            element: "AXWindow 'dialog'",
            window: TracksAreaFocus.ForeignKeyWindow(
                kind: LogicWindowKind.mixer, title: "Testlåt Copy - Mixer: Tracks",
                wayOut: "close it with logic_set_mixer {open: false}"
            )
        )
        XCTAssertTrue(outcome.summary.contains("UNVERIFIED"), outcome.summary)
        XCTAssertTrue(outcome.summary.contains("Mixer: Tracks"), outcome.summary)
        XCTAssertTrue(outcome.summary.contains("logic_set_mixer {open: false}"), outcome.summary)
        // It must not read as a refusal: the command still fires.
        XCTAssertFalse(outcome.summary.contains("refused"), outcome.summary)
    }

    func testTheForeignDictionaryCarriesTheWindowMachineReadably() {
        let outcome = TracksAreaFocus.Outcome.foreignKeyWindow(
            element: nil,
            window: TracksAreaFocus.ForeignKeyWindow(
                kind: LogicWindowKind.pluginOrAuxiliary, title: "Crash",
                wayOut: "close it with logic_close_plugin_window"
            )
        )
        let dictionary = outcome.dictionary
        XCTAssertEqual(dictionary["state"] as? String, "unverified")
        XCTAssertTrue(dictionary["focused_element"] is NSNull)
        let blocked = dictionary["blocked_by"] as? [String: Any]
        XCTAssertEqual(blocked?["window_kind"] as? String, "plugin_or_auxiliary")
        XCTAssertEqual(blocked?["window_title"] as? String, "Crash")
        XCTAssertEqual(
            blocked?["way_out"] as? String, "close it with logic_close_plugin_window"
        )
        // The repairable verdicts gain nothing: `blocked_by` is present only
        // when something really is blocking.
        XCTAssertNil(
            TracksAreaFocus.Outcome.unverified(element: nil).dictionary["blocked_by"]
        )
        XCTAssertNil(
            TracksAreaFocus.Outcome.alreadyFocused(element: "x").dictionary["blocked_by"]
        )
    }

    func testAPasteThatDidNothingUnderAForeignWindowStillBlamesFocusFirst() {
        let reason = TracksAreaFocus.pasteFailedReason(
            toBar: 20, barAlreadyOccupied: false,
            focus: .foreignKeyWindow(
                element: "AXWindow 'dialog'",
                window: TracksAreaFocus.ForeignKeyWindow(
                    kind: LogicWindowKind.pluginOrAuxiliary, title: "Crash",
                    wayOut: "close it with logic_close_plugin_window"
                )
            ),
            dialogTitles: []
        )
        XCTAssertTrue(reason.contains("FIRST SUSPECT"), reason)
        XCTAssertTrue(reason.contains("logic_close_plugin_window"), reason)
        XCTAssertTrue(reason.hasSuffix("Clipboard state uncertain"), reason)
    }

    func testTheForeignSummaryComesBackOutOfASelectionResult() {
        // The carried-around form every nudge/split/multi-select refusal reads.
        let selection: [String: Any] = [
            "key_focus": TracksAreaFocus.Outcome.foreignKeyWindow(
                element: "AXWindow 'dialog'",
                window: TracksAreaFocus.ForeignKeyWindow(
                    kind: LogicWindowKind.pluginOrAuxiliary, title: "Crash",
                    wayOut: "close it with logic_close_plugin_window"
                )
            ).dictionary
        ]
        XCTAssertTrue(
            TracksAreaFocus.summary(inSelectionResult: selection)
                .contains("logic_close_plugin_window")
        )
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
