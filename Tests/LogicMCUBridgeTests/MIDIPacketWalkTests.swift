import CoreMIDI
import XCTest
@testable import LogicMCUBridge

/// The packet-list walk. A single-packet list was always fine; the bug that
/// killed the running daemon (SIGBUS in the read callback, 2026-08-28, at a
/// project close/open) only appears from the SECOND packet on, so every test
/// here that matters builds a multi-packet list.
final class MIDIPacketWalkTests: XCTestCase {

    /// Builds a real `MIDIPacketList` the way CoreMIDI does and hands it to
    /// `body`. Using `MIDIPacketListAdd` rather than a hand-laid struct is the
    /// point: the packet stride (alignment, padding) is CoreMIDI's, not ours.
    private func withPacketList(
        _ packets: [[UInt8]], capacity: Int = 4096, _ body: (UnsafePointer<MIDIPacketList>) -> Void
    ) {
        var storage = [UInt8](repeating: 0, count: capacity)
        storage.withUnsafeMutableBytes { raw in
            let list = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
            var cursor = MIDIPacketListInit(list)
            for (index, bytes) in packets.enumerated() {
                cursor = MIDIPacketListAdd(
                    list, capacity, cursor, MIDITimeStamp(index), bytes.count, bytes
                )
            }
            body(UnsafePointer(list))
        }
    }

    func testSinglePacketRoundTrips() {
        withPacketList([[0x90, 0x3C, 0x7F]]) { list in
            XCTAssertEqual(midiPacketBytes(in: list), [[0x90, 0x3C, 0x7F]])
        }
    }

    /// THE regression. Eight packets is what an MCU surface rebuild looks
    /// like; the old loop read the second one and everything after it off the
    /// stack, which is the crash that was observed.
    func testEveryPacketOfAMultiPacketListIsReadInOrder() {
        let burst: [[UInt8]] = [
            [0x90, 0x00, 0x7F],
            [0x90, 0x01, 0x00],
            [0xD0, 0x35],
            [0xE0, 0x00, 0x40],
            [0xB0, 0x30, 0x41],
            [0x90, 0x2E, 0x7F],
            [0xE7, 0x7F, 0x7F],
            [0x90, 0x07, 0x00]
        ]
        withPacketList(burst) { list in
            XCTAssertEqual(midiPacketBytes(in: list), burst)
        }
    }

    func testEmptyListYieldsNothing() {
        withPacketList([]) { list in
            XCTAssertTrue(midiPacketBytes(in: list).isEmpty)
        }
    }

    /// A SysEx longer than the 256-byte `data` tuple must be clamped, not read
    /// past — the other way this callback could have wandered out of bounds.
    func testAnOverlongPacketIsClampedRatherThanOverread() {
        let long = [UInt8(0xF0)] + [UInt8](repeating: 0x7F, count: 400) + [UInt8(0xF7)]
        withPacketList([long]) { list in
            let read = midiPacketBytes(in: list)
            XCTAssertEqual(read.count, 1)
            XCTAssertLessThanOrEqual(read[0].count, 256)
            XCTAssertEqual(read[0].first, 0xF0)
        }
    }

    /// The parser downstream must survive the same burst — this is the whole
    /// path the crash sat in.
    func testDecodedBurstReachesTheParser() {
        let parser = MIDIParser()
        // Three distinct LED notes, one per packet: the second and third only
        // arrive if the walk left the stack copy behind.
        parser.feed([0x80, 0x21, 0x00])
        parser.feed([0x80, 0x22, 0x00])
        parser.feed([0x80, 0x23, 0x00])
        withPacketList([[0x90, 0x21, 0x7F], [0x90, 0x22, 0x7F], [0x90, 0x23, 0x7F]]) { list in
            for bytes in midiPacketBytes(in: list) { parser.feed(bytes) }
        }
        let lit = Set(state.snapshot().ledsLit)
        XCTAssertTrue(lit.isSuperset(of: [0x21, 0x22, 0x23]))
    }
}
