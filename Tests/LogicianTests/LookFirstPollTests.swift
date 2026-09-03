import XCTest
@testable import Logician

/// `lookFirstShouldSleep` — the shape shared by every blind-sleep AX poll
/// this server runs (`LogicAccessibility.setCycle`'s key-command fallback,
/// `setTransportCheckbox`'s AX-press verification, `MCUMetronome
/// .setMetronome`'s verification loop before this fix): a look-first retry
/// sleeps before every attempt EXCEPT the first, so a result that already
/// landed — an `AXUIElementPerformAction`'s effect, a key command's, a press
/// an event wait already confirmed — costs nothing instead of one
/// guaranteed tick.
///
/// These loops need a live AX walk or MCU bridge to exercise end to end
/// (profiles/logic_set_cycle.md C1: "not measured live, MCU plane answered
/// on every run"), so the one thing that IS a pure decision — attempt N
/// sleeps or does not — is pinned here instead.
final class LookFirstPollTests: XCTestCase {

    func testTheFirstAttemptNeverSleeps() {
        XCTAssertFalse(lookFirstShouldSleep(attempt: 0))
    }

    func testEveryAttemptAfterTheFirstSleeps() {
        for attempt in 1...19 {
            XCTAssertTrue(lookFirstShouldSleep(attempt: attempt), "attempt \(attempt) should sleep before looking")
        }
    }

    /// The property the fix actually buys: across a full 20-attempt budget,
    /// exactly one look is free.
    func testExactlyOneLookInTheBudgetIsFree() {
        let sleeps = (0..<20).filter { lookFirstShouldSleep(attempt: $0) }
        XCTAssertEqual(sleeps.count, 19)
        XCTAssertFalse(sleeps.contains(0))
    }
}
