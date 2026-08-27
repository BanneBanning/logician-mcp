import Foundation

/// Pure reasoning about the MCU bank map: which strip a requested name refers
/// to, given nothing but the LCD name rows Logic paints per bank. No bridge,
/// no Logic, no I/O — every rule in here is unit-tested, because a wrong answer
/// here is a write on the wrong channel (which has happened: FINDINGS.md,
/// 2026-08-25 v0.31.0, plugins landed on Stereo Out by accident).
extension MCUController {

    /// One strip, addressed the only way the surface can address one: bank
    /// position plus strip index inside that bank.
    struct BankMatch: Equatable {
        let bank: Int
        let channel: Int
    }

    /// How the resolution of a name ended. `findChannel` returns `Int?`
    /// because its callers answer nil with "try the other control plane", but
    /// "no such strip" and "six strips match" need different words in an error
    /// message — so the reason is recorded alongside.
    enum ChannelResolution: Equatable {
        case resolved(Int)
        /// No strip's LCD cell is a plausible abbreviation of the name.
        case notFound(cells: [String])
        /// Several DIFFERENT strips match (duplicate track names, or two names
        /// that abbreviate to the same six characters).
        case ambiguous(cells: [String])
        /// The surface could not be read or banked at all (bridge down, the
        /// pan-names view unreachable, a bank that never settled).
        case unavailable(reason: String)
    }

    /// Diagnostic only: the reason the most recent `findChannel` gave the
    /// answer it did, so a caller that turns nil into an error can name what
    /// was observed. Never a routing input — the routing value is the return
    /// value. (Single-threaded server loop, like `hotPluginView`.)
    nonisolated(unsafe) static var lastChannelResolution: ChannelResolution = .unavailable(reason: "no resolution attempted yet")

    /// Characters Logic fills a channel-name cell with before it starts
    /// dropping any. The LCD row is 8 × 7 characters, but the eighth character
    /// is the separator: every observed abbreviation of a longer name is
    /// exactly 6 (`Lofi Pad` → `LofPad`, `Acke Slagverk` → `AckSlg`,
    /// `Audio 8` → `Audio8`, `Stereo Out` → `St Out`), and names of 6 or fewer
    /// characters are painted whole, spaces included (`Inst 2`, `Aux 1`).
    /// Measured across 25 strips of the reference project, 2026-08-27.
    static let lcdNameCellWidth = 6

    /// `lcdNameMatches` accepts any ordered subsequence, which is what recovers
    /// Logic's abbreviations — and also what lets a cell match a name it has
    /// nothing to do with: asking for `Stereo Out` matches a track literally
    /// named `Set` (s, e, t all occur in that order). On a project without a
    /// Stereo Out that false positive would be the *only* match, and the write
    /// would land on `Set`.
    ///
    /// The tightening is Logic's own behaviour: it fills the cell before it
    /// drops anything, so a cell far shorter than the cell width cannot be an
    /// abbreviation of a long name. A cell at least as long as the name is not
    /// abbreviated at all and passes on the subsequence match alone.
    static func lcdAbbreviationPlausible(track: String, lcd: String) -> Bool {
        guard lcdNameMatches(track: track, lcd: lcd) else { return false }
        let cell = lcd.trimmingCharacters(in: .whitespaces)
        let name = track.trimmingCharacters(in: .whitespaces)
        if cell.count >= name.count { return true }
        return cell.count >= min(name.count, lcdNameCellWidth)
    }

    /// How many strips the rightmost bank shares with the bank before it.
    ///
    /// Logic's rightmost bank CLAMPS: with a strip count that is not a multiple
    /// of 8 it shows the *last* 8 strips, so it re-shows the tail of the
    /// previous bank shifted left. Returns that shift (1...7), or nil when the
    /// two banks are disjoint (a strip count that divides by 8).
    static func clampOverlap(previous: [String], last: [String]) -> Int? {
        guard previous.count == 8, last.count == 8 else { return nil }
        for shift in 1..<8 where Array(last[0..<(8 - shift)]) == Array(previous[shift..<8]) {
            return shift
        }
        return nil
    }

    /// Collapses matches that the clamped rightmost bank reports twice.
    ///
    /// This is what kept the whole master chain unaddressable: `Stereo Out`,
    /// `Aux 1-3`, the buses and the last audio tracks all appear in the last
    /// two banks of a project whose strip count is not a multiple of 8, so a
    /// full scan counted two matches, `findChannel` read that as "ambiguous"
    /// and returned nil — for a name that is in fact perfectly unique.
    /// The earliest occurrence is kept: it addresses the same strip and its
    /// bank is not the clamped one.
    static func dedupedMatches(_ matches: [BankMatch], bankTops: [String]) -> [BankMatch] {
        guard bankTops.count >= 2, matches.count >= 2 else { return matches }
        let lastBank = bankTops.count - 1
        guard let shift = clampOverlap(
            previous: lcdFields(bankTops[lastBank - 1]),
            last: lcdFields(bankTops[lastBank])
        ) else { return matches }
        return matches.filter { match in
            guard match.bank == lastBank, match.channel + shift <= 7 else { return true }
            let twin = BankMatch(bank: lastBank - 1, channel: match.channel + shift)
            return !matches.contains(twin)
        }
    }

    /// The full name → strip pipeline over a bank map: subsequence matching to
    /// recover Logic's abbreviations, the plausibility filter to reject cells
    /// that merely happen to be a subsequence, and the clamp de-duplication.
    static func channelMatches(name: String, bankTops: [String]) -> [BankMatch] {
        var matches: [BankMatch] = []
        for (bank, top) in bankTops.enumerated() {
            for (channel, cell) in lcdFields(top).enumerated()
            where lcdAbbreviationPlausible(track: name, lcd: cell) {
                matches.append(BankMatch(bank: bank, channel: channel))
            }
        }
        return dedupedMatches(matches, bankTops: bankTops)
    }

    /// Every non-empty cell in a bank map, for "not found" messages that name
    /// what the surface actually shows.
    static func bankMapCells(_ bankTops: [String]) -> [String] {
        var seen: [String] = []
        for top in bankTops {
            for cell in lcdFields(top) where !cell.isEmpty && cell != "-" && !seen.contains(cell) {
                seen.append(cell)
            }
        }
        return seen
    }
}
