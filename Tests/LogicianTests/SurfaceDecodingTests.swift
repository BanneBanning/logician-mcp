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

    /// The banner sits on the very cell about to be written: the live display
    /// cannot confirm the target strip, so this falls through to the walk.
    func testABannerOnTheTargetCellIsNotAccepted() {
        XCTAssertFalse(MCUController.bankedAtMatch(live: bannerBank, cached: mappedBank, channel: 1))
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
