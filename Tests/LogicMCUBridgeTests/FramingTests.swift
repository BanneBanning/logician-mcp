import XCTest
@testable import LogicMCUBridge

/// The socket framing that used to truncate every command past the socket
/// receive buffer (~8 KB), which made logic_record_midi fail above roughly
/// 130 notes with a misleading "invalid JSON".
final class FramingTests: XCTestCase {
    /// Creates a connected socket pair; returns (a, b).
    private func makeSocketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        try XCTSkipIf(result != 0, "socketpair unavailable")
        return (fds[0], fds[1])
    }

    func testRoundTripsPayloadLargerThanTheSocketBuffer() throws {
        let (writer, reader) = try makeSocketPair()
        defer { close(writer); close(reader) }

        // 512 KB: far past any plausible socket receive buffer, and past the
        // 140 KB real-world midi_stream case that motivated the fix.
        let payload = Data(repeating: UInt8(ascii: "x"), count: 512 * 1024)

        let writeQueue = DispatchQueue(label: "framing.write")
        writeQueue.async {
            XCTAssertTrue(writeAll(writer, payload))
            shutdown(writer, SHUT_WR)
        }

        let received = readToEOF(reader)
        XCTAssertEqual(received.count, payload.count)
        XCTAssertEqual(received, payload)
    }

    func testReadToEOFReturnsEverythingWrittenInSeveralChunks() throws {
        let (writer, reader) = try makeSocketPair()
        defer { close(writer); close(reader) }

        let chunks = (0..<40).map { index in
            Data("chunk-\(index);".utf8)
        }
        DispatchQueue(label: "framing.chunks").async {
            for chunk in chunks {
                XCTAssertTrue(writeAll(writer, chunk))
                usleep(200) // force separate reads on the other side
            }
            shutdown(writer, SHUT_WR)
        }

        let received = readToEOF(reader)
        XCTAssertEqual(received, chunks.reduce(Data(), +))
    }

    func testReadToEOFOnAnAlreadyClosedPeerIsEmptyRatherThanHanging() throws {
        let (writer, reader) = try makeSocketPair()
        defer { close(reader) }
        close(writer)
        XCTAssertTrue(readToEOF(reader).isEmpty)
    }

    func testWriteAllReportsFailureWhenThePeerIsGone() throws {
        let (writer, reader) = try makeSocketPair()
        defer { close(writer) }
        close(reader)
        signal(SIGPIPE, SIG_IGN) // otherwise the process dies instead of erroring
        // Large enough that it cannot all disappear into the send buffer.
        let payload = Data(repeating: 0x41, count: 4 * 1024 * 1024)
        XCTAssertFalse(writeAll(writer, payload))
    }

    func testRoundTripsJSONThatTheBridgeWouldActuallyReceive() throws {
        let (writer, reader) = try makeSocketPair()
        defer { close(writer); close(reader) }

        // Shaped like a real midi_stream: 3,000 notes = 6,000 events.
        var events: [[Any]] = []
        for index in 0..<3000 {
            let time = Double(index) * 20.0
            events.append([time, 144, 60 + (index % 24), 100])
            events.append([time + 15.0, 128, 60 + (index % 24), 0])
        }
        let command: [String: Any] = ["cmd": "midi_stream", "events": events]
        let payload = try JSONSerialization.data(withJSONObject: command)
        XCTAssertGreaterThan(payload.count, 64 * 1024, "test should exceed the old single-read buffer")

        DispatchQueue(label: "framing.json").async {
            XCTAssertTrue(writeAll(writer, payload))
            shutdown(writer, SHUT_WR)
        }
        let received = readToEOF(reader)
        let decoded = try JSONSerialization.jsonObject(with: received) as? [String: Any]
        XCTAssertEqual(decoded?["cmd"] as? String, "midi_stream")
        XCTAssertEqual((decoded?["events"] as? [[Any]])?.count, 6000)
    }

    func testProtocolVersionIsDefinedOnceAndIsCurrent() {
        // The server requires >= this from a running daemon; the bridge
        // answers with the same symbol. One definition, no skew.
        XCTAssertGreaterThanOrEqual(bridgeProtocolVersion, 3)
    }
}
