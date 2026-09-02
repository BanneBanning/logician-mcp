import XCTest
@testable import Logician

/// `logic_list_windows` is the server's own window-identification oracle — the
/// tool `windowNotClosable` names when it refuses to close something. It used
/// to answer with `documentPath != nil ? "project" : "plugin_or_auxiliary"`,
/// and both halves were wrong in a way that was observed live (2026-09-02: the
/// Mixer came back `kind: "project"`). These pin the subrole rule that replaced
/// it — the same rule `logic_close_plugin_window` enforces.
final class LogicWindowKindTests: XCTestCase {

    private let document = "/Users/x/Music/Logic/Testlåt Copy.logicx"

    /// The observed defect: with the Mixer open there are TWO standard windows
    /// carrying the same document, and only one of them is the project window.
    /// `projectWindow()` filters the Mixer out; the oracle now says why.
    func testTheMixerIsItsOwnKindAndNotTheProjectWindow() {
        XCTAssertEqual(
            LogicWindowKind.classify(
                subrole: "AXStandardWindow",
                title: "Testlåt Copy - Mixer: Tracks",
                hasDocument: true
            ),
            "mixer"
        )
        XCTAssertEqual(
            LogicWindowKind.classify(
                subrole: "AXStandardWindow",
                title: "Testlåt Copy - Tracks",
                hasDocument: true
            ),
            "project"
        )
    }

    /// The other direction of the old error: a Drum Machine Designer window is
    /// an `AXDialog` that CARRIES the project document. Called "project" it
    /// told an agent the window could not be closed, while
    /// `logic_close_plugin_window` closes it happily.
    func testADocumentCarryingDialogIsStillAClosableDialog() {
        for hasDocument in [true, false] {
            XCTAssertEqual(
                LogicWindowKind.classify(
                    subrole: "AXDialog", title: "Drum Machine Designer", hasDocument: hasDocument
                ),
                "plugin_or_auxiliary"
            )
        }
    }

    /// A standard window with no document is not a plugin window either — the
    /// half of the old rule that mislabelled everything document-less.
    func testAStandardWindowWithoutADocumentIsNeitherProjectNorPlugin() {
        let kind = LogicWindowKind.classify(
            subrole: "AXStandardWindow", title: "Untitled", hasDocument: false
        )
        XCTAssertEqual(kind, "standard")
        XCTAssertNotEqual(kind, "plugin_or_auxiliary")
    }

    /// Floating windows (Key Commands) and windows with no subrole at all are
    /// named, not guessed at.
    func testUnknownSubrolesAreNamedOther() {
        XCTAssertEqual(
            LogicWindowKind.classify(
                subrole: "AXFloatingWindow",
                title: "Key Command Assignments – Swedish",
                hasDocument: false
            ),
            "other"
        )
        XCTAssertEqual(
            LogicWindowKind.classify(subrole: "", title: "", hasDocument: true),
            "other"
        )
    }

    /// The Mixer test is on the VIEW segment after the last `" - "`, so a
    /// project whose NAME mentions the mixer is still a project window.
    func testAProjectNamedAfterTheMixerIsNotTheMixer() {
        XCTAssertFalse(LogicWindowKind.isMixerTitle("Mixer Notes - Tracks"))
        XCTAssertEqual(
            LogicWindowKind.classify(
                subrole: "AXStandardWindow", title: "Mixer Notes - Tracks", hasDocument: true
            ),
            "project"
        )
        XCTAssertTrue(LogicWindowKind.isMixerTitle("Mixer Notes - Mixer: Tracks"))
    }

    /// The description an agent reads must not carry the misconception the
    /// code no longer holds. `Support.swift`'s refusal already says the real
    /// rule; this was the last copy of the old one.
    func testTheToolDescriptionNoLongerTeachesTheDocumentRule() {
        let description = MCPServer.wholeRegistry
            .first { $0.name == "logic_list_windows" }?.description ?? ""
        XCTAssertFalse(description.isEmpty)
        XCTAssertFalse(description.contains("dialogs without a document"))
        XCTAssertTrue(description.contains("SUBROLE"))
        XCTAssertTrue(description.contains("'mixer'"))
    }
}
