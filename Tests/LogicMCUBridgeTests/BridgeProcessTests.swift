import XCTest
@testable import LogicMCUBridge

final class BridgeProcessTests: XCTestCase {
    /// A real Unix listener, with a path containing spaces, proves that peer
    /// identity comes from the kernel without parsing a command line or PID file.
    /// This never launches a bridge, opens CoreMIDI, or signals a process.
    func testSocketOwnerIsIdentifiedAndOwnProcessIsExcluded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge test \(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("peer.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        try XCTSkipIf(bytes.count > MemoryLayout.size(ofValue: address.sun_path), "temporary path too long")
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(result, 0)
        XCTAssertEqual(listen(fd, 4), 0)
        XCTAssertEqual(BridgeProcess.daemonPID(socketPath: path, excluding: -1), getpid())
        XCTAssertNil(BridgeProcess.daemonPID(socketPath: path, excluding: getpid()))
    }

    func testMissingOrOverlongSocketPathDoesNotProduceATarget() {
        XCTAssertNil(BridgeProcess.daemonPID(socketPath: "/no-such-bridge-\(UUID().uuidString)", excluding: getpid()))
        XCTAssertNil(BridgeProcess.daemonPID(socketPath: String(repeating: "x", count: 200), excluding: getpid()))
    }

    func testDiagnosticPidFileParsing() {
        XCTAssertEqual(BridgeProcess.parsePidFile("24761\n"), 24761)
        for invalid in ["", "\n", "not a pid", "0", "1", "-5"] {
            XCTAssertNil(BridgeProcess.parsePidFile(invalid))
        }
    }
}
