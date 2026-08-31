import XCTest
@testable import LogicMCUBridge

/// The deadline-bounded framing that keeps a stuck peer from wedging the
/// daemon. On 2026-08-31 a client connected to the command socket and never
/// completed its transaction; the daemon's single accept-and-handle thread
/// blocked forever inside an unbounded read, and every later connection hung
/// behind it. These tests pin the two properties the fix rests on: a peer
/// that never finishes its frame is TIMED OUT (not waited on, not answered
/// from a partial frame), and a peer that stops reading its reply cannot
/// stall the writer past its deadline.
final class ConnectionDeadlineTests: XCTestCase {
    /// Creates a connected socket pair; returns (a, b). Same fixture as
    /// FramingTests, minus the SO_RCVTIMEO belt: here the deadline under test
    /// is the thing that must cut the wait short.
    private func makeSocketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        try XCTSkipIf(result != 0, "socketpair unavailable")
        // Several of these tests close one end while the other is still
        // writing (that is the point); the write must error, not SIGPIPE the
        // test runner — the same choice serveConnection makes for the daemon.
        var noSigpipe: Int32 = 1
        for fd in fds {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
                       socklen_t(MemoryLayout<Int32>.size))
        }
        return (fds[0], fds[1])
    }

    private func setNonBlocking(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    /// Runs `work` on a REAL OS thread (see FramingTests.onSeparateThread for
    /// why a GCD queue can starve these blocking-reader tests).
    private func onSeparateThread(_ work: @escaping () -> Void) {
        Thread.detachNewThread(work)
    }

    private func deadline(_ seconds: Double) -> Date {
        Date().addingTimeInterval(seconds)
    }

    // MARK: readToEOF(deadline:)

    func testDeadlineReadCompletesANormalFrame() throws {
        let (writer, reader) = try makeSocketPair()
        defer { close(writer); close(reader) }
        setNonBlocking(reader)

        let payload = Data(repeating: UInt8(ascii: "x"), count: 512 * 1024)
        onSeparateThread {
            XCTAssertTrue(writeAll(writer, payload))
            shutdown(writer, SHUT_WR)
        }
        XCTAssertEqual(readToEOF(reader, deadline: deadline(20)), .complete(payload))
    }

    func testDeadlineReadTimesOutOnAPeerThatNeverWrites() throws {
        // The exact shape of the 2026-08-31 wedge: connected, silent, open.
        let (writer, reader) = try makeSocketPair()
        defer { close(writer); close(reader) }
        setNonBlocking(reader)

        let started = Date()
        XCTAssertEqual(readToEOF(reader, deadline: deadline(0.2)), .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "the deadline must actually cut the wait short")
    }

    func testDeadlineReadTimesOutOnAPeerThatNeverHalfCloses() throws {
        // Half a command and then silence: the partial frame must NOT come
        // back as .complete, or it would be parsed and answered as if whole.
        let (writer, reader) = try makeSocketPair()
        defer { close(writer); close(reader) }
        setNonBlocking(reader)

        XCTAssertTrue(writeAll(writer, Data("{\"cmd\": \"pi".utf8)))
        XCTAssertEqual(readToEOF(reader, deadline: deadline(0.2)), .timedOut)
    }

    func testDeadlineReadTimesOutOnATricklingPeerDespiteEachByteArriving() throws {
        // A per-read timeout (SO_RCVTIMEO) never fires against a peer that
        // keeps sending SOMETHING; the frame deadline is what bounds this.
        let (writer, reader) = try makeSocketPair()
        defer { close(reader) }
        setNonBlocking(reader)

        onSeparateThread {
            for _ in 0..<100 {
                guard writeAll(writer, Data([UInt8(ascii: "x")])) else { break }
                usleep(20_000)
            }
            close(writer)
        }
        let started = Date()
        XCTAssertEqual(readToEOF(reader, deadline: deadline(0.3)), .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testDeadlineReadOnAnAlreadyClosedPeerIsAnEmptyCompleteFrame() throws {
        let (writer, reader) = try makeSocketPair()
        defer { close(reader) }
        setNonBlocking(reader)
        close(writer)
        XCTAssertEqual(readToEOF(reader, deadline: deadline(5)), .complete(Data()))
    }

    // MARK: writeAll(deadline:)

    func testDeadlineWriteDeliversALargeReplyToAReadingPeer() throws {
        let (reader, writer) = try makeSocketPair()
        defer { close(writer); close(reader) }
        setNonBlocking(writer)

        let payload = Data(repeating: 0x42, count: 4 * 1024 * 1024)
        let drained = expectation(description: "peer drained the reply")
        onSeparateThread {
            var timeout = timeval(tv_sec: 20, tv_usec: 0)
            setsockopt(reader, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))
            let received = readToEOF(reader)
            XCTAssertEqual(received.count, payload.count)
            drained.fulfill()
        }
        XCTAssertTrue(writeAll(writer, payload, deadline: deadline(20)))
        shutdown(writer, SHUT_WR)
        wait(for: [drained], timeout: 20)
    }

    func testDeadlineWriteGivesUpOnAPeerThatStoppedReading() throws {
        // The reply-side mirror of the wedge: the peer holds its end open but
        // never drains, so the send buffer fills and stays full.
        let (reader, writer) = try makeSocketPair()
        defer { close(writer); close(reader) }
        setNonBlocking(writer)

        let payload = Data(repeating: 0x41, count: 4 * 1024 * 1024)
        let started = Date()
        XCTAssertFalse(writeAll(writer, payload, deadline: deadline(0.3)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: The daemon's per-connection service, end to end

    func testServeConnectionAnswersAPingAndCloses() throws {
        let (client, server) = try makeSocketPair()
        defer { close(client) } // server side is closed by serveConnection

        let served = expectation(description: "connection served")
        onSeparateThread {
            serveConnection(server)
            served.fulfill()
        }
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        XCTAssertTrue(writeAll(client, Data("{\"cmd\": \"ping\"}".utf8)))
        shutdown(client, SHUT_WR)
        let reply = readToEOF(client)
        wait(for: [served], timeout: 20)

        let decoded = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        XCTAssertEqual(decoded?["ok"] as? Bool, true)
        XCTAssertEqual(decoded?["pong"] as? Bool, true)
        XCTAssertEqual(decoded?["bridge_protocol"] as? Int, bridgeProtocolVersion)
    }

    func testServeConnectionDropsAStuckPeerInsteadOfWaitingForever() throws {
        // A one-off scaled-down deadline would be nicer, but the timeout is a
        // file-level constant by design (one number to reason about), so this
        // test rides the real 10 s one. It stays well under the suite's
        // tolerance and is the single test that proves the daemon-side wedge
        // is actually gone.
        let (client, server) = try makeSocketPair()
        defer { close(client) }

        let served = expectation(description: "stuck connection dropped")
        onSeparateThread {
            serveConnection(server) // the peer never writes, never closes
            served.fulfill()
        }
        wait(for: [served], timeout: connectionIOTimeout + 10)

        // The dropped peer sees a bare close, no reply bytes.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        XCTAssertTrue(readToEOF(client).isEmpty)
    }
}
