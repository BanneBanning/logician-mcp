import Foundation

// MARK: - Which ROW, and which REGION on it

/// Which row a `(track_name, track_number)` pair names — the one rule, for the
/// track-header column and for the arrangement's region rows alike.
///
/// It used to be `resolveTrack`'s rule and nobody else's. The TRACK tools took
/// a `track_number`, cross-checked it against `track_name` and refused the
/// pair that disagreed; the REGION tools took no number at all and resolved
/// `track_name` with `rows.first(where:)` — the FIRST row of that name,
/// silently. That is exactly backwards for the project shape that makes
/// duplicate names normal: `logic_import_midi` names every track it creates
/// after whichever default patch Logic loaded, so an imported arrangement is a
/// stack of rows called `Studio Grand`, and the tools that edit the regions on
/// them were the ones that could not say which row they meant.
///
/// Pure, and shared, so both planes decide it the same way and a test can pin
/// the decision without Logic running.
enum TrackRowAddressing {

    /// One row, reduced to what addressing needs. The track-header column and
    /// the region walk publish different things; they agree on these two.
    struct Row: Equatable {
        let number: Int
        let name: String
    }

    /// What the pair names, or why it names nothing. Each case is a different
    /// refusal at the call site, because "there is no row 26", "row 26 is
    /// called something else" and "three rows are called that" send the caller
    /// somewhere different.
    enum Verdict: Equatable {
        /// The row's number.
        case resolved(number: Int)
        /// A `track_number` no rendered row carries.
        case numberNotFound(Int)
        /// No row of that name.
        case nameNotFound
        /// Several rows carry the name and no number was given, so the request
        /// names a set rather than a row. The numbers are the way out.
        case ambiguous(numbers: [Int])
        /// Both were given and they disagree. Nothing may be written on this
        /// verdict: a stale idea of the row is exactly what the number is for
        /// catching.
        case mismatch(number: Int, expected: String, actual: String)
    }

    /// - Parameter caseInsensitive: the region walk compares names the way
    ///   `selectRegion` always has (case-insensitively, because the name comes
    ///   out of Logic's own description sentence); the track-header path
    ///   compares exactly, as `resolveTrack` always has. Sharing the rule
    ///   changes neither behaviour.
    static func resolve(
        rows: [Row], name: String, number: Int?, caseInsensitive: Bool
    ) -> Verdict {
        func matches(_ row: Row) -> Bool {
            caseInsensitive
                ? row.name.caseInsensitiveCompare(name) == .orderedSame
                : row.name == name
        }
        if let number {
            guard let row = rows.first(where: { $0.number == number }) else {
                return .numberNotFound(number)
            }
            guard matches(row) else {
                return .mismatch(number: number, expected: name, actual: row.name)
            }
            return .resolved(number: row.number)
        }
        let hits = rows.filter(matches)
        guard let first = hits.first else { return .nameNotFound }
        guard hits.count == 1 else { return .ambiguous(numbers: hits.map(\.number)) }
        return .resolved(number: first.number)
    }

    /// The rows as a refusal prints them: `26: Crash`, numbered, because a
    /// caller who addressed a row by number needs the numbers back.
    static func rowSummary(_ rows: [Row]) -> String {
        rows.isEmpty
            ? "none rendered"
            : rows.map { "\($0.number): \($0.name)" }.joined(separator: ", ")
    }

    /// The number and the NAME out of a `Track 7 “Bass”` description — the one
    /// parse, for the track-header column and for the arrangement's region
    /// rows alike.
    ///
    /// **Why it is shared.** Logic appends the row's live STATE after the
    /// closing quote, and the two readers disagreed about whether that was
    /// part of the name. The header column's parse took the text BETWEEN the
    /// quotes and never saw it; `regionRows()` had its own parse that split on
    /// the opening quote and kept the TAIL, so with track 26 soloed the same
    /// row was `Crash` to `logic_list_tracks` and `Crash, solo` to
    /// `logic_list_regions`, and `resolveRegionRow` refused the caller's own
    /// reported name: *"Track 26 is named 'Crash, solo', not 'Crash'"* on
    /// `logic_copy_region`, `logic_delete_region` and `logic_select_region`
    /// alike (reproduced live 2026-09-03 on the pre-fix binary, 5 of 5 calls;
    /// the split profile hit it as four consecutive refusals whose reported
    /// `actual` alternated between the two spellings). One parse, so the two
    /// planes cannot disagree again.
    ///
    /// **Measured annotations** — live 2026-09-03, English Logic Pro 12.3.1,
    /// reference project, track 26 read through this walk with each state set
    /// and verified by `logic_track_info`:
    ///
    /// | state | row description | reads |
    /// |---|---|---|
    /// | plain | `Track 26 “Crash”` | 6/6 |
    /// | soloed | `Track 26 “Crash”, solo` | 3/3 |
    /// | muted | `Track 26 “Crash”, mute` | 2/2 |
    /// | record-armed | `Track 26 “Crash”` — **no annotation** | 2/2 |
    ///
    /// So the row carries the two states that silence a track and not the one
    /// that arms it; frozen and hidden were not tested. The suffix is `, mute`
    /// on the row (the REGION elements on a silenced track say `, muted`
    /// instead — a separate leak, on `parseRegion`'s name, still open).
    ///
    /// **The rule is STRUCTURAL, not a word list**: everything outside the
    /// quoted span is punctuation and state, whatever Logic writes there, so
    /// the annotations nobody has measured (frozen, hidden) and a LOCALIZED
    /// one are dropped by the same rule with no table to update — there is
    /// deliberately no list of English state words here to fall off. What does
    /// not survive a localized Logic is the row walk itself
    /// (`trackDescriptionPrefix`, the quote glyphs) — see `LogicUIStrings`.
    ///
    /// A track whose real name genuinely ends in `, solo` keeps it: it is
    /// inside the quotes, and this parse never looks at the words.
    ///
    /// Returns nil when the text is not a track description at all, so the
    /// caller decides whether that is "skip this element" or "keep the row and
    /// say the name is unparsed".
    static func parseRowDescription(
        _ description: String,
        prefix: String = LogicUIStrings.Format.trackDescriptionPrefix,
        openQuote: Character = LogicUIStrings.Format.openQuote,
        closeQuote: Character = LogicUIStrings.Format.closeQuote
    ) -> (number: Int, name: String)? {
        guard description.hasPrefix(prefix),
              let open = description.firstIndex(of: openQuote),
              let close = description.lastIndex(of: closeQuote),
              open < close else {
            return nil
        }
        let numberText = description[
            description.index(description.startIndex, offsetBy: prefix.count)..<open
        ].trimmingCharacters(in: .whitespaces)
        guard let number = Int(numberText) else { return nil }
        return (number, String(description[description.index(after: open)..<close]))
    }
}

/// How a region on a row is asked for, and how a refusal about it reads.
///
/// The wording lives here because two call sites raise it (`selectRegion` and
/// `splitRegion`) and both used to raise it as `parameterAmbiguous`, whose
/// message opens "Accessible plugin parameter is ambiguous" — a sentence about
/// a PLUGIN, printed at an agent that had asked about a region, with the real
/// remedy (`start_bar`, or `track_number` when two rows share a name) nowhere
/// in it.
enum RegionAddressing {

    /// What the caller asked for, in one phrase, so the refusal can repeat the
    /// request back instead of describing only the candidates.
    static func request(regionName: String?, startBar: Int?) -> String {
        switch (regionName, startBar) {
        case let (name?, bar?): return "region '\(name)' at bar \(bar)"
        case let (name?, nil): return "region '\(name)'"
        case let (nil, bar?): return "the region at bar \(bar)"
        case (nil, nil): return "a region (neither region_name nor start_bar was given)"
        }
    }

    /// Logic's own name and start bar for every region on the row, in table
    /// order — the list both the ambiguous and the not-found refusal print.
    static func candidates(_ regions: [[String: Any]]) -> [String] {
        regions.map { region in
            let name = (region["name"] as? String) ?? "?"
            let bar = (region["start_bar"] as? Int).map(String.init) ?? "?"
            return "'\(name)' at bar \(bar)"
        }
    }
}
