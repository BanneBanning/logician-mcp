import Foundation

// MARK: - The meter map (which bar is how many beats long)

/// One time-signature event, as Logic's Signature List publishes it: the bar it
/// starts on and the signature that starts there.
///
/// Logic's tempo is quarter-note BPM, so a bar's length in the beats every other
/// piece of math here counts is `numerator x 4 / denominator` — 3/4 is three
/// beats, 6/8 is three, 7/8 is three and a half, 5/4 is five. That conversion is
/// the whole reason this type exists rather than a bare integer.
struct MeterEvent: Equatable, Codable {
    /// 1-based bar the signature starts on, exactly as the Position cell reads.
    let bar: Int
    let numerator: Int
    let denominator: Int

    init(bar: Int, numerator: Int, denominator: Int) {
        self.bar = bar
        self.numerator = numerator
        self.denominator = denominator
    }

    /// The bar's length in quarter-note beats.
    var beatsPerBar: Double { Double(numerator) * 4.0 / Double(denominator) }

    /// `"4/4"`, the way Logic writes it and the way a result payload should.
    var signature: String { "\(numerator)/\(denominator)" }
}

/// A project's meter map: the signature events in bar order, and the bar→beat
/// arithmetic that a changing meter makes non-linear.
///
/// The relationship to `TempoMap` is deliberate and one-directional: the tempo
/// map converts BEATS to SECONDS, this one converts BARS to BEATS, and every
/// bar→seconds conversion in this server is the composition of the two. Before
/// this type existed the bar→beat half was a single multiplication by one
/// beats-per-bar — the last assumption left in the bar math after the tempo map
/// landed (ROADMAP item 3).
///
/// THE CONSTANT-METER CONTRACT. A map whose signatures all describe the same bar
/// length is *reported* and never *used*: every consumer asks `isVariable` first
/// and falls back to the caller's scalar `beats_per_bar` when the answer is no.
/// That is not laziness — it is what keeps a constant-meter project's boundaries
/// bit-for-bit identical to what this server has always cut, the same discipline
/// `TempoMap.rangeSeconds` applies to its one-event fast path. The scalar also
/// remains overridable by the caller, which a map would silently take away.
struct MeterMap: Equatable, Codable {
    /// Where the map came from. Only `.signatureList` is a READ map.
    enum Source: String, Equatable, Codable {
        /// Read row by row out of Logic's Signature List (List Editors >
        /// Signature, or `Window > Open Signature List`).
        case signatureList
        /// Built from the control bar's one time-signature reading — the
        /// pre-map behavior wearing this type's clothes. NOT evidence about the
        /// project's real signature track.
        case singleReading
    }

    /// Sorted by bar, never empty, every numerator/denominator positive.
    let events: [MeterEvent]
    let source: Source

    init?(events: [MeterEvent], source: Source) {
        guard !events.isEmpty,
              events.allSatisfy({ $0.bar >= 1 && $0.numerator > 0 && $0.denominator > 0 })
        else { return nil }
        self.events = events.sorted { $0.bar < $1.bar }
        self.source = source
    }

    /// The one-event map that reproduces the constant-meter behavior exactly.
    static func constant(numerator: Int, denominator: Int = 4) -> MeterMap? {
        MeterMap(
            events: [MeterEvent(bar: 1, numerator: numerator, denominator: denominator)],
            source: .singleReading
        )
    }

    /// Do all the events describe the same bar length? A 3/4 followed by a 6/8
    /// is NOT constant even though both are three beats — the bar lengths agree,
    /// so the arithmetic is unaffected, and this asks the arithmetic's question
    /// rather than the notation's.
    var isConstant: Bool {
        guard let first = events.first else { return true }
        return events.allSatisfy { abs($0.beatsPerBar - first.beatsPerBar) < 1e-9 }
    }

    /// True when this map actually changes the bar math. Every consumer branches
    /// on this and on nothing else; see the constant-meter contract above.
    var isVariable: Bool { !isConstant }

    /// The signatures in bar order, for result payloads: `["4/4", "3/4"]`.
    var signatures: [String] { events.map(\.signature) }

    /// The bars the signatures start on, paired with `signatures`.
    var bars: [Int] { events.map(\.bar) }

    /// The meter in force in `bar`, in quarter-note beats.
    ///
    /// A map whose first event is not at bar 1 (Logic always puts one there, but
    /// a partial read must not invent a meter) carries that first event's
    /// signature backwards over the bars before it — the same choice
    /// `TempoMap.seconds` makes for the stretch before its first tempo event.
    func beatsPerBar(atBar bar: Int) -> Double {
        var current = events[0].beatsPerBar
        for event in events {
            if event.bar > bar { break }
            current = event.beatsPerBar
        }
        return current
    }

    /// Quarter-note beats from bar 1 beat 1 (which is 0) to `bar`'s bar line.
    ///
    /// This is the primitive the whole type exists for: under one meter it is
    /// `(bar - 1) x beatsPerBar`, and under a changing one it is the sum of the
    /// individual segments' lengths, which is not any single multiplication.
    func beatOffset(bar: Int) -> Double {
        guard bar > 1 else { return 0 }
        var total = 0.0
        var current = events[0].beatsPerBar
        var filledTo = 1
        for event in events {
            let start = max(event.bar, 1)
            if start >= bar { break }
            if start > filledTo {
                total += Double(start - filledTo) * current
                filledTo = start
            }
            current = event.beatsPerBar
        }
        return total + Double(bar - filledTo) * current
    }

    /// Beats from `fromBar`'s bar line to `toBar` beat `beat` (1-based within
    /// the bar) — what a note's or an automation point's offset inside a take is.
    /// Negative when the position lies before `fromBar`, which callers refuse on.
    func beatOffset(fromBar: Int, toBar: Int, beat: Double) -> Double {
        beatOffset(bar: toBar) - beatOffset(bar: fromBar) + (beat - 1)
    }

    /// The bar a beat offset from project start falls in, and how far into it —
    /// the inverse of `beatOffset(bar:)`, for measuring where a take ends.
    func position(atBeatOffset beats: Double) -> (bar: Int, beatInBar: Double) {
        guard beats > 0 else { return (1, 1 + beats) }
        var bar = 1
        var consumed = 0.0
        // Walk bar by bar: exact, rather than a division that assumes one meter.
        // The cap is not a correctness limit but a refusal to hang — Logic's own
        // maximum project length is far inside it, and a caller that asks about
        // bar 100 001 gets the last bar this walk reached rather than a spin.
        while bar < 100_000 {
            let length = beatsPerBar(atBar: bar)
            if consumed + length > beats + 1e-9 { break }
            consumed += length
            bar += 1
        }
        return (bar, 1 + (beats - consumed))
    }

    // MARK: Signature List row parsing (pure; fed by AXListEditors)

    /// Logic's Signature cell text. The Signature List publishes a signature as
    /// `"4/4"`; a Swedish locale changes decimal separators, never this slash.
    /// Anything else — a key signature, a blank cell — is refused rather than
    /// guessed at, because a wrong bar length silently misplaces every later bar.
    static func parseSignature(_ raw: String) -> (numerator: Int, denominator: Int)? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleaned.split(separator: "/", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2,
              let numerator = Int(parts[0]), let denominator = Int(parts[1]),
              numerator > 0, numerator <= 99,
              // Logic's denominators are powers of two, 1 to 64.
              [1, 2, 4, 8, 16, 32, 64].contains(denominator) else { return nil }
        return (numerator, denominator)
    }

    /// What one Signature List row is, decided from its cell texts alone.
    ///
    /// Pure because the rules came out of a live session and should not need one
    /// to stay true. Both of them are things this code got wrong before it was
    /// measured (2026-08-28):
    ///
    /// - **An empty Position cell means bar 1**, not an unreadable row. The
    ///   project's own first time signature and first key signature publish no
    ///   position at all (no children, no value) while a signature created later
    ///   publishes `"41 1 1 1 "` like every other list. Treating the empty cell
    ///   as a parse failure made the meter read fail on EVERY project.
    /// - **A row with no `n/d` anywhere is a key change**, not an error: the
    ///   Signature List holds time and key signatures in one table, and a key
    ///   row's Value cell reads `"B♭ Major"`.
    enum SignatureRow: Equatable {
        case timeSignature(MeterEvent)
        /// A key-signature row: counted for the truncation cross-check, and
        /// then skipped, because it says nothing about bar lengths.
        case keySignature(bar: Int)
        case unreadable(String)
    }

    static func parseSignatureRow(cells: [String], positionIndex: Int) -> SignatureRow {
        let raw = positionIndex < cells.count ? cells[positionIndex] : ""
        let bar: Int
        if raw.trimmingCharacters(in: .whitespaces).isEmpty {
            bar = 1
        } else if let position = parsePosition(raw) {
            bar = position.bar
        } else {
            return .unreadable(
                "position '\(raw)' is neither empty (the project's initial signature)"
                    + " nor bar/beat/division/tick"
            )
        }
        let signature = cells.enumerated()
            .filter { $0.offset != positionIndex }
            .lazy
            .compactMap { parseSignature($0.element) }
            .first
        guard let signature else { return .keySignature(bar: bar) }
        return .timeSignature(MeterEvent(
            bar: bar, numerator: signature.numerator, denominator: signature.denominator
        ))
    }

    /// The bar out of a Signature List Position cell (`"9 1 1 1 "` — same
    /// grammar as the Tempo List's, and parsed by the same function). Only the
    /// BAR is kept: a signature change that did not sit on a bar line would make
    /// "which bar is this many beats long" unanswerable, so a sub-bar position is
    /// reported by the reader rather than silently rounded here.
    static func parsePosition(_ raw: String) -> (bar: Int, onBarLine: Bool)? {
        guard let position = TempoMap.parseTempoListPosition(raw) else { return nil }
        return (position.bar, position.beatInBar == 1)
    }
}
