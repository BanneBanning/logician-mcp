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

    func testFreeNoteStepsOverAProductCommandSittingInTheUpperRange() {
        // `Open Mixer…` reserves 123 as of 2026-09-03, and 123 is INSIDE the
        // 122-127 fallback range — so the ranges no longer avoid the named
        // set by construction the way they did while it was all 100-121.
        // `freeNote` skips its own reservations; a caller that reserves
        // nothing still gets the ranges verbatim.
        var taken = Set(KeyCommandRegistry.learnableNoteRange)
        taken.insert(122)
        XCTAssertEqual(KeyCommandRegistry.freeNote(taken: taken), 124)
        XCTAssertEqual(KeyCommandRegistry.freeNote(taken: taken, reserved: []), 123)
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

    /// The notes have been guarded since they were written; the NAMES never
    /// were, and they are the riskier column. `Name` is a localization surface
    /// and four of these entries are `Nudge Region/Event Position …` variants
    /// one word apart — a translation that flattened two of them would have
    /// been caught by nothing until `logic_list_key_commands` was called.
    func testStandardCommandNamesAreUnique() {
        let names = KeyCommandRegistry.standardCommands.map { $0.name.lowercased() }
        XCTAssertEqual(
            Set(names).count, names.count,
            "two standard commands carry the same name: "
                + Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }
                    .keys.sorted().joined(separator: ", ")
        )
    }

    /// And if one day they are NOT unique, the answer is still an answer.
    /// This was `Dictionary(uniqueKeysWithValues:)` in the listing handler,
    /// which traps rather than throws: a duplicated name killed the whole MCP
    /// server process on a read-only call.
    func testCollidingStandardNamesAnswerNormallyInsteadOfTrapping() {
        let colliding: [(search: String, name: String, preferredNote: Int)] = [
            ("nudge", "Nudge Region/Event Position Right by Bar", 112),
            ("nudge", "Nudge Region/Event Position Right by Bar", 113),
            ("save", "Save", 105)
        ]
        let missing = KeyCommandRegistry.standardNotLearned(in: colliding, registryNames: [])
        XCTAssertEqual(missing, ["Nudge Region/Event Position Right by Bar", "Save"])

        // And the collision does not survive into the answer twice when the
        // registry does hold it either.
        XCTAssertEqual(
            KeyCommandRegistry.standardNotLearned(in: colliding, registryNames: ["save"]),
            ["Nudge Region/Event Position Right by Bar"]
        )
    }

    func testStandardNotLearnedMatchesCaseInsensitivelyAndKeepsDeclarationOrder() {
        let registry: Set<String> = Set(
            KeyCommandRegistry.standardCommands.dropFirst().map { $0.name.lowercased() }
        )
        XCTAssertEqual(
            KeyCommandRegistry.standardNotLearned(registryNames: registry),
            [KeyCommandRegistry.standardCommands[0].name]
        )
        XCTAssertTrue(
            KeyCommandRegistry.standardNotLearned(
                registryNames: Set(KeyCommandRegistry.standardCommands.map { $0.name.uppercased() })
            ).count == KeyCommandRegistry.standardCommands.count,
            "registryNames is documented as lowercased; an uppercase set must not match"
        )
    }

    // MARK: - The listing payload's shape
    //
    // Pinned because there was no test at all when 55% of this payload was
    // found to be the same sentence 22-27 times (profiled 2026-09-02, 7 026 B).
    // Each assertion below is a fact the answer must keep saying, or a repeat
    // it must not start saying again.

    private var sampleRegistry: [[String: Any]] {
        [
            [
                "name": "Save", "note": 105, "channel": 16,
                "learned": "2026-08-25", "learned_at": "2026-08-25T10:00:00Z",
                "notes": "learned automatically by logic_setup_key_commands"
            ],
            [
                "name": "Bounce Regions in Place", "note": 60, "channel": 15,
                "source": "logic_learn_key_command", "search": "bounce",
                "learned_at": "2026-08-30T09:00:00Z", "port_unique_id": 4711
            ],
            ["name": "Delete", "note": 111, "channel": 16, "port_unique_id": 99]
        ]
    }

    func testListingRowsKeepEveryFactACallerCanActOn() {
        let rows = KeyCommandRegistry.listingRows(from: sampleRegistry, currentPortUniqueID: 4711)
        XCTAssertEqual(rows.map { $0["name"] as? String }, ["Bounce Regions in Place", "Delete", "Save"])
        XCTAssertEqual(rows.map { $0["note"] as? Int }, [60, 111, 105])

        let bounce = rows[0]
        XCTAssertEqual(bounce["channel"] as? Int, 15, "a non-default channel must survive")
        XCTAssertEqual(bounce["source"] as? String, "logic_learn_key_command")
        XCTAssertEqual(bounce["port_identity"] as? String, "current")
        XCTAssertNil(bounce["port_unique_id"], "the live identity is already named at top level")

        let delete = rows[1]
        XCTAssertEqual(delete["port_identity"] as? String, "changed")
        XCTAssertEqual(delete["port_unique_id"] as? Int, 99, "a foreign identity is worth naming")
    }

    func testListingRowsSayTheConstantsNoTimes() {
        let rows = KeyCommandRegistry.listingRows(from: sampleRegistry, currentPortUniqueID: 4711)
        for row in rows {
            XCTAssertNil(row["notes"], "notes restated source")
            XCTAssertNil(row["standard"], "derivable, and 27 booleans of it")
            XCTAssertNil(row["learned"], "in the file at registry_path")
            XCTAssertNil(row["learned_at"], "in the file at registry_path")
            XCTAssertNil(row["search"], "in the file at registry_path")
        }
        XCTAssertNil(rows[2]["channel"], "channel 16 is the default and is said once")
        XCTAssertNil(
            rows[2]["source"],
            "an entry with no recorded source costs no 55-char apology per row"
        )
        XCTAssertEqual(KeyCommandRegistry.unrecordedSourceCount(in: sampleRegistry), 2)
    }

    /// A row that records an identity while the live port cannot be read at
    /// all: nothing may be claimed, but the recorded number is the only
    /// witness there is, so it stays.
    func testListingRowsClaimNoIdentityWhenTheLivePortIsUnreadable() {
        let rows = KeyCommandRegistry.listingRows(from: sampleRegistry, currentPortUniqueID: nil)
        for row in rows { XCTAssertNil(row["port_identity"]) }
        XCTAssertEqual(rows[0]["port_unique_id"] as? Int, 4711)
    }

    /// A corrupt channel is a fact. Dropping it would let the caller read the
    /// absence as "16".
    func testListingRowsKeepAChannelThatIsNotAnInt() {
        let rows = KeyCommandRegistry.listingRows(
            from: [["name": "Save", "note": 105, "channel": "sixteen"]], currentPortUniqueID: nil
        )
        XCTAssertEqual(rows[0]["channel"] as? String, "sixteen")
    }

    func testListingRowsSurviveARegistryRowWithNothingInIt() {
        let rows = KeyCommandRegistry.listingRows(from: [[:]], currentPortUniqueID: 1)
        XCTAssertEqual(rows[0]["name"] as? String, "?")
        XCTAssertTrue(rows[0]["note"] is NSNull)
    }
}
