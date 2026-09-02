import XCTest
@testable import Logician

/// What `logic_open_plugin` accepts as proof that a plugin's window is up.
///
/// Real `AXUIElement`s cannot be constructed in a test, so the decisions are
/// generic over the key type and pinned here on plain integers — the same
/// arrangement `WindowCloseVerificationTests` and `walkTree` use.
///
/// The property that matters is the one the window LIST cannot see: Logic
/// reuses one plugin window per channel and swaps the plugin into it, keeping
/// the element and the title. Every case below is written from that fact.
final class PluginWindowContentTests: XCTestCase {

    // The channel's plugin window (1) and the project window (2), as they are
    // open when the press happens.
    private let channel = 1
    private let project = 2
    private let track = "808"

    private func showing(
        _ key: Int, _ plugin: String, shape: [String] = ["size:192×177", "AXButton|close"]
    ) -> PluginWindowShowing<Int> {
        PluginWindowShowing(key: key, shows: plugin, shape: shape)
    }

    // MARK: - Reading the plugin name out of the header

    func testTheHeaderNamesThePluginRightBeforeTheChannel() {
        // MEASURED live 2026-09-02: Decapitator's window publishes exactly
        // these two static texts, in this order.
        XCTAssertEqual(
            pluginNameFromHeader(staticTexts: ["Decapitator", "808"], trackName: track),
            "Decapitator"
        )
    }

    func testAnEarlierStaticTextIsNotThePluginName() {
        // Channel EQ publishes a third static text, "View:", ahead of the
        // pair — so "the text that is not the track name" is the wrong rule.
        XCTAssertEqual(
            pluginNameFromHeader(staticTexts: ["View:", "Channel EQ", "808"], trackName: track),
            "Channel EQ"
        )
    }

    func testAHiddenHeaderNamesNothing() {
        // The plugin window has a Show/Hide header button; a hidden header
        // takes the static texts with it, and the answer must be empty rather
        // than a guess.
        XCTAssertEqual(pluginNameFromHeader(staticTexts: [], trackName: track), "")
        XCTAssertEqual(pluginNameFromHeader(staticTexts: ["808"], trackName: track), "")
    }

    func testATrackNamedLikeItsPluginStillResolves() {
        // The LAST occurrence of the track name is the anchor, so a plugin
        // that happens to be called "808" does not eat its own label.
        XCTAssertEqual(
            pluginNameFromHeader(staticTexts: ["808", "808"], trackName: track),
            "808"
        )
    }

    // MARK: - The already-open decision, taken WITHOUT pressing

    func testTheChannelWindowShowingThisPluginIsAlreadyOpen() {
        XCTAssertEqual(
            windowAlreadyShowing([showing(channel, "Channel EQ")], plugin: "Channel EQ"),
            channel
        )
    }

    func testATruncatedSlotNameStillMatchesTheHeadersFullName() {
        // The strip paints "Decapitato"; the header spells "Decapitator".
        XCTAssertEqual(
            windowAlreadyShowing([showing(channel, "Decapitator")], plugin: "Decapitato"),
            channel
        )
    }

    func testAWindowShowingADIFFERENTPluginIsNotAlreadyOpen() {
        // This is the case the old code could not tell from the one above,
        // and it is the difference between a swap and closing the user's
        // window.
        XCTAssertNil(
            windowAlreadyShowing([showing(channel, "Decapitator")], plugin: "Channel EQ")
        )
    }

    func testAWindowThatNamesNothingIsNotAlreadyOpen() {
        XCTAssertNil(windowAlreadyShowing([showing(channel, "")], plugin: "Channel EQ"))
    }

    func testTwoWindowsAnsweringToTheSameNameDecideNothing() {
        // Two Channel EQs on one track: the header cannot say WHICH insert
        // this window belongs to, so the tool must press and watch rather
        // than report a no-op it cannot stand behind.
        XCTAssertNil(
            windowAlreadyShowing(
                [showing(channel, "Channel EQ"), showing(3, "Channel EQ")],
                plugin: "Channel EQ"
            )
        )
    }

    // MARK: - The verdict after the press

    private func verdict(
        plugin: String = "Channel EQ",
        before: [PluginWindowShowing<Int>],
        allBefore: Set<Int>,
        now: [PluginWindowShowing<Int>],
        allNow: [Int]
    ) -> PluginOpenVerdict<Int>? {
        pluginOpenVerdict(
            plugin: plugin, before: before, allBefore: allBefore, now: now, allNow: allNow
        )
    }

    func testTheInPlaceSwapTheWindowListCannotSee() {
        // THE DEFECT, in one assertion. The window list is identical before
        // and after — same two windows, same elements — and the press
        // nonetheless did what was asked: the channel's window stopped
        // showing Decapitator and started showing Channel EQ.
        let before = [showing(channel, "Decapitator")]
        let after = [showing(channel, "Channel EQ", shape: ["size:516×331", "AXButton|close"])]
        XCTAssertEqual(
            verdict(before: before, allBefore: [channel, project], now: after, allNow: [channel, project]),
            .showing(channel)
        )
    }

    func testNothingHavingHappenedYetIsNoVerdict() {
        let before = [showing(channel, "Decapitator")]
        XCTAssertNil(
            verdict(before: before, allBefore: [channel, project], now: before, allNow: [channel, project])
        )
    }

    func testANewWindowIsAnOpen() {
        let appeared = 4
        XCTAssertEqual(
            verdict(
                before: [], allBefore: [project],
                now: [showing(appeared, "Channel EQ")], allNow: [project, appeared]
            ),
            .showing(appeared)
        )
    }

    func testANewWindowThatNamesNothingIsStillAnOpen() {
        let appeared = 4
        XCTAssertEqual(
            verdict(
                before: [], allBefore: [project],
                now: [showing(appeared, "")], allNow: [project, appeared]
            ),
            .appeared(appeared)
        )
    }

    func testAWindowTitledAfterTheTrackOutranksAnUnrelatedOneOpeningInTheSamePoll() {
        // An alert or a floating window turning up inside the 2 s poll must
        // not be reported as the plugin's window.
        let stray = 9
        let appeared = 4
        XCTAssertEqual(
            verdict(
                before: [], allBefore: [project],
                now: [showing(appeared, "")], allNow: [project, stray, appeared]
            ),
            .appeared(appeared)
        )
    }

    func testATogglePressThatShutTheWindowIsSeen() {
        // Only reachable when the header would not name the plugin, because
        // the pre-press read otherwise answers already_open without pressing.
        let before = [showing(channel, "")]
        XCTAssertEqual(
            verdict(before: before, allBefore: [channel, project], now: [], allNow: [project]),
            .closed
        )
    }

    func testAChangedShapeIsTheFallbackProofOfASwap() {
        // Header hidden on both sides: no name either way, but the window is
        // publishing a different size and different children than it was.
        let before = [showing(channel, "", shape: ["size:192×177", "AXButton|close"])]
        let after = [showing(channel, "", shape: ["size:516×331", "AXButton|close", "AXGroup|EQ"])]
        XCTAssertEqual(
            verdict(before: before, allBefore: [channel, project], now: after, allNow: [channel, project]),
            .changed(channel)
        )
    }

    func testAnUnchangedShapeIsNeverProof() {
        // The press landed on the insert whose plugin was ALREADY showing and
        // Logic did nothing visible: the tool must keep waiting, and then say
        // it could not tell — not claim an open.
        let before = [showing(channel, "", shape: ["size:192×177", "AXButton|close"])]
        XCTAssertNil(
            verdict(before: before, allBefore: [channel, project], now: before, allNow: [channel, project])
        )
    }

    func testAWindowThatWasNotThereBeforeCannotProveAShapeChange() {
        // `changed` compares a window against ITSELF a moment earlier. A
        // window with no before-shape is an appearance, and is reported as
        // one, never as a swap.
        let appeared = 4
        XCTAssertEqual(
            verdict(
                before: [showing(channel, "")], allBefore: [channel, project],
                now: [showing(channel, ""), showing(appeared, "")],
                allNow: [channel, project, appeared]
            ),
            .appeared(appeared)
        )
    }

    // MARK: - The name match this all rests on

    func testPluginNamesMatchAcceptsEitherSideBeingTheTruncatedOne() {
        XCTAssertTrue(pluginNamesMatch("Space D", "Space Designer"))
        XCTAssertTrue(pluginNamesMatch("Space Designer", "Space D"))
        XCTAssertTrue(pluginNamesMatch(" channel eq ", "Channel EQ"))
    }

    func testPluginNamesMatchRefusesEmptyAndUnrelatedNames() {
        XCTAssertFalse(pluginNamesMatch("", "Channel EQ"))
        XCTAssertFalse(pluginNamesMatch("Channel EQ", ""))
        XCTAssertFalse(pluginNamesMatch("Compressor", "Channel EQ"))
    }
}
