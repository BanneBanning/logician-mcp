import XCTest
@testable import Logician

/// The pure half of G00 — `logic_learn_key_command`'s note choice and its
/// search-term derivation. Both are cheap to get wrong in a way that is
/// invisible until it matters: a note collision silently rebinds a command the
/// product's own tools fire, and a bad search term is a silent `not_found`
/// against Logic's ~1400-row Key Commands window.
final class KeyCommandTests: XCTestCase {

    // MARK: - Free note selection

    func testFreeNoteStartsAtTheBottomOfTheLearnableRange() {
        XCTAssertEqual(KeyCommandRegistry.freeNote(taken: []), 60)
    }

    func testFreeNoteSkipsWhatIsAlreadyTaken() {
        XCTAssertEqual(KeyCommandRegistry.freeNote(taken: [60, 61, 62]), 63)
    }

    func testFreeNoteNeverHandsOutANoteTheStandardSetPrefers() {
        // The standard commands live at 100-121 and are reserved whether or
        // not they have been learned yet: an arbitrary command taking one
        // would push the product's own onboarding onto an alternate note.
        let reserved = Set(KeyCommandRegistry.standardCommands.map(\.preferredNote))
        var taken = Set(KeyCommandRegistry.learnableNoteRange)
        for _ in 0..<6 {
            let note = try? XCTUnwrap(KeyCommandRegistry.freeNote(taken: taken))
            guard let note else { return XCTFail("ran out of notes too early") }
            XCTAssertFalse(reserved.contains(note), "note \(note) is a standard command's")
            taken.insert(note)
        }
    }

    func testFreeNoteFallsToTheUpperRangeWhenTheLearnableRangeIsFull() {
        XCTAssertEqual(
            KeyCommandRegistry.freeNote(taken: Set(KeyCommandRegistry.learnableNoteRange)),
            122
        )
    }

    func testFreeNoteFallsToTheLowRangeLast() {
        var taken = Set(KeyCommandRegistry.learnableNoteRange)
        taken.formUnion(122...127)
        XCTAssertEqual(KeyCommandRegistry.freeNote(taken: taken), 21)
    }

    func testFreeNoteRefusesRatherThanWrappingWhenEverythingIsSpokenFor() {
        // Wrapping would rebind something. 112 learned commands is far past
        // anything real, so refusing is the honest answer.
        XCTAssertNil(KeyCommandRegistry.freeNote(taken: Set(0...127)))
    }

    func testTakenNotesReservesEveryStandardPreferredNote() {
        let taken = KeyCommandRegistry.takenNotes()
        for command in KeyCommandRegistry.standardCommands {
            XCTAssertTrue(taken.contains(command.preferredNote), command.name)
        }
    }

    // MARK: - Search-term derivation

    func testDefaultSearchTermTakesTheFirstTwoWordsLowercased() {
        XCTAssertEqual(KeyCommandRegistry.defaultSearchTerm(for: "Strip Silence"), "strip silence")
        XCTAssertEqual(
            KeyCommandRegistry.defaultSearchTerm(for: "Bounce Regions in Place"),
            "bounce regions"
        )
    }

    func testDefaultSearchTermTakesAThirdWordWhenTheFirstTwoAreTiny() {
        // "Cut at ..." would otherwise search for "cut at", which matches
        // half the Edit menu.
        XCTAssertEqual(
            KeyCommandRegistry.defaultSearchTerm(for: "Cut at Playhead Position"),
            "cut at playhead"
        )
    }

    func testDefaultSearchTermHandlesASingleWordName() {
        XCTAssertEqual(KeyCommandRegistry.defaultSearchTerm(for: "Undo"), "undo")
    }

    /// The property the whole design rests on: a term derived from the name is
    /// a SUBSTRING of that name, so it can only fail to find the row when the
    /// name itself is wrong — which is exactly the case the `candidates` list
    /// in the not_found answer exists for.
    func testDerivedSearchTermIsAlwaysASubstringOfTheName() {
        let names = KeyCommandRegistry.standardCommands.map(\.name) + [
            "Select All Following of Same Track",
            "Bounce Regions in Place",
            "Strip Silence…",
            "Split Regions/Events at Playhead Position"
        ]
        for name in names {
            let term = KeyCommandRegistry.defaultSearchTerm(for: name)
            XCTAssertTrue(
                name.lowercased().contains(term),
                "'\(term)' is not a substring of '\(name)'"
            )
        }
    }

    /// The same property for the terms that are hand-written in the shipped
    /// table: one of them drifting away from its name would be a silent
    /// not_found during onboarding.
    func testEveryStandardCommandsOwnSearchTermMatchesItsName() {
        for command in KeyCommandRegistry.standardCommands {
            XCTAssertTrue(
                command.name.lowercased().contains(command.search.lowercased()),
                "'\(command.search)' does not occur in '\(command.name)'"
            )
        }
    }

    func testStandardPreferredNotesAreUniqueAndOutsideTheLearnableRange() {
        let notes = KeyCommandRegistry.standardCommands.map(\.preferredNote)
        XCTAssertEqual(Set(notes).count, notes.count, "two standard commands prefer the same note")
        for note in notes {
            XCTAssertFalse(
                KeyCommandRegistry.learnableNoteRange.contains(note),
                "standard note \(note) sits inside the range learned commands draw from"
            )
        }
    }
}
