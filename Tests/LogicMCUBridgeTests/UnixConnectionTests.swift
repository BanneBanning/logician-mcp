import XCTest
@testable import LogicMCUBridge

final class UnixConnectionTests: XCTestCase {
    func testConnectAndFullDuplexFrameUseTheSameDeadline() throws {
        let path = "/tmp/logician-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(listener); close(client); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [UInt8(0)]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        XCTAssertEqual(fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK), 0)
        let deadline = Date().addingTimeInterval(0.3)
        XCTAssertTrue(connectUnixSocket(client, path: path, deadline: deadline))
        let peer = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { close(peer) }
        XCTAssertTrue(writeAll(client, Data("request".utf8), deadline: deadline))
        shutdown(client, SHUT_WR)
        XCTAssertEqual(readToEOF(peer), Data("request".utf8))
        // A syntactically valid prefix is not a complete response. In
        // particular, the client must not execute/replay the request again.
        XCTAssertTrue(writeAll(peer, Data("{\"ok\":true}".utf8)))
        XCTAssertEqual(readToEOF(client, deadline: deadline), .timedOut)
    }

    func testMissingAndUnrepresentableAddressesRefuse() {
        for path in ["/tmp/no-such-logician-\(UUID().uuidString)", String(repeating: "x", count: 110), "bad\0path"] {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            XCTAssertEqual(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK), 0)
            XCTAssertFalse(connectUnixSocket(fd, path: path, deadline: Date().addingTimeInterval(0.2)))
        }
    }
}
