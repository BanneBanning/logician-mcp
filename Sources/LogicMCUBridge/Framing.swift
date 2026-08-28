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
