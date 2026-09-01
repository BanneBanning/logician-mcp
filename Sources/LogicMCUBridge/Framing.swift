// Shared socket framing for the server ⇄ bridge command channel.
//
// Both sides import this file's module, so there is ONE implementation of
// "write all of it" and "read until the peer is done" instead of two hopeful
// single-syscall shortcuts. The previous code did one write() and one read()
// of a 64 KB buffer with the return values discarded, which silently
// truncated any command larger than the socket receive buffer (measured at
// 8 KB on macOS) — logic_record_midi failed above roughly 130 notes with a
// misleading "invalid JSON", while the bridge advertised a 20,000-event cap.
//
// Framing rule: one command per connection, terminated by the sender
// half-closing its write side (shutdown(SHUT_WR)); the reply is terminated by
// the bridge closing the connection. So "read to EOF" is well-defined in both
// directions and needs no length prefix.

import Foundation

/// Writes every byte, retrying short writes and EINTR. Returns false if the
/// peer went away mid-write (EPIPE) or the socket errored.
@discardableResult
public func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var sent = 0
    return data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        while sent < data.count {
            let written = Darwin.write(fd, base.advanced(by: sent), data.count - sent)
            if written > 0 {
                sent += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            return false
        }
        return true
    }
}

/// Reads until the peer half-closes or closes (EOF). `limit` is a safety stop
/// so a stuck or hostile peer cannot grow this unboundedly.
public func readToEOF(_ fd: Int32, limit: Int = 8 * 1024 * 1024) -> Data {
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while data.count < limit {
        let count = chunk.withUnsafeMutableBytes { raw -> Int in
            Darwin.read(fd, raw.baseAddress, raw.count)
        }
        if count > 0 {
            data.append(contentsOf: chunk[0..<count])
            continue
        }
        if count < 0, errno == EINTR { continue }
        break // 0 = EOF, negative = error
    }
    return data
}

// MARK: - Deadline-bounded framing (the daemon's side)

/// What a deadline-bounded read of one frame ended as.
public enum DeadlineReadResult: Equatable {
    /// The peer half-closed; the frame is complete (possibly empty).
    case complete(Data)
    /// The deadline expired before the peer finished its frame. Whatever was
    /// received so far is deliberately NOT surfaced: a partial command must
    /// never be parsed and answered as if it were the whole one.
    case timedOut
    /// The socket errored.
    case failed
}

/// Like `readToEOF`, but gives up at `deadline` instead of trusting the peer
/// to eventually half-close.
///
/// This exists because trusting the peer is exactly what wedged the daemon on
/// 2026-08-31: one client connected and never completed its transaction, and
/// the read blocked forever. The deadline bounds the WHOLE frame, not each
/// read — a peer trickling one byte per poll interval is cut off just the
/// same, which SO_RCVTIMEO alone would not do.
public func readToEOF(
    _ fd: Int32, limit: Int = 8 * 1024 * 1024, deadline: Date
) -> DeadlineReadResult {
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while data.count < limit {
        guard waitFor(fd, events: Int16(POLLIN), deadline: deadline) else {
            return .timedOut
        }
        let count = chunk.withUnsafeMutableBytes { raw -> Int in
            Darwin.read(fd, raw.baseAddress, raw.count)
        }
        if count > 0 {
            data.append(contentsOf: chunk[0..<count])
            continue
        }
        if count == 0 { return .complete(data) }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
        return .failed
    }
    // At the safety limit without EOF: same shape the un-deadlined reader
    // hands out, so an oversized frame still gets the "invalid JSON" reply
    // instead of a silent hang or a new failure mode.
    return .complete(data)
}

/// Like `writeAll`, but gives up at `deadline` instead of blocking on a peer
/// that stopped reading its reply. The fd should be non-blocking (the daemon
/// sets O_NONBLOCK on every accepted connection); on a blocking fd a single
/// large write could still stall past the deadline.
public func writeAll(_ fd: Int32, _ data: Data, deadline: Date) -> Bool {
    var sent = 0
    return data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        while sent < data.count {
            guard waitFor(fd, events: Int16(POLLOUT), deadline: deadline) else {
                return false
            }
            let written = Darwin.write(fd, base.advanced(by: sent), data.count - sent)
            if written > 0 {
                sent += written
                continue
            }
            if written < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            return false
        }
        return true
    }
}

/// Polls `fd` for `events` until it is ready or `deadline` passes.
/// True = ready (or the socket has an error/hangup pending, which the caller's
/// next read/write will surface properly); false = the deadline expired.
private func waitFor(_ fd: Int32, events: Int16, deadline: Date) -> Bool {
    while true {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let ms = Int32(min(remaining * 1000, 60_000).rounded(.up))
        let ready = poll(&descriptor, 1, ms)
        if ready > 0 { return true }
        if ready < 0, errno != EINTR, errno != EAGAIN { return false }
        // 0 = this poll slice elapsed; loop re-checks the real deadline.
    }
}

/// The bridge command protocol version, in ONE place. The server requires
/// `>= bridgeProtocolVersion` from a running daemon and replaces older ones;
/// keeping the literal here (instead of one copy per module) is what makes
/// the skew check itself immune to skew.
/// 4 (2026-08-28): the in-bridge convergence reads its echo through
/// `MCULCDRow.valueCell`. Version 3 dropped the rightmost strip's minus sign
/// and converged the wrong way, so the server refuses to converge cell 7 in a
/// daemon older than this and runs the loop itself instead.
/// 5 (2026-08-28): the snapshot grew `meter_levels`, `meter_overloads` and
/// `meter_events` (Logic's own per-strip meter feed, previously received and
/// discarded — G56), and `fader` gained an opt-in `verify` that answers with
/// `final_value` + `followed`. Both are ADDITIVE: an older daemon simply omits
/// the keys, `SurfaceSnapshot` defaults them rather than failing to decode,
/// and the server reports the meter feed as unavailable instead of empty.
public let bridgeProtocolVersion = 5
