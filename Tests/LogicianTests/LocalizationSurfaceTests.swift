import Foundation
import LogicMCUBridge
import XCTest
@testable import Logician

/// The control-surface plane's English-string surfaces, guarded as TABLES
/// rather than as scattered literals.
///
/// Localization is parked (there is no second-language user to qualify
/// against yet), but the thing that makes it expensive is not the translating
/// — it is FINDING the strings. These tests keep the two tables complete and
/// keep call sites from quietly re-spelling their way back out of them, so the
/// eventual Swedish session starts from a list instead of a grep.
final class LocalizationSurfaceTests: XCTestCase {

    // MARK: - Key command names

    func testEveryStandardCommandNameIsUnique() {
        // Two rows with the same name would make `note(named:)` — a
        // case-insensitive first-match — silently pick one of them, and
        // `takenNotes` would reserve a note nothing can reach.
        let names = KeyCommandRegistry.standardCommands.map { $0.name.lowercased() }
        XCTAssertEqual(Set(names).count, names.count, "two standard commands share a name")
    }

    func testEveryStandardCommandNameIsOneOfTheNameConstants() {
        let known = Set(KeyCommandRegistry.Name.all)
        for command in KeyCommandRegistry.standardCommands {
            XCTAssertTrue(
                known.contains(command.name),
                "'\(command.name)' is spelled in standardCommands but missing from Name.all"
            )
        }
    }

    func testTheTranslationListHasNoDuplicates() {
        let all = KeyCommandRegistry.Name.all
        XCTAssertEqual(Set(all).count, all.count, "Name.all lists the same name twice")
    }

    func testNoCommandNameIsBlankOrPadded() {
        // A name is matched against Logic's Key Commands window verbatim; a
        // stray space is a not_found that looks like a missing command.
        for name in KeyCommandRegistry.Name.all {
            XCTAssertEqual(name, name.trimmingCharacters(in: .whitespaces), "'\(name)' is padded")
            XCTAssertFalse(name.isEmpty)
        }
    }

    /// THE LEAK GUARD. A call site that writes `fireKeyCommand("Rename Track")`
    /// instead of `fireKeyCommand(KeyCommandRegistry.Name.renameTrack)` still
    /// works — and puts a Logic UI string back outside the one table a
    /// translator reads. That is exactly how the surface got to fourteen
    /// scattered literals the first time.
    ///
    /// Scope, deliberately: only names of TWO OR MORE words are guarded.
    /// `Save`, `Cut`, `Copy`, `Paste`, `Delete`, `Undo`, `Redo` are also
    /// legitimate AX button titles and plugin-menu item titles elsewhere in
    /// the tree (`"Don’t Save"`'s sibling, the track-deletion alert's Delete
    /// button, the preset menu's Undo row) — those are a different surface
    /// that a different table owns, and matching on them would fail on
    /// correct code. Prose is not matched either: the guide and the tool
    /// descriptions quote command names for agents to read, in single quotes
    /// and backticks, which is documentation rather than a comparison.
    func testNoSourceFileOutsideTheRegistryReSpellsAMultiWordCommandName() throws {
        let sources = repositoryRoot.appendingPathComponent("Sources")
        let guarded = KeyCommandRegistry.Name.all.filter { $0.split(separator: " ").count >= 2 }
        XCTAssertGreaterThan(guarded.count, 15, "the guard would be vacuous")

        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        )
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let file = url.lastPathComponent
            guard file != "KeyCommandRegistry.swift" else { continue }
            // Whole-line comments are dropped first: the tree quotes command
            // names in doc comments constantly ("the real one is \"Remove
            // Silence from Audio Region…\"") and that is a reader's note, not
            // a comparison Logic's language could break.
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            scanned += 1
            for name in guarded where code.contains("\"\(name)\"") {
                XCTFail(
                    "\(file) spells the key command \"\(name)\" inline; "
                        + "use KeyCommandRegistry.Name instead"
                )
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the source scan found almost nothing — wrong root?")
    }

    // MARK: - MCU LCD strings

    func testTheLocaleRiskLiteralsAreNonEmptyAndUntrimmable() {
        // Every one of these is compared against a 7-character LCD cell that
        // has already been trimmed, so a padded table entry would never match.
        let literals = [
            MCULCDStrings.channelStripVolumeBanner,
            MCULCDStrings.parameterBannerMarker,
            MCULCDStrings.insertListFirstSlotLabel,
            MCULCDStrings.sendFieldLabelPrefix,
            MCULCDStrings.pageIndicatorWord,
            MCULCDStrings.minusInfinity
        ] + MCULCDStrings.instrumentChannelFormats
        for literal in literals {
            XCTAssertFalse(literal.isEmpty)
            XCTAssertEqual(literal, literal.trimmingCharacters(in: .whitespaces), "'\(literal)'")
        }
    }

    func testTheBannerMarkerIsSharedByTheBannerItMustDetect() {
        // `MCUTransportLCD` decides "a mode banner is covering the names row"
        // from the marker alone, and `MCUMixing` proves the volume view from
        // the full banner. If a locale swap moved one and not the other, the
        // pan view would classify a volume banner as settled names.
        XCTAssertTrue(
            MCULCDStrings.channelStripVolumeBanner
                .contains(MCULCDStrings.parameterBannerMarker),
            "the volume banner no longer carries the marker every banner shares"
        )
    }

    func testThePageIndicatorPatternsAllDeriveFromTheSameWord() throws {
        // Three patterns read the same indicator at three strictnesses. They
        // are built from `pageIndicatorWord` so a locale changes one string,
        // not three regexes — this proves the derivation still holds.
        let word = MCULCDStrings.pageIndicatorWord
        for pattern in [
            MCULCDStrings.pageIndicatorPattern,
            MCULCDStrings.pageIndicatorPresentPattern,
            MCULCDStrings.pageIndicatorCellPattern
        ] {
            XCTAssertTrue(pattern.hasPrefix(word), pattern)
            XCTAssertNotNil(try? NSRegularExpression(pattern: pattern), pattern)
        }
        let row = "\(word) 3/12"
        XCTAssertNotNil(row.range(of: MCULCDStrings.pageIndicatorPattern, options: .regularExpression))
        XCTAssertNotNil(
            row.range(of: MCULCDStrings.pageIndicatorPresentPattern, options: .regularExpression)
        )
        XCTAssertNotNil(
            row.range(of: MCULCDStrings.pageIndicatorCellPattern, options: .regularExpression)
        )
    }

    func testTheIndicatorPatternStillReadsBothNumbers() {
        // The captured form is what `pageIndicator()` turns into (current,
        // total); the parse splits on space and slash, so the pattern and the
        // parse have to agree about the shape.
        let row = "Comp    \(MCULCDStrings.pageIndicatorWord) 3/12"
        let range = row.range(
            of: MCULCDStrings.pageIndicatorPattern, options: .regularExpression
        )
        let digits = try? XCTUnwrap(range).map { String(row[$0]) }
        XCTAssertEqual(digits?.split(separator: " ").last.map(String.init), "3/12")
    }

    func testTheProtocolConstantsAreTheTokensTheGrammarUses() {
        // Not a translation check — a "nobody rewrote the display grammar"
        // check. These are matched against trimmed cells and a 7-segment
        // readout, and each one being exactly what Logic paints is what makes
        // the LOCALE-RISK/PROTOCOL-CONSTANT split in the table honest.
        XCTAssertEqual(MCULCDStrings.emptySlot, "--")
        XCTAssertEqual(MCULCDStrings.clearingCell, "-")
        XCTAssertEqual(MCULCDStrings.bypassMarker, "*")
        XCTAssertEqual(MCULCDStrings.modalAlertTimecode, "ALERT")
        XCTAssertEqual(MCULCDStrings.Assignment.pan, "PN")
        XCTAssertEqual(MCULCDStrings.Assignment.instrument, "IN")
        XCTAssertEqual(MCULCDStrings.Assignment.send, "SE")
        XCTAssertEqual(MCULCDStrings.Assignment.insertSlot(3), "P3")
        // The empty sentinel must not collapse into the clearing placeholder:
        // one means "this slot holds nothing", the other "this cell is being
        // repainted", and the plugin browser walks TOWARD the first.
        XCTAssertNotEqual(MCULCDStrings.emptySlot, MCULCDStrings.clearingCell)
    }

    func testMinusInfinityParsesToTheAgreedFloorOnBothSidesOfTheSocket() {
        // The server's `parseDb` and the daemon's in-process converge parser
        // are separate code; they read the same table so a fader pulled to
        // the bottom cannot mean two different numbers.
        XCTAssertEqual(
            MCUController.parseDb(MCULCDStrings.minusInfinity + " dB"),
            MCULCDStrings.minusInfinityDb
        )
        // The decimal comma is normalized before parsing — the one locale
        // hazard that is already handled, kept honest here.
        XCTAssertEqual(MCUController.parseDb("-19,5 dB"), -19.5)
        XCTAssertEqual(MCUController.parseDb("-19.5 dB"), -19.5)
    }

    func testTheInstrumentFormatsAreOrderedLongestSpellingFirst() {
        // `splitInstrumentEntry` takes the first suffix that matches, so
        // "Multi Output" listed after "Output"-like shorter words would cut an
        // entry in the wrong place.
        let formats = MCULCDStrings.instrumentChannelFormats
        for (index, format) in formats.enumerated() {
            for longer in formats[..<index] where longer.hasSuffix(format) {
                XCTFail("'\(format)' is a suffix of '\(longer)' but is listed after it")
            }
        }
        XCTAssertEqual(
            MCUController.splitInstrumentEntry("Drum Kit Designer Multi-Output").format,
            "Multi-Output"
        )
    }

    // MARK: -

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LogicianTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }
}
