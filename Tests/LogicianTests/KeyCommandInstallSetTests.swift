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

    func testTheInstallRoundIsTwentyCommands() {
        // The number is quoted in the tool description and in the round's own
        // arithmetic, so it is worth failing on rather than drifting.
        // 19 until 2026-09-03, when `logic_set_mixer` stopped walking the
        // menu bar (see below).
        XCTAssertEqual(KeyCommandRegistry.standardCommands.count, 20)
        XCTAssertEqual(KeyCommandRegistry.allNamedCommands.count, 23)
    }

    // MARK: - The command the 2026-09-03 conversion added

    /// `Open Mixer…` replaced a menu walk through two English literals in a
    /// `.core` tool, and it is paid for by exactly one row in the user's own
    /// key command set. That trade is the argument for its membership, so it
    /// is written down where a future trim will read it.
    func testTheConvertedRouteIsInTheInstallRound() {
        XCTAssertTrue(
            installed.contains(KeyCommandRegistry.Name.openMixer),
            "logic_set_mixer fires this on every open; without it the tool learns it on first"
                + " use and the user pays the Key Commands window mid-session"
        )
    }

    /// The companion that did NOT make it, pinned so nobody re-adds it from
    /// the review without re-running the experiment.
    ///
    /// TWO reasons now, and the second one is the durable one. Logic would
    /// not learn `Open/Close Track Stack` — four rounds on 2026-09-03, three
    /// candidate notes each, through both `logic_setup_key_commands` and
    /// `logic_learn_key_command`, the row's assignment column never changing
    /// and no neighbouring row picking anything up either. And the fold does
    /// not need a key command at all: `logic_set_track_stack` folds the stack
    /// with an `AXPress` on its disclosure triangle (22-40 ms, 4/4, measured
    /// the same day), which addresses the element instead of acting on the
    /// SELECTED track the way a Tracks-scoped key command would. Logic ships
    /// the directional `Open Track Stack` and `Close Track Stack` rows
    /// (unassigned, read off the window that day); `Open Track Stack` was
    /// attempted once with the user's explicit permission and answered exactly
    /// as the toggle did (10.98 s, three candidate notes, nothing bound,
    /// registry unchanged at 20) — under an inert Accessibility ACTION plane
    /// that also disarms Logic's own Learn checkbox, so the row is recorded as
    /// UNPROVEN rather than unbindable, and `Close Track Stack` was not spent
    /// on a confounded experiment. Either way a row here is an irreversible
    /// write into the user's own Logic, and nothing in this server fires one.
    func testTheStackFoldIsNotInTheInstallRoundAndIsNotSpelledAtAll() {
        for name in ["Open/Close Track Stack", "Open Track Stack", "Close Track Stack",
                     "Open/Close All Track Stacks"] {
            XCTAssertFalse(installed.contains(name), name)
            XCTAssertFalse(KeyCommandRegistry.Name.all.contains(name), name)
        }
    }

    func testTheConvertedCommandSitsOutsideTheArbitraryLearnRange() {
        // An arbitrary `logic_learn_key_command` picks from 60-99. A product
        // command that lived in there would be indistinguishable from an
        // agent's own binding in the user's window later.
        let note = KeyCommandRegistry.allNamedCommands
            .first { $0.name == KeyCommandRegistry.Name.openMixer }?.preferredNote
        XCTAssertEqual(note, 123)
        if let note {
            XCTAssertFalse(KeyCommandRegistry.learnableNoteRange.contains(note))
            XCTAssertTrue(
                KeyCommandRegistry.takenNotes().contains(note),
                "note \(note) is not reserved, so an arbitrary learn could take it"
            )
        }
    }

    func testAFreeNoteNeverLandsOnTheConvertedCommandsReservedNote() {
        var taken = KeyCommandRegistry.takenNotes()
        for _ in 0..<8 {
            guard let note = KeyCommandRegistry.freeNote(taken: taken) else { break }
            XCTAssertNotEqual(note, 123, "note 123 is reserved for the Mixer command")
            taken.insert(note)
        }
    }

    func testTheMixerCommandKeepsLogicsOwnEllipsis() {
        // Logic's row is `Open Mixer…` with U+2026, not three periods. The
        // search term is what finds the row and the NAME is what matches it,
        // so a helpfully "normalised" ellipsis here is a silent not_found
        // several seconds into a live learn — and the live dry run confirmed
        // the row spells it this way (`exact_match: true`, 2026-09-03).
        XCTAssertTrue(KeyCommandRegistry.Name.openMixer.hasSuffix("\u{2026}"))
        XCTAssertFalse(KeyCommandRegistry.Name.openMixer.contains("..."))
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
        XCTAssertEqual(missing.count, 20)
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
