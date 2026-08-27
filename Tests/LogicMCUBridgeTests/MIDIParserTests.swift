import XCTest
@testable import LogicMCUBridge

/// The running-status state machine that turns Logic's MIDI feedback into
/// the mirrored surface state. Bugs here surface three layers up as
/// inexplicable readback errors, so it is worth pinning down precisely.
///
/// Note: the parser writes into the module-global `state`, so these tests
/// read that back. They run serially (XCTest default) and each asserts only
/// on what it just fed.
final class MIDIParserTests: XCTestCase {
    private func snapshot() -> SurfaceSnapshot {
        state.snapshot()
    }

    private func lcdTop() -> String {
        snapshot().lcdTop
    }

    private func litLEDs() -> Set<Int> {
        Set(snapshot().ledsLit)
    }

    private func faders() -> [Int] {
        snapshot().faders14bit
    }

    func testNoteOnLightsALEDAndNoteOffClearsIt() {
        let parser = MIDIParser()
        parser.feed([0x90, 0x5E, 0x7F]) // play LED on
        XCTAssertTrue(litLEDs().contains(0x5E))

        parser.feed([0x80, 0x5E, 0x00]) // note off
        XCTAssertFalse(litLEDs().contains(0x5E))
    }

    func testNoteOnWithZeroVelocityCountsAsOff() {
        let parser = MIDIParser()
        parser.feed([0x90, 0x51, 0x7F])
        XCTAssertTrue(litLEDs().contains(0x51))

        parser.feed([0x90, 0x51, 0x00]) // the common "note on, velocity 0" idiom
        XCTAssertFalse(litLEDs().contains(0x51))
    }

    func testRunningStatusAppliesToFollowingDataPairs() {
        let parser = MIDIParser()
        // One status byte, then three note-on pairs relying on running status.
        parser.feed([0x90, 0x40, 0x7F, 0x41, 0x7F, 0x42, 0x7F])
        let lit = litLEDs()
        XCTAssertTrue(lit.contains(0x40))
        XCTAssertTrue(lit.contains(0x41))
        XCTAssertTrue(lit.contains(0x42))
    }

    func testRunningStatusSurvivesBeingSplitAcrossPackets() {
        let parser = MIDIParser()
        parser.feed([0x90, 0x30, 0x7F])
        parser.feed([0x31, 0x7F]) // continuation in a separate CoreMIDI packet
        XCTAssertTrue(litLEDs().contains(0x31))
    }

    func testPitchBendUpdatesTheFaderForItsChannel() {
        let parser = MIDIParser()
        // 14-bit value 8192 = LSB 0x00, MSB 0x40, on channel 3.
        parser.feed([0xE3, 0x00, 0x40])
        XCTAssertEqual(faders()[3], 8192)

        parser.feed([0xE3, 0x7F, 0x7F]) // maximum
        XCTAssertEqual(faders()[3], 16383)
    }

    func testSysexLCDWriteLandsAtTheGivenOffset() {
        let parser = MIDIParser()
        var message: [UInt8] = [0xF0, 0x00, 0x00, 0x66, 0x14, 0x12, 0x00]
        message.append(contentsOf: Array("HELLO".utf8))
        message.append(0xF7)
        parser.feed(message)
        XCTAssertTrue(lcdTop().hasPrefix("HELLO"))
    }

    func testSysexWithAForeignHeaderIsIgnored() {
        let parser = MIDIParser()
        let before = lcdTop()
        // Correct sysex framing, but not the Mackie manufacturer header.
        parser.feed([0xF0, 0x7E, 0x00, 0x06, 0x02, 0x41, 0xF7])
        XCTAssertEqual(lcdTop(), before)
    }

    func testUnterminatedSysexDoesNotSwallowTheFollowingMessage() {
        let parser = MIDIParser()
        // Sysex interrupted by a status byte (no 0xF7) — a real-world
        // truncation. The note-on after it must still register.
        parser.feed([0xF0, 0x00, 0x00, 0x66, 0x14, 0x12])
        parser.feed([0x90, 0x22, 0x7F])
        XCTAssertTrue(litLEDs().contains(0x22))
    }

    func testTruncatedPairAtTheEndOfAPacketDoesNotCrash() {
        let parser = MIDIParser()
        parser.feed([0x90, 0x60]) // status + one data byte, packet ends
        parser.feed([0x90, 0x61, 0x7F])
        XCTAssertTrue(litLEDs().contains(0x61))
    }

    func testFeedingRandomBytesNeverCrashes() {
        let parser = MIDIParser()
        var seed: UInt64 = 0x5EED_1234
        func nextByte() -> UInt8 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return UInt8((seed >> 33) & 0xFF)
        }
        for _ in 0..<200 {
            let length = Int(nextByte() % 16) + 1
            parser.feed((0..<length).map { _ in nextByte() })
        }
        // Reaching here without trapping is the assertion; confirm the state
        // is still coherent.
        XCTAssertEqual(faders().count, 9)
    }

    func testEmptyFeedIsHarmless() {
        let parser = MIDIParser()
        parser.feed([])
        XCTAssertEqual(faders().count, 9)
    }
}
