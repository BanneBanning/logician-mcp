import Foundation
import LogicMCUBridge
import XCTest
@testable import Logician

/// The pure halves of the mixing family's 2026-09-03 fixes: the pan-view
/// toggle a restore has to VERIFY rather than assume, the bank step that
/// counts against what the surface shows rather than against arithmetic, the
/// record-arm witness that must be SKIPPED and not merely ignored, and the
/// volume no-op that turns nothing.
///
/// Every one of these was a live cost before it was a rule: 2.1–2.3 s of mode
/// banner on 4 of 9 consecutive volume writes, `Master` unreachable on a
/// 25-strip project, 229–1 651 ms of LED window discarded on 4 of 4 record-arm
/// calls, and a `db` the fader was already sitting at costing the same as a
/// real move.
final class MixingWriteRulesTests: XCTestCase {

    // MARK: - Which half of the PN toggle is showing

    /// Logic's own multi-channel names row, `Testlåt Copy`, 2026-09-02.
    private let namesRow = "LofPad Bas    808    Inst 2 Drums  Fill   AckSlg IvnSlg "

    /// The same row with Logic's mode banner painted over its right half —
    /// the transient that clears itself in ~2 s. The NAMES on the left are
    /// what says the view underneath is already the right one.
    private let bannerOverNames = "LofPad Bas    808    Pan/Surround parameter: Pan"

    /// The single-channel Pan page: one label and seven cleared cells. It
    /// carries the same `PN` code and never clears.
    private let singleChannelRow = "Pan    -      -      -      -      -      -      -      "

    func testTheNamesRowIsReadable() {
        XCTAssertEqual(
            MCUController.panRowState(assignment: "PN", top: namesRow), .namesReadable
        )
    }

    func testABannerOverTheNamesRowIsAWaitAndNotAPress() {
        XCTAssertEqual(
            MCUController.panRowState(assignment: "PN", top: bannerOverNames), .namesUnderBanner
        )
    }

    /// The state the old code could not tell from a fading banner, so it
    /// waited out a transient that is not one — six times, five seconds each,
    /// and then gave up without ever pressing.
    func testTheSingleChannelPanPageIsAPressAndNotAWait() {
        XCTAssertEqual(
            MCUController.panRowState(assignment: "PN", top: singleChannelRow), .singleChannelPan
        )
    }

    func testAnyOtherViewIsNotThePanFamilyAtAll() {
        for code in ["CS", "SE", "IN", "P1", "PL"] {
            XCTAssertEqual(
                MCUController.panRowState(assignment: code, top: namesRow), .notPanView, code
            )
        }
        XCTAssertEqual(MCUController.panRowState(assignment: nil, top: namesRow), .notPanView)
        XCTAssertEqual(MCUController.panRowState(assignment: "PN", top: nil), .notPanView)
    }

    // MARK: - Stepping to a bank by what the surface shows

    /// Eight seven-character cells, the width Logic paints and the width the
    /// arrival rule slices the row into.
    private func rowFor(_ bank: Int) -> String {
        (0..<8).map { "B\(bank)c\($0)   " }.joined()
    }

    func testAStepThatLandsOnTheWantedRowArrives() {
        XCTAssertEqual(
            MCUController.bankStepVerdict(
                outcome: .settled(rowFor(3)), expecting: rowFor(3), channel: 0, stallsSoFar: 0
            ),
            .arrived
        )
    }

    func testAStepThatLandsSomewhereElseKeepsWalking() {
        XCTAssertEqual(
            MCUController.bankStepVerdict(
                outcome: .settled(rowFor(2)), expecting: rowFor(3), channel: 0, stallsSoFar: 0
            ),
            .stepAgain
        )
    }

    /// THE `Master` BUG. Three bank_right presses were sent, two landed, and
    /// the walk reported the third bank's content missing rather than pressing
    /// again — a swallowed press and the right edge are the same reading from
    /// here, so the first unchanged row buys a retry, not a verdict.
    func testASwallowedPressIsRetriedBeforeItIsCalledTheRightEdge() {
        for stalls in 0..<MCUController.bankStepStallRetries {
            XCTAssertEqual(
                MCUController.bankStepVerdict(
                    outcome: .unchanged(rowFor(2)), expecting: rowFor(3), channel: 0, stallsSoFar: stalls
                ),
                .retryTheStep,
                "stall \(stalls)"
            )
        }
    }

    func testASurfaceThatWillNotStepAgainIsOutOfBanks() {
        XCTAssertEqual(
            MCUController.bankStepVerdict(
                outcome: .unchanged(rowFor(2)),
                expecting: rowFor(3),
                channel: 0,
                stallsSoFar: MCUController.bankStepStallRetries
            ),
            .outOfBanks(showing: rowFor(2))
        )
    }

    /// The clamped last bank re-shows the previous bank's tail, so "the row
    /// stopped changing" can be the arrival itself.
    func testTheClampedLastBankStillCountsAsArriving() {
        XCTAssertEqual(
            MCUController.bankStepVerdict(
                outcome: .unchanged(rowFor(3)), expecting: rowFor(3), channel: 0, stallsSoFar: 0
            ),
            .arrived
        )
    }

    /// The `Master` walk end to end, as the loop runs it: four banks, the
    /// third press swallowed. The old walk counted PRESSES, so three presses
    /// meant "done" and it checked the row at bank 2 — which is what made
    /// `Master` unreachable. Counting bank steps that HAPPENED gets there, and
    /// spends one extra press doing it.
    func testTheSwallowedPressWalkStillReachesTheLastBank() {
        let target = rowFor(3)
        let outcomes: [MCUController.SettledTopOutcome] = [
            .settled(rowFor(1)),
            .settled(rowFor(2)),
            .unchanged(rowFor(2)),  // the swallowed press
            .settled(rowFor(3))
        ]
        var moves = 0, stalls = 0, presses = 0, arrived = false
        for outcome in outcomes where moves < 3 {
            presses += 1
            switch MCUController.bankStepVerdict(
                outcome: outcome, expecting: target, channel: 0, stallsSoFar: stalls
            ) {
            case .arrived: arrived = true
            case .stepAgain: stalls = 0; moves += 1
            case .retryTheStep: stalls += 1
            case .outOfBanks, .unreadable: XCTFail("the walk gave up"); return
            }
            if arrived { break }
        }
        XCTAssertTrue(arrived)
        XCTAssertEqual(moves, 2, "the arrival itself is not counted as a step first")
        XCTAssertEqual(presses, 4, "one press more than the distance, because one was swallowed")
    }

    /// And a genuinely stale cache still fails after `index` steps rather than
    /// walking the whole project: three real steps, no arrival, loop over.
    func testAStaleCacheStopsAfterTheMappedDistance() {
        var moves = 0, presses = 0
        let stale = "not a row this project has  "
        for step in 1...3 where moves < 3 {
            presses += 1
            let verdict = MCUController.bankStepVerdict(
                outcome: .settled(rowFor(step)), expecting: stale, channel: 0, stallsSoFar: 0
            )
            XCTAssertEqual(verdict, .stepAgain)
            moves += 1
        }
        XCTAssertEqual(presses, 3)
        XCTAssertEqual(moves, 3)
    }

    func testARowThatNeverSettlesIsNeverAnAnswer() {
        for outcome in [MCUController.SettledTopOutcome.neverSettled, .surfaceUnreadable] {
            XCTAssertEqual(
                MCUController.bankStepVerdict(
                    outcome: outcome, expecting: rowFor(3), channel: 0, stallsSoFar: 0
                ),
                .unreadable
            )
        }
    }

    // MARK: - The record-arm witness that must be skipped, not ignored

    func testTheLEDWindowNeverRunsWhenAccessibilityAnswers() {
        for answer in [true, false] {
            var windowRan = false
            let reading = MCUController.armReading(
                accessibility: answer,
                ledWindow: { windowRan = true; return !answer }()
            )
            XCTAssertEqual(reading, .accessibility(answer))
            XCTAssertEqual(reading.armed, answer)
            XCTAssertEqual(reading.readbackRoute, "ax_record_enable_checkbox")
            XCTAssertFalse(windowRan, "the LED window ran for a question Accessibility had answered")
        }
    }

    /// The case the window exists for: a scrolled-out or headerless-rendered
    /// track, where the LED is the only evidence there is.
    func testTheLEDWindowStillRunsWhenAccessibilityCannotAnswer() {
        var windowRan = false
        let reading = MCUController.armReading(
            accessibility: nil,
            ledWindow: { windowRan = true; return true }()
        )
        XCTAssertTrue(windowRan)
        XCTAssertEqual(reading, .ledWindow(true))
        XCTAssertEqual(reading.readbackRoute, "mcu_rec_led_window")
    }

    func testThePostPressWindowIsSkippedOnceTheCheckboxAgrees() {
        var windowRan = false
        let proof = MCUController.armProof(
            accessibilityAgrees: true,
            ledWindow: { windowRan = true; return false }()
        )
        XCTAssertEqual(proof, .accessibility)
        XCTAssertFalse(windowRan)
    }

    func testThePostPressWindowDecidesWhenTheCheckboxDoesNot() {
        XCTAssertEqual(
            MCUController.armProof(accessibilityAgrees: false, ledWindow: true), .ledWindow
        )
        XCTAssertEqual(
            MCUController.armProof(accessibilityAgrees: false, ledWindow: false), .neither
        )
    }

    // MARK: - The volume no-op

    func testAVerifiedNoOpNamesNoWriteRoute() {
        let payload = MCUController.volumeVerdict(
            trackName: "Bas", startDb: -5.1, targetDb: -5.1, landedDb: -5.1,
            toleranceDb: 0.15, writeRoute: nil, state: "already_set"
        )
        XCTAssertEqual(payload["state"] as? String, "already_set")
        XCTAssertEqual(payload["verified"] as? Bool, true)
        XCTAssertEqual(payload["before_db"] as? Double, -5.1)
        XCTAssertEqual(payload["after_db"] as? Double, -5.1)
        // Nothing was turned, so there is no route to name — an absent key,
        // never a route called "none".
        XCTAssertNil(payload["write_route"])
        XCTAssertEqual(payload["readback_route"] as? String, "mcu_lcd_db")
    }

    func testARealWriteStillNamesItsRouteAndItsState() {
        let payload = MCUController.volumeVerdict(
            trackName: "Bas", startDb: -4.1, targetDb: -5.1, landedDb: -5.1,
            toleranceDb: 0.15, writeRoute: "bridge_converge"
        )
        XCTAssertEqual(payload["state"] as? String, "volume_set")
        XCTAssertEqual(payload["write_route"] as? String, "bridge_converge")
    }
}
