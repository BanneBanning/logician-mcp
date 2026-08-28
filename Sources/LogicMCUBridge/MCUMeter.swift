// The Mackie Control channel-meter grammar.
//
// Logic publishes a per-channel level to a control surface the same way it
// publishes fader positions and button LEDs: as MIDI, unprompted, describing
// its own state. The bridge received those bytes from the first day and threw
// them away — `case 0xD0` advanced the read index and kept nothing, and the
// neighbouring `case 0xA0` carried a comment calling itself "channel pressure
// pairs used for meters", which is doubly wrong (0xA0 is polyphonic
// aftertouch, and it is not what carries meters).
//
// WHAT THIS IS AND IS NOT. This is a STATE READ of a value Logic itself
// computed and chose to send — the same class of evidence as a fader echo or
// a mute LED. It is NOT audio analysis: nothing here measures a signal, and
// the number must never be reported as a loudness measurement. It is one of
// twelve segments on an imaginary LED ladder, with no documented dB mapping,
// and the server says exactly that wherever it surfaces the value.
//
// THE GRAMMAR (Mackie Control convention). Meters ride on channel pressure:
//
//     D0 <vv>        one status byte, ONE data byte
//     vv = (channel << 4) | code
//     channel: 0-7   the strip in the current BANK, not the project
//     code:
//       0x0 ... 0xC  the lit segment count, 0 = silence, 0xC = top segment
//       0xD          undefined in the published maps; ignored, level kept
//       0xE          SET the overload ("clip") indicator
//       0xF          CLEAR the overload indicator
//
// Two consequences the server has to carry:
//   * the channel is BANK-RELATIVE, exactly like the mute/solo/select LEDs,
//     so one reading only ever describes the eight strips currently banked;
//   * the value is a moving instantaneous level, so it is only meaningful
//     while the transport is rolling, and two strips read during a bank walk
//     were not read at the same moment.

import Foundation

public enum MCUMeter {
    /// Strips in one bank — meters are bank-relative.
    public static let channelCount = 8

    /// The highest ordinary segment. Levels are clamped into 0...topSegment.
    public static let topSegment = 0x0C

    /// What one meter data byte means.
    public enum Event: Equatable, Sendable {
        /// A new segment level for `channel`.
        case level(channel: Int, segment: Int)
        /// The overload indicator for `channel` was set or cleared.
        case overload(channel: Int, on: Bool)
        /// A code with no published meaning (0x0D). Kept as a case rather
        /// than silently dropped so the parser's behaviour is testable.
        case unknown(channel: Int, code: Int)
    }

    /// Decodes one channel-pressure data byte.
    ///
    /// Pure and total: every one of the 256 possible byte values maps to some
    /// event, because the alternative — a nil that callers forget to handle —
    /// is how a wrong meter silently becomes a wrong strip's meter.
    public static func decode(_ byte: UInt8) -> Event {
        let channel = Int(byte >> 4) & 0x07 // 8 strips; a 9th nibble wraps
        let code = Int(byte & 0x0F)
        switch code {
        case 0x0...topSegment:
            return .level(channel: channel, segment: code)
        case 0x0E:
            return .overload(channel: channel, on: true)
        case 0x0F:
            return .overload(channel: channel, on: false)
        default:
            return .unknown(channel: channel, code: code)
        }
    }

    /// Applies one event to a level/overload pair, in place.
    ///
    /// Split out from the parser so the state transition is unit-testable
    /// without CoreMIDI: the interesting rules are that an overload message
    /// does NOT disturb the level, and that an unknown code changes nothing.
    public static func apply(
        _ event: Event,
        levels: inout [Int],
        overloads: inout [Bool]
    ) {
        switch event {
        case .level(let channel, let segment):
            guard levels.indices.contains(channel) else { return }
            levels[channel] = segment
        case .overload(let channel, let on):
            guard overloads.indices.contains(channel) else { return }
            overloads[channel] = on
        case .unknown:
            return
        }
    }
}
