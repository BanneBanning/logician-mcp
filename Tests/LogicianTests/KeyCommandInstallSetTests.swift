import XCTest
@testable import Logician

/// What the one-time install round writes into the user's own Logic.
///
/// This is the only set in the server whose membership is IRREVERSIBLE from
/// inside the server: a learned key command lives in the user's persisted key
/// command set, outside the project file, outside Undo and outside the sandbox
/// protocol, and the only way back is the user's own Key Commands window. It
/// was also measured expensive — 223 s for 22 commands, live, 2026-09-02 — so
/// three commands nothing fires cost every user ~30 s of a write they cannot
/// take back. The audit that removed them (`Logician-archive
/// /KEY-COMMANDS-REVIEW.md` §1.2) is the kind of thing that quietly regresses
/// when someone adds a name, so the rules are pinned here.
final class KeyCommandInstallSetTests: XCTestCase {

    private var installed: Set<String> {
        Set(KeyCommandRegistry.standardCommands.map(\.name))
    }

    // MARK: - The trim

    func testTheInstallRoundDoesNotBindCommandsNothingFires() {
        for name in [KeyCommandRegistry.Name.undo, KeyCommandRegistry.Name.redo,
                     KeyCommandRegistry.Name.flashbackCaptureAsRecording] {
            XCTAssertFalse(
                installed.contains(name),
                "'\(name)' is in the install round but no handler fires it - every installed row "
                    + "is an irreversible write into the user's own key command set"
            )
        }
    }

    func testTheTrimmedCommandsAreStillSpelledAndStillLearnable() {
        let onDemand = KeyCommandRegistry.onDemandCommands.map(\.name)
        XCTAssertEqual(
            Set(onDemand),
            [KeyCommandRegistry.Name.undo, KeyCommandRegistry.Name.redo,
             KeyCommandRegistry.Name.flashbackCaptureAsRecording]
        )
        // `resolveKeyCommand` looks a name up in `allNamedCommands`, so being
        // here is exactly what keeps `{name: "Undo"}` working on first use.
        for name in onDemand {
            XCTAssertTrue(KeyCommandRegistry.allNamedCommands.contains { $0.name == name })
        }
    }

    func testEveryNamedCommandIsInTheTranslationList() {
        let known = Set(KeyCommandRegistry.Name.all)
        for command in KeyCommandRegistry.allNamedCommands {
            XCTAssertTrue(
                known.contains(command.name),
                "'\(command.name)' is spelled in a command list but missing from Name.all"
            )
        }
    }

    func testTheTrimmedCommandsKeepTheirReservedNotes() {
        // Not installed is not un-reserved: handing 100-102 to an arbitrary
        // command today would collide the day something asks for Undo.
        let taken = KeyCommandRegistry.takenNotes()
        for command in KeyCommandRegistry.onDemandCommands {
            XCTAssertTrue(
                taken.contains(command.preferredNote),
                "note \(command.preferredNote) (\(command.name)) is no longer reserved"
            )
        }
    }

    func testNoTwoNamedCommandsWantTheSameNote() {
        let notes = KeyCommandRegistry.allNamedCommands.map(\.preferredNote)
        XCTAssertEqual(Set(notes).count, notes.count)
    }

    func testTheInstallRoundIsNineteenCommands() {
        // The number is quoted in the tool description and in the round's own
        // arithmetic, so it is worth failing on rather than drifting.
        XCTAssertEqual(KeyCommandRegistry.standardCommands.count, 19)
        XCTAssertEqual(KeyCommandRegistry.allNamedCommands.count, 22)
    }

    // MARK: - Create Marker stays

    func testCreateMarkerStaysInTheInstallRoundEvenThoughMarkersUsesTheButton() {
        // `logic_markers {action:"create"}` presses the Marker tab's own
        // button (measured 3/3). The binding stays anyway: it is that button's
        // fallback, and it is the probe for "are key commands firing at all"
        // (global command, cheap count readback) — Deselect All is not, it is
        // Tracks-area-scoped and reads `unchanged` when focus is elsewhere.
        XCTAssertTrue(installed.contains(KeyCommandRegistry.Name.createMarker))
    }

    // MARK: - What the health census counts

    func testTheHealthCensusNeverNagsAboutACommandNothingInstalls() {
        // Nothing learned at all: the missing list is the INSTALL set, and the
        // three on-demand commands are not in it.
        let missing = KeyCommandRegistry.standardNotLearned(registryNames: [])
        XCTAssertEqual(missing.count, 19)
        for command in KeyCommandRegistry.onDemandCommands {
            XCTAssertFalse(missing.contains(command.name), command.name)
        }
    }

    func testAFreeNoteNeverLandsOnATrimmedCommandsReservedNote() {
        var taken = KeyCommandRegistry.takenNotes()
        let reserved = Set(KeyCommandRegistry.onDemandCommands.map(\.preferredNote))
        for _ in 0..<8 {
            guard let note = KeyCommandRegistry.freeNote(taken: taken) else { break }
            XCTAssertFalse(reserved.contains(note), "note \(note) is reserved for a trimmed command")
            taken.insert(note)
        }
    }
}
