import CoreMIDI
import Foundation

/// Every packet in a CoreMIDI packet list, as byte arrays, in order.
///
/// This exists because the obvious loop is wrong, and wrong in a way that
/// only shows up under load:
///
/// ```swift
/// var packet = packetList.pointee.packet     // a COPY, on the stack
/// for _ in 0..<packetList.pointee.numPackets {
///     …
///     packet = MIDIPacketNext(&packet).pointee   // next address FROM THE STACK
/// }
/// ```
///
/// `MIDIPacketNext` computes the following packet's address by advancing past
/// the one it is given. Given a stack copy it advances past the STACK COPY, so
/// every packet after the first is read from whatever happens to sit above
/// that local variable. A single-packet list — which is what almost all MCU
/// traffic is — works perfectly, so the bug hides for weeks.
///
/// Measured live 2026-08-28: the running bridge daemon died with SIGBUS,
/// `EXC_BAD_ACCESS … Bad access in stack guard region`, inside this callback,
/// at the exact moment a project was closed and reopened — the one moment
/// Logic dumps its whole surface state and the list carries many packets. That
/// is `logic_reset_to`'s normal operation, so an eval harness resetting
/// between episodes would have killed the bridge every few episodes.
///
/// The fix is CoreMIDI's own iterator, which walks the list's REAL memory.
/// Extracted as a plain function so it can be unit-tested against a
/// hand-built multi-packet list, which is what the old loop never was.
public func midiPacketBytes(in packetList: UnsafePointer<MIDIPacketList>) -> [[UInt8]] {
    var collected: [[UInt8]] = []
    for packet in packetList.unsafeSequence() {
        // `data` is a fixed 256-byte tuple while `length` describes the real
        // packet, so a longer payload (a big SysEx) must be clamped rather
        // than read past the tuple. `prefix` clamps on its own; saying it here
        // makes the bound explicit instead of incidental.
        let length = min(Int(packet.pointee.length), MemoryLayout.size(ofValue: packet.pointee.data))
        guard length > 0 else { continue }
        let bytes = withUnsafeBytes(of: packet.pointee.data) { raw in
            Array(raw.prefix(length))
        }
        collected.append(bytes)
    }
    return collected
}
