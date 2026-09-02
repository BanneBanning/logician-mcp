import XCTest
@testable import Logician

/// `logic_import_midi` without Logic: the argument mapping, the filename, the
/// tempo prompt's policy, the census diff and the note diff.
///
/// These are the parts that decide WHAT gets written and WHAT counts as proof,
/// and none of them needs a running DAW to be wrong. The live route is
/// verified by hand against the sandbox project; everything here is pinned.
final class ImportMIDITests: XCTestCase {

    // MARK: - Arguments to an arrangement

    private func arrangement(_ tracks: [[String: Any]]) throws -> [SMFTrack] {
        try ImportMIDI.tracks(from: tracks)
    }

    func testAWholeArrangementMapsOntoSMFTracksInOrder() throws {
        let tracks = try arrangement([
            [
                "name": "Bass",
                "channel": 2,
                "notes": [
                    ["pitch": "C1", "bar": 9, "beat": 1.5, "duration_beats": 0.5, "velocity": 88],
                    ["pitch": 36, "bar": 10]
                ],
                "control_changes": [["cc": 1, "value": 64, "bar": 9, "beat": 2]],
                "pitch_bends": [["value": -4096, "bar": 9, "channel": 3]],
                "program_changes": [["program": 33, "bar": 9]]
            ],
            ["name": "Pad", "notes": [["pitch": "C3", "bar": 9]]]
        ])
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks.map(\.name), ["Bass", "Pad"])
        XCTAssertEqual(tracks[0].channel, 2)
        // The channel defaults to 1, not to the previous track's.
        XCTAssertEqual(tracks[1].channel, 1)
        XCTAssertEqual(tracks[0].notes, [
            SMFNote(pitch: 36, bar: 9, beat: 1.5, durationBeats: 0.5, velocity: 88),
            SMFNote(pitch: 36, bar: 10, beat: 1, durationBeats: 1, velocity: 100)
        ])
        XCTAssertEqual(
            tracks[0].controlChanges, [SMFControlChange(controller: 1, value: 64, bar: 9, beat: 2)]
        )
        XCTAssertEqual(tracks[0].pitchBends, [SMFPitchBend(value: -4096, bar: 9, channel: 3)])
        XCTAssertEqual(tracks[0].programChanges, [SMFProgramChange(program: 33, bar: 9)])
        XCTAssertEqual(tracks[1].notes.first?.pitch, 60, "C3 is middle C = 60, Logic's convention")
    }

    /// JSON numbers arrive as Int or Double depending on how the client typed
    /// them, and `2` and `2.0` are the same beat.
    func testIntegerAndFloatingArgumentsMeanTheSameThing() throws {
        let integers = try arrangement([["name": "A", "notes": [
            ["pitch": 60, "bar": 2, "beat": 2, "duration_beats": 1, "velocity": 90]
        ]]])
        let doubles = try arrangement([["name": "A", "notes": [
            ["pitch": 60.0, "bar": 2.0, "beat": 2.0, "duration_beats": 1.0, "velocity": 90.0]
        ]]])
        XCTAssertEqual(integers, doubles)
    }

    func testControllerIsAcceptedAsASpellingOfCC() throws {
        let tracks = try arrangement([["name": "A", "control_changes": [
            ["controller": 11, "value": 100, "bar": 1]
        ]]])
        XCTAssertEqual(tracks[0].controlChanges.first?.controller, 11)
    }

    func testAnArrangementWithNoTracksIsRefused() {
        XCTAssertThrowsError(try arrangement([])) { error in
            XCTAssertTrue("\(error)".contains("at least one track"), "\(error)")
        }
    }

    func testATrackWithoutANameIsRefusedBecauseTheNameIsTheOnlyHandle() {
        XCTAssertThrowsError(try arrangement([["notes": []]])) { error in
            XCTAssertTrue("\(error)".contains("tracks[0] needs a non-empty name"), "\(error)")
            XCTAssertTrue("\(error)".contains("REGION"), "\(error)")
        }
        XCTAssertThrowsError(try arrangement([["name": "   "]]))
    }

    /// Two regions with one name could not be told apart afterwards, and both
    /// verification and cleanup address by name.
    func testTwoTracksWithTheSameNameAreRefused() {
        XCTAssertThrowsError(try arrangement([["name": "Pad"], ["name": "pad"]])) { error in
            XCTAssertTrue("\(error)".contains("both named"), "\(error)")
        }
    }

    func testAnEventWithoutABarIsRefusedAndNamesItsIndex() {
        XCTAssertThrowsError(try arrangement([["name": "A", "notes": [
            ["pitch": 60, "bar": 1], ["pitch": 62]
        ]]])) { error in
            XCTAssertTrue("\(error)".contains("tracks[0].notes[1] needs bar"), "\(error)")
        }
    }

    func testAnUnparseablePitchIsRefusedWithTheConvention() {
        XCTAssertThrowsError(try arrangement([["name": "A", "notes": [["pitch": "H4", "bar": 1]]]])) { error in
            XCTAssertTrue("\(error)".contains("C3"), "\(error)")
        }
    }

    func testAnEventListThatIsNotAListIsRefused() {
        XCTAssertThrowsError(try arrangement([["name": "A", "notes": "C3"]])) { error in
            XCTAssertTrue("\(error)".contains("tracks[0].notes must be an array"), "\(error)")
        }
    }

    /// The mapping's real contract: what it produces, written out and read back
    /// by the independent reader, is the arrangement that was asked for.
    func testTheMappedArrangementRoundTripsThroughTheWriterAndBackOut() throws {
        let tracks = try arrangement([
            ["name": "Alpha", "channel": 1, "notes": [
                ["pitch": "C3", "bar": 62, "duration_beats": 1, "velocity": 100],
                ["pitch": "E3", "bar": 62, "beat": 2, "duration_beats": 1, "velocity": 100]
            ]],
            ["name": "Bravo", "channel": 2, "notes": [
                ["pitch": "C4", "bar": 62, "beat": 3, "duration_beats": 2, "velocity": 64]
            ]]
        ])
        var timing = SMFTiming()
        timing.originBar = 62
        let file = try SMFTestReader.read(
            try SMFWriter(tracks: tracks, timing: timing).encode()
        )
        XCTAssertEqual(file.format, 1)
        // Conductor + one MTrk per track.
        XCTAssertEqual(file.tracks.count, 3)
        XCTAssertEqual(file.tracks[1].name, "Alpha")
        XCTAssertEqual(file.tracks[2].name, "Bravo")
        XCTAssertEqual(file.tracks[1].notes, [
            .note(tick: 0, endTick: 960, channel: 1, pitch: 60, velocity: 100, releaseVelocity: 0),
            .note(tick: 960, endTick: 1920, channel: 1, pitch: 64, velocity: 100, releaseVelocity: 0)
        ])
        XCTAssertEqual(file.tracks[2].notes, [
            .note(tick: 1920, endTick: 3840, channel: 2, pitch: 72, velocity: 64, releaseVelocity: 0)
        ])
    }

    // MARK: - The file's name

    func testTheFileNameCarriesTheFirstTrackAndCannotEscapeTheDirectory() {
        XCTAssertEqual(
            ImportMIDI.fileName(firstTrack: "Hook Bass", timestamp: 1234),
            "logicmcp-import-Hook-Bass-1234.mid"
        )
        let escaped = ImportMIDI.fileName(firstTrack: "../../../../etc/passwd", timestamp: 1)
        XCTAssertFalse(escaped.contains("/"))
        XCTAssertTrue(escaped.hasSuffix(".mid"))
        // The property that matters: glued onto the captures directory it
        // cannot address anything outside it.
        let path = URL(fileURLWithPath: "/base/captures").appendingPathComponent(escaped).path
        XCTAssertTrue(path.hasPrefix("/base/captures/"))
    }

    func testANamelessArrangementStillGetsAFileName() {
        XCTAssertEqual(
            ImportMIDI.fileName(firstTrack: nil, timestamp: 7), "logicmcp-import-arrangement-7.mid"
        )
        XCTAssertEqual(
            ImportMIDI.fileName(firstTrack: "..", timestamp: 7), "logicmcp-import-arrangement-7.mid"
        )
    }

    // MARK: - The tempo prompt

    /// The buttons are IDENTIFIED, not titled: the titles are localisable and
    /// the window has no title at all.
    func testThePromptPolicyPicksNoUnlessTempoWasAskedFor() {
        XCTAssertEqual(ImportMIDI.answer(importTempo: false), .no)
        XCTAssertEqual(ImportMIDI.answer(importTempo: true), .importTempo)
        XCTAssertEqual(ImportMIDI.TempoPrompt.no.rawValue, "action-button-1")
        XCTAssertEqual(ImportMIDI.TempoPrompt.importTempo.rawValue, "action-button-2")
        XCTAssertEqual(ImportMIDI.TempoPrompt.cancel.rawValue, "action-button-3")
    }

    func testTheTempoPromptIsRecognisedByItsOwnFirstLine() {
        XCTAssertTrue(ImportMIDI.isTempoPrompt(texts: [
            "Also import tempo information?",
            "This will replace the project’s current tempo information in the range of the MIDI file."
        ]))
        // The save-changes alert, which route 2 raises and which must never be
        // answered by this tool.
        XCTAssertFalse(ImportMIDI.isTempoPrompt(texts: [
            "Do you want to save the changes made to the document “Testlåt Copy”?",
            "Your changes will be lost if you don’t save them."
        ]))
        XCTAssertFalse(ImportMIDI.isTempoPrompt(texts: []))
    }

    // MARK: - The census

    private func regionPayload(_ rows: [(Int, String, [(String, Int)])]) -> [String: Any] {
        [
            "tracks": rows.map { number, name, regions in
                [
                    "track_number": number,
                    "track_name": name,
                    "regions": regions.map { ["name": $0.0, "start_bar": $0.1] }
                ] as [String: Any]
            }
        ]
    }

    func testTheRegionCensusDiffFindsOnlyWhatTheImportAdded() {
        let before = ImportMIDI.RegionCensus.parse(regionPayload([
            (1, "Lofi Pad", [("Lofi Pad", 1), ("Lofi Pad.1", 9)]),
            (2, "Bas", [("Bas", 9)])
        ]))
        let after = ImportMIDI.RegionCensus.parse(regionPayload([
            (1, "Lofi Pad", [("Lofi Pad", 1), ("Lofi Pad.1", 9)]),
            (2, "Bas", [("Bas", 9)]),
            (30, "Studio Grand", [("R2 Alpha", 62)]),
            (31, "Epic Cloud Formation", [("R2 Bravo", 62)])
        ]))
        let added = after.added(since: before)
        XCTAssertEqual(added.map(\.name), ["R2 Alpha", "R2 Bravo"])
        XCTAssertEqual(added.map(\.startBar), [62, 62])
        XCTAssertEqual(added.map(\.trackName), ["Studio Grand", "Epic Cloud Formation"])
        XCTAssertTrue(before.added(since: after).isEmpty)
    }

    /// A SET difference, not an index one: a region added to an EXISTING track
    /// must be found, and the untouched ones must not be.
    func testARegionAddedToAnExistingTrackIsAlsoNew() {
        let before = ImportMIDI.RegionCensus.parse(regionPayload([(1, "Pad", [("Pad", 1)])]))
        let after = ImportMIDI.RegionCensus.parse(
            regionPayload([(1, "Pad", [("Pad", 1), ("Pad.1", 5)])])
        )
        XCTAssertEqual(after.added(since: before).map(\.name), ["Pad.1"])
    }

    func testAddedTrackNumbersAreTheOnesThatWereNotThereBefore() {
        let before: [[String: Any]] = [["track_number": 1], ["track_number": 2], ["track_number": 29]]
        let after: [[String: Any]] = [
            ["track_number": 1], ["track_number": 2], ["track_number": 29],
            ["track_number": 30], ["track_number": 31]
        ]
        XCTAssertEqual(ImportMIDI.addedTrackNumbers(before: before, after: after), [30, 31])
        XCTAssertEqual(ImportMIDI.addedTrackNumbers(before: after, after: after), [])
    }

    // MARK: - The note diff

    private func row(
        _ bar: Int, _ beat: Int, _ pitch: Int, velocity: Int?, status: String = "Note"
    ) -> EventRow {
        EventRow(
            index: 0, position: [bar, beat, 1, 1], status: status, channel: "1",
            numberText: EventListWrite.noteName(pitch), pitch: pitch, velocity: velocity,
            length: [0, 1, 0, 0], lengthText: "0 1 0 0", positionText: "\(bar) \(beat) 1 1"
        )
    }

    func testAnExactImportDiffsClean() {
        let expected = [
            SMFNote(pitch: 60, bar: 62, beat: 1, velocity: 100),
            SMFNote(pitch: 64, bar: 62, beat: 2, velocity: 100)
        ]
        let diff = ImportMIDI.diff(expected: expected, observed: [
            row(62, 1, 60, velocity: 100), row(62, 2, 64, velocity: 100)
        ])
        XCTAssertTrue(diff.matches)
        XCTAssertEqual(diff.expected, 2)
        XCTAssertEqual(diff.observed, 2)
    }

    /// A fractional beat lands inside Logic's 1/16 grid, so the diff compares
    /// the BEAT and not the division and tick — otherwise every offbeat note
    /// would read as drift the writer did not create.
    func testAnOffbeatNoteMatchesTheBeatItSitsIn() {
        let diff = ImportMIDI.diff(
            expected: [SMFNote(pitch: 60, bar: 4, beat: 2.5, velocity: 100)],
            observed: [EventRow(
                index: 0, position: [4, 2, 3, 1], status: "Note", channel: "1",
                numberText: "C3", pitch: 60, velocity: 100, length: [0, 0, 2, 0],
                lengthText: "0 0 2 0", positionText: "4 2 3 1"
            )]
        )
        XCTAssertTrue(diff.matches, "\(diff)")
    }

    func testAMissingNoteAndAnExtraNoteAreBothNamed() {
        let diff = ImportMIDI.diff(
            expected: [
                SMFNote(pitch: 60, bar: 1, beat: 1, velocity: 100),
                SMFNote(pitch: 64, bar: 1, beat: 2, velocity: 100)
            ],
            observed: [row(1, 1, 60, velocity: 100), row(1, 3, 67, velocity: 100)]
        )
        XCTAssertFalse(diff.matches)
        XCTAssertEqual(diff.missing, ["bar 1 beat 2 E3 vel 100"])
        XCTAssertEqual(diff.unexpected, ["bar 1 beat 3 G3 vel 100"])
    }

    func testAVelocityThatDidNotSurviveIsReportedWithoutLosingTheNote() {
        let diff = ImportMIDI.diff(
            expected: [SMFNote(pitch: 60, bar: 1, beat: 1, velocity: 100)],
            observed: [row(1, 1, 60, velocity: 64)]
        )
        XCTAssertFalse(diff.matches)
        XCTAssertTrue(diff.missing.isEmpty)
        XCTAssertTrue(diff.unexpected.isEmpty)
        XCTAssertEqual(diff.velocityMismatches, ["bar 1 beat 1 C3: wrote 100, Logic shows 64"])
    }

    /// Two notes on one pitch and position at different velocities: the pair
    /// must match up rather than produce two spurious mismatches.
    func testAUnisonAtTwoVelocitiesPairsUpByVelocity() {
        let diff = ImportMIDI.diff(
            expected: [
                SMFNote(pitch: 60, bar: 1, beat: 1, velocity: 100),
                SMFNote(pitch: 60, bar: 1, beat: 1, velocity: 40)
            ],
            observed: [row(1, 1, 60, velocity: 40), row(1, 1, 60, velocity: 100)]
        )
        XCTAssertTrue(diff.matches, "\(diff)")
    }

    /// A CC or program-change row is a row too. Counting it as an extra note
    /// would make a correct import look wrong.
    func testNonNoteRowsAreIgnored() {
        let diff = ImportMIDI.diff(
            expected: [SMFNote(pitch: 60, bar: 1, beat: 1, velocity: 100)],
            observed: [
                row(1, 1, 60, velocity: 100),
                row(1, 1, 1, velocity: 64, status: "Control")
            ]
        )
        XCTAssertTrue(diff.matches, "\(diff)")
        XCTAssertEqual(diff.observed, 1)
    }

    func testAnImportThatLandedNothingReportsEveryNoteMissing() {
        let diff = ImportMIDI.diff(
            expected: [
                SMFNote(pitch: 60, bar: 1, beat: 1, velocity: 100),
                SMFNote(pitch: 62, bar: 1, beat: 2, velocity: 100)
            ],
            observed: []
        )
        XCTAssertFalse(diff.matches)
        XCTAssertEqual(diff.observed, 0)
        XCTAssertEqual(diff.missing.count, 2)
        XCTAssertEqual(diff.payload["matches"] as? Bool, false)
    }

    // MARK: - Routing onto tracks that already exist (to_track)

    private func routings(_ tracks: [[String: Any]]) throws -> [ImportMIDI.Routing] {
        try ImportMIDI.routings(from: tracks)
    }

    /// The whole point of the argument: one import, each SMF track sent to its
    /// own existing destination, and any subset left unrouted.
    func testEachTrackRoutesToItsOwnDestinationAndUnroutedOnesAreAbsent() throws {
        let routed = try routings([
            ["name": "Bass Line", "to_track": "Bas"],
            ["name": "Pad", "notes": []],
            ["name": "Kit", "to_track": "Drums", "to_track_number": 7]
        ])
        XCTAssertEqual(routed, [
            ImportMIDI.Routing(track: "Bass Line", destination: "Bas", destinationNumber: nil),
            ImportMIDI.Routing(track: "Kit", destination: "Drums", destinationNumber: 7)
        ])
    }

    func testNoToTrackAnywhereIsNoRouting() throws {
        XCTAssertTrue(try routings([["name": "A"], ["name": "B"]]).isEmpty)
    }

    /// A blank destination is not a destination; it keeps the new track rather
    /// than being resolved against a track named "".
    func testABlankToTrackIsNotARouting() throws {
        XCTAssertTrue(try routings([["name": "A", "to_track": "   "]]).isEmpty)
    }

    /// The number only ever disambiguates a NAME. Alone it is a mistake worth
    /// naming, not a silent no-op.
    func testAToTrackNumberWithoutAToTrackIsRefused() {
        XCTAssertThrowsError(try routings([["name": "A", "to_track_number": 3]])) { error in
            XCTAssertEqual((error as? LogicianError)?.code, "invalid_arguments")
        }
    }

    /// Two parts onto one track would stack both regions on the same lane at
    /// the same bar - one playing over the other, and no way to tell them
    /// apart afterwards.
    func testTwoTracksCannotShareOneDestination() {
        XCTAssertThrowsError(try routings([
            ["name": "Bass Line", "to_track": "Bas"],
            ["name": "Bass Double", "to_track": "bas"]
        ])) { error in
            XCTAssertEqual((error as? LogicianError)?.code, "invalid_arguments")
            XCTAssertTrue(
                error.localizedDescription.contains("Bass Double"),
                error.localizedDescription
            )
        }
    }

    /// The same NAME with two different numbers is two different tracks.
    func testTheSameNameWithDifferentNumbersIsTwoDestinations() throws {
        let routed = try routings([
            ["name": "A", "to_track": "Gtr", "to_track_number": 4],
            ["name": "B", "to_track": "Gtr", "to_track_number": 5]
        ])
        XCTAssertEqual(routed.count, 2)
    }

    /// JSON numbers arrive as Int or Double; both are track 7.
    func testAFloatingToTrackNumberIsAnInteger() throws {
        XCTAssertEqual(
            try routings([["name": "A", "to_track": "Bas", "to_track_number": 7.0]]).first?
                .destinationNumber,
            7
        )
    }

    // MARK: Resolving a destination against the track headers

    private let headers = [
        ImportMIDI.TrackHeader(number: 1, name: "Lofi Pad"),
        ImportMIDI.TrackHeader(number: 2, name: "Bas"),
        ImportMIDI.TrackHeader(number: 4, name: "Gtr"),
        ImportMIDI.TrackHeader(number: 5, name: "Gtr")
    ]

    func testADestinationResolvesCaseInsensitivelyToItsHeader() {
        XCTAssertEqual(
            ImportMIDI.resolve(destination: "bas", number: nil, in: headers),
            .resolved(ImportMIDI.TrackHeader(number: 2, name: "Bas"))
        )
    }

    /// The refusal carries what IS there, so the retry is informed.
    func testAMissingDestinationListsTheCandidates() {
        XCTAssertEqual(
            ImportMIDI.resolve(destination: "Baas", number: nil, in: headers),
            .notFound(candidates: ["Lofi Pad", "Bas", "Gtr", "Gtr"])
        )
    }

    func testADuplicatedDestinationNameIsAmbiguousAndOffersTheNumbers() {
        XCTAssertEqual(
            ImportMIDI.resolve(destination: "Gtr", number: nil, in: headers),
            .ambiguous(numbers: [4, 5])
        )
    }

    func testATrackNumberResolvesTheDuplicate() {
        XCTAssertEqual(
            ImportMIDI.resolve(destination: "Gtr", number: 5, in: headers),
            .resolved(ImportMIDI.TrackHeader(number: 5, name: "Gtr"))
        )
    }

    /// A number pointing at a track with another name is a stale reference,
    /// not a rename request.
    func testANumberNamingADifferentTrackIsAMismatch() {
        XCTAssertEqual(
            ImportMIDI.resolve(destination: "Bas", number: 4, in: headers),
            .mismatch(number: 4, actual: "Gtr")
        )
    }

    func testANumberThatIsNotAVisibleRowIsNotFound() {
        XCTAssertEqual(
            ImportMIDI.resolve(destination: "Bas", number: 99, in: headers),
            .notFound(candidates: ["Lofi Pad", "Bas", "Gtr", "Gtr"])
        )
    }

    /// The header rows come straight off logic_list_tracks; a row missing
    /// either field is not a destination anyone can be routed to.
    func testHeadersAreBuiltFromListTracksRowsAndIncompleteRowsAreDropped() {
        let rows: [[String: Any]] = [
            ["track_number": 2, "track_name": "Bas"],
            ["track_name": "no number"],
            ["track_number": 3]
        ]
        XCTAssertEqual(
            rows.compactMap(ImportMIDI.TrackHeader.init(row:)),
            [ImportMIDI.TrackHeader(number: 2, name: "Bas")]
        )
    }

    // MARK: - Which region `verify: "events"` reads back

    /// The project after two unrouted imports: BOTH new tracks are called
    /// `Studio Grand`, because Logic names them after the default patch it
    /// loaded and not after the SMF track. This is the shape the note
    /// verification got wrong live (2026-09-02) — it addressed the read by
    /// track NAME, resolved the FIRST namesake, and reported a mismatch about
    /// the region it had not read.
    private let twoStudioGrands = [
        ImportMIDI.RegionCensus.Entry(
            trackNumber: 32, trackName: "Studio Grand", name: "IMPPROF-C1", startBar: 1),
        ImportMIDI.RegionCensus.Entry(
            trackNumber: 33, trackName: "Studio Grand", name: "IMPPROF-E1", startBar: 1)
    ]

    func testTheVerifyTargetIsAddressedByTrackNumberNotByTheSharedTrackName() {
        XCTAssertEqual(
            ImportMIDI.verifyTarget(forTrackNamed: "IMPPROF-E1", in: twoStudioGrands),
            ImportMIDI.VerifyTarget(
                regionName: "IMPPROF-E1", trackName: "Studio Grand",
                trackNumber: 33, startBar: 1),
            "the row this import created, not the namesake the earlier one left behind"
        )
        XCTAssertEqual(
            ImportMIDI.verifyTarget(forTrackNamed: "IMPPROF-C1", in: twoStudioGrands)?.trackNumber,
            32
        )
    }

    /// A routed part is read on the track it was MOVED to, which is the entry
    /// the routing phase rewrote into the census.
    func testARoutedRegionIsVerifiedOnItsDestinationRow() {
        let landed = [
            ImportMIDI.RegionCensus.Entry(
                trackNumber: 2, trackName: "Bas", name: "Bass Line", startBar: 9)
        ]
        XCTAssertEqual(
            ImportMIDI.verifyTarget(forTrackNamed: "bass line", in: landed),
            ImportMIDI.VerifyTarget(
                regionName: "Bass Line", trackName: "Bas", trackNumber: 2, startBar: 9),
            "matched case-insensitively, the way every other name in this tool is"
        )
    }

    func testAWrittenTrackWithNoLandedRegionHasNoTargetRatherThanTheWrongOne() {
        XCTAssertNil(ImportMIDI.verifyTarget(forTrackNamed: "IMPPROF-X", in: twoStudioGrands))
    }

    // MARK: The verdict: unverified is not mismatched

    func testEverythingReadAndMatchingIsVerifiedWithNoWarning() {
        let verdict = ImportMIDI.noteVerdict([.matched, .matched])
        XCTAssertTrue(verdict.verified)
        XCTAssertNil(verdict.warning)
    }

    /// The measured lie: three attempts failed to READ the region and the tool
    /// warned that the notes "do not all match". Notes nobody read are
    /// UNVERIFIED, and the warning has to say so.
    func testNotesThatWereNeverReadAreUnverifiedAndNotAMismatch() {
        let verdict = ImportMIDI.noteVerdict([.matched, .unverified])
        XCTAssertFalse(verdict.verified, "an unread region is not a verified one either")
        let warning = verdict.warning ?? ""
        XCTAssertTrue(warning.contains("UNVERIFIED"), warning)
        XCTAssertFalse(warning.contains("do not match"), warning)
    }

    func testNotesThatWereReadAndDifferAreReportedAsAMismatch() {
        let warning = ImportMIDI.noteVerdict([.mismatched]).warning ?? ""
        XCTAssertTrue(warning.contains("do not match"), warning)
        XCTAssertFalse(warning.contains("UNVERIFIED"), warning)
    }

    /// Both kinds in one call get both sentences, with their own counts —
    /// they ask the caller to do different things.
    func testAMixedPassSaysBothThingsSeparately() {
        let warning = ImportMIDI.noteVerdict([.mismatched, .unverified, .matched]).warning ?? ""
        XCTAssertTrue(warning.contains("1 of them do not match"), warning)
        XCTAssertTrue(warning.contains("1 region(s) could not be READ BACK"), warning)
    }

    // MARK: - Proving a dialog is gone

    /// Only an INVALID element is a closed one. `cannotComplete` is Logic busy
    /// instantiating the instruments the import just made — reading that as
    /// "the panel closed" would report a modal still on screen as dismissed.
    func testOnlyAnInvalidElementCountsAsGone() {
        XCTAssertTrue(ImportMIDI.elementIsGone(.invalidUIElement))
        for status: AXError in [.success, .cannotComplete, .notImplemented, .attributeUnsupported,
                                .noValue, .apiDisabled] {
            XCTAssertFalse(ImportMIDI.elementIsGone(status), "\(status.rawValue)")
        }
    }

    /// The cheap probe answers and the expensive tree search is never paid.
    func testTheRetainedElementProbeShortCircuitsTheSearch() {
        var searches = 0
        XCTAssertTrue(waitForDisappearance(
            timeout: 5, patience: 0,
            probe: { true }, confirm: { searches += 1; return true }
        ))
        XCTAssertEqual(searches, 0, "a dead element needs no walk of the tree to prove it")
    }

    /// A panel AppKit closed but KEPT — its element stays valid, so the probe
    /// never fires and the search has to be the one that decides.
    func testTheSearchStillDecidesWhenTheElementStaysValid() {
        var searches = 0
        XCTAssertTrue(waitForDisappearance(
            timeout: 5, patience: 0,
            probe: { false }, confirm: { searches += 1; return true }
        ))
        XCTAssertEqual(searches, 1)
    }

    /// And it gets the LAST word: a dialog that is genuinely still standing is
    /// searched for once more before this reports failure.
    func testTheSearchIsAskedOnceMoreBeforeReportingADialogStillStanding() {
        var searches = 0
        XCTAssertFalse(waitForDisappearance(
            timeout: 0, patience: 60,
            probe: { false }, confirm: { searches += 1; return false }
        ))
        XCTAssertEqual(searches, 1, "even with the slow clock nowhere near due")
    }
}
