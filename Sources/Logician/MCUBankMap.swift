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
        /// that abbreviate to the same six characters), and the AX track list
        /// could not settle which one — no numbers to offer at all, or the
        /// candidate count does not line up with the header count (a
        /// headerless strip in the collision, or a stale duplicate cell that
        /// did not resolve on retry; see `isStaleDuplicateCellSuspect`).
        case ambiguous(cells: [String])
        /// Several DIFFERENT strips match and the AX track list carries the
        /// collision itself (that many headers share the name) — the numbers
        /// are the way out, the same shape `track_info` refuses a duplicate
        /// header name with.
        case ambiguousNumbered(cells: [String], numbers: [Int])
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

    // MARK: - Tie-breaking a multi-way LCD-name match by AX track number

    /// One LCD-name match, carrying the live cell text a tie-break needs to
    /// tell a control-press banner apart from a real second strip.
    struct ChannelCandidate: Equatable {
        let match: BankMatch
        let cell: String
    }

    /// How a multi-way LCD-name collision was settled once the AX track
    /// list's own numbering is brought in.
    enum ChannelTieBreak: Equatable {
        /// Positionally correlated with a header — the requested
        /// `track_number`, or the collision's only header when none was
        /// given.
        case resolved(BankMatch)
        /// The AX track list itself carries the collision (that many headers
        /// share the name): the numbers are the way out, same as
        /// `track_info`'s own duplicate-name refusal.
        case ambiguousNumbered(numbers: [Int])
        /// Could not be correlated at all — no headers share this name, or
        /// the header count disagrees with the candidate count (a headerless
        /// strip in the mix, or a stale duplicate cell). The caller's plain
        /// `cells`-only ambiguity stands.
        case unresolved
    }

    /// Settles a multi-way LCD-name collision by the AX track list's own
    /// numbering (FIX_SPEC 2026-09-03: `resolveChannel`'s LCD-name scan had no
    /// row numbers to compare against, so no `track_number` argument could
    /// break a tie between two strips that legitimately abbreviate alike —
    /// the sandbox's two `Ivan Vocals` rows, 21 and 22, both read `IvnVoc`).
    ///
    /// A banner is dropped BEFORE anything is counted: it is the echo of a
    /// press this process (or another one sharing the mirror) made a moment
    /// ago, painted over a strip's name cell, never a second strip that
    /// happens to be called the same thing — the same reading
    /// `bankedAtMatch` already gives a banner cell.
    ///
    /// What is left is correlated ORDINALLY, never by content: the Nth header
    /// carrying this name (by track number, ascending) is the Nth candidate
    /// (by project position — bank then channel, ascending), which is the
    /// same order a bank scan always visits strips in and `logic_list_strips`
    /// reports them in. That correlation is only trusted when the two counts
    /// AGREE. When they do not — a headerless strip sharing the name, or the
    /// same physical strip's row read twice — this refuses to guess and hands
    /// back `.unresolved`, which is a DIFFERENT shape from a genuine
    /// duplicate-header collision and the one `isStaleDuplicateCellSuspect`
    /// exists to recognise.
    static func tieBreakChannelMatches(
        _ candidates: [ChannelCandidate],
        trackName: String,
        headers: [TrackRowAddressing.Row],
        trackNumber: Int?
    ) -> ChannelTieBreak {
        let real = candidates.filter { !isControlBannerCell($0.cell) }
        guard real.count > 1 else {
            return real.first.map { .resolved($0.match) } ?? .unresolved
        }
        let sameName = headers
            .filter { $0.name.caseInsensitiveCompare(trackName) == .orderedSame }
            .sorted { $0.number < $1.number }
        guard sameName.count == real.count else { return .unresolved }
        let ordered = real.map(\.match).sorted { ($0.bank, $0.channel) < ($1.bank, $1.channel) }
        guard let trackNumber, let index = sameName.firstIndex(where: { $0.number == trackNumber }) else {
            return .ambiguousNumbered(numbers: sameName.map(\.number))
        }
        return .resolved(ordered[index])
    }

    /// Is a multi-way match the signature of the SAME physical strip's row
    /// being read twice — a repaint racing the scan, or a second bridge
    /// reader sharing the mirror — rather than of two real strips?
    ///
    /// Observed live 2026-09-03: `logic_read_automation {track_name: "Audio
    /// 9"}` died once with *"'Audio 9' matches 2 control-surface strips
    /// (Audio9, Audio9)"* and succeeded on the immediate retry. Exactly one AX
    /// header is named `Audio 9`, so this shape — a single header, several
    /// BYTE-IDENTICAL live cells — cannot be a real second strip: two
    /// distinct strips print two distinct cells (their bank position differs,
    /// but so does everything else about them; two GENUINELY duplicate names
    /// still occupy different neighbouring cells and only coincide in the
    /// text). A coincidental collision between two DIFFERENT names that
    /// abbreviate alike (`St Out` / `StOutr`) is not this shape either — the
    /// cells differ — and is not retried.
    static func isStaleDuplicateCellSuspect(cells: [String], sameNameHeaderCount: Int) -> Bool {
        guard sameNameHeaderCount == 1, cells.count > 1 else { return false }
        return Set(cells).count == 1
    }

    /// The refusal a `findChannel` miss deserves for a caller that has no AX
    /// two-plane story of its own — the automation record path, which is
    /// MCU-only by nature (Latch and the vpot chase have no header-plane
    /// equivalent) and used to collapse every miss into one generic "not
    /// found in the bank view", hiding an ambiguous match behind the same
    /// words as a genuinely absent one. `ambiguousNumbered` is what makes
    /// `track_number` an honest way out here rather than a silently ignored
    /// argument.
    static func automationChannelError(trackName: String, resolution: ChannelResolution) -> LogicianError {
        switch resolution {
        case .resolved:
            // `findChannel` returned nil, so this cannot be the resolution it
            // recorded — answer honestly rather than by guessing.
            return .trackNotExposed(
                requested: "MCU channel for '\(trackName)'",
                exposed: "the control surface would not name the strip it had just resolved"
            )
        case .ambiguousNumbered(_, let numbers):
            return .trackAmbiguous(trackName, numbers: numbers)
        case .ambiguous(let cells):
            return .stripAmbiguous(name: trackName, cells: cells)
        case .notFound(let cells):
            return .stripNotFound(name: trackName, tracks: [], cells: cells)
        case .unavailable(let reason):
            return .trackNotExposed(
                requested: "MCU channel for '\(trackName)'",
                exposed: "not found in the bank view (\(reason))"
            )
        }
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
    /// A SECOND case forced the rewrite below: adding `Low Pass Filter`
    /// succeeded and the cross-check failed it too, because Accessibility
    /// calls the result `LoPass` — and the fix shipped for `ParEQ`, a bare
    /// "first three characters match verbatim" guard, rejects it. `Low`
    /// abbreviates to `Lo` by dropping the trailing CONSONANT `w`, so `LoPass`
    /// and `Low Pass Filter` disagree in their third character (`p` vs `w`)
    /// even though the abbreviation is exactly as legitimate as `ParEQ`'s.
    /// The same shape breaks `Overdrive` → `Ovrdr` (drops the interior VOWEL
    /// `e`, third characters `r` vs `e`).
    ///
    /// So the guard is not "do the first three characters match" but "is `ax`
    /// obtainable from `want`, word by word, the way Logic actually
    /// truncates a name onto a 6-character cell": walk `want`'s words in
    /// order; a word, once entered, MUST contribute its own first letter
    /// verbatim (Logic never drops that — `Overdrive` keeps its leading `O`
    /// even though it is a vowel); after that anchor, each further letter of
    /// the word is either kept, or — if it is a VOWEL — dropped, or the word
    /// is closed early and the walk moves to the next one (`Comprs` closes
    /// `Compressor` after its second `s`, dropping the trailing `or`
    /// entirely; `LoPass` closes `Low` after two letters and moves straight
    /// into `Pass`). A trailing word that is never entered (`Filter`, in `Low
    /// Pass Filter`) is simply never reached once `ax` runs out.
    ///
    /// Consonants can never be skipped within a word that has been entered,
    /// and a word can never be entered without its own first letter — both
    /// are what keep this from doing what a bare subsequence test would:
    /// `Gain` cannot be produced from `Guitar Amp Pro` this way (entering
    /// `Guitar` forces its `t` to survive if any letter past it is kept, and
    /// `Gain` has no `t`; entering `Amp` or `Pro` instead needs their own
    /// first letter, `a` or `p`, to be `ax`'s FIRST character, and it isn't).
    /// The same rule is the anti-collision guard the FIX_SPEC asked for: two
    /// real plugins that share every word but their first
    /// (`Bass Amp Designer` / `Guitar Amp Designer`, both plausibly `AmpDes`)
    /// can never BOTH satisfy this test against the same `ax`, because
    /// neither name's first word can be skipped to reach the shared tail —
    /// a collision degrades to `false` on both sides, which is what sends the
    /// caller back to the slot-index proof instead of a wrong `verified:
    /// true` (`testAxNamesPluginCollisionDegradesSafely`).
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
        return axNameDecomposes(ax, from: want)
    }

    /// The word-by-word walk `axNamesPlugin` runs, isolated so it can be
    /// unit-tested against every abbreviation shape on its own. See
    /// `axNamesPlugin`'s doc comment for the rule this implements and why it
    /// resists collisions between two real, similarly-abbreviated plugins.
    ///
    /// Memoized on (word, position-in-word, characters of `ax` consumed):
    /// each of the three axes is bounded by a plugin name's own length, so
    /// this stays a `O(names × ax.count)` table walk rather than the
    /// exponential blow-up a naive backtrack would risk on a long name.
    static func axNameDecomposes(_ ax: String, from want: String) -> Bool {
        let words = want.split(separator: " ").map(Array.init)
        let axChars = Array(ax.replacingOccurrences(of: " ", with: ""))
        guard !words.isEmpty, !axChars.isEmpty else { return false }
        let axCount = axChars.count

        func isVowel(_ c: Character) -> Bool { "aeiou".contains(c) }

        var memo: [Int: Bool] = [:]
        func key(_ word: Int, _ pos: Int, _ ai: Int) -> Int {
            (word * 64 + pos) * (axCount + 1) + ai
        }

        func walk(_ word: Int, _ pos: Int, _ ai: Int) -> Bool {
            if ai == axCount { return true }
            guard word < words.count else { return false }
            let w = words[word]
            if pos == w.count { return walk(word + 1, 0, ai) }
            let k = key(word, pos, ai)
            if let cached = memo[k] { return cached }
            let c = w[pos]
            var result = false
            if pos == 0 {
                // A word's own first letter is never dropped — the anchor
                // that both recovers Logic's abbreviations and refuses two
                // plugins whose SHARED tail collides.
                if c == axChars[ai], walk(word, 1, ai + 1) { result = true }
                // The one exception: a word with no LETTERS in it at all
                // (a bare model number — `ARP 2600 V3`'s `2600`) carries no
                // identity for Logic to abbreviate and is dropped whole,
                // never contributing a digit to the cell (`ARPV3`, not
                // `ARP2V3` or similar) — measured live 2026-09-02, the load
                // that worked and was reported `verification_failed` on a
                // `safety: .destructive` tool. This cannot reopen the
                // collision this anchor exists to close: two plugins whose
                // names differ only by which WORD they use still need that
                // word's own first LETTER to survive, and a digit-only word
                // never supplies one.
                if !result, !w.contains(where: { $0.isLetter }), walk(word + 1, 0, ai) { result = true }
            } else {
                if c == axChars[ai], walk(word, pos + 1, ai + 1) { result = true }
                if !result, isVowel(c), walk(word, pos + 1, ai) { result = true }
                if !result, walk(word + 1, 0, ai) { result = true }
            }
            memo[k] = result
            return result
        }
        return walk(0, 0, 0)
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
