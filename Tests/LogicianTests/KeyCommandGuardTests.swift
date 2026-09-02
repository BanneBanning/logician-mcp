import XCTest
@testable import Logician

/// The guards around key-command learning — the one flow in this server whose
/// writes land OUTSIDE every project, in the user's persisted Logic key command
/// set, where no Undo and no sandbox copy reaches them. Each test below pins a
/// decision that was previously taken on trust: which notes a collision may
/// retry on, whether a table found in the Key Commands window is the
/// assignments table or the command list, whether a row already carries an
/// assignment, whether a note is free to record, and whether the MIDI port the
/// binding will be scoped to is the one Logic sees.
///
/// All of it is pure: nothing here opens a window, sends a note, or reads or
/// writes the registry file.
final class KeyCommandGuardTests: XCTestCase {

    // MARK: - The collision-retry ladder (was `[n, (n+20)%128, (n+40)%128]`)

    /// The reservation `takenNotes()` computes, without reading the machine's
    /// registry file — these tests must decide the same way on any machine.
    private var reservedNotes: Set<Int> {
        Set(KeyCommandRegistry.standardCommands.map(\.preferredNote))
    }

    func testFallbackNotesComeFromTheFreeAllocatorNotArithmetic() {
        // 60 + 40 = 100, the first note of the standard block. The old ladder
        // handed that out; the picker never does.
        let candidates = KeyCommandRegistry.candidateNotes(preferred: 60, taken: reservedNotes)
        XCTAssertEqual(candidates.first, 60)
        XCTAssertEqual(candidates.count, 3)
        for note in candidates.dropFirst() {
            XCTAssertFalse(
                (100...121).contains(note),
                "fallback \(note) sits in the block reserved for standard commands"
            )
        }
    }

    func testNoFirstChoiceInTheLearnableRangeCanFallIntoTheReservedBlock() {
        // The arithmetic ladder's defect was universal, not incidental: with
        // `learnableNoteRange` 40 wide from 60, n+40 (n ≤ 79) and n+20
        // (n ≥ 80) both landed in 100-119. Every first choice, checked.
        for preferred in KeyCommandRegistry.learnableNoteRange {
            let candidates = KeyCommandRegistry.candidateNotes(
                preferred: preferred, taken: reservedNotes
            )
            for note in candidates.dropFirst() {
                XCTAssertFalse(reservedNotes.contains(note), "\(preferred) fell back onto \(note)")
            }
        }
    }

    func testFallbackNotesSkipEverythingAlreadyTakenAndEachOther() {
        let taken = reservedNotes.union([61, 62])
        let candidates = KeyCommandRegistry.candidateNotes(preferred: 74, taken: taken)
        XCTAssertEqual(candidates, [74, 60, 63])
        XCTAssertEqual(Set(candidates).count, candidates.count, "a note was offered twice")
    }

    func testCandidateLadderStopsRatherThanWrappingWhenNothingIsFree() {
        // Wrapping is what rebinds something. Short is the honest answer.
        XCTAssertEqual(
            KeyCommandRegistry.candidateNotes(preferred: 74, taken: Set(0...127)), [74]
        )
    }

    // MARK: - The registry refuses a note another command holds

    private let registryRows: [[String: Any]] = [
        ["name": "Bar", "note": 82, "channel": 16],
        ["name": "Baz", "note": 83, "channel": 16]
    ]

    func testRegisteringANoteHeldByAnotherCommandIsRefused() {
        let refusal = KeyCommandRegistry.registrationRefusal(
            note: 82, channel: 16, name: "Foo", in: registryRows
        )
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("'Bar'") == true, refusal ?? "no refusal")
        XCTAssertTrue(refusal?.contains("NOT recorded") == true, refusal ?? "no refusal")
    }

    func testRegisteringACommandsOwnNoteAgainIsAllowed() {
        // Re-learning is the repair path; it must not be refused by its own
        // entry. Case-insensitively, because the registry holds Logic's
        // spelling and callers type their own.
        XCTAssertNil(KeyCommandRegistry.registrationRefusal(
            note: 82, channel: 16, name: "Bar", in: registryRows
        ))
        XCTAssertNil(KeyCommandRegistry.registrationRefusal(
            note: 82, channel: 16, name: "bar", in: registryRows
        ))
    }

    func testAFreeNoteRegistersWithoutComplaint() {
        XCTAssertNil(KeyCommandRegistry.registrationRefusal(
            note: 84, channel: 16, name: "Foo", in: registryRows
        ))
    }

    func testADifferentChannelIsADifferentSlot() {
        XCTAssertNil(KeyCommandRegistry.registrationRefusal(
            note: 82, channel: 1, name: "Foo", in: registryRows
        ))
    }

    // MARK: - The explicit `note:` guard applies on the relearn path too

    func testExplicitNoteHeldByAnotherCommandIsRefusedEvenWithRelearn() {
        // The guard used to be prefixed `!relearn,`, so
        // {name: "Foo", note: 82, relearn: true} was accepted while note 82
        // belonged to "Bar". The function takes no relearn flag at all now —
        // the exemption relearn needs is the same-name one below.
        let refusal = KeyCommandRegistry.explicitNoteRefusal(
            note: 82, name: "Foo", in: registryRows
        )
        XCTAssertEqual(
            refusal,
            "note 82 is already registered to 'Bar'. Nothing was bound. "
                + "Omit 'note' to let the free range pick one."
        )
    }

    func testRebindingACommandToItsOwnExplicitNoteIsStillAllowed() {
        XCTAssertNil(KeyCommandRegistry.explicitNoteRefusal(
            note: 82, name: "Bar", in: registryRows
        ))
    }

    // MARK: - What a command row already carries

    func testARowShowingThePreferredNoteIsAVerifiedNoOp() {
        XCTAssertEqual(
            KeyCommandRegistry.rowAssignment("⌘S Note 74", preferredNote: 74),
            .preferred(74)
        )
    }

    func testARowShowingAnotherNoteIsRefusedRatherThanStacked() {
        // The old check only recognised the note this call had just picked, so
        // a command already bound on a different note silently gained a
        // SECOND controller assignment.
        XCTAssertEqual(
            KeyCommandRegistry.rowAssignment("Note 91", preferredNote: 74),
            .other([91])
        )
    }

    func testAKeyboardShortcutAloneIsNotAnAssignment() {
        // Learning is additive to the keyboard shortcut and must not refuse
        // over one.
        XCTAssertEqual(KeyCommandRegistry.rowAssignment("⌥⌘F", preferredNote: 74), .none)
        XCTAssertEqual(KeyCommandRegistry.rowAssignment("", preferredNote: 74), .none)
    }

    func testEveryNoteInTheRowIsRead() {
        XCTAssertEqual(
            KeyCommandRegistry.assignedNotes(in: "Note 91 Note 105"), [91, 105]
        )
    }

    func testANoteNumberWithoutTheNotePrefixIsNotClaimed() {
        XCTAssertEqual(KeyCommandRegistry.assignedNotes(in: "F2 (Modifiers ...)"), [])
        XCTAssertEqual(KeyCommandRegistry.assignedNotes(in: "Notes 91"), [])
    }

    // MARK: - relearn refuses to delete rows it cannot prove are assignments

    func testRelearnIsRefusedWhenTheOnlyTableIsTheCommandList() {
        let refusal = KeyCommandRelearnGuard.refusal(
            commandListRole: "AXTable", assignmentTableIsCommandList: true
        )
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("NOTHING WAS DELETED") == true, refusal ?? "no refusal")
        // A refusal that does not name the alternative is a dead end.
        XCTAssertTrue(refusal?.contains("without relearn") == true, refusal ?? "no refusal")
    }

    func testRelearnRunsWhenTheAssignmentsTableIsADifferentElement() {
        XCTAssertNil(KeyCommandRelearnGuard.refusal(
            commandListRole: "AXOutline", assignmentTableIsCommandList: false
        ))
        // Even a command list published as a table is fine as long as the
        // assignments table is provably not it.
        XCTAssertNil(KeyCommandRelearnGuard.refusal(
            commandListRole: "AXTable", assignmentTableIsCommandList: false
        ))
    }

    func testRelearnIsRefusedWhenTheCommandListCannotBeIdentified() {
        // Not knowing which element the command list is means not being able
        // to prove the delete loop is aimed anywhere else.
        XCTAssertNotNil(KeyCommandRelearnGuard.refusal(
            commandListRole: nil, assignmentTableIsCommandList: false
        ))
    }

    // MARK: - Orphaned twin ports

    func testACleanPortListRefusesNothing() {
        XCTAssertNil(KeyCommandRegistry.orphanRefusal(orphans: [], action: "learning 'Foo'"))
    }

    func testAnOrphanedTwinPortRefusesTheLearnAndNamesTheRepair() {
        let refusal = KeyCommandRegistry.orphanRefusal(
            orphans: ["Logic MCP Commands (input)"], action: "learning 'Foo'"
        )
        XCTAssertNotNil(refusal)
        XCTAssertTrue(
            refusal?.contains("Logic MCP Commands (input)") == true, refusal ?? "no refusal"
        )
        XCTAssertTrue(refusal?.contains("NOTHING WAS BOUND") == true, refusal ?? "no refusal")
        XCTAssertTrue(refusal?.contains("killall MIDIServer") == true, refusal ?? "no refusal")
    }

    // MARK: - The port identity recorded at learn time

    func testAnEntryLearnedAgainstAnotherPortIdentityIsReported() {
        let rows: [[String: Any]] = [
            ["name": "Old", "note": 74, "port_unique_id": 12345],
            ["name": "New", "note": 75, "port_unique_id": 0x4C4D_4332]
        ]
        XCTAssertEqual(
            KeyCommandRegistry.staleIdentityNames(in: rows, currentPortUniqueID: 0x4C4D_4332),
            ["Old"]
        )
    }

    func testEntriesWithNoRecordedIdentityAreNotAccused() {
        // Absence of a witness is not evidence: everything bound before the
        // identity was written down has none.
        let rows: [[String: Any]] = [["name": "Ancient", "note": 74]]
        XCTAssertEqual(
            KeyCommandRegistry.staleIdentityNames(in: rows, currentPortUniqueID: 0x4C4D_4332), []
        )
    }

    func testNothingIsClaimedWhenTheLivePortCannotBeRead() {
        let rows: [[String: Any]] = [["name": "Old", "note": 74, "port_unique_id": 12345]]
        XCTAssertEqual(
            KeyCommandRegistry.staleIdentityNames(in: rows, currentPortUniqueID: nil), []
        )
    }
}
