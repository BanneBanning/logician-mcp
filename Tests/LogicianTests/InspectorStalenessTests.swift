import XCTest
@testable import Logician

/// Whether the left inspector strip showing a name other than the requested
/// track means "wrong strip" (refuse) or "Logic has not repainted it since the
/// rename" (proceed).
///
/// This is the decision behind the worst defect the 2026-09-02 profile found:
/// a rename left its own track unaddressable by every `selectTrack`-routed
/// tool, and the refusal took 8.9 s to arrive and named the very row it had
/// been asked for. It is a decision about four strings, and a live run cannot
/// easily produce the case that matters — a rename of one of two rows sharing
/// a name — so it is pinned here.
final class InspectorStalenessTests: XCTestCase {

    private func verdict(
        requested: String,
        header: String?,
        inspector: String?,
        rendered: [String],
        renamed: InspectorReadback.RenamedInPlace? = nil
    ) -> InspectorReadback.Verdict {
        InspectorReadback.verdict(
            requested: requested,
            selectedHeaderName: header,
            inspectorName: inspector,
            renderedNames: rendered,
            renamedInPlace: renamed
        )
    }

    // MARK: The pre-existing contract, unchanged

    func testAnAgreeingInspectorMatches() {
        XCTAssertEqual(
            verdict(requested: "Drums", header: "Drums", inspector: "Drums", rendered: ["Drums", "Bas"]),
            .matches
        )
    }

    /// The wrong-strip state the readback exists to catch: the inspector is
    /// showing a real, different track. Nothing about a rename excuses it.
    func testAnInspectorShowingAnotherRealTrackIsRefused() {
        XCTAssertEqual(
            verdict(requested: "Drums", header: "Drums", inspector: "Bas", rendered: ["Drums", "Bas"]),
            .showsAnotherTrack("Bas")
        )
    }

    func testNoStripAtAllVerifiesNothing() {
        XCTAssertEqual(
            verdict(requested: "Drums", header: "Drums", inspector: nil, rendered: ["Drums"]),
            .noStripVisible
        )
        XCTAssertEqual(
            verdict(requested: "Drums", header: "Drums", inspector: "", rendered: ["Drums"]),
            .noStripVisible
        )
    }

    // MARK: The rename staleness

    /// The measured case: `Inst 2` was renamed to `RenamedTrk1`, the header
    /// repainted, the inspector did not, and no track answers to `Inst 2` any
    /// more. That is not another strip; it is unrepainted text.
    func testAnInspectorNameNoRowCarriesIsStale() {
        XCTAssertEqual(
            verdict(
                requested: "RenamedTrk1",
                header: "RenamedTrk1",
                inspector: "Inst 2",
                rendered: ["Lofi Pad", "RenamedTrk1", "Drums"]
            ),
            .staleAfterRename(was: "Inst 2")
        )
    }

    /// The header row's own identity is what replaces the proof the stale
    /// description can no longer give, so a selected row that does NOT carry
    /// the requested name is refused even when the inspector's name is
    /// otherwise unaccounted for.
    func testAHeaderThatDoesNotCarryTheRequestedNameIsRefused() {
        XCTAssertEqual(
            verdict(
                requested: "RenamedTrk1",
                header: "Something Else",
                inspector: "Inst 2",
                rendered: ["Lofi Pad", "Something Else"]
            ),
            .showsAnotherTrack("Inst 2")
        )
        XCTAssertEqual(
            verdict(
                requested: "RenamedTrk1",
                header: nil,
                inspector: "Inst 2",
                rendered: ["Lofi Pad"]
            ),
            .showsAnotherTrack("Inst 2")
        )
    }

    /// An unreadable header column proves nothing, and must not be read as
    /// "no row has that name".
    func testAnUnreadableHeaderColumnIsNotEvidenceOfStaleness() {
        XCTAssertEqual(
            verdict(requested: "Fp1", header: "Fp1", inspector: "Inst 2", rendered: []),
            .showsAnotherTrack("Inst 2")
        )
    }

    /// The one case the generic proof cannot reach, and the reason the record
    /// exists: one of two rows called `Crash` was renamed, so the inspector's
    /// stale `Crash` still matches a real row.
    func testRenamingOneOfTwoSameNamedRowsNeedsTheRecord() {
        XCTAssertEqual(
            verdict(
                requested: "Crash Copy",
                header: "Crash Copy",
                inspector: "Crash",
                rendered: ["Crash", "Crash Copy"]
            ),
            .showsAnotherTrack("Crash")
        )
        XCTAssertEqual(
            verdict(
                requested: "Crash Copy",
                header: "Crash Copy",
                inspector: "Crash",
                rendered: ["Crash", "Crash Copy"],
                renamed: InspectorReadback.RenamedInPlace(was: "Crash", now: "Crash Copy")
            ),
            .staleAfterRename(was: "Crash")
        )
    }

    /// The record widens the readback by ONE exact pair and no further: a
    /// record about some other rename cannot excuse a strip showing a real
    /// track.
    func testTheRecordDoesNotExcuseAnUnrelatedStrip() {
        XCTAssertEqual(
            verdict(
                requested: "Crash Copy",
                header: "Crash Copy",
                inspector: "Bas",
                rendered: ["Bas", "Crash Copy"],
                renamed: InspectorReadback.RenamedInPlace(was: "Crash", now: "Crash Copy")
            ),
            .showsAnotherTrack("Bas")
        )
        XCTAssertEqual(
            verdict(
                requested: "Crash Copy",
                header: "Crash Copy",
                inspector: "Crash",
                rendered: ["Crash", "Crash Copy"],
                renamed: InspectorReadback.RenamedInPlace(was: "Crash", now: "Fp1")
            ),
            .showsAnotherTrack("Crash")
        )
    }

    /// Case-sensitively, like `resolveTrack`: a case-only rename is a real
    /// rename, and `Inst 2` standing where `INST 2` was asked for is exactly
    /// the staleness this handles.
    func testACaseOnlyRenameLeavesAStaleInspector() {
        XCTAssertEqual(
            verdict(
                requested: "INST 2",
                header: "INST 2",
                inspector: "Inst 2",
                rendered: ["Lofi Pad", "INST 2"],
                renamed: InspectorReadback.RenamedInPlace(was: "Inst 2", now: "INST 2")
            ),
            .staleAfterRename(was: "Inst 2")
        )
    }
}
