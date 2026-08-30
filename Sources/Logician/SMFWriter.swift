import Foundation

// MARK: - Standard MIDI File writing (bars and beats -> bytes)

/// The vocabulary of this file is deliberately `logic_record_midi`'s: a note is
/// a pitch at a `bar` and a 1-based fractional `beat`, `duration_beats` long,
/// with a velocity and a channel; CC, pitch-bend and program events carry the
/// same position pair. Pitches parse through `EventListWrite.parsePitchArgument`
/// — the one note-name→number implementation in this server (Logic's
/// convention, middle C = C3 = 60) — so a part written for the real-time
/// recorder and the same part written to a file mean the same notes.
///
/// WHAT THIS TYPE IS FOR. `logic_record_midi` plays a part in over the MIDI port
/// in real wall-clock time, one track at a time. A Standard MIDI File is the
/// other shape: a whole arrangement — many named tracks, each on its own channel
/// — handed to Logic in ONE import. This writer is the pure, testable half of
/// that; nothing here touches Logic, the bridge, or the filesystem unless
/// `write(to:)` is called.
///
/// ## Byte-level decisions
///
/// - **PPQ 960.** The project's established resolution (`TempoMap`'s Position
///   parsing already assumes Logic's 960 ppq), so a 1/16 division is 240 ticks
///   and nothing rounds on import. Overridable, 1…32767.
/// - **Delta times are VLQs**, 1–4 bytes, and every position is validated in
///   `init` to fit `0x0FFFFFFF` ticks so encoding cannot overflow.
/// - **Running status** is on by default: a channel message whose status byte
///   equals the previous one drops it. Meta events reset it (the spec requires
///   that), and the first event of a track never uses it.
/// - **Note-offs are note-ons with velocity 0** (`0x9n pitch 0x00`) whenever the
///   release velocity is 0 and running status is on — that is what lets a run of
///   notes on one channel share a single status byte, which is where the
///   compaction actually comes from. A non-zero release velocity, or running
///   status turned off, emits a real `0x8n` note-off instead: correctness first.
/// - **Ordering inside one tick** is fixed and deterministic: meta, program
///   change, control change, pitch bend, note-off, note-on — so a note that ends
///   exactly where the next one starts is released before the new one sounds
///   (no zero-length re-trigger), and two runs of the writer produce identical
///   bytes.
///
/// ## What is NOT written unless asked
///
/// `timing.tempo` and `timing.timeSignature` both default to `.omit`, and that
/// default is a safety property rather than a convenience: a tempo meta event in
/// the conductor track is a WRITE TO THE USER'S TEMPO MAP the moment Logic
/// imports the file (the Smart Tempo lesson — see `logic_record_midi`'s
/// Adapt-mode refusal), and a time-signature meta is the same write against the
/// signature track. A file with neither cannot move either. The caller that
/// knows the policy asks for them explicitly.
///
/// ## Logic import assumptions (documented so the live route can verify them)
///
/// 1. A format-1 file's track-name meta (`FF 03`) at tick 0 names the track and
///    its region in Logic's import. Assumed, not measured.
/// 2. Logic creates one track per MTrk chunk of a format-1 file and leaves the
///    conductor track (which carries no channel events) out of the arrangement.
/// 3. Imported material is anchored at bar 1 = tick 0, i.e. positions are
///    absolute project bars. `timing.originBar` shifts that anchor for a caller
///    that wants the file's tick 0 to mean some later bar.
/// 4. Note-off before note-on at the same tick is honoured (the note is not
///    swallowed). This is why the writer does not shorten notes by a tick.
/// 5. Track names are written as UTF-8. The SMF spec says ASCII; Logic 12 reads
///    UTF-8. Non-ASCII names are the case to check on the live route.
struct SMFWriter {
    /// Logic's internal resolution, and this server's established one.
    static let logicTicksPerQuarter = 960

    /// SMF header format word. Format 2 (independent sequences) is not written:
    /// Logic imports it as unrelated patterns and no caller here wants that.
    enum Format: Int, Equatable {
        /// One MTrk holding everything, channels doing the separating.
        case singleTrack = 0
        /// A conductor track plus one MTrk per named instrument track. The
        /// shape this writer exists for.
        case multiTrack = 1
    }

    let format: Format
    let tracks: [SMFTrack]
    let timing: SMFTiming
    /// Written as a sequence-name meta at tick 0 of the first chunk (the
    /// conductor track in format 1). Nil writes none.
    let sequenceName: String?
    /// Whether repeated status bytes are dropped. Off produces a longer file in
    /// which every event is self-describing — the shape to reach for when
    /// something downstream is suspected of mis-parsing.
    let usesRunningStatus: Bool

    /// Validates the whole arrangement up front, so `encode()` cannot fail.
    ///
    /// Every refusal names the track and the event index it came from, because
    /// the caller is assembling a hundred notes at a time and "velocity must be
    /// 1-127" alone does not say which one.
    ///
    /// - Throws: `LogicianError.invalidArguments` for any out-of-range value, a
    ///   position before `timing.originBar`, a format/track-count mismatch, or a
    ///   position so far out that its tick would not fit a 4-byte VLQ.
    init(
        format: Format = .multiTrack,
        tracks: [SMFTrack],
        timing: SMFTiming = SMFTiming(),
        sequenceName: String? = nil,
        usesRunningStatus: Bool = true
    ) throws {
        guard !tracks.isEmpty else {
            throw LogicianError.invalidArguments("a MIDI file needs at least one track")
        }
        guard format != .singleTrack || tracks.count == 1 else {
            throw LogicianError.invalidArguments(
                "format 0 holds exactly ONE track (each track's name would be lost in the merge);"
                    + " \(tracks.count) tracks were given — use format 1"
            )
        }
        try timing.validate()
        for (index, track) in tracks.enumerated() {
            try track.validate(timing: timing, label: track.name ?? "track \(index + 1)")
        }
        if let sequenceName, sequenceName.trimmingCharacters(in: .whitespaces).isEmpty {
            throw LogicianError.invalidArguments("sequence_name is empty")
        }
        self.format = format
        self.tracks = tracks
        self.timing = timing
        self.sequenceName = sequenceName
        self.usesRunningStatus = usesRunningStatus
    }

    // MARK: Encoding

    /// The complete file. Total, deterministic, and already validated by `init`.
    func encode() -> Data {
        var chunks: [UInt8] = []
        let trackChunks: [[UInt8]]
        switch format {
        case .multiTrack:
            trackChunks = [conductorChunk()] + tracks.map { trackChunk($0) }
        case .singleTrack:
            // The degenerate case: conductor meta and the one track's events in
            // a single MTrk, merged on the same tick/priority ordering.
            var events = conductorEvents()
            events.append(contentsOf: trackEvents(tracks[0], startingAt: events.count))
            trackChunks = [SMFWriter.chunk("MTrk", encode(events: sorted(events)))]
        }
        chunks += SMFWriter.chunk("MThd", [
            UInt8((format.rawValue >> 8) & 0xFF), UInt8(format.rawValue & 0xFF),
            UInt8((trackChunks.count >> 8) & 0xFF), UInt8(trackChunks.count & 0xFF),
            UInt8((timing.ticksPerQuarter >> 8) & 0xFF), UInt8(timing.ticksPerQuarter & 0xFF)
        ])
        for chunk in trackChunks { chunks += chunk }
        return Data(chunks)
    }

    /// Writes the file. The bytes are produced first and handed to `Data.write`
    /// atomically, so a failure leaves no half-written file behind.
    ///
    /// - Returns: the number of bytes written.
    @discardableResult
    func write(to url: URL) throws -> Int {
        let data = encode()
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw LogicianError.writeFailed(
                "could not write the MIDI file to \(url.path): \(error.localizedDescription)"
            )
        }
        return data.count
    }

    // MARK: Chunk assembly

    private func conductorChunk() -> [UInt8] {
        SMFWriter.chunk("MTrk", encode(events: sorted(conductorEvents())))
    }

    private func trackChunk(_ track: SMFTrack) -> [UInt8] {
        SMFWriter.chunk("MTrk", encode(events: sorted(trackEvents(track, startingAt: 0))))
    }

    /// Sequence name, tempo meta and time-signature meta — everything that is
    /// about the SONG rather than about a part.
    private func conductorEvents() -> [RawEvent] {
        var events: [RawEvent] = []
        func add(tick: Int, bytes: [UInt8]) {
            events.append(RawEvent(
                tick: tick, priority: Priority.meta, order: events.count, bytes: bytes, isMeta: true
            ))
        }
        if let sequenceName {
            add(tick: 0, bytes: SMFWriter.textMeta(0x03, sequenceName))
        }
        for (tick, bpm) in timing.tempoPoints() {
            add(tick: tick, bytes: SMFWriter.tempoMeta(bpm))
        }
        for signature in timing.timeSignaturePoints() {
            add(tick: signature.tick, bytes: SMFWriter.timeSignatureMeta(
                numerator: signature.numerator, denominator: signature.denominator
            ))
        }
        return events
    }

    private func trackEvents(_ track: SMFTrack, startingAt offset: Int) -> [RawEvent] {
        var events: [RawEvent] = []
        func add(tick: Int, priority: Int, bytes: [UInt8], isMeta: Bool = false) {
            events.append(RawEvent(
                tick: tick, priority: priority, order: offset + events.count,
                bytes: bytes, isMeta: isMeta
            ))
        }
        if let name = track.name {
            add(tick: 0, priority: Priority.meta, bytes: SMFWriter.textMeta(0x03, name), isMeta: true)
        }
        // `|` and `-` share a precedence group in Swift, so the channel nibble
        // is computed on its own line rather than inline with the status.
        for change in track.programChanges {
            let status = 0xC0 | UInt8((change.channel ?? track.channel) - 1)
            add(
                tick: timing.tick(bar: change.bar, beat: change.beat),
                priority: Priority.programChange,
                bytes: [status, UInt8(change.program)]
            )
        }
        for change in track.controlChanges {
            let status = 0xB0 | UInt8((change.channel ?? track.channel) - 1)
            add(
                tick: timing.tick(bar: change.bar, beat: change.beat),
                priority: Priority.controlChange,
                bytes: [status, UInt8(change.controller), UInt8(change.value)]
            )
        }
        for bend in track.pitchBends {
            let status = 0xE0 | UInt8((bend.channel ?? track.channel) - 1)
            let fourteen = bend.value + 8192
            add(
                tick: timing.tick(bar: bend.bar, beat: bend.beat),
                priority: Priority.pitchBend,
                bytes: [status, UInt8(fourteen & 0x7F), UInt8((fourteen >> 7) & 0x7F)]
            )
        }
        for note in track.notes {
            let channel = UInt8((note.channel ?? track.channel) - 1)
            let (onTick, offTick) = timing.noteTicks(note)
            add(
                tick: onTick, priority: Priority.noteOn,
                bytes: [0x90 | channel, UInt8(note.pitch), UInt8(note.velocity)]
            )
            // The note-on-velocity-0 form is what running status can chain; a
            // real note-off is emitted when a release velocity was asked for,
            // or when running status is off and self-describing bytes are the
            // point.
            let offBytes: [UInt8] = (note.releaseVelocity == 0 && usesRunningStatus)
                ? [0x90 | channel, UInt8(note.pitch), 0x00]
                : [0x80 | channel, UInt8(note.pitch), UInt8(note.releaseVelocity)]
            add(tick: offTick, priority: Priority.noteOff, bytes: offBytes)
        }
        return events
    }

    // MARK: The event stream

    /// Where an event sorts inside one tick. Note-off before note-on is the
    /// load-bearing one: a legato line whose note ends exactly where the next
    /// begins must not have the new note killed by the old one's release.
    private enum Priority {
        static let meta = 0
        static let programChange = 1
        static let controlChange = 2
        static let pitchBend = 3
        static let noteOff = 4
        static let noteOn = 5
    }

    private struct RawEvent {
        let tick: Int
        let priority: Int
        /// Insertion index — the tie-break that makes the sort total, since
        /// Swift's `sort` is not stable.
        let order: Int
        let bytes: [UInt8]
        let isMeta: Bool
    }

    private func sorted(_ events: [RawEvent]) -> [RawEvent] {
        events.sorted { ($0.tick, $0.priority, $0.order) < ($1.tick, $1.priority, $1.order) }
    }

    private func encode(events: [RawEvent]) -> [UInt8] {
        var bytes: [UInt8] = []
        var lastTick = 0
        var runningStatus: UInt8?
        for event in events {
            bytes += SMFWriter.variableLengthQuantity(event.tick - lastTick)
            lastTick = event.tick
            if event.isMeta {
                bytes += event.bytes
                runningStatus = nil // a meta event cancels running status
                continue
            }
            let status = event.bytes[0]
            if usesRunningStatus, runningStatus == status {
                bytes += event.bytes.dropFirst()
            } else {
                bytes += event.bytes
                runningStatus = status
            }
        }
        bytes += [0x00, 0xFF, 0x2F, 0x00] // end of track, delta 0
        return bytes
    }

    // MARK: Primitives

    /// A delta time or meta length as a variable-length quantity: seven bits per
    /// byte, high bit set on every byte but the last. `0x7F` is one byte, `0x80`
    /// is two (`81 00`), `0x3FFF` is two (`FF 7F`), `0x4000` is three.
    ///
    /// - Precondition: `0 <= value <= 0x0FFFFFFF` (four bytes, the SMF maximum);
    ///   `init` validates every tick against that bound.
    static func variableLengthQuantity(_ value: Int) -> [UInt8] {
        precondition(value >= 0 && value <= 0x0FFF_FFFF, "VLQ out of range: \(value)")
        var buffer: [UInt8] = [UInt8(value & 0x7F)]
        var remaining = value >> 7
        while remaining > 0 {
            buffer.append(UInt8((remaining & 0x7F) | 0x80))
            remaining >>= 7
        }
        return Array(buffer.reversed())
    }

    /// `<4-char type><big-endian 32-bit length><payload>` — the only chunk shape
    /// an SMF has.
    static func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let length = UInt32(payload.count)
        return Array(type.utf8) + [
            UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)
        ] + payload
    }

    /// `FF <type> <VLQ length> <UTF-8 text>` — sequence name (0x01/0x03),
    /// track name (0x03), instrument name (0x04).
    static func textMeta(_ type: UInt8, _ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return [0xFF, type] + variableLengthQuantity(bytes.count) + bytes
    }

    /// `FF 51 03 tttttt` — microseconds per quarter note. 120 BPM is 500000
    /// (`07 A1 20`).
    static func tempoMeta(_ bpm: Double) -> [UInt8] {
        let microseconds = SMFWriter.microsecondsPerQuarter(bpm)
        return [
            0xFF, 0x51, 0x03,
            UInt8((microseconds >> 16) & 0xFF),
            UInt8((microseconds >> 8) & 0xFF),
            UInt8(microseconds & 0xFF)
        ]
    }

    /// Rounded microseconds per quarter note, clamped to the 24-bit field.
    /// `SMFTiming.validate()` refuses a BPM that would need the clamp.
    static func microsecondsPerQuarter(_ bpm: Double) -> Int {
        Int(min(max((60_000_000.0 / bpm).rounded(), 1), Double(0xFF_FFFF)))
    }

    /// `FF 58 04 nn dd cc bb` — numerator, log2(denominator), MIDI clocks per
    /// metronome click, 32nd notes per quarter. The last two are written as the
    /// conventional 24 and 8; every DAW this targets derives its click from the
    /// signature itself.
    static func timeSignatureMeta(numerator: Int, denominator: Int) -> [UInt8] {
        var power: UInt8 = 0
        var value = denominator
        while value > 1 { value >>= 1; power += 1 }
        return [0xFF, 0x58, 0x04, UInt8(numerator), power, 24, 8]
    }
}

// MARK: - Timing: bars and beats to ticks

/// How musical positions become ticks, and what (if anything) the conductor
/// track says about tempo and meter.
///
/// The bar→beat half follows the same constant-meter contract as everything else
/// in this server (`MeterMap`): `beatsPerBar` is authoritative, and the meter map
/// is consulted for positions only when it actually VARIES. A constant map is
/// still used for the time-signature meta, where it is the notation that matters
/// rather than the arithmetic. A constant map that disagrees with `beatsPerBar`
/// is refused rather than silently ignored.
struct SMFTiming: Equatable {
    /// Ticks per quarter note. 960 = Logic's own resolution.
    var ticksPerQuarter: Int = SMFWriter.logicTicksPerQuarter
    /// Quarter-note beats in a bar — 4 for 4/4, 3 for 3/4 and for 6/8.
    var beatsPerBar: Double = 4
    /// The project's signature track, honoured for positions only when variable.
    var meterMap: MeterMap?
    /// The bar that becomes tick 0. 1 = absolute project positions (the
    /// default); a later bar makes the file's start mean that bar.
    var originBar: Int = 1
    /// What the conductor track says about tempo. `.omit` by default — see the
    /// note on `SMFWriter`: a tempo meta rewrites the importing project's tempo
    /// map.
    var tempo: SMFTempoPolicy = .omit
    /// What the conductor track says about meter. `.omit` by default, for the
    /// same reason.
    var timeSignature: SMFTimeSignaturePolicy = .omit

    /// The largest tick a 4-byte VLQ can express, and therefore the furthest a
    /// position may sit from the origin.
    static let maximumTick = 0x0FFF_FFFF

    /// - Throws: `LogicianError.invalidArguments` naming the field that is out
    ///   of range or self-contradictory.
    func validate() throws {
        guard (1...32767).contains(ticksPerQuarter) else {
            throw LogicianError.invalidArguments(
                "ticks_per_quarter must be 1-32767 (Logic's own resolution is"
                    + " \(SMFWriter.logicTicksPerQuarter)); got \(ticksPerQuarter)"
            )
        }
        guard beatsPerBar > 0, beatsPerBar.isFinite else {
            throw LogicianError.invalidArguments("beats_per_bar must be greater than 0")
        }
        guard originBar >= 1 else {
            throw LogicianError.invalidArguments("origin_bar must be 1 or greater")
        }
        if let meterMap, meterMap.isConstant,
           abs(meterMap.beatsPerBar(atBar: originBar) - beatsPerBar) > 1e-9 {
            throw LogicianError.invalidArguments(
                "the meter map says \(meterMap.signatures[0]) ="
                    + " \(meterMap.beatsPerBar(atBar: originBar)) beats a bar while beats_per_bar"
                    + " says \(beatsPerBar); a constant meter map is not used for positions, so"
                    + " the disagreement would silently misplace every bar"
            )
        }
        switch tempo {
        case .omit:
            break
        case .constant(let bpm):
            try SMFTiming.validateTempo(bpm)
        case .map(let map):
            for event in map.events { try SMFTiming.validateTempo(event.bpm) }
        }
        switch timeSignature {
        case .omit:
            break
        case .constant(let numerator, let denominator):
            try SMFTiming.validateSignature(numerator: numerator, denominator: denominator)
        case .fromMeter:
            if let meterMap {
                for event in meterMap.events {
                    try SMFTiming.validateSignature(
                        numerator: event.numerator, denominator: event.denominator
                    )
                }
            } else {
                _ = try derivedSignature()
            }
        }
    }

    private static func validateTempo(_ bpm: Double) throws {
        // The tempo meta's field is 24 bits of microseconds per quarter, so the
        // slowest expressible tempo is ~3.58 BPM.
        guard bpm.isFinite, bpm > 0, 60_000_000.0 / bpm <= Double(0xFF_FFFF) else {
            throw LogicianError.invalidArguments(
                "tempo \(bpm) BPM cannot be written: a tempo meta event holds 24 bits of"
                    + " microseconds per quarter note, which is 3.58 BPM at the slow end"
            )
        }
    }

    private static func validateSignature(numerator: Int, denominator: Int) throws {
        guard (1...255).contains(numerator) else {
            throw LogicianError.invalidArguments(
                "time-signature numerator must be 1-255; got \(numerator)"
            )
        }
        guard [1, 2, 4, 8, 16, 32, 64].contains(denominator) else {
            throw LogicianError.invalidArguments(
                "time-signature denominator must be a power of two, 1-64; got \(denominator)"
            )
        }
    }

    /// The signature `.fromMeter` writes when there is no meter map: the scalar
    /// `beatsPerBar` read as n/4.
    func derivedSignature() throws -> (numerator: Int, denominator: Int) {
        let rounded = beatsPerBar.rounded()
        guard abs(beatsPerBar - rounded) < 1e-9, rounded >= 1, rounded <= 255 else {
            throw LogicianError.invalidArguments(
                "beats_per_bar \(beatsPerBar) is not a whole number of quarter notes, so no"
                    + " time signature follows from it — pass the signature explicitly or a"
                    + " meter map (6/8 is 3 beats a bar and must be written as 6/8, not 3/4)"
            )
        }
        return (Int(rounded), 4)
    }

    // MARK: Positions

    /// Quarter-note beats from `originBar`'s bar line to (`bar`, `beat`).
    /// Negative for a position before the origin, which the writer refuses on.
    func beatOffset(bar: Int, beat: Double) -> Double {
        let bars: Double
        if let meterMap, meterMap.isVariable {
            bars = meterMap.beatOffset(bar: bar) - meterMap.beatOffset(bar: originBar)
        } else {
            bars = Double(bar - originBar) * beatsPerBar
        }
        return bars + (beat - 1)
    }

    /// The tick of a musical position, rounded to the nearest tick.
    func tick(bar: Int, beat: Double) -> Int {
        tick(beatOffset: beatOffset(bar: bar, beat: beat))
    }

    /// The tick a beat offset from the origin lands on.
    func tick(beatOffset: Double) -> Int {
        Int((beatOffset * Double(ticksPerQuarter)).rounded())
    }

    /// A note's on and off ticks. A positive duration that rounds to nothing is
    /// lengthened to a single tick: a zero-length note is one that never sounds,
    /// and silently dropping it would be worse than the tick of drift.
    func noteTicks(_ note: SMFNote) -> (on: Int, off: Int) {
        let start = beatOffset(bar: note.bar, beat: note.beat)
        let on = tick(beatOffset: start)
        let off = max(tick(beatOffset: start + note.durationBeats), on + 1)
        return (on, off)
    }

    /// The conductor's tempo events as (tick, BPM), in tick order, with the
    /// tempo in force AT the origin emitted at tick 0 — a map whose first event
    /// is later than the origin carries that event's tempo backwards, exactly as
    /// `TempoMap`'s own integration does.
    func tempoPoints() -> [(tick: Int, bpm: Double)] {
        switch tempo {
        case .omit:
            return []
        case .constant(let bpm):
            return [(0, bpm)]
        case .map(let map):
            var atOrigin = map.events[0].bpm
            var later: [(tick: Int, bpm: Double)] = []
            for event in map.events {
                let tick = self.tick(bar: event.bar, beat: event.beatInBar)
                if tick <= 0 { atOrigin = event.bpm } else { later.append((tick, event.bpm)) }
            }
            return [(0, atOrigin)] + later
        }
    }

    /// The conductor's time signatures as (tick, signature), same origin rule as
    /// `tempoPoints()`.
    func timeSignaturePoints() -> [(tick: Int, numerator: Int, denominator: Int)] {
        switch timeSignature {
        case .omit:
            return []
        case .constant(let numerator, let denominator):
            return [(0, numerator, denominator)]
        case .fromMeter:
            guard let meterMap else {
                // `validate()` already proved this succeeds.
                guard let derived = try? derivedSignature() else { return [] }
                return [(0, derived.numerator, derived.denominator)]
            }
            var atOrigin = meterMap.events[0]
            var later: [(tick: Int, numerator: Int, denominator: Int)] = []
            for event in meterMap.events {
                let tick = self.tick(bar: event.bar, beat: 1)
                if tick <= 0 {
                    atOrigin = event
                } else {
                    later.append((tick, event.numerator, event.denominator))
                }
            }
            return [(0, atOrigin.numerator, atOrigin.denominator)] + later
        }
    }
}

/// What the conductor track says about tempo. `.omit` writes no tempo meta at
/// all, which is the only setting that cannot touch an importing project's
/// tempo map.
enum SMFTempoPolicy: Equatable {
    case omit
    /// One tempo meta at tick 0.
    case constant(Double)
    /// One tempo meta per event of the project's tempo map (curves are written
    /// as steps, the same approximation `TempoMap` documents).
    case map(TempoMap)
}

/// What the conductor track says about meter. `.omit` writes no signature meta,
/// leaving the importing project's signature track alone.
enum SMFTimeSignaturePolicy: Equatable {
    case omit
    /// One signature meta per event of `SMFTiming.meterMap`, or the signature
    /// that follows from `beatsPerBar` when there is no map.
    case fromMeter
    case constant(numerator: Int, denominator: Int)
}

// MARK: - The arrangement

/// One named track of the file: a name, a default channel, and its events.
///
/// In a format-1 file this becomes one MTrk chunk and, on import, one Logic
/// track. The channel is the track's default; any event may override it, which
/// is what a multi-timbral part needs.
struct SMFTrack: Equatable {
    /// Written as a track-name meta at tick 0. Nil writes none — the track then
    /// arrives in Logic under whatever name Logic invents.
    var name: String?
    /// 1-16, the channel every event on this track uses unless it says otherwise.
    var channel: Int = 1
    var notes: [SMFNote] = []
    var controlChanges: [SMFControlChange] = []
    var pitchBends: [SMFPitchBend] = []
    var programChanges: [SMFProgramChange] = []

    /// Every event this track holds is in range and lands at or after the
    /// origin. Called by `SMFWriter.init`; `label` names the track in refusals.
    func validate(timing: SMFTiming, label: String) throws {
        if let name, name.trimmingCharacters(in: .whitespaces).isEmpty {
            throw LogicianError.invalidArguments("\(label): the track name is empty")
        }
        try SMFTrack.validateChannel(channel, what: "\(label): the track channel")
        for (index, note) in notes.enumerated() {
            let what = "\(label) note \(index + 1)"
            guard (0...127).contains(note.pitch) else {
                throw LogicianError.invalidArguments("\(what): pitch \(note.pitch) outside 0-127")
            }
            guard (1...127).contains(note.velocity) else {
                throw LogicianError.invalidArguments(
                    "\(what): velocity must be 1-127 (0 is a note-off, not a quiet note);"
                        + " got \(note.velocity)"
                )
            }
            guard (0...127).contains(note.releaseVelocity) else {
                throw LogicianError.invalidArguments(
                    "\(what): release_velocity must be 0-127; got \(note.releaseVelocity)"
                )
            }
            guard note.durationBeats > 0, note.durationBeats.isFinite else {
                throw LogicianError.invalidArguments(
                    "\(what): duration_beats must be greater than 0"
                )
            }
            if let channel = note.channel {
                try SMFTrack.validateChannel(channel, what: "\(what): channel")
            }
            try SMFTrack.validatePosition(
                bar: note.bar, beat: note.beat, timing: timing, what: what,
                throughBeats: note.durationBeats
            )
        }
        for (index, change) in controlChanges.enumerated() {
            let what = "\(label) cc event \(index + 1)"
            guard (0...127).contains(change.controller) else {
                throw LogicianError.invalidArguments(
                    "\(what): controller must be 0-127; got \(change.controller)"
                )
            }
            guard (0...127).contains(change.value) else {
                throw LogicianError.invalidArguments(
                    "\(what): value must be 0-127; got \(change.value)"
                )
            }
            if let channel = change.channel {
                try SMFTrack.validateChannel(channel, what: "\(what): channel")
            }
            try SMFTrack.validatePosition(
                bar: change.bar, beat: change.beat, timing: timing, what: what
            )
        }
        for (index, bend) in pitchBends.enumerated() {
            let what = "\(label) pitch bend \(index + 1)"
            guard (-8192...8191).contains(bend.value) else {
                throw LogicianError.invalidArguments(
                    "\(what): value must be -8192..8191 (0 = centre); got \(bend.value)"
                )
            }
            if let channel = bend.channel {
                try SMFTrack.validateChannel(channel, what: "\(what): channel")
            }
            try SMFTrack.validatePosition(
                bar: bend.bar, beat: bend.beat, timing: timing, what: what
            )
        }
        for (index, change) in programChanges.enumerated() {
            let what = "\(label) program change \(index + 1)"
            guard (0...127).contains(change.program) else {
                throw LogicianError.invalidArguments(
                    "\(what): program must be 0-127 on the wire (Logic displays these 1-128);"
                        + " got \(change.program)"
                )
            }
            if let channel = change.channel {
                try SMFTrack.validateChannel(channel, what: "\(what): channel")
            }
            try SMFTrack.validatePosition(
                bar: change.bar, beat: change.beat, timing: timing, what: what
            )
        }
    }

    private static func validateChannel(_ channel: Int, what: String) throws {
        guard (1...16).contains(channel) else {
            throw LogicianError.invalidArguments("\(what) must be 1-16; got \(channel)")
        }
    }

    private static func validatePosition(
        bar: Int, beat: Double, timing: SMFTiming, what: String, throughBeats: Double = 0
    ) throws {
        guard bar >= 1 else {
            throw LogicianError.invalidArguments("\(what): bar must be 1 or greater; got \(bar)")
        }
        guard beat >= 1, beat.isFinite else {
            throw LogicianError.invalidArguments(
                "\(what): beat is 1-based (beat 1 is the bar line); got \(beat)"
            )
        }
        let offset = timing.beatOffset(bar: bar, beat: beat)
        guard offset >= -1e-9 else {
            throw LogicianError.invalidArguments(
                "\(what): bar \(bar) beat \(beat) lies before origin_bar \(timing.originBar)"
            )
        }
        let last = timing.tick(beatOffset: offset + throughBeats)
        guard last >= 0, last <= SMFTiming.maximumTick else {
            throw LogicianError.invalidArguments(
                "\(what): bar \(bar) is \(last) ticks from origin_bar \(timing.originBar), past the"
                    + " \(SMFTiming.maximumTick)-tick maximum a delta time can express"
            )
        }
    }
}

/// A note, in `logic_record_midi`'s vocabulary.
struct SMFNote: Equatable {
    /// MIDI note number 0-127. Use `SMFWriter.pitch(_:)` for names.
    var pitch: Int
    /// Absolute bar, 1-based.
    var bar: Int
    /// Beat within the bar, 1-based; fractions allowed (1.5 = the offbeat).
    var beat: Double = 1
    /// Length in quarter-note beats.
    var durationBeats: Double = 1
    /// 1-127.
    var velocity: Int = 100
    /// 0-127. 0 (the default) lets the note-off ride running status as a
    /// note-on with velocity 0; anything else forces a real `0x8n` note-off.
    var releaseVelocity: Int = 0
    /// 1-16, or nil for the track's channel.
    var channel: Int?
}

/// A control-change event — mod wheel (1), expression (11), sustain (64).
struct SMFControlChange: Equatable {
    var controller: Int
    var value: Int
    var bar: Int
    var beat: Double = 1
    var channel: Int?
}

/// A pitch-bend event, -8192…8191 with 0 at centre (the same units
/// `logic_record_midi` takes).
struct SMFPitchBend: Equatable {
    var value: Int
    var bar: Int
    var beat: Double = 1
    var channel: Int?
}

/// A program change. `program` is the wire number, 0-127; Logic's UI counts
/// these from 1.
struct SMFProgramChange: Equatable {
    var program: Int
    var bar: Int
    var beat: Double = 1
    var channel: Int?
}

extension SMFWriter {
    /// A pitch as an agent may plausibly give it — `60`, `"60"`, `"C3"`,
    /// `"F#1"`, `"Bb2"`, `"D♯2"` — as a MIDI note number.
    ///
    /// This is `EventListWrite.parsePitchArgument`, the one note-name
    /// implementation in this server, wearing this file's name: Logic's
    /// convention, middle C = C3 = 60, which is also what `logic_record_midi`
    /// and `logic_edit_event` accept. Duplicating it here would be how the file
    /// writer and the recorder start disagreeing about what "C3" means.
    ///
    /// - Throws: `LogicianError.invalidArguments` naming the convention.
    static func pitch(_ value: Any?) throws -> Int {
        guard let parsed = EventListWrite.parsePitchArgument(value) else {
            throw LogicianError.invalidArguments(
                "pitch must be a MIDI note number 0-127 or a note name in Logic's own spelling,"
                    + " where C3 is middle C (60): 'C3', 'F#1', 'Bb2', 'D♯2'"
            )
        }
        return parsed
    }
}
