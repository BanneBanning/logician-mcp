import XCTest
@testable import Logician
import LogicMCUBridge

/// The efficiency package's two new pieces of reasoning, both pure: the
/// DEBT left behind when a plugin tool stops returning the surface to the Pan
/// view, and the OFFLINE address resolution that replaces a six-page walk on
/// every parameter write.
///
/// Neither can be checked by watching Logic: a deferral that leaks looks
/// exactly like a deferral that works until, three tools later, Logic starts
/// auto-opening plugin windows — and an offline page lookup that picks the
/// wrong index writes confidently to the wrong parameter. So the rules are
/// written where they can be exercised without a surface.
final class SurfaceDeferralTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MCUController.surfaceDebt = nil
        MCUController.hotEditView = nil
    }

    override func tearDown() {
        MCUController.surfaceDebt = nil
        MCUController.hotEditView = nil
        super.tearDown()
    }

    // MARK: - The debt lifecycle

    func testDeferringRecordsWhatTheSurfaceIsShowing() {
        MCUController.deferSurfaceRestore(
            MCUController.SurfaceDebt(strip: "Bas", view: "plugin_edit", slot: 1)
        )
        XCTAssertEqual(
            MCUController.surfaceDebt,
            MCUController.SurfaceDebt(strip: "Bas", view: "plugin_edit", slot: 1)
        )
    }

    /// The whole point of the deferral: the next tool on the SAME strip reuses
    /// the view instead of paying ~3.3 s to put it back and take it out again.
    func testADebtOnTheSameStripIsLeftStanding() {
        MCUController.deferSurfaceRestore(
            MCUController.SurfaceDebt(strip: "Bas", view: "plugin_edit", slot: 1)
        )
        XCTAssertFalse(MCUController.settleSurfaceDebt(before: "Bas"))
        XCTAssertNotNil(MCUController.surfaceDebt)
    }

    /// Which views make Logic auto-open a plugin window on the next track
    /// selection — the question `settleSurfaceDebt` asks the surface when this
    /// process remembers no debt, because a previous process can have left one.
    func testOnlyThePluginAndInstrumentViewsAreADebt() {
        for slot in 1...8 {
            XCTAssertTrue(MCUController.isPluginEditAssignment("P\(slot)"))
        }
        XCTAssertTrue(MCUController.isPluginEditAssignment("IN"))
        // Codes this project has not enumerated but Logic paints anyway. `P_`
        // was observed live and a selection taken on top of it opened a plugin
        // window, so the family is matched by its prefix rather than by a list.
        for code in ["P_", "P0", "P9", "Pl"] {
            XCTAssertTrue(MCUController.isPluginEditAssignment(code), code)
        }
        // The neutral names view, the channel-strip overview, sends and the EQ
        // view are all views other tools set on purpose and none of them leaks
        // plugin windows.
        for code in ["PN", "CS", "SE", "EQ", ""] {
            XCTAssertFalse(MCUController.isPluginEditAssignment(code), code)
        }
    }

    /// The restore clears BOTH records — a debt that survived a restore would
    /// make the next tool skip a restore it needs. Asserted on
    /// `forgetSurfaceViews`, the half of `exitToPan` that does not press
    /// anything: a unit test must not move the user's real surface.
    func testTheRestoreClearsTheDebtAndTheHotView() {
        MCUController.hotEditView = MCUController.HotEditView(
            track: "Bas", slot: .insert(1), cacheKey: "Cha EQ"
        )
        MCUController.deferSurfaceRestore(
            MCUController.SurfaceDebt(strip: "Bas", view: "plugin_edit", slot: 1)
        )
        MCUController.forgetSurfaceViews()
        XCTAssertNil(MCUController.surfaceDebt)
        XCTAssertNil(MCUController.hotEditView)
    }

    // MARK: - The send view's debt

    /// A finished send write records the same kind of debt a plugin read
    /// does, on the strip it wrote to — so the next tool on that strip reuses
    /// the standing send view instead of paying `ensurePanNames` twice over.
    func testAFinishedSendWriteRecordsItsViewAgainstItsStrip() {
        MCUController.deferSurfaceRestore(MCUController.sendViewDebt(strip: "Sweeps"))
        XCTAssertEqual(
            MCUController.surfaceDebt,
            MCUController.SurfaceDebt(strip: "Sweeps", view: "send", slot: nil)
        )
        XCTAssertFalse(MCUController.settleSurfaceDebt(before: "Sweeps"))
        XCTAssertNotNil(MCUController.surfaceDebt)
    }

    /// The send view is a SAFER thing to leave standing than the plugin views
    /// the debt pattern was invented for: `SE` is not a plugin-edit
    /// assignment, so it cannot make Logic auto-open a plug-in window on the
    /// next track selection. Pinned here because that is the whole argument
    /// for deferring in the send tools at all.
    func testAStandingSendViewIsNotTheAutoOpenHazard() {
        XCTAssertFalse(MCUController.isPluginEditAssignment("SE"))
    }

    /// A write on a strip this build could not name (`logic_mcu_set_send` on a
    /// headerless strip resolved by number) still records a debt — an unnamed
    /// one, which every later selection settles rather than reuses. Erring
    /// toward one extra restore, never toward a view left standing behind an
    /// unknown strip.
    func testAnUnnamedStripsDebtIsSettledByTheNextSelection() {
        MCUController.deferSurfaceRestore(MCUController.sendViewDebt(strip: nil))
        XCTAssertEqual(
            MCUController.surfaceDebt,
            MCUController.SurfaceDebt(strip: nil, view: "send", slot: nil)
        )
    }

    // MARK: - Resolving a plugin_name to an insert slot

    /// The reference project's `Bas`, as the LCD paints it: two Channel EQs,
    /// a bypassed Pitch Shifter, a Compressor, then empty slots.
    private let basInserts = ["Cha EQ", "*PitchS", "Cha EQ", "Compre", "--", "--", "--", "--"]

    func testAFullPluginNameFindsItsAbbreviatedCell() {
        XCTAssertEqual(
            MCUController.insertSlotsMatching(pluginName: "Compressor", cells: basInserts),
            [4]
        )
    }

    func testTwoCopiesOfOnePluginAreReportedAsTwo() {
        // Never resolved to "the first one": the caller has to choose.
        XCTAssertEqual(
            MCUController.insertSlotsMatching(pluginName: "Channel EQ", cells: basInserts),
            [1, 3]
        )
    }

    func testTheBypassMarkerIsNotPartOfTheName() {
        XCTAssertEqual(
            MCUController.insertSlotsMatching(pluginName: "Pitch Shifter", cells: basInserts),
            [2]
        )
    }

    func testEmptySlotsMatchNothing() {
        XCTAssertTrue(
            MCUController.insertSlotsMatching(pluginName: "--", cells: basInserts).isEmpty
        )
        XCTAssertTrue(
            MCUController.insertSlotsMatching(pluginName: "Limiter", cells: basInserts).isEmpty
        )
    }

    // MARK: - The offline page/vpot lookup

    /// `Bas`'s Channel EQ, exactly as `param-names-cache.json` holds it — six
    /// pages, and Logic end-aligns the last one so page 6 repeats page 5's tail.
    private let channelEQ: [[String]] = [
        ["LoCutS", "LoShGa", "Pea1Ga", "Pea2Ga", "Pea3Ga", "Pea4Ga", "HiShGa", "HiCutS"],
        ["LoCutF", "LoShF", "Peak1F", "Peak2F", "Peak3F", "Peak4F", "HiShF", "HiCutF"],
        ["LoCutQ", "LoShQ", "Peak1Q", "Peak2Q", "Peak3Q", "Peak4Q", "HiShQ", "HiCutQ"],
        ["LCO/Of", "LSO/Of", "Pe1On/", "Pe2On/", "Pe3On/", "Pe4On/", "HSO/Of", "HCO/Of"],
        ["AnOn/O", "AnlrMd", "AnlzrD", "AnlPos", "AnlRes", "AnlTop", "", "Ga-QCo"],
        ["AnlzrD", "AnlPos", "AnlRes", "AnlTop", "", "Ga-QCo", "G-QCou", "MasGai"]
    ]

    func testTheEqBandGainResolvesToPageOne() {
        let hit = MCUController.locateParameter("Pea2Ga", in: channelEQ)
        XCTAssertEqual(hit, MCUController.CachedParameterLocation(page: 1, index: 3, name: "Pea2Ga"))
    }

    func testAParameterOnALaterPageKeepsItsVpotIndex() {
        let hit = MCUController.locateParameter("Peak3Q", in: channelEQ)
        XCTAssertEqual(hit, MCUController.CachedParameterLocation(page: 3, index: 4, name: "Peak3Q"))
    }

    /// The abbreviation-tolerant match the live search uses has to work here
    /// too, or the fast path would silently disagree with the slow one about
    /// which names resolve at all.
    func testAnUnabbreviatedNameStillResolves() {
        XCTAssertEqual(
            MCUController.locateParameter("Master Gain", in: channelEQ)?.name,
            "MasGai"
        )
    }

    /// The end-aligned last page shows six parameters for the second time.
    /// Counting them as duplicates would send every one of them down the slow
    /// path; counting them as new ones would aim the encoder at page 6.
    func testTheEndAlignedRepeatIsNotADuplicate() {
        XCTAssertEqual(MCUController.lastPageOverlap(channelEQ), 5)
        let hit = MCUController.locateParameter("AnlzrD", in: channelEQ)
        XCTAssertEqual(hit, MCUController.CachedParameterLocation(page: 5, index: 2, name: "AnlzrD"))
    }

    /// A parameter that only the last page carries is still reachable.
    func testAParameterPastTheOverlapResolvesOnTheLastPage() {
        let hit = MCUController.locateParameter("G-QCou", in: channelEQ)
        XCTAssertEqual(hit, MCUController.CachedParameterLocation(page: 6, index: 6, name: "G-QCou"))
    }

    func testAnUnknownNameResolvesToNothing() {
        XCTAssertNil(MCUController.locateParameter("Threshold", in: channelEQ))
    }

    /// A genuine ambiguity is refused rather than resolved — the caller then
    /// walks the pages live and reports `parameterAmbiguous` with the real rows.
    func testAGenuineDuplicateIsRefused() {
        let twoLevels: [[String]] = [
            ["Level", "A", "B", "C", "D", "E", "F", "G"],
            ["H", "I", "J", "K", "L", "M", "N", "Level"]
        ]
        XCTAssertNil(MCUController.locateParameter("Level", in: twoLevels))
    }

    /// Rows this function cannot index are rows it will not reason about.
    func testAShortRowIsRefused() {
        XCTAssertNil(MCUController.locateParameter("A", in: [["A", "B"]]))
    }

    // MARK: - What the write path is allowed to cache

    private func page(_ names: [String]) -> [(name: String, value: String)] {
        names.map { ($0, "0") }
    }

    func testAFullyReadWalkIsCacheable() {
        let rows = MCUController.cacheableNameRows([page(channelEQ[0]), page(channelEQ[1])])
        XCTAssertEqual(rows, [channelEQ[0], channelEQ[1]])
    }

    /// `settledParameterPage` gives up after 3.5 s and hands back whatever the
    /// LCD shows, indicator and all. Caching that row would teach every later
    /// read a layout Logic never finished painting.
    func testARowStillCarryingThePageIndicatorIsNotCacheable() {
        var tainted = channelEQ[0]
        tainted[6] = "Page 1"
        XCTAssertNil(MCUController.cacheableNameRows([page(tainted)]))
    }

    func testAPartialRowIsNotCacheable() {
        XCTAssertNil(MCUController.cacheableNameRows([page(["A", "B", "C"])]))
        XCTAssertNil(MCUController.cacheableNameRows([]))
    }

    // MARK: - Which bridge commands can move the user's surface
    //
    // `MCUBridge.didTouchSurface` decides whether the server presses PAN on
    // the way out. It used to be set for everything except `ping`, so
    // `logic_health` — a `safety: .readOnly` diagnostic whose only bridge
    // traffic is a `status` the daemon answers from its own snapshot —
    // restored a surface it had never moved (measured 2026-09-02: 145 ms, and
    // a real view change on a surface the user had left in a Send view).

    func testTheOnlyReadShapedBridgeCommandsAreTheThreeThatSendNoMIDI() {
        // Pinned as a SET over CaseIterable rather than checked one by one:
        // a new command added to the vocabulary shows up here as a failure
        // instead of quietly inheriting whichever side someone forgot.
        let readShaped = Set(BridgeCommandName.allCases.filter { !$0.emitsMIDI })
        XCTAssertEqual(readShaped, [.ping, .status, .awaitEvents])
    }

    func testEveryOtherBridgeCommandCountsAsTouchingTheSurface() {
        let writing = Set(BridgeCommandName.allCases.filter(\.emitsMIDI))
        XCTAssertEqual(
            writing,
            [.press, .select, .mute, .solo, .vpotPress, .fader, .vpot, .raw,
             .converge, .midiStream, .midiAbort, .keycmd]
        )
    }

    func testTheDoctorsOwnCommandsAreReadShaped() {
        XCTAssertFalse(BridgeCommand.status.emitsMIDI)
        XCTAssertFalse(BridgeCommand.ping.emitsMIDI)
        XCTAssertFalse(BridgeCommand.awaitEvents(since: 0, timeoutMs: 10).emitsMIDI)
    }

    func testACommandThisBuildDoesNotModelCountsAsAWrite() {
        // `logic_mcu_command` forwards agent-authored objects verbatim and the
        // daemon can be a newer build, so the unknown case is the one where
        // guessing "read-only" skips a restore the user needed.
        XCTAssertTrue(BridgeCommand(cmd: "teleport").emitsMIDI)
        XCTAssertTrue(BridgeCommand(cmd: nil).emitsMIDI)
    }

    func testTheCheapestSurfaceWritesStillCount() {
        XCTAssertTrue(BridgeCommand.press(button: "assign_pan").emitsMIDI)
        XCTAssertTrue(BridgeCommand.raw(bytes: [0x90, 0x2A, 0x7F]).emitsMIDI)
        XCTAssertTrue(BridgeCommand.midiAbort.emitsMIDI)
    }
}
