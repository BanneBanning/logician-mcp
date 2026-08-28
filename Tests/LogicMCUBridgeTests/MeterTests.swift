import XCTest
@testable import LogicMCUBridge

/// The channel-meter grammar (G56) and its path through the parser.
///
/// These bytes were RECEIVED AND DISCARDED from the first day of the bridge,
/// so there is no historical behaviour to preserve — only a published
/// convention to implement exactly. The live decode against Logic is still
/// pending a daemon restart (the running daemon is a pre-protocol-5 build and
/// cannot be replaced mid-session), which is precisely why the grammar is
/// pinned here against synthesized bytes: when the live run happens, a
/// disagreement will point at Logic's dialect rather than at our arithmetic.
final class MCUMeterTests: XCTestCase {

    // MARK: The pure grammar

    func testHighNibbleIsTheChannelAndLowNibbleTheSegment() {
        XCTAssertEqual(MCUMeter.decode(0x00), .level(channel: 0, segment: 0))
        XCTAssertEqual(MCUMeter.decode(0x05), .level(channel: 0, segment: 5))
        XCTAssertEqual(MCUMeter.decode(0x30), .level(channel: 3, segment: 0))
        XCTAssertEqual(MCUMeter.decode(0x37), .level(channel: 3, segment: 7))
        XCTAssertEqual(MCUMeter.decode(0x7C), .level(channel: 7, segment: 12))
    }

    func testTopSegmentIsTwelveNotFifteen() {
        // 0x0D/0x0E/0x0F are NOT levels; reading them as such would report a
        // silent strip as hotter than a clipping one.
        XCTAssertEqual(MCUMeter.decode(0x2C), .level(channel: 2, segment: MCUMeter.topSegment))
        if case .level = MCUMeter.decode(0x2D) {
            XCTFail("0x0D must not decode as a level")
        }
    }

    func testOverloadIsSetByEAndClearedByF() {
        XCTAssertEqual(MCUMeter.decode(0x4E), .overload(channel: 4, on: true))
        XCTAssertEqual(MCUMeter.decode(0x4F), .overload(channel: 4, on: false))
    }

    func testUndefinedCodeIsReportedRatherThanGuessed() {
        XCTAssertEqual(MCUMeter.decode(0x6D), .unknown(channel: 6, code: 0x0D))
    }

    func testEveryByteDecodesToSomething() {
        // Total by construction: a nil here becomes an unhandled branch three
        // layers up, and the high bit must not escape into a 9th channel.
        for byte in UInt8.min...UInt8.max {
            switch MCUMeter.decode(byte) {
            case .level(let channel, let segment):
                XCTAssertTrue((0..<8).contains(channel))
                XCTAssertTrue((0...MCUMeter.topSegment).contains(segment))
            case .overload(let channel, _), .unknown(let channel, _):
                XCTAssertTrue((0..<8).contains(channel))
            }
        }
    }

    // MARK: State transitions

    func testOverloadDoesNotDisturbTheLevel() {
        var levels = [Int](repeating: -1, count: 8)
        var overloads = [Bool](repeating: false, count: 8)
        MCUMeter.apply(.level(channel: 2, segment: 9), levels: &levels, overloads: &overloads)
        MCUMeter.apply(.overload(channel: 2, on: true), levels: &levels, overloads: &overloads)
        XCTAssertEqual(levels[2], 9)
        XCTAssertTrue(overloads[2])
        MCUMeter.apply(.overload(channel: 2, on: false), levels: &levels, overloads: &overloads)
        XCTAssertEqual(levels[2], 9, "clearing the clip LED must not zero the level")
        XCTAssertFalse(overloads[2])
    }

    func testUnknownCodeChangesNothing() {
        var levels = [Int](repeating: 4, count: 8)
        var overloads = [Bool](repeating: false, count: 8)
        MCUMeter.apply(.unknown(channel: 1, code: 0x0D), levels: &levels, overloads: &overloads)
        XCTAssertEqual(levels, [Int](repeating: 4, count: 8))
        XCTAssertEqual(overloads, [Bool](repeating: false, count: 8))
    }

    func testOutOfRangeChannelIsIgnoredRatherThanTrapping() {
        var levels = [Int](repeating: -1, count: 2) // deliberately short
        var overloads = [Bool](repeating: false, count: 2)
        MCUMeter.apply(.level(channel: 7, segment: 3), levels: &levels, overloads: &overloads)
        MCUMeter.apply(.overload(channel: 7, on: true), levels: &levels, overloads: &overloads)
        XCTAssertEqual(levels, [-1, -1])
    }

    // MARK: Through the parser

    func testChannelPressureUpdatesTheMirroredMeters() {
        let parser = MIDIParser()
        parser.feed([0xD0, 0x05]) // channel 0, segment 5
        parser.feed([0xD0, 0x7C]) // channel 7, top segment
        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.meterLevels[0], 5)
        XCTAssertEqual(snapshot.meterLevels[7], 12)
    }

    func testChannelPressureConsumesExactlyOneDataByte() {
        // 0xD0 is channel pressure: ONE data byte. Consuming two would eat the
        // following status byte and desynchronise the whole stream.
        let parser = MIDIParser()
        parser.feed([0xD0, 0x21, 0x90, 0x5E, 0x7F])
        XCTAssertEqual(state.snapshot().meterLevels[2], 1)
        XCTAssertTrue(state.snapshot().ledsLit.contains(0x5E),
                      "the note-on after a meter byte must still be parsed")
    }

    func testRunningStatusStreamsManyMetersInOnePacket() {
        // A real host sends one status byte and then a byte per channel.
        let parser = MIDIParser()
        parser.feed([0xD0, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77])
        let levels = state.snapshot().meterLevels
        XCTAssertEqual(levels, [0, 1, 2, 3, 4, 5, 6, 7])
    }

    func testOverloadArrivesThroughTheParser() {
        let parser = MIDIParser()
        parser.feed([0xD0, 0x3E])
        XCTAssertTrue(state.snapshot().meterOverloads[3])
        parser.feed([0xD0, 0x3F])
        XCTAssertFalse(state.snapshot().meterOverloads[3])
    }

    /// The design decision that keeps playback from breaking name resolution.
    func testMetersDoNotCountAsOrdinaryEventsOrRefreshLiveness() {
        let parser = MIDIParser()
        let before = state.snapshot()
        parser.feed([0xD0, 0x44, 0x55, 0x66])
        let after = state.snapshot()
        XCTAssertEqual(after.receivedEvents, before.receivedEvents,
                       "meters must not tick received_events: awaitEvents/settle logic"
                           + " waits for SILENCE, which playback would then never reach")
        XCTAssertEqual(after.lastReceive, before.lastReceive)
        XCTAssertGreaterThan(after.meterEvents, before.meterEvents,
                             "but they must be counted somewhere, or 'Logic sends no"
                                 + " meters' cannot be told from 'all strips are silent'")
    }

    func testPolyphonicAftertouchIsStillSkippedAsTwoBytes() {
        let parser = MIDIParser()
        parser.feed([0xA0, 0x10, 0x20, 0x90, 0x5D, 0x7F])
        XCTAssertTrue(state.snapshot().ledsLit.contains(0x5D))
    }
}
