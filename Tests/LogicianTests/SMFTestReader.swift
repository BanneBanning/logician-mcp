import Foundation

/// A minimal Standard MIDI File reader that exists ONLY for the tests.
///
/// It is deliberately not part of the shipped library: nothing in the server
/// reads MIDI files, and a reader that shared code with the writer would prove
/// nothing. This one is written from the SMF spec rather than from
/// `SMFWriter`, so a round trip through it is independent evidence that the
/// bytes say what the arrangement said.
///
/// Strict on purpose — every malformed length, stray running status or missing
/// end-of-track throws, because a lenient reader would forgive exactly the bugs
/// the round-trip tests are hunting for.
enum SMFTestReader {

    enum ReadError: Error, CustomStringConvertible {
        case truncated(String)
        case badChunk(expected: String, found: String)
        case badHeaderLength(Int)
        case smpteDivision(Int)
        case runningStatusWithoutStatus(offset: Int)
        case unknownStatus(UInt8, offset: Int)
        case trackLengthMismatch(declared: Int, consumed: Int)
        case missingEndOfTrack
        case unmatchedNoteOff(channel: Int, pitch: Int, tick: Int)
        case danglingNoteOn(channel: Int, pitch: Int, tick: Int)

        var description: String {
            switch self {
            case .truncated(let what): return "truncated while reading \(what)"
            case .badChunk(let expected, let found): return "expected chunk '\(expected)', found '\(found)'"
            case .badHeaderLength(let length): return "MThd length is \(length), must be 6"
            case .smpteDivision(let raw): return "SMPTE division 0x\(String(raw, radix: 16)) is not supported"
            case .runningStatusWithoutStatus(let offset): return "data byte with no running status at \(offset)"
            case .unknownStatus(let status, let offset): return "unknown status 0x\(String(status, radix: 16)) at \(offset)"
            case .trackLengthMismatch(let declared, let consumed):
                return "MTrk declared \(declared) bytes, parsing consumed \(consumed)"
            case .missingEndOfTrack: return "MTrk has no end-of-track meta"
            case .unmatchedNoteOff(let channel, let pitch, let tick):
                return "note-off with no note-on: channel \(channel) pitch \(pitch) at tick \(tick)"
            case .danglingNoteOn(let channel, let pitch, let tick):
                return "note-on never released: channel \(channel) pitch \(pitch) at tick \(tick)"
            }
        }
    }

    /// A parsed event at an ABSOLUTE tick. Note-ons and note-offs are paired
    /// into `.note`, which is what makes an event-for-event comparison with the
    /// writer's input possible.
    enum Event: Equatable {
        case note(tick: Int, endTick: Int, channel: Int, pitch: Int, velocity: Int, releaseVelocity: Int)
        case controlChange(tick: Int, channel: Int, controller: Int, value: Int)
        case pitchBend(tick: Int, channel: Int, value: Int)
        case programChange(tick: Int, channel: Int, program: Int)
        case tempo(tick: Int, microsecondsPerQuarter: Int)
        case timeSignature(tick: Int, numerator: Int, denominator: Int)
        case text(tick: Int, type: UInt8, text: String)

        var tick: Int {
            switch self {
            case .note(let tick, _, _, _, _, _), .controlChange(let tick, _, _, _),
                 .pitchBend(let tick, _, _), .programChange(let tick, _, _),
                 .tempo(let tick, _), .timeSignature(let tick, _, _), .text(let tick, _, _):
                return tick
            }
        }
    }

    struct Track: Equatable {
        /// The `FF 03` meta at tick 0, if there is one.
        var name: String?
        var events: [Event]
        /// The tick the end-of-track meta sits on.
        var endTick: Int
        /// How many status bytes the track spelled out, i.e. how many times
        /// running status did NOT apply. The compactness assertions read this.
        var statusBytes: Int

        var notes: [Event] { events.filter { if case .note = $0 { return true }; return false } }
    }

    struct File: Equatable {
        var format: Int
        /// The header's declared track count, which must equal `tracks.count`.
        var declaredTrackCount: Int
        var ticksPerQuarter: Int
        var tracks: [Track]
    }

    // MARK: Parsing

    static func read(_ data: Data) throws -> File {
        let bytes = [UInt8](data)
        var cursor = 0

        func take(_ count: Int, _ what: String) throws -> [UInt8] {
            guard cursor + count <= bytes.count else { throw ReadError.truncated(what) }
            defer { cursor += count }
            return Array(bytes[cursor..<(cursor + count)])
        }
        func beUInt32(_ raw: [UInt8]) -> Int {
            (Int(raw[0]) << 24) | (Int(raw[1]) << 16) | (Int(raw[2]) << 8) | Int(raw[3])
        }
        func beUInt16(_ raw: [UInt8]) -> Int { (Int(raw[0]) << 8) | Int(raw[1]) }

        let type = String(decoding: try take(4, "MThd type"), as: UTF8.self)
        guard type == "MThd" else { throw ReadError.badChunk(expected: "MThd", found: type) }
        let headerLength = beUInt32(try take(4, "MThd length"))
        guard headerLength == 6 else { throw ReadError.badHeaderLength(headerLength) }
        let format = beUInt16(try take(2, "format"))
        let declaredTrackCount = beUInt16(try take(2, "ntrks"))
        let division = beUInt16(try take(2, "division"))
        guard division & 0x8000 == 0 else { throw ReadError.smpteDivision(division) }

        var tracks: [Track] = []
        while cursor < bytes.count {
            let chunkType = String(decoding: try take(4, "chunk type"), as: UTF8.self)
            let length = beUInt32(try take(4, "chunk length"))
            let payload = try take(length, "chunk payload")
            guard chunkType == "MTrk" else { continue } // unknown chunks are skippable per spec
            tracks.append(try readTrack(payload))
        }
        return File(
            format: format, declaredTrackCount: declaredTrackCount,
            ticksPerQuarter: division, tracks: tracks
        )
    }

    private static func readTrack(_ payload: [UInt8]) throws -> Track {
        var cursor = 0
        var tick = 0
        var runningStatus: UInt8?
        var statusBytes = 0
        var events: [Event] = []
        var name: String?
        var endTick: Int?
        /// Sounding note-ons, oldest first per (channel, pitch), so a repeated
        /// pitch releases in the order it was struck.
        var sounding: [Int: [(tick: Int, velocity: Int)]] = [:]

        func byte(_ what: String) throws -> UInt8 {
            guard cursor < payload.count else { throw ReadError.truncated(what) }
            defer { cursor += 1 }
            return payload[cursor]
        }
        func vlq(_ what: String) throws -> Int {
            var value = 0
            for _ in 0..<4 {
                let next = try byte(what)
                value = (value << 7) | Int(next & 0x7F)
                if next & 0x80 == 0 { return value }
            }
            throw ReadError.truncated("\(what) (VLQ longer than 4 bytes)")
        }

        while cursor < payload.count, endTick == nil {
            tick += try vlq("delta time")
            let next = try byte("status")
            let status: UInt8
            if next & 0x80 != 0 {
                status = next
                if next < 0xF0 { runningStatus = next } else { runningStatus = nil }
                statusBytes += 1
            } else {
                guard let running = runningStatus else {
                    throw ReadError.runningStatusWithoutStatus(offset: cursor - 1)
                }
                status = running
                cursor -= 1 // the byte we peeked is the first data byte
            }

            switch status & 0xF0 {
            case 0x80, 0x90:
                let channel = Int(status & 0x0F) + 1
                let pitch = Int(try byte("pitch"))
                let velocity = Int(try byte("velocity"))
                let key = channel << 8 | pitch
                let isNoteOn = (status & 0xF0) == 0x90 && velocity > 0
                if isNoteOn {
                    sounding[key, default: []].append((tick, velocity))
                } else {
                    guard var pending = sounding[key], !pending.isEmpty else {
                        throw ReadError.unmatchedNoteOff(channel: channel, pitch: pitch, tick: tick)
                    }
                    let start = pending.removeFirst()
                    sounding[key] = pending
                    events.append(.note(
                        tick: start.tick, endTick: tick, channel: channel, pitch: pitch,
                        velocity: start.velocity,
                        releaseVelocity: (status & 0xF0) == 0x80 ? velocity : 0
                    ))
                }
            case 0xA0:
                _ = try byte("aftertouch pitch"); _ = try byte("aftertouch pressure")
            case 0xB0:
                events.append(.controlChange(
                    tick: tick, channel: Int(status & 0x0F) + 1,
                    controller: Int(try byte("controller")), value: Int(try byte("cc value"))
                ))
            case 0xC0:
                events.append(.programChange(
                    tick: tick, channel: Int(status & 0x0F) + 1,
                    program: Int(try byte("program"))
                ))
            case 0xD0:
                _ = try byte("channel pressure")
            case 0xE0:
                let low = Int(try byte("bend lsb"))
                let high = Int(try byte("bend msb"))
                events.append(.pitchBend(
                    tick: tick, channel: Int(status & 0x0F) + 1,
                    value: ((high << 7) | low) - 8192
                ))
            default:
                switch status {
                case 0xFF:
                    let metaType = try byte("meta type")
                    let length = try vlq("meta length")
                    var raw: [UInt8] = []
                    for _ in 0..<length { raw.append(try byte("meta payload")) }
                    switch metaType {
                    case 0x2F:
                        endTick = tick
                    case 0x51 where raw.count == 3:
                        events.append(.tempo(
                            tick: tick,
                            microsecondsPerQuarter: (Int(raw[0]) << 16) | (Int(raw[1]) << 8) | Int(raw[2])
                        ))
                    case 0x58 where raw.count == 4:
                        events.append(.timeSignature(
                            tick: tick, numerator: Int(raw[0]),
                            denominator: 1 << Int(raw[1])
                        ))
                    default:
                        let text = String(decoding: raw, as: UTF8.self)
                        if metaType == 0x03, tick == 0, name == nil { name = text }
                        events.append(.text(tick: tick, type: metaType, text: text))
                    }
                case 0xF0, 0xF7:
                    let length = try vlq("sysex length")
                    for _ in 0..<length { _ = try byte("sysex payload") }
                default:
                    throw ReadError.unknownStatus(status, offset: cursor - 1)
                }
            }
        }
        guard let endTick else { throw ReadError.missingEndOfTrack }
        guard cursor == payload.count else {
            throw ReadError.trackLengthMismatch(declared: payload.count, consumed: cursor)
        }
        for (key, pending) in sounding where !pending.isEmpty {
            throw ReadError.danglingNoteOn(
                channel: key >> 8, pitch: key & 0xFF, tick: pending[0].tick
            )
        }
        // Notes are appended when they END, so put the stream back in the order
        // the file spells it: by start tick, then by the order they were read.
        let indexed = events.enumerated().sorted {
            ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset)
        }
        return Track(
            name: name, events: indexed.map(\.element), endTick: endTick, statusBytes: statusBytes
        )
    }
}
