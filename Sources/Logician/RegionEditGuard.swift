import Foundation

// MARK: - What a destructive region command is allowed to be sure of

/// The guard in front of every region key command that acts on the SELECTION,
/// as pure decisions: `logic_delete_region`'s Delete, `logic_copy_region`'s
/// Cut/Copy, `logic_move_region`'s Nudge and `logic_split_region`'s Split.
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
/// Cut, Nudge and Split are the SAME command shape with a different verb, and
/// they had the same blind spot: Cut removes every selected region, Copy puts
/// every selected region on the clipboard for Paste to put back down, Nudge
/// moves every one of them and Split cuts every one of them at the playhead.
/// This type is deliberately shared by all four rather than copied per tool —
/// there is one question here ("how far does this call's selection reach?") and
/// it must not be answered four slightly different ways.
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
///    provably hidden, REFUSE before the command fires and name them.
///
/// Pure so every branch is pinned without Logic running; the AX reads that feed
/// it live in `AXRegions`.
enum RegionEditGuard {

    // MARK: The command being guarded

    /// The five destructive region commands, in the words the messages need.
    ///
    /// They differ only in vocabulary, never in the problem: each acts on
    /// Logic's selection, and Logic's selection is project-wide while this
    /// server's arrangement map is not.
    enum Command: Equatable {
        /// `logic_delete_region` — Logic's `Delete`.
        case delete
        /// `logic_copy_region {move: true}` — Logic's `Cut`.
        case cut
        /// `logic_copy_region` — Logic's `Copy`. Non-destructive on its own, but
        /// the `Paste` that follows puts down EVERYTHING the clipboard holds, so
        /// a wide selection at Copy time is a wide write at Paste time.
        case copy
        /// `logic_move_region` — `Nudge Region/Event Position … by Bar/Beat`.
        case nudge
        /// `logic_split_region` — `Split Regions/Events at Playhead Position`.
        case split

        /// Logic's own word for the command, so a refusal matches what the agent
        /// will find in the Key Commands window.
        var name: String {
            switch self {
            case .delete: return "Delete"
            case .cut: return "Cut"
            case .copy: return "Copy"
            case .nudge: return "Nudge"
            case .split: return "Split"
            }
        }

        /// What happens to a region this call never named, if one is selected on
        /// a row nobody can see.
        var collateralClause: String {
            switch self {
            case .delete: return "A region selected on one of those rows would be deleted too"
            case .cut: return "A region selected on one of those rows would be cut too"
            case .copy:
                return "A region selected on one of those rows would go onto the clipboard too,"
                    + " and the Paste that follows would put it down"
            case .nudge: return "A region selected on one of those rows would be nudged too"
            case .split:
                return "A region selected on one of those rows would be cut at the playhead too"
            }
        }

        /// The sentence a refusal ends on. Present tense of "nothing happened",
        /// because a refusal is taken before the command fires.
        var nothingHappened: String {
            switch self {
            case .delete: return "Nothing was deleted"
            case .cut: return "Nothing was cut"
            case .copy: return "Nothing was copied"
            case .nudge: return "Nothing was moved"
            case .split: return "Nothing was split"
            }
        }
    }

    // MARK: Coverage

    /// Whether the arrangement walk can see every row the command would act on.
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
        func unseenSentence(for command: Command) -> String {
            guard !unseenTrackNumbers.isEmpty else { return "" }
            return "Track row(s) "
                + unseenTrackNumbers.map(String.init).joined(separator: ", ")
                + " are not rendered, so their regions are invisible to this walk"
                + " — and Logic's \(command.name) is project-wide."
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

    /// How this call intends to earn the word "exclusive" before the command
    /// fires.
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
    ///
    /// WHY THERE IS NO "SKIP THE CLEAR" FAST PATH, and it is not an oversight.
    /// The clear is the expensive half of these calls — measured 2026-09-01,
    /// `logic_delete_region` went 1.98 s to 2.78 s for it, and the same ~0.8 s
    /// lands on Cut, Nudge and Split here — so the obvious optimisation is to
    /// skip it when the project is fully visible. It cannot be taken: `Coverage`
    /// has no `complete` verdict, by construction and for the reason spelled out
    /// in `TrackListCompleteness` — Accessibility publishes what is RENDERED and
    /// says nothing whatever about what is not, so "every row I can see has a
    /// region row, no stack is collapsed and the scroll bar says everything
    /// fits" is the absence of evidence, not evidence of absence. Spending it as
    /// a guarantee in front of a destructive command is precisely the bug this
    /// guard exists to close. The one plane that CAN enumerate a project's
    /// strips is the control surface, and it enumerates mixer strips, not track
    /// rows or their regions, so it cannot answer this question either.
    static func plan(
        coverage: Coverage, deselectAllRegistered: Bool, command: Command
    ) -> Plan {
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
                "the arrangement walk cannot see the whole project, and Logic's \(command.name)"
                    + " can: " + coverage.reasons.joined(separator: "; ") + ".",
                coverage.unseenSentence(for: command),
                command.collateralClause + ", and neither the selection count nor the after-check"
                    + " could notice. Refusing to fire \(command.name) blind. "
                    + command.nothingHappened + " and nothing was selected.",
                Coverage.remedySentence
            ].filter { !$0.isEmpty }.joined(separator: " ")
        )
    }

    // MARK: The after-check — Delete

    /// What the arrangement says about a Delete that has already fired.
    ///
    /// The counts are totals across every rendered row, not the target track's —
    /// the old check compared the target track alone, which is satisfied by a
    /// Delete that also emptied three other rows.
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

    // MARK: The after-check — Cut, Copy, Nudge, Split

    /// The rendered-row-wide count check for a command whose effect on the
    /// region TOTAL is known in advance.
    ///
    /// A Split adds exactly one region, a Copy+Paste adds exactly one, a Nudge
    /// changes none and a Cut+Paste changes none (one leaves, one arrives). Any
    /// other movement of the total is a command that reached further than this
    /// call did — the same blind spot `verify` closes for Delete, in the shape
    /// the other three tools need.
    ///
    /// READ WHAT IT CANNOT SEE, because the tools say so in their results: a
    /// second selected region that MOVED without landing on anything keeps the
    /// total exactly where it was, so this check would call it clean. The count
    /// is the backstop; the project-wide clear above is the actual guard, and
    /// the reason the backstop is nearly always quiet.
    enum DeltaVerdict: Equatable {
        /// The total moved by exactly the amount this call can produce.
        case asExpected
        /// The total has not moved at all and it was supposed to: nothing has
        /// happened YET. A poll's cue to keep looking, not a verdict.
        case pending
        /// The total moved, and not by an amount this call can produce.
        case unexpected(actualDelta: Int)
    }

    static func delta(expected: Int, before: Int, after: Int) -> DeltaVerdict {
        let actual = after - before
        if actual == expected { return .asExpected }
        if actual == 0 { return .pending }
        return .unexpected(actualDelta: actual)
    }

    /// What to tell the caller when the rendered totals moved by the wrong
    /// amount. Both causes are named because counts cannot tell them apart, and
    /// both are things the caller has to act on.
    static func unexpectedTotalSentence(
        command: Command, expectedDelta: Int, before: Int, after: Int
    ) -> String {
        func signed(_ value: Int) -> String { value < 0 ? "\(value)" : "+\(value)" }
        return "the region total across every RENDERED track row went \(before) → \(after) "
            + "(\(signed(after - before))), and this call could only ever produce "
            + "\(signed(expectedDelta)). Either \(command.name) acted on a selection wider than "
            + "this call made — a region selected on another row went with it — or a region was "
            + "overlaid completely and Logic swallowed it. Undo restores them; read "
            + "logic_list_regions before doing anything else."
    }

    // MARK: - The after-check — where the Nudge actually put it

    /// WHERE THE NUDGE LEFT THE REGION, against where it was asked to leave it.
    ///
    /// `logic_move_region` used to gate its ONLY positional check on
    /// `byBeats == 0`, and had no check on `start_beat` anywhere: a beat nudge
    /// was "verified" by nothing but *the region still exists and is still
    /// selected*. Measured 2026-09-02, `{by_beats: 1}` came back `from_bar: 20,
    /// to_bar: 20, to_beat: 2, verified: true` — and the caller could not check
    /// it either, because the result published `from_bar` and never
    /// `from_beat`. So a beat nudge that did nothing at all (the focus-dead
    /// Logic `TracksAreaFocus` exists for, or a stale `Nudge … by Beat`
    /// binding) was a silent success on a destructive tool, and
    /// `{by_bars: 16, by_beats: 1}` switched the exact bar comparison off as
    /// well.
    ///
    /// WHY THE METER IS NOT READ. A beat nudge can carry across a bar line, and
    /// how many beats a bar holds is a project property — 5/4 on the reference
    /// project — that the control bar publishes only AT THE PLAYHEAD and the
    /// Signature List only for ~2 s of reading. Neither is worth a read here,
    /// because the request and the two positions already over-determine it: the
    /// bar and the beat delta have to add up under ONE meter, and that meter
    /// then has to reproduce the landing bar and beat exactly. A nudge that did
    /// nothing, one that went the wrong way and one that stopped short all fail
    /// that. What it CANNOT separate is a multi-beat request that ran partway
    /// in a meter it cannot see — 7 beats requested and 5 delivered looks
    /// exactly like 7 beats in 7/4 — which is why the carried verdict names the
    /// meter it INFERRED instead of claiming to have read one.
    enum NudgeVerdict: Equatable {
        /// The bar delta and the beat delta are the ones that were requested.
        case exact
        /// The beats carried across a bar line, and the landing position is the
        /// one this meter produces from the request. Inferred from the move
        /// itself, never read from Logic.
        case carried(beatsPerBar: Int)
        /// The region is exactly where it started. Nothing has happened yet, or
        /// nothing is going to.
        case unmoved
        /// It moved, and not to where this request would have put it.
        case wrongPosition
    }

    /// Floor division, because a leftward beat nudge carries backwards and
    /// Swift's `/` truncates towards zero: `-1 / 5` is 0 while the bar line
    /// crossed is -1.
    private static func floorDiv(_ dividend: Int, _ divisor: Int) -> Int {
        let quotient = dividend / divisor
        let remainder = dividend % divisor
        return remainder != 0 && ((remainder < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    /// - Parameters:
    ///   - fromBeat: beat 1 when the arrangement map published none —
    ///     `parseRegion` OMITS `start_beat` on a region that starts on the bar
    ///     line, so absent means 1 and must never be read as "unknown".
    ///   - toBeat: the same, on the other side of the nudge.
    static func nudgeVerdict(
        byBars: Int, byBeats: Int,
        fromBar: Int, fromBeat: Int, toBar: Int, toBeat: Int
    ) -> NudgeVerdict {
        let barDelta = toBar - fromBar
        let beatDelta = toBeat - fromBeat
        // The whole-bar case, and every beat case that stayed inside its bar:
        // no meter needed, and the check is exact in both terms.
        if barDelta == byBars, beatDelta == byBeats { return .exact }
        if barDelta == 0, beatDelta == 0 { return .unmoved }
        // Only the beat term can carry across a bar line, so a bar-only request
        // that landed on a different bar than it asked for is simply wrong.
        guard byBeats != 0 else { return .wrongPosition }
        let carriedBars = barDelta - byBars
        // Rightward beats can only carry forwards and leftward ones backwards.
        guard carriedBars != 0, carriedBars.signum() == byBeats.signum() else {
            return .wrongPosition
        }
        let unaccountedBeats = byBeats - beatDelta
        guard unaccountedBeats % carriedBars == 0 else { return .wrongPosition }
        let beatsPerBar = unaccountedBeats / carriedBars
        // 2…64 quarter-note beats to a bar: under 2 nothing can carry, over 64
        // this is arithmetic that happened to divide rather than a meter.
        guard (2...64).contains(beatsPerBar),
              (1...beatsPerBar).contains(fromBeat),
              (1...beatsPerBar).contains(toBeat) else { return .wrongPosition }
        // The divisibility above only says the TOTAL displacement adds up. This
        // says the landing bar and beat are the ones that meter produces from
        // this request at this starting position, which is the actual claim.
        let beatOffset = (fromBeat - 1) + byBeats
        let carry = floorDiv(beatOffset, beatsPerBar)
        guard fromBar + byBars + carry == toBar,
              beatOffset - carry * beatsPerBar + 1 == toBeat else { return .wrongPosition }
        return .carried(beatsPerBar: beatsPerBar)
    }

    /// The request, in the terms the caller passed it in.
    static func nudgeRequestSentence(byBars: Int, byBeats: Int) -> String {
        func term(_ value: Int, _ noun: String) -> String? {
            guard value != 0 else { return nil }
            return "\(value > 0 ? "+" : "")\(value) \(abs(value) == 1 ? noun : noun + "s")"
        }
        let terms = [term(byBars, "bar"), term(byBeats, "beat")].compactMap { $0 }
        return terms.isEmpty ? "no move at all" : terms.joined(separator: " and ")
    }

    /// What to tell the caller when the region is not where the nudge should
    /// have left it. The `unmoved` sentence is the one a Nudge fired without
    /// Tracks-area keyboard focus produces every time, so the caller gets that
    /// verdict after it rather than a hunt.
    static func nudgeSentence(
        verdict: NudgeVerdict, byBars: Int, byBeats: Int,
        fromBar: Int, fromBeat: Int, toBar: Int, toBeat: Int
    ) -> String {
        let landed = "bar \(toBar) beat \(toBeat)"
        switch verdict {
        case .unmoved:
            return "the region is still at \(landed), where it started - it did not move at all."
        case .wrongPosition:
            return "the region went from bar \(fromBar) beat \(fromBeat) to \(landed), which is "
                + "not \(nudgeRequestSentence(byBars: byBars, byBeats: byBeats)) from where it "
                + "was. Either some of the nudges landed and some did not, or something else "
                + "moved it. Undo steps back one nudge at a time; read logic_list_regions before "
                + "anything else."
        case .exact, .carried:
            return "the region is at \(landed)."
        }
    }

    // MARK: - The after-check — what the Nudge landed ON

    /// One region's position as the arrangement map published it: the yardstick
    /// for the neighbours of a region that has just moved.
    ///
    /// Beats default to 1 rather than to "unknown" for the same reason as in
    /// `nudgeVerdict`: `parseRegion` omits them on the bar line.
    struct Span: Hashable {
        let name: String
        let startBar: Int
        let startBeat: Int
        let endBar: Int
        let endBeat: Int

        var sentence: String {
            "'\(name)' bar \(startBar) beat \(startBeat) to bar \(endBar) beat \(endBeat)"
        }

        /// nil when the region published no position at all — an unparsed help
        /// sentence is COUNTED, never compared, so it cannot fake a trim.
        init?(_ region: [String: Any]) {
            guard let startBar = region["start_bar"] as? Int else { return nil }
            name = region["name"] as? String ?? "?"
            self.startBar = startBar
            startBeat = region["start_beat"] as? Int ?? 1
            endBar = region["end_bar"] as? Int ?? startBar
            endBeat = region["end_beat"] as? Int ?? 1
        }

        init(name: String, startBar: Int, startBeat: Int = 1, endBar: Int, endBeat: Int = 1) {
            self.name = name
            self.startBar = startBar
            self.startBeat = startBeat
            self.endBar = endBar
            self.endBeat = endBeat
        }
    }

    /// What happened to the regions on the row that were NOT the one moving.
    ///
    /// The count check above can only see a neighbour swallowed WHOLE. Logic's
    /// actual behaviour, which `logic_move_region`'s own description warns
    /// about, is that a nudged region TRIMS whatever it is laid over — and a
    /// trim moves a neighbour's start or end and leaves the region total
    /// exactly where it was, so it used to pass as a clean success.
    enum NeighbourVerdict: Equatable {
        /// Every other region on the row is where it was, at the length it was.
        case untouched
        /// Spans that were there before and are not now, and spans that are
        /// there now and were not before — the same trim from both sides.
        case changed(lost: [Span], gained: [Span])
        /// The two snapshots disagree about how many regions published no
        /// position at all, so the comparison cannot speak. Reported rather
        /// than rounded down to "untouched".
        case unreadable(before: Int, after: Int)
    }

    /// Compares the target row either side of the nudge, at zero AX cost: both
    /// snapshots are already in hand (`arrangementCensus().targetRegions`), and
    /// the moved region's own before/after span is taken out of the comparison
    /// so that the thing that was SUPPOSED to move does not read as damage.
    ///
    /// A multiset, not a sort-and-zip: two regions on one row can share a name
    /// (a copy of `Crash` beside `Crash`), and the question is which SPANS came
    /// and went, not which index changed.
    static func neighbourVerdict(
        before: [[String: Any]], after: [[String: Any]],
        movedBefore: [String: Any], movedAfter: [String: Any]
    ) -> NeighbourVerdict {
        func multiset(
            _ regions: [[String: Any]], excluding moved: [String: Any]
        ) -> (counts: [Span: Int], unreadable: Int) {
            var counts: [Span: Int] = [:]
            var unreadable = 0
            for region in regions {
                if let span = Span(region) {
                    counts[span, default: 0] += 1
                } else {
                    unreadable += 1
                }
            }
            if let span = Span(moved), let held = counts[span] {
                counts[span] = held > 1 ? held - 1 : nil
            }
            return (counts, unreadable)
        }
        let start = multiset(before, excluding: movedBefore)
        let end = multiset(after, excluding: movedAfter)
        var lost: [Span] = []
        var gained: [Span] = []
        for (span, count) in start.counts {
            let delta = count - (end.counts[span] ?? 0)
            if delta > 0 { lost.append(contentsOf: repeatElement(span, count: delta)) }
        }
        for (span, count) in end.counts {
            let delta = count - (start.counts[span] ?? 0)
            if delta > 0 { gained.append(contentsOf: repeatElement(span, count: delta)) }
        }
        func ordered(_ spans: [Span]) -> [Span] {
            spans.sorted {
                ($0.startBar, $0.startBeat, $0.name) < ($1.startBar, $1.startBeat, $1.name)
            }
        }
        if !lost.isEmpty || !gained.isEmpty {
            return .changed(lost: ordered(lost), gained: ordered(gained))
        }
        if start.unreadable != end.unreadable {
            return .unreadable(before: start.unreadable, after: end.unreadable)
        }
        return .untouched
    }

    /// The trim, named. Both sides are listed because a trim is one region in
    /// two places — the span that was there and the shorter one that replaced
    /// it — and because a neighbour that went entirely has no "after" span.
    static func neighbourSentence(lost: [Span], gained: [Span]) -> String {
        func list(_ spans: [Span]) -> String { spans.map(\.sentence).joined(separator: ", ") }
        var sentence = "the other regions on the row did not stay where they were: "
        if !lost.isEmpty { sentence += list(lost) + " is gone" }
        if !lost.isEmpty && !gained.isEmpty { sentence += " and " }
        if !gained.isEmpty {
            sentence += list(gained) + (lost.isEmpty ? " is new" : " is there instead")
        }
        return sentence + ". A nudged region TRIMS whatever it is laid over, which changes a "
            + "neighbour's start or end and leaves the region total alone - so this is the damage "
            + "the count check cannot see. Undo puts it back one nudge at a time; read "
            + "logic_list_regions before anything else."
    }

    /// Did the region that moved keep its LENGTH?
    ///
    /// Meter-free, and exact: whatever the nudge did to the start it must have
    /// done to the end, so the two displacements are compared to each other
    /// rather than to a bar count. A difference is the moved region itself
    /// being trimmed — the same overlay damage from the other side.
    static func nudgeLengthKept(before: Span, after: Span) -> Bool {
        (after.startBar - before.startBar, after.startBeat - before.startBeat)
            == (after.endBar - before.endBar, after.endBeat - before.endBeat)
    }
}
