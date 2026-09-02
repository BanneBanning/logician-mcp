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

    /// The collapsed stack a run of missing numbers sits directly behind.
    ///
    /// An INFERENCE, and the only one in this type: the numbers start at the
    /// row immediately after a stack that is rendered, is a stack, and is
    /// closed. Nothing on this plane proves those numbers are that stack's
    /// subtracks — but they are the one thing on screen that hides exactly
    /// there, and saying so turns "ten tracks are missing somewhere" into
    /// "expand track 9 and you have them".
    struct HiddenBy {
        let trackNumber: Int
        let trackName: String
        /// The contiguous run of missing numbers attributed to it.
        let trackNumbers: [Int]
    }

    /// What Logic's own scroll bar said, and — when it said nothing — what that
    /// silence does and does not mean.
    ///
    /// Exists because the silence is the normal case (measured 2026-09-02: the
    /// reference project's Tracks scroll area publishes no vertical scroll bar
    /// at all) and it is indistinguishable, in a result that only reports
    /// signals that FIRED, from "Logic said everything fits".
    struct ScrollSignal {
        /// `"scrollable"`, `"fits"` or `"unavailable"`.
        let state: String
        let reason: String
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
        /// The collapsed stack the first run of missing numbers sits behind,
        /// when one does. Nil when the gap is not attributable.
        let hiddenBy: HiddenBy?
        /// The scroll bar's verdict, or the reason there was none.
        let scrollSignal: ScrollSignal
    }

    /// THE FREE SIGNAL: what the ROW NUMBERS alone prove is missing.
    ///
    /// Logic numbers its track rows consecutively from 1, so a listing that
    /// renders rows 1–9 and 20–29 has already proved that ten rows exist which
    /// it cannot see — no second read, no header column, no scroll bar. That
    /// matters because the other three signals are not free: the collapsed-stack
    /// and scroll-bar evidence needs the track HEADER column, measured 2026-09-02
    /// at +40–50 ms on a call that runs in 95–120 ms warm — a 40% surcharge for
    /// two signals. The arrangement map therefore pays for this rule always and for
    /// the header column only on request — see `LogicAccessibility.listRegions`.
    ///
    /// `rowNoun` names what is missing in the first sentence, because the two
    /// callers list different things: `logic_list_tracks` renders track HEADERS,
    /// `logic_list_regions` renders region ROWS, and the same number can be
    /// missing from one and present in the other.
    static func numbering(rowNumbers: [Int], rowNoun: String) -> Verdict {
        var evidence: [String] = []
        var missing: [Int] = []
        let numbers = rowNumbers.sorted()
        guard let first = numbers.first, let last = numbers.last else {
            return Verdict(partial: false, evidence: [], missingTrackNumbers: [],
                           hiddenBy: nil, scrollSignal: scrollSignal(nil))
        }
        if first > 1 {
            missing.append(contentsOf: 1..<first)
            evidence.append(
                "the lowest track number rendered is \(first), so \(first - 1) \(rowNoun)(s)"
                    + " above it are scrolled out of the Tracks area"
            )
        }
        let gaps = Array(Set(first...last).subtracting(numbers)).sorted()
        if !gaps.isEmpty {
            missing.append(contentsOf: gaps)
            evidence.append(
                "track number(s) \(gaps.map(String.init).joined(separator: ", ")) fall inside"
                    + " the rendered range and are not listed — they are hidden or scrolled out"
            )
        }
        return Verdict(
            partial: !evidence.isEmpty,
            evidence: evidence,
            missingTrackNumbers: Array(Set(missing)).sorted(),
            hiddenBy: nil,
            scrollSignal: scrollSignal(nil)
        )
    }

    /// `scrollable` is the Tracks area's own scroll state: true when Logic's
    /// scroll bar says there is content outside the viewport, false when it says
    /// there is not, nil when the question could not be asked. That last case is
    /// the reason this is a three-valued input and not a boolean — a scroll bar
    /// this code could not find must never read as "everything fits".
    static func evaluate(rows: [Row], scrollable: Bool?) -> Verdict {
        var evidence: [String] = []
        var missing: [Int] = []
        let signal = scrollSignal(scrollable)

        if rows.isEmpty {
            evidence.append(
                "no track headers are rendered at all, so this list describes nothing about the"
                    + " project — not even that it is empty"
            )
            return Verdict(
                partial: true, evidence: evidence, missingTrackNumbers: [],
                hiddenBy: nil, scrollSignal: signal
            )
        }

        let numbers = rows.map(\.number).sorted()
        // Collapsed stacks are found BEFORE the gap sentence is written,
        // because the gap sentence is allowed to name the one it sits behind.
        let collapsed = rows.filter { $0.isStack && $0.expanded == false }
        var hiddenBy: HiddenBy?

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
                let run = contiguousRun(from: gaps)
                if let first = run.first,
                   let stack = collapsed.first(where: { $0.number == first - 1 }) {
                    hiddenBy = HiddenBy(
                        trackNumber: stack.number, trackName: stack.name, trackNumbers: run
                    )
                }
                evidence.append(gapSentence(gaps: gaps, hiddenBy: hiddenBy))
            }
        }
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
            missingTrackNumbers: Array(Set(missing)).sorted(),
            hiddenBy: hiddenBy,
            scrollSignal: signal
        )
    }

    /// The run of consecutive numbers the sorted gap list opens with. The join
    /// below only ever claims THAT run: a second, later gap has its own cause.
    static func contiguousRun(from gaps: [Int]) -> [Int] {
        guard let first = gaps.first else { return [] }
        var run = [first]
        for number in gaps.dropFirst() {
            guard number == run.last! + 1 else { break }
            run.append(number)
        }
        return run
    }

    /// The gap sentence — and, when the numbers start immediately after a
    /// collapsed stack, the JOIN. The two facts used to ship as independent
    /// sentences ("10…19 are missing" and "stack 9 is collapsed") and left the
    /// agent to connect them; the connection costs no AX read at all.
    static func gapSentence(gaps: [Int], hiddenBy: HiddenBy?) -> String {
        let list = gaps.map(String.init).joined(separator: ", ")
        let opening = "track number(s) \(list) fall inside the rendered range and are not listed"
        guard let hidden = hiddenBy else {
            return opening + " — they are hidden or scrolled out"
        }
        let stack = "collapsed track stack \(hidden.trackNumber) “\(hidden.trackName)”"
        if hidden.trackNumbers.count == gaps.count {
            return opening + "; they follow \(stack) immediately, so they are almost certainly its"
                + " hidden subtracks — expand it with logic_set_track_stack to list them"
        }
        let run = hidden.trackNumbers.map(String.init).joined(separator: ", ")
        return opening + "; \(run) follow \(stack) immediately, so they are almost certainly its"
            + " hidden subtracks (expand it with logic_set_track_stack) — the rest are hidden or"
            + " scrolled out"
    }

    /// What the Tracks area's scroll bar said. `unavailable` is not a shrug: it
    /// names the one failure mode the other two signals cannot cover, because
    /// both of those need a RENDERED row to point at.
    static func scrollSignal(_ scrollable: Bool?) -> ScrollSignal {
        switch scrollable {
        // Every reason is one short sentence. This field ships on EVERY call,
        // and a standing paragraph here would just be the note this pass cut.
        case .some(true):
            return ScrollSignal(
                state: "scrollable",
                reason: "Logic's scroll bar reports content outside the Tracks viewport"
            )
        case .some(false):
            return ScrollSignal(
                state: "fits",
                reason: "Logic's scroll bar reports that the Tracks content fits the viewport"
            )
        case .none:
            return ScrollSignal(
                state: "unavailable",
                reason: "Logic publishes no vertical scroll bar on the Tracks area, so rows BELOW"
                    + " the last one listed leave no evidence here — this silence is not a fit"
            )
        }
    }

    /// The sentence every listing carries, partial or not. It says the thing an
    /// agent must not forget: this plane cannot see the whole project, and the
    /// strips without track headers (`Stereo Out`, `Master`, auxes, buses) are
    /// never in it at all.
    ///
    /// Trimmed 2026-09-02 from 570 bytes to 399 — it was 22% of a 2 597-byte
    /// response and byte-identical on every call ever made. Every claim it made
    /// is still here; the restatements are not.
    static let standingNote =
        "Only track headers Logic has RENDERED are exposed. partial: true means rows are provably"
            + " missing (see partial_evidence); partial: false only means nothing proved any"
            + " missing — never a census, because an unrendered row publishes nothing. Output, aux"
            + " and bus strips (Stereo Out, Master, buses) have no track header and are never"
            + " listed here, yet the mixing, send and plugin tools accept their names."
}
