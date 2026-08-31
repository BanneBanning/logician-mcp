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

    /// The TOP rows below are verbatim captures — the same ones
    /// `SendViewRowTests` documents — because the top row is the half that
    /// decides this read: it is what tells a browse (banner up, name allowed to
    /// spill past its cell) from a settled slot (every cell labelled, the
    /// neighbours are other fields). The bottom rows are built from 7-character
    /// cells, and the settled one is the row the live
    /// `logic_remove_send` failure of 2026-08-31 quoted back
    /// (*"the field reads 'Bus 90 -oodB  PosPan active'"*).
    private let browsingSlot1Top =
        "Send 1 Destination   -      Sen2In -      -      -      "
    private let settledSlot1Top =
        "Sen1In Send 1 Sen1Po Sen1Mu Sen2In -      -      -      "
    private let browsingSlot2Top =
        "Sen1In Send 1 Sen1Po Sen1Mu Send 2 Destination   -      "

    private func row(_ cells: [String]) -> String {
        let padded = cells.map { $0.padding(toLength: 7, withPad: " ", startingAt: 0) }.joined()
        return padded.padding(toLength: MCULCDRow.length, withPad: " ", startingAt: 0)
    }

    /// A browsed name spills past its own cell — `Output 3-4` is ten characters
    /// and a cell holds six — and the banner leaves the cells it spills into
    /// unlabelled, which is the licence to read on.
    func testABrowsedNameIsReadOnPastItsOwnCell() {
        let bottom = row(["Output", "3-4", "", "", "", "", "", ""])
        XCTAssertEqual(
            MCUController.sendDestinationCell(top: browsingSlot1Top, bottom: bottom, destIndex: 0),
            "Output 3-4"
        )
    }

    /// The live failure this read exists to end: a SETTLED slot's neighbours
    /// are its level, position and status, and reading on into them returned
    /// the whole field group as though it were the destination's name.
    func testASettledSlotStopsAtItsOwnCell() {
        let bottom = row(["Bus 90", "-oodB", "PosPan", "active", "", "", "", ""])
        XCTAssertEqual(bottom.prefix(28), "Bus 90 -oodB  PosPan active ")
        XCTAssertEqual(
            MCUController.sendDestinationCell(top: settledSlot1Top, bottom: bottom, destIndex: 0),
            "Bus 90"
        )
    }

    /// Slot 2's group starts at cell 4, and send 1's settled fields must not
    /// leak into it in either direction.
    func testTheSecondSlotIsReadAtItsOwnFieldGroup() {
        let bottom = row(["Bus 1", "-12,2", "Post", "active", "Stereo", "Output", "", ""])
        XCTAssertEqual(
            MCUController.sendDestinationCell(top: browsingSlot2Top, bottom: bottom, destIndex: 4),
            "Stereo Output"
        )
        XCTAssertEqual(
            MCUController.sendDestinationCell(top: browsingSlot2Top, bottom: bottom, destIndex: 0),
            "Bus 1"
        )
    }

    /// A name that spills mid-word comes back as Logic spelled it: the text is
    /// sliced out of the raw row, not rejoined from trimmed cells with invented
    /// spaces. A cell is seven characters, so `Compressor` breaks after
    /// `Compres` — there is no space at the boundary to rejoin on.
    func testANameThatSpillsMidWordIsNotGivenASpace() {
        let bottom = row(["Compres", "sor", "", "", "", "", "", ""])
        XCTAssertEqual(
            MCUController.sendDestinationCell(top: browsingSlot1Top, bottom: bottom, destIndex: 0),
            "Compressor"
        )
    }

    /// An empty slot reads as the empty marker, and a neighbour's marker is
    /// never read as part of a name — the contamination that used to defeat the
    /// plug-in browser's wrap test, and that would defeat the exact name match
    /// the confirming press is gated on here.
    func testPlaceholdersAreNotReadAsPartOfAName() {
        let empty = row([MCULCDStrings.emptySlot, MCULCDStrings.emptySlot, "", "", "", "", "", ""])
        XCTAssertEqual(
            MCUController.sendDestinationCell(top: browsingSlot1Top, bottom: empty, destIndex: 0),
            MCULCDStrings.emptySlot
        )
        let named = row(["Bus 90", MCULCDStrings.emptySlot, "", "", "", "", "", ""])
        XCTAssertEqual(
            MCUController.sendDestinationCell(top: browsingSlot1Top, bottom: named, destIndex: 0),
            "Bus 90"
        )
        let clearing = row(["Bus 90", MCULCDStrings.clearingCell, "", "", "", "", "", ""])
        XCTAssertEqual(
            MCUController.sendDestinationCell(top: browsingSlot1Top, bottom: clearing, destIndex: 0),
            "Bus 90"
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
    /// abbreviation, so the exact compare the add's readback used called a good
    /// write a failure — measured live 2026-08-31: `Output 3-4` was created and
    /// reported as `verification_failed` with `restored: false`, and the send
    /// was in the project the whole time. `sendDestinationMatches` is the one
    /// matcher both ends of the send tools use; `SendRemovalTests` pins the
    /// removal's side of the same contract.
    func testTheSendListsAbbreviationIsAcceptedAsTheDestination() {
        XCTAssertTrue(MCUController.sendDestinationMatches(
            requested: "Output 3-4", listed: "Out3-4"
        ))
        XCTAssertTrue(MCUController.sendDestinationMatches(requested: "Bus 90", listed: "Bus 90"))
        XCTAssertTrue(MCUController.sendDestinationMatches(requested: "bus 90", listed: "Bus 90"))
    }

    /// The frame that actually caused the false failure: while the browse
    /// banner is still up, the slot's cell holds the first seven characters of
    /// the browsed name. `Output` is an ordered subsequence of `Output 3-4`, so
    /// only the trailing number keeps a repaint frame from passing as a
    /// verified send.
    func testATruncatedRepaintFrameIsNotProofOfASettledSend() {
        XCTAssertFalse(MCUController.sendDestinationMatches(
            requested: "Output 3-4", listed: "Output"
        ))
        XCTAssertFalse(MCUController.sendDestinationMatches(
            requested: "Bus 100", listed: "Bus 10"
        ))
    }

    /// Live, 2026-08-31: a send created to `Bus 200` is listed as `B 200` —
    /// Logic abbreviates past the space once the name needs more than the
    /// cell's six content characters. Nothing shorter than `Bus 100` does, which
    /// is why this only became reachable when the add browse stopped stopping at
    /// `Bus 72`.
    func testTheHeavierAbbreviationOfADeepBusIsAccepted() {
        XCTAssertTrue(MCUController.sendDestinationMatches(requested: "Bus 200", listed: "B 200"))
        XCTAssertTrue(MCUController.sendDestinationMatches(requested: "Bus 100", listed: "Bus100"))
        // And still not across numbers.
        XCTAssertFalse(MCUController.sendDestinationMatches(requested: "Bus 200", listed: "B 20"))
        XCTAssertFalse(MCUController.sendDestinationMatches(requested: "Bus 20", listed: "B 200"))
    }

    func testTheTrailingNumberIsReadOffEitherSpelling() {
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
