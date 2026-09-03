import XCTest
@testable import Logician

/// `logic_new_project` writes a project, opens it, and — when `initial_track`
/// is a software instrument — Logic opens that track's own plug-in window and
/// leaves it standing (measured 2026-09-03, `Inst 1`, `AXDialog`; an `audio`
/// create opens none). Left open, that window is exactly what every region
/// tool's `key_focus: unverified` / `blocked_by` names (the region-focus fix,
/// 0bafa09) — a brand-new project starting life already degraded, and until
/// now neither reported nor closed.
///
/// `closeStrayPluginWindows()` (AXPlugins.swift) does the live detection —
/// `LogicWindowKind.classify`, the same rule `logic_list_windows` publishes —
/// and the live close, reusing `closePluginWindow(title:)` itself rather than
/// forking it. These pin the pure half it hands its outcome to:
/// `ProjectOpen.strayPluginWindowClosedEntry` (the `dialogs_closed` line) and
/// `ProjectOpen.strayPluginWindowWarning` (whether a `warning` naming
/// `logic_close_plugin_window` is owed). Neither touches Logic, Accessibility
/// or the environment — pure, runnable with no live session at all.
final class StrayPluginWindowTests: XCTestCase {

    // MARK: - strayPluginWindowClosedEntry

    func testClosedEntryReportsTheHouseShape() {
        let entry = ProjectOpen.strayPluginWindowClosedEntry(title: "Inst 1", closed: true)
        XCTAssertEqual(entry["phase"] as? String, "post_create")
        XCTAssertEqual(entry["dialog"] as? String, "plugin_window")
        XCTAssertEqual(entry["window"] as? String, "Inst 1")
        XCTAssertEqual(entry["state"] as? String, "closed")
        let effect = entry["effect"] as? String
        XCTAssertNotNil(effect)
        XCTAssertTrue(effect!.contains("closed"))
    }

    func testUnclosedEntryReportsOpenAndNeverClaimsSuccess() {
        let entry = ProjectOpen.strayPluginWindowClosedEntry(title: "Inst 1", closed: false)
        XCTAssertEqual(entry["window"] as? String, "Inst 1")
        XCTAssertEqual(entry["state"] as? String, "open")
        XCTAssertNotEqual(entry["state"] as? String, "closed")
    }

    /// A window that could not even be resolved for closing (raced shut, or
    /// `closePluginWindow` threw `windowAmbiguous`) still gets a line, and the
    /// underlying reason rides along rather than being swallowed.
    func testUnclosedEntryCarriesTheFailureDetail() {
        let entry = ProjectOpen.strayPluginWindowClosedEntry(
            title: "Inst 1", closed: false, detail: "2 windows titled 'Inst 1'"
        )
        let effect = entry["effect"] as? String
        XCTAssertNotNil(effect)
        XCTAssertTrue(effect!.contains("2 windows titled 'Inst 1'"))
        XCTAssertEqual(entry["state"] as? String, "open")
    }

    /// Every entry names the window: nothing here is ever `{}` for a caller
    /// that has to know WHICH window is still standing.
    func testEveryEntryNamesItsWindowRegardlessOfOutcome() {
        for closed in [true, false] {
            let entry = ProjectOpen.strayPluginWindowClosedEntry(title: "Bass Player 1", closed: closed)
            XCTAssertEqual(entry["window"] as? String, "Bass Player 1")
        }
    }

    // MARK: - strayPluginWindowWarning

    func testNoWarningWhenNothingWasThereToClose() {
        XCTAssertNil(ProjectOpen.strayPluginWindowWarning(dialogsClosed: []))
    }

    func testNoWarningWhenEveryWindowClosed() {
        let entries = [
            ProjectOpen.strayPluginWindowClosedEntry(title: "Inst 1", closed: true)
        ]
        XCTAssertNil(ProjectOpen.strayPluginWindowWarning(dialogsClosed: entries))
    }

    /// The one case the tool must never go silent on: a window it tried and
    /// failed to close gets a `warning` naming the escape hatch by its exact
    /// tool name, so an agent reading only `warning` still knows what to call.
    func testWarningNamesLogicClosePluginWindowWhenAWindowIsStillOpen() {
        let entries = [
            ProjectOpen.strayPluginWindowClosedEntry(title: "Inst 1", closed: false)
        ]
        let warning = ProjectOpen.strayPluginWindowWarning(dialogsClosed: entries)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("logic_close_plugin_window"))
    }

    /// One unclosed window among several closed ones still trips the warning
    /// — a caller must not have to scan `dialogs_closed` itself to notice.
    func testWarningTripsIfAnySingleWindowFailedAmongSeveral() {
        let entries = [
            ProjectOpen.strayPluginWindowClosedEntry(title: "Inst 1", closed: true),
            ProjectOpen.strayPluginWindowClosedEntry(title: "Inst 2", closed: false)
        ]
        XCTAssertNotNil(ProjectOpen.strayPluginWindowWarning(dialogsClosed: entries))
    }

    // MARK: - selectedTrackTypeExpectsStrayWindow

    private func offer(_ category: String, _ variant: String) -> ProjectOpen.TrackTypeOffer {
        ProjectOpen.TrackTypeOffer(category: category, variant: variant, variantSelectedInCategory: true)
    }

    /// The two categories measured to raise the window both offer a variant
    /// literally spelled "Software Instrument" — that's the whole test, not
    /// the category name (which the gate ignores on purpose).
    func testSoftwareInstrumentVariantExpectsAWindowRegardlessOfCategory() {
        XCTAssertTrue(
            ProjectOpen.selectedTrackTypeExpectsStrayWindow(offer("MIDI", "Software Instrument"))
        )
        XCTAssertTrue(
            ProjectOpen.selectedTrackTypeExpectsStrayWindow(offer("Pattern", "Software Instrument"))
        )
    }

    /// MEASURED 2026-09-03, 5/5: an audio create opens no plug-in window at
    /// all, so it gets the cheap `waitingUpTo: 0` path.
    func testAudioVariantExpectsNoWindow() {
        XCTAssertFalse(
            ProjectOpen.selectedTrackTypeExpectsStrayWindow(offer("Audio", "Mic or Line"))
        )
        XCTAssertFalse(
            ProjectOpen.selectedTrackTypeExpectsStrayWindow(offer("Audio", "Guitar or Bass"))
        )
    }

    /// Untested categories (Session Player's three variants) say nothing
    /// about whether Logic opens a window for them, so the gate answers
    /// false rather than guessing — the honest "not measured" default.
    func testUntestedCategoriesDefaultToNoWindowRatherThanAGuess() {
        XCTAssertFalse(
            ProjectOpen.selectedTrackTypeExpectsStrayWindow(offer("Session Player", "Drummer"))
        )
    }

    /// No sheet selection at all (the sheet never answered, or degraded to
    /// `trackTypeUnreadable`) is the same "do not wait" answer as a kind
    /// known not to raise a window — never a crash on the nil.
    func testNoSelectionExpectsNoWindow() {
        XCTAssertFalse(ProjectOpen.selectedTrackTypeExpectsStrayWindow(nil))
    }

    /// The match is on the sheet's own words, case- and separator-insensitive
    /// the way `normalizedTrackTypeName` already treats every other track
    /// type comparison in this file — 'software_instrument' style spellings
    /// are not expected here (this gate reads what the SHEET selected, never
    /// what a caller requested), but the comparison must still not be
    /// case-sensitive by accident.
    func testTheMatchIsCaseInsensitive() {
        XCTAssertTrue(
            ProjectOpen.selectedTrackTypeExpectsStrayWindow(offer("MIDI", "software instrument"))
        )
    }
}
