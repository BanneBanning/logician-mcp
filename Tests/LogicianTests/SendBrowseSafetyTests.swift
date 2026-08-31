import XCTest
@testable import Logician
@testable import LogicMCUBridge

/// The safety rules a destination browse runs under since the send view was
/// measured NOT to stay standing (2026-08-31, `Testlåt Copy`): the view
/// gate, the entry classifier that stops blind ticking, and the readback
/// verdict every abandoned browse must pass before it may claim "nothing was
/// written". The frames in these tests are the ones the surface actually
/// painted that day — the pan values a fallen-out browse read, the teardown's
/// assignment codes, the send that materialized behind an abandoned browse.
final class SendBrowseSafetyTests: XCTestCase {

    // MARK: - The view gate

    /// Only the single-channel send view gives a destination vpot message its
    /// meaning. Every other code the teardown was measured to pass through —
    /// the multi-channel send views `S_`/`S1`, and the Pan view it lands in —
    /// must read as "the view dropped", and so must a frame with no
    /// assignment at all.
    func testOnlyTheSendChannelViewCountsAsStanding() {
        XCTAssertTrue(MCUController.sendViewStanding(in: ["assignment": "SE"]))
        for fallen in ["S1", "S_", "PN", "IN", "CS", "P1"] {
            XCTAssertFalse(MCUController.sendViewStanding(in: ["assignment": fallen]), fallen)
        }
        XCTAssertFalse(MCUController.sendViewStanding(in: [:]))
        XCTAssertFalse(MCUController.sendViewStanding(in: nil))
    }

    func testTheDropErrorNamesTheViewItFoundAndTheMessageItWithheld() {
        let text = MCUController.sendViewDroppedError(
            ["assignment": "PN"], before: "a 63-entry jump"
        ).localizedDescription
        XCTAssertTrue(text.contains("'PN'"), text)
        XCTAssertTrue(text.contains("a 63-entry jump"), text)
        XCTAssertTrue(text.contains("was not sent"), text)
    }

    // MARK: - The entry classifier

    /// Real catalog entries, including the abbreviated and unnumbered ones.
    func testCatalogEntriesReadAsEntries() {
        for entry in ["Bus 2", "Bus 200", "B 200", "Output 3-4", "Out3-4", "Stereo Output"] {
            XCTAssertTrue(MCUController.sendBrowseReadIsEntry(entry), entry)
        }
    }

    /// Blank and the No-Send placeholder are the browse's ordinary
    /// non-answers; a bare number is a foreign view's parameter under this
    /// index. `-64` and `0` are the pans a fallen-out browse read live, and
    /// `-12,2` is the level the spurious send carried.
    func testNonEntriesReadAsNonEntries() {
        for nonEntry in ["", "  ", "--", "-64", "0", "+28", "-12,2", "-9.0", "63"] {
            XCTAssertFalse(MCUController.sendBrowseReadIsEntry(nonEntry), "'\(nonEntry)'")
        }
    }

    /// The cap exists so blank reads are counted instead of ticked past; a
    /// browse must be allowed a FEW of them (the unpainted origin, a
    /// blink-off frame of the pending entry, an unfinished repaint), so the
    /// cap must comfortably exceed one or two — and stay small enough that a
    /// view that never paints is abandoned within seconds, not budgets.
    func testTheBlankReadCapAllowsBlinksAndStopsBlindTicking() {
        XCTAssertTrue((3...20).contains(MCUController.sendBrowseBlankReadCap))
    }

    // MARK: - The abandon verdict

    /// An add browse ran on an empty slot; the slot must still be empty.
    func testAnAbandonedAddBrowseIsCleanWhenTheSlotStayedEmpty() {
        let verdict = MCUController.sendAbandonVerdict(
            slot: 2, expected: nil, after: [(1, "Bus 2")]
        )
        XCTAssertTrue(verdict.clean)
        XCTAssertTrue(verdict.detail.contains("still empty"), verdict.detail)
    }

    /// The measured incident: `B 200` materialized in a slot no press had
    /// confirmed anything on. The verdict must name what appeared and how to
    /// clean it up, and must not be clean.
    func testAnAbandonedAddBrowseReportsASendThatMaterialized() {
        let verdict = MCUController.sendAbandonVerdict(
            slot: 2, expected: nil, after: [(1, "Bus 2"), (2, "B 200")]
        )
        XCTAssertFalse(verdict.clean)
        XCTAssertTrue(verdict.detail.contains("'B 200'"), verdict.detail)
        XCTAssertTrue(verdict.detail.contains("logic_remove_send"), verdict.detail)
    }

    /// A removal browse ran on an occupied slot; the send must still stand
    /// exactly as the resolution matched it, case-insensitively — the same
    /// tolerance the pre-browse check gives Logic's own spelling.
    func testAnAbandonedRemovalBrowseIsCleanWhenTheSendStillStands() {
        let verdict = MCUController.sendAbandonVerdict(
            slot: 1, expected: "Bus 2", after: [(1, "bus 2")]
        )
        XCTAssertTrue(verdict.clean)
    }

    func testAnAbandonedRemovalBrowseReportsARewrittenDestination() {
        let verdict = MCUController.sendAbandonVerdict(
            slot: 1, expected: "Bus 2", after: [(1, "Bus 65")]
        )
        XCTAssertFalse(verdict.clean)
        XCTAssertTrue(verdict.detail.contains("'Bus 65'"), verdict.detail)
        XCTAssertTrue(verdict.detail.contains("'Bus 2'"), verdict.detail)
    }

    func testAnAbandonedRemovalBrowseReportsASendThatVanished() {
        let verdict = MCUController.sendAbandonVerdict(
            slot: 1, expected: "Bus 2", after: []
        )
        XCTAssertFalse(verdict.clean)
        XCTAssertTrue(verdict.detail.contains("gone"), verdict.detail)
    }
}
