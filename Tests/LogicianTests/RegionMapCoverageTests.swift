import XCTest
@testable import Logician

/// `logic_list_regions` used to hide its partiality in a 165-byte static note
/// while `logic_list_tracks`, called on the same 19 rendered rows seconds
/// later, reported `partial: true` and `missing_track_numbers: [10…19]`. These
/// pin the verdict the arrangement map now computes for itself — and pin it
/// AGAINST the track listing's, because two tools disagreeing about the same
/// project is the failure that was actually shipped.
final class RegionMapCoverageTests: XCTestCase {

    /// The reference project: rows 1–9 and 20–29 are rendered, 10–19 sit behind
    /// a collapsed `Drum Synth Kit` stack. The gap in the numbering is the whole
    /// proof, and it costs no AX read at all — `regionRows()` already has it.
    private let referenceRows = Array(1...9) + Array(20...29)

    // MARK: The free signal

    func testNumberingGapNamesTheMissingRows() {
        let verdict = TrackListCompleteness.numbering(
            rowNumbers: referenceRows, rowNoun: "region row"
        )
        XCTAssertTrue(verdict.partial)
        XCTAssertEqual(verdict.completeness, "partial")
        XCTAssertEqual(verdict.missingTrackNumbers, Array(10...19))
        XCTAssertEqual(verdict.evidence.count, 1)
    }

    /// Rows that start above 1 prove the rows above them exist, and the sentence
    /// names what is missing in the caller's own noun.
    func testRowsStartingAboveOneNameTheRowNoun() {
        let verdict = TrackListCompleteness.numbering(
            rowNumbers: [4, 5, 6], rowNoun: "region row"
        )
        XCTAssertEqual(verdict.missingTrackNumbers, [1, 2, 3])
        XCTAssertTrue(verdict.evidence.contains { $0.contains("region row(s)") })
        XCTAssertFalse(verdict.evidence.contains { $0.contains("track header(s)") })
    }

    /// Contiguous rows from 1 prove NOTHING missing — and "nothing proved
    /// missing" is `unknown`, never `complete`. This is the assertion the whole
    /// completeness contract exists for.
    func testContiguousRowsAreUnknownNeverComplete() {
        let verdict = TrackListCompleteness.numbering(
            rowNumbers: Array(1...19), rowNoun: "region row"
        )
        XCTAssertFalse(verdict.partial)
        XCTAssertEqual(verdict.completeness, "unknown")
        XCTAssertNotEqual(verdict.completeness, "complete")
        XCTAssertTrue(verdict.evidence.isEmpty)
        XCTAssertEqual(verdict.missingTrackNumbers, [])
    }

    func testNoRowsProvesNothingFromNumberingAlone() {
        let verdict = TrackListCompleteness.numbering(rowNumbers: [], rowNoun: "region row")
        XCTAssertFalse(verdict.partial)
        XCTAssertTrue(verdict.evidence.isEmpty)
        XCTAssertEqual(verdict.missingTrackNumbers, [])
    }

    /// Unsorted input is the realistic input: `regionRows()` returns rows in
    /// walk order, which is not guaranteed to be numeric order.
    func testUnsortedRowNumbersStillFindTheGap() {
        let verdict = TrackListCompleteness.numbering(
            rowNumbers: [29, 3, 1, 2, 20], rowNoun: "region row"
        )
        XCTAssertEqual(verdict.missingTrackNumbers, Array(4...19) + Array(21...28))
    }

    // MARK: The two tools must agree

    /// The bug in one assertion: the arrangement map's verdict and the track
    /// listing's verdict, computed from the same row numbers, name the same
    /// missing tracks.
    func testArrangementMapAgreesWithTrackListingOnTheSameRows() {
        let trackVerdict = TrackListCompleteness.evaluate(
            rows: referenceRows.map {
                TrackListCompleteness.Row(number: $0, name: "T\($0)", isStack: false, expanded: nil)
            },
            scrollable: nil
        )
        let regionVerdict = LogicAccessibility.regionMapCoverage(
            rowNumbers: referenceRows, headerColumn: nil
        )
        XCTAssertEqual(regionVerdict.missingTrackNumbers, trackVerdict.missingTrackNumbers)
        XCTAssertEqual(regionVerdict.partial, trackVerdict.partial)
        XCTAssertEqual(regionVerdict.missingTrackNumbers, Array(10...19))
    }

    // MARK: What the call actually paid for

    func testFreeVerdictSaysItReadOnlyTheNumbering() {
        let coverage = LogicAccessibility.regionMapCoverage(
            rowNumbers: referenceRows, headerColumn: nil
        )
        XCTAssertEqual(coverage.checked, "row_numbering")
        XCTAssertTrue(coverage.partial)
    }

    /// The opt-in call folds in what the header column and the scroll bar saw,
    /// without losing the numbering's own evidence or repeating a sentence both
    /// produced.
    func testHeaderColumnEvidenceIsMergedNotDuplicated() {
        let shared = "track number(s) 10, 11 fall inside the rendered range and are not listed"
        let headerColumn = RegionEditGuard.Coverage(
            partial: true,
            unseenTrackNumbers: [30, 31],
            reasons: [
                shared,
                "the Tracks area is scrolled or scrollable, so rows outside the viewport are not"
                    + " rendered and cannot be listed"
            ]
        )
        let coverage = LogicAccessibility.regionMapCoverage(
            rowNumbers: referenceRows, headerColumn: headerColumn
        )
        XCTAssertEqual(coverage.checked, "row_numbering+track_header_column")
        XCTAssertEqual(coverage.missingTrackNumbers, Array(10...19) + [30, 31])
        XCTAssertTrue(coverage.evidence.contains { $0.contains("scrolled or scrollable") })
        XCTAssertEqual(coverage.evidence.filter { $0 == shared }.count, 1)
    }

    /// A scroll bar can prove rows are missing when the numbering cannot: the
    /// header column's verdict must be able to flip `partial` on its own.
    func testHeaderColumnAloneCanMakeAContiguousMapPartial() {
        let coverage = LogicAccessibility.regionMapCoverage(
            rowNumbers: Array(1...13),
            headerColumn: RegionEditGuard.Coverage(
                partial: true, unseenTrackNumbers: [],
                reasons: ["the Tracks area is scrolled or scrollable"]
            )
        )
        XCTAssertTrue(coverage.partial)
        XCTAssertEqual(coverage.completeness, "partial")
        XCTAssertEqual(coverage.missingTrackNumbers, [])
    }

    func testCheapVerdictWithNothingProvenIsUnknown() {
        let coverage = LogicAccessibility.regionMapCoverage(
            rowNumbers: Array(1...13), headerColumn: nil
        )
        XCTAssertFalse(coverage.partial)
        XCTAssertEqual(coverage.completeness, "unknown")
        XCTAssertTrue(coverage.evidence.isEmpty)
    }

    // MARK: The type Logic does not always publish

    /// The degraded shape the profile caught: one region on the row carries
    /// Logic's `, MIDI region` tail and the others do not. The row is one
    /// track, so it is one kind of region.
    func testOneTypedRegionTypesTheWholeRow() {
        let filled = LogicAccessibility.typedRowRegions([
            ["name": "a"],
            ["name": "b", "selected": true, "type": "midi"],
            ["name": "c"]
        ])
        XCTAssertEqual(filled.compactMap { $0["type"] as? String }, ["midi", "midi", "midi"])
        // Logic's own word is not relabelled as an inference.
        XCTAssertNil(filled[1]["type_from"])
        XCTAssertEqual(filled[0]["type_from"] as? String, "track_row")
        XCTAssertEqual(filled[2]["type_from"] as? String, "track_row")
    }

    /// Nothing to infer from: the regions come back exactly as they were, with
    /// no `type` invented and no `type_from` claiming there was one.
    func testARowWithNoTypedRegionIsLeftAlone() {
        let input: [[String: Any]] = [["name": "a"], ["name": "b"]]
        let filled = LogicAccessibility.typedRowRegions(input)
        XCTAssertEqual(filled.count, 2)
        XCTAssertTrue(filled.allSatisfy { $0["type"] == nil && $0["type_from"] == nil })
    }

    /// A row that reports two different types contradicts the one-kind-per-track
    /// rule the inference stands on, so nothing is filled in — a guess against
    /// the evidence is worse than an absent field.
    func testContradictoryTypesOnOneRowFillNothing() {
        let filled = LogicAccessibility.typedRowRegions([
            ["name": "a", "type": "midi"],
            ["name": "b", "type": "audio"],
            ["name": "c"]
        ])
        XCTAssertNil(filled[2]["type"])
        XCTAssertEqual(filled[0]["type"] as? String, "midi")
        XCTAssertEqual(filled[1]["type"] as? String, "audio")
    }

    func testAFullyTypedRowIsUnchanged() {
        let filled = LogicAccessibility.typedRowRegions([
            ["name": "a", "type": "audio"], ["name": "b", "type": "audio"]
        ])
        XCTAssertTrue(filled.allSatisfy { $0["type_from"] == nil })
        XCTAssertEqual(filled.compactMap { $0["type"] as? String }, ["audio", "audio"])
    }

    func testAnEmptyRowIsHandled() {
        XCTAssertTrue(LogicAccessibility.typedRowRegions([]).isEmpty)
    }

    // MARK: The note

    /// The cheap call has to say what it did NOT look at — otherwise
    /// `partial: false` reads as a stronger claim than it is.
    func testNoteOffersTheOptInOnlyWhenTheHeaderColumnWasNotRead() {
        let cheap = LogicAccessibility.regionMapNote(headerColumnChecked: false)
        XCTAssertTrue(cheap.contains("check_hidden_rows"))
        XCTAssertTrue(cheap.contains("NUMBERING"))

        let thorough = LogicAccessibility.regionMapNote(headerColumnChecked: true)
        XCTAssertFalse(thorough.contains("check_hidden_rows"))
    }

    func testNoteStatesTheOmittedDefaultsAndRefusesTheWordComplete() {
        for checked in [true, false] {
            let note = LogicAccessibility.regionMapNote(headerColumnChecked: checked)
            XCTAssertTrue(note.contains("partial: false"))
            XCTAssertTrue(note.contains("start_beat/end_beat are omitted on the barline,"
                + " selected when false"))
            XCTAssertFalse(note.contains("complete"))
        }
    }

    /// The other half of the honesty repair: an absent `type` has to be named
    /// as unknown, not left to read as "not audio".
    func testNoteSaysWhenTypeIsPresentAndWhatItsAbsenceMeans() {
        for checked in [true, false] {
            let note = LogicAccessibility.regionMapNote(headerColumnChecked: checked)
            XCTAssertTrue(note.contains("is NOT guaranteed"))
            XCTAssertTrue(note.contains("type_from"))
            XCTAssertTrue(note.contains("means UNKNOWN, never 'not audio'"))
        }
    }
}
