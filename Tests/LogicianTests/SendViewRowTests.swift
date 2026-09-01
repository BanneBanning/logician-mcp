import XCTest
@testable import Logician
@testable import LogicMCUBridge

/// The two positive checks the send tools use to stop waiting for things that
/// have already happened: "is the send view already on its first page" and
/// "has the destination press been taken". Both read one LCD top row, so both
/// are pure and testable without Logic.
///
/// Every row below was captured off the running surface on 2026-08-31 while
/// profiling `logic_add_send` against `Testlåt Copy`. That matters: the
/// rows a naive reading would get wrong are the TRANSIENT ones — the browse
/// banner Logic paints over the page it is editing spells the label out
/// (`Send 1`) where the settled page abbreviates it (`Sen1In`), and those two
/// differ only at the fourth character.
final class SendViewRowTests: XCTestCase {

    // MARK: - Rows captured live

    /// Page 1, settled, nothing in either slot.
    private let firstPageEmpty =
        "Sen1In -      -      -      Sen2In -      -      -      "
    /// Page 1, settled, send 1 occupied and send 2 empty.
    private let firstPageOneSend =
        "Sen1In Send 1 Sen1Po Sen1Mu Sen2In -      -      -      "
    /// Page 1, settled, both slots occupied.
    private let firstPageTwoSends =
        "Sen1In Send 1 Sen1Po Sen1Mu Sen2In Send 2 Sen2Po Sen2Mu "
    /// Page 1 mid-repaint: `Sen1Destination` truncated to the 7-char cell.
    private let firstPageRepainting =
        "Sen1De Send 1 Sen1Po Sen1Mu Sen2De -      -      -      "
    /// Page 2, settled, both slots empty.
    private let secondPageEmpty =
        "Sen3In -      -      -      Sen4In -      -      -      "
    /// Page 3, settled — the page the surface was found parked on.
    private let thirdPageEmpty =
        "Sen5In -      -      -      Sen6In -      -      -      "

    /// BROWSING send 1 on page 1: the banner "Send 1 Destination" covers
    /// cells 0-2 and the slot's own labels are gone.
    private let browsingSlot1 =
        "Send 1 Destination   -      Sen2In -      -      -      "
    /// BROWSING send 2 on page 1: send 1 keeps its labels, the banner covers
    /// cells 4-6.
    private let browsingSlot2 =
        "Sen1In Send 1 Sen1Po Sen1Mu Send 2 Destination   -      "
    /// BROWSING send 3 on page 2.
    private let browsingSlot3 =
        "Send 3 Destination   -      Sen4In -      -      -      "

    /// The frame right AFTER the confirming press for send 1: the banner has
    /// become "Instantiate" and cell 3 carries send 1's own status label.
    private let committedSlot1 =
        "Send 1 Instantiate   Sen1Mu Sen2In -      -      -      "
    /// The same, for send 2 (field group 4-7).
    private let committedSlot2 =
        "Sen1In Send 1 Sen1Po Sen1Mu Send 2 Instantiate   Sen2Mu "
    /// The same, for send 3 (page 2, field group 0-3).
    private let committedSlot3 =
        "Send 3 Instantiate   Sen3Mu Sen4In -      -      -      "

    func testEveryCapturedRowIsFiftySixCharacters() {
        for row in [firstPageEmpty, firstPageOneSend, firstPageTwoSends,
                    firstPageRepainting, secondPageEmpty, thirdPageEmpty,
                    browsingSlot1, browsingSlot2, browsingSlot3,
                    committedSlot1, committedSlot2, committedSlot3] {
            XCTAssertEqual(row.count, MCULCDRow.length, "row: |\(row)|")
        }
    }

    // MARK: - "Already on the first page"

    func testTheFirstPageIsRecognisedSettledAndMidRepaint() {
        for row in [firstPageEmpty, firstPageOneSend,
                    firstPageTwoSends, firstPageRepainting] {
            XCTAssertTrue(MCUController.sendViewTopIsFirstPage(row), "row: |\(row)|")
        }
    }

    func testOtherPagesAreNotMistakenForTheFirst() {
        XCTAssertFalse(MCUController.sendViewTopIsFirstPage(secondPageEmpty))
        XCTAssertFalse(MCUController.sendViewTopIsFirstPage(thirdPageEmpty))
    }

    /// The reason the check is a prefix test against `Sen1` and not against
    /// the word Logic spells in the banner: `Send 1` is send ONE's banner and
    /// says nothing about which page is showing — `browsingSlot3` proves it,
    /// because there the same shape of banner sits on page TWO.
    func testABrowseBannerNeverClaimsTheFirstPage() {
        for row in [browsingSlot1, browsingSlot3, committedSlot1, committedSlot3] {
            XCTAssertFalse(MCUController.sendViewTopIsFirstPage(row), "row: |\(row)|")
        }
    }

    /// Cheap and one-sided: a banner over send 2's group leaves send 1's
    /// labels standing, so the row still truthfully reads as page 1.
    func testABannerOverTheSecondSlotStillShowsTheFirstPage() {
        XCTAssertTrue(MCUController.sendViewTopIsFirstPage(browsingSlot2))
        XCTAssertTrue(MCUController.sendViewTopIsFirstPage(committedSlot2))
    }

    // MARK: - "The destination press was taken"

    func testACommittedSlotShowsItsOwnLabelsAtItsFieldGroup() {
        XCTAssertTrue(MCUController.sendSlotFieldsPainted(
            top: committedSlot1, slot: 1, destIndex: 0))
        XCTAssertTrue(MCUController.sendSlotFieldsPainted(
            top: committedSlot2, slot: 2, destIndex: 4))
        XCTAssertTrue(MCUController.sendSlotFieldsPainted(
            top: committedSlot3, slot: 3, destIndex: 0))
    }

    /// The state the wait exists to leave: still browsing, banner up, no slot
    /// labels. If this passed, the wait would return before the press landed.
    func testAnUncommittedBrowseIsNotMistakenForACommit() {
        XCTAssertFalse(MCUController.sendSlotFieldsPainted(
            top: browsingSlot1, slot: 1, destIndex: 0))
        XCTAssertFalse(MCUController.sendSlotFieldsPainted(
            top: browsingSlot2, slot: 2, destIndex: 4))
        XCTAssertFalse(MCUController.sendSlotFieldsPainted(
            top: browsingSlot3, slot: 3, destIndex: 0))
    }

    /// The NEIGHBOUR's labels must not answer for this slot: on page 2 while
    /// send 3 is being browsed, send 4's group is fully painted, and a check
    /// that looked at the wrong cell would call the write committed
    /// immediately and for ever.
    func testANeighbourSlotsLabelsDoNotCountAsThisSlotsCommit() {
        XCTAssertFalse(MCUController.sendSlotFieldsPainted(
            top: browsingSlot3, slot: 4, destIndex: 0))
        XCTAssertFalse(MCUController.sendSlotFieldsPainted(
            top: browsingSlot1, slot: 2, destIndex: 0))
    }

    // MARK: - "This strip has no send slots at all"

    /// Captured live 2026-08-31 on `Testlåt Copy`. `Vocals` is a
    /// folder-stack main track: its reduced strip publishes no sends, and its
    /// send view raises the slot labels over a bottom row it leaves entirely
    /// blank. `Sweeps` has zero sends on a REAL strip, and the same top row
    /// sits over the No-Send entry `--` in both destination cells — that pair
    /// browses fine, and the add tool proved it by creating and removing a
    /// send there the same day. The blank cell, not the empty slot, is what
    /// broke: it used to read as "slot 1 is free" and sent the browse to turn
    /// a vpot Logic had given no parameter.
    private let sendlessBottom =
        "                                                        "
    private let zeroSendsBottom =
        "--                          --                          "
    private let occupiedBottom =
        "Bus 2  -9,0dB PosPan active Out 3                       "

    func testAFolderStackMainTrackReadsAsSendless() {
        XCTAssertEqual(sendlessBottom.count, MCULCDRow.length)
        XCTAssertTrue(MCUController.sendViewShowsSendlessStrip(
            top: firstPageEmpty, bottom: sendlessBottom))
    }

    func testARealStripNeverReadsAsSendless() {
        XCTAssertEqual(zeroSendsBottom.count, MCULCDRow.length)
        XCTAssertEqual(occupiedBottom.count, MCULCDRow.length)
        // Zero sends on a real strip: the No-Send entry is painted, so the
        // slot is empty and browsable, not missing.
        XCTAssertFalse(MCUController.sendViewShowsSendlessStrip(
            top: firstPageEmpty, bottom: zeroSendsBottom))
        // Occupied: the cell holds a destination.
        XCTAssertFalse(MCUController.sendViewShowsSendlessStrip(
            top: firstPageOneSend, bottom: occupiedBottom))
    }

    /// The signature is confined to the FIRST page and to rows whose slot-1
    /// label is up: a later page, or a browse banner covering the labels, says
    /// nothing about whether the strip has sends.
    func testOtherPagesAndBannersDoNotReadAsSendless() {
        XCTAssertFalse(MCUController.sendViewShowsSendlessStrip(
            top: secondPageEmpty, bottom: sendlessBottom))
        XCTAssertFalse(MCUController.sendViewShowsSendlessStrip(
            top: browsingSlot1, bottom: sendlessBottom))
    }

    /// A single frame CAN lie: mid-repaint the label is up while the cell is
    /// still blank. That reading passes here on purpose — the check is cheap
    /// and one-frame — and the caller is what makes it safe, by requiring the
    /// signature twice around a quiescence window before refusing.
    func testAMidRepaintFrameCanShowTheSignatureWhichIsWhyTheCallerReadsTwice() {
        XCTAssertTrue(MCUController.sendViewShowsSendlessStrip(
            top: firstPageRepainting, bottom: sendlessBottom))
    }

    /// Slot 8 sits at field group 4-7, so its status cell is the last one;
    /// the index clamp must not let the read wander off the row.
    func testTheLastFieldGroupStaysInsideTheRow() {
        let committedSlot8 =
            "Sen7In Send 7 Sen7Po Sen7Mu Send 8 Instantiate   Sen8Mu "
        XCTAssertEqual(committedSlot8.count, MCULCDRow.length)
        XCTAssertTrue(MCUController.sendSlotFieldsPainted(
            top: committedSlot8, slot: 8, destIndex: 4))
    }
}
