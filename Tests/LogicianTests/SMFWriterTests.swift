import XCTest
#if canImport(AudioToolbox)
import AudioToolbox
#endif
@testable import Logician

/// The Standard MIDI File writer, held to the standard the format deserves: a
/// file is either byte-exact or it is a file some importer will disagree with,
/// and there is no way to tell which from a passing "it didn't crash" test.
///
/// Three layers, deliberately:
///
/// 1. **Hand-computed byte fixtures.** Whole files spelled out in hex, computed
///    from the SMF spec by hand — VLQ boundaries, chunk lengths, running
///    status, note-off form, end-of-track, multi-track offsets.
/// 2. **Round trips through `SMFTestReader`**, a reader written from the spec
///    rather than from the writer, asserting event-for-event equality with the
///    arrangement that went in.
/// 3. **A system oracle**: CoreAudio's `MusicSequence` loads the bytes and is
///    asked how many notes it found. Nothing plays; this is a parser, not a
///    synth, so it runs headless.
final class SMFWriterTests: XCTestCase {

    // MARK: - Helpers

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func meter(_ events: [(Int, Int, Int)]) -> MeterMap {
        guard let map = MeterMap(
            events: events.map { MeterEvent(bar: $0.0, numerator: $0.1, denominator: $0.2) },
            source: .signatureList
        ) else { fatalError("test meter map is invalid") }
        return map
    }

    private func tempoMap(_ events: [(bar: Int, beat: Double, bpm: Double)]) -> TempoMap {
        guard let map = TempoMap(
            events: events.map { TempoEvent(bar: $0.bar, beatInBar: $0.beat, bpm: $0.bpm) },
            source: .tempoList
        ) else { fatalError("test tempo map is invalid") }
        return map
    }

    // MARK: - Variable-length quantities (the spec's own table)

    /// Every boundary the SMF spec tabulates, including the ones a naive
    /// implementation gets wrong: 0x7F/0x80 (one byte to two), 0x3FFF/0x4000
    /// (two to three), 0x1FFFFF/0x200000 (three to four), and the 0x0FFFFFFF
    /// ceiling.
    func testVariableLengthQuantityMatchesTheSpecTable() {
        let table: [(Int, [UInt8])] = [
            (0x0000_0000, [0x00]),
            (0x0000_0040, [0x40]),
            (0x0000_007F, [0x7F]),
            (0x0000_0080, [0x81, 0x00]),
            (0x0000_2000, [0xC0, 0x00]),
            (0x0000_3FFF, [0xFF, 0x7F]),
            (0x0000_4000, [0x81, 0x80, 0x00]),
            (0x0010_0000, [0xC0, 0x80, 0x00]),
            (0x001F_FFFF, [0xFF, 0xFF, 0x7F]),
            (0x0020_0000, [0x81, 0x80, 0x80, 0x00]),
            (0x0800_0000, [0xC0, 0x80, 0x80, 0x00]),
            (0x0FFF_FFFF, [0xFF, 0xFF, 0xFF, 0x7F])
        ]
        for (value, expected) in table {
            XCTAssertEqual(
                SMFWriter.variableLengthQuantity(value), expected,
                "VLQ of \(value): got \(hex(SMFWriter.variableLengthQuantity(value)))"
            )
        }
    }

    /// A VLQ must round-trip through the test reader's own decoder for every
    /// boundary too — the encoder and the independent decoder agreeing is what
    /// makes the round-trip tests below meaningful.
    func testVariableLengthQuantityRoundTripsThroughTheReader() throws {
        // The reader has no public VLQ entry point, so the check goes through a
        // real file: one CC per boundary delta, read back at the right ticks.
        var ticks = [0]
        for delta in [0x7F, 0x80, 0x3FFF, 0x4000, 0x1F_FFFF, 0x20_0000] {
            ticks.append(ticks.last! + delta)
        }
        var timing = SMFTiming()
        timing.ticksPerQuarter = 1
        timing.beatsPerBar = 1
        let track = SMFTrack(
            channel: 1,
            controlChanges: ticks.map { SMFControlChange(controller: 7, value: 64, bar: $0 + 1) }
        )
        let file = try SMFTestReader.read(
            SMFWriter(format: .singleTrack, tracks: [track], timing: timing).encode()
        )
        XCTAssertEqual(file.tracks[0].events.map(\.tick), ticks)
    }

    // MARK: - Whole-file byte fixtures

    /// The smallest useful format-1 file, spelled out byte by byte.
    ///
    /// `MThd` 6 bytes: format 1, two chunks, division 960 (`03 C0`). An EMPTY
    /// conductor track — four bytes, delta 0 plus `FF 2F 00` — because the
    /// default writes no tempo and no signature. Then the named track: track
    /// name meta, note-on, note-off 960 ticks later riding running status, end
    /// of track.
    func testOneNoteFormatOneFileIsByteExact() throws {
        let track = SMFTrack(
            name: "Bass", channel: 1,
            notes: [SMFNote(pitch: 60, bar: 1, beat: 1, durationBeats: 1, velocity: 100)]
        )
        let data = try SMFWriter(tracks: [track]).encode()
        let expected: [UInt8] = [
            // MThd, length 6, format 1, 2 tracks, 960 ppq
            0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
            0x00, 0x01, 0x00, 0x02, 0x03, 0xC0,
            // conductor MTrk, length 4: delta 0, end of track
            0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x04,
            0x00, 0xFF, 0x2F, 0x00,
            // "Bass" MTrk, length 20
            0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x14,
            0x00, 0xFF, 0x03, 0x04, 0x42, 0x61, 0x73, 0x73, // delta 0, track name "Bass"
            0x00, 0x90, 0x3C, 0x64,                         // delta 0, note on C3 vel 100
            0x87, 0x40, 0x3C, 0x00,                         // delta 960, running status, vel 0
            0x00, 0xFF, 0x2F, 0x00                          // delta 0, end of track
        ]
        XCTAssertEqual([UInt8](data), expected, "got \(hex(data))")
        XCTAssertEqual(data.count, 54)
    }

    /// Three consecutive notes on one channel must spell the `0x90` status byte
    /// EXACTLY ONCE. This is the whole point of encoding the release as a
    /// note-on with velocity 0: every note-off then chains off the same status.
    func testRunningStatusSpellsOneStatusByteForAMonophonicLine() throws {
        let notes = [60, 62, 64].enumerated().map {
            SMFNote(pitch: $0.element, bar: 1, beat: Double($0.offset) + 1, durationBeats: 1, velocity: 100)
        }
        let data = try SMFWriter(
            format: .singleTrack, tracks: [SMFTrack(channel: 1, notes: notes)]
        ).encode()
        let expected: [UInt8] = [
            0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
            0x00, 0x00, 0x00, 0x01, 0x03, 0xC0,     // format 0, one track
            0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x1A,
            0x00, 0x90, 0x3C, 0x64,                 // t0    note on 60
            0x87, 0x40, 0x3C, 0x00,                 // t960  release 60 (running status)
            0x00, 0x3E, 0x64,                       // t960  note on 62 (running status)
            0x87, 0x40, 0x3E, 0x00,                 // t1920 release 62
            0x00, 0x40, 0x64,                       // t1920 note on 64
            0x87, 0x40, 0x40, 0x00,                 // t2880 release 64
            0x00, 0xFF, 0x2F, 0x00
        ]
        XCTAssertEqual([UInt8](data), expected, "got \(hex(data))")
        XCTAssertEqual([UInt8](data).filter { $0 == 0x90 }.count, 1, "status byte repeated")
        XCTAssertEqual(try SMFTestReader.read(data).tracks[0].statusBytes, 2, "status + end-of-track")
    }

    /// With running status turned off the same line must be self-describing:
    /// every event carries its status, and every release is a real `0x8n`
    /// note-off rather than a velocity-0 note-on.
    func testRunningStatusOffEmitsRealNoteOffsAndEveryStatusByte() throws {
        let notes = [60, 62].enumerated().map {
            SMFNote(pitch: $0.element, bar: 1, beat: Double($0.offset) + 1, durationBeats: 1, velocity: 100)
        }
        let data = try SMFWriter(
            format: .singleTrack, tracks: [SMFTrack(channel: 1, notes: notes)],
            usesRunningStatus: false
        ).encode()
        let payload: [UInt8] = [
            0x00, 0x90, 0x3C, 0x64,
            0x87, 0x40, 0x80, 0x3C, 0x00,
            0x00, 0x90, 0x3E, 0x64,
            0x87, 0x40, 0x80, 0x3E, 0x00,
            0x00, 0xFF, 0x2F, 0x00
        ]
        XCTAssertEqual([UInt8](data).suffix(payload.count), payload[...], "got \(hex(data))")
        // Every channel event spelled its status; nothing chained.
        XCTAssertEqual(try SMFTestReader.read(data).tracks[0].statusBytes, 5)
    }

    /// A non-zero release velocity forces the real note-off even with running
    /// status on — the release velocity has nowhere to live in the velocity-0
    /// form, and losing it silently would be the wrong trade.
    func testReleaseVelocityForcesARealNoteOff() throws {
        let note = SMFNote(pitch: 60, bar: 1, durationBeats: 1, velocity: 100, releaseVelocity: 64)
        let data = try SMFWriter(
            format: .singleTrack, tracks: [SMFTrack(channel: 1, notes: [note])]
        ).encode()
        XCTAssertEqual([UInt8](data).suffix(13), [
            0x00, 0x90, 0x3C, 0x64,
            0x87, 0x40, 0x80, 0x3C, 0x40,
            0x00, 0xFF, 0x2F, 0x00
        ][...], "got \(hex(data))")
        guard case .note(_, _, _, _, _, let release) = try SMFTestReader.read(data).tracks[0].events[0] else {
            return XCTFail("expected a note")
        }
        XCTAssertEqual(release, 64)
    }

    /// The chunk lengths and the offsets they imply, on a file with three named
    /// tracks. A length that is off by one is a file every importer rejects, and
    /// nothing else in the bytes reveals it.
    func testMultiTrackChunkLengthsAndOffsets() throws {
        let tracks = ["Drums", "Bass", "Keys"].enumerated().map { index, name in
            SMFTrack(
                name: name, channel: index + 1,
                notes: [SMFNote(pitch: 36 + index, bar: 1, durationBeats: 1, velocity: 100)]
            )
        }
        let data = try SMFWriter(tracks: tracks).encode()
        let bytes = [UInt8](data)
        // Header says four chunks: the conductor plus three tracks.
        XCTAssertEqual(Array(bytes[10..<12]), [0x00, 0x04])
        // Walk the chunks by their declared lengths alone: every hop must land
        // on an "MTrk", and the last must land exactly on the end of the file.
        var offset = 14
        var lengths: [Int] = []
        while offset < bytes.count {
            XCTAssertEqual(
                String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self), "MTrk",
                "the hop to offset \(offset) missed a chunk header — a previous length is wrong"
            )
            let length = (Int(bytes[offset + 4]) << 24) | (Int(bytes[offset + 5]) << 16)
                | (Int(bytes[offset + 6]) << 8) | Int(bytes[offset + 7])
            lengths.append(length)
            offset += 8 + length
        }
        XCTAssertEqual(offset, bytes.count, "the last chunk's length overruns or underruns the file")
        // Conductor: end-of-track only. Each named track: name meta, note-on,
        // note-off, end of track.
        XCTAssertEqual(lengths, [
            4,
            9 + 4 + 4 + 4,  // "Drums" is five characters
            8 + 4 + 4 + 4,  // "Bass" four
            8 + 4 + 4 + 4   // "Keys" four
        ])
        let file = try SMFTestReader.read(data)
        XCTAssertEqual(file.declaredTrackCount, file.tracks.count)
        XCTAssertEqual(file.tracks.dropFirst().map(\.name), ["Drums", "Bass", "Keys"])
    }

    /// Every track ends with `00 FF 2F 00`, including an empty one, and the
    /// end-of-track delta is measured from the last event rather than reset.
    func testEndOfTrackIsPresentAndDeltaIsZero() throws {
        let data = try SMFWriter(tracks: [
            SMFTrack(name: "Empty", channel: 1),
            SMFTrack(name: "One", channel: 2, notes: [SMFNote(pitch: 60, bar: 3, durationBeats: 2)])
        ]).encode()
        XCTAssertEqual([UInt8](data).suffix(4), [0x00, 0xFF, 0x2F, 0x00][...])
        let file = try SMFTestReader.read(data)
        XCTAssertEqual(file.tracks[0].endTick, 0, "the conductor ends where it starts")
        XCTAssertEqual(file.tracks[1].endTick, 0, "an event-free track ends at its name meta")
        // Bar 3 beat 1 is 2 bars x 4 beats x 960; the note is 2 beats long.
        XCTAssertEqual(file.tracks[2].endTick, 2 * 4 * 960 + 2 * 960)
    }

    // MARK: - Conductor track: tempo and meter, only when asked

    /// The default writes NO tempo and NO time signature. This is the safety
    /// property the whole conductor design turns on: importing this file cannot
    /// move the project's tempo map or its signature track, because there is
    /// nothing in it that says anything about either.
    func testConductorIsEmptyByDefault() throws {
        let data = try SMFWriter(tracks: [
            SMFTrack(name: "Keys", channel: 1, notes: [SMFNote(pitch: 60, bar: 1)])
        ]).encode()
        let conductor = try SMFTestReader.read(data).tracks[0]
        XCTAssertEqual(conductor.events, [], "the conductor track carried something")
        XCTAssertFalse(
            [UInt8](data).contains(0x51) && [UInt8](data).contains(0x58),
            "no tempo or signature meta may appear anywhere"
        )
    }

    /// 120 BPM is 500000 microseconds per quarter — `FF 51 03 07 A1 20`, the
    /// one tempo fixture worth memorising.
    func testTempoMetaBytes() {
        XCTAssertEqual(SMFWriter.tempoMeta(120), [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20])
        XCTAssertEqual(SMFWriter.microsecondsPerQuarter(120), 500_000)
        XCTAssertEqual(SMFWriter.microsecondsPerQuarter(60), 1_000_000)
        XCTAssertEqual(SMFWriter.microsecondsPerQuarter(174), 344_828) // rounded, not truncated
    }

    /// `FF 58 04 nn dd 18 08`, with the denominator as a power of two.
    func testTimeSignatureMetaBytes() {
        XCTAssertEqual(SMFWriter.timeSignatureMeta(numerator: 4, denominator: 4),
                       [0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08])
        XCTAssertEqual(SMFWriter.timeSignatureMeta(numerator: 6, denominator: 8),
                       [0xFF, 0x58, 0x04, 0x06, 0x03, 0x18, 0x08])
        XCTAssertEqual(SMFWriter.timeSignatureMeta(numerator: 7, denominator: 16),
                       [0xFF, 0x58, 0x04, 0x07, 0x04, 0x18, 0x08])
    }

    /// A constant tempo asked for explicitly lands at tick 0 of the conductor.
    func testConstantTempoIsWrittenAtTickZero() throws {
        var timing = SMFTiming()
        timing.tempo = .constant(90)
        timing.timeSignature = .fromMeter
        let data = try SMFWriter(
            tracks: [SMFTrack(name: "Keys", channel: 1, notes: [SMFNote(pitch: 60, bar: 1)])],
            timing: timing, sequenceName: "Sketch"
        ).encode()
        let conductor = try SMFTestReader.read(data).tracks[0]
        XCTAssertEqual(conductor.events, [
            .text(tick: 0, type: 0x03, text: "Sketch"),
            .tempo(tick: 0, microsecondsPerQuarter: 666_667),
            .timeSignature(tick: 0, numerator: 4, denominator: 4)
        ])
    }

    /// A tempo MAP becomes one meta per event, at the event's tick, integrated
    /// over the same bar math the notes use.
    func testTempoMapBecomesOneMetaPerEvent() throws {
        var timing = SMFTiming()
        timing.tempo = .map(tempoMap([(1, 1, 120), (5, 1, 140), (9, 3, 100)]))
        let data = try SMFWriter(
            tracks: [SMFTrack(name: "Keys", channel: 1, notes: [SMFNote(pitch: 60, bar: 1)])],
            timing: timing
        ).encode()
        XCTAssertEqual(try SMFTestReader.read(data).tracks[0].events, [
            .tempo(tick: 0, microsecondsPerQuarter: 500_000),
            .tempo(tick: 4 * 4 * 960, microsecondsPerQuarter: 428_571),
            .tempo(tick: 8 * 4 * 960 + 2 * 960, microsecondsPerQuarter: 600_000)
        ])
    }

    /// A tempo map whose first event is later than the origin carries that
    /// tempo backwards to tick 0 — the same rule `TempoMap`'s integration uses,
    /// so the file and the server's own bar math cannot disagree.
    func testTempoBeforeTheOriginCollapsesToTickZero() throws {
        var timing = SMFTiming()
        timing.originBar = 5
        timing.tempo = .map(tempoMap([(1, 1, 120), (3, 1, 90), (9, 1, 140)]))
        let data = try SMFWriter(
            tracks: [SMFTrack(name: "Keys", channel: 1, notes: [SMFNote(pitch: 60, bar: 5)])],
            timing: timing
        ).encode()
        XCTAssertEqual(try SMFTestReader.read(data).tracks[0].events, [
            .tempo(tick: 0, microsecondsPerQuarter: 666_667),          // the 90 in force at bar 5
            .tempo(tick: 4 * 4 * 960, microsecondsPerQuarter: 428_571) // bar 9, four bars later
        ])
    }

    /// A variable meter map writes one signature per change AND drives the
    /// bar→tick math: a note in bar 3 of a 3/4-then-7/8 project lands where the
    /// signature track puts it, not where four-beat bars would.
    func testVariableMeterDrivesBothTheSignaturesAndThePositions() throws {
        var timing = SMFTiming()
        timing.beatsPerBar = 3          // 3/4 until bar 3
        timing.meterMap = meter([(1, 3, 4), (3, 7, 8)])
        timing.timeSignature = .fromMeter
        let data = try SMFWriter(
            tracks: [SMFTrack(name: "Odd", channel: 1, notes: [
                SMFNote(pitch: 60, bar: 3, beat: 1, durationBeats: 0.5),
                SMFNote(pitch: 62, bar: 4, beat: 1, durationBeats: 0.5)
            ])],
            timing: timing
        ).encode()
        let file = try SMFTestReader.read(data)
        XCTAssertEqual(file.tracks[0].events, [
            .timeSignature(tick: 0, numerator: 3, denominator: 4),
            .timeSignature(tick: 2 * 3 * 960, numerator: 7, denominator: 8)
        ])
        // Bar 3 = two 3/4 bars in = 6 beats; bar 4 = one 7/8 bar later = 9.5.
        XCTAssertEqual(file.tracks[1].notes.map(\.tick), [6 * 960, Int(9.5 * 960)])
    }

    /// `beats_per_bar` alone still yields a signature when one is asked for,
    /// and a fractional bar length refuses rather than inventing 3.5/4.
    func testSignatureDerivedFromBeatsPerBar() throws {
        var timing = SMFTiming()
        timing.beatsPerBar = 5
        timing.timeSignature = .fromMeter
        let data = try SMFWriter(tracks: [SMFTrack(name: "Five", notes: [SMFNote(pitch: 60, bar: 1)])],
                                 timing: timing).encode()
        XCTAssertEqual(try SMFTestReader.read(data).tracks[0].events,
                       [.timeSignature(tick: 0, numerator: 5, denominator: 4)])

        var fractional = SMFTiming()
        fractional.beatsPerBar = 3.5
        fractional.timeSignature = .fromMeter
        XCTAssertThrowsError(try SMFWriter(
            tracks: [SMFTrack(name: "Seven Eight", notes: [SMFNote(pitch: 60, bar: 1)])],
            timing: fractional
        )) { XCTAssertTrue("\($0)".contains("time signature"), "\($0)") }
    }

    // MARK: - Positions

    /// The bar→tick table at PPQ 960, in 4/4: the arithmetic every note's
    /// placement rests on.
    func testBarAndBeatToTicks() {
        let timing = SMFTiming()
        XCTAssertEqual(timing.tick(bar: 1, beat: 1), 0)
        XCTAssertEqual(timing.tick(bar: 1, beat: 1.5), 480)
        XCTAssertEqual(timing.tick(bar: 1, beat: 2), 960)
        XCTAssertEqual(timing.tick(bar: 2, beat: 1), 3840)
        XCTAssertEqual(timing.tick(bar: 9, beat: 4.75), 8 * 3840 + 3 * 960 + 720)
        // A 1/16 division is 240 ticks — Logic's own grid, exactly.
        XCTAssertEqual(timing.tick(bar: 1, beat: 1.25), 240)
    }

    /// `originBar` shifts the anchor without changing anything else.
    func testOriginBarShiftsTheAnchor() throws {
        var timing = SMFTiming()
        timing.originBar = 17
        XCTAssertEqual(timing.tick(bar: 17, beat: 1), 0)
        XCTAssertEqual(timing.tick(bar: 18, beat: 3), 3840 + 2 * 960)
        let data = try SMFWriter(
            tracks: [SMFTrack(name: "Late", notes: [SMFNote(pitch: 60, bar: 17, durationBeats: 4)])],
            timing: timing
        ).encode()
        guard case .note(let tick, let endTick, _, _, _, _) =
                try SMFTestReader.read(data).tracks[1].notes[0] else {
            return XCTFail("expected a note")
        }
        XCTAssertEqual([tick, endTick], [0, 3840])
    }

    /// A duration that rounds to nothing is lengthened to a single tick: a
    /// zero-length note is one that never sounds, and dropping it silently
    /// would be worse than a tick of drift.
    func testAVanishinglyShortNoteStillSounds() throws {
        var timing = SMFTiming()
        timing.ticksPerQuarter = 96
        let data = try SMFWriter(
            format: .singleTrack,
            tracks: [SMFTrack(notes: [SMFNote(pitch: 60, bar: 1, durationBeats: 0.0001)])],
            timing: timing
        ).encode()
        guard case .note(let tick, let endTick, _, _, _, _) =
                try SMFTestReader.read(data).tracks[0].events[0] else {
            return XCTFail("expected a note")
        }
        XCTAssertEqual([tick, endTick], [0, 1])
    }

    /// Back-to-back notes on the same pitch: the release must be spelled BEFORE
    /// the next attack at the shared tick, or an importer hears one note and
    /// then silence.
    func testNoteOffPrecedesNoteOnAtTheSameTick() throws {
        let data = try SMFWriter(
            format: .singleTrack,
            tracks: [SMFTrack(notes: [
                SMFNote(pitch: 60, bar: 1, beat: 1, durationBeats: 1, velocity: 80),
                SMFNote(pitch: 60, bar: 1, beat: 2, durationBeats: 1, velocity: 90)
            ])]
        ).encode()
        // 90 3C 50 | (960) 3C 00 | (0) 3C 5A | (960) 3C 00
        XCTAssertEqual([UInt8](data).suffix(19), [
            0x00, 0x90, 0x3C, 0x50,
            0x87, 0x40, 0x3C, 0x00,
            0x00, 0x3C, 0x5A,
            0x87, 0x40, 0x3C, 0x00,
            0x00, 0xFF, 0x2F, 0x00
        ][...], "got \(hex(data))")
        // The reader pairs them without complaint, which it cannot do if the
        // order is wrong.
        XCTAssertEqual(try SMFTestReader.read(data).tracks[0].events, [
            .note(tick: 0, endTick: 960, channel: 1, pitch: 60, velocity: 80, releaseVelocity: 0),
            .note(tick: 960, endTick: 1920, channel: 1, pitch: 60, velocity: 90, releaseVelocity: 0)
        ])
    }

    /// Events sharing a tick come out in a fixed order — program, CC, bend,
    /// note-off, note-on — and two encodes of the same arrangement are the same
    /// bytes.
    func testEncodingIsDeterministic() throws {
        let track = SMFTrack(
            name: "All", channel: 3,
            notes: (0..<12).map { SMFNote(pitch: 48 + $0, bar: 1 + $0 / 4, beat: Double($0 % 4) + 1) },
            controlChanges: (0..<8).map { SMFControlChange(controller: 1, value: $0 * 16, bar: 1, beat: 1) },
            pitchBends: [SMFPitchBend(value: 0, bar: 1), SMFPitchBend(value: 8191, bar: 1)],
            programChanges: [SMFProgramChange(program: 33, bar: 1)]
        )
        let first = try SMFWriter(tracks: [track]).encode()
        let second = try SMFWriter(tracks: [track]).encode()
        XCTAssertEqual(first, second)
        // Thirteen events share tick 0: the track-name meta, one program
        // change, eight CCs, two bends and the first note — in that order.
        let events = Array(try SMFTestReader.read(first).tracks[1].events.prefix(13))
        XCTAssertEqual(events.map(\.tick), Array(repeating: 0, count: 13))
        guard case .text = events[0] else { return XCTFail("the name meta comes first") }
        guard case .programChange = events[1] else { return XCTFail("program change before the rest") }
        guard case .controlChange = events[2] else { return XCTFail("CC after the program change") }
        guard case .controlChange = events[9] else { return XCTFail("eight CCs") }
        guard case .pitchBend = events[10] else { return XCTFail("bends after the CCs") }
        guard case .pitchBend = events[11] else { return XCTFail("two bends") }
        guard case .note = events[12] else { return XCTFail("notes last") }
    }

    // MARK: - Channel messages

    /// CC, pitch bend and program change on the wire, including the bend's
    /// 14-bit split (0 = centre = `00 40`).
    func testControlBendAndProgramBytes() throws {
        let data = try SMFWriter(
            format: .singleTrack,
            tracks: [SMFTrack(channel: 10, controlChanges: [
                SMFControlChange(controller: 1, value: 127, bar: 1)
            ], pitchBends: [
                SMFPitchBend(value: 0, bar: 1, beat: 2),
                SMFPitchBend(value: -8192, bar: 1, beat: 3),
                SMFPitchBend(value: 8191, bar: 1, beat: 4)
            ], programChanges: [
                SMFProgramChange(program: 0, bar: 1), SMFProgramChange(program: 127, bar: 2)
            ])]
        ).encode()
        // Channel 10 is status nibble 9. The bend's 14 bits are LSB then MSB,
        // biased by 8192: centre is 00 40, the bottom 00 00, the top 7F 7F.
        // The three bends chain on one E9, and the program change at bar 2
        // breaks the chain.
        XCTAssertEqual([UInt8](data).suffix(28), [
            0x00, 0xC9, 0x00,             // t0    program 0
            0x00, 0xB9, 0x01, 0x7F,       // t0    CC 1 = 127
            0x87, 0x40, 0xE9, 0x00, 0x40, // t960  bend centre
            0x87, 0x40, 0x00, 0x00,       // t1920 bend -8192 (running status)
            0x87, 0x40, 0x7F, 0x7F,       // t2880 bend +8191 (running status)
            0x87, 0x40, 0xC9, 0x7F,       // t3840 program 127
            0x00, 0xFF, 0x2F, 0x00
        ][...], "got \(hex(data))")
        XCTAssertEqual(try SMFTestReader.read(data).tracks[0].events, [
            .programChange(tick: 0, channel: 10, program: 0),
            .controlChange(tick: 0, channel: 10, controller: 1, value: 127),
            .pitchBend(tick: 960, channel: 10, value: 0),
            .pitchBend(tick: 1920, channel: 10, value: -8192),
            .pitchBend(tick: 2880, channel: 10, value: 8191),
            .programChange(tick: 3840, channel: 10, program: 127)
        ])
    }

    private func bytesContain(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }

    /// A per-event channel override beats the track's default, which is what a
    /// multi-timbral part needs.
    func testPerEventChannelOverride() throws {
        let data = try SMFWriter(format: .singleTrack, tracks: [SMFTrack(
            channel: 1,
            notes: [
                SMFNote(pitch: 60, bar: 1),
                SMFNote(pitch: 62, bar: 2, channel: 16)
            ]
        )]).encode()
        XCTAssertEqual(try SMFTestReader.read(data).tracks[0].events.map {
            if case .note(_, _, let channel, _, _, _) = $0 { return channel }
            return -1
        }, [1, 16])
    }

    // MARK: - Round trips

    /// A whole arrangement — four named tracks, four channels, notes with
    /// fractional beats and overlapping durations, CC curves, a bend, program
    /// changes — encoded and re-read by a reader written from the spec, then
    /// compared EVENT FOR EVENT with what went in.
    func testFullArrangementRoundTripsEventForEvent() throws {
        let names = ["Drums", "Bass", "Keys", "Lead"]
        var tracks: [SMFTrack] = []
        for (index, name) in names.enumerated() {
            var track = SMFTrack(name: name, channel: index + 1)
            track.programChanges = [SMFProgramChange(program: index * 8, bar: 1)]
            for bar in 1...8 {
                for step in 0..<4 {
                    track.notes.append(SMFNote(
                        pitch: 36 + index * 12 + step,
                        bar: bar, beat: Double(step) + 1 + (step == 2 ? 0.5 : 0),
                        durationBeats: step == 3 ? 2 : 0.75,
                        velocity: 40 + step * 20 + index
                    ))
                }
                track.controlChanges.append(SMFControlChange(
                    controller: 11, value: min(127, bar * 15), bar: bar, beat: 1
                ))
            }
            track.pitchBends = [
                SMFPitchBend(value: -4096, bar: 4, beat: 1),
                SMFPitchBend(value: 0, bar: 4, beat: 2)
            ]
            tracks.append(track)
        }
        var timing = SMFTiming()
        timing.tempo = .constant(128)
        let data = try SMFWriter(tracks: tracks, timing: timing, sequenceName: "Round trip").encode()
        let file = try SMFTestReader.read(data)

        XCTAssertEqual(file.format, 1)
        XCTAssertEqual(file.ticksPerQuarter, 960)
        XCTAssertEqual(file.declaredTrackCount, 5)
        XCTAssertEqual(file.tracks.count, 5)
        XCTAssertEqual(file.tracks[0].events, [
            .text(tick: 0, type: 0x03, text: "Round trip"),
            .tempo(tick: 0, microsecondsPerQuarter: 468_750)
        ])

        for (index, track) in tracks.enumerated() {
            let parsed = file.tracks[index + 1]
            XCTAssertEqual(parsed.name, track.name)
            var expected: [SMFTestReader.Event] = [
                .text(tick: 0, type: 0x03, text: track.name!),
                .programChange(tick: 0, channel: index + 1, program: index * 8)
            ]
            expected += track.controlChanges.map {
                .controlChange(
                    tick: timing.tick(bar: $0.bar, beat: $0.beat), channel: index + 1,
                    controller: $0.controller, value: $0.value
                )
            }
            expected += track.pitchBends.map {
                .pitchBend(
                    tick: timing.tick(bar: $0.bar, beat: $0.beat), channel: index + 1, value: $0.value
                )
            }
            expected += track.notes.map { note in
                let ticks = timing.noteTicks(note)
                return .note(
                    tick: ticks.on, endTick: ticks.off, channel: index + 1,
                    pitch: note.pitch, velocity: note.velocity, releaseVelocity: 0
                )
            }
            XCTAssertEqual(
                Set(parsed.events.map(\.tick)), Set(expected.map(\.tick)),
                "\(track.name!): tick set differs"
            )
            XCTAssertEqual(
                parsed.events.sorted(by: eventOrder), expected.sorted(by: eventOrder),
                "\(track.name!): events differ"
            )
        }
    }

    /// A stable total order for comparing two event lists whose within-tick
    /// order is an implementation detail of the writer.
    private func eventOrder(_ lhs: SMFTestReader.Event, _ rhs: SMFTestReader.Event) -> Bool {
        (lhs.tick, "\(lhs)") < (rhs.tick, "\(rhs)")
    }

    /// The same arrangement over a variable meter and a tempo map, round-tripped
    /// — the case where every position is a walk rather than a multiplication.
    func testRoundTripUnderAVariableMeterAndTempoMap() throws {
        var timing = SMFTiming()
        timing.beatsPerBar = 4
        timing.meterMap = meter([(1, 4, 4), (5, 7, 8), (9, 3, 4)])
        timing.tempo = .map(tempoMap([(1, 1, 100), (5, 1, 133.5)]))
        timing.timeSignature = .fromMeter
        let notes = (1...12).map {
            SMFNote(pitch: 60 + $0, bar: $0, beat: 1.5, durationBeats: 0.5, velocity: 64)
        }
        let data = try SMFWriter(
            tracks: [SMFTrack(name: "Odd", channel: 4, notes: notes)], timing: timing
        ).encode()
        let file = try SMFTestReader.read(data)
        XCTAssertEqual(file.tracks[0].events.sorted(by: eventOrder), [
            .tempo(tick: 0, microsecondsPerQuarter: 600_000),
            .tempo(tick: 4 * 4 * 960, microsecondsPerQuarter: 449_438),
            .timeSignature(tick: 0, numerator: 4, denominator: 4),
            .timeSignature(tick: 4 * 4 * 960, numerator: 7, denominator: 8),
            .timeSignature(tick: 4 * 4 * 960 + 4 * Int(3.5 * 960), numerator: 3, denominator: 4)
        ].sorted(by: eventOrder))
        XCTAssertEqual(file.tracks[1].events.compactMap {
            if case .note(let tick, _, _, _, _, _) = $0 { return tick }
            return nil
        }, notes.map { timing.tick(bar: $0.bar, beat: $0.beat) })
    }

    /// Format 0 is the degenerate case and must still be a legal file: one
    /// chunk, everything merged, channels doing the separating.
    func testFormatZeroRoundTrip() throws {
        var timing = SMFTiming()
        timing.tempo = .constant(96)
        let track = SMFTrack(name: "Everything", channel: 2, notes: [
            SMFNote(pitch: 60, bar: 1), SMFNote(pitch: 64, bar: 1, channel: 5)
        ])
        let data = try SMFWriter(
            format: .singleTrack, tracks: [track], timing: timing
        ).encode()
        let file = try SMFTestReader.read(data)
        XCTAssertEqual(file.format, 0)
        XCTAssertEqual(file.declaredTrackCount, 1)
        XCTAssertEqual(file.tracks.count, 1)
        XCTAssertEqual(file.tracks[0].name, "Everything")
        XCTAssertEqual(file.tracks[0].events.filter {
            if case .tempo = $0 { return true }
            return false
        }.count, 1)
    }

    /// Writing to disk produces the same bytes `encode()` returns.
    func testWriteToDiskMatchesEncode() throws {
        let writer = try SMFWriter(tracks: [
            SMFTrack(name: "Disk", notes: [SMFNote(pitch: 60, bar: 1)])
        ])
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("logician-smf-\(UUID().uuidString).mid")
        defer { try? FileManager.default.removeItem(at: url) }
        let count = try writer.write(to: url)
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk, writer.encode())
        XCTAssertEqual(count, onDisk.count)
    }

    // MARK: - Refusals

    func testRefusesAnEmptyArrangement() {
        XCTAssertThrowsError(try SMFWriter(tracks: []))
    }

    /// Format 0 with several tracks would silently lose every name but one.
    func testRefusesFormatZeroWithSeveralTracks() {
        XCTAssertThrowsError(try SMFWriter(format: .singleTrack, tracks: [
            SMFTrack(name: "A", notes: [SMFNote(pitch: 60, bar: 1)]),
            SMFTrack(name: "B", notes: [SMFNote(pitch: 62, bar: 1)])
        ])) { XCTAssertTrue("\($0)".contains("format 0"), "\($0)") }
    }

    /// Every out-of-range value is refused, and the message names the track and
    /// the event so a hundred-note arrangement can be corrected.
    func testRefusesOutOfRangeEvents() {
        func refuses(_ track: SMFTrack, containing fragment: String, _ line: UInt = #line) {
            XCTAssertThrowsError(try SMFWriter(tracks: [track]), line: line) {
                XCTAssertTrue("\($0)".contains(fragment), "\($0)", line: line)
            }
        }
        refuses(SMFTrack(name: "T", notes: [SMFNote(pitch: 128, bar: 1)]), containing: "pitch 128")
        refuses(SMFTrack(name: "T", notes: [SMFNote(pitch: 60, bar: 0)]), containing: "bar must be 1")
        refuses(SMFTrack(name: "T", notes: [SMFNote(pitch: 60, bar: 1, beat: 0)]), containing: "1-based")
        refuses(SMFTrack(name: "T", notes: [SMFNote(pitch: 60, bar: 1, durationBeats: 0)]),
                containing: "duration_beats")
        refuses(SMFTrack(name: "T", notes: [SMFNote(pitch: 60, bar: 1, velocity: 0)]),
                containing: "0 is a note-off")
        refuses(SMFTrack(name: "T", notes: [SMFNote(pitch: 60, bar: 1, channel: 17)]),
                containing: "must be 1-16")
        refuses(SMFTrack(name: "T", channel: 0, notes: [SMFNote(pitch: 60, bar: 1)]),
                containing: "track channel")
        refuses(SMFTrack(name: "T", controlChanges: [SMFControlChange(controller: 128, value: 0, bar: 1)]),
                containing: "controller must be 0-127")
        refuses(SMFTrack(name: "T", pitchBends: [SMFPitchBend(value: 8192, bar: 1)]),
                containing: "-8192..8191")
        refuses(SMFTrack(name: "T", programChanges: [SMFProgramChange(program: 128, bar: 1)]),
                containing: "program must be 0-127")
        refuses(SMFTrack(name: "  ", notes: [SMFNote(pitch: 60, bar: 1)]),
                containing: "track name is empty")
        // The refusal names WHICH note.
        XCTAssertThrowsError(try SMFWriter(tracks: [SMFTrack(name: "Keys", notes: [
            SMFNote(pitch: 60, bar: 1), SMFNote(pitch: 62, bar: 1), SMFNote(pitch: 200, bar: 1)
        ])])) { XCTAssertTrue("\($0)".contains("Keys note 3"), "\($0)") }
    }

    /// A position before the origin is a caller bug, not something to clamp.
    func testRefusesAPositionBeforeTheOrigin() {
        var timing = SMFTiming()
        timing.originBar = 9
        XCTAssertThrowsError(try SMFWriter(
            tracks: [SMFTrack(name: "Early", notes: [SMFNote(pitch: 60, bar: 8)])], timing: timing
        )) { XCTAssertTrue("\($0)".contains("before origin_bar 9"), "\($0)") }
    }

    /// A tick past the 4-byte VLQ ceiling is refused in `init`, so `encode()`
    /// can never hit the precondition inside the VLQ encoder.
    func testRefusesAPositionPastTheVLQCeiling() {
        // 0x0FFFFFFF ticks at 960 ppq is ~69 905 bars of 4/4.
        XCTAssertThrowsError(try SMFWriter(tracks: [
            SMFTrack(name: "Far", notes: [SMFNote(pitch: 60, bar: 100_000)])
        ])) { XCTAssertTrue("\($0)".contains("maximum a delta time can express"), "\($0)") }
    }

    /// A constant meter map that disagrees with `beats_per_bar` is refused
    /// rather than ignored: a constant map is never used for positions, so the
    /// disagreement would silently misplace every bar.
    func testRefusesAConstantMeterMapThatDisagreesWithBeatsPerBar() {
        var timing = SMFTiming()
        timing.beatsPerBar = 4
        timing.meterMap = meter([(1, 3, 4)])
        XCTAssertThrowsError(try SMFWriter(
            tracks: [SMFTrack(name: "T", notes: [SMFNote(pitch: 60, bar: 1)])], timing: timing
        )) { XCTAssertTrue("\($0)".contains("beats a bar while beats_per_bar"), "\($0)") }
    }

    /// The tempo meta's field is 24 bits; a tempo it cannot hold is refused
    /// before anything is written.
    func testRefusesATempoTheMetaCannotHold() {
        var timing = SMFTiming()
        timing.tempo = .constant(2)
        XCTAssertThrowsError(try SMFWriter(
            tracks: [SMFTrack(name: "T", notes: [SMFNote(pitch: 60, bar: 1)])], timing: timing
        )) { XCTAssertTrue("\($0)".contains("3.58 BPM"), "\($0)") }
    }

    func testRefusesAnImpossibleResolution() {
        var timing = SMFTiming()
        timing.ticksPerQuarter = 40000
        XCTAssertThrowsError(try SMFWriter(
            tracks: [SMFTrack(name: "T", notes: [SMFNote(pitch: 60, bar: 1)])], timing: timing
        )) { XCTAssertTrue("\($0)".contains("ticks_per_quarter"), "\($0)") }
    }

    // MARK: - Shared pitch vocabulary

    /// The writer parses pitches through the one note-name implementation in
    /// this server, so a part written for `logic_record_midi` and the same part
    /// written to a file mean the same notes: Logic's convention, C3 = 60.
    func testPitchNamesFollowLogicsConvention() throws {
        XCTAssertEqual(try SMFWriter.pitch("C3"), 60)
        XCTAssertEqual(try SMFWriter.pitch(60), 60)
        XCTAssertEqual(try SMFWriter.pitch("60"), 60)
        XCTAssertEqual(try SMFWriter.pitch("F#1"), 42)
        XCTAssertEqual(try SMFWriter.pitch("Bb2"), 58)
        XCTAssertEqual(try SMFWriter.pitch("D♯2"), 51)
        XCTAssertEqual(try SMFWriter.pitch("C-2"), 0)
        XCTAssertEqual(try SMFWriter.pitch("G8"), 127)
        XCTAssertThrowsError(try SMFWriter.pitch("H3"))
        XCTAssertThrowsError(try SMFWriter.pitch("C9"))
        XCTAssertThrowsError(try SMFWriter.pitch(nil))
        // The same answer `EventListWrite` gives, because it IS that answer.
        for name in ["C3", "F#1", "Bb2", "D♯2", "A0"] {
            XCTAssertEqual(try SMFWriter.pitch(name), EventListWrite.parsePitchArgument(name) ?? -1)
        }
    }

    /// A non-ASCII track name survives as UTF-8. Whether LOGIC reads it that way
    /// is the live route's question; this pins what the bytes say.
    func testTrackNamesAreUTF8() throws {
        let data = try SMFWriter(tracks: [
            SMFTrack(name: "Stråkar", notes: [SMFNote(pitch: 60, bar: 1)])
        ]).encode()
        let track = try SMFTestReader.read(data).tracks[1]
        XCTAssertEqual(track.name, "Stråkar")
        // Seven characters, eight bytes: the å is two, and the meta's VLQ
        // length must count BYTES.
        XCTAssertTrue(bytesContain([UInt8](data), [0xFF, 0x03, 0x08]), hex(data))
    }

    // MARK: - System oracle

    #if canImport(AudioToolbox)
    /// CoreAudio's `MusicSequence` is a Standard MIDI File parser Apple ships
    /// and Logic's own frameworks sit on. Loading the bytes without error, and
    /// finding the notes that were written, is independent evidence that the
    /// file is well-formed — no audio device, no playback, headless.
    func testCoreAudioLoadsTheFileAndFindsEveryNote() throws {
        let names = ["Drums", "Bass", "Keys"]
        var expectedNotes = 0
        let tracks: [SMFTrack] = names.enumerated().map { index, name in
            var track = SMFTrack(name: name, channel: index + 1)
            for bar in 1...4 {
                for step in 0..<4 {
                    track.notes.append(SMFNote(
                        pitch: 40 + index * 7 + step, bar: bar, beat: Double(step) + 1,
                        durationBeats: 0.5, velocity: 90
                    ))
                    expectedNotes += 1
                }
            }
            return track
        }
        var timing = SMFTiming()
        timing.tempo = .constant(120)
        timing.timeSignature = .fromMeter
        let data = try SMFWriter(tracks: tracks, timing: timing).encode()

        var sequence: MusicSequence?
        XCTAssertEqual(NewMusicSequence(&sequence), noErr)
        guard let sequence else { return XCTFail("could not create a MusicSequence") }
        defer { DisposeMusicSequence(sequence) }
        XCTAssertEqual(
            MusicSequenceFileLoadData(sequence, data as CFData, .midiType, MusicSequenceLoadFlags()),
            noErr, "CoreAudio refused the file"
        )
        var trackCount: UInt32 = 0
        XCTAssertEqual(MusicSequenceGetTrackCount(sequence, &trackCount), noErr)
        XCTAssertGreaterThanOrEqual(Int(trackCount), names.count)

        var found = 0
        for index in 0..<trackCount {
            var track: MusicTrack?
            guard MusicSequenceGetIndTrack(sequence, index, &track) == noErr, let track else { continue }
            var iterator: MusicEventIterator?
            guard NewMusicEventIterator(track, &iterator) == noErr, let iterator else { continue }
            defer { DisposeMusicEventIterator(iterator) }
            var hasEvent: DarwinBoolean = false
            MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
            while hasEvent.boolValue {
                var timeStamp = MusicTimeStamp(0)
                var type = MusicEventType(0)
                var payload: UnsafeRawPointer?
                var size: UInt32 = 0
                MusicEventIteratorGetEventInfo(iterator, &timeStamp, &type, &payload, &size)
                if type == kMusicEventType_MIDINoteMessage { found += 1 }
                MusicEventIteratorNextEvent(iterator)
                MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
            }
        }
        XCTAssertEqual(found, expectedNotes, "CoreAudio found a different number of notes")
    }
    #endif
}
