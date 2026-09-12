import XCTest
@testable import Logician

final class AXMixingReadbackTests: XCTestCase {
    func testKnownToggleStatesAreReadable() throws {
        XCTAssertTrue(try AXMixingReadback.toggle("on", control: "mute"))
        XCTAssertFalse(try AXMixingReadback.toggle("off", control: "solo"))
    }

    func testUnknownToggleValuesCannotCertifyOffOrSatisfyCompareAndSet() {
        for raw in ["", "mixed", "unavailable", "0", "1"] {
            XCTAssertThrowsError(try AXMixingReadback.toggle(raw, control: "mute"))
            XCTAssertNil(try? AXMixingReadback.toggle(raw, control: "solo"))
        }
    }

    func testReadablePanPositionsIncludeCenterAndBothSides() throws {
        XCTAssertEqual(try AXMixingReadback.panPosition("0"), 0)
        XCTAssertEqual(try AXMixingReadback.panPosition("-64"), -64)
        XCTAssertEqual(try AXMixingReadback.panPosition("63"), 63)
    }

    func testUnreadablePanCannotCertifyCenterOrSatisfyCompareAndSet() {
        for raw in ["", "center", "unavailable", "0.0", "NaN"] {
            XCTAssertThrowsError(try AXMixingReadback.panPosition(raw))
        }
    }
}
