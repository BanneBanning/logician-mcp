import Foundation

// MARK: - Is the track list the whole project?

/// Whether a track listing is missing rows, and the evidence for saying so.
///
/// This exists because of the sharpest honesty failure the producer audit found
/// (COVERAGE U1): `logic_list_tracks` returned `success: true` with a PARTIAL
/// world — only the track headers Logic had currently rendered, 13 of 27 on the
/// reference project — and the caveat was a footnote on a successful result
/// while every other guard in this server is loud. An agent that skims builds
/// its whole mental model on that list and never learns the other fourteen
/// tracks exist.
///
/// THE ONE RULE HERE. There is no "complete" verdict, and there never can be
/// from this plane: Accessibility publishes what is rendered and says nothing
/// about what is not, so the absence of evidence is not evidence of absence.
/// The two answers are therefore `partial` (something is provably missing, and
/// here is what) and `unknown` (nothing proved it incomplete). A caller that
/// needs certainty has to ask the control surface, which enumerates every strip
/// in the project whether it is on screen or not.
///
/// Pure so that each signal can be tested without Logic running; the AX-side
/// reads that feed it are in `AXTracks`.
enum TrackListCompleteness {

    /// One rendered track header, reduced to what completeness depends on.
    struct Row {
        let number: Int
        let name: String
        let isStack: Bool
        let expanded: Bool?

        init(number: Int, name: String, isStack: Bool, expanded: Bool?) {
            self.number = number
            self.name = name
            self.isStack = isStack
            self.expanded = expanded
        }
    }

    struct Verdict {
        /// True only on POSITIVE evidence that rows are missing. False means
        /// "nothing proved it incomplete" — never "this is every track".
        let partial: Bool
        /// `"partial"` or `"unknown"`. Deliberately not a boolean pair with a
        /// third meaning: see the rule above.
        var completeness: String { partial ? "partial" : "unknown" }
        /// One sentence per signal, in the words a result can carry.
        let evidence: [String]
        /// Track numbers that provably exist and are not in the list, when the
        /// numbering makes them nameable. Never a guess at how many rows are
        /// below the viewport — that count is not knowable from here.
        let missingTrackNumbers: [Int]
    }

    /// `scrollable` is the Tracks area's own scroll state: true when Logic's
    /// scroll bar says there is content outside the viewport, false when it says
    /// there is not, nil when the question could not be asked. That last case is
    /// the reason this is a three-valued input and not a boolean — a scroll bar
    /// this code could not find must never read as "everything fits".
    static func evaluate(rows: [Row], scrollable: Bool?) -> Verdict {
        var evidence: [String] = []
        var missing: [Int] = []

        if rows.isEmpty {
            evidence.append(
                "no track headers are rendered at all, so this list describes nothing about the"
                    + " project — not even that it is empty"
            )
            return Verdict(partial: true, evidence: evidence, missingTrackNumbers: [])
        }

        let numbers = rows.map(\.number).sorted()
        if let first = numbers.first, first > 1 {
            missing.append(contentsOf: 1..<first)
            evidence.append(
                "the lowest track number rendered is \(first), so \(first - 1) track header(s)"
                    + " above it are scrolled out of the Tracks area"
            )
        }
        if let last = numbers.last {
            let gaps = Array(Set(numbers.first!...last).subtracting(numbers)).sorted()
            if !gaps.isEmpty {
                missing.append(contentsOf: gaps)
                evidence.append(
                    "track number(s) \(gaps.map(String.init).joined(separator: ", ")) fall inside"
                        + " the rendered range and are not listed — they are hidden or scrolled out"
                )
            }
        }
        let collapsed = rows.filter { $0.isStack && $0.expanded == false }
        if !collapsed.isEmpty {
            evidence.append(
                "collapsed track stack(s) "
                    + collapsed.map { "\($0.number) “\($0.name)”" }.joined(separator: ", ")
                    + " hide their subtracks; expand with logic_set_track_stack to list them"
            )
        }
        if scrollable == true {
            evidence.append(
                "the Tracks area is scrolled or scrollable, so rows outside the viewport are not"
                    + " rendered and cannot be listed"
            )
        }
        return Verdict(
            partial: !evidence.isEmpty,
            evidence: evidence,
            missingTrackNumbers: Array(Set(missing)).sorted()
        )
    }

    /// The sentence every listing carries, partial or not. It says the thing an
    /// agent must not forget: this plane cannot see the whole project, and the
    /// strips without track headers (`Stereo Out`, `Master`, auxes, buses) are
    /// never in it at all.
    static let standingNote =
        "Only track headers Logic has currently RENDERED in the Tracks area are exposed through"
            + " Accessibility. partial: true means rows are provably missing (see"
            + " partial_evidence); partial: false means nothing proved any missing — it is NOT a"
            + " guarantee that this is every track, because a row Logic has not rendered publishes"
            + " nothing at all. Never treat this list as the project's track census. Output, aux"
            + " and bus strips (Stereo Out, Master, Aux 1, buses) have no track header and are"
            + " never listed here, yet the mixing, send and plugin tools accept their names."
}
