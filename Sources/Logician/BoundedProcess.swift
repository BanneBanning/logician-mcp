import Foundation
import Darwin

/// Runs a child without letting its output pipes or lifetime block the tool
/// executor indefinitely. Killing the child does not undo an Apple Event it
/// has already sent; callers must still verify the state of Logic afterwards.
enum BoundedProcess {
    enum Outcome: Equatable {
        case exited(Int32)
        case timedOut
        case cancelled
        case outputLimit
        case cleanupFailed
    }

    struct Result {
        let outcome: Outcome
        let stdout: Data
        let stderr: Data
        let processID: Int32
    }

    static func run(
        executable: String, arguments: [String], timeout: TimeInterval,
        outputLimit: Int = 1_048_576, cancelled: () -> Bool = { Task.isCancelled }
    ) throws -> Result {
        guard timeout.isFinite, timeout > 0, outputLimit >= 0 else {
            throw LogicianError.invalidArguments("invalid process deadline or output limit")
        }
        if cancelled() {
            return Result(outcome: .cancelled, stdout: Data(), stderr: Data(), processID: 0)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let pipes = [output, errors]
        defer {
            for pipe in pipes {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
        }
        for pipe in pipes {
            let fd = pipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw LogicianError.writeFailed("could not configure child output pipes")
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try process.run()
        func stopChild() -> Bool {
            guard process.isRunning else { return true }
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            let reapDeadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < reapDeadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            return !process.isRunning
        }
        defer { _ = stopChild() }
        for pipe in pipes { try? pipe.fileHandleForWriting.close() }
        var buffers = [Data(), Data()]
        var eof = [false, false]
        var chunk = [UInt8](repeating: 0, count: 16_384)
        var outcome: Outcome?
        while outcome == nil {
            if cancelled() { outcome = .cancelled; break }
            if ProcessInfo.processInfo.systemUptime >= deadline { outcome = .timedOut; break }
            for index in pipes.indices where !eof[index] {
                let count = chunk.withUnsafeMutableBytes {
                    Darwin.read(pipes[index].fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    let remaining = outputLimit - buffers[0].count - buffers[1].count
                    buffers[index].append(contentsOf: chunk.prefix(min(count, remaining)))
                    if count > remaining { outcome = .outputLimit; break }
                } else if count == 0 {
                    eof[index] = true
                } else if errno != EAGAIN && errno != EINTR && errno != EWOULDBLOCK {
                    throw LogicianError.writeFailed("could not read child output")
                }
            }
            if outcome != nil { break }
            if !process.isRunning && eof.allSatisfy({ $0 }) {
                outcome = .exited(process.terminationStatus)
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        if !stopChild() { outcome = .cleanupFailed }
        return Result(
            outcome: outcome ?? .cleanupFailed, stdout: buffers[0], stderr: buffers[1],
            processID: process.processIdentifier
        )
    }
}
