import Foundation

public enum BridgeProcess {
    public static let lockFileName = "bridge.lock"

    /// Identifies the process that owns the connected Unix socket using the
    /// kernel's peer credentials. A lockfile PID can outlive its process and
    /// be reused; text from `ps` cannot distinguish argv[0] from an argument
    /// that happens to contain our executable name. Neither is a kill target.
    /// No command is sent and no MIDI is emitted by this probe.
    public static func daemonPID(socketPath: String, excluding own: Int32) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&descriptor, 1, 1000) > 0 else { return nil }
            var socketError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0,
                  socketError == 0 else { return nil }
        }
        var pid: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
              pid > 1, pid != own else { return nil }
        return pid
    }

    /// The pid file remains useful for diagnostics, never as authority to kill.
    public static func parsePidFile(_ contents: String) -> Int32? {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmed), pid > 1 else { return nil }
        return pid
    }
}
