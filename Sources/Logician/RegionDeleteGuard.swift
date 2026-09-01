import Foundation

// MARK: - What a Delete is allowed to be sure of

/// The guard in front of `logic_delete_region`'s `Delete`, as pure decisions.
///
/// WHY IT EXISTS. Logic's `Delete` acts on the SELECTION, and the selection is
/// project-wide: every selected region goes, on every track, rendered or not.
/// The tool's own guard was not — it counted selected regions by reducing over
/// `regionRows()`, which publishes only the track rows Logic has currently
/// RENDERED, and then promised the caller "exactly ONE region selected
/// project-wide". `selectRegion(exclusive: true)` clears the same rendered-only
/// set, so the tool could not even MAKE the selection exclusive off screen, and
/// the post-delete check compared region counts on the TARGET TRACK alone — so
/// a Delete that took the addressed region plus three on scrolled-out rows
/// satisfied it exactly and came back `success: true, verified: true`.
///
/// That is not a hypothetical shape on the reference project. `logic_list_tracks`
/// on the sandbox `Testlåt Copy`, read 2026-09-01, answers
/// `partial: true, missing_track_numbers: [10…19]` with a collapsed
/// `9 “Drum Synth Kit”` stack hiding its subtracks: ten rows whose regions the
/// arrangement walk cannot see, in the very project the region tools are
/// developed against.
///
/// THE FIX, IN TWO PARTS.
/// 1. Stop inferring exclusivity from a walk that cannot see the project. Fire
///    Logic's OWN `Deselect All` — a project-wide command — and prove it landed
///    by watching the rendered selection collapse to zero, then select the one
///    target region back. What makes the claim honest is that the proof and the
///    coverage are different planes: the receipt says the command reached Logic
///    and had effect, and Logic's semantics carry it to the rows nobody can see.
/// 2. When that command is not available, do not guess. If nothing proved rows
///    hidden, say the guard covered the rendered rows and no more; if rows ARE
///    provably hidden, REFUSE before Delete and name them.
///
/// Pure so every branch is pinned without Logic running; the AX reads that feed
/// it live in `AXRegions`.
enum RegionDeleteGuard {

    // MARK: Coverage

    /// Whether the arrangement walk can see every row a Delete would act on.
    ///
    /// Same rule as `TrackListCompleteness`, for the same reason: there is no
    /// `complete` verdict and there never can be from this plane. `partial` is
    /// positive evidence that rows are missing; `unknown` is "nothing proved any
    /// missing", which is NOT a guarantee that this is the whole project.
    struct Coverage: Equatable {
        /// True only on POSITIVE evidence that rows exist which the region walk
        /// cannot see.
        let partial: Bool
        /// `"partial"` or `"unknown"`, never `"complete"`.
        var completeness: String { partial ? "partial" : "unknown" }
        /// Track numbers that provably exist and whose regions are not in the
        /// walk. Never a guess at how many rows sit below the viewport.
        let unseenTrackNumbers: [Int]
        /// One sentence per signal.
        let reasons: [String]

        /// The rows, named, for a refusal or a result. Empty when the evidence
        /// is a scroll bar rather than a numbering gap — "something is out
        /// there" is still evidence, it just cannot be enumerated.
        var unseenSentence: String {
            guard !unseenTrackNumbers.isEmpty else { return "" }
            return "Track row(s) "
                + unseenTrackNumbers.map(String.init).joined(separator: ", ")
                + " are not rendered, so their regions are invisible to this walk"
                + " — and Logic's Delete is project-wide."
        }

        /// What the caller can do about it. Both routes are real tools, and the
        /// second one is the cheaper of the two.
        static let remedySentence =
            "Make the rows visible (scroll the Tracks area, and expand collapsed stacks with"
                + " logic_set_track_stack; logic_list_tracks reports what is missing), or run"
                + " logic_select_regions {mode: \"none\"} once — that learns Logic's own"
                + " 'Deselect All' into your key command set, after which this tool clears the"
                + " project-wide selection itself and needs no scrolling"
    }

    /// - Parameters:
    ///   - trackVerdict: the track-header column's own completeness verdict —
    ///     scroll state and collapsed stacks come from there, because the region
    ///     walk publishes neither.
    ///   - headerNumbers: track numbers with a rendered HEADER.
    ///   - regionRowNumbers: track numbers with a rendered REGION ROW.
    ///
    /// The two number sets are compared rather than assumed equal: a header
    /// without a region row is a row whose regions this walk cannot read, which
    /// is exactly the blind spot, and it costs a set subtraction to notice.
    static func coverage(
        trackVerdict: TrackListCompleteness.Verdict,
        headerNumbers: [Int],
        regionRowNumbers: [Int]
    ) -> Coverage {
        var reasons: [String] = []
        var unseen = Set<Int>()

        if trackVerdict.partial {
            reasons.append(contentsOf: trackVerdict.evidence)
            unseen.formUnion(trackVerdict.missingTrackNumbers)
        }
        let rowless = Set(headerNumbers).subtracting(regionRowNumbers).sorted()
        if !rowless.isEmpty {
            unseen.formUnion(rowless)
            reasons.append(
                "track row(s) " + rowless.map(String.init).joined(separator: ", ")
                    + " have a rendered track header but no rendered region row, so their regions"
                    + " are not in the arrangement map"
            )
        }
        if headerNumbers.isEmpty {
            reasons.append(
                "the track header column could not be read, so whether rows are missing from the"
                    + " arrangement map cannot be answered at all"
            )
        }
        return Coverage(
            partial: !reasons.isEmpty,
            unseenTrackNumbers: unseen.sorted(),
            reasons: reasons
        )
    }

    // MARK: The plan

    /// How this call intends to earn the word "exclusive" before Delete fires.
    enum Plan: Equatable {
        /// Fire Logic's project-wide `Deselect All`, prove it landed by watching
        /// the rendered selection fall to zero, then select the target back.
        /// The resulting claim covers rows nobody can see.
        case projectWideClear
        /// `Deselect All` is not in the key command registry and nothing proved
        /// any row hidden. Go ahead on the rendered-rows count alone, and say in
        /// the result that that is what was checked.
        case renderedRowsOnly(warning: String)
        /// Rows are provably hidden AND there is no project-wide clear to reach
        /// them with. Refuse before anything is written.
        case refuse(String)
    }

    /// The decision, taken BEFORE the first write so that a refusal can honestly
    /// say the project is untouched.
    ///
    /// The project-wide clear is used whenever it is available, not only when
    /// the listing looks partial: `partial: false` means "nothing proved rows
    /// missing", and a destructive command is the last place to spend an absence
    /// of evidence as if it were a guarantee.
    static func plan(coverage: Coverage, deselectAllRegistered: Bool) -> Plan {
        if deselectAllRegistered { return .projectWideClear }
        if !coverage.partial {
            return .renderedRowsOnly(
                warning: "Exclusivity was checked across the RENDERED track rows only. Nothing"
                    + " proved any row missing, but a row Logic has not rendered publishes"
                    + " nothing at all, so this is not a project-wide proof. "
                    + Coverage.remedySentence + "."
            )
        }
        return .refuse(
            [
                "the arrangement walk cannot see the whole project, and Logic's Delete can: "
                    + coverage.reasons.joined(separator: "; ") + ".",
                coverage.unseenSentence,
                "A region selected on one of those rows would be deleted too, and neither the"
                    + " selection count nor the after-check could notice. Refusing to fire Delete"
                    + " blind. Nothing was deleted and nothing was selected.",
                Coverage.remedySentence
            ].filter { !$0.isEmpty }.joined(separator: " ")
        )
    }

    // MARK: The after-check

    /// What the arrangement says about a Delete that has already fired.
    ///
    /// The counts are totals across every rendered row, not the target track's —
    /// the old check compared the target track alone, which is satisfied by a
    /// Delete that also took regions from three other rows.
    enum Verification: Equatable {
        /// Exactly the addressed region left the arrangement.
        case deleted
        /// Nothing has changed yet: keep looking, then refuse.
        case unchanged
        /// The addressed region went AND so did others. Loud, and never
        /// `success: true`.
        case collateral(alsoRemoved: Int)
        /// The count fell but the addressed region is still there: something
        /// else was deleted.
        case wrongRegion(removed: Int)
    }

    static func verify(
        targetStillPresent: Bool, regionsBefore: Int, regionsAfter: Int
    ) -> Verification {
        let removed = regionsBefore - regionsAfter
        if targetStillPresent {
            return removed <= 0 ? .unchanged : .wrongRegion(removed: removed)
        }
        // The target is gone and the totals have not moved: the map is mid-update
        // (or a region appeared as one left). Keep looking rather than calling a
        // half-read snapshot a verified delete.
        if removed <= 0 { return .unchanged }
        if removed == 1 { return .deleted }
        return .collateral(alsoRemoved: removed - 1)
    }
}
