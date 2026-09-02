import Foundation
import LogicMCUBridge
import XCTest
@testable import Logician

/// The two ends of a control-surface bank walk, as DECISIONS rather than as
/// counts.
///
/// The walk used to be `for _ in 0..<8` going left and `for _ in 0..<10` going
/// right, neither with a branch for running out. On the reference project (26
/// strips, 4 banks) both caps are comfortably out of reach, so nothing in this
/// repo could ever reach one — which is exactly why a project past 64 strips
/// got a census numbered from the wrong bank, and one past 80 strips a
/// truncated one, both reported as a plain `success: true`, for as long as
/// they did.
///
/// These are the synthetic bank sequences no live test can produce: 4 banks
/// (the reference project), 8 (the old left-hand cap, exactly), 9 (one past
/// it — the first size the old walk got wrong) and 11 (one past the old
/// right-hand cap).
final class BankWalkBoundsTests: XCTestCase {

    // MARK: - Synthetic surfaces

    /// A project of `banks` banks as the surface shows them: every bank a
    /// distinct row, and the last one CLAMPED (Logic's rightmost bank re-shows
    /// the previous bank's tail, which is what makes "the row stopped
    /// changing" the end-of-list proof).
    private func bankRows(_ banks: Int) -> [String] {
        (0..<banks).map { bank in
            (0..<8).map { channel in
                let strip = bank * 8 + channel
                return "S\(strip)".padding(toLength: 7, withPad: " ", startingAt: 0)
            }.joined()
        }
    }

    /// Walks a synthetic surface exactly as `resetToLeftmostBank` does, with
    /// the pure decision functions in the loop and the surface's answers
    /// supplied by the model rather than by Logic.
    ///
    /// `standingOn` is the bank the surface starts on. A `bank_left` at the
    /// edge produces no event and leaves the row alone; anywhere else it moves
    /// and Logic answers.
    private func walkLeft(
        from standingOn: Int, of banks: Int, cap: Int = MCUController.leftEdgeWalkCap
    ) -> (presses: Int, landedOn: Int?) {
        let rows = bankRows(banks)
        var bank = standingOn
        var presses = 0
        while presses < cap {
            let rowBefore = rows[bank]
            let atEdge = bank == 0
            if !atEdge { bank -= 1 }
            presses += 1
            let rowAfter = rows[bank]
            let answered = !atEdge
            guard MCUController.bankLeftLooksLikeEdge(
                rowBefore: rowBefore, rowAfter: rowAfter, answered: answered
            ) else { continue }
            // The confirming window: quiet, and the row still the one we
            // pressed from.
            if MCUController.leftEdgeConfirmed(
                rowBefore: rowBefore, rowNow: rows[bank], quiet: true, unchangedFor: 0
            ) {
                return (presses, bank)
            }
        }
        return (presses, nil)
    }

    /// Walks right exactly as `scanBanks` does: append, press, and stop only
    /// when the row proves it will not change again.
    private func walkRight(of banks: Int, cap: Int = MCUController.bankScanCap) -> (tops: [String], provenEnd: Bool) {
        let rows = bankRows(banks)
        var bank = 0
        var tops: [String] = []
        while tops.count < cap {
            tops.append(rows[bank])
            let previous = rows[bank]
            if bank < banks - 1 { bank += 1 }
            // `.unchanged` when the press did not move the surface.
            if rows[bank] == previous { return (tops, true) }
        }
        return (tops, false)
    }

    // MARK: - The left edge

    func testTheWalkLeftStopsAtTheEdgeAndNotAtACount() {
        for banks in [4, 8, 9, 11] {
            for standingOn in 0..<banks {
                let walk = walkLeft(from: standingOn, of: banks)
                XCTAssertEqual(
                    walk.landedOn, 0,
                    "a \(banks)-bank project standing on bank \(standingOn) did not reach the left edge"
                )
                // One press per bank travelled, plus the one that finds the
                // edge. The old walk always spent eight, whatever the distance.
                XCTAssertEqual(walk.presses, standingOn + 1)
            }
        }
    }

    /// The defect, stated as the number it turns on: nine banks is 72 strips,
    /// and eight blind presses from bank 8 land on bank 0 — but from bank 10
    /// of an eleven-bank project they land on bank 2, and everything numbered
    /// from there is wrong. The proven walk does not care how far it is.
    func testTheOldEightPressCapMissedTheEdgePastSixtyFourStrips() {
        // Exactly at the old cap: eight presses were just enough from bank 8.
        XCTAssertEqual(walkLeft(from: 8, of: 9).presses, 9)
        // One bank further out and the old count fell short by two.
        let deep = walkLeft(from: 10, of: 11)
        XCTAssertEqual(deep.landedOn, 0)
        XCTAssertEqual(deep.presses, 11)
        XCTAssertGreaterThan(deep.presses, 8, "the old blind count would have stopped on bank 2")
    }

    func testAWalkThatNeverFindsAnEdgeIsReportedRatherThanAssumedArrived() {
        // A surface that keeps moving forever: the cap is reached and the
        // walk says so instead of pretending it is home.
        let walk = walkLeft(from: 3, of: 4, cap: 2)
        XCTAssertNil(walk.landedOn)
        XCTAssertEqual(walk.presses, 2)
    }

    // MARK: - The edge decision itself

    func testAPressLooksLikeTheEdgeOnlyWhenBOTHWitnessesAgree() {
        let row = "Bas    808    Inst 2 Drums  Fill   AckSlg IvnSlg Vocals "
        let other = "DrSyKi Vocals IvnVoc IvnVoc IvanFx AckVoc Sweeps Crash  "
        // No event and the row held: the edge.
        XCTAssertTrue(MCUController.bankLeftLooksLikeEdge(rowBefore: row, rowAfter: row, answered: false))
        // Logic answered: it moved, whatever the row says.
        XCTAssertFalse(MCUController.bankLeftLooksLikeEdge(rowBefore: row, rowAfter: row, answered: true))
        // The row moved: it moved, whatever the events say. This is the
        // export_stems fix's objection — `timed_out` alone is not proof.
        XCTAssertFalse(MCUController.bankLeftLooksLikeEdge(rowBefore: row, rowAfter: other, answered: false))
        XCTAssertFalse(MCUController.bankLeftLooksLikeEdge(rowBefore: row, rowAfter: other, answered: true))
    }

    func testTheConfirmingWindowRulesOutALateAnswer() {
        let row = "Bas    808    Inst 2 Drums  Fill   AckSlg IvnSlg Vocals "
        let other = "DrSyKi Vocals IvnVoc IvnVoc IvanFx AckVoc Sweeps Crash  "
        // The ordinary case: quiet, row unchanged.
        XCTAssertTrue(MCUController.leftEdgeConfirmed(
            rowBefore: row, rowNow: row, quiet: true, unchangedFor: 0
        ))
        // The hazard: the press DID move a bank and Logic said so late. The
        // row that comes back is a different one, so the edge is not proven
        // and the walk keeps going.
        XCTAssertFalse(MCUController.leftEdgeConfirmed(
            rowBefore: row, rowNow: other, quiet: true, unchangedFor: 99
        ))
        // Logic will not go quiet (a record-armed strip blinks its LED
        // forever). A row that has not moved for a second is the second
        // proof — the same rule `settledTop` and `ensurePanNames` use.
        XCTAssertFalse(MCUController.leftEdgeConfirmed(
            rowBefore: row, rowNow: row, quiet: false, unchangedFor: 0.4
        ))
        XCTAssertTrue(MCUController.leftEdgeConfirmed(
            rowBefore: row, rowNow: row,
            quiet: false, unchangedFor: MCUController.motionlessRowProofSeconds
        ))
    }

    // MARK: - The right-hand end

    func testTheScanStopsOnTheClampAndReadsEveryBank() {
        for banks in [4, 8, 9, 11] {
            let walk = walkRight(of: banks)
            XCTAssertTrue(walk.provenEnd, "\(banks) banks: the scan did not reach a proven end")
            XCTAssertEqual(
                walk.tops.count, banks,
                "\(banks) banks: the scan read \(walk.tops.count)"
            )
        }
    }

    /// Eleven banks is 88 strips, and the old `for _ in 0..<10` read ten of
    /// them and returned `success: true`. The cap is now 128 and, more to the
    /// point, reaching it is a different answer from finishing.
    func testRunningOutOfLoopIsNotTheSameAnswerAsReachingTheEnd() {
        let truncated = walkRight(of: 11, cap: 10)
        XCTAssertFalse(truncated.provenEnd, "the old cap would have reported a complete census")
        XCTAssertEqual(truncated.tops.count, 10)

        let complete = walkRight(of: 11)
        XCTAssertTrue(complete.provenEnd)
        XCTAssertEqual(complete.tops.count, 11)
    }

    func testTheCapIsWellPastAnyRealProject() {
        XCTAssertGreaterThanOrEqual(MCUController.bankScanCap, 64)
        XCTAssertGreaterThanOrEqual(MCUController.leftEdgeWalkCap, 32)
    }

    /// The census's strip numbering, walked end to end on a synthetic surface
    /// too big for the old caps: this is the answer the shifted walk used to
    /// get wrong without saying so.
    func testStripNumbersAreRightOnASurfaceBiggerThanTheOldCaps() {
        for banks in [4, 8, 9, 11] {
            let tops = walkRight(of: banks).tops
            let inventory = MCUController.stripInventory(bankTops: tops)
            XCTAssertEqual(inventory.count, banks * 8)
            XCTAssertEqual(inventory.first?.cell, "S0")
            XCTAssertEqual(inventory.last?.cell, "S\(banks * 8 - 1)")
            for (index, entry) in inventory.enumerated() {
                XCTAssertEqual(entry.position, index + 1)
                XCTAssertEqual(entry.bank, index / 8)
                XCTAssertEqual(entry.channel, index % 8)
            }
        }
    }

    // MARK: - The end-of-scan probe (one silence round, not two)

    func testASilentPressNeedsOneQuietRoundAndAnAnsweredOneNeedsTwo() {
        // The press produced no MIDI at all: there was never anything in
        // flight, so the second 200 ms round proves nothing new.
        XCTAssertEqual(
            MCUController.quietRoundsRequired(eventsBeforePress: 4_200, eventsNow: 4_200), 1
        )
        // Logic said something: the row may still be on its way.
        XCTAssertEqual(
            MCUController.quietRoundsRequired(eventsBeforePress: 4_200, eventsNow: 4_207), 2
        )
        // No evidence offered, or the mirror could not give a count: the
        // conservative two rounds, exactly as before.
        XCTAssertEqual(MCUController.quietRoundsRequired(eventsBeforePress: nil, eventsNow: 4_200), 2)
        XCTAssertEqual(MCUController.quietRoundsRequired(eventsBeforePress: -1, eventsNow: -1), 2)
    }

    // MARK: - The leftover control banner

    func testAControlBannerInTheFirstBanksRowIsSpotted() {
        // Solo `Bas` and Logic paints `Solo` over that strip's name cell and
        // leaves it there (measured 2026-09-02) — the row the census reads
        // straight after presses Logic ignored.
        let bannered = "LofPad Solo   808    Inst 2 Drums  Fill   AckSlg IvnSlg "
        XCTAssertEqual(MCUController.controlBannerCell(in: bannered), "Solo")

        let clean = "LofPad Bas    808    Inst 2 Drums  Fill   AckSlg IvnSlg "
        XCTAssertNil(MCUController.controlBannerCell(in: clean))
    }

    func testANameThatMerelyCONTAINSAControlWordIsNotABanner() {
        // The banner REPLACES the cell; it does not decorate it. `Solo Gtr`
        // and `Mutes` are strip names and must not send the scan off to
        // repaint a row for nothing.
        let names = "SoloGt Mutes  SelectsBas    808    Drums  Fill   Vocals "
        XCTAssertNil(MCUController.controlBannerCell(in: names))
    }

    /// The banner is not a bank-1 problem. Measured 2026-09-02, a `Solo` left
    /// over from an unsolo rode through THREE consecutive bank steps and was
    /// published as a strip name in each of them, so the check runs on every
    /// bank's row.
    func testTheBannerIsSpottedOnAnyBanksRowNotJustTheFirst() {
        let rows = [
            "LofPad Bas    808    Inst 2 Drums  Fill   AckSlg IvnSlg ",
            "DrSyKi Solo   IvnVoc IvnVoc IvanFx AckVoc Sweeps Crash  ",
            "Vinyl  Audio8 Audio9 Aux 1  Aux 2  Aux 3  SP/1.3 St Out "
        ]
        XCTAssertEqual(rows.compactMap(MCUController.controlBannerCell(in:)), ["Solo"])
    }

    /// The budget has to outlast the banner with room to spare, counted from
    /// the moment it is first SEEN rather than from the press.
    func testTheFadeBudgetOutlastsTheMeasuredBanner() {
        let longestMeasuredStand = 1.994
        XCTAssertGreaterThan(MCUController.controlBannerFadeBudget, longestMeasuredStand * 1.4)
    }

    /// A banner breaks more than one name: it also stops `clampOverlap` from
    /// recognizing the rightmost bank's re-shown tail, so the census invents
    /// the seven strips the clamp is there to remove. Measured live: 32 strips
    /// reported for a 25-strip project.
    func testABannerInflatesTheStripCountByBreakingTheClamp() {
        let clean = [
            "LofPad Bas    808    Inst 2 Drums  Fill   AckSlg IvnSlg ",
            "DrSyKi Vocals IvnVoc IvnVoc IvanFx AckVoc Sweeps Crash  ",
            "Vinyl  Audio8 Audio9 Aux 1  Aux 2  Aux 3  SP/1.3 St Out ",
            "Audio8 Audio9 Aux 1  Aux 2  Aux 3  SP/1.3 St Out Master "
        ]
        XCTAssertEqual(MCUController.stripInventory(bankTops: clean).count, 25)

        var bannered = clean
        bannered[2] = "Vinyl  Solo   Audio9 Aux 1  Aux 2  Aux 3  SP/1.3 St Out "
        XCTAssertEqual(MCUController.stripInventory(bankTops: bannered).count, 32)
        XCTAssertNotNil(bannered.compactMap(MCUController.controlBannerCell(in:)).first)
    }

    func testEveryBannerSpellingIsCheckedAndNoneIsBlank() {
        for banner in MCULCDStrings.controlNameBanners {
            XCTAssertFalse(banner.isEmpty)
            XCTAssertEqual(banner, banner.trimmingCharacters(in: .whitespaces), "'\(banner)' is padded")
            let row = ([banner] + Array(repeating: "Bas", count: 7))
                .map { $0.padding(toLength: 7, withPad: " ", startingAt: 0) }
                .joined()
            XCTAssertEqual(MCUController.controlBannerCell(in: row), banner)
        }
    }
}
