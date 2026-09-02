import Foundation
import LogicMCUBridge
import XCTest
@testable import Logician

/// The pure half of the control-surface INSTRUMENT browser, as it stands after
/// round 2 (2026-09-02) wired the plug-in browser's machinery to it.
///
/// Three of these rules exist because a correct call lied. The slot-name test
/// reported a working destructive load as `verification_failed`; the head-cut
/// matcher exists because an entry too long for the shared row is captured with
/// its head missing and the exact-name test could then never match it; and the
/// already-loaded decision exists because a tool advertising `idempotent: true`
/// failed the repeat call in 4.9 s with the answer already in hand.
final class InstrumentBrowserTests: XCTestCase {

    // MARK: - The arithmetic the jump is planned with

    func testOneTickPerEntryMakesOneMessageWorthSixtyTwoEntries() {
        // The plug-in browser advances every two ticks and the send browser
        // every one; this one is the send browser's arithmetic with the plug-in
        // browser's jump planner, so a 62-tick message carries 62 entries.
        XCTAssertEqual(MCUController.instrumentBrowseTicksPerEntry, 1)
        let plan = MCUController.browseJumpPlan(
            ticks: 62 * MCUController.instrumentBrowseTicksPerEntry
        )
        XCTAssertEqual(plan, [62])
    }

    func testAJumpSplitsIntoWholeMessagesAndSumsBackExactly() {
        let entries = 150
        let plan = MCUController.browseJumpPlan(
            ticks: entries * MCUController.instrumentBrowseTicksPerEntry
        )
        XCTAssertEqual(plan, [62, 62, 26])
        XCTAssertEqual(
            plan.reduce(0, +) / MCUController.instrumentBrowseTicksPerEntry, entries
        )
        // Backwards is the same plan mirrored — a jump has to be able to come
        // home, which is what made it trustworthy on the plug-in browser.
        XCTAssertEqual(MCUController.browseJumpPlan(ticks: -entries), [-62, -62, -26])
    }

    // MARK: - How much room the shared row leaves

    func testTheWindowNarrowsSevenCharactersPerStrip() {
        // 56 columns less the final separator column, which Logic never paints
        // an entry into: measured 2026-09-02, five over-long entries on strip 5
        // all ended at column 54 and were captured 27 characters long.
        XCTAssertEqual(MCUController.instrumentBrowseWindowWidth(channel: 0), 55)
        XCTAssertEqual(MCUController.instrumentBrowseWindowWidth(channel: 4), 27)
        XCTAssertEqual(MCUController.instrumentBrowseWindowWidth(channel: 7), 6)
    }

    // MARK: - Reading one entry off the shared row

    /// A 56-column row with `text` painted from `column`, and the remaining
    /// strips' slot names left where the bank view puts them.
    private func row(_ pieces: [(column: Int, text: String)]) -> String {
        var characters = Array(repeating: Character(" "), count: MCULCDRow.length)
        for piece in pieces {
            for (offset, character) in piece.text.enumerated()
            where piece.column + offset < MCULCDRow.length {
                characters[piece.column + offset] = character
            }
        }
        return String(characters)
    }

    func testTheNeighbouringStripsSlotNameIsCutOffTheCapture() {
        // The exact capture from warm run 4, step 0 (2026-09-02): the entry
        // ended three columns short of strip 6's cell, so the old four-space
        // cut missed and `Samplr` rode along as part of the entry.
        let bottom = row([(28, "ARP 2600 V3 Stereo"), (49, "Samplr")])
        var slots = Array(repeating: "", count: 8)
        slots[6] = "AnlLab"
        slots[7] = "Samplr"
        XCTAssertEqual(
            MCUController.instrumentBrowseWindow(row: bottom, channel: 4, slotRow: slots),
            "ARP 2600 V3 Stereo"
        )
    }

    func testANeighbourButtedRIGHTUpAgainstTheEntryIsStillCutOff() {
        // The case a gap-based cut cannot see at all: the entry ends in the
        // last column of its cell, so there is no gap before the next slot
        // name. The pre-browse slot row says where that name starts.
        // 21 characters from strip 5's cell ends in column 48, the last column
        // of strip 7's cell; strip 8's slot name starts in column 49.
        let bottom = row([(28, "Sculpture Legacy Mono"), (49, "Bas")])
        var slots = Array(repeating: "", count: 8)
        slots[7] = "Bas"
        XCTAssertEqual(
            MCUController.instrumentBrowseWindow(row: bottom, channel: 4, slotRow: slots),
            "Sculpture Legacy Mono"
        )
    }

    func testTheEmptySlotMarkerIsStillTakenBackOff() {
        let bottom = row([(28, "Sampler Stereo"), (49, "--")])
        XCTAssertEqual(
            MCUController.instrumentBrowseWindow(
                row: bottom, channel: 4, slotRow: Array(repeating: "", count: 8)
            ),
            "Sampler Stereo"
        )
    }

    // MARK: - The head-cut entry (D2)

    func testAnEntryTooLongForTheRowIsRecognisedByItsTail() {
        // `Drum Kit Designer Multi-Output` is 30 characters and strip 5 leaves
        // 27, so Logic paints it shifted left and the capture reads
        // `m Kit Designer Multi-Output`. Before this, that instrument simply
        // could not be loaded on that strip: the walk ran to the cap and
        // refused with "never showed it".
        let captured = "m Kit Designer Multi-Output"
        XCTAssertEqual(
            MCUController.instrumentBrowseMatch(
                captured: captured, request: "Drum Kit Designer",
                format: "Multi-Output", windowWidth: 27
            ),
            .headCut(full: "Drum Kit Designer Multi-Output")
        )
        // Given bare, the same tail identifies the format that landed.
        XCTAssertEqual(
            MCUController.instrumentBrowseMatch(
                captured: captured, request: "Drum Kit Designer",
                format: nil, windowWidth: 27
            ),
            .headCut(full: "Drum Kit Designer Multi-Output")
        )
    }

    func testAWholeEntryIsStillAnExactMatchAndNeverAHeadCutOne() {
        XCTAssertEqual(
            MCUController.instrumentBrowseMatch(
                captured: "Drum Kit Designer Stereo", request: "Drum Kit Designer",
                format: nil, windowWidth: 55
            ),
            .exact
        )
    }

    func testATailIsOnlyTrustedWhenItFillsTheRowToItsEnd() {
        // A capture with room to spare is a WHOLE entry — nothing was shifted —
        // so a coincidental tail must not pass. `Designer Stereo` is a suffix
        // of `Drum Kit Designer Stereo` and is not it.
        XCTAssertEqual(
            MCUController.instrumentBrowseMatch(
                captured: "Designer Stereo", request: "Drum Kit Designer",
                format: "Stereo", windowWidth: 55
            ),
            .none
        )
    }

    func testATailIsRefusedOnAWindowTooNarrowToIdentifyAnEntry() {
        // Strip 8 leaves six characters, and `-Output` names a dozen entries.
        // The browse never gets that far: the load is refused up front. This is
        // the matcher half of that rule.
        XCTAssertEqual(
            MCUController.instrumentBrowseMatch(
                captured: "-Output", request: "Drum Kit Designer",
                format: "Multi-Output", windowWidth: 6
            ),
            .none
        )
    }

    func testADifferentInstrumentsTailIsNotAMatch() {
        XCTAssertEqual(
            MCUController.instrumentBrowseMatch(
                captured: "bey Road Saturator (m) Mono", request: "Drum Kit Designer",
                format: nil, windowWidth: 27
            ),
            .none
        )
    }

    func testACaptureThatFillsTheWindowIsKeptOutOfTheCatalogMap() {
        // A head-cut name means something different on another strip, so it
        // must never be recorded as a coordinate other browses will read.
        XCTAssertTrue(MCUController.instrumentEntryMayBeHeadCut(
            "m Kit Designer Multi-Output", windowWidth: 27
        ))
        XCTAssertFalse(MCUController.instrumentEntryMayBeHeadCut(
            "Sampler Stereo", windowWidth: 27
        ))
    }

    // MARK: - Reading the slot cell back (D1)

    func testTheSlotCellNamesAnInstrumentLogicAbbreviatedPastSixCharacters() {
        // The load that worked and was reported as a failure, with
        // `restored: false`, on a `safety: .destructive` tool.
        XCTAssertTrue(MCUController.instrumentSlotNames("ARPV3", instrument: "ARP 2600 V3"))
    }

    func testTheSlotCellNamesAnInstrumentAbbreviatedInsideItsFirstThreeCharacters() {
        // The other half: `axNamesPlugin` alone rejects these, because Logic
        // drops characters inside the first three on this row.
        XCTAssertTrue(
            MCUController.instrumentSlotNames("DrmKit", instrument: "Drum Kit Designer")
        )
        XCTAssertTrue(
            MCUController.instrumentSlotNames("AnlLab", instrument: "Analog Lab V")
        )
    }

    func testAnUnrelatedSlotCellIsStillARefusal() {
        XCTAssertFalse(
            MCUController.instrumentSlotNames("Comprs", instrument: "Drum Kit Designer")
        )
        XCTAssertFalse(MCUController.instrumentSlotNames("--", instrument: "Sampler"))
        XCTAssertFalse(MCUController.instrumentSlotNames("", instrument: "Sampler"))
    }

    // MARK: - The already-loaded decision (D6)

    func testTheSlotAlreadyHoldingTheInstrumentIsAnsweredWithoutBrowsing() {
        XCTAssertTrue(MCUController.instrumentSlotAlreadyHolds(
            slot: "DrmKit", request: "Drum Kit Designer", format: nil
        ))
        XCTAssertTrue(MCUController.instrumentSlotAlreadyHolds(
            slot: "*DrmKit", request: "drum kit designer", format: nil
        ))
    }

    func testANamedFormatAlwaysBrowses() {
        // The slot cell is six characters and carries no channel format, so it
        // cannot say whether the track holds the Stereo or the Multi-Output
        // twin. Refusing the shortcut is what keeps this honest — and it is the
        // caller's deterministic way to force a genuine reload.
        XCTAssertFalse(MCUController.instrumentSlotAlreadyHolds(
            slot: "DrmKit", request: "Drum Kit Designer", format: "Multi-Output"
        ))
        XCTAssertFalse(MCUController.instrumentSlotAlreadyHolds(
            slot: "DrmKit", request: "Drum Kit Designer Stereo", format: nil
        ))
    }

    func testAnEmptyOrDifferentSlotIsNotAlreadyLoaded() {
        XCTAssertFalse(MCUController.instrumentSlotAlreadyHolds(
            slot: "--", request: "Drum Kit Designer", format: nil
        ))
        XCTAssertFalse(MCUController.instrumentSlotAlreadyHolds(
            slot: "", request: "Drum Kit Designer", format: nil
        ))
        XCTAssertFalse(MCUController.instrumentSlotAlreadyHolds(
            slot: "Samplr", request: "Drum Kit Designer", format: nil
        ))
    }

    // MARK: - The catalog map, reused

    func testTheMapAnswersAnInstrumentRequestByTheSameTestTheWalkUses() {
        var map = InstrumentCatalogMap()
        map.merge([
            .init(name: "Drum Kit Designer Stereo", position: 5),
            .init(name: "Drum Kit Designer Multi-Output", position: 6),
            .init(name: "Analog Lab V Stereo", position: 59)
        ], coveredPositions: 59)
        XCTAssertEqual(map.instrumentPosition(matching: "Analog Lab V", format: nil), 59)
        // A named format picks its own entry, not the first name match.
        XCTAssertEqual(
            map.instrumentPosition(matching: "Drum Kit Designer", format: "Multi-Output"), 6
        )
        XCTAssertEqual(map.instrumentPosition(matching: "Drum Kit Designer", format: nil), 5)
        XCTAssertNil(map.instrumentPosition(matching: "Sampler", format: nil))
    }

    func testTheMapAnchorsABrowseThatDidNotStartAtTheOrigin() {
        // A track that already holds an instrument starts its browse somewhere
        // in the middle of the list, so the origin is unknown — but an entry
        // the map recognises says where the browse is standing, and that is
        // enough to jump from.
        var map = InstrumentCatalogMap()
        map.merge([
            .init(name: "Sampler Stereo", position: 12),
            .init(name: "Analog Lab V Stereo", position: 59)
        ], coveredPositions: 59)
        XCTAssertEqual(map.position(ofExactly: "Sampler Stereo"), 12)
        XCTAssertNil(map.position(ofExactly: "m Kit Designer Multi-Output"))
    }

    // MARK: - The parameter page that is not one (D7)

    /// The bank view's own top row on the strip these proofs were taken on.
    private static let namesRow = "LofPad Bas    808    Inst 2 Inst 9 Drums  Fill   AckSlg "

    func testARowOfDashesIsReportedAsUnavailableRatherThanAsEvidence() {
        // Measured 2026-09-02: `Analog Lab V` and both Audio Unit loads the
        // profile watched produced only dashes here, while Logic's own Drum Kit
        // Designer produced a real page. The field is advertised as "the first
        // sign it took", so it must not hand back punctuation as if it were one.
        let dashes = "-      -      -      -      -      -      -      -"
        XCTAssertNotNil(MCUController.instrumentEditPageEvidence(
            dashes, bankNamesRow: Self.namesRow, channel: 4
        ) as? [String: String])
    }

    func testTheChannelNamesRowIsNotAParameterPageEither() {
        // The exact row `ARP 2600 V3` came back with, 2026-09-02: the names row
        // with Logic's transient `Select` banner over the browsed strip's cell.
        // Reporting that as the instrument's parameter page would be evidence
        // of nothing dressed up as evidence of the load.
        let afterConfirm = "LofPad Bas    808    Inst 2 Select Drums  Fill   AckSlg"
        XCTAssertNotNil(MCUController.instrumentEditPageEvidence(
            afterConfirm, bankNamesRow: Self.namesRow, channel: 4
        ) as? [String: String])
    }

    func testARealParameterPageIsReportedAsItself() {
        // What Logic's own Drum Kit Designer painted, live, on the same strip.
        let page = "Kit    InMapp Kick   KicMut KicTun KicDam KicGai KicLea"
        XCTAssertEqual(
            MCUController.instrumentEditPageEvidence(
                page, bankNamesRow: Self.namesRow, channel: 4
            ) as? String,
            page
        )
    }
}
