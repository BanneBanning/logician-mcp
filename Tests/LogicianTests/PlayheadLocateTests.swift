import XCTest
@testable import Logician

/// The pure decisions inside `convergeSlider` — the shared playhead stepper
/// behind `logic_set_playhead`, `logic_set_cycle_range` and 14 more call
/// sites — and the ruler-visibility geometry `setCycleRange` recovers with.
///
/// The loop itself needs a live Accessibility tree (the CI grep forbids one
/// here), so what is pinned is the part that decides WITHOUT one: the write
/// budget, the pre-write range refusal, the unrequested-beat verdict, and
/// which way the ruler has to move.
final class PlayheadLocateTests: XCTestCase {

    // MARK: - The write budget

    func testTheBudgetIsTheDistancePlusAnAllowance() {
        XCTAssertEqual(PlayheadLocate.stepBudget(from: 41, to: 43), 6)
        XCTAssertEqual(PlayheadLocate.stepBudget(from: 64, to: 41), 27)
    }

    func testTheBudgetIsSymmetric() {
        XCTAssertEqual(
            PlayheadLocate.stepBudget(from: 5, to: 40),
            PlayheadLocate.stepBudget(from: 40, to: 5)
        )
    }

    func testTheBudgetIsCappedSoNothingCanSpinAgainstAClamp() {
        XCTAssertEqual(PlayheadLocate.stepBudget(from: 1, to: 100_000), 512)
    }

    func testANoOpStillGetsEnoughBudgetToProveItself() {
        XCTAssertGreaterThan(PlayheadLocate.stepBudget(from: 7, to: 7), 0)
    }

    /// A long locate must be allowed to keep writing: the budget is the whole
    /// distance, because the slider moves one bar per write and nothing here
    /// may cut the walk short. (There is deliberately no pre-write range
    /// check — the slider's own `AXMinValue`/`AXMaxValue` were measured
    /// 2026-09-03 to be a ±1 window around the CURRENT value, not the
    /// project's range; see `convergeSlider`'s comment.)
    func testTheBudgetCoversTheWholeDistanceOfALongLocate() {
        XCTAssertGreaterThanOrEqual(PlayheadLocate.stepBudget(from: 56, to: 1), 55)
        XCTAssertGreaterThanOrEqual(PlayheadLocate.stepBudget(from: 1, to: 400), 399)
    }

    // MARK: - The beat nobody asked about (defect: beat 3 -> 1, silently)

    func testABeatThatMovedOnItsOwnIsPutBack() {
        XCTAssertEqual(
            PlayheadLocate.unrequestedBeatDrift(requested: nil, before: 3, after: 1), 3
        )
    }

    func testABeatTheCallerAskedForIsNeverUndone() {
        XCTAssertNil(PlayheadLocate.unrequestedBeatDrift(requested: 1, before: 3, after: 1))
    }

    func testABeatThatDidNotMoveIsLeftAlone() {
        XCTAssertNil(PlayheadLocate.unrequestedBeatDrift(requested: nil, before: 3, after: 3))
    }

    func testAnUnreadableBeatIsNotGuessedAt() {
        XCTAssertNil(PlayheadLocate.unrequestedBeatDrift(requested: nil, before: nil, after: 1))
        XCTAssertNil(PlayheadLocate.unrequestedBeatDrift(requested: nil, before: 3, after: nil))
    }

    func testTheWarningNamesBothBeatsAndTheOutcome() {
        let restored = PlayheadLocate.beatDriftWarning(from: 3, to: 1, restored: true)
        XCTAssertTrue(restored.contains("3"))
        XCTAssertTrue(restored.contains("1"))
        XCTAssertTrue(restored.contains("put back"))

        let leaked = PlayheadLocate.beatDriftWarning(from: 3, to: 1, restored: false)
        XCTAssertTrue(leaked.contains("NOT"))
        XCTAssertTrue(leaked.contains("logic_set_playhead"), leaked)
    }

    // MARK: - Ruler visibility (defect: a valid range dragged out of reach)

    func testARangeWellInsideTheRulerIsVisible() {
        XCTAssertTrue(RulerVisibility.isVisible(
            startX: 200, endX: 400, rulerMinX: 100, rulerMaxX: 900, margin: 30
        ))
    }

    func testARangeTouchingTheEdgeIsNotVisibleEnoughToDragOn() {
        XCTAssertFalse(RulerVisibility.isVisible(
            startX: 110, endX: 400, rulerMinX: 100, rulerMaxX: 900, margin: 30
        ))
        XCTAssertFalse(RulerVisibility.isVisible(
            startX: 200, endX: 880, rulerMinX: 100, rulerMaxX: 900, margin: 30
        ))
    }

    func testAVisibleRangeNeedsNoShift() {
        XCTAssertEqual(RulerVisibility.shiftToReveal(
            startX: 200, endX: 400, rulerMinX: 100, rulerMaxX: 900, margin: 30
        ), 0)
    }

    func testARangeOffTheLeftMovesTheContentRight() {
        let shift = RulerVisibility.shiftToReveal(
            startX: -50, endX: 150, rulerMinX: 100, rulerMaxX: 900, margin: 30
        )
        XCTAssertEqual(shift, 180)
    }

    func testARangeOffTheRightMovesTheContentLeft() {
        let shift = RulerVisibility.shiftToReveal(
            startX: 800, endX: 1000, rulerMinX: 100, rulerMaxX: 900, margin: 30
        )
        XCTAssertEqual(shift, -130)
    }

    /// The property the recovery depends on: applying the shift it asks for
    /// makes the range visible, from either side.
    func testApplyingTheShiftMakesTheRangeVisible() {
        for (startX, endX) in [(-50.0, 150.0), (800.0, 1000.0), (-400.0, -200.0), (2000.0, 2100.0)] {
            let shift = RulerVisibility.shiftToReveal(
                startX: startX, endX: endX, rulerMinX: 100, rulerMaxX: 900, margin: 30
            )
            XCTAssertTrue(
                RulerVisibility.isVisible(
                    startX: startX + shift, endX: endX + shift,
                    rulerMinX: 100, rulerMaxX: 900, margin: 30
                ),
                "shifting (\(startX), \(endX)) by \(shift) should reveal it"
            )
        }
    }

    /// A span wider than the window can never fit; the recovery brings its
    /// START into view, because that is the edge the drag begins on.
    func testASpanWiderThanTheWindowRevealsItsStart() {
        let shift = RulerVisibility.shiftToReveal(
            startX: -500, endX: 2000, rulerMinX: 100, rulerMaxX: 900, margin: 30
        )
        XCTAssertEqual(-500 + shift, 130)
    }
}

/// The pure arithmetic behind `logic_set_cycle_range`'s ruler mapping: how a
/// bar becomes a pixel when the ruler's bars are not all the same width, and
/// how a failed write decides whether it put the locators back.
///
/// A ruler whose bars differ in width is not hypothetical — a bar's width on
/// Logic's timeline follows its meter, and the sandbox project changes meter
/// at bar 41 — so `RULER` below is a two-width ruler and every distance test
/// is taken against it rather than against a single slope.
final class RulerBarMappingTests: XCTestCase {

    /// A ruler with two bar widths: 40 px per bar up to bar 41, 50 px after
    /// it. Nothing here claims those are Logic's numbers; the point is that
    /// ONE average slope cannot describe both stretches, which is the whole
    /// reason the tool measures its bar lines instead of extrapolating them.
    private enum RULER {
        static let changeBar = 41
        static let narrow: CGFloat = 40
        static let wide: CGFloat = 50

        /// Pixels from bar 1's line to `bar`'s line.
        static func x(_ bar: Int) -> CGFloat {
            let narrowBars = min(bar, changeBar) - 1
            let wideBars = max(0, bar - changeBar)
            return CGFloat(narrowBars) * narrow + CGFloat(wideBars) * wide
        }

        /// What `pixelsPerBar` reads off the Start and End markers: one slope
        /// averaged over the whole project.
        static func averageSlope(lastBar: Int) -> CGFloat {
            x(lastBar) / CGFloat(lastBar - 1)
        }
    }

    // MARK: - Anchoring

    /// The live geometry this rule was rewritten from (2026-09-03, Logic Pro
    /// 12.3.1, the sandbox at its resting zoom): a 5/4 bar is 17 px, a 4/4 bar
    /// 13.2 px, the ruler's average slope 13.4 px, and the cycle region's
    /// frame sits a constant 8 px to the RIGHT of its own locator line.
    private static let regionInset: CGFloat = 8
    private static let wideBar: CGFloat = 17
    private static let narrowBar: CGFloat = 13.2
    private static let averageBar: CGFloat = 13.4

    func testAParkedBarThatIsTheRegionsOwnBarIsAnchored() {
        XCTAssertEqual(
            RulerBarMapping.barsOff(
                gapPixels: Self.regionInset, localPixelsPerBar: Self.wideBar
            ), 0
        )
        XCTAssertEqual(
            RulerBarMapping.barsOff(
                gapPixels: Self.regionInset, localPixelsPerBar: Self.narrowBar
            ), 0
        )
    }

    /// The exact miss that stranded the sandbox: judged against the ruler's
    /// AVERAGE slope, a region sitting on its own bar line reads as most of a
    /// bar away — and the search then oscillates, because from the next bar it
    /// reads as most of a bar back.
    func testTheAverageSlopeWouldHaveCalledTheRightBarWrong() {
        let asAverageBars = Double(Self.regionInset / Self.averageBar)
        XCTAssertGreaterThan(asAverageBars, 0.55, "this is the reading that used to fail")
        XCTAssertEqual(
            RulerBarMapping.barsOff(
                gapPixels: Self.regionInset, localPixelsPerBar: Self.wideBar
            ), 0, "measured against the bar's own width it is simply anchored"
        )
    }

    func testAParkedBarOneShortOfTheRegionSaysSo() {
        XCTAssertEqual(
            RulerBarMapping.barsOff(
                gapPixels: Self.regionInset + Self.wideBar, localPixelsPerBar: Self.wideBar
            ), 1
        )
    }

    func testAParkedBarPastTheRegionSaysHowFar() {
        XCTAssertEqual(
            RulerBarMapping.barsOff(
                gapPixels: Self.regionInset - Self.wideBar, localPixelsPerBar: Self.wideBar
            ), -1
        )
        XCTAssertEqual(
            RulerBarMapping.barsOff(
                gapPixels: Self.regionInset - 6 * Self.wideBar, localPixelsPerBar: Self.wideBar
            ), -6
        )
    }

    /// A pixel of rounding either side of the inset must not move the verdict:
    /// this is the knife edge the old rule fell off.
    func testAPixelOfRoundingDoesNotChangeTheBar() {
        for slack in [-2.0, -1.0, 0.0, 1.0, 2.0] {
            XCTAssertEqual(
                RulerBarMapping.barsOff(
                    gapPixels: Self.regionInset + CGFloat(slack),
                    localPixelsPerBar: Self.narrowBar
                ), 0, "\(slack) px of slack should not move the bar"
            )
        }
    }

    func testAnUnreadableBarWidthClaimsNoOffset() {
        XCTAssertEqual(RulerBarMapping.barsOff(gapPixels: 40, localPixelsPerBar: 0), 0)
    }

    /// The property the anchor loop depends on, and the one the old plus/minus
    /// one search did not have: from the average slope's guess — three bars out
    /// for a region past the change — the search reaches the region's real bar
    /// inside the loop's tries, from either side of the change.
    func testTheAnchorSearchConvergesOnAWiderThanAverageRuler() {
        let average = RULER.averageSlope(lastBar: 82)
        for trueBar in [3, 20, 40, 41, 44, 60, 80] {
            let regionX = RULER.x(trueBar) + Self.regionInset
            // The tool's opening guess: the region's x read through one slope.
            var candidate = max(1, Int((regionX / average).rounded()) + 1)
            var tries = 0
            while tries < 5 {
                tries += 1
                // What the loop measures: the gap, and the bar's own width
                // from the neighbouring bar line.
                let gap = regionX - RULER.x(candidate)
                let width = RULER.x(candidate + 1) - RULER.x(candidate)
                let off = RulerBarMapping.barsOff(gapPixels: gap, localPixelsPerBar: width)
                if off == 0 { break }
                candidate = max(1, candidate + off)
            }
            XCTAssertEqual(candidate, trueBar, "did not converge on bar \(trueBar) in \(tries) tries")
        }
    }

    // MARK: - Why the average slope is not enough

    /// The defect this fix is about, in arithmetic: extrapolating from the
    /// anchor with one average slope misses the target by more than the
    /// landing tolerance, so a grid-snapped write would land on the wrong bar
    /// and the tool refuses a range it can perfectly well reach.
    func testExtrapolatingOneSlopeMissesABarPastTheMeterChange() {
        let average = RULER.averageSlope(lastBar: 82)
        let anchorBar = 5
        let targetBar = 43
        let extrapolated = RULER.x(anchorBar) + average * CGFloat(targetBar - anchorBar)
        let error = RulerBarMapping.errorBars(
            measured: RULER.x(targetBar), extrapolated: extrapolated, pixelsPerBar: RULER.wide
        )
        XCTAssertGreaterThan(
            abs(error), Double(RulerBarMapping.landingToleranceBars),
            "one slope is supposed to be off by more than a landing tolerance here"
        )
    }

    /// …and the same extrapolation over the same distance is fine while the
    /// bars are all one width, which is why this went unnoticed: the tool is
    /// only wrong on the far side of a meter change.
    func testExtrapolatingOneSlopeIsFineBeforeTheMeterChange() {
        let average = RULER.averageSlope(lastBar: 41)
        let extrapolated = RULER.x(5) + average * CGFloat(24 - 5)
        XCTAssertEqual(
            RulerBarMapping.errorBars(
                measured: RULER.x(24), extrapolated: extrapolated, pixelsPerBar: RULER.narrow
            ),
            0, accuracy: 0.01
        )
    }

    // MARK: - The measured local slope

    func testTheLocalSlopeIsTheMeasuredSpanOverItsBars() {
        XCTAssertEqual(
            RulerBarMapping.localPixelsPerBar(startOffset: 100, endOffset: 300, bars: 4), 50
        )
    }

    func testASpanOfNoBarsHasNoSlope() {
        XCTAssertEqual(
            RulerBarMapping.localPixelsPerBar(startOffset: 100, endOffset: 300, bars: 0), 0
        )
    }

    func testAMeterChangeSizedSlopeIsBelieved() {
        XCTAssertTrue(RulerBarMapping.isPlausibleSlope(local: 50, average: 40))
        XCTAssertTrue(RulerBarMapping.isPlausibleSlope(local: 30, average: 40))
    }

    /// The guard against a thumb that never followed the park: a reading that
    /// collapses or inverts the slope is not a meter change, it is a bad
    /// measurement, and the caller falls back to the average slope.
    func testACollapsedOrInvertedSlopeIsNotBelieved() {
        XCTAssertFalse(RulerBarMapping.isPlausibleSlope(local: 0, average: 40))
        XCTAssertFalse(RulerBarMapping.isPlausibleSlope(local: -50, average: 40))
        XCTAssertFalse(RulerBarMapping.isPlausibleSlope(local: 4, average: 40))
        XCTAssertFalse(RulerBarMapping.isPlausibleSlope(local: 400, average: 40))
        XCTAssertFalse(RulerBarMapping.isPlausibleSlope(local: 40, average: 0))
    }

    func testTheErrorIsSignedInBars() {
        XCTAssertEqual(
            RulerBarMapping.errorBars(measured: 100, extrapolated: 140, pixelsPerBar: 40),
            -1, accuracy: 1e-9
        )
        XCTAssertEqual(
            RulerBarMapping.errorBars(measured: 100, extrapolated: 100, pixelsPerBar: 0), 0
        )
    }

    // MARK: - Saying where a failed write left the range

    func testTheBarOfAnOffsetIsRoundedToTheNearestLine() {
        XCTAssertEqual(
            RulerBarMapping.barAt(offset: 210, anchorOffset: 10, anchorBar: 5, pixelsPerBar: 40), 10
        )
        XCTAssertEqual(
            RulerBarMapping.barAt(offset: 205, anchorOffset: 10, anchorBar: 5, pixelsPerBar: 40), 10
        )
    }

    func testTheBarOfAnOffsetIsNeverBeforeTheFirstBar() {
        XCTAssertEqual(
            RulerBarMapping.barAt(offset: -4000, anchorOffset: 10, anchorBar: 5, pixelsPerBar: 40), 1
        )
        XCTAssertEqual(
            RulerBarMapping.barAt(offset: 10, anchorOffset: 10, anchorBar: 5, pixelsPerBar: 0), 5
        )
    }

    // MARK: - Was it put back? (defect: a failed write left the region moved)

    func testARangeBackAtItsOwnPositionAndLengthIsRestored() {
        XCTAssertTrue(RulerBarMapping.isSameRange(
            offset: 204, originalOffset: 200, length: 4, originalLength: 4, pixelsPerBar: 40
        ))
    }

    func testARangeOnTheWrongBarIsNotRestored() {
        XCTAssertFalse(RulerBarMapping.isSameRange(
            offset: 240, originalOffset: 200, length: 4, originalLength: 4, pixelsPerBar: 40
        ))
    }

    func testARangeOfTheWrongLengthIsNotRestored() {
        XCTAssertFalse(RulerBarMapping.isSameRange(
            offset: 200, originalOffset: 200, length: 6, originalLength: 4, pixelsPerBar: 40
        ))
    }

    /// "We could not tell" must never report itself as `restored: true`.
    func testAnUnreadableRangeIsNeverCalledRestored() {
        XCTAssertFalse(RulerBarMapping.isSameRange(
            offset: nil, originalOffset: 200, length: 4, originalLength: 4, pixelsPerBar: 40
        ))
        XCTAssertFalse(RulerBarMapping.isSameRange(
            offset: 200, originalOffset: 200, length: nil, originalLength: 4, pixelsPerBar: 40
        ))
        XCTAssertFalse(RulerBarMapping.isSameRange(
            offset: 200, originalOffset: 200, length: 4, originalLength: nil, pixelsPerBar: 40
        ))
    }

    func testTheRestoreSentenceNamesWhereTheRangeWentBackTo() {
        let sentence = RulerBarMapping.restoreSentence(
            restored: true, original: "bars 5-9", leftAt: "bars 43-47"
        )
        XCTAssertTrue(sentence.contains("bars 5-9"), sentence)
        XCTAssertFalse(sentence.contains("bars 43-47"), sentence)
    }

    func testTheRestoreSentenceNamesWhereItIsLeftWhenItCannot() {
        let sentence = RulerBarMapping.restoreSentence(
            restored: false, original: "bars 5-9", leftAt: "bars 43-47"
        )
        XCTAssertTrue(sentence.contains("NOT"), sentence)
        XCTAssertTrue(sentence.contains("bars 43-47"), sentence)
        XCTAssertTrue(sentence.contains("logic_set_cycle_range"), sentence)
    }
}
