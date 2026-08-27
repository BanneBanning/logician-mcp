import Foundation

// MARK: - The tempo map (bars -> seconds under a tempo track)

/// One tempo event, as Logic's Tempo List publishes it: a musical position and
/// the BPM that starts there.
struct TempoEvent: Equatable, Codable {
    /// 1-based bar, exactly as the Position cell reads it.
    let bar: Int
    /// 1-based beat WITHIN the bar (beat 1 = the bar line), so a point on the
    /// bar line is `beatInBar == 1`. Sub-beat positions carry a fraction; see
    /// `TempoMap.parseTempoListPosition` for the division/tick assumption that
    /// produces it.
    let beatInBar: Double
    let bpm: Double
    /// True when this event is joined to the NEXT one by a tempo CURVE — a
    /// continuous ramp rather than a step.
    ///
    /// The Tempo List does not publish this. Probed live 2026-08-27 (Logic Pro
    /// 12.3.1): the table has exactly three columns — Position, Tempo, SMPTE
    /// Position — and the "Additional Info" checkbox adds none. So the reader
    /// always sets this false and a curve is integrated as a step; the amount
    /// that can cost is computed by `curveUncertaintySeconds` and named in the
    /// caller's warning rather than hidden. The field exists because Logic's
    /// curves are real: the integration below is exact for them the day a
    /// source that reports them arrives.
    let rampToNext: Bool

    init(bar: Int, beatInBar: Double = 1, bpm: Double, rampToNext: Bool = false) {
        self.bar = bar
        self.beatInBar = beatInBar
        self.bpm = bpm
        self.rampToNext = rampToNext
    }
}

/// A project's tempo map: the tempo events in musical order, with exact
/// bars→seconds integration over them.
///
/// The meter is a PARAMETER of every conversion, not part of the map: Logic's
/// signature changes live in their own list (the Signature tab of the same List
/// Editors), which this type deliberately does not model. The constant-meter
/// assumption that has always been in this server's bar math therefore stays,
/// and stays documented — a project whose METER changes mid-song still gets bar
/// boundaries computed from one beats-per-bar.
///
/// Anchor: bar 1 beat 1 = 0 seconds, the same anchor `barRangeSeconds` has
/// always used, because freeze/render files start at project start.
struct TempoMap: Equatable, Codable {
    /// Where the map came from. Only `.tempoList` is a READ map; the other is a
    /// single tempo reading wearing this type's clothes, and callers that
    /// upgrade their behavior on "the map is known" must check this.
    enum Source: String, Equatable, Codable {
        /// Read row by row out of Logic's Tempo List (List Editors > Tempo).
        case tempoList
        /// Built from one control-bar tempo reading — i.e. the pre-map
        /// behavior, expressed as a one-event map. NOT evidence of anything
        /// about the project's real tempo track.
        case singleReading
    }

    /// Sorted by musical position, never empty, every BPM > 0.
    let events: [TempoEvent]
    let source: Source
    /// True when at least one event sits off a beat, so the division/tick
    /// assumption in `parseTempoListPosition` actually mattered.
    let subBeatPositions: Bool

    init?(events: [TempoEvent], source: Source, subBeatPositions: Bool = false) {
        guard !events.isEmpty, events.allSatisfy({ $0.bpm > 0 && $0.bar >= 1 }) else { return nil }
        self.events = events.sorted { ($0.bar, $0.beatInBar) < ($1.bar, $1.beatInBar) }
        self.source = source
        self.subBeatPositions = subBeatPositions
    }

    /// The one-event map that reproduces the constant-tempo formula exactly.
    static func constant(_ bpm: Double) -> TempoMap? {
        TempoMap(events: [TempoEvent(bar: 1, bpm: bpm)], source: .singleReading)
    }

    /// Do all the events agree, within the same epsilon the two-point sample
    /// uses? A one-event map is constant by construction.
    var isConstant: Bool {
        guard let first = events.first else { return true }
        return events.allSatisfy { abs($0.bpm - first.bpm) < tempoSampleEpsilonBPM }
    }

    /// The distinct tempos in the map, in position order, for result payloads.
    var tempos: [Double] { events.map(\.bpm) }

    /// Could this map produce `bpm` as the tempo at some position? The cheap
    /// staleness check for a cached map: the control bar publishes the tempo at
    /// the playhead for free (no motion, no pane), and a tempo this map cannot
    /// account for proves the map is out of date.
    ///
    /// Meter-free on purpose — it asks "is this one of my tempos?", not "is this
    /// my tempo at bar N?", so it needs no beats-per-bar and cannot be fooled by
    /// a meter this server does not read. It catches an EDITED tempo value; it
    /// cannot catch a new point whose tempo equals one already in the map, or a
    /// point moved to another bar. Those need a re-read, which is what a tempo
    /// write and a non-Keep recording already force.
    func couldProduceTempo(_ bpm: Double) -> Bool {
        if events.contains(where: { abs($0.bpm - bpm) <= tempoSampleEpsilonBPM }) { return true }
        // Inside a ramp the tempo passes through every value between its ends.
        for (index, event) in events.enumerated() where event.rampToNext && index + 1 < events.count {
            let low = min(event.bpm, events[index + 1].bpm) - tempoSampleEpsilonBPM
            let high = max(event.bpm, events[index + 1].bpm) + tempoSampleEpsilonBPM
            if bpm >= low && bpm <= high { return true }
        }
        return false
    }

    /// Beats from bar 1 beat 1 (which is 0) to an event's position.
    private func beatOffset(_ event: TempoEvent, beatsPerBar: Double) -> Double {
        Double(event.bar - 1) * beatsPerBar + (event.beatInBar - 1)
    }

    /// Beats from bar 1 beat 1 to `bar`'s bar line.
    static func beatOffset(bar: Int, beatsPerBar: Double) -> Double {
        Double(bar - 1) * beatsPerBar
    }

    // MARK: Integration

    /// Seconds from project start to a position given in beats from project
    /// start. This is the primitive everything else here is built on.
    ///
    /// Exact, not subdivided: a step segment is `beats x 60 / BPM`, and a linear
    /// BPM ramp integrates to a logarithm (`60/k x ln(b1/b0)`), which is the
    /// closed form of ∫ 60/BPM(beat) d(beat) when BPM is linear in beats. There
    /// is therefore no error bound to document for the math itself — only for
    /// what the SOURCE could not tell us (see `curveUncertaintySeconds`).
    func seconds(atBeatOffset beats: Double, beatsPerBar: Double) -> Double {
        guard beats > 0, beatsPerBar > 0 else { return 0 }
        // One event: reproduce the constant-tempo arithmetic exactly.
        if events.count == 1 { return beats * 60.0 / events[0].bpm }
        var total = 0.0
        let offsets = events.map { max(beatOffset($0, beatsPerBar: beatsPerBar), 0) }
        // A map whose first event is not at bar 1 (Logic always puts one there,
        // but a partial read must not invent seconds): the stretch before it is
        // carried at that first event's tempo.
        if offsets[0] > 0 {
            total += min(beats, offsets[0]) * 60.0 / events[0].bpm
            if beats <= offsets[0] { return total }
        }
        for index in events.indices {
            let segmentStart = offsets[index]
            if segmentStart >= beats { break }
            let segmentEnd = index + 1 < events.count
                ? max(offsets[index + 1], segmentStart)
                : Double.infinity
            let target = min(segmentEnd, beats)
            let span = target - segmentStart
            if span <= 0 { continue }
            if events[index].rampToNext, segmentEnd.isFinite, segmentEnd > segmentStart,
               abs(events[index + 1].bpm - events[index].bpm) > 1e-9 {
                // BPM linear in beats: b(u) = b0 + k*u, so the elapsed time is
                // ∫ 60/b(u) du = (60/k) ln(b(span)/b0) — exact, no subdivision.
                let k = (events[index + 1].bpm - events[index].bpm) / (segmentEnd - segmentStart)
                let b0 = events[index].bpm
                total += (60.0 / k) * log((b0 + k * span) / b0)
            } else {
                total += span * 60.0 / events[index].bpm
            }
            if target >= beats { break }
        }
        return total
    }

    /// The tempo in force at a beat offset — what a per-beat budget or a
    /// convergence lead needs when "the tempo" is no longer one number.
    func bpm(atBeatOffset beats: Double, beatsPerBar: Double) -> Double {
        var current = events[0].bpm
        for (index, event) in events.enumerated() {
            let start = beatOffset(event, beatsPerBar: beatsPerBar)
            if start > beats { break }
            current = event.bpm
            if event.rampToNext, index + 1 < events.count {
                let next = events[index + 1]
                let end = beatOffset(next, beatsPerBar: beatsPerBar)
                if beats < end, end > start {
                    let t = (beats - start) / (end - start)
                    current = event.bpm + (next.bpm - event.bpm) * t
                }
            }
        }
        return current
    }

    /// Bar boundaries in seconds, the shape `barRangeSeconds` hands its callers.
    ///
    /// A ONE-EVENT map takes the shipped constant-tempo expression verbatim,
    /// operation order included — `(bar - 1) x (beats x 60 / BPM)`, not
    /// `((bar - 1) x beats) x 60 / BPM`. Those differ in the last bit of a
    /// Double for some tempos, and constant-tempo projects are the common case:
    /// a boundary that moved by a float's last bit would be a silent change to
    /// every freeze slice this server has ever cut.
    func rangeSeconds(
        startBar: Int, endBar: Int, beatsPerBar: Double
    ) -> (start: Double, end: Double) {
        if events.count == 1 {
            let secondsPerBar = beatsPerBar * 60.0 / events[0].bpm
            return (Double(startBar - 1) * secondsPerBar, Double(endBar - 1) * secondsPerBar)
        }
        return (
            seconds(
                atBeatOffset: TempoMap.beatOffset(bar: startBar, beatsPerBar: beatsPerBar),
                beatsPerBar: beatsPerBar
            ),
            seconds(
                atBeatOffset: TempoMap.beatOffset(bar: endBar, beatsPerBar: beatsPerBar),
                beatsPerBar: beatsPerBar
            )
        )
    }

    /// How much a CURVE the Tempo List could not report would move this range's
    /// boundaries: the difference between integrating every adjacent pair as a
    /// step (what the read map says) and as a linear ramp (the other thing Logic
    /// can hold between the same two points).
    ///
    /// Zero for a constant map, and zero when every pair of adjacent points that
    /// differ starts after `endBar`. NOT zero merely because no tempo change
    /// falls between `startBar` and `endBar`: these boundaries are measured from
    /// PROJECT START, so a curve anywhere earlier shifts them — a range inside a
    /// segment whose endpoints differ is inside the curve, and a range after one
    /// is displaced by the whole of it. That is the honest number a warning
    /// should carry, and it is why this is computed rather than guessed.
    func curveUncertaintySeconds(
        startBar: Int, endBar: Int, beatsPerBar: Double
    ) -> Double {
        guard events.count > 1 else { return 0 }
        let ramped = TempoMap(
            events: events.enumerated().map { index, event in
                TempoEvent(
                    bar: event.bar, beatInBar: event.beatInBar, bpm: event.bpm,
                    rampToNext: index + 1 < events.count
                )
            },
            source: source,
            subBeatPositions: subBeatPositions
        )
        guard let ramped else { return 0 }
        let steps = rangeSeconds(startBar: startBar, endBar: endBar, beatsPerBar: beatsPerBar)
        let curves = ramped.rangeSeconds(startBar: startBar, endBar: endBar, beatsPerBar: beatsPerBar)
        return max(abs(curves.start - steps.start), abs(curves.end - steps.end))
    }

    // MARK: Tempo List row parsing (pure; fed by AXTempoList)

    /// Logic's Position cell text: `"1 1 1 1 "` — bar, beat, division, tick,
    /// space separated, every field 1-based (verified live 2026-08-27).
    ///
    /// Division and tick are converted with Logic's defaults: the division is a
    /// 1/16 note (4 per quarter) and there are 240 ticks per division (Logic's
    /// 960 ppq). Both are project settings this server does not read, so the
    /// conversion is an ASSUMPTION — but only for a point that is off the beat:
    /// division 1 / tick 1 (every point on a beat, which is where tempo changes
    /// normally sit) is exact regardless.
    static func parseTempoListPosition(_ raw: String) -> (bar: Int, beatInBar: Double, offBeat: Bool)? {
        let fields = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let bar = fields.first.flatMap(Int.init), bar >= 1 else { return nil }
        let beat = fields.count > 1 ? (Int(fields[1]) ?? 1) : 1
        let division = fields.count > 2 ? (Int(fields[2]) ?? 1) : 1
        let tick = fields.count > 3 ? (Int(fields[3]) ?? 1) : 1
        guard beat >= 1, division >= 1, tick >= 1 else { return nil }
        let fraction = Double(division - 1) / 4.0 + Double(tick - 1) / 960.0
        return (bar, Double(beat) + fraction, division > 1 || tick > 1)
    }

    /// Logic's Tempo cell text: `"120,0000"` in a Swedish locale, `"120.0000"`
    /// in an English one (the comma is what the live project actually
    /// published). Both are accepted, and no thousands separator is possible in
    /// a BPM.
    static func parseTempoListBPM(_ raw: String) -> Double? {
        let cleaned = raw
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(cleaned), value > 0, value < 1000 else { return nil }
        return value
    }

    /// Logic's "Number of Items" text: `"1 Event"` / `"7 Events"`. This is the
    /// cross-check that makes a truncated read detectable — an AX table inside a
    /// scroll area may publish only the rows it has realised, and a map missing
    /// its later events would integrate CONFIDENTLY WRONG. Compare this against
    /// the row count and refuse the map on a mismatch.
    static func parseTempoListItemCount(_ raw: String) -> Int? {
        let digits = raw.prefix(while: { $0.isNumber || $0 == " " })
            .trimmingCharacters(in: .whitespaces)
        return Int(digits)
    }
}
