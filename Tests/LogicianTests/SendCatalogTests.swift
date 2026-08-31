import XCTest
@testable import Logician
@testable import LogicMCUBridge

/// The send-destination catalog's arithmetic, and the refusal that now names
/// what the browser held.
///
/// The numbers in the first section are not chosen — they are the jump table
/// measured off the running surface on 2026-08-31 against `Testlåt Copy`,
/// browsing the destination field of an empty send slot on `Sweeps` and
/// abandoning every browse to Pan without a press. That measurement is the
/// only reason this code may jump at all, so it is pinned here: if a future
/// change to `sendOutputCatalogEntries` or `sendBrowseTicksPerEntry` disagrees
/// with what the surface did, these fail.
final class SendCatalogTests: XCTestCase {

    // MARK: - The catalog as measured

    /// Live table, 2026-08-31: ticks sent from the `--` origin against the
    /// entry the browser then showed. One tick per entry, exact and linear.
    private let measuredLandings: [(cumulativeTicks: Int, entry: String)] = [
        (1, "Output 1"),
        (11, "Bus 3"),
        (31, "Bus 23"),
        (50, "Bus 42"),
        (61, "Bus 53"),
        (91, "Bus 83")
    ]

    func testTheMeasuredLandingsAreWhereTheArithmeticPutsThem() {
        for landing in measuredLandings {
            XCTAssertEqual(
                MCUController.sendDestinationOrdinal(landing.entry), landing.cumulativeTicks,
                "entry \(landing.entry)"
            )
        }
    }

    /// One tick per entry HERE, two in the plug-in browser. Reusing the
    /// plug-in constant would double every distance, so the two are pinned
    /// apart deliberately.
    func testThisBrowserIsOneTickPerEntryUnlikeThePluginBrowser() {
        XCTAssertEqual(MCUController.sendBrowseTicksPerEntry, 1)
        XCTAssertEqual(MCUController.browseTicksPerEntry, 2)
    }

    func testBusNIsEightEntriesPastItsOwnNumber() {
        XCTAssertEqual(MCUController.sendDestinationOrdinal("Bus 1"), 9)
        XCTAssertEqual(MCUController.sendDestinationOrdinal("Bus 12"), 20)
        XCTAssertEqual(MCUController.sendDestinationOrdinal("Bus 90"), 98)
        XCTAssertEqual(MCUController.sendDestinationOrdinal("Bus 256"), 264)
    }

    func testTheOutputsAreTheFirstEightEntries() {
        XCTAssertEqual(MCUController.sendDestinationOrdinal("Output 1"), 1)
        XCTAssertEqual(MCUController.sendDestinationOrdinal("Output 8"), 8)
        // There is no ninth output, so this is not an ordinal — it walks.
        XCTAssertNil(MCUController.sendDestinationOrdinal("Output 9"))
    }

    /// The defect this change exists to fix: the browse loop stopped at entry
    /// 80, and `Bus 73` and everything past it was refused as though it did
    /// not exist. The bound has to clear the whole catalog Logic offers.
    func testTheSearchBoundClearsTheWholeCatalogNotJustEntryEighty() {
        let busSeventyThree = MCUController.sendDestinationOrdinal("Bus 73")
        XCTAssertEqual(busSeventyThree, 81, "the old 80-step loop stopped one entry short of this")
        XCTAssertGreaterThan(MCUController.sendBrowseEntryCap, 264)
        XCTAssertGreaterThan(
            MCUController.sendBrowseEntryCap,
            MCUController.sendDestinationOrdinal("Bus 256") ?? .max
        )
    }

    // MARK: - Cutting the destination out of the row

    /// These rows are SYNTHETIC, and say so: they exercise the cut rule, and
    /// they make no claim about how Logic pads the row it paints while a
    /// destination is being browsed (`SendViewRowTests` holds the captured
    /// rows, and its captures are all TOP rows). What the rule has to do is
    /// read forward from the slot's own cell, stop at the first wide gap
    /// because a browsed name spills past its cell, and not carry a
    /// neighbour's `--` home with it.
    func testTheNameIsReadForwardFromTheSlotsOwnCellAndCutAtTheGap() {
        // Built out of 7-character cells rather than written out, so the
        // fixture cannot be a column off and quietly test the wrong thing.
        let row = ["Bus 1", "", "", "", "Bus 90", "", "", ""]
            .map { $0.padding(toLength: 7, withPad: " ", startingAt: 0) }
            .joined()
        XCTAssertEqual(row.count, MCULCDRow.length)
        XCTAssertEqual(MCUController.sendDestinationCell(row, destIndex: 0), "Bus 1")
        XCTAssertEqual(MCUController.sendDestinationCell(row, destIndex: 4), "Bus 90")
    }

    /// A name longer than its 7-character cell is the ordinary case here, not
    /// the exception: `Output 3-4` is ten characters and was browsed to and
    /// created live on 2026-08-31.
    func testANameLongerThanItsCellIsReadWhole() {
        let row = "Output 3-4                                              "
        XCTAssertEqual(row.count, MCULCDRow.length)
        XCTAssertEqual(MCUController.sendDestinationCell(row, destIndex: 0), "Output 3-4")
    }

    /// A neighbour's `--` carried into the read is the contamination that used
    /// to defeat the plug-in browser's wrap test, and it would defeat the exact
    /// name match the press is gated on here.
    func testANeighboursEmptyMarkerIsTakenBackOff() {
        XCTAssertEqual(
            MCUController.sendDestinationCell(
                "Bus 90 --                                               ", destIndex: 0
            ),
            "Bus 90"
        )
        // An empty slot is still empty: the marker is only stripped when there
        // is a name in front of it.
        XCTAssertEqual(
            MCUController.sendDestinationCell(
                "--     --                                               ", destIndex: 0
            ),
            MCULCDStrings.emptySlot
        )
    }

    // MARK: - Parsing a destination name

    func testAFamilyAndANumberComeOutOfADestinationName() {
        XCTAssertEqual(
            MCUController.parseSendDestination("Bus 12"),
            MCUController.SendDestinationName(family: "bus", number: 12)
        )
        XCTAssertEqual(
            MCUController.parseSendDestination("  Output 3  "),
            MCUController.SendDestinationName(family: "output", number: 3)
        )
    }

    /// The family is FOLDED, never translated: that is what lets the
    /// same-family arithmetic work on a Logic whose UI language spells the
    /// word differently, because both sides of the subtraction are that same
    /// word.
    func testTheFamilyIsFoldedAndNotInterpreted() {
        XCTAssertEqual(MCUController.parseSendDestination("BUS 4")?.family, "bus")
        XCTAssertEqual(MCUController.parseSendDestination("Buss 4")?.family, "buss")
        XCTAssertEqual(MCUController.parseSendDestination("Utgång 4")?.family, "utgång")
    }

    func testANameWithoutBothHalvesIsNotADestination() {
        XCTAssertNil(MCUController.parseSendDestination("Bus"))
        XCTAssertNil(MCUController.parseSendDestination("12"))
        XCTAssertNil(MCUController.parseSendDestination(MCULCDStrings.emptySlot))
        XCTAssertNil(MCUController.parseSendDestination(""))
        XCTAssertNil(MCUController.parseSendDestination("Stereo Out"))
    }

    /// A family word this build has never read off the surface gets no
    /// cold-start ordinal — it walks to the first entry of its own family and
    /// jumps from there. Nothing is guessed.
    func testAnUnmeasuredFamilyHasNoOrdinal() {
        XCTAssertNil(MCUController.sendDestinationOrdinal("Buss 90"))
        XCTAssertNil(MCUController.sendDestinationOrdinal("Utgång 2"))
        XCTAssertNil(MCUController.sendDestinationOrdinal("Bus 0"))
    }

    // MARK: - Planning the jump from what is on screen

    func testTheDeltaBetweenTwoMembersOfOneFamilyIsTheDifferenceOfTheirNumbers() {
        XCTAssertEqual(MCUController.sendJumpDelta(from: "Bus 23", to: "Bus 90"), 67)
        XCTAssertEqual(MCUController.sendJumpDelta(from: "Bus 90", to: "Bus 23"), -67)
        XCTAssertEqual(MCUController.sendJumpDelta(from: "Bus 5", to: "Bus 5"), 0)
        XCTAssertEqual(MCUController.sendJumpDelta(from: "Output 1", to: "Output 8"), 7)
    }

    /// The same arithmetic on a family word this build does not know, which is
    /// the whole point of doing it this way: no table is consulted.
    func testTheDeltaNeedsNoTableForTheFamilyItIsCounting() {
        XCTAssertEqual(MCUController.sendJumpDelta(from: "Buss 3", to: "Buss 88"), 85)
    }

    func testTwoFamiliesAreNotSubtractedFromEachOther() {
        XCTAssertNil(MCUController.sendJumpDelta(from: "Output 1", to: "Bus 90"))
        XCTAssertNil(MCUController.sendJumpDelta(from: MCULCDStrings.emptySlot, to: "Bus 90"))
        XCTAssertNil(MCUController.sendJumpDelta(from: "Bus 3", to: "Stereo Out"))
    }

    // MARK: - The messages a jump becomes

    func testAJumpFitsInsideTheVpotClamp() {
        XCTAssertEqual(MCUController.sendBrowseJumpPlan(entries: 0), [])
        XCTAssertEqual(MCUController.sendBrowseJumpPlan(entries: 10), [10])
        XCTAssertEqual(MCUController.sendBrowseJumpPlan(entries: 63), [63])
        XCTAssertEqual(MCUController.sendBrowseJumpPlan(entries: 97), [63, 34])
        XCTAssertEqual(MCUController.sendBrowseJumpPlan(entries: -97), [-63, -34])
    }

    /// `turnVPot` clamps a message at 63 ticks; a chunk over that would be
    /// silently shortened and every position after it would be wrong.
    func testEveryChunkIsWithinTheClampAndTheySumBackExactly() {
        for entries in [-264, -97, -63, -1, 1, 5, 63, 64, 126, 127, 264] {
            let plan = MCUController.sendBrowseJumpPlan(entries: entries)
            XCTAssertEqual(plan.reduce(0, +), entries, "entries: \(entries)")
            for chunk in plan {
                XCTAssertLessThanOrEqual(abs(chunk), 63, "entries: \(entries)")
                XCTAssertEqual(chunk < 0, entries < 0, "entries: \(entries)")
            }
        }
    }

    /// The whole catalog in two messages, which is the point of the change:
    /// `Bus 90` used to be unreachable at any cost.
    func testTheFarEndOfTheCatalogIsTwoMessagesAway() {
        let ordinal = MCUController.sendDestinationOrdinal("Bus 90")!
        XCTAssertEqual(MCUController.sendBrowseJumpPlan(entries: ordinal - 1).count, 2)
    }

    /// A jump is trimmed so it cannot aim past the far end of any catalog.
    /// `Bus 999` has an ordinal of 1007, and aiming there cost 16 messages and
    /// 9 s walking off the end of the list to learn what the entry the first
    /// five landed on would have said (measured live 2026-08-31).
    func testAJumpIsTrimmedToTheFarEndOfTheCatalog() {
        let cap = MCUController.sendBrowseEntryCap
        XCTAssertEqual(MCUController.sendClampedJump(1006, from: 1), cap - 1)
        XCTAssertEqual(MCUController.sendClampedJump(50, from: 10), 50)
        XCTAssertEqual(MCUController.sendClampedJump(10, from: cap), 0)
        // Backwards is never trimmed: the way home is always open.
        XCTAssertEqual(MCUController.sendClampedJump(-800, from: cap), -800)
    }

    // MARK: - Reading the send list back

    /// The send list's destination cell is six characters of Logic's own
    /// abbreviation, so an exact compare called a good write a failure —
    /// measured live 2026-08-31: `Output 3-4` was created and reported as
    /// `verification_failed` with `restored: false`, and the send was in the
    /// project the whole time. These two rows are what the surface said.
    func testTheSendListsAbbreviationIsAcceptedAsTheDestination() {
        XCTAssertTrue(MCUController.sendListDestinationMatches("Out3-4", requested: "Output 3-4"))
        XCTAssertTrue(MCUController.sendListDestinationMatches("Bus 90", requested: "Bus 90"))
        XCTAssertTrue(MCUController.sendListDestinationMatches("  Bus 90 ", requested: "bus 90"))
    }

    /// The confusion the tolerance must NOT admit: `Bus 1` is an ordered
    /// subsequence of `Bus 12`, so a bare subsequence test would accept a send
    /// to the wrong bus as proof of the right one.
    func testAShorterBusIsNotAcceptedForALongerOne() {
        XCTAssertFalse(MCUController.sendListDestinationMatches("Bus 1", requested: "Bus 12"))
        XCTAssertFalse(MCUController.sendListDestinationMatches("Bus 12", requested: "Bus 1"))
        XCTAssertFalse(MCUController.sendListDestinationMatches("Out3-4", requested: "Output 5-6"))
        XCTAssertFalse(MCUController.sendListDestinationMatches("", requested: "Bus 90"))
        XCTAssertFalse(MCUController.sendListDestinationMatches(
            MCULCDStrings.emptySlot, requested: "Bus 90"
        ))
    }

    /// A destination with no number at either end is matched on the
    /// abbreviation alone, which is all there is to go on.
    func testANumberlessDestinationIsMatchedOnItsAbbreviation() {
        XCTAssertTrue(MCUController.sendListDestinationMatches("StOutp", requested: "Stereo Output"))
        XCTAssertNil(MCUController.sendDestinationTrailingNumber("Stereo Output"))
        XCTAssertEqual(MCUController.sendDestinationTrailingNumber("Out3-4"), 4)
        XCTAssertEqual(MCUController.sendDestinationTrailingNumber("Bus 256"), 256)
    }

    // MARK: - Saying what the browser held

    private func report(
        seen: [String], tail: [String] = [], jumped: Bool = false,
        stop: MCUController.SendBrowseStop
    ) -> MCUController.SendBrowseReport {
        MCUController.SendBrowseReport(seen: seen, tail: tail, jumped: jumped, stop: stop)
    }

    /// A run of one family folds into a range, so a refusal can name the whole
    /// catalog without dumping 264 entries at the agent.
    func testConsecutiveEntriesFoldIntoARange() {
        let outputs = (1...8).map { "Output \($0)" }
        XCTAssertEqual(
            MCUController.sendCatalogSummary(outputs),
            "Output 1 … Output 8 (8 entries)"
        )
    }

    func testAGapEndsTheRunAndShortRunsAreListedInFull() {
        XCTAssertEqual(
            MCUController.sendCatalogSummary(["Output 7", "Output 8", "Bus 1", "Bus 2", "Bus 3"]),
            "Output 7, Output 8, Bus 1 … Bus 3 (3 entries)"
        )
        XCTAssertEqual(
            MCUController.sendCatalogSummary(["Output 1", "Bus 90"]),
            "Output 1, Bus 90"
        )
        XCTAssertEqual(MCUController.sendCatalogSummary([]), "nothing")
    }

    /// The defect: the refusal used to be "the destination browser never
    /// showed 'Bus 90'" and nothing else, having just enumerated the catalog
    /// and thrown it away. Every ending now names what was seen.
    func testEveryRefusalNamesWhatTheBrowserActuallyHeld() {
        let seen = (1...8).map { "Output \($0)" } + (1...4).map { "Bus \($0)" }
        for stop in [MCUController.SendBrowseStop.listEnded, .wrapped, .entryCap, .timeBudget] {
            let text = MCUController.sendDestinationRefusalText(
                requested: "Bus 90", report: report(seen: seen, stop: stop)
            )
            XCTAssertTrue(text.contains("Output 1 … Output 8 (8 entries)"), "\(stop): \(text)")
            XCTAssertTrue(text.contains("Bus 1 … Bus 4 (4 entries)"), "\(stop): \(text)")
            XCTAssertTrue(text.contains("Nothing was written"), "\(stop): \(text)")
        }
    }

    /// "The list ends here, so there is no Bus 300" and "I ran out of time and
    /// the list goes on" are opposite pieces of advice, so the two endings must
    /// not read alike.
    func testTheEndOfTheListIsReportedAsTheEndAndNamesTheLastEntry() {
        let text = MCUController.sendDestinationRefusalText(
            requested: "Bus 300",
            report: report(seen: ["Output 1", "Bus 128"], jumped: true, stop: .listEnded)
        )
        XCTAssertTrue(text.contains("ends at 'Bus 128'"), text)
        XCTAssertTrue(text.contains("highest 'bus' in it is 128"), text)
        XCTAssertFalse(text.contains("may well go on"), text)
    }

    func testACutShortSearchSaysTheListMayGoOnAndWhichBoundStoppedIt() {
        let seen = (1...8).map { "Output \($0)" }
        let budget = MCUController.sendDestinationRefusalText(
            requested: "Plate", report: report(seen: seen, stop: .timeBudget)
        )
        XCTAssertTrue(budget.contains("never reached the end of its list"), budget)
        XCTAssertTrue(budget.contains("in the 8 entries this browse read"), budget)
        XCTAssertTrue(budget.contains("\(Int(MCUController.sendBrowseSearchBudget)) s"), budget)

        let cap = MCUController.sendDestinationRefusalText(
            requested: "Plate", report: report(seen: seen, stop: .entryCap)
        )
        XCTAssertTrue(cap.contains("\(MCUController.sendBrowseEntryCap)-entry limit"), cap)

        // One entry read is "1 entry", not "1 entries".
        let single = MCUController.sendDestinationRefusalText(
            requested: "Plate", report: report(seen: ["Output 1"], stop: .timeBudget)
        )
        XCTAssertTrue(single.contains("in the 1 entry this browse read"), single)
    }

    /// The live catalog, read off the surface 2026-08-31: `Output 1`…`Output 8`,
    /// `Bus 1`…`Bus 256`, `Stereo Output`, `Output 3-4`, `Output 5-6`,
    /// `Output 7-8` — 268 entries, ending in the stereo pairs rather than in a
    /// bus. So a browse that jumps off the end lands FOUR entries past the last
    /// bus, and "the list ends at 'Output 7-8'" is true and no use at all to
    /// someone who asked for `Bus 999`. Reading the tail back is what turns
    /// that refusal into an answer.
    ///
    /// The tail below is verbatim what the live refusal reported.
    func testTheTailNamesTheHighestBusEvenThoughTheListEndsInOutputs() {
        let text = MCUController.sendDestinationRefusalText(
            requested: "Bus 999",
            report: report(
                seen: ["Output 1", "Output 7-8"],
                tail: ["Bus 254", "Bus 255", "Bus 256",
                       "Stereo Output", "Output 3-4", "Output 5-6", "Output 7-8"],
                jumped: true, stop: .listEnded
            )
        )
        XCTAssertTrue(text.contains("ends at 'Output 7-8'"), text)
        XCTAssertTrue(text.contains("highest 'bus' in it is 256"), text)
        XCTAssertTrue(
            text.contains("Its last entries are Bus 254 … Bus 256 (3 entries), Stereo Output"),
            text
        )
    }

    /// `Stereo Output` carries no number at all, so it is nobody's family
    /// member and nothing is ever subtracted from it.
    func testTheMainStereoPairIsNotANumberedDestination() {
        XCTAssertNil(MCUController.parseSendDestination("Stereo Output"))
        XCTAssertNil(MCUController.sendJumpDelta(from: "Stereo Output", to: "Bus 90"))
    }

    /// A stereo output PAIR is not member 8 of a family called `output 7-`.
    /// Reading it as one would let the arithmetic subtract it from `Output 3`.
    func testAStereoOutputPairIsNotAMemberOfANumberedFamily() {
        XCTAssertNil(MCUController.parseSendDestination("Output 7-8"))
        XCTAssertNil(MCUController.parseSendDestination("Output 1-2"))
        XCTAssertNil(MCUController.sendJumpDelta(from: "Output 7-8", to: "Output 3"))
        XCTAssertNil(MCUController.sendDestinationOrdinal("Output 7-8"))
    }

    /// A browse that jumped has holes in what it saw, and the refusal must not
    /// present its list as an enumeration.
    func testAJumpedBrowseAdmitsTheEntriesItSkipped() {
        let jumped = MCUController.sendDestinationRefusalText(
            requested: "Bus 300",
            report: report(seen: ["Output 1", "Bus 128"], jumped: true, stop: .listEnded)
        )
        XCTAssertTrue(jumped.contains("jumped ahead"), jumped)
        let walked = MCUController.sendDestinationRefusalText(
            requested: "Bus 300",
            report: report(seen: ["Output 1", "Bus 128"], stop: .listEnded)
        )
        XCTAssertFalse(walked.contains("jumped ahead"), walked)
    }

    /// The refusal is the `exposed` half of a `not_exposed` error, so it is
    /// read straight after "Send destination 'Bus 300' is not available." —
    /// which is the same shape `logic_set_track_routing` refuses an unknown
    /// destination in.
    func testTheRefusalReadsAsTheSecondHalfOfTheSentence() {
        let text = MCUController.sendDestinationRefusalText(
            requested: "Bus 300",
            report: report(seen: ["Bus 128"], stop: .listEnded)
        )
        XCTAssertEqual(text.first?.isUppercase, false, text)
        XCTAssertFalse(text.hasSuffix("."), text)
    }
}
