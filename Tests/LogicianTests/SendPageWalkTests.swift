import XCTest
@testable import Logician

/// The pure half of the page-verified send-list walk: the slot number a
/// send-view field label names. This is the proof `readSends` and
/// `sendViewToPage` demand after every page advance — a page that cannot
/// name its own first slot is a page that did not arrive.
final class SendPageWalkTests: XCTestCase {

    func testSettledSlotLabelsNameTheirSlot() {
        XCTAssertEqual(MCUController.sendSlotNumber(inFieldLabel: "Sen1In"), 1)
        XCTAssertEqual(MCUController.sendSlotNumber(inFieldLabel: "Sen3In"), 3)
        XCTAssertEqual(MCUController.sendSlotNumber(inFieldLabel: "Sen5In"), 5)
        XCTAssertEqual(MCUController.sendSlotNumber(inFieldLabel: "Sen7In"), 7)
        XCTAssertEqual(MCUController.sendSlotNumber(inFieldLabel: "Sen2De"), 2)
        XCTAssertEqual(MCUController.sendSlotNumber(inFieldLabel: "Sen8Mu"), 8)
    }

    /// The browse banner spells the word out ("Send 1", "Send 3") — its
    /// fourth character is not a digit, so it can never vouch for a page.
    /// Same one-sidedness as `sendViewTopIsFirstPage`.
    func testBrowseBannerNeverNamesAPage() {
        XCTAssertNil(MCUController.sendSlotNumber(inFieldLabel: "Send 1"))
        XCTAssertNil(MCUController.sendSlotNumber(inFieldLabel: "Send 3"))
    }

    func testForeignAndTornLabelsNameNothing() {
        XCTAssertNil(MCUController.sendSlotNumber(inFieldLabel: ""))
        XCTAssertNil(MCUController.sendSlotNumber(inFieldLabel: "Sen"))
        XCTAssertNil(MCUController.sendSlotNumber(inFieldLabel: "SenXIn"))
        XCTAssertNil(MCUController.sendSlotNumber(inFieldLabel: "Sen0In"))
        XCTAssertNil(MCUController.sendSlotNumber(inFieldLabel: "Sen9In"))
        XCTAssertNil(MCUController.sendSlotNumber(inFieldLabel: "PanDst"))
        XCTAssertNil(MCUController.sendSlotNumber(inFieldLabel: "Volume"))
        // A pan cell's numeric value must never read as a slot label.
        XCTAssertNil(MCUController.sendSlotNumber(inFieldLabel: "-64"))
    }

    // MARK: - Walking home by the page's own name

    /// A row of eight 7-character cells, as the surface publishes it.
    private func row(_ cells: [String]) -> String {
        cells.map { $0.padding(toLength: 7, withPad: " ", startingAt: 0) }.joined()
    }

    /// The row says how far home is: two sends to a page, so a row carrying
    /// `Sen5In` is page 3 and two cursor-lefts from the first page. This is
    /// what replaces four blind cursor-lefts (~1.0 s, measured twice) on every
    /// call that opens the send view on a page it was left on.
    func testTheRowSaysHowManyStepsHomeAre() {
        let pages = [
            (["Sen1In", "Send 1", "Sen1Po", "Sen1Mu", "Sen2In", "Send 2", "Sen2Po", "Sen2Mu"], 0),
            (["Sen3In", "Send 3", "Sen3Po", "Sen3Mu", "Sen4In", "Send 4", "Sen4Po", "Sen4Mu"], 1),
            (["Sen5In", "Send 5", "Sen5Po", "Sen5Mu", "Sen6In", "Send 6", "Sen6Po", "Sen6Mu"], 2),
            (["Sen7In", "Send 7", "Sen7Po", "Sen7Mu", "Sen8In", "Send 8", "Sen8Po", "Sen8Mu"], 3)
        ]
        for (cells, backsteps) in pages {
            XCTAssertEqual(MCUController.sendViewPageBacksteps(inRow: row(cells)), backsteps,
                           cells[0])
        }
    }

    /// The frame this scan exists for, captured live 2026-09-02 right after a
    /// confirming press: the browse banner covers the first three cells while
    /// the fourth already carries the slot's own label. Reading cell 0 alone
    /// called this "no page" and walked four blind lefts to the page it was
    /// already standing on.
    func testTheBannerFrameStillNamesItsPageThroughTheCellsItLeftAlone() {
        for label in ["Sen2In", "Sen2De"] {
            let banner = row(["Send 1", "Instant", "-", label, "-", "-", "-", "-"])
            XCTAssertEqual(MCUController.sendViewPageBacksteps(inRow: banner), 0, label)
        }
        // The same banner over the SECOND page names the second page.
        let deeper = row(["Send 3", "Instant", "-", "Sen4In", "-", "-", "-", "-"])
        XCTAssertEqual(MCUController.sendViewPageBacksteps(inRow: deeper), 1)
    }

    /// A row that names no page at all cannot say how far home is — the caller
    /// then walks the four blind lefts it always walked, which is one-sided in
    /// the same direction as every other guess in this file.
    func testARowThatNamesNoPageSaysNothingAboutTheDistanceHome() {
        XCTAssertNil(MCUController.sendViewPageBacksteps(
            inRow: row(["Send 1", "Instant", "-", "-", "-", "-", "-", "-"])))
        XCTAssertNil(MCUController.sendViewPageBacksteps(inRow: row([])))
        XCTAssertNil(MCUController.sendViewPageBacksteps(
            inRow: row(["LofPad", "Bas", "808", "Inst 2", "Drums", "Fill", "AckSlg", "IvnSlg"])))
        // The pan row a fallen-out view paints: numbers, never a page.
        XCTAssertNil(MCUController.sendViewPageBacksteps(
            inRow: row(["-64", "0", "+28", "0", "0", "0", "0", "0"])))
    }

    /// Stepping back `backsteps` pages visits the pages in descending order
    /// and ends on page 1 — the arithmetic the paced walk waits on, pinned so
    /// an off-by-one cannot land the caller on a page whose slots it would
    /// then renumber.
    func testSteppingBackLandsOnTheFirstPageThroughEveryPageBetween() {
        for (label, expected) in [("Sen3In", [1]), ("Sen5In", [3, 1]), ("Sen7In", [5, 3, 1])] {
            let backsteps = MCUController.sendViewPageBacksteps(
                inRow: row([label, "", "", "", "", "", "", ""])
            )
            XCTAssertEqual(backsteps, expected.count, label)
            let visited = stride(from: (backsteps ?? 0) - 1, through: 0, by: -1)
                .map { $0 * 2 + 1 }
            XCTAssertEqual(visited, expected, label)
            XCTAssertEqual(visited.last, 1, label)
        }
    }

    // MARK: - Reading a page that Logic is painting over

    /// The two rows of a page, as `settledSendPage` pairs them up.
    private func page(_ top: [String], _ bottom: [String]) -> [(name: String, value: String)] {
        zip(MCUController.lcdFields(row(top)), MCUController.lcdValueFields(row(bottom)))
            .map { ($0, $1) }
    }

    /// The settled row: every occupied slot shows its own four labels, and the
    /// values under them are that slot's values.
    func testASettledPageIsReadable() {
        XCTAssertTrue(MCUController.sendPageShowsSettledFields(page(
            ["Sen1In", "Send 1", "Sen1Po", "Sen1Mu", "Sen2In", "-", "-", "-"],
            ["Bus 2", "-12,2", "PosPan", "active", "--", "", "", ""]
        )))
    }

    /// The post-write overlay, captured live 2026-09-02 (it stood for 1.76 to
    /// 2.01 s after a level write): the position LABEL is replaced by the
    /// destination's aux name and the dB value spills into the cell under it.
    /// Read as settled, that row reported send 1's position as `B`.
    func testTheOverlayLogicPaintsAfterALevelWriteIsNotASettledPage() {
        XCTAssertFalse(MCUController.sendPageShowsSettledFields(page(
            ["Sen1In", "Send 1", " Aux 2", "Sen1Mu", "Sen2In", "-", "-", "-"],
            ["Bus 2", "-11,8 d", "B", "active", "--", "", "", ""]
        )))
    }

    /// The browse banner over an occupied slot fails the same test, from the
    /// other end of the field group.
    func testTheBrowseBannerIsNotASettledPage() {
        XCTAssertFalse(MCUController.sendPageShowsSettledFields(page(
            ["Send 1", "Instant", "-", "Sen2De", "-", "-", "-", "-"],
            ["Bus 2", "", "", "", "", "", "", ""]
        )))
    }

    /// An EMPTY slot is held to nothing but its destination label — which is
    /// all Logic labels there, so a track with no sends must not be made to
    /// wait for cells that are never coming.
    func testAnEmptySlotNeedsNoFieldLabelsOfItsOwn() {
        XCTAssertTrue(MCUController.sendPageShowsSettledFields(page(
            ["Sen1In", "-", "-", "-", "Sen2In", "-", "-", "-"],
            ["--", "", "", "", "--", "", "", ""]
        )))
        // And the same page with the second slot occupied still checks that one.
        XCTAssertFalse(MCUController.sendPageShowsSettledFields(page(
            ["Sen1In", "-", "-", "-", "Sen2In", "Send 2", " Aux 2", "Sen2Mu"],
            ["--", "", "", "", "Bus 2", "-11,8 d", "B", "active"]
        )))
    }

    /// The walk expects odd first slots per page: page p shows slots
    /// 2p+1 and 2p+2, so the labels the advance waits for are exactly
    /// Sen1/Sen3/Sen5/Sen7 — pin the arithmetic the callers share.
    func testPageFirstSlotArithmetic() {
        for (page, slot) in [(0, 1), (1, 3), (2, 5), (3, 7)] {
            XCTAssertEqual(page * 2 + 1, slot)
        }
        for send in 1...8 {
            let page = (send - 1) / 2
            let firstSlot = page * 2 + 1
            XCTAssertTrue(firstSlot == send || firstSlot == send - 1)
            XCTAssertTrue(firstSlot % 2 == 1)
        }
    }
}
