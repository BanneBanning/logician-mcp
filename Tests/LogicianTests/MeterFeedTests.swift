import XCTest
@testable import Logician

/// How the server reads Logic's meter feed out of a surface status, and — the
/// part that actually matters — how it tells "no feed" apart from "silence".
///
/// `logic_mixer_snapshot` is a READ tool, so its whole value is that a number
/// in the result came from Logic. A meter invented by a defaulting `?? 0`
/// would look exactly like a real silent strip, and an agent deciding gain
/// staging off it would be reasoning about our default instead of the mix.
final class MeterFeedTests: XCTestCase {

    func testAbsentMeterKeysMeanNoFeedRatherThanSilence() {
        let status: [String: Any] = ["lcd_top": "x", "received_events": 12]
        XCTAssertNil(MCUController.meterReading(in: status))
        XCTAssertFalse(MCUController.meterFeedSeen(in: status))
    }

    func testAnEmptyMeterArrayIsAlsoNoFeed() {
        // A protocol-5 daemon that has decoded nothing yet publishes the key
        // with an empty array; that is still "cannot tell you".
        let status: [String: Any] = ["meter_levels": [Int](), "meter_events": 0]
        XCTAssertNil(MCUController.meterReading(in: status))
        XCTAssertFalse(MCUController.meterFeedSeen(in: status))
    }

    func testSilentStripsAreReportedAsZeroNotAsAbsent() {
        let status: [String: Any] = [
            "meter_levels": [Int](repeating: 0, count: 8),
            "meter_overloads": [Bool](repeating: false, count: 8),
            "meter_events": 512
        ]
        let reading = MCUController.meterReading(in: status)
        XCTAssertNotNil(reading)
        XCTAssertEqual(reading?.levels, [Int](repeating: 0, count: 8))
        XCTAssertTrue(MCUController.meterFeedSeen(in: status))
    }

    func testLevelsAndOverloadsAreReadTogether() {
        let status: [String: Any] = [
            "meter_levels": [0, 3, 12, -1, 5, 6, 7, 8],
            "meter_overloads": [false, false, true, false, false, false, false, false],
            "meter_events": 3
        ]
        let reading = MCUController.meterReading(in: status)
        XCTAssertEqual(reading?.levels[2], 12)
        XCTAssertEqual(reading?.overloads[2], true)
        XCTAssertEqual(reading?.levels[3], -1, "never-reported stays -1, not 0")
    }

    func testMissingOverloadsDoNotLoseTheLevels() {
        // Levels without overloads is a shape a partial daemon could produce;
        // it must degrade to "levels, no clip info", not to nothing.
        let status: [String: Any] = ["meter_levels": [1, 2, 3], "meter_events": 1]
        let reading = MCUController.meterReading(in: status)
        XCTAssertEqual(reading?.levels, [1, 2, 3])
        XCTAssertEqual(reading?.overloads, [])
    }

    func testMeterEventsSeenEvenWhenLevelsAreAllSilent() {
        // The counter is the evidence that the FEED exists. Without it, a
        // project paused at silence and a daemon that never decodes a meter
        // are indistinguishable — which is the open question G56's live run
        // has to answer.
        let status: [String: Any] = [
            "meter_levels": [Int](repeating: 0, count: 8), "meter_events": 4096
        ]
        XCTAssertTrue(MCUController.meterFeedSeen(in: status))
    }
}
