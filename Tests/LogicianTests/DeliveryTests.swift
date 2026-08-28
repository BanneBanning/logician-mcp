import XCTest
@testable import Logician

/// The pure parts of the delivery slice: the bounce dialog's value vocabulary
/// (G53), the stem contract (G54) and Logic's Remove Silence preview (G30).
/// All three are read off dialogs that were walked live on 2026-08-28; these
/// tests pin the mapping between what a caller writes and what has to be
/// pressed, which is the half that does not need Logic running.
final class DeliveryTests: XCTestCase {

    // MARK: - Bounce format vocabulary

    func testCanonicalAcceptsTheExactMenuTitles() {
        for title in BounceFormat.sampleRates {
            XCTAssertEqual(BounceFormat.canonical(title, in: BounceFormat.sampleRates), title)
        }
        for title in BounceFormat.bitDepths {
            XCTAssertEqual(BounceFormat.canonical(title, in: BounceFormat.bitDepths), title)
        }
    }

    func testCanonicalIgnoresCaseSpacingAndPunctuation() {
        XCTAssertEqual(
            BounceFormat.canonical("32 bit float", in: BounceFormat.bitDepths), "32-bit float"
        )
        XCTAssertEqual(BounceFormat.canonical("aiff", in: BounceFormat.fileTypes), "AIFF")
        XCTAssertEqual(
            BounceFormat.canonical("overload protection only", in: BounceFormat.normalizeModes),
            "Overload Protection Only"
        )
    }

    func testCanonicalTakesAUniquePrefix() {
        XCTAssertEqual(BounceFormat.canonical("48", in: BounceFormat.sampleRates), "48 kHz")
        XCTAssertEqual(BounceFormat.canonical("24", in: BounceFormat.bitDepths), "24-bit")
        XCTAssertEqual(
            BounceFormat.canonical("POW-r #2", in: BounceFormat.ditherings),
            "POW-r #2 (Noise Shaping)"
        )
    }

    func testCanonicalRefusesAnAmbiguousPrefix() {
        // "1" starts 11.025, 12, 176.4 and 192 kHz - four answers is no answer.
        XCTAssertNil(BounceFormat.canonical("1", in: BounceFormat.sampleRates))
    }

    func testCanonicalReadsASampleRateWrittenInHertz() {
        XCTAssertEqual(BounceFormat.canonical("48000", in: BounceFormat.sampleRates), "48 kHz")
        XCTAssertEqual(BounceFormat.canonical("96000 Hz", in: BounceFormat.sampleRates), "96 kHz")
        XCTAssertEqual(BounceFormat.canonical("44100", in: BounceFormat.sampleRates), "44.1 kHz")
    }

    func testCanonicalRefusesWhatIsNotThere() {
        XCTAssertNil(BounceFormat.canonical("FLAC", in: BounceFormat.fileTypes))
        XCTAssertNil(BounceFormat.canonical("", in: BounceFormat.fileTypes))
        XCTAssertNil(BounceFormat.canonical("12-bit", in: BounceFormat.bitDepths))
    }

    func testRejectionNamesEveryRealOption() {
        let text = BounceFormat.rejection("FLAC", label: "File Type", options: BounceFormat.fileTypes)
        XCTAssertTrue(text.contains("FLAC"))
        for option in BounceFormat.fileTypes { XCTAssertTrue(text.contains(option)) }
        XCTAssertTrue(text.contains("Nothing was bounced"))
    }

    // MARK: - Stems

    func testStemsRefuseADuplicateTrackName() {
        XCTAssertThrowsError(try StemExport.normalizedTracks(["Bas", "Drums", "bas"])) { error in
            XCTAssertTrue("\(error)".contains("twice"), "\(error)")
        }
    }

    func testStemsTrimAndDropBlanks() throws {
        XCTAssertEqual(try StemExport.normalizedTracks([" Bas ", "Drums", "  "]), ["Bas", "Drums"])
    }

    func testStemsRefuseAnEmptyOrOversizedList() {
        XCTAssertThrowsError(try StemExport.normalizedTracks([]))
        XCTAssertThrowsError(
            try StemExport.normalizedTracks((0...StemExport.maximumTracks).map { "T\($0)" })
        )
    }

    func testStemAlignmentIsOnlyClaimedWhenEveryFrameCountAgrees() {
        XCTAssertTrue(StemExport.frameAlignment([441_000, 441_000, 441_000]).aligned)
        XCTAssertFalse(StemExport.frameAlignment([441_000, 441_001]).aligned)
        XCTAssertFalse(StemExport.frameAlignment([441_000, nil]).aligned)
        XCTAssertFalse(StemExport.frameAlignment([nil, nil]).aligned)
    }

    func testStemAlignmentNoteQuantifiesTheSpread() {
        let verdict = StemExport.frameAlignment([441_000, 440_100])
        XCTAssertFalse(verdict.aligned)
        XCTAssertTrue(verdict.note.contains("900"), verdict.note)
    }

    func testStemContentsNoteWarnsAboutTheTwoWaysSummingLies() {
        XCTAssertTrue(StemExport.contentsNote.contains("master chain"))
        XCTAssertTrue(StemExport.contentsNote.contains("logic_render_track"))
    }

    // MARK: - Remove Silence preview

    func testPreviewCountReadsLogicsOwnWording() {
        XCTAssertEqual(RemoveSilence.previewCount("9 Regions"), 9)
        XCTAssertEqual(RemoveSilence.previewCount("1 Region"), 1)
        XCTAssertEqual(RemoveSilence.previewCount("  12 Regions  "), 12)
    }

    func testPreviewCountRefusesAnythingElse() {
        // A number that is not a region count must never be reported as one.
        XCTAssertNil(RemoveSilence.previewCount("Threshold:"))
        XCTAssertNil(RemoveSilence.previewCount("-28"))
        XCTAssertNil(RemoveSilence.previewCount(""))
    }

    // MARK: - Split

    func testSplitOffersLogicsThreeAnswersForCrossingNotes() {
        XCTAssertEqual(Set(LogicAccessibility.notesCrossingChoices.keys),
                       ["keep", "shorten", "split"])
    }

    func testEverySelectionModeNamesARealCommandAndSaysWhatItMeans() {
        for (mode, entry) in LogicAccessibility.regionSelectionCommands {
            XCTAssertFalse(entry.command.isEmpty, mode)
            XCTAssertFalse(entry.meaning.isEmpty, mode)
        }
        XCTAssertEqual(
            LogicAccessibility.regionSelectionCommands["following_same_track"]?.command,
            "Select All Following of Same Track/Pitch",
            "Logic 12.3.1's own spelling, read out of the Key Commands window"
        )
    }

    // MARK: - Menu shortcut decoding

    func testModifierMaskTreatsCommandAsTheDefault() {
        // Measured on Logic's own menus: ⌘B = 0, ⌃B = 12, ⌥K = 10.
        XCTAssertEqual(MenuShortcut.flags(fromModifiers: 0), .maskCommand)
        XCTAssertEqual(MenuShortcut.flags(fromModifiers: 12), .maskControl)
        XCTAssertEqual(MenuShortcut.flags(fromModifiers: 10), .maskAlternate)
        XCTAssertEqual(MenuShortcut.flags(fromModifiers: 8), [])
        XCTAssertEqual(
            MenuShortcut.flags(fromModifiers: 1), [.maskShift, .maskCommand]
        )
    }

    func testShortcutDescriptionMatchesWhatTheMenuPrints() {
        XCTAssertEqual(MenuShortcut.describe(character: "K", modifiers: 10), "⌥K")
        XCTAssertEqual(MenuShortcut.describe(character: "B", modifiers: 12), "⌃B")
        XCTAssertEqual(MenuShortcut.describe(character: "B", modifiers: 0), "⌘B")
    }

    func testShortcutDecodeMapsLettersAndRefusesTheRest() {
        XCTAssertEqual(MenuShortcut.decode(character: "K", modifiers: 10)?.key, 40)
        XCTAssertEqual(MenuShortcut.decode(character: "b", modifiers: 0)?.key, 11)
        XCTAssertNil(MenuShortcut.decode(character: "⌫", modifiers: 0))
        XCTAssertNil(MenuShortcut.decode(character: "", modifiers: 0))
    }
}
