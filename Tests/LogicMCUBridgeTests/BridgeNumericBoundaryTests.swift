import XCTest
@testable import LogicMCUBridge

final class BridgeNumericBoundaryTests: XCTestCase {
    func testVPotClampsBothIntegerExtremesWithoutLosingDirection() {
        XCTAssertEqual(vpotValue(delta: Int.min), 0x7F)
        XCTAssertEqual(vpotValue(delta: Int.max), 0x3F)
        XCTAssertEqual(vpotValue(delta: -12), 0x4C)
        XCTAssertEqual(vpotValue(delta: 12), 12)
        XCTAssertEqual(vpotValue(delta: 0), 0)
    }

    func testKeyCommandChannelWrappingDoesNotOverflow() {
        XCTAssertEqual(keyCommandChannel(1), 0)
        XCTAssertEqual(keyCommandChannel(16), 15)
        XCTAssertEqual(keyCommandChannel(0), 15)
        XCTAssertEqual(keyCommandChannel(Int.min), 15)
        XCTAssertEqual(keyCommandChannel(Int.max), 14)
    }

    func testConvergenceClampsBeforeIntegerConversionAndRejectsOverflow() {
        XCTAssertEqual(convergenceTicks(target: 1e300, current: 0, ratio: 2), 60)
        XCTAssertEqual(convergenceTicks(target: -1e300, current: 0, ratio: 2), -60)
        XCTAssertNil(convergenceTicks(target: 1e300, current: 0, ratio: 1e300))
        XCTAssertEqual(convergenceTicks(target: -6, current: -8, ratio: 2), 4)
    }

    func testStreamOffsetRejectsUnrepresentableTimesBeforeStartingPlayback() throws {
        for offset in [1e300, Double.infinity, Double.nan, -1] {
            XCTAssertFalse(validMIDIStreamOffset(offset))
        }
        XCTAssertTrue(validMIDIStreamOffset(0))
        XCTAssertTrue(validMIDIStreamOffset(3_600_000.5))
        let command = try bridgeJSONDecoder.decode(
            BridgeCommand.self, from: Data(#"{"cmd":"midi_stream","events":[[1e300,144,60,100]]}"#.utf8)
        )
        let response = handleCommand(command)
        XCTAssertFalse(response.ok)
        XCTAssertFalse(isMIDIStreamActive(), "an invalid event must not start a playback thread")
    }
}
