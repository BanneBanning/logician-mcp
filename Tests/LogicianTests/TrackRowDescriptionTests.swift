import XCTest

@testable import Logician

/// What a track row is CALLED, read out of the one description Logic
/// publishes for it.
///
/// The defect these pin: Logic appends the row's live state after the closing
/// quote — `Track 26 “Crash”, solo` — and whether that is part of the name was
/// a matter of which reader you asked. The track-header column's parse took
/// the text BETWEEN the quotes and never saw it; the arrangement's region walk
/// had a SECOND parse that split on the opening quote and kept the tail, so
/// the same row was `Crash` to `logic_list_tracks` and `Crash, solo` to
/// `logic_list_regions`. `resolveRegionRow` compares those names exactly, so
/// `logic_copy_region`, `logic_delete_region` and `logic_select_region` all
/// refused the name the server itself had just reported — reproduced live
/// 2026-09-03 on the reference project, 5 of 5 calls, and gone on the same 5
/// after this fix. One parse now, and these tests are what keeps it one.
final class TrackRowDescriptionTests: XCTestCase {

    // MARK: - The shapes Logic actually publishes

    /// The plain row, and the baseline every other case is compared against.
    func testAPlainRowGivesItsNumberAndName() {
        let parsed = TrackRowAddressing.parseRowDescription("Track 26 \u{201C}Crash\u{201D}")
        XCTAssertEqual(parsed?.number, 26)
        XCTAssertEqual(parsed?.name, "Crash")
    }

    /// The state annotations measured live on 2026-09-03 (English Logic Pro
    /// 12.3.1, reference project, the row walk's own `AXDescription`, each
    /// state set and verified by `logic_track_info`): `, solo` 3/3 reads while
    /// soloed, `, mute` 2/2 while muted, and NOTHING at all while
    /// record-armed, 2/2. Each must read as the SAME name as the plain row —
    /// that equality is the whole defect.
    func testALiveStateAnnotationIsNotPartOfTheName() {
        let plain = TrackRowAddressing.parseRowDescription("Track 26 \u{201C}Crash\u{201D}")
        for annotated in [
            "Track 26 \u{201C}Crash\u{201D}, solo",
            "Track 26 \u{201C}Crash\u{201D}, mute",
            // Both at once was not measured; the parse cannot tell one tail
            // from two, and this is here to say so out loud.
            "Track 26 \u{201C}Crash\u{201D}, solo, mute"
        ] {
            let parsed = TrackRowAddressing.parseRowDescription(annotated)
            XCTAssertEqual(parsed?.number, plain?.number, annotated)
            XCTAssertEqual(parsed?.name, plain?.name, annotated)
        }
    }

    /// The rule is STRUCTURAL — everything outside the quoted span goes,
    /// whatever the words are. So an annotation nobody has measured, and a
    /// LOCALIZED one, are dropped by the same code with no table to update.
    /// There is deliberately no list of English state words anywhere in this
    /// parse for a localized Logic to fall off.
    func testAnUnmeasuredOrTranslatedAnnotationIsDroppedByTheSameRule() {
        for annotated in [
            "Track 4 \u{201C}Bass\u{201D}, frozen",   // not measured; freeze was not tested
            "Track 4 \u{201C}Bass\u{201D}, hidden",   // not measured either
            "Track 4 \u{201C}Bass\u{201D}, record enable",
            "Track 4 \u{201C}Bass\u{201D}, stumm"     // a translation this code has never seen
        ] {
            XCTAssertEqual(TrackRowAddressing.parseRowDescription(annotated)?.name, "Bass", annotated)
        }
    }

    /// And the other side of "structural": a track whose REAL name ends in
    /// something that looks exactly like an annotation keeps it, because it is
    /// inside the quotes. A word list would have eaten this name.
    func testARealNameThatLooksLikeAnAnnotationSurvives() {
        XCTAssertEqual(
            TrackRowAddressing.parseRowDescription("Track 7 \u{201C}Kick, solo\u{201D}")?.name,
            "Kick, solo"
        )
        XCTAssertEqual(
            TrackRowAddressing.parseRowDescription("Track 7 \u{201C}Kick, solo\u{201D}, solo")?.name,
            "Kick, solo"
        )
        XCTAssertEqual(
            TrackRowAddressing.parseRowDescription("Track 7 \u{201C}, mute\u{201D}")?.name,
            ", mute"
        )
    }

    /// Names carrying the punctuation the parse itself keys on. The opening
    /// quote is found FIRST and the closing one LAST, so a name containing
    /// either survives whole.
    func testANameCarryingTheQuoteGlyphsSurvives() {
        XCTAssertEqual(
            TrackRowAddressing.parseRowDescription(
                "Track 3 \u{201C}The \u{201C}Big\u{201D} Room\u{201D}"
            )?.name,
            "The \u{201C}Big\u{201D} Room"
        )
        XCTAssertEqual(
            TrackRowAddressing.parseRowDescription("Track 3 \u{201C}Gtr \"DI\"\u{201D}")?.name,
            "Gtr \"DI\""
        )
    }

    /// An empty name is a real Logic row (a freshly created track can render
    /// nameless), and it is not the same answer as "this is not a track row".
    func testAnEmptyNameIsARowNotAFailure() {
        let parsed = TrackRowAddressing.parseRowDescription("Track 12 \u{201C}\u{201D}")
        XCTAssertEqual(parsed?.number, 12)
        XCTAssertEqual(parsed?.name, "")
    }

    // MARK: - What is NOT a track row

    /// Anything the parse cannot read says so rather than guessing. Note the
    /// reversed-quotes case: it used to be readable as an empty name because
    /// the close quote was searched for with `lastIndex` independently of
    /// where the open quote was.
    func testTextThatIsNotATrackRowIsRefused() {
        for text in [
            "",
            "Region \u{201C}Crash\u{201D}",           // a region, not a row
            "Track \u{201C}Crash\u{201D}",            // no number
            "Track twelve \u{201C}Crash\u{201D}",     // not a number
            "Track 26 Crash",                          // no quotes at all
            "Track 26 \u{201C}Crash",                  // no closing quote
            "Track 26 \u{201D}Crash\u{201C}",          // quotes the wrong way round
            " Track 26 \u{201C}Crash\u{201D}"          // the prefix must open the string
        ] {
            XCTAssertNil(TrackRowAddressing.parseRowDescription(text), text)
        }
    }

    // MARK: - The two planes cannot disagree again

    /// The header column and the region walk read DIFFERENT elements, and each
    /// element publishes the annotation on its own schedule — that is why the
    /// two spellings could exist at the same moment. Feeding both spellings of
    /// one row through the one parse is what makes the disagreement
    /// impossible, so this pins the parse being the same function rather than
    /// two functions that currently agree.
    func testBothPlanesReadTheSameNameFromDifferentlyAnnotatedDescriptions() {
        let fromHeaderColumn = TrackRowAddressing.parseRowDescription("Track 26 \u{201C}Crash\u{201D}")
        let fromRegionWalk = TrackRowAddressing.parseRowDescription("Track 26 \u{201C}Crash\u{201D}, solo")
        XCTAssertEqual(fromHeaderColumn?.name, fromRegionWalk?.name)
        XCTAssertEqual(fromHeaderColumn?.number, fromRegionWalk?.number)
    }

    /// And the addressing rule on top of it resolves what the caller was
    /// handed. This is the refused call from the live reproduction, replayed:
    /// row 26 read while soloed, addressed by the plain name every other tool
    /// reports.
    func testTheRefusedCopyResolvesOnceBothPlanesAgree() {
        let rows = ["Track 26 \u{201C}Crash\u{201D}, solo", "Track 1 \u{201C}Kick\u{201D}"]
            .compactMap { TrackRowAddressing.parseRowDescription($0) }
            .map { TrackRowAddressing.Row(number: $0.number, name: $0.name) }
        XCTAssertEqual(
            TrackRowAddressing.resolve(
                rows: rows, name: "Crash", number: 26, caseInsensitive: true
            ),
            .resolved(number: 26)
        )
        // The old walk's name, if a caller copied it out of an earlier
        // `logic_list_regions` response, is now simply a name no row carries —
        // a clean refusal, not a coin flip between two spellings.
        XCTAssertEqual(
            TrackRowAddressing.resolve(
                rows: rows, name: "Crash, solo", number: 26, caseInsensitive: true
            ),
            .mismatch(number: 26, expected: "Crash, solo", actual: "Crash")
        )
    }

    // MARK: - Locale

    /// French Logic writes `Piste 1 « Lofi Pad »` with guillemets and no-break
    /// spaces (R4, exact code points). The parse is shape-only, so it reads
    /// that row too once the constants are the French ones — the locale
    /// session's job stays a constants problem, not a parser one.
    func testTheFrenchRowShapeReadsWithTheFrenchConstants() {
        let parsed = TrackRowAddressing.parseRowDescription(
            "Piste 1 \u{00AB}\u{00A0}Lofi Pad\u{00A0}\u{00BB}",
            prefix: "Piste ",
            openQuote: "\u{00AB}",
            closeQuote: "\u{00BB}"
        )
        XCTAssertEqual(parsed?.number, 1)
        // The no-break spaces are Logic's punctuation, and they are still
        // inside the quoted span — recorded here as the measured truth, not
        // trimmed silently, so a locale session can see exactly what a French
        // name comparison would be up against.
        XCTAssertEqual(parsed?.name, "\u{00A0}Lofi Pad\u{00A0}")
    }
}
