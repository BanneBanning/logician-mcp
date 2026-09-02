import XCTest
@testable import Logician

/// The decisions in front of every region key command that acts on the
/// selection: Delete, Cut, Copy, Nudge and Split.
///
/// Logic's Delete is project-wide; the arrangement map is not. The tool used to
/// promise the first while checking the second — a count over RENDERED track
/// rows only, an exclusive-clear that reached the same rendered rows only, and
/// an after-check that compared region counts on the target track alone. On the
/// sandbox project (`partial: true`, `missing_track_numbers: [10…19]`, a
/// collapsed `9 “Drum Synth Kit”` stack) a Delete that also took regions off
/// those hidden rows passed all three and reported `success: true`. Cut, Copy,
/// Nudge and Split had the identical blind spot, which is why the guard is one
/// type with a `Command` rather than four near-copies.
///
/// These pin the replacement without Logic running: what counts as a row this
/// walk cannot see, what each command does about it, and what the after-checks
/// call an edit that reached further than the call did.
final class RegionEditGuardTests: XCTestCase {

    private func headers(_ numbers: [Int], collapsedStacks: [Int] = []) -> [TrackListCompleteness.Row] {
        numbers.map {
            TrackListCompleteness.Row(
                number: $0, name: "T\($0)",
                isStack: collapsedStacks.contains($0),
                expanded: collapsedStacks.contains($0) ? false : nil
            )
        }
    }

    private func coverage(
        headerNumbers: [Int],
        regionRowNumbers: [Int]? = nil,
        scrollable: Bool? = false,
        collapsedStacks: [Int] = []
    ) -> RegionEditGuard.Coverage {
        RegionEditGuard.coverage(
            trackVerdict: TrackListCompleteness.evaluate(
                rows: headers(headerNumbers, collapsedStacks: collapsedStacks),
                scrollable: scrollable
            ),
            headerNumbers: headerNumbers,
            regionRowNumbers: regionRowNumbers ?? headerNumbers
        )
    }

    // MARK: Coverage

    /// The baseline: every rendered row has a region row, no gaps, no stacks,
    /// the scroll bar says everything fits. Nothing PROVES a row hidden — and
    /// the verdict is `unknown`, never `complete`, because a row Logic has not
    /// rendered publishes nothing at all.
    func testNothingProvedHiddenIsUnknownNotComplete() {
        let verdict = coverage(headerNumbers: Array(1...8))
        XCTAssertFalse(verdict.partial)
        XCTAssertEqual(verdict.completeness, "unknown")
        XCTAssertNotEqual(verdict.completeness, "complete")
        XCTAssertEqual(verdict.unseenTrackNumbers, [])
        XCTAssertTrue(verdict.reasons.isEmpty)
    }

    /// The sandbox project's own shape, reduced: a numbering gap where a
    /// collapsed stack's subtracks live. Both signals fire, and the missing rows
    /// are NAMED — a refusal that cannot say which rows it means is not
    /// actionable.
    func testCollapsedStackAndNumberingGapAreUnseenRows() {
        let verdict = coverage(
            headerNumbers: [1, 2, 9, 20, 21], collapsedStacks: [9]
        )
        XCTAssertTrue(verdict.partial)
        XCTAssertEqual(verdict.unseenTrackNumbers, [3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19])
        XCTAssertTrue(verdict.reasons.contains { $0.contains("collapsed track stack") })
        XCTAssertTrue(verdict.unseenSentence(for: .delete).contains("10"))
        XCTAssertTrue(verdict.unseenSentence(for: .delete).contains("Logic's Delete is project-wide"))
        // The same rows, named for the command that would actually reach them.
        XCTAssertTrue(verdict.unseenSentence(for: .nudge).contains("Logic's Nudge is project-wide"))
    }

    /// A scrolled Tracks area proves rows are out there without being able to
    /// name one. Partial all the same, and the sentence stays empty rather than
    /// inventing numbers.
    func testScrollableIsPartialWithNoNameableRows() {
        let verdict = coverage(headerNumbers: Array(1...8), scrollable: true)
        XCTAssertTrue(verdict.partial)
        XCTAssertEqual(verdict.unseenTrackNumbers, [])
        XCTAssertEqual(verdict.unseenSentence(for: .split), "")
        XCTAssertTrue(verdict.reasons.contains { $0.contains("scroll") })
    }

    /// The signal the header verdict cannot give: a track row Logic renders a
    /// HEADER for while the arrangement walk finds no region row under it. Its
    /// regions are unreadable, so it is an unseen row like any other.
    func testHeaderWithoutARegionRowCountsAsUnseen() {
        let verdict = coverage(headerNumbers: [1, 2, 3], regionRowNumbers: [1, 3])
        XCTAssertTrue(verdict.partial)
        XCTAssertEqual(verdict.unseenTrackNumbers, [2])
        XCTAssertTrue(verdict.reasons.contains { $0.contains("no rendered region row") })
    }

    /// An unreadable header column is not a clean bill of health. This is the
    /// `(try? parsedTrackHeaders()) ?? []` path, and it must not read as "no
    /// tracks are hidden".
    func testUnreadableHeaderColumnIsPartial() {
        let verdict = RegionEditGuard.coverage(
            trackVerdict: TrackListCompleteness.evaluate(rows: [], scrollable: nil),
            headerNumbers: [],
            regionRowNumbers: [1, 2, 3]
        )
        XCTAssertTrue(verdict.partial)
        XCTAssertTrue(verdict.reasons.contains { $0.contains("could not be read") })
    }

    // MARK: The plan

    /// Every command this guard fronts. Kept as a list so a new one cannot be
    /// added without the plan tests covering it.
    private static let allCommands: [RegionEditGuard.Command] =
        [.delete, .cut, .copy, .nudge, .split, .removeSilence]

    /// The whole point: with Logic's project-wide clear available, it is used —
    /// on EVERY destructive region command, not only the ones that look partial.
    /// `partial: false` means "nothing proved rows missing", and a destructive
    /// command is the last place to spend an absence of evidence as a guarantee.
    func testTheProjectWideClearIsUsedWheneverItIsAvailable() {
        for verdict in [
            coverage(headerNumbers: Array(1...8)),
            coverage(headerNumbers: [1, 2, 9, 20], collapsedStacks: [9]),
            coverage(headerNumbers: Array(1...8), scrollable: true)
        ] {
            for command in Self.allCommands {
                XCTAssertEqual(
                    RegionEditGuard.plan(
                        coverage: verdict, deselectAllRegistered: true, command: command
                    ),
                    .projectWideClear,
                    "\(command)"
                )
            }
        }
    }

    /// No project-wide clear and provably hidden rows: REFUSE, before anything
    /// is written. The message has to carry the rows and both ways out, because
    /// a refusal an agent cannot act on just becomes a retry.
    func testHiddenRowsWithoutTheClearCommandRefuse() {
        let plan = RegionEditGuard.plan(
            coverage: coverage(headerNumbers: [1, 2, 9, 20], collapsedStacks: [9]),
            deselectAllRegistered: false, command: .delete
        )
        guard case .refuse(let reason) = plan else {
            return XCTFail("expected a refusal, got \(plan)")
        }
        XCTAssertTrue(reason.contains("Refusing to fire Delete blind"))
        XCTAssertTrue(reason.contains("Nothing was deleted"))
        XCTAssertTrue(reason.contains("logic_set_track_stack"))
        XCTAssertTrue(reason.contains("logic_select_regions"))
        XCTAssertTrue(reason.contains("3, 4, 5"))
    }

    /// THE REASON THIS GUARD IS SHARED. Cut, Copy, Nudge, Split and Remove
    /// Silence refuse on the same evidence as Delete, each in its own words — a refusal that says
    /// "Delete" while the agent called `logic_split_region` is a refusal the
    /// agent will not believe.
    func testEveryCommandRefusesInItsOwnWords() {
        let hidden = coverage(headerNumbers: [1, 2, 9, 20], collapsedStacks: [9])
        let expected: [(RegionEditGuard.Command, String, String)] = [
            (.cut, "Refusing to fire Cut blind", "Nothing was cut"),
            (.copy, "Refusing to fire Copy blind", "Nothing was copied"),
            (.nudge, "Refusing to fire Nudge blind", "Nothing was moved"),
            (.split, "Refusing to fire Split blind", "Nothing was split"),
            (.removeSilence, "Refusing to fire Remove Silence blind", "Nothing was stripped")
        ]
        for (command, refusal, nothing) in expected {
            let plan = RegionEditGuard.plan(
                coverage: hidden, deselectAllRegistered: false, command: command
            )
            guard case .refuse(let reason) = plan else {
                return XCTFail("expected a refusal for \(command), got \(plan)")
            }
            XCTAssertTrue(reason.contains(refusal), reason)
            XCTAssertTrue(reason.contains(nothing), reason)
            XCTAssertTrue(reason.contains("3, 4, 5"), reason)
            XCTAssertTrue(reason.contains("logic_select_regions"), reason)
        }
    }

    /// A Copy is not destructive on its own, which is exactly the trap: the
    /// Paste that follows empties the WHOLE clipboard, so a region selected on a
    /// row nobody can see gets put down too. The refusal has to say that rather
    /// than shrug at a read-only command.
    func testCopyRefusalNamesThePasteAsTheDamage() {
        let plan = RegionEditGuard.plan(
            coverage: coverage(headerNumbers: [1, 2, 9, 20], collapsedStacks: [9]),
            deselectAllRegistered: false, command: .copy
        )
        guard case .refuse(let reason) = plan else {
            return XCTFail("expected a refusal, got \(plan)")
        }
        XCTAssertTrue(reason.contains("clipboard"), reason)
        XCTAssertTrue(reason.contains("Paste"), reason)
    }

    /// No project-wide clear and nothing proving a row hidden: go ahead, and say
    /// precisely what was checked. The warning is not decoration — it is the
    /// difference between this result and the one the tools used to give.
    func testCleanCoverageWithoutTheClearCommandProceedsWithAWarning() {
        for command in Self.allCommands {
            let plan = RegionEditGuard.plan(
                coverage: coverage(headerNumbers: Array(1...8)),
                deselectAllRegistered: false, command: command
            )
            guard case .renderedRowsOnly(let warning) = plan else {
                return XCTFail("expected rendered-rows-only for \(command), got \(plan)")
            }
            XCTAssertTrue(warning.contains("RENDERED track rows only"))
            XCTAssertTrue(warning.contains("not a project-wide proof"))
        }
    }

    // MARK: The after-check

    /// One region gone from the project's rendered total, and it is the one that
    /// was addressed.
    func testExactlyOneRegionGoneIsADelete() {
        XCTAssertEqual(
            RegionEditGuard.verify(
                targetStillPresent: false, regionsBefore: 54, regionsAfter: 53
            ),
            .deleted
        )
    }

    /// THE REGRESSION THIS FILE EXISTS FOR. The old check compared counts on the
    /// target track only, so a Delete that took the addressed region AND three
    /// on other rows read as a clean success. Across the whole rendered map it
    /// cannot: four fewer regions is collateral damage, reported as a failure.
    func testACollateralDeleteIsNeverASuccess() {
        XCTAssertEqual(
            RegionEditGuard.verify(
                targetStillPresent: false, regionsBefore: 54, regionsAfter: 50
            ),
            .collateral(alsoRemoved: 3)
        )
    }

    /// Delete took something, but not what was asked for.
    func testTheWrongRegionLeavingIsItsOwnVerdict() {
        XCTAssertEqual(
            RegionEditGuard.verify(
                targetStillPresent: true, regionsBefore: 54, regionsAfter: 53
            ),
            .wrongRegion(removed: 1)
        )
    }

    /// Nothing moved — the focus-dead Logic answer, and the poll's cue to keep
    /// looking rather than to declare anything.
    func testNothingMovedKeepsPolling() {
        XCTAssertEqual(
            RegionEditGuard.verify(
                targetStillPresent: true, regionsBefore: 54, regionsAfter: 54
            ),
            .unchanged
        )
    }

    /// A half-read snapshot — the target gone while the totals have not moved —
    /// is not a verified delete. It keeps polling; at the deadline it refuses.
    func testTargetGoneWithUnmovedTotalsIsNotYetADelete() {
        XCTAssertEqual(
            RegionEditGuard.verify(
                targetStillPresent: false, regionsBefore: 54, regionsAfter: 54
            ),
            .unchanged
        )
    }

    // MARK: The after-check — Cut, Copy, Nudge, Split

    /// A Split turns one region into two, so the PROJECT's rendered total rises
    /// by exactly one. The old check asked the target track for `before + 1`,
    /// which a Split that also cut four regions on other rows satisfies exactly.
    func testASplitAddsExactlyOneRegionToTheProject() {
        XCTAssertEqual(
            RegionEditGuard.delta(expected: 1, before: 54, after: 55), .asExpected
        )
    }

    /// THE REGRESSION FOR SPLIT. Five regions where there were 54 means Split
    /// cut more than the one this call named.
    func testASplitThatCutFourRegionsIsNotASplit() {
        XCTAssertEqual(
            RegionEditGuard.delta(expected: 1, before: 54, after: 58),
            .unexpected(actualDelta: 4)
        )
    }

    /// Nothing has moved and something was supposed to: the poll's cue to look
    /// again, not a verdict. This is what a Split fired without Tracks-area
    /// keyboard focus looks like on every read until the deadline.
    func testAnUnmovedTotalIsPendingWhenSomethingWasExpected() {
        XCTAssertEqual(RegionEditGuard.delta(expected: 1, before: 54, after: 54), .pending)
    }

    /// A Nudge moves regions and creates none, so the total staying put IS the
    /// expected answer — never `pending`, which would make the tool poll for a
    /// change that must not come.
    func testANudgeExpectsTheTotalToStayExactlyWhereItWas() {
        XCTAssertEqual(RegionEditGuard.delta(expected: 0, before: 54, after: 54), .asExpected)
    }

    /// A nudge (or a paste) that lands squarely on a neighbour can swallow it
    /// whole. The counts cannot tell that apart from a command that reached a
    /// region on a row nobody can see — so it is reported, loudly, with both
    /// causes named, instead of coming back as a clean success.
    func testANudgeThatSwallowedANeighbourIsNeverASuccess() {
        XCTAssertEqual(
            RegionEditGuard.delta(expected: 0, before: 54, after: 53),
            .unexpected(actualDelta: -1)
        )
        let sentence = RegionEditGuard.unexpectedTotalSentence(
            command: .nudge, expectedDelta: 0, before: 54, after: 53
        )
        XCTAssertTrue(sentence.contains("54 → 53"), sentence)
        XCTAssertTrue(sentence.contains("(-1)"), sentence)
        XCTAssertTrue(sentence.contains("could only ever produce +0"), sentence)
        XCTAssertTrue(sentence.contains("wider than this call made"), sentence)
        XCTAssertTrue(sentence.contains("overlaid completely"), sentence)
        XCTAssertTrue(sentence.contains("Undo restores them"), sentence)
    }

    /// A Cut+Paste is count-neutral: one region leaves the project and the same
    /// one arrives. A total that fell means the Cut took something the Paste did
    /// not bring back — the most dangerous shape `logic_copy_region` has.
    func testACutPasteKeepsTheTotalAndAMissingRegionIsLoud() {
        XCTAssertEqual(RegionEditGuard.delta(expected: 0, before: 54, after: 54), .asExpected)
        XCTAssertEqual(
            RegionEditGuard.delta(expected: 0, before: 54, after: 52),
            .unexpected(actualDelta: -2)
        )
    }

    /// A Copy+Paste adds exactly one. A total that did not move at all means the
    /// paste landed on top of a region and Logic swallowed it — reported rather
    /// than polled for, because the landing itself was already proven.
    func testACopyPasteThatConsumedItsTargetIsNotAsExpected() {
        XCTAssertEqual(RegionEditGuard.delta(expected: 1, before: 54, after: 55), .asExpected)
        XCTAssertNotEqual(RegionEditGuard.delta(expected: 1, before: 54, after: 54), .asExpected)
    }
}
