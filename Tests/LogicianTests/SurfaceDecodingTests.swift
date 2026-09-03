import Foundation
import LogicMCUBridge
import XCTest
@testable import Logician

/// The pure decoding behind the strip census, the instrument browser and the
/// automation read. No Logic, no bridge. Each of these turns Logic's own echo
/// into an answer an agent acts on: a wrong strip inventory attributes a mixer
/// reading to the wrong track, a wrong browser match instantiates the wrong
/// instrument, and a wrong sampling grid reports a curve the project has not
/// got — none of which fails visibly.
final class SurfaceDecodingTests: XCTestCase {

    // MARK: - Strip inventory

    /// The reference project's real bank map, read off the surface 2026-08-28
    /// (`Testlåt Copy`, 26 strips, so the rightmost bank clamps by one).
    private let referenceBanks = [
        "LofPad Bas    Inst 9 808    Inst 2 Drums  Fill   AckSlg ",
        "IvnSlg DrSyKi Vocals IvnVoc IvnVoc IvanFx AckVoc Sweeps ",
        "Crash  Vinyl  Audio8 Audio9 Aux 1  Aux 2  Aux 3  SP/1.3 ",
        "Vinyl  Audio8 Audio9 Aux 1  Aux 2  Aux 3  SP/1.3 St Out "
    ]

    func testInventoryDropsTheClampedBanksRepeats() {
        let strips = MCUController.stripInventory(bankTops: referenceBanks)
        // Three full banks plus the one strip the clamped bank genuinely adds.
        XCTAssertEqual(strips.count, 25)
        XCTAssertEqual(strips.first?.cell, "LofPad")
        XCTAssertEqual(strips.last?.cell, "St Out")
        XCTAssertEqual(strips.last?.position, 25)
        // Every name appears once, even the six the clamped bank re-shows.
        XCTAssertEqual(strips.filter { $0.cell == "Vinyl" }.count, 1)
        XCTAssertEqual(strips.filter { $0.cell == "Aux 1" }.count, 1)
        // A duplicate TRACK NAME is not a clamp repeat and must survive: two
        // tracks are genuinely called "Ivan Vocals".
        XCTAssertEqual(strips.filter { $0.cell == "IvnVoc" }.count, 2)
    }

    func testClampedStripKeepsTheEarliestBankAddress() {
        let strips = MCUController.stripInventory(bankTops: referenceBanks)
        // `Vinyl` is on bank 2 channel 1 and re-shown on bank 3 channel 0; the
        // address kept must be the one on the bank that is not clamped.
        let vinyl = strips.first { $0.cell == "Vinyl" }
        XCTAssertEqual(vinyl?.bank, 2)
        XCTAssertEqual(vinyl?.channel, 1)
        // The one strip only the clamped bank shows keeps that bank's address.
        let output = strips.first { $0.cell == "St Out" }
        XCTAssertEqual(output?.bank, 3)
        XCTAssertEqual(output?.channel, 7)
    }

    func testInventoryWithNoClampKeepsEveryBankWhole() {
        // A strip count that divides by 8: the last bank shares nothing.
        let banks = [
            "One    Two    Three  Four   Five   Six    Seven  Eight  ",
            "Nine   Ten    Eleven Twelve Thirtn Fourtn Fiftn  Sixtn  "
        ]
        let strips = MCUController.stripInventory(bankTops: banks)
        XCTAssertEqual(strips.count, 16)
        XCTAssertEqual(strips.map(\.position), Array(1...16))
    }

    func testInventoryIgnoresBlankAndClearingCells() {
        // A project of three strips: Logic pads the bank with empty cells, and
        // paints a lone "-" while it is clearing one.
        let strips = MCUController.stripInventory(
            bankTops: ["Kick   Snare  Hat    -                            "]
        )
        XCTAssertEqual(strips.map(\.cell), ["Kick", "Snare", "Hat"])
    }

    func testEmptyBankMapYieldsNoStrips() {
        XCTAssertTrue(MCUController.stripInventory(bankTops: []).isEmpty)
    }

    // MARK: - LED note decoding

    /// The four per-strip LED rows of the Mackie protocol, as Logic drives
    /// them: rec/ready 0x00-0x07, solo 0x08-0x0F, mute 0x10-0x17, select
    /// 0x18-0x1F. Read off the reference project 2026-08-28.
    func testDecodesTheFourPerStripLedRows() {
        // Strip 3 armed, strip 1 muted, strip 8 soloed, strip 3 selected,
        // plus the transport and mode LEDs that share the same mirror.
        let status: [String: Any] = ["leds_lit": [0x02, 0x0F, 0x10, 0x1A, 0x2A, 0x4A, 0x5D, 0x72]]
        XCTAssertEqual(MCUController.recArmedStrips(in: status), [2])
        XCTAssertEqual(MCUController.soloedStrips(in: status), [7])
        XCTAssertEqual(MCUController.mutedStrips(in: status), [0])
        XCTAssertEqual(MCUController.selectedStrips(in: status), [2])
    }

    func testLedRowsDoNotBleedIntoEachOther() {
        // 0x08 is solo strip 1, NOT rec strip 9 — the rows are eight wide and
        // an off-by-one here reports a soloed track as record-armed.
        let solo1: [String: Any] = ["leds_lit": [0x08]]
        XCTAssertEqual(MCUController.recArmedStrips(in: solo1), [])
        XCTAssertEqual(MCUController.soloedStrips(in: solo1), [0])
        // 0x18 is select strip 1, not mute strip 9.
        let select1: [String: Any] = ["leds_lit": [0x18]]
        XCTAssertEqual(MCUController.mutedStrips(in: select1), [])
        XCTAssertEqual(MCUController.selectedStrips(in: select1), [0])
    }

    func testNoLedsLitDecodesToNothingRatherThanFailing() {
        XCTAssertEqual(MCUController.recArmedStrips(in: ["leds_lit": [Int]()]), [])
        // A status with no LED key at all is a mirror that has never been
        // painted; it must read as "nothing lit", not crash.
        XCTAssertEqual(MCUController.recArmedStrips(in: [:]), [])
        XCTAssertEqual(MCUController.selectedStrips(in: [:]), [])
    }

    /// Note 0x73 is the whole-project answer: it is lit while ANY channel is
    /// soloed, including one with no strip in the showing bank and one with no
    /// track header at all. Every other solo read here is bank-relative.
    func testTheRudeSoloIndicatorIsReadWholeProject() {
        XCTAssertEqual(MCUController.rudeSoloLED, 0x73)
        // A soloed strip in the showing bank lights both.
        let visible: [String: Any] = ["leds_lit": [0x08, 0x73]]
        XCTAssertTrue(MCUController.anySoloedStrip(in: visible))
        XCTAssertEqual(MCUController.soloedStrips(in: visible), [0])
        // A soloed track OUTSIDE the showing bank lights only 0x73 — this is
        // the case the per-strip read cannot see and a stem set must not miss.
        let hidden: [String: Any] = ["leds_lit": [0x73]]
        XCTAssertTrue(MCUController.anySoloedStrip(in: hidden))
        XCTAssertEqual(MCUController.soloedStrips(in: hidden), [])
        XCTAssertFalse(MCUController.anySoloedStrip(in: ["leds_lit": [0x08 + 8, 0x72]]))
        XCTAssertFalse(MCUController.anySoloedStrip(in: [:]))
    }

    // MARK: - Bank rows

    /// The transient press banner: Logic paints the name of the control it just
    /// saw over the touched strip's NAME cell (`Bas` → `Solo`) and leaves it
    /// there until something else repaints the row. Read off the live surface
    /// 2026-09-02.
    private let mappedBank = "LofPad Bas    808    Inst 2 Drums  Fill   AckSlg IvnSlg "
    private let bannerBank = "LofPad Solo   808    Inst 2 Drums  Fill   AckSlg IvnSlg "

    func testAnExactRowIsStillTheFirstAnswer() {
        XCTAssertTrue(MCUController.bankedAtMatch(live: mappedBank, cached: mappedBank, channel: 1))
    }

    /// The banner sits on strip 2 while the call is about strip 3 — the bank is
    /// the right one and the target cell reads its own name, so this must not
    /// pay a full re-navigation to the bank it is already on.
    func testAPressBannerOnAnotherStripDoesNotHideTheBank() {
        XCTAssertTrue(MCUController.bankedAtMatch(live: bannerBank, cached: mappedBank, channel: 2))
    }

    /// The banner sits on the very cell about to be written, and nothing says
    /// where it came from: the live display cannot confirm the target strip, so
    /// this falls through to the walk. (Which is right — and cost 1.6-1.7 s on
    /// every same-channel repeat until the caller started saying "that banner
    /// is mine"; see the tests below.)
    func testABannerOnTheTargetCellIsNotAcceptedWithoutEvidence() {
        XCTAssertFalse(MCUController.bankedAtMatch(live: bannerBank, cached: mappedBank, channel: 1))
    }

    /// FS-1, measured live 2026-09-03: mute a track (833 ms) and the very next
    /// call about the SAME track paid 2 407 ms, because Logic had painted
    /// `Mute` over that strip's own name cell and the cache could not tell its
    /// own echo from a stale map. With the caller's evidence that the banner is
    /// this server's own press, the bank the surface never left is accepted.
    func testOurOwnPressBannerOnTheTargetCellKeepsTheFastPath() {
        XCTAssertTrue(
            MCUController.bankedAtMatch(
                live: bannerBank, cached: mappedBank, channel: 1, ownPressBannerCells: 1
            )
        )
        // Both spellings, both planes' controls: `Mute` reads exactly like
        // `Solo` here, which is the point of one shared banner list.
        let muteBanner = "LofPad Mute   808    Inst 2 Drums  Fill   AckSlg IvnSlg "
        XCTAssertTrue(
            MCUController.bankedAtMatch(
                live: muteBanner, cached: mappedBank, channel: 1, ownPressBannerCells: 1
            )
        )
    }

    /// The wildcard is for a BANNER, not for any surprise. A track renamed
    /// under a stale map changes exactly one cell too (the rename profile's
    /// finding), and that one must still be discovered and rescanned — even
    /// while the caller believes it just pressed something there.
    func testARenamedCellIsNotABannerEvenWithTheEvidence() {
        let renamed = "LofPad Bass 2 808    Inst 2 Drums  Fill   AckSlg IvnSlg "
        XCTAssertFalse(
            MCUController.bankedAtMatch(
                live: renamed, cached: mappedBank, channel: 1, ownPressBannerCells: 1
            )
        )
    }

    /// The one-cell budget is not widened by the wildcard: the banner IS the
    /// one cell allowed to differ.
    func testABannerPlusAnotherChangedCellStillTakesTheWalk() {
        let bannerAndDrift = "LofPad Solo   808    Inst 2 Drums  Fill   AckSlg Sweeps "
        XCTAssertFalse(
            MCUController.bankedAtMatch(
                live: bannerAndDrift, cached: mappedBank, channel: 1, ownPressBannerCells: 1
            )
        )
    }

    /// The safety property the whole fix hangs on: a banner cannot make one
    /// bank pass as another, so the wildcard can never resolve to the wrong
    /// channel. Every neighbouring bank is a SHIFTED window and differs in
    /// seven or eight cells; painting a banner into any cell of it changes
    /// nothing about that.
    func testTheWildcardCannotMakeADifferentBankPass() {
        for (index, bank) in referenceBanks.enumerated() where index > 0 {
            for channel in 0..<8 {
                let cells = MCUController.lcdFields(bank)
                let withBanner = cells.enumerated()
                    .map { ($0.offset == channel ? "Mute" : $0.element).padding(
                        toLength: MCULCDRow.cellWidth, withPad: " ", startingAt: 0
                    ) }
                    .joined()
                XCTAssertFalse(
                    MCUController.bankedAtMatch(
                        live: withBanner, cached: referenceBanks[0],
                        channel: channel, ownPressBannerCells: 1
                    ),
                    "bank \(index) with a banner on strip \(channel + 1) passed as bank 0"
                )
            }
        }
    }

    // MARK: - Whose banner is it

    func testABannerCellIsRecognisedPaddedOrTrimmed() {
        for cell in MCULCDStrings.controlNameBannerCells {
            XCTAssertTrue(MCUController.isControlBannerCell(cell))
            XCTAssertTrue(MCUController.isControlBannerCell(cell + "  "))
        }
        XCTAssertFalse(MCUController.isControlBannerCell("Bas   "))
        XCTAssertFalse(MCUController.isControlBannerCell(""))
    }

    /// Three things must agree before a cell is excused, and each of them is
    /// the one that stops a different wrong answer.
    func testOnlyOurOwnFreshPressOnThisStripEarnsTheWildcard() {
        let now = Date()
        let record = MCUController.ControlPressBanner(track: "Bas", channel: 1, at: now)
        XCTAssertTrue(
            MCUController.ownPressBannerStanding(record, track: "Bas", channel: 1, now: now)
        )
        // Another track's resolution never gets it, even on the same strip.
        XCTAssertFalse(
            MCUController.ownPressBannerStanding(record, track: "808", channel: 1, now: now)
        )
        // Nor another strip's, even for the same track.
        XCTAssertFalse(
            MCUController.ownPressBannerStanding(record, track: "Bas", channel: 2, now: now)
        )
        // Nothing pressed, nothing excused.
        XCTAssertFalse(
            MCUController.ownPressBannerStanding(nil, track: "Bas", channel: 1, now: now)
        )
    }

    /// The banner is a timed transient — measured at 1.94 and 1.99 s — and the
    /// wildcard expires with it. Past the budget the cell has repainted itself,
    /// so the exact match works again and a stale record must not be able to
    /// excuse anything.
    func testTheWildcardExpiresWithTheBanner() {
        let pressed = Date()
        let record = MCUController.ControlPressBanner(track: "Bas", channel: 1, at: pressed)
        // The evidence has to outlive the longest stand anyone has seen (~6 s
        // on the solo profile), not the wait budget's 1.94-1.99 s measurement.
        XCTAssertGreaterThan(
            MCUController.ownPressBannerTrustSeconds, MCUController.controlBannerFadeBudget
        )
        XCTAssertTrue(
            MCUController.ownPressBannerStanding(
                record, track: "Bas", channel: 1,
                now: pressed.addingTimeInterval(MCUController.ownPressBannerTrustSeconds - 0.1)
            )
        )
        XCTAssertFalse(
            MCUController.ownPressBannerStanding(
                record, track: "Bas", channel: 1,
                now: pressed.addingTimeInterval(MCUController.ownPressBannerTrustSeconds + 0.1)
            )
        )
        // A record from the future is a clock that moved, not a fresh press.
        XCTAssertFalse(
            MCUController.ownPressBannerStanding(
                record, track: "Bas", channel: 1, now: pressed.addingTimeInterval(-1)
            )
        )
    }

    // MARK: - The poisoned cache (FS-4)

    /// The exact row pair the solo profile caught in the debug log: a full scan
    /// captured `Solo` as `808`'s name and wrote it to disk, so the CACHED row
    /// is the wrong one and the live surface is right.
    private let poisonedBank = "LofPad Bas    Solo   Inst 2 Drums  Fill   AckSlg IvnSlg "
    private let cleanBank = "LofPad Bas    808    Inst 2 Drums  Fill   AckSlg IvnSlg "

    /// A map with a banner in it must never reach `bank-cache.json`: on disk it
    /// outlives the banner, and every later resolution that lands on that bank
    /// pays a wait that cannot succeed.
    func testABankMapCarryingABannerIsNotCacheable() {
        XCTAssertTrue(MCUController.bankMapCacheable(referenceBanks))
        XCTAssertFalse(
            MCUController.bankMapCacheable(referenceBanks + [poisonedBank])
        )
        for cell in MCULCDStrings.controlNameBannerCells {
            let row = "LofPad " + cell.padding(
                toLength: MCULCDRow.cellWidth, withPad: " ", startingAt: 0
            ) + "808    Inst 2 Drums  Fill   AckSlg IvnSlg "
            XCTAssertFalse(MCUController.bankMapCacheable([row]), cell)
        }
    }

    /// Arrival at a bank is now judged by the same one-cell rule as "am I
    /// already here", so a cache poisoned in some OTHER cell no longer costs a
    /// guaranteed-fail 1.5 s wait (4 332 ms for one solo restore, measured).
    func testAPoisonedCellElsewhereDoesNotHideTheRightBank() {
        XCTAssertTrue(
            MCUController.bankedAtMatch(live: cleanBank, cached: poisonedBank, channel: 3)
        )
    }

    /// …but a cache poisoned on the TARGET's own cell still cannot confirm the
    /// strip about to be written, with or without a press record — the live
    /// cell says `808` where the map says `Solo`, and that disagreement is the
    /// map's, not a banner's.
    func testAPoisonedTargetCellStillFallsThroughToTheRescan() {
        XCTAssertFalse(
            MCUController.bankedAtMatch(live: cleanBank, cached: poisonedBank, channel: 2)
        )
        XCTAssertFalse(
            MCUController.bankedAtMatch(
                live: cleanBank, cached: poisonedBank, channel: 2, ownPressBannerCells: 1
            )
        )
    }

    func testADifferentBankIsNeverMistakenForABanner() {
        for (index, bank) in referenceBanks.enumerated() where index > 0 {
            XCTAssertFalse(
                MCUController.bankedAtMatch(live: bank, cached: referenceBanks[0], channel: 0),
                "bank \(index) passed as bank 0"
            )
        }
        // The clamped rightmost bank is the previous one SHIFTED, which is the
        // nearest thing to a near-miss this surface produces.
        XCTAssertFalse(
            MCUController.bankedAtMatch(
                live: referenceBanks[3], cached: referenceBanks[2], channel: 1
            )
        )
    }

    func testTwoCellsOutIsAStaleMapAndTakesTheWalk() {
        let twoOut = "LofPad Solo   Mute   Inst 2 Drums  Fill   AckSlg IvnSlg "
        XCTAssertFalse(MCUController.bankedAtMatch(live: twoOut, cached: mappedBank, channel: 3))
    }

    // MARK: - The banner that is wider than a cell (record-arm)

    /// Eight cells joined the way the surface paints them, so a test row is
    /// written as what it says rather than as 56 counted spaces.
    private func row(_ cells: [String]) -> String {
        cells.map { $0.padding(toLength: MCULCDRow.cellWidth, withPad: " ", startingAt: 0) }
            .joined()
    }

    /// MEASURED live 2026-09-03 on `Testlåt Copy`: arming `Bas` (strip 2,
    /// `808` beside it) paints `Record Enable` from that strip's cell ORIGIN,
    /// which is thirteen characters and therefore two cells — the touched
    /// strip's and its right-hand neighbour's. Everything else Logic paints on
    /// a per-strip press fits inside one.
    func testTheRecordArmBannerIsTwoCellsAndTheRestAreOne() {
        XCTAssertEqual(MCULCDStrings.bannerCells(MCULCDStrings.recordArmBanner), ["Record", "Enable"])
        XCTAssertEqual(MCULCDStrings.controlNameBannerSpan(MCULCDStrings.recordArmBanner), 2)
        for banner in [MCULCDStrings.muteBanner, MCULCDStrings.soloBanner, MCULCDStrings.selectBanner] {
            XCTAssertEqual(MCULCDStrings.controlNameBannerSpan(banner), 1, banner)
        }
        // Both halves have to be recognizable on their own: the row is read
        // one cell at a time and neither cell spells the whole phrase.
        XCTAssertTrue(MCUController.isControlBannerCell("Record"))
        XCTAssertTrue(MCUController.isControlBannerCell("Enable"))
        XCTAssertFalse(MCUController.isControlBannerCell(MCULCDStrings.recordArmBanner))
    }

    /// The defect this fixes, and its fix, in one pair of assertions. The
    /// arm-on → arm-off pair the guide recommends met two differing cells on
    /// the very next resolution; the one-cell budget could not pass them, so
    /// every repeat paid a full rescan (~5-7 s live) once e7c1a84 made the
    /// press fast enough to land inside Logic's ~2 s banner window.
    func testTheTwoCellArmBannerKeepsTheFastPathOnlyWithATwoCellBudget() {
        let armed = row(["LofPad", "Record", "Enable", "Inst 2", "Drums", "Fill", "AckSlg", "IvnSlg"])
        XCTAssertTrue(
            MCUController.bankedAtMatch(
                live: armed, cached: mappedBank, channel: 1, ownPressBannerCells: 2
            )
        )
        XCTAssertFalse(
            MCUController.bankedAtMatch(
                live: armed, cached: mappedBank, channel: 1, ownPressBannerCells: 1
            )
        )
        XCTAssertFalse(
            MCUController.bankedAtMatch(live: armed, cached: mappedBank, channel: 1)
        )
    }

    /// The span runs RIGHTWARDS from the touched strip and stops there. `808`
    /// lost its cell to the second half of the word, but nobody pressed
    /// anything on `808` — so a resolution of `808` reads the map as stale and
    /// takes the walk, which is the only answer that cannot write to the wrong
    /// strip.
    func testTheSecondHalfIsNeverExcusedForTheStripThatMerelyLostItsCell() {
        let armed = row(["LofPad", "Record", "Enable", "Inst 2", "Drums", "Fill", "AckSlg", "IvnSlg"])
        XCTAssertFalse(
            MCUController.bankedAtMatch(
                live: armed, cached: mappedBank, channel: 2, ownPressBannerCells: 2
            )
        )
        let record = MCUController.ControlPressBanner(track: "Bas", channel: 1, cells: 2, at: Date())
        XCTAssertEqual(
            MCUController.ownPressBannerCells(record, track: "808", channel: 2, now: Date()), 0
        )
    }

    /// A press on the RIGHTMOST strip has no neighbour to bleed into. The span
    /// is clamped to the row rather than reaching past its last cell, so the
    /// one cell that exists is excused and the match still holds.
    func testABannerThatWouldOverlapTheRowsEdgeIsClampedToTheRow() {
        let armedLast = row(["LofPad", "Bas", "808", "Inst 2", "Drums", "Fill", "AckSlg", "Record"])
        XCTAssertTrue(
            MCUController.bankedAtMatch(
                live: armedLast, cached: mappedBank, channel: 7, ownPressBannerCells: 2
            )
        )
        // And it does not wrap round to cell 0: a drift there is still a
        // stale map, budget or no budget.
        let armedLastPlusDrift = row(
            ["Sweeps", "Bas", "808", "Inst 2", "Drums", "Fill", "AckSlg", "Record"]
        )
        XCTAssertFalse(
            MCUController.bankedAtMatch(
                live: armedLastPlusDrift, cached: mappedBank, channel: 7, ownPressBannerCells: 2
            )
        )
    }

    /// The banner's words COLLIDING with real strip names, both directions.
    ///
    /// A neighbour genuinely called `Enable` simply agrees with the map under
    /// the banner, so the press still matches on one differing cell. And a
    /// strip genuinely called `Record` under a STALE map — nobody pressed
    /// anything — is a rename, which must still be discovered: the wildcard is
    /// for a banner this process caused, never for a cell that merely looks
    /// like one.
    func testTheBannersWordsCollidingWithRealTrackNames() {
        let mapWithEnable = row(
            ["LofPad", "Bas", "Enable", "Inst 2", "Drums", "Fill", "AckSlg", "IvnSlg"]
        )
        let armed = row(["LofPad", "Record", "Enable", "Inst 2", "Drums", "Fill", "AckSlg", "IvnSlg"])
        XCTAssertTrue(
            MCUController.bankedAtMatch(
                live: armed, cached: mapWithEnable, channel: 1, ownPressBannerCells: 2
            )
        )
        let renamedToRecord = row(
            ["LofPad", "Record", "808", "Inst 2", "Drums", "Fill", "AckSlg", "IvnSlg"]
        )
        XCTAssertFalse(
            MCUController.bankedAtMatch(live: renamedToRecord, cached: mappedBank, channel: 1)
        )
        // The honest cost of listing the two halves: a strip really called
        // `Record` reads as a banner to the census, which re-reads the row and
        // believes whatever the repaint says. One forced repaint, no wrong
        // name — the trade this list has always made.
        XCTAssertFalse(MCUController.bankMapCacheable([renamedToRecord]))
    }

    /// A two-cell banner must not reach `bank-cache.json` either: on disk it
    /// outlives the banner, and both halves would be published as strip names.
    func testATwoCellBannerIsAlsoRefusedByTheCacheGuard() {
        let armed = row(["LofPad", "Record", "Enable", "Inst 2", "Drums", "Fill", "AckSlg", "IvnSlg"])
        XCTAssertFalse(MCUController.bankMapCacheable(referenceBanks + [armed]))
        XCTAssertEqual(MCUController.controlBannerCell(in: armed), "Record")
        // …and the row-level check that the scan waits on sees it too — the
        // same function `rowWithoutControlBanner` calls once per bank.
        let secondHalfOnly = row(
            ["LofPad", "Bas", "Enable", "Inst 2", "Drums", "Fill", "AckSlg", "IvnSlg"]
        )
        XCTAssertEqual(MCUController.controlBannerCell(in: secondHalfOnly), "Enable")
    }

    /// The safety property, re-proved at two cells: a wider wildcard still
    /// cannot make one bank pass as another. Neighbouring banks are SHIFTED
    /// windows differing in seven or eight cells, so excusing two of them
    /// leaves five or six.
    func testTheTwoCellWildcardCannotMakeADifferentBankPass() {
        for (index, bank) in referenceBanks.enumerated() where index > 0 {
            for channel in 0..<8 {
                var cells = MCUController.lcdFields(bank)
                cells[channel] = "Record"
                if channel + 1 < cells.count { cells[channel + 1] = "Enable" }
                XCTAssertFalse(
                    MCUController.bankedAtMatch(
                        live: row(cells), cached: referenceBanks[0],
                        channel: channel, ownPressBannerCells: 2
                    ),
                    "bank \(index) with a two-cell banner on strip \(channel + 1) passed as bank 0"
                )
            }
        }
    }

    /// The press site names the banner it caused and the record carries that
    /// WIDTH, so the matcher never has to guess it from the live row.
    func testThePressSiteRecordsHowWideItsBannerIs() {
        let previous = MCUController.lastControlPressBanner
        defer { MCUController.lastControlPressBanner = previous }
        let pressed = Date()
        MCUController.noteControlPressBanner(
            track: "Bas", channel: 1, banner: MCULCDStrings.recordArmBanner, at: pressed
        )
        XCTAssertEqual(MCUController.lastControlPressBanner?.cells, 2)
        MCUController.noteControlPressBanner(
            track: "Bas", channel: 1, banner: MCULCDStrings.muteBanner, at: pressed
        )
        XCTAssertEqual(MCUController.lastControlPressBanner?.cells, 1)
        // An unknown word is one cell — the narrower span excuses less, never
        // more, so a spelling nobody has measured cannot widen the wildcard.
        MCUController.noteControlPressBanner(
            track: "Bas", channel: 1, banner: "", at: pressed
        )
        XCTAssertEqual(MCUController.lastControlPressBanner?.cells, 1)
    }

    /// The pre-press proof, which the fast path moved rather than solved.
    /// Measured live 2026-09-03: with the resolution no longer waiting the
    /// banner out, five consecutive record-arm calls read `Record` in the
    /// cell and refused a strip they had just proved. A banner is accepted
    /// there — but only ours, only on this strip, and only while it is young.
    func testTheStripIsProvenByItsNameOrByOurOwnBannerAndNothingElse() {
        let now = Date()
        let ours = MCUController.ControlPressBanner(track: "Bas", channel: 1, cells: 2, at: now)
        // The plain reading is the first and usual answer.
        XCTAssertTrue(
            MCUController.stripProvenByCell(
                track: "Bas", cell: "Bas", channel: 1, record: nil, now: now
            )
        )
        // Our own banner, on our own strip, inside the window.
        XCTAssertTrue(
            MCUController.stripProvenByCell(
                track: "Bas", cell: "Record", channel: 1, record: ours, now: now
            )
        )
        // Nobody pressed anything: a cell that merely looks like a banner
        // proves nothing, and the write is refused rather than aimed.
        XCTAssertFalse(
            MCUController.stripProvenByCell(
                track: "Bas", cell: "Record", channel: 1, record: nil, now: now
            )
        )
        // Our press, but a different strip — the second half of the banner
        // landed on `808`'s cell and `808` is not what we pressed.
        XCTAssertFalse(
            MCUController.stripProvenByCell(
                track: "808", cell: "Enable", channel: 2, record: ours, now: now
            )
        )
        // Expired.
        XCTAssertFalse(
            MCUController.stripProvenByCell(
                track: "Bas", cell: "Record", channel: 1, record: ours,
                now: now.addingTimeInterval(MCUController.ownPressBannerTrustSeconds + 0.1)
            )
        )
        // A wrong name that is not a banner is still a wrong strip.
        XCTAssertFalse(
            MCUController.stripProvenByCell(
                track: "Bas", cell: "St Out", channel: 1, record: ours, now: now
            )
        )
    }

    /// The width expires with the rest of the record: past the trust window a
    /// two-cell press excuses nothing at all.
    func testTheTwoCellWidthExpiresWithTheRecord() {
        let pressed = Date()
        let record = MCUController.ControlPressBanner(track: "Bas", channel: 1, cells: 2, at: pressed)
        XCTAssertEqual(
            MCUController.ownPressBannerCells(record, track: "Bas", channel: 1, now: pressed), 2
        )
        XCTAssertEqual(
            MCUController.ownPressBannerCells(
                record, track: "Bas", channel: 1,
                now: pressed.addingTimeInterval(MCUController.ownPressBannerTrustSeconds + 0.1)
            ),
            0
        )
        XCTAssertTrue(
            MCUController.ownPressBannerStanding(record, track: "Bas", channel: 1, now: pressed)
        )
    }

    // MARK: - Instrument browser entries

    func testSplitsLogicsChannelFormatOffAnEntry() {
        XCTAssertEqual(
            MCUController.splitInstrumentEntry("Drum Kit Designer Stereo").name,
            "Drum Kit Designer"
        )
        XCTAssertEqual(
            MCUController.splitInstrumentEntry("Drum Kit Designer Stereo").format, "Stereo"
        )
        XCTAssertEqual(
            MCUController.splitInstrumentEntry("Drum Kit Designer Multi-Output").format,
            "Multi-Output"
        )
        XCTAssertEqual(
            MCUController.splitInstrumentEntry("Ampeg SVTVR Classic Mono").name,
            "Ampeg SVTVR Classic"
        )
        // Logic's inline channel marker is part of the NAME, not the format
        // suffix — it distinguishes two different plug-in entries.
        let saturator = MCUController.splitInstrumentEntry("Abbey Road Saturator (m) Mono")
        XCTAssertEqual(saturator.name, "Abbey Road Saturator (m)")
        XCTAssertEqual(saturator.format, "Mono")
        // No recognised suffix: everything is the name.
        XCTAssertNil(MCUController.splitInstrumentEntry("Analog Lab V").format)
    }

    func testBareRequestMatchesAnyFormatOfThatInstrument() {
        XCTAssertTrue(MCUController.instrumentEntryMatches(
            entry: "Drum Kit Designer Stereo", request: "Drum Kit Designer", format: nil
        ))
        XCTAssertTrue(MCUController.instrumentEntryMatches(
            entry: "Drum Kit Designer Multi-Output", request: "drum kit designer", format: nil
        ))
    }

    func testAFormatNarrowsTheMatchWhicheverWayItIsGiven() {
        XCTAssertTrue(MCUController.instrumentEntryMatches(
            entry: "Drum Kit Designer Multi-Output",
            request: "Drum Kit Designer", format: "Multi-Output"
        ))
        XCTAssertFalse(MCUController.instrumentEntryMatches(
            entry: "Drum Kit Designer Stereo",
            request: "Drum Kit Designer", format: "Multi-Output"
        ))
        // Carried inside the request instead of passed separately.
        XCTAssertTrue(MCUController.instrumentEntryMatches(
            entry: "Drum Kit Designer Stereo", request: "Drum Kit Designer Stereo", format: nil
        ))
        XCTAssertFalse(MCUController.instrumentEntryMatches(
            entry: "Drum Kit Designer Multi-Output",
            request: "Drum Kit Designer Stereo", format: nil
        ))
        // An explicit argument outranks one embedded in the request.
        XCTAssertTrue(MCUController.instrumentEntryMatches(
            entry: "Drum Kit Designer Mono",
            request: "Drum Kit Designer Stereo", format: "Mono"
        ))
    }

    func testMatchingIsExactOnTheNameAndNeverFuzzy() {
        // A prefix is not a match: instantiating "Sampler" when "Sample Alchemy"
        // was asked for is not a small mistake.
        XCTAssertFalse(MCUController.instrumentEntryMatches(
            entry: "Sampler Stereo", request: "Sample Alchemy", format: nil
        ))
        XCTAssertFalse(MCUController.instrumentEntryMatches(
            entry: "Sampler Stereo", request: "Sampl", format: nil
        ))
        XCTAssertFalse(MCUController.instrumentEntryMatches(
            entry: "Augmented STRINGS Stereo", request: "Augmented VOICES", format: nil
        ))
        // Case and diacritics do not: those are display noise.
        XCTAssertTrue(MCUController.instrumentEntryMatches(
            entry: "AUGMENTED STRINGS Stereo", request: "augmented strings", format: nil
        ))
        // The empty slot marker never matches anything.
        XCTAssertFalse(MCUController.instrumentEntryMatches(
            entry: "", request: "Sampler", format: nil
        ))
    }

    // MARK: - Automation sampling grid

    func testSamplesRunFromStartToEndBarInclusive() {
        let positions = MCUController.automationSamplePositions(
            startBar: 2, endBar: 4, beatsPerBar: 4, resolutionBeats: 1, maxPoints: 64
        )
        XCTAssertEqual(positions.count, 9) // 2 bars x 4 beats, plus bar 4 beat 1
        XCTAssertEqual(positions.first?.bar, 2)
        XCTAssertEqual(positions.first?.beat, 1)
        XCTAssertEqual(positions.last?.bar, 4)
        XCTAssertEqual(positions.last?.beat, 1)
        XCTAssertEqual(positions[4].bar, 3)
        XCTAssertEqual(positions[4].beat, 1)
    }

    func testResolutionWidensTheStepRatherThanTruncatingTheRange() {
        // 33 beats of span would be 34 samples at one per beat; capped at 10
        // the step widens until it fits, and the LAST bar is still reached.
        let positions = MCUController.automationSamplePositions(
            startBar: 1, endBar: 9, beatsPerBar: 4, resolutionBeats: 1, maxPoints: 10
        )
        XCTAssertLessThanOrEqual(positions.count, 10)
        XCTAssertEqual(positions.first?.bar, 1)
        XCTAssertEqual(positions.last?.bar, 9)
        XCTAssertEqual(positions.last?.beat, 1)
    }

    func testCoarseResolutionAndOddMeter() {
        let positions = MCUController.automationSamplePositions(
            startBar: 5, endBar: 7, beatsPerBar: 3, resolutionBeats: 3, maxPoints: 64
        )
        XCTAssertEqual(positions.map { "\($0.bar).\($0.beat)" }, ["5.1", "6.1", "7.1"])
    }

    func testASingleBarRangeIsOneSample() {
        let positions = MCUController.automationSamplePositions(
            startBar: 3, endBar: 3, beatsPerBar: 4, resolutionBeats: 1, maxPoints: 64
        )
        XCTAssertEqual(positions.count, 1)
        XCTAssertEqual(positions.first?.bar, 3)
    }

    func testNonsenseRangesYieldNothingRatherThanGuesses() {
        XCTAssertTrue(MCUController.automationSamplePositions(
            startBar: 8, endBar: 4, beatsPerBar: 4, resolutionBeats: 1, maxPoints: 64
        ).isEmpty)
        XCTAssertTrue(MCUController.automationSamplePositions(
            startBar: 0, endBar: 4, beatsPerBar: 4, resolutionBeats: 1, maxPoints: 64
        ).isEmpty)
        XCTAssertTrue(MCUController.automationSamplePositions(
            startBar: 1, endBar: 4, beatsPerBar: 0, resolutionBeats: 1, maxPoints: 64
        ).isEmpty)
    }
}
