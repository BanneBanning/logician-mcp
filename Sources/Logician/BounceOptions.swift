import Foundation

/// G53: the value vocabulary of Logic's bounce dialog, read off the real
/// dialog on 2026-08-28 by opening every pop-up and enumerating its items.
///
/// These lists are OBSERVATIONS, not guesses — which is why they are exact
/// strings including Logic's own spelling of `POW-r #2 (Noise Shaping)`. They
/// serve two purposes: the caller's friendly value ("48k", "24 bit") is mapped
/// onto the menu title that has to be pressed, and a value that maps onto
/// nothing is refused with the real list rather than pressed at random.
enum BounceFormat {
    /// The `File Type:` pop-up (Uncompressed destination).
    static let fileTypes = ["AIFF", "WAVE", "CAF"]
    /// `Bit Depth:`.
    static let bitDepths = ["8-bit", "16-bit", "24-bit", "32-bit float"]
    /// `Sample Rate:`.
    static let sampleRates = [
        "11.025 kHz", "12 kHz", "22.05 kHz", "24 kHz", "32 kHz", "44.1 kHz",
        "48 kHz", "64 kHz", "88.2 kHz", "96 kHz", "176.4 kHz", "192 kHz"
    ]
    /// `Dithering:` — the separators in the real menu are dropped.
    static let ditherings = [
        "None", "POW-r #1 (Dithering)", "POW-r #2 (Noise Shaping)",
        "POW-r #3 (Noise Shaping)", "UV22HR"
    ]
    /// `Normalize:` — on the bounce dialog AND on the bounce-in-place sheet.
    static let normalizeModes = ["Off", "Overload Protection Only", "On"]
    /// `Format:` (interleaving), listed for completeness; not exposed as an
    /// argument, because a Split file breaks every reader downstream of this
    /// server (the metrics parser included).
    static let interleaving = ["Split", "Interleaved"]

    /// Maps what a caller wrote onto the exact menu title to press.
    ///
    /// Three steps, each one only accepted when it is UNAMBIGUOUS: an exact
    /// match ignoring case and punctuation ("32-bit float" == "32 bit
    /// float"), a unique prefix ("POW-r #1" for the full name, "48" for
    /// "48 kHz"), and a numeric reading for sample rates written in Hz
    /// (48000 -> "48 kHz"). Anything else is nil, and the caller refuses with
    /// the list.
    static func canonical(_ raw: String, in options: [String]) -> String? {
        func key(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let wanted = key(raw)
        guard !wanted.isEmpty else { return nil }
        if let exact = options.first(where: { key($0) == wanted }) { return exact }
        let prefixed = options.filter { key($0).hasPrefix(wanted) }
        if prefixed.count == 1 { return prefixed[0] }
        // "48000", "48000 Hz", "96000hz" — a rate written in Hz.
        let digits = raw.filter { $0.isNumber || $0 == "." }
        if let hertz = Double(digits), hertz >= 1000 {
            let kilohertz = hertz / 1000
            let text = kilohertz == kilohertz.rounded()
                ? String(Int(kilohertz))
                : String(kilohertz)
            let matches = options.filter {
                key($0).contains("khz") && key($0).hasPrefix(key(text))
            }
            if matches.count == 1 { return matches[0] }
        }
        return nil
    }

    /// The refusal text for a value that maps onto nothing.
    static func rejection(_ raw: String, label: String, options: [String]) -> String {
        "'\(raw)' is not one of \(label)'s values in Logic's bounce dialog. "
            + "Nothing was bounced. Available: \(options.joined(separator: ", "))."
    }
}

/// The bounce dialog's Start/End position fields, as the DISPLAY publishes
/// them — `"63\t3\t1\t1"` is bar 63, beat 3, division 1, tick 1.
///
/// Why the display and not the raw tick value (measured 2026-08-28): the field
/// is one `AXSlider` per digit and every one of them mirrors the same absolute
/// tick count, and that count is meter-blind. Stepping it DOWN one press at a
/// time moves one of LOGIC's bars, which is 5 beats' worth of ticks inside a
/// 5/4 stretch and 4 beats' worth outside it — so a target computed as
/// `minimum + (bar - 1) x oneFourFourBar` is simply a different number from
/// where the field lands, and a converger comparing the two steps past its
/// target forever. The bar/beat text is Logic's own answer to "where is this
/// field", and it is the only honest convergence test.
struct BouncePosition: Equatable {
    let bar: Int
    let beat: Int
    let division: Int
    let tick: Int

    /// True when the position sits exactly on the bar line.
    var isBarStart: Bool { beat == 1 && division == 1 && tick == 1 }

    var text: String { "\(bar) \(beat) \(division) \(tick)" }

    /// Parses Logic's tab-separated position text. Anything that is not four
    /// numbers is nil — never a guess, because a misread position bounces the
    /// wrong music.
    static func parse(_ raw: String) -> BouncePosition? {
        let parts = raw
            .components(separatedBy: CharacterSet(charactersIn: "\t "))
            .filter { !$0.isEmpty }
            .compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        return BouncePosition(bar: parts[0], beat: parts[1], division: parts[2], tick: parts[3])
    }
}

/// Which of the two position fields to write first.
///
/// The two fields describe one range, and a write that would momentarily
/// INVERT it (end before start) is the one Logic can clamp. Moving the range
/// later in time therefore writes the END first (it opens the range to the
/// right before the start follows), and every other case writes the START
/// first. The rule is stated on the target/current pair rather than on
/// "later/earlier" so that overlapping moves — the common case — take the
/// branch that cannot invert either.
enum BounceWriteOrder: String, Equatable {
    case endFirst
    case startFirst

    static func choose(currentEnd: Int, targetStart: Int) -> BounceWriteOrder {
        targetStart >= currentEnd ? .endFirst : .startFirst
    }
}

/// One region as the arrangement map sees it — the unit `logic_bounce_in_place`
/// compares before and after to prove that something was printed.
struct ArrangementRegion: Equatable {
    let track: String
    let name: String
    let start: Int
    let end: Int

    init(track: String, name: String, start: Int, end: Int) {
        self.track = track
        self.name = name
        self.start = start
        self.end = end
    }

    /// From the tuple `flatRegionMap()` produces.
    init(_ row: (track: String, name: String, start: Int, end: Int)) {
        self.init(track: row.track, name: row.name, start: row.start, end: row.end)
    }
}

/// Which region a bounce-in-place actually printed.
///
/// THE TRAP (measured 2026-08-28). Logic's default `Source: Mute` renames the
/// SOURCE region in the Accessibility tree — `Crash` becomes `Crash, muted` —
/// so a naive before/after diff finds two "new" regions and the source is the
/// first of them. The first live run reported `verified: true` with the muted
/// SOURCE as the printed region while the real print sat on a brand-new track
/// one row below. A wrong region reported as a verified success is the failure
/// mode this repo cares most about, so the comparison ignores the mute suffix
/// and the choice prefers the name the caller asked for.
enum PrintedRegion {

    /// Logic's Accessibility suffix for a muted region.
    static let mutedSuffix = ", muted"

    static func canonicalName(_ name: String) -> String {
        name.hasSuffix(mutedSuffix) ? String(name.dropLast(mutedSuffix.count)) : name
    }

    private static func key(_ region: ArrangementRegion) -> String {
        "\(region.track)\u{1}\(canonicalName(region.name))\u{1}\(region.start)\u{1}\(region.end)"
    }

    /// The region the print added, or nil when nothing new appeared.
    static func find(
        before: [ArrangementRegion], after: [ArrangementRegion], requestedName: String?
    ) -> ArrangementRegion? {
        let known = Set(before.map(key))
        let candidates = after.filter { !known.contains(key($0)) }
        guard !candidates.isEmpty else { return nil }
        if let requestedName, !requestedName.isEmpty {
            if let exact = candidates.first(where: {
                canonicalName($0.name).caseInsensitiveCompare(requestedName) == .orderedSame
            }) { return exact }
            if let prefixed = candidates.first(where: {
                canonicalName($0.name).lowercased().hasPrefix(requestedName.lowercased())
            }) { return prefixed }
        }
        // Logic's own default names the print "<region>_bip".
        if let bip = candidates.first(where: { canonicalName($0.name).hasSuffix("_bip") }) {
            return bip
        }
        // Otherwise the print is the one on a track that had no regions before
        // (destination "New Track"), and only then "the first new thing".
        let knownTracks = Set(before.map(\.track))
        return candidates.first { !knownTracks.contains($0.track) } ?? candidates.first
    }
}
