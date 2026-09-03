import XCTest
@testable import Logician

/// WHICH track a new project comes with.
///
/// Logic will not show a project with no tracks, so every `logic_new_project`
/// is answered by its "Create New Track" sheet and every one of them therefore
/// creates a track (measured 2026-09-02: cancelling that sheet abandons the
/// project, 3/3). Until now the tool said so only in prose, inside a dialog log
/// entry: the KIND was "whatever the sheet offered" — Logic's memory of the
/// last kind used on that Mac — and the NAME cost the caller a second round
/// trip to `logic_list_tracks`. `initial_track` answers both, and the same
/// argument name lets the caller decide the kind instead of inheriting it.
///
/// The vocabulary is read off the sheet rather than kept in a table here: the
/// chooser's contents change with the Logic version and with the UI language,
/// so a table of English track types would be a fifth thing to keep in step
/// with Logic and would be wrong on any localized install.
final class InitialTrackTests: XCTestCase {

    /// The chooser this Logic publishes, read live 2026-09-03: four category
    /// groups, each with its own variants, and `Audio` the selected one. Note
    /// what a flat model of this gets wrong — `Software Instrument` belongs to
    /// TWO categories, and every category has a variant reading selected.
    private let sheet: [ProjectOpen.TrackTypeOffer] = [
        .init(category: "MIDI", variant: "Software Instrument", variantSelectedInCategory: true),
        .init(category: "MIDI", variant: "External MIDI", variantSelectedInCategory: false),
        .init(category: "Pattern", variant: "Software Instrument",
              variantSelectedInCategory: true),
        .init(category: "Pattern", variant: "External MIDI", variantSelectedInCategory: false),
        .init(category: "Session Player", variant: "Drummer", variantSelectedInCategory: true),
        .init(category: "Session Player", variant: "Bass Player",
              variantSelectedInCategory: false),
        .init(category: "Session Player", variant: "Keyboard Player",
              variantSelectedInCategory: false),
        .init(category: "Audio", variant: "Mic or Line", variantSelectedInCategory: true),
        .init(category: "Audio", variant: "Guitar or Bass", variantSelectedInCategory: false)
    ]

    // MARK: - Reading the sheet's own description of itself

    /// Logic's own words, verbatim from the live dump.
    func testTheGroupDescriptionsParse() throws {
        let midi = try XCTUnwrap(ProjectOpen.parseTrackTypeGroup("MIDI, Software Instrument"))
        XCTAssertEqual(midi.category, "MIDI")
        XCTAssertEqual(midi.variant, "Software Instrument")
        XCTAssertFalse(midi.selected)

        let audio = try XCTUnwrap(ProjectOpen.parseTrackTypeGroup("Audio, Mic or Line, selected"))
        XCTAssertEqual(audio.category, "Audio")
        XCTAssertEqual(audio.variant, "Mic or Line")
        XCTAssertTrue(audio.selected)
    }

    /// The sheet is full of other groups, and none of them is a track type.
    func testAnythingElseIsNotACategoryGroup() {
        XCTAssertNil(ProjectOpen.parseTrackTypeGroup(""))
        XCTAssertNil(ProjectOpen.parseTrackTypeGroup("Details"))
        XCTAssertNil(ProjectOpen.parseTrackTypeGroup("selected"))
    }

    /// On a Logic in another language the suffix will not be the English word,
    /// so NO group parses as selected — which must read as "cannot tell",
    /// never as "the first one".
    func testALocalizedSuffixLeavesNothingSelected() throws {
        let french = try XCTUnwrap(ProjectOpen.parseTrackTypeGroup("Audio, Mic or Line, sélectionné"))
        XCTAssertFalse(french.selected)
        XCTAssertEqual(french.category, "Audio")
    }

    // MARK: - The caller's spelling and Logic's

    func testUnderscoresAndCaseAreOneRequest() {
        XCTAssertEqual(ProjectOpen.normalizedTrackTypeName("software_instrument"),
                       "software instrument")
        XCTAssertEqual(ProjectOpen.normalizedTrackTypeName("  Software   Instrument "),
                       "software instrument")
        XCTAssertEqual(ProjectOpen.normalizedTrackTypeName("External-MIDI"), "external midi")
        XCTAssertEqual(ProjectOpen.normalizedTrackTypeName(""), "")
        XCTAssertEqual(ProjectOpen.normalizedTrackTypeName("   "), "")
    }

    /// `logic_create_track` spells its own argument `software_instrument`, so
    /// an agent that already knows this server types that here. It is a
    /// VARIANT of two categories on this sheet; the first the sheet lists
    /// wins, and the result names the category it picked.
    func testTheCreateTrackVocabularyReachesTheSheet() throws {
        let match = try XCTUnwrap(
            ProjectOpen.matchedTrackTypeOffer(requested: "software_instrument", offers: sheet)
        )
        XCTAssertEqual(match.category, "MIDI")
        XCTAssertEqual(match.variant, "Software Instrument")
        XCTAssertEqual(match.label, "MIDI/Software Instrument")
    }

    /// A bare CATEGORY takes the choice the sheet already made inside it,
    /// rather than the first variant listed — asking for "audio" must not
    /// silently switch a user's Guitar or Bass default to Mic or Line.
    func testACategoryKeepsTheSheetsOwnVariant() throws {
        let offers: [ProjectOpen.TrackTypeOffer] = [
            .init(category: "Audio", variant: "Mic or Line", variantSelectedInCategory: false),
            .init(category: "Audio", variant: "Guitar or Bass", variantSelectedInCategory: true)
        ]
        let match = try XCTUnwrap(
            ProjectOpen.matchedTrackTypeOffer(requested: "audio", offers: offers)
        )
        XCTAssertEqual(match.variant, "Guitar or Bass")
    }

    /// The spelling `offered` prints is the spelling that comes back — the
    /// only way to ask for the Pattern flavour of a shared variant name.
    func testTheLabelItPrintsIsTheLabelItAccepts() throws {
        let match = try XCTUnwrap(ProjectOpen.matchedTrackTypeOffer(
            requested: "pattern/software instrument", offers: sheet
        ))
        XCTAssertEqual(match.category, "Pattern")
        let underscored = try XCTUnwrap(ProjectOpen.matchedTrackTypeOffer(
            requested: "Session_Player/Bass_Player", offers: sheet
        ))
        XCTAssertEqual(underscored.label, "Session Player/Bass Player")
    }

    func testAUniquePrefixIsEnough() throws {
        XCTAssertEqual(
            ProjectOpen.matchedTrackTypeOffer(requested: "sess", offers: sheet)?.category,
            "Session Player"
        )
        XCTAssertEqual(
            ProjectOpen.matchedTrackTypeOffer(requested: "guitar", offers: sheet)?.variant,
            "Guitar or Bass"
        )
    }

    /// …and an AMBIGUOUS one is not. Two variants starting the same way must
    /// leave the caller told what was offered, never handed whichever the
    /// Accessibility walk reached first.
    func testAnAmbiguousPrefixMatchesNothing() {
        // "Bass Player" and "Bass" inside "Guitar or Bass" do not collide, but
        // these two do: both are variants beginning with the same word.
        let offers: [ProjectOpen.TrackTypeOffer] = [
            .init(category: "Session Player", variant: "Bass Player",
                  variantSelectedInCategory: true),
            .init(category: "Session Player", variant: "Bass Guitar",
                  variantSelectedInCategory: false)
        ]
        XCTAssertNil(ProjectOpen.matchedTrackTypeOffer(requested: "bass ", offers: offers))
    }

    /// An exact CATEGORY beats a variant of another one: `"pattern"` names the
    /// Pattern column, not something that merely starts that way.
    func testExactBeatsPrefix() throws {
        XCTAssertEqual(
            ProjectOpen.matchedTrackTypeOffer(requested: "pattern", offers: sheet)?.label,
            "Pattern/Software Instrument"
        )
        XCTAssertEqual(
            ProjectOpen.matchedTrackTypeOffer(requested: "external midi", offers: sheet)?.category,
            "MIDI"
        )
    }

    func testNothingMatchesAnEmptyRequestOrAnEmptySheet() {
        XCTAssertNil(ProjectOpen.matchedTrackTypeOffer(requested: "", offers: sheet))
        XCTAssertNil(ProjectOpen.matchedTrackTypeOffer(requested: "   ", offers: sheet))
        XCTAssertNil(ProjectOpen.matchedTrackTypeOffer(requested: "audio", offers: []))
        XCTAssertNil(ProjectOpen.matchedTrackTypeOffer(requested: "banjo", offers: sheet))
    }

    // MARK: - What the caller is told

    func testTheBlockNamesTheTrackItWasHanded() {
        let payload = ProjectOpen.initialTrackPayload(
            requested: nil, selected: sheet[7], offered: sheet,
            track: (1, "Audio 1"), trackUnavailable: nil
        )
        XCTAssertEqual(payload["type"] as? String, "Audio/Mic or Line")
        XCTAssertEqual(payload["category"] as? String, "Audio")
        XCTAssertEqual(payload["variant"] as? String, "Mic or Line")
        XCTAssertEqual(payload["track_number"] as? Int, 1)
        XCTAssertEqual(payload["track_name"] as? String, "Audio 1")
        XCTAssertEqual(payload["verified_by"] as? String, "logic_list_tracks")
        XCTAssertEqual((payload["offered"] as? [String])?.first, "MIDI/Software Instrument")
        // Nothing was asked for, so nothing is reported as honoured or refused.
        XCTAssertNil(payload["requested"])
        XCTAssertNil(payload["requested_honoured"])
    }

    /// Honoured is decided against what was READ BACK off the sheet, which is
    /// the whole reason the press is followed by a second read: live
    /// 2026-09-03 the press moved the sheet's selected group from `Audio, Mic
    /// or Line, selected` to `MIDI, Software Instrument, selected`, and the
    /// project came out with `Inst 1` in it.
    func testAnHonouredRequestSaysSo() {
        let payload = ProjectOpen.initialTrackPayload(
            requested: "software_instrument", selected: sheet[0], offered: sheet,
            track: (1, "Inst 1"), trackUnavailable: nil
        )
        XCTAssertEqual(payload["requested"] as? String, "software_instrument")
        XCTAssertEqual(payload["requested_honoured"] as? Bool, true)
        XCTAssertEqual(payload["type"] as? String, "MIDI/Software Instrument")
    }

    /// The case that must not read as success: the sheet stayed on a kind
    /// other than the one asked for, so a track of another kind exists.
    func testARequestTheSheetCouldNotHonourSaysSo() {
        let payload = ProjectOpen.initialTrackPayload(
            requested: "drummer", selected: sheet[7], offered: sheet,
            track: (1, "Audio 1"), trackUnavailable: nil
        )
        XCTAssertEqual(payload["requested_honoured"] as? Bool, false)
        XCTAssertEqual(payload["type"] as? String, "Audio/Mic or Line")
    }

    /// A sheet whose selected group this Logic does not mark is an unreadable
    /// TYPE, not a missing field and not a guess — and a request against it
    /// was certainly not honoured.
    func testAnUnreadableChooserIsSpokenAloud() throws {
        let payload = ProjectOpen.initialTrackPayload(
            requested: "audio", selected: nil, offered: [],
            track: (1, "Audio 1"), trackUnavailable: nil
        )
        let type = try XCTUnwrap(payload["type"] as? String)
        XCTAssertTrue(type.hasPrefix("unavailable:"), type)
        XCTAssertTrue(type.contains("logic_list_tracks"), type)
        XCTAssertEqual(payload["requested_honoured"] as? Bool, false)
        XCTAssertEqual(payload["offered"] as? [String], [])
        XCTAssertNil(payload["category"])
    }

    /// And a track list that would not answer leaves a REASON where the name
    /// goes — never an absent key, never a name nobody read.
    func testAnUnreadableTrackListIsSpokenAloud() throws {
        let payload = ProjectOpen.initialTrackPayload(
            requested: nil, selected: sheet[7], offered: sheet,
            track: nil, trackUnavailable: "the track list did not answer within 2.0 s"
        )
        let name = try XCTUnwrap(payload["track_name"] as? String)
        XCTAssertTrue(name.hasPrefix("unavailable:"), name)
        XCTAssertTrue(name.contains("did not answer"), name)
        XCTAssertNil(payload["track_number"])
        XCTAssertNil(payload["verified_by"])
    }

    func testTheDefaultReasonIsStillAReason() throws {
        let payload = ProjectOpen.initialTrackPayload(
            requested: nil, selected: nil, offered: [], track: nil, trackUnavailable: nil
        )
        let name = try XCTUnwrap(payload["track_name"] as? String)
        XCTAssertTrue(name.hasPrefix("unavailable:"), name)
    }

    // MARK: - The warning, on the one path that cannot refuse

    /// There is no refusal available here and the warning has to say why: by
    /// the time the sheet is up the project EXISTS and Cancel would close it
    /// (measured 3/3). So the caller is told what happened, what was on offer,
    /// and the two calls that fix it.
    func testTheWarningNamesTheOfferAndTheWayOut() {
        let warning = ProjectOpen.trackTypeNotOfferedWarning(
            requested: "banjo", offered: sheet, created: "Audio/Mic or Line"
        )
        XCTAssertTrue(warning.contains("'banjo'"), warning)
        XCTAssertTrue(warning.contains("MIDI/Software Instrument"), warning)
        XCTAssertTrue(warning.contains("Audio/Mic or Line"), warning)
        XCTAssertTrue(warning.contains("logic_create_track"), warning)
        XCTAssertTrue(warning.contains("logic_delete_track"), warning)
        XCTAssertTrue(warning.contains("cancelling"), warning)
    }

    func testTheWarningSurvivesASheetWithNoReadableChooser() {
        let warning = ProjectOpen.trackTypeNotOfferedWarning(
            requested: "audio", offered: [], created: nil
        )
        XCTAssertTrue(warning.contains("no track-type radio buttons"), warning)
        XCTAssertTrue(warning.contains("not readable from here"), warning)
        XCTAssertFalse(warning.contains("offered: ."), warning)
    }

    // MARK: - Budgets and prose

    /// Looked for before it is waited on, and small: the track is built while
    /// the sheet closes, so this budget is only ever spent on the gap.
    func testTheNameBudgetIsSmallAndPacedByThePoll() {
        XCTAssertEqual(ProjectOpen.initialTrackNameBudgetSeconds, 2.0)
        XCTAssertGreaterThan(
            ProjectOpen.initialTrackNameBudgetSeconds, ProjectOpen.pollIntervalSeconds
        )
    }

    /// The note points at the field rather than repeating it — and still says
    /// the one thing a caller must not have to discover, that a track exists.
    func testTheNotePointsAtTheField() {
        let created = ProjectOpen.openNote(created: true, answeredCreateTrackSheet: true)
        XCTAssertTrue(created.contains("initial_track"), created)
        XCTAssertTrue(created.contains("ONE track"), created)
        XCTAssertFalse(
            ProjectOpen.openNote(created: true, answeredCreateTrackSheet: false)
                .contains("initial_track")
        )
    }
}
