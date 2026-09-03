import XCTest
@testable import Logician

/// The pure decisions behind `logic_set_cycle_range`'s mouse-free write route:
/// recognising the LCD's locator cells, pairing them, never inverting them,
/// and the sentences the refusals are made of.
///
/// The writes themselves need a live Accessibility tree (the CI grep forbids
/// one here); what is pinned is everything that decides WITHOUT one — and the
/// one decision that used to be made with a synthetic mouse drag.
final class LocatorCellsTests: XCTestCase {

    // MARK: - Recognising a cell

    /// A locator cell names its own value, in digits, in every language.
    func testACellIsRecognisedByItsDigits() {
        XCTAssertTrue(LocatorCells.isCellDescription("0005  1  1  001"))
        XCTAssertTrue(LocatorCells.isCellDescription("  0026  1  1  001  "))
        XCTAssertTrue(LocatorCells.isCellDescription("1"))
    }

    /// The position display sits right next to the locators and is described
    /// in words — in English here, in French on a French Logic. Neither is
    /// ever mistaken for a locator cell.
    func testAWordyNeighbourIsNotACell() {
        XCTAssertFalse(LocatorCells.isCellDescription("Playhead Position"))
        XCTAssertFalse(LocatorCells.isCellDescription("Position de la tête de lecture"))
        XCTAssertFalse(LocatorCells.isCellDescription("4 bars "))
        XCTAssertFalse(LocatorCells.isCellDescription(""))
        XCTAssertFalse(LocatorCells.isCellDescription("   "))
    }

    func testTheBarIsTheCellsLeadingNumber() {
        XCTAssertEqual(LocatorCells.bar(inCellDescription: "0005  1  1  001"), 5)
        XCTAssertEqual(LocatorCells.bar(inCellDescription: "0026  1  1  001"), 26)
        XCTAssertEqual(LocatorCells.bar(inCellDescription: " 0141  4  2  120 "), 141)
        XCTAssertNil(LocatorCells.bar(inCellDescription: "Playhead Position"))
    }

    // MARK: - Pairing (a second pair of locators must not be half-written)

    /// MEASURED 2026-09-03: both cycle locator cells sit at x 615, the left at
    /// y 63 and the right at y 85.
    func testTheTwoCellsOfOneColumnArePairedTopToBottom() {
        let pairs = LocatorCells.pairs(frames: [
            CGRect(x: 615, y: 85, width: 150, height: 25),
            CGRect(x: 615, y: 63, width: 150, height: 25)
        ])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.top, 1)
        XCTAssertEqual(pairs.first?.bottom, 0)
    }

    /// Logic's Customize Control Bar and Display can put the Punch locators
    /// beside the cycle ones. Pairing by COLUMN is what keeps one locator of
    /// each pair from being read as a pair of its own.
    func testASecondColumnIsASecondPairNotAMixedOne() {
        let pairs = LocatorCells.pairs(frames: [
            CGRect(x: 615, y: 63, width: 150, height: 25),
            CGRect(x: 615, y: 85, width: 150, height: 25),
            CGRect(x: 790, y: 63, width: 150, height: 25),
            CGRect(x: 790, y: 85, width: 150, height: 25)
        ])
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs.map { $0.top }, [0, 2])
        XCTAssertEqual(pairs.map { $0.bottom }, [1, 3])
    }

    /// A column of one, or of three, is not a locator pair — and guessing
    /// which two of the three belong together is how a tool writes into the
    /// wrong locator.
    func testAColumnThatIsNotAPairIsDropped() {
        XCTAssertTrue(LocatorCells.pairs(frames: [CGRect(x: 615, y: 63, width: 150, height: 25)]).isEmpty)
        XCTAssertTrue(LocatorCells.pairs(frames: [
            CGRect(x: 615, y: 63, width: 150, height: 25),
            CGRect(x: 615, y: 85, width: 150, height: 25),
            CGRect(x: 615, y: 107, width: 150, height: 25)
        ]).isEmpty)
    }

    func testACellAFewPixelsOffStillCountsAsTheSameColumn() {
        let pairs = LocatorCells.pairs(frames: [
            CGRect(x: 615, y: 63, width: 150, height: 25),
            CGRect(x: 618, y: 85, width: 150, height: 25)
        ])
        XCTAssertEqual(pairs.count, 1)
    }

    // MARK: - Which pair is the cycle's

    func testOnePairNeedsNoWitness() {
        XCTAssertEqual(LocatorCells.cyclePair(spans: [4], regionLengthBars: nil), 0)
    }

    /// The ruler's cycle region says how many bars the cycle spans; only the
    /// cycle locators can span exactly that.
    func testTheRulerPicksTheCyclePairOutOfTwo() {
        XCTAssertEqual(LocatorCells.cyclePair(spans: [4, 8], regionLengthBars: 8), 1)
        XCTAssertEqual(LocatorCells.cyclePair(spans: [4, 8], regionLengthBars: 4), 0)
    }

    /// Nothing here guesses: no witness, or two pairs that both match it, and
    /// the caller refuses instead of moving the user's punch locators.
    func testAnUndecidablePairIsNotGuessed() {
        XCTAssertNil(LocatorCells.cyclePair(spans: [4, 8], regionLengthBars: nil))
        XCTAssertNil(LocatorCells.cyclePair(spans: [4, 4], regionLengthBars: 4))
        XCTAssertNil(LocatorCells.cyclePair(spans: [4, 8], regionLengthBars: 6))
        XCTAssertNil(LocatorCells.cyclePair(spans: [], regionLengthBars: 4))
    }

    // MARK: - Never an inverted pair

    /// An inverted pair is Logic's SKIP cycle — a different feature, measured
    /// 2026-09-03 (the ruler's cycle region then publishes an EMPTY size
    /// description and the Cycle button reads 4). So the locator that moves
    /// first is the one that cannot cross the other.
    func testTheOrderIsTheOneThatCannotCross() {
        XCTAssertEqual(LocatorCells.writeOrder(currentRight: 9, startBar: 5), .left)
        XCTAssertEqual(LocatorCells.writeOrder(currentRight: 9, startBar: 20), .right)
        XCTAssertEqual(LocatorCells.writeOrder(currentRight: 9, startBar: 9), .right)
    }

    /// The property that matters: whatever the current range and whatever is
    /// asked for, the left locator is never at or past the right one — not at
    /// the end, and not between the two legs either.
    func testNeitherLegEverInvertsThePair() {
        for currentLeft in 1...12 {
            for currentRight in (currentLeft + 1)...13 {
                for startBar in 1...12 {
                    for endBar in (startBar + 1)...13 {
                        var left = currentLeft
                        var right = currentRight
                        switch LocatorCells.writeOrder(currentRight: right, startBar: startBar) {
                        case .left:
                            left = startBar
                            XCTAssertLessThan(left, right, "left leg first inverted \(currentLeft)-\(currentRight) → \(startBar)-\(endBar)")
                            right = endBar
                        case .right:
                            right = endBar
                            XCTAssertLessThan(left, right, "right leg first inverted \(currentLeft)-\(currentRight) → \(startBar)-\(endBar)")
                            left = startBar
                        }
                        XCTAssertEqual(left, startBar)
                        XCTAssertEqual(right, endBar)
                    }
                }
            }
        }
    }

    // MARK: - A locator on a bar line

    /// The range this tool sets is whole bars, so a locator that still carries
    /// a beat, a division or a tick is not where it was asked to be — and the
    /// verification says so rather than reporting the bar alone.
    func testOnlyAWholeBarLocatorCountsAsOnItsLine() {
        func reading(beat: Int = 1, division: Int = 1, tick: Int = 1) -> LogicAccessibility.LocatorReading {
            LogicAccessibility.LocatorReading(
                bar: 5, beat: beat, division: division, tick: tick, text: "0005  1  1  001"
            )
        }
        XCTAssertTrue(reading().isOnBarLine)
        XCTAssertFalse(reading(beat: 3).isOnBarLine)
        XCTAssertFalse(reading(division: 2).isOnBarLine)
        XCTAssertFalse(reading(tick: 120).isOnBarLine)
    }

    // MARK: - What the caller is told

    func testTheRangeReadsAsBars() {
        XCTAssertEqual(LocatorCells.rangeText(startBar: 5, endBar: 9), "bars 5-9")
    }

    /// Where a failed restore left things is QUOTED from the cells, not
    /// derived — the derivation may be exactly what went wrong.
    func testAnUnrestoredRangeQuotesTheCells() {
        let text = LocatorCells.rangeText(left: " 0020  1  1  001 ", right: "0026  1  1  001")
        XCTAssertTrue(text.contains("0020  1  1  001"), text)
        XCTAssertTrue(text.contains("0026  1  1  001"), text)
    }

    /// The refusal has to name the ONE thing the user can do about it: there
    /// is no fallback route any more, on purpose.
    func testTheNoCellsRefusalNamesTheFixAndTheModeItFound() {
        let refusal = LocatorCells.noCellsRefusal(displayMode: "Beats & Project", triedSwitch: false)
        XCTAssertTrue(refusal.contains("Beats & Project"), refusal)
        XCTAssertTrue(refusal.contains("Customize Control Bar and Display"), refusal)
        XCTAssertTrue(refusal.contains("Locators"), refusal)
        XCTAssertFalse(refusal.contains("did not reveal"), refusal)
    }

    func testTheNoCellsRefusalSaysWhenSwitchingTheDisplayWasTried() {
        let refusal = LocatorCells.noCellsRefusal(displayMode: "Beats", triedSwitch: true)
        XCTAssertTrue(refusal.contains("did not reveal them"), refusal)
        XCTAssertTrue(refusal.contains(LogicUIStrings.Element.customDisplayMode), refusal)
    }

    func testTheAmbiguousRefusalNamesTheCountAndWhatItRefusedToTouch() {
        let refusal = LocatorCells.ambiguousPairsRefusal(count: 2)
        XCTAssertTrue(refusal.contains("2 locator pairs"), refusal)
        XCTAssertTrue(refusal.contains("Punch"), refusal)
        XCTAssertTrue(refusal.contains("nothing was written"), refusal)
    }

    func testTheVerificationNamesBothWitnesses() {
        let sentence = LocatorCells.verificationSentence(startBar: 20, endBar: 26, rulerLength: 6)
        XCTAssertTrue(sentence.contains("bar 20"), sentence)
        XCTAssertTrue(sentence.contains("bar 26"), sentence)
        XCTAssertTrue(sentence.contains("6 bars"), sentence)
    }

    /// A witness that could not be read is SAID to be missing, never quietly
    /// dropped from the sentence.
    func testTheVerificationAdmitsAMissingSecondWitness() {
        let sentence = LocatorCells.verificationSentence(startBar: 20, endBar: 26, rulerLength: nil)
        XCTAssertTrue(sentence.contains("could not be read"), sentence)
    }
}
