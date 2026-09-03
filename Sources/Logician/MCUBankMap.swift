import Foundation
import LogicMCUBridge

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
    /// value. (Single-threaded server loop, like `hotEditView`.)
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
    /// `cellWidth` is how many characters were available to Logic for the
    /// abbreviation, and it is not always `lcdNameCellWidth`: a BYPASSED insert
    /// spends one of its six on the bypass marker, so `Overdrive` is painted
    /// `*Ovrdr` — five characters of name — and the six-character floor
    /// rejected it as implausible. Measured live 2026-09-02 on `Drum Synth
    /// Kit`, whose row is `-- | *Ovrdr | *Bitcr | Pedlba | *Envlp | *St-De |
    /// *PtVer | Cha EQ`: the two ENABLED cells passed the floor and all five
    /// bypassed ones failed it, so the strip check refused a list that agreed
    /// perfectly.
    static func lcdAbbreviationPlausible(
        track: String, lcd: String, cellWidth: Int = lcdNameCellWidth
    ) -> Bool {
        guard lcdNameMatches(track: track, lcd: lcd) else { return false }
        let cell = lcd.trimmingCharacters(in: .whitespaces)
        let name = track.trimmingCharacters(in: .whitespaces)
        if cell.count >= name.count { return true }
        return cell.count >= min(name.count, cellWidth)
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

    /// Whether the plugin-list view the surface is showing can belong to the
    /// strip Accessibility describes.
    ///
    /// The PL view names no channel — that is the whole reason
    /// `selectChannelVerified` exists — and the SELECT LED turned out not to
    /// be sufficient either: observed 2026-08-28 with the LED on strip 8
    /// (`Stereo Out`, confirmed on two banks) while the PL row read
    /// `Cha EQ | *PShft | Cha EQ | Comprs`, which is the track `Bas`. A
    /// SELECT press on a strip whose LED is ALREADY lit is a no-op, so
    /// re-selecting cannot recover it; selecting a neighbour and coming back
    /// does. A browser write in that state inserts into the wrong strip.
    ///
    /// So a write that depends on the PL view asks a third, independent
    /// question first: does the list the surface shows agree with the one
    /// Accessibility reads off the same strip's inspector? Slot ORDER is
    /// deliberately not compared — it is reversed on an output strip
    /// (FINDINGS 2026-08-27) — only the multiset of occupied names, each MCU
    /// cell being an abbreviation of some AX name.
    ///
    /// `nil` means "cannot be checked": Accessibility sees only the strips an
    /// inspector is showing, so `Master` and most auxes answer with nothing,
    /// and an unanswerable check must never fail a working operation. The
    /// caller reports the check as unavailable instead.
    static func pluginListAgreesWithAX(mcuCells: [String], axNames: [String]) -> Bool? {
        guard !axNames.isEmpty else { return nil }
        // A leading '*' is Logic's bypass marker, not part of the name — and it
        // costs the name one of the cell's six characters, which the width the
        // match is judged against has to know about (see
        // `lcdAbbreviationPlausible`).
        let occupied = mcuCells
            .map { raw -> (name: String, width: Int) in
                let marker = MCULCDStrings.bypassMarker
                let bypassed = raw.trimmingCharacters(in: .whitespaces).hasPrefix(marker)
                return (
                    raw.trimmingCharacters(in: CharacterSet(charactersIn: marker + " ")),
                    lcdNameCellWidth - (bypassed ? marker.count : 0)
                )
            }
            .filter { !$0.name.isEmpty && $0.name != MCULCDStrings.emptySlot }
        // Counts must match EXACTLY, and the caller is responsible for handing
        // in a comparable list: the AX channel strip publishes an occupied
        // INSTRUMENT slot in the same shape as an insert, and the MCU plug-in
        // list never shows it, so a raw `listInserts` reading of a software
        // instrument track carries one entry the surface cannot have. Compare
        // against `insertPluginNames`, which drops it.
        guard occupied.count == axNames.count else { return false }
        var remaining = axNames
        for cell in occupied {
            guard let index = remaining.firstIndex(where: {
                lcdAbbreviationPlausible(track: $0, lcd: cell.name, cellWidth: cell.width)
            }) else { return false }
            remaining.remove(at: index)
        }
        return true
    }

    /// Does an Accessibility insert name refer to the plugin that was asked
    /// for? Separate from `lcdAbbreviationPlausible`, which is calibrated for
    /// the surface's 6-character LCD grid and rejects anything shorter — a
    /// rule that is right for an LCD cell and wrong here, because Logic's own
    /// short names are not padded to any width.
    ///
    /// The case that forced this: adding `Parametric EQ` succeeded, and the
    /// cross-check then failed it, because Accessibility calls the result
    /// `ParEQ` and the old test was a two-way `hasPrefix` — neither
    /// "pareq".hasPrefix("parametric eq") nor the reverse is true. The write
    /// had landed correctly and the tool reported "it may have landed on
    /// another channel" and left it in place (observed 2026-08-31 on `Sweeps`).
    ///
    /// Deliberately not a bare subsequence test, which would let `Gain` match
    /// half the catalog: an abbreviation has to keep the first three
    /// characters and at least four in total. Loosening this cannot make a
    /// wrong-CHANNEL write pass — the strip is named by the caller and proven
    /// by the SELECT LED; at worst a right-channel write is confirmed by a
    /// sibling plugin with a confusingly similar name.
    static func axNamesPlugin(_ axName: String, requested: String) -> Bool {
        func normalize(_ raw: String) -> String {
            raw.replacingOccurrences(
                of: #"\s*\((?:[sm]/[sm]|[sm])\)\s*$"#, with: "", options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: MCULCDStrings.bypassMarker + " "))
            .lowercased()
        }
        let ax = normalize(axName), want = normalize(requested)
        guard !ax.isEmpty, !want.isEmpty else { return false }
        if ax == want || ax.hasPrefix(want) || want.hasPrefix(ax) { return true }
        guard ax.count >= 4, want.count > ax.count else { return false }
        guard ax.prefix(3) == want.prefix(3) else { return false }
        return lcdNameMatches(track: want, lcd: ax)
    }

    /// Every non-empty cell in a bank map, for "not found" messages that name
    /// what the surface actually shows.
    static func bankMapCells(_ bankTops: [String]) -> [String] {
        var seen: [String] = []
        for top in bankTops {
            for cell in lcdFields(top)
            where !cell.isEmpty && cell != MCULCDStrings.clearingCell && !seen.contains(cell) {
                seen.append(cell)
            }
        }
        return seen
    }
}
