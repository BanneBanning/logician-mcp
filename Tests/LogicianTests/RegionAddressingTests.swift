import XCTest

@testable import Logician

/// Which ROW a region call lands on, and what a refusal about a region says.
///
/// Two defects, one family. The region tools took no `track_number` at all and
/// resolved `track_name` with "the first row called that" — on a project where
/// `logic_import_midi` had left three rows called `Studio Grand`, the delete an
/// agent aimed at the third one landed on the first, silently. And when a
/// region could not be picked out on the row it did find, the refusal it raised
/// was `parameterAmbiguous`, whose message opens "Accessible plugin parameter
/// is ambiguous" — a sentence about a plug-in, printed at an agent that had
/// asked about a region.
final class RegionAddressingTests: XCTestCase {

    /// The project shape the whole fix is about: four rendered rows, three of
    /// them sharing one name.
    private let imported = [
        TrackRowAddressing.Row(number: 1, name: "Crash"),
        TrackRowAddressing.Row(number: 24, name: "Studio Grand"),
        TrackRowAddressing.Row(number: 25, name: "Studio Grand"),
        TrackRowAddressing.Row(number: 26, name: "Studio Grand")
    ]

    // MARK: - The number/name cross-check

    /// The pair that agrees resolves to the row the NUMBER names — which is
    /// the point of passing it: row 26 rather than whichever `Studio Grand`
    /// Logic rendered first.
    func testANumberAndNameThatAgreeResolveToThatRow() {
        XCTAssertEqual(
            TrackRowAddressing.resolve(
                rows: imported, name: "Studio Grand", number: 26, caseInsensitive: true
            ),
            .resolved(number: 26)
        )
    }

    /// The pair that DISAGREES is the reason the argument is cross-checked
    /// rather than trusted: a row number read before an edit that renumbered
    /// the arrangement is exactly the stale handle this catches, and the
    /// verdict names both halves so the refusal can say which is which.
    func testANumberAndNameThatDisagreeRefuseAndNameBoth() {
        XCTAssertEqual(
            TrackRowAddressing.resolve(
                rows: imported, name: "Crash", number: 26, caseInsensitive: true
            ),
            .mismatch(number: 26, expected: "Crash", actual: "Studio Grand")
        )
    }

    /// A number no rendered row carries is its own verdict: "there is no row
    /// 99" sends the caller somewhere different from "row 99 is called
    /// something else".
    func testANumberNoRowCarriesIsNotFoundRatherThanAMismatch() {
        XCTAssertEqual(
            TrackRowAddressing.resolve(
                rows: imported, name: "Studio Grand", number: 99, caseInsensitive: true
            ),
            .numberNotFound(99)
        )
    }

    /// Name-only addressing on a duplicated name is AMBIGUOUS, where it used
    /// to be answered by the first match. The numbers come back with it,
    /// because they are the way out.
    func testADuplicatedNameWithNoNumberIsAmbiguousWithTheRowsListed() {
        XCTAssertEqual(
            TrackRowAddressing.resolve(
                rows: imported, name: "Studio Grand", number: nil, caseInsensitive: true
            ),
            .ambiguous(numbers: [24, 25, 26])
        )
    }

    /// A unique name still needs no number — the ordinary call is unchanged.
    func testAUniqueNameStillResolvesWithoutANumber() {
        XCTAssertEqual(
            TrackRowAddressing.resolve(
                rows: imported, name: "crash", number: nil, caseInsensitive: true
            ),
            .resolved(number: 1)
        )
    }

    /// The two planes compare names differently and keep doing so: the region
    /// walk takes the name out of Logic's own description sentence and has
    /// always matched case-insensitively; the track-header path has always
    /// matched exactly. Sharing the rule changed neither.
    func testTheCaseSensitivityOfEachPlaneIsPreserved() {
        XCTAssertEqual(
            TrackRowAddressing.resolve(
                rows: imported, name: "crash", number: nil, caseInsensitive: false
            ),
            .nameNotFound
        )
        XCTAssertEqual(
            TrackRowAddressing.resolve(
                rows: imported, name: "crash", number: 1, caseInsensitive: false
            ),
            .mismatch(number: 1, expected: "crash", actual: "Crash")
        )
    }

    /// The rows a refusal prints are NUMBERED: a caller who addressed a row by
    /// number needs the numbers back, not a list of names three of which are
    /// identical.
    func testTheRowSummaryCarriesTheNumbers() {
        XCTAssertEqual(
            TrackRowAddressing.rowSummary(imported),
            "1: Crash, 24: Studio Grand, 25: Studio Grand, 26: Studio Grand"
        )
        XCTAssertEqual(TrackRowAddressing.rowSummary([]), "none rendered")
    }

    // MARK: - What the refusal SAYS

    /// The wording defect itself: a region ambiguity now reads as one, and
    /// carries the two arguments that resolve it.
    func testARegionAmbiguityNamesTheRegionsAndBothWaysOut() {
        let error = LogicianError.regionAmbiguous(
            track: "Crash",
            requested: RegionAddressing.request(regionName: "Crash", startBar: nil),
            candidates: RegionAddressing.candidates([
                ["name": "Crash", "start_bar": 1],
                ["name": "Crash", "start_bar": 33]
            ])
        )
        let message = error.errorDescription ?? ""
        XCTAssertEqual(error.code, "ambiguous")
        XCTAssertTrue(message.contains("Region 'Crash' on track 'Crash' matches 2 regions"), message)
        XCTAssertTrue(message.contains("'Crash' at bar 1, 'Crash' at bar 33"), message)
        XCTAssertTrue(message.contains("start_bar"), message)
        XCTAssertTrue(message.contains("track_number"), message)
        // The sentence it replaced, and the one it must not have borrowed.
        XCTAssertFalse(message.contains("plugin parameter"), message)
    }

    /// And the message it used to borrow is untouched: `parameterAmbiguous`
    /// still says what it always said, for the plug-in parameters that are
    /// genuinely ambiguous.
    func testThePluginParameterAmbiguityIsUnchanged() {
        XCTAssertEqual(
            LogicianError.parameterAmbiguous("Threshold", 3).errorDescription,
            "Accessible plugin parameter is ambiguous: Threshold matched 3 controls."
        )
    }

    /// A refusal repeats the REQUEST back, so an agent can see which of its
    /// arguments were actually used to pick — including the call that named no
    /// region at all on a track holding several.
    func testTheRequestPhraseNamesWhatWasAsked() {
        XCTAssertEqual(
            RegionAddressing.request(regionName: "Crash", startBar: 41),
            "region 'Crash' at bar 41"
        )
        XCTAssertEqual(RegionAddressing.request(regionName: "Crash", startBar: nil), "region 'Crash'")
        XCTAssertEqual(RegionAddressing.request(regionName: nil, startBar: 41), "the region at bar 41")
        XCTAssertEqual(
            RegionAddressing.request(regionName: nil, startBar: nil),
            "a region (neither region_name nor start_bar was given)"
        )
    }

    /// A candidate list is Logic's own name and bar per region, and a region
    /// whose cells could not be parsed still gets a slot rather than
    /// disappearing from the list of what is on the row.
    func testCandidatesArePrintedWithTheirBars() {
        XCTAssertEqual(
            RegionAddressing.candidates([
                ["name": "Crash", "start_bar": 1],
                ["start_bar": 9],
                ["name": "Crash#2"]
            ]),
            ["'Crash' at bar 1", "'?' at bar 9", "'Crash#2' at bar ?"]
        )
    }
}

/// The addressing argument as the SCHEMA advertises it, and the refusal that
/// keeps it honest.
final class RegionTrackNumberSchemaTests: XCTestCase {

    /// Every tool that resolves a track row to reach a region takes
    /// `track_number`. `logic_delete_region` is the one the defect was
    /// reported against — it refused the argument outright while
    /// `logic_delete_track` accepted it — and the rest are here so the family
    /// cannot drift apart again.
    func testEveryRegionToolAdvertisesTrackNumber() {
        let server = MCPServer()
        let regionTools = [
            "logic_select_regions", "logic_delete_region",
            "logic_move_region", "logic_split_region", "logic_copy_region",
            "logic_rename_region", "logic_get_region_params", "logic_set_region_params",
            "logic_remove_silence", "logic_list_events", "logic_edit_event",
            "logic_bounce_in_place"
        ]
        let registry = server.toolRegistry()
        for name in regionTools {
            guard let tool = registry.first(where: { $0.name == name }) else {
                XCTFail("\(name) is not in the registry")
                continue
            }
            let properties = tool.inputSchema["properties"] as? [String: Any]
            XCTAssertNotNil(
                properties?["track_number"],
                "\(name) resolves a track by name and must accept track_number"
            )
        }
        // The destination row of a copy needs the same handle as the source.
        let copy = registry.first { $0.name == "logic_copy_region" }
        let copyProperties = copy?.inputSchema["properties"] as? [String: Any]
        XCTAssertNotNil(copyProperties?["to_track_number"])
    }

    /// `track_number` is only worth anything because it is CHECKED against
    /// `track_name`; alone it would have to be trusted. The tools whose
    /// `track_name` is optional therefore refuse the pairing instead of
    /// ignoring a number they cannot use.
    func testATrackNumberWithoutATrackNameIsRefused() {
        let server = MCPServer()
        XCTAssertThrowsError(try server.regionTrackNumber(in: ["track_number": 26])) { error in
            XCTAssertEqual((error as? LogicianError)?.code, "invalid_arguments")
            XCTAssertTrue(
                (error.localizedDescription).contains("track_name"),
                error.localizedDescription
            )
        }
        XCTAssertEqual(
            try server.regionTrackNumber(in: ["track_number": 26, "track_name": "Crash"]), 26
        )
        XCTAssertNil(try server.regionTrackNumber(in: ["track_name": "Crash"]))
    }

    /// The same refusal on the one region tool that parses its arguments
    /// before it touches Logic: `logic_edit_event` validates everything in a
    /// pure request type precisely so a bad call cannot change the selection
    /// on its way to saying no.
    func testTheEventEditRequestCarriesTheRowNumber() throws {
        let request = try EventEditRequest(arguments: [
            "action": "set", "bar": 9, "pitch": "C3",
            "track_name": "Studio Grand", "track_number": 26
        ])
        XCTAssertEqual(request.trackNumber, 26)
        XCTAssertEqual(request.trackName, "Studio Grand")
        // And refuses the lone number here too, before it can reach the
        // selection: measured live 2026-09-02, a `logic_list_events
        // {track_number: 26}` whose guard sat INSIDE the "did they pass a
        // track_name?" branch read the region that happened to be showing
        // (`808 Mutation Bass`, on row 3) and reported it as an answer.
        XCTAssertThrowsError(
            try EventEditRequest(arguments: ["action": "set", "bar": 9, "track_number": 26])
        ) { error in
            XCTAssertEqual((error as? LogicianError)?.code, "invalid_arguments")
        }
    }

    /// A rename writes a region's NAME, so it must not carry the standing
    /// instruction to bounce a range and listen across the seam for a
    /// displaced groove: 457 B of an 890 B response (51%), attached to the
    /// `already_set` no-op too, sending the agent after a snare a metadata
    /// write cannot move. The tools that CAN displace one keep it.
    func testARenameCarriesNoBounceAndListenInstruction() throws {
        let registry = MCPServer().toolRegistry()
        let rename = try XCTUnwrap(registry.first { $0.name == "logic_rename_region" })
        XCTAssertFalse(rename.changesArrangement)
        XCTAssertFalse(rename.changesSound)
        XCTAssertNil(rename.listenNoteText)
        // Still a write, still idempotent, and the Undo sentence stays in the
        // description: nothing about the classification changes what it does.
        XCTAssertEqual(rename.safety, .write)
        XCTAssertTrue(rename.idempotent)
        XCTAssertTrue(rename.description.contains("Undo restores the old name"))
        for name in [
            "logic_copy_region", "logic_move_region", "logic_split_region", "logic_import_midi"
        ] {
            let tool = try XCTUnwrap(registry.first { $0.name == name })
            XCTAssertTrue(
                tool.changesArrangement, "\(name) can displace a groove and must keep the note"
            )
        }
    }

    /// The description is the tool's contract, and it used to promise a
    /// verification the code did not perform ("verified TWICE" while the
    /// inspector readback was taken and thrown away).
    func testTheRenameDescriptionPromisesOnlyWhatTheCodeChecks() throws {
        let rename = try XCTUnwrap(
            MCPServer().toolRegistry().first { $0.name == "logic_rename_region" }
        )
        XCTAssertFalse(rename.description.contains("verified TWICE"))
        XCTAssertTrue(rename.description.contains("BOTH channels"))
        XCTAssertTrue(rename.description.contains("case included"))
        // And it warns about the names Logic keeps for itself, which the tool
        // now refuses before it writes.
        XCTAssertTrue(rename.description.contains("2 selected"))
    }
}
