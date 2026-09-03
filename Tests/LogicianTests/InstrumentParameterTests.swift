import Foundation
import LogicMCUBridge
import XCTest
@testable import Logician

/// The instrument slot's parameter tools, after they were given the OUTER
/// wins their insert twin got in package #1 (2026-09-02).
///
/// Everything here is pure, and every rule in it is one a live run cannot
/// check honestly. A hot view that is trusted one view too long writes to
/// whatever the surface happens to be showing and reports success; a partial
/// cache that forgets it is partial pairs page 13's values with names nobody
/// read; and a refusal that flattens six causes into one sentence leaves an
/// agent retrying a fact about the project.
final class InstrumentParameterTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MCUController.hotEditView = nil
        MCUController.surfaceDebt = nil
    }

    override func tearDown() {
        MCUController.hotEditView = nil
        MCUController.surfaceDebt = nil
        super.tearDown()
    }

    // MARK: - The hot view's shape

    /// The insert slots and the instrument slot are different addresses, and
    /// the record has to keep them apart: `.insert(1)` and the instrument slot
    /// of the same track are not the same view, and one standing in for the
    /// other aims an encoder at the wrong plugin.
    func testTheInstrumentSlotIsNotInsertSlotAnything() {
        let instrument = MCUController.HotSlot.instrument(channel: 1)
        XCTAssertNotEqual(instrument, .insert(1))
        XCTAssertNotEqual(instrument, .instrument(channel: 2))
        XCTAssertEqual(instrument, .instrument(channel: 1))
    }

    func testTheHotRecordCarriesTrackSlotAndTheLcdCacheKey() {
        let hot = MCUController.HotEditView(
            track: "808", slot: .instrument(channel: 2), cacheKey: "Q-Samp"
        )
        MCUController.hotEditView = hot
        XCTAssertEqual(MCUController.hotEditView, hot)
        MCUController.forgetSurfaceViews()
        XCTAssertNil(MCUController.hotEditView)
    }

    /// `IN` is the assignment code of BOTH the instrument bank view and the
    /// instrument's parameter pages, so the code alone cannot say which one is
    /// up. What separates them is the top row: the bank view names the STRIP
    /// in its own channel's cell (the same evidence `ensureInstrumentBankView`
    /// accepts as `mcu_in_bank_named_strip`), the parameter pages paint
    /// parameter names there.
    func testTheBankViewIsRecognisedByItsOwnNamedStrip() {
        // The IN bank view banked on `808`, which sits in channel 2.
        let bankRow = "LofPad Bas    808    Inst 2 Sweeps Kick   Snare  Hats   "
        XCTAssertTrue(
            MCUController.instrumentBankRowShowing(top: bankRow, channel: 2, trackName: "808")
        )
        // Quick Sampler's first parameter page, same channel index.
        let editRow = "CoaTun FinTun GldTim Filter FilTyp FilCut FilRes FilDrv "
        XCTAssertFalse(
            MCUController.instrumentBankRowShowing(top: editRow, channel: 2, trackName: "808")
        )
    }

    /// A channel outside the row is not evidence of anything, and must not be
    /// read as "the parameter pages are up".
    func testAnUnreadableChannelCellIsNotTheParameterView() {
        XCTAssertFalse(
            MCUController.instrumentBankRowShowing(top: "", channel: 7, trackName: "808")
        )
    }

    // MARK: - What the refusals say

    /// Six causes, six answers. The one that matters most is the empty slot:
    /// it is a fact about the project, so it comes back as a precondition an
    /// agent must fix rather than as a transient "not exposed" to retry.
    func testAnEmptySlotIsAPreconditionNotATransientFailure() {
        let error = MCUController.instrumentEditError(.emptySlot, trackName: "Inst 2")
        XCTAssertEqual(error.code, "precondition_failed")
        let text = error.errorDescription ?? ""
        XCTAssertTrue(text.contains("no software instrument"), text)
        XCTAssertTrue(text.contains("logic_load_instrument"), text)
        XCTAssertTrue(text.contains("Nothing was read or written"), text)
    }

    func testAViewThatWouldNotSwitchSaysSoAndSaysRetry() {
        let text = MCUController.instrumentEditError(
            .bankViewUnreachable, trackName: "808"
        ).errorDescription ?? ""
        XCTAssertTrue(text.contains("instrument (IN) view"), text)
        XCTAssertTrue(text.contains("retry"), text)
    }

    func testADeadBridgeNamesTheDiagnosticAndTheMissingRoute() {
        let text = MCUController.instrumentEditError(
            .bridgeUnavailable, trackName: "808"
        ).errorDescription ?? ""
        XCTAssertTrue(text.contains("logic_health"), text)
        XCTAssertTrue(text.contains("no Accessibility route"), text)
    }

    /// The typed resolution `findChannel` already recorded is carried through
    /// instead of being thrown away — an ambiguous strip and a missing one are
    /// different problems with different fixes.
    func testTheStripResolutionKeepsItsOwnErrorShape() {
        XCTAssertEqual(
            MCUController.instrumentEditError(
                .stripUnresolved(.notFound(cells: ["Bas", "808"])), trackName: "Lead"
            ).code,
            "not_found"
        )
        XCTAssertEqual(
            MCUController.instrumentEditError(
                .stripUnresolved(.ambiguous(cells: ["Bas", "Bas"])), trackName: "Bas"
            ).code,
            "ambiguous"
        )
        // The AX track list settled which cells are colliding: the numbers
        // are the way out, not the bare LCD cells.
        let numbered = MCUController.instrumentEditError(
            .stripUnresolved(.ambiguousNumbered(cells: ["IvnVoc", "IvnVoc"], numbers: [21, 22])),
            trackName: "Ivan Vocals"
        )
        XCTAssertEqual(numbered.code, "ambiguous")
        XCTAssertTrue((numbered.errorDescription ?? "").contains("21"))
        XCTAssertTrue((numbered.errorDescription ?? "").contains("22"))
        let unavailable = MCUController.instrumentEditError(
            .stripUnresolved(.unavailable(reason: "the pan-names view could not be reached")),
            trackName: "Bas"
        )
        XCTAssertEqual(unavailable.code, "not_exposed")
        XCTAssertTrue(
            (unavailable.errorDescription ?? "").contains("pan-names view"),
            unavailable.errorDescription ?? ""
        )
    }

    /// Every miss says nothing was written. The write tool changes sound, and
    /// an agent that cannot tell "refused before touching anything" from
    /// "failed halfway" has to go and look.
    func testEveryRefusalSaysNothingWasWritten() {
        let misses: [MCUController.InstrumentEditMiss] = [
            .bridgeUnavailable,
            .stripUnresolved(.unavailable(reason: "no surface")),
            .bankViewUnreachable,
            .emptySlot,
            .vpotPressRejected("socket closed"),
            .editViewUnreachable
        ]
        for miss in misses {
            let text = MCUController.instrumentEditError(miss, trackName: "808")
                .errorDescription ?? ""
            XCTAssertTrue(
                text.lowercased().contains("nothing was read or written")
                    || text.lowercased().contains("nothing was changed"),
                "\(miss): \(text)"
            )
        }
    }

    /// The refusals are distinct STRINGS, not one string reached six ways —
    /// which is the whole defect (D2) this shape replaces.
    func testTheSixMissesProduceSixDifferentMessages() {
        let misses: [MCUController.InstrumentEditMiss] = [
            .bridgeUnavailable,
            .stripUnresolved(.unavailable(reason: "no surface")),
            .bankViewUnreachable,
            .emptySlot,
            .vpotPressRejected("socket closed"),
            .editViewUnreachable
        ]
        let messages = Set(misses.map {
            MCUController.instrumentEditError($0, trackName: "808").errorDescription ?? ""
        })
        XCTAssertEqual(messages.count, misses.count)
    }

    // MARK: - The cache key

    /// The key is namespaced so an insert and an instrument that abbreviate
    /// alike cannot inherit each other's parameter rows.
    func testTheInstrumentCacheKeyIsNamespaced() {
        XCTAssertEqual(MCUController.instrumentCacheKey("Q-Samp"), "instrument:Q-Samp")
        XCTAssertNotEqual(MCUController.instrumentCacheKey("Compre"), "Compre")
    }

    // MARK: - Partial (capped) cache entries

    private func row(_ prefix: String) -> [String] {
        (1...8).map { "\(prefix)\($0)" }
    }

    /// A capped read of a 64-page instrument stores the 12 pages it read and
    /// says, by its own length, that the other 52 are missing.
    func testACappedWalkIsStoredAsAPrefixOfTheRealPageCount() {
        let entry = MCUController.paddedNameRows([row("a"), row("b")], total: 5)
        XCTAssertEqual(entry.count, 5)
        XCTAssertEqual(MCUController.cachedNameRowPrefix(entry), 2)
        XCTAssertFalse(MCUController.cachedNameRowsComplete(entry))
    }

    func testACompleteWalkIsStoredWhole() {
        let entry = MCUController.paddedNameRows([row("a"), row("b")], total: 2)
        XCTAssertEqual(entry, [row("a"), row("b")])
        XCTAssertTrue(MCUController.cachedNameRowsComplete(entry))
    }

    /// The later, larger read COMPLETES the partial entry rather than
    /// replacing it — and a smaller read afterwards must not throw away pages
    /// the larger one already paid 2.1 s each for.
    func testALaterFullReadCompletesAPartialEntry() {
        let partial = MCUController.paddedNameRows([row("a")], total: 3)
        let full = [row("a"), row("b"), row("c")]
        XCTAssertEqual(MCUController.mergedNameRows(existing: partial, incoming: full), full)
        XCTAssertEqual(MCUController.mergedNameRows(existing: full, incoming: partial), full)
    }

    /// A page count that moved is a different plugin (or a different version
    /// of one), and merging two layouts would be the confidently wrong answer
    /// the whole cache is scoped to avoid. The fresher walk wins outright.
    func testAChangedPageCountReplacesTheEntryInsteadOfMerging() {
        let old = [row("a"), row("b")]
        let new = [row("x")]
        XCTAssertEqual(MCUController.mergedNameRows(existing: old, incoming: new), new)
    }

    /// A partial entry is not something the offline address lookup will reason
    /// about: it cannot prove a name unique across pages it does not hold, so
    /// it refuses and the caller walks live. Conservative on purpose.
    func testAPartialEntryIsRefusedByTheOfflineAddressLookup() {
        let partial = MCUController.paddedNameRows([row("a")], total: 3)
        XCTAssertNil(MCUController.locateParameter("a3", in: partial))
    }

    // MARK: - Landing on the cell about to be turned

    private let page: [String] = [
        "CoaTun", "FinTun", "GldTim", "Filter", "FilTyp", "FilCut", "FilRes", "FilDrv"
    ]

    private func hit(_ index: Int, page number: Int = 1) -> MCUController.CachedParameterLocation {
        MCUController.CachedParameterLocation(page: number, index: index, name: page[index])
    }

    /// The ordinary proof, unchanged: the cell whose encoder is about to move
    /// matches the live LCD exactly.
    func testAnExactCellMatchProvesTheRow() {
        XCTAssertTrue(MCUController.cachedRowProvesCell(
            hit: hit(1), cachedRow: page, live: page, indicator: nil, totalPages: 9
        ))
    }

    func testAShiftedRowIsRefused() {
        var live = page
        live[2] = "Someth"
        XCTAssertFalse(MCUController.cachedRowProvesCell(
            hit: hit(1), cachedRow: page, live: live, indicator: nil, totalPages: 9
        ))
    }

    /// Cells 7-8 are where Logic draws the transient "Page x/y" indicator, so
    /// the cell about to move cannot be read there for ~2.1 s. The indicator
    /// itself is the substitute witness: it names the page, out of the total
    /// the cache holds.
    func testTheIndicatorProvesTheLastTwoCellsWithoutWaitingForTheFade() {
        var live = page
        live[6] = "Page 3"
        live[7] = "/9"
        XCTAssertTrue(MCUController.cachedRowProvesCell(
            hit: hit(6, page: 3), cachedRow: page, live: live,
            indicator: (current: 3, total: 9), totalPages: 9
        ))
    }

    func testAnIndicatorNamingAnotherPageProvesNothing() {
        var live = page
        live[6] = "Page 4"
        XCTAssertFalse(MCUController.cachedRowProvesCell(
            hit: hit(6, page: 3), cachedRow: page, live: live,
            indicator: (current: 4, total: 9), totalPages: 9
        ))
        // ... and neither does one that disagrees about how many pages exist.
        XCTAssertFalse(MCUController.cachedRowProvesCell(
            hit: hit(6, page: 3), cachedRow: page, live: live,
            indicator: (current: 3, total: 12), totalPages: 9
        ))
    }

    /// The substitute witness is only for the two cells the indicator covers.
    /// A cell in 1-6 that differs is a shifted layout, indicator or not.
    func testTheIndicatorDoesNotExcuseACellItDoesNotCover() {
        var live = page
        live[1] = "Someth"
        XCTAssertFalse(MCUController.cachedRowProvesCell(
            hit: hit(1), cachedRow: page, live: live,
            indicator: (current: 1, total: 9), totalPages: 9
        ))
    }

    /// A cell 7-8 that is neither the cached name nor the indicator — Logic
    /// paints the touched parameter's full name across the row right after a
    /// write — takes the full fade rather than the cheap answer.
    func testACellHiddenBySomethingOtherThanTheIndicatorTakesTheFade() {
        var live = page
        live[6] = "Thresho"
        XCTAssertFalse(MCUController.cachedRowProvesCell(
            hit: hit(6), cachedRow: page, live: live,
            indicator: (current: 1, total: 9), totalPages: 9
        ))
    }

    // MARK: - Stepping between pages

    /// Logic remembers the last page, so the walk starts wherever the previous
    /// call left it. Stepping straight to the match beats walking home first:
    /// measured 2026-09-02, a 9-page read leaves the next call an 8-press
    /// (472 ms) walk home, and a 64-page one leaves ~3.5 s of it.
    func testTheWalkStepsInWhicheverDirectionIsShorter() {
        XCTAssertEqual(MCUController.pageStepPlan(from: 9, to: 3).steps, 6)
        XCTAssertFalse(MCUController.pageStepPlan(from: 9, to: 3).forward)
        XCTAssertEqual(MCUController.pageStepPlan(from: 1, to: 4).steps, 3)
        XCTAssertTrue(MCUController.pageStepPlan(from: 1, to: 4).forward)
        XCTAssertEqual(MCUController.pageStepPlan(from: 5, to: 5).steps, 0)
    }

    /// No wrap. Whether cursor-right rolls over from the last page to the
    /// first is UNMEASURED, and a wrong guess would land the write on a page
    /// the caller never named.
    func testTheWalkNeverWrapsAround() {
        XCTAssertEqual(MCUController.pageStepPlan(from: 64, to: 1).steps, 63)
    }

    // MARK: - The positive page settle

    /// The 150 ms silence window this replaces timed out 16/16 with zero
    /// variance — a fixed sleep wearing a poll's clothes. The positive check
    /// is the same comparison the walk performs three lines later.
    func testACachedRowIsRecognisedAsSoonAsLogicPaintsIt() {
        XCTAssertTrue(MCUController.cachedRowVisible(cached: page, live: page))
    }

    func testACellStillCarryingTheIndicatorIsNoEvidenceEitherWay() {
        var live = page
        live[5] = "Page 2"
        XCTAssertTrue(MCUController.cachedRowVisible(cached: page, live: live))
    }

    func testThePreviousPagesRowIsNotMistakenForThisOne() {
        var live = page
        live[0] = "AmpEnv"
        XCTAssertFalse(MCUController.cachedRowVisible(cached: page, live: live))
    }

    func testAShortRowProvesNothing() {
        XCTAssertFalse(MCUController.cachedRowVisible(cached: page, live: ["a", "b"]))
    }

    // MARK: - What the tools leave behind

    /// Both instrument views are recorded in the SAME debt vocabulary
    /// `logic_load_instrument` uses, and both are the auto-open hazard the
    /// deferral exists to keep track of.
    func testTheInstrumentViewsAreRecordedAsDebtsAgainstTheirStrip() {
        XCTAssertEqual(
            MCUController.instrumentEditDebt(strip: "808"),
            MCUController.SurfaceDebt(strip: "808", view: "instrument_edit", slot: nil)
        )
        XCTAssertEqual(
            MCUController.instrumentBankDebt(strip: "808"),
            MCUController.SurfaceDebt(strip: "808", view: "instrument_bank", slot: nil)
        )
        XCTAssertTrue(MCUController.isPluginEditAssignment(MCULCDStrings.Assignment.instrument))
    }

    /// A debt on the same strip is what the next call REUSES; a selection onto
    /// any other strip settles it first.
    func testTheInstrumentDebtIsReusedOnItsOwnStripOnly() {
        MCUController.deferSurfaceRestore(MCUController.instrumentEditDebt(strip: "808"))
        XCTAssertFalse(MCUController.settleSurfaceDebt(before: "808"))
        XCTAssertNotNil(MCUController.surfaceDebt)
    }
}
