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
