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
