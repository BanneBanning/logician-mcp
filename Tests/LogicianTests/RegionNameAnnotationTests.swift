import XCTest

@testable import Logician

/// What a REGION is called, told apart from the live state Logic writes into
/// the same string.
///
/// The defect these pin, measured live 2026-09-03 on the reference project:
/// with exactly ONE track soloed, 53 of the project's 54 regions published
/// their `AXDescription` as `<name>, muted` — every region on the other 14
/// rendered rows — and `parseRegion` reported that whole string as the
/// region's `name`. `logic_list_regions` answered `808 Mutation Bass, muted`
/// and `logic_select_region {region_name: "808 Mutation Bass"}` then refused
/// its own reported name. One soloed track broke every region tool on every
/// other track, project-wide, for as long as the solo stood.
///
/// Unlike the track ROW, the region element publishes no quotes to fence the
/// name off (see `TrackRowDescriptionTests`), so this parse is a WORD LIST and
/// these tests are the receipt that it degrades honestly when it meets a tail
/// it cannot read.
final class RegionNameAnnotationTests: XCTestCase {

    // MARK: - The shapes Logic actually publishes

    /// The plain region: nothing stripped, nothing claimed.
    func testAPlainRegionKeepsItsNameAndReadsUnmuted() {
        let parsed = RegionNameAnnotation.parse("Crash")
        XCTAssertEqual(parsed.name, "Crash")
        XCTAssertEqual(parsed.annotations, [])
        XCTAssertFalse(parsed.unreadTail)
        XCTAssertEqual(RegionNameAnnotation.mutedVerdict(parsed) as? Bool, false)
    }

    /// The two causes measured 2026-09-03, which publish the SAME bytes: the
    /// region's own `mute: true` (`logic_set_region_params` → `Crash, muted`)
    /// and another track being soloed (`808 Mutation Bass, muted`, 53 of 54
    /// regions). The name comes back clean from both, and `muted` is true for
    /// both — the element does not say which cause, and neither do we.
    func testTheMutedAnnotationLeavesTheNameAndIsReportedBesideIt() {
        for description in ["Crash, muted", "808 Mutation Bass, muted"] {
            let parsed = RegionNameAnnotation.parse(description)
            XCTAssertEqual(parsed.annotations, ["muted"], description)
            XCTAssertEqual(RegionNameAnnotation.mutedVerdict(parsed) as? Bool, true, description)
        }
        XCTAssertEqual(RegionNameAnnotation.parse("Crash, muted").name, "Crash")
        XCTAssertEqual(
            RegionNameAnnotation.parse("808 Mutation Bass, muted").name, "808 Mutation Bass"
        )
    }

    /// Logic's own casing is what it is; the table is matched case-insensitively
    /// so a different build cannot reopen the leak over one capital letter.
    func testTheStateWordIsMatchedWithoutRegardToCase() {
        XCTAssertEqual(RegionNameAnnotation.parse("Crash, MUTED").name, "Crash")
        XCTAssertEqual(RegionNameAnnotation.parse("Crash, Muted").name, "Crash")
    }

    /// A word that merely CONTAINS the state word is not the state word.
    func testANeighbouringWordIsNotStripped() {
        let parsed = RegionNameAnnotation.parse("Kick, unmuted")
        XCTAssertEqual(parsed.name, "Kick, unmuted")
        XCTAssertTrue(parsed.unreadTail)
    }

    /// An empty description parses to an empty name rather than to nil, and an
    /// unnamed muted region still reports the mute.
    func testAnEmptyAndAnUnnamedRegionAreBothHandled() {
        XCTAssertEqual(RegionNameAnnotation.parse("").name, "")
        XCTAssertFalse(RegionNameAnnotation.parse("").unreadTail)
        let unnamed = RegionNameAnnotation.parse(", muted")
        XCTAssertEqual(unnamed.name, "")
        XCTAssertEqual(RegionNameAnnotation.mutedVerdict(unnamed) as? Bool, true)
    }

    // MARK: - Honest degradation

    /// A LOCALIZED annotation is not in the table, so it is NOT stripped: the
    /// name stays exactly as Logic shows it. What must never happen is the
    /// silent `false` — a muted region on a French Logic answering "not
    /// muted" — so the verdict is `"unavailable"` instead.
    func testATranslatedAnnotationIsLeftAloneAndTheVerdictSaysSo() {
        for description in ["Crash, en sourdine", "Crash, stumm", "Crash, sordina"] {
            let parsed = RegionNameAnnotation.parse(description)
            XCTAssertEqual(parsed.name, description, description)
            XCTAssertTrue(parsed.unreadTail, description)
            XCTAssertEqual(
                RegionNameAnnotation.mutedVerdict(parsed) as? String,
                RegionNameAnnotation.unavailable, description
            )
        }
    }

    /// The same branch catches an English region genuinely NAMED with a comma:
    /// we cannot prove `, DI` is a name rather than a state word nobody has
    /// measured, so the name is kept whole and the verdict abstains.
    func testANameContainingACommaIsKeptWholeAndAbstains() {
        let parsed = RegionNameAnnotation.parse("Gtr, DI")
        XCTAssertEqual(parsed.name, "Gtr, DI")
        XCTAssertEqual(
            RegionNameAnnotation.mutedVerdict(parsed) as? String, RegionNameAnnotation.unavailable
        )
    }

    /// …and when that comma name IS muted, the annotation we can read wins: the
    /// suffix comes off, the rest of the name stays, and the verdict is a plain
    /// true rather than an abstention, because a state word was actually seen.
    func testAKnownAnnotationOnACommaNameStillReadsAsMuted() {
        let parsed = RegionNameAnnotation.parse("Gtr, DI, muted")
        XCTAssertEqual(parsed.name, "Gtr, DI")
        XCTAssertTrue(parsed.unreadTail)
        XCTAssertEqual(RegionNameAnnotation.mutedVerdict(parsed) as? Bool, true)
    }

    /// A separator with nothing after it is not an annotation.
    func testATrailingSeparatorIsNotAnAnnotation() {
        let parsed = RegionNameAnnotation.parse("Kick, ")
        XCTAssertEqual(parsed.name, "Kick, ")
        XCTAssertEqual(
            RegionNameAnnotation.mutedVerdict(parsed) as? String, RegionNameAnnotation.unavailable
        )
    }

    // MARK: - The corner case, documented rather than solved

    /// A region LITERALLY named `Kick, muted` publishes the same bytes as a
    /// muted region called `Kick`. This is the one case the parse gets wrong,
    /// and it is wrong on purpose: the muted `Kick` is overwhelmingly the
    /// likelier of the two. The test exists so nobody "fixes" it by accident.
    func testARegionLiterallyNamedKickCommaMutedIsIndistinguishable() {
        let parsed = RegionNameAnnotation.parse("Kick, muted")
        XCTAssertEqual(parsed.name, "Kick")
        XCTAssertEqual(RegionNameAnnotation.mutedVerdict(parsed) as? Bool, true)
        // And when that region is ALSO muted, Logic writes the state twice; the
        // peel is a loop, so both come off and the name is still `Kick`.
        let both = RegionNameAnnotation.parse("Kick, muted, muted")
        XCTAssertEqual(both.name, "Kick")
        XCTAssertEqual(both.annotations, ["muted", "muted"])
    }

    // MARK: - Table-driven, not hard-coded

    /// The vocabulary is a parameter with a `LogicUIStrings` default, so a
    /// newly measured annotation is one row in that table and no code change.
    /// Pinned over a table this test supplies, which is what proves the parse
    /// reads the table rather than the word `muted`.
    func testTheParseReadsItsVocabularyFromTheTable() {
        let parsed = RegionNameAnnotation.parse(
            "Loop A, looped, muted",
            words: ["muted": "muted", "looped": "looped"]
        )
        XCTAssertEqual(parsed.name, "Loop A")
        XCTAssertEqual(parsed.annotations, ["looped", "muted"])
        XCTAssertFalse(parsed.unreadTail)
    }

    /// Today's table, measured: exactly one word, and `muted` is the key the
    /// payload reports it under.
    func testTodaysMeasuredTableIsTheOneWord() {
        XCTAssertEqual(
            LogicUIStrings.Element.RegionStateSuffix.words, ["muted": "muted"]
        )
        XCTAssertEqual(LogicUIStrings.Element.RegionStateSuffix.separator, ", ")
    }

    // MARK: - Matching a region_name argument

    /// BOTH spellings land. The clean name is what this server reports now; the
    /// annotated one is what it reported before 2026-09-03 and what an agent
    /// replaying an older answer will type.
    func testBothSpellingsOfANameMatchTheSameRegion() {
        for request in ["808 Mutation Bass", "808 Mutation Bass, muted"] {
            XCTAssertTrue(
                RegionNameAnnotation.matches(name: "808 Mutation Bass", request: request), request
            )
        }
    }

    /// Case-insensitive, exactly as every region matcher already was.
    func testMatchingIgnoresCase() {
        XCTAssertTrue(RegionNameAnnotation.matches(name: "Crash", request: "crash"))
        XCTAssertTrue(RegionNameAnnotation.matches(name: "Crash", request: "CRASH, MUTED"))
    }

    /// A different region is still a different region: accepting both
    /// spellings must not widen into accepting a prefix or a substring.
    func testADifferentNameStillDoesNotMatch() {
        XCTAssertFalse(RegionNameAnnotation.matches(name: "Crash", request: "Crash 2"))
        XCTAssertFalse(RegionNameAnnotation.matches(name: "Crash", request: "Cras"))
        XCTAssertFalse(RegionNameAnnotation.matches(name: "Crash", request: ""))
    }

    /// The comma-name case from the other direction: the caller who types the
    /// literal name of a region called `Kick, muted` reaches the region this
    /// parse cleaned to `Kick`, because the request is cleaned by the same rule.
    func testTheLiteralCommaNameStillReachesTheRegion() {
        XCTAssertTrue(RegionNameAnnotation.matches(name: "Kick", request: "Kick, muted"))
    }

    /// A name that IS kept whole (an unread tail) is matched whole.
    func testAnUnreadTailNameMatchesItself() {
        XCTAssertTrue(RegionNameAnnotation.matches(name: "Gtr, DI", request: "Gtr, DI"))
        XCTAssertTrue(RegionNameAnnotation.matches(name: "Gtr, DI", request: "gtr, di"))
    }

    // MARK: - The one shared word list

    /// The bounce diff's own canonicaliser used to carry a private `", muted"`
    /// constant. It now goes through this parse, so there is exactly one
    /// vocabulary in the server to keep in step with Logic.
    func testTheBounceCanonicaliserUsesTheSameList() {
        XCTAssertEqual(PrintedRegion.canonicalName("Crash, muted"), "Crash")
        XCTAssertEqual(PrintedRegion.canonicalName("Crash"), "Crash")
        XCTAssertEqual(PrintedRegion.canonicalName("Gtr, DI"), "Gtr, DI")
    }

    /// And the Region inspector's comparison, which reads the PANEL's string
    /// rather than the map's, trims on top of the same list.
    func testTheInspectorComparisonTrimsOnTopOfTheSameList() {
        XCTAssertEqual(RegionInspector.canonicalPanelName("  Crash, muted "), "Crash")
    }

    // MARK: - What the map tells the caller

    /// Every `logic_list_regions` carries the sentence that explains the field,
    /// including the part an agent must not miss: `muted: true` has two causes
    /// and the element does not say which.
    func testTheArrangementMapNoteExplainsTheField() {
        let note = LogicAccessibility.regionMapNote(headerColumnChecked: true)
        XCTAssertTrue(note.contains("muted"), note)
        XCTAssertTrue(note.contains("another track is soloed"), note)
        XCTAssertTrue(note.contains("unavailable"), note)
    }
}
