import Foundation
import XCTest
@testable import Logician

/// The pure half of the control-surface plug-in browser: reading one catalog
/// entry off a shared LCD row, and the map that lets the next browse jump
/// straight to it instead of walking there.
///
/// All of this is expensive to get wrong in the same specific way. A browse is
/// uncommitted until the vpot press, so a mis-planned jump only costs steps —
/// but a mis-READ entry name is what the press is gated on, and a map that
/// answered "first match" with the wrong occurrence would quietly change which
/// plug-in this tool instantiates.
final class PluginCatalogTests: XCTestCase {

    // MARK: - Normalising a captured entry

    func testNormalisationTakesTheNeighbouringEmptySlotBackOff() {
        // The exact capture that used to defeat the wrap test: a name long
        // enough to leave only a two-space gap before the next cell's "--".
        XCTAssertEqual(
            MCUController.normalizedBrowseEntry("Parametric EQ (s/s)  --"),
            "Parametric EQ (s/s)"
        )
    }

    func testNormalisationTakesSeveralNeighboursBackOff() {
        XCTAssertEqual(
            MCUController.normalizedBrowseEntry("Gain (s/s)  --  --   -- "),
            "Gain (s/s)"
        )
    }

    func testNormalisationLeavesACleanEntryAlone() {
        XCTAssertEqual(
            MCUController.normalizedBrowseEntry("  SilverVerb (s/s)  "),
            "SilverVerb (s/s)"
        )
    }

    func testNormalisationKeepsABareNoPluginMarker() {
        // "--" IS an entry — the boundary removePluginViaBrowser browses to.
        // Normalising it away would break every removal.
        XCTAssertEqual(MCUController.normalizedBrowseEntry("--"), "--")
        XCTAssertEqual(MCUController.normalizedBrowseEntry("   --   "), "--")
    }

    func testNormalisationMakesTheSameEntryCompareEqualEitherWayRound() {
        // The wrap test asks "has the FIRST entry come back?", so the two
        // captures of one entry have to normalise to the same string. This is
        // the whole defect: they did not.
        XCTAssertEqual(
            MCUController.normalizedBrowseEntry("Parametric EQ (s/s)  --"),
            MCUController.normalizedBrowseEntry("Parametric EQ (s/s)")
        )
    }

    // MARK: - Names, formats and the match that gates the press

    func testEntryNameDropsTheChannelFormatAnnotation() {
        XCTAssertEqual(MCUController.browseEntryName("Compressor (s/s)"), "Compressor")
        XCTAssertEqual(MCUController.browseEntryName("Compressor (m/m)"), "Compressor")
        XCTAssertEqual(MCUController.browseEntryName("Compressor"), "Compressor")
    }

    func testEntryFormatIsReadWhenThereIsOne() {
        XCTAssertEqual(MCUController.browseEntryFormat("Compressor (s/s)"), "(s/s)")
        XCTAssertEqual(MCUController.browseEntryFormat("Compressor (m/s)"), "(m/s)")
        XCTAssertNil(MCUController.browseEntryFormat("--"))
        XCTAssertNil(MCUController.browseEntryFormat("Compressor"))
    }

    func testMatchAcceptsTheContaminatedCaptureToo() {
        // Whatever else changes, the press must still be gated correctly on a
        // row that has a neighbour's marker in it.
        XCTAssertTrue(
            MCUController.browseEntryMatches("Parametric EQ (s/s)  --", requested: "Parametric EQ")
        )
        XCTAssertTrue(MCUController.browseEntryMatches("Gain (s/s)", requested: "gain"))
    }

    func testMatchToleratesTruncationFromEitherSide() {
        // A high insert slot leaves fewer LCD cells, so a long name arrives cut.
        XCTAssertTrue(
            MCUController.browseEntryMatches(
                "EVOC 20 TrackOscilla", requested: "EVOC 20 TrackOscillator"
            )
        )
        XCTAssertTrue(MCUController.browseEntryMatches("Compressor (s/s)", requested: "Comp"))
    }

    func testMatchRejectsAnUnrelatedEntryAndAnEmptyOne() {
        XCTAssertFalse(MCUController.browseEntryMatches("Chorus (s/s)", requested: "Gain"))
        XCTAssertFalse(MCUController.browseEntryMatches("", requested: "Gain"))
        XCTAssertFalse(MCUController.browseEntryMatches("   ", requested: "Gain"))
    }

    // MARK: - Planning the jump

    func testJumpPlanFitsASmallJumpInOneMessage() {
        XCTAssertEqual(MCUController.browseJumpPlan(ticks: 20), [20])
        XCTAssertEqual(MCUController.browseJumpPlan(ticks: 62), [62])
    }

    func testJumpPlanSplitsAtTheMessageLimitAndSumsBackExactly() {
        // Gain sits at entry 38, which is 76 ticks: one full message and a
        // remainder. The sum is the contract — a plan that did not add up would
        // land the browse somewhere nobody asked for.
        let plan = MCUController.browseJumpPlan(ticks: 76)
        XCTAssertEqual(plan, [62, 14])
        XCTAssertEqual(plan.reduce(0, +), 76)
    }

    func testJumpPlanNeverExceedsWhatOneMessageCarries() {
        for ticks in [2, 63, 64, 124, 125, 400, 1201] {
            let plan = MCUController.browseJumpPlan(ticks: ticks)
            XCTAssertEqual(plan.reduce(0, +), ticks, "plan for \(ticks) must sum back")
            for chunk in plan {
                XCTAssertLessThanOrEqual(
                    abs(chunk), MCUController.browseJumpTicksPerMessage,
                    "a chunk above the limit would be clamped by turnVPot and lost"
                )
            }
        }
    }

    func testJumpPlanCarriesTheSignAndStaysReversible() {
        XCTAssertEqual(MCUController.browseJumpPlan(ticks: -76), [-62, -14])
        XCTAssertEqual(MCUController.browseJumpPlan(ticks: -76).reduce(0, +), -76)
        XCTAssertEqual(MCUController.browseJumpPlan(ticks: 0), [])
    }

    func testEveryJumpChunkLandsOnAnEntryBoundary() {
        // 62 rather than the 63 turnVPot allows, because the list advances one
        // entry per two ticks: an odd chunk would leave the browse between
        // entries and the next chunk would compound it.
        XCTAssertEqual(
            MCUController.browseJumpTicksPerMessage % MCUController.browseTicksPerEntry, 0
        )
        for ticks in [2, 76, 400] {
            for chunk in MCUController.browseJumpPlan(ticks: ticks) {
                XCTAssertEqual(abs(chunk) % MCUController.browseTicksPerEntry, 0)
            }
        }
    }

    // MARK: - The map

    private func sweepsCatalog() -> PluginCatalogMap {
        var map = PluginCatalogMap()
        map.merge(
            [
                .init(name: "Parametric EQ (s/s)", position: 1),
                .init(name: "Low Pass Filter (s/s)", position: 2),
                .init(name: "Compressor (s/s)", position: 15),
                .init(name: "Gain (s/s)", position: 38)
            ],
            coveredPositions: 38
        )
        return map
    }

    func testMapAnswersWithTheEntryTheWalkWouldHaveStoppedAt() {
        let map = sweepsCatalog()
        XCTAssertEqual(map.position(matching: "Gain", format: "(s/s)"), 38)
        XCTAssertEqual(map.position(matching: "Compressor", format: "(s/s)"), 15)
        XCTAssertEqual(map.position(matching: "Parametric EQ", format: nil), 1)
    }

    func testMapSaysNothingRatherThanGuessingAboutAnEntryItHasNotSeen() {
        XCTAssertNil(sweepsCatalog().position(matching: "Decapitator", format: "(s/s)"))
    }

    func testMapWillNotHandAMonoStripAStereoStripsCoordinate() {
        // Mono-only and stereo-only plug-ins drop in and out of the catalog,
        // which shifts every position after them, so a coordinate is only a
        // hint for the format it was counted on.
        XCTAssertNil(sweepsCatalog().position(matching: "Gain", format: "(m/m)"))
    }

    func testMapPrefersTheEarliestOccurrenceOfAName() {
        var map = PluginCatalogMap()
        map.merge([.init(name: "Fat EQ (s/s)", position: 31)], coveredPositions: 31)
        // A later run seeing the same name further along was looking at a
        // SECOND occurrence, not a moved one.
        map.merge([.init(name: "Fat EQ (s/s)", position: 120)], coveredPositions: 200)
        XCTAssertEqual(map.position(matching: "Fat EQ", format: "(s/s)"), 31)
        XCTAssertEqual(map.entries.filter { $0.name == "Fat EQ (s/s)" }.count, 1)
    }

    func testMapStaysSortedByPositionSoFirstMatchMeansFirstMatch() {
        var map = PluginCatalogMap()
        map.merge(
            [
                .init(name: "Gain (s/s)", position: 38),
                .init(name: "Chorus (s/s)", position: 6),
                .init(name: "Compressor (s/s)", position: 15)
            ],
            coveredPositions: 38
        )
        XCTAssertEqual(map.entries.map(\.position), [6, 15, 38])
    }

    func testMapCoverageOnlyGrows() {
        var map = sweepsCatalog()
        map.merge([.init(name: "Chorus (s/s)", position: 6)], coveredPositions: 6)
        XCTAssertEqual(
            map.coveredPositions, 38,
            "two contiguous prefixes union to the longer one; coverage must not shrink"
        )
    }

    func testMapIgnoresNonsenseObservations() {
        var map = PluginCatalogMap()
        map.merge(
            [
                .init(name: "", position: 4),
                .init(name: "Gain (s/s)", position: 0),
                .init(name: "Chorus (s/s)", position: 6)
            ],
            coveredPositions: 6
        )
        XCTAssertEqual(map.entries.map(\.name), ["Chorus (s/s)"])
    }

    // MARK: - Scoping the map to the install rather than the project

    func testInstallScopedCacheRoundTripsWithinTheSameScope() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        saveScopedCache(sweepsCatalog(), to: url, scope: "logic 12.3.1|plugins abc")
        XCTAssertEqual(
            loadScopedCache(url, scope: "logic 12.3.1|plugins abc", as: PluginCatalogMap.self),
            sweepsCatalog()
        )
    }

    func testInstallScopedCacheIsInvisibleAfterThePluginSetChanges() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        saveScopedCache(sweepsCatalog(), to: url, scope: "logic 12.3.1|plugins abc")
        XCTAssertNil(
            loadScopedCache(url, scope: "logic 12.3.1|plugins DIFFERENT", as: PluginCatalogMap.self)
        )
    }

    func testInstallScopedCacheIsRetiredOnMismatchWhenAskedTo() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        saveScopedCache(sweepsCatalog(), to: url, scope: "logic 12.3.1|plugins abc")
        XCTAssertNil(
            loadScopedCache(
                url, scope: "logic 12.4|plugins abc", as: PluginCatalogMap.self,
                deleteOnMismatch: true
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "a file stamped for another install can never become useful; it should not linger"
        )
    }

    func testInstallScopedCacheIsUnreadableAndUnwritableWithoutAScope() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        saveScopedCache(sweepsCatalog(), to: url, scope: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        saveScopedCache(sweepsCatalog(), to: url, scope: "logic 12.3.1|plugins abc")
        XCTAssertNil(loadScopedCache(url, scope: nil, as: PluginCatalogMap.self))
    }

    // MARK: - The bounds the browse promises

    func testTheSearchIsBoundedInEntriesRatherThanMessages() {
        // The old 500-MESSAGE cap saw only 269 entries at unpaced speed, on a
        // catalog longer than that: the browse could report "not shown" having
        // looked at half the list.
        XCTAssertGreaterThan(MCUController.browseEntryCap, 590)
        XCTAssertGreaterThanOrEqual(MCUController.browseSearchBudget, 15)
    }

    func testAJumpAimsStraightAtTheCachedOrdinal() {
        // An ordinal can only err downward, so undershooting buys nothing and
        // was measured to cost three extra steps.
        XCTAssertEqual(MCUController.browseJumpUndershootEntries, 0)
        XCTAssertGreaterThan(MCUController.browseJumpGraceSteps, 0)
    }

    // MARK: - Which view the surface is actually in
    //
    // Every string below is verbatim from the live surface, 2026-09-02.

    func testTheSlotLabelRowIsTheInsertList() {
        XCTAssertEqual(
            MCUController.pluginListView(
                assignment: "PL",
                lcdTop: "Ins1Pl Ins2Pl Ins3Pl Ins4Pl Ins5Pl Ins6Pl Ins7Pl Ins8Pl "
            ),
            .insertList
        )
    }

    /// The state that makes reading the row a lie: the assignment is still
    /// `PL`, but the bottom row is showing a CATALOG ENTRY for the slot being
    /// browsed, not that slot's contents.
    func testAStandingBrowseIsNotTheInsertList() {
        XCTAssertEqual(
            MCUController.pluginListView(
                assignment: "PL",
                lcdTop: "Insert 1 Plug-in     Ins4Pl Ins5Pl Ins6Pl Ins7Pl Ins8Pl "
            ),
            .browseStanding
        )
    }

    /// The measured trap: the per-insert bank paints the PAN NAMES row, so the
    /// top row alone cannot tell `P1` from the neutral `PN` view — which is
    /// what let a five-press loop give up one press short of the list.
    func testThePerInsertBankPaintsThePanNamesRowAndIsToldApartByItsCode() {
        let panNames = "DrSyKi Vocals IvnVoc IvnVoc IvanFx AckVoc Sweeps Crash  "
        XCTAssertEqual(
            MCUController.pluginListView(assignment: "P1", lcdTop: panNames), .perInsertBank
        )
        XCTAssertEqual(
            MCUController.pluginListView(assignment: "PN", lcdTop: panNames), .elsewhere
        )
        XCTAssertEqual(
            MCUController.pluginListView(assignment: "IN", lcdTop: panNames), .perInsertBank
        )
    }

    func testTheInsertRowWinsEvenWithNoAssignmentToReadIt() {
        XCTAssertEqual(
            MCUController.pluginListView(assignment: nil, lcdTop: "Ins1Pl Ins2Pl "),
            .insertList
        )
        XCTAssertEqual(MCUController.pluginListView(assignment: nil, lcdTop: nil), .elsewhere)
    }

    // MARK: - What a search that found nothing says

    /// The refusal that sent one session hunting a spelling mistake: the same
    /// `Parametric EQ` that is entry 1 on a stereo strip was not in the first
    /// 226 entries of a mono strip's catalog, and the message named neither
    /// the catalog nor a single entry it had seen.
    func testTheSearchRefusalNamesTheCatalogItWalkedAndWhatWasInIt() {
        let text = MCUController.browseSearchRefusal(
            pluginName: "Parametric EQ",
            slot: 1,
            entriesSeen: 226,
            opening: ["Low Pass Filter (m/m)", "Chorus (m/m)"],
            tail: ["Tape Delay (m/m)", "Tremolo (m/m)"],
            format: "(m/m)",
            stoppedOnCap: false
        )
        XCTAssertTrue(text.contains("226 catalog entries"))
        XCTAssertTrue(text.contains("(the search budget)"))
        XCTAssertTrue(text.contains("Low Pass Filter (m/m)"))
        XCTAssertTrue(text.contains("Tremolo (m/m)"))
        XCTAssertTrue(text.contains("browses the (m/m) catalog"))
        XCTAssertTrue(text.contains("Nothing was written"))
    }

    func testTheSearchRefusalSaysWhichBoundStoppedItAndCountsInSingularToo() {
        let capped = MCUController.browseSearchRefusal(
            pluginName: "Gain", slot: 3, entriesSeen: MCUController.browseEntryCap,
            opening: ["Parametric EQ (s/s)"], tail: ["Parametric EQ (s/s)"],
            format: "(s/s)", stoppedOnCap: true
        )
        XCTAssertTrue(capped.contains("\(MCUController.browseEntryCap)-entry limit"))
        XCTAssertFalse(capped.contains("search budget"))
        let one = MCUController.browseSearchRefusal(
            pluginName: "Gain", slot: 3, entriesSeen: 1, opening: ["Parametric EQ (s/s)"],
            tail: ["Parametric EQ (s/s)"], format: nil, stoppedOnCap: false
        )
        XCTAssertTrue(one.contains("1 catalog entry it looked at"))
        // No annotation seen means no catalog claim can be made — say the one
        // thing that is still true instead of inventing a format.
        XCTAssertFalse(one.contains("catalog, and a MONO"))
        XCTAssertTrue(one.contains("Check the spelling"))
    }

    /// A browse that did not open on the No Plug-in entry is counted from the
    /// wrong zero, and the refusal has to say so — and say that repeating the
    /// call is safe, because the abandoned browse wrote nothing.
    func testTheOriginRefusalNamesTheSlotAndWhatItFoundThere() {
        let text = MCUController.browseOriginRefusal(slot: 2, showing: "Chorus (m/m)")
        XCTAssertTrue(text.contains("slot 2"))
        XCTAssertTrue(text.contains("Chorus (m/m)"))
        XCTAssertTrue(text.contains("safe to repeat"))
        XCTAssertTrue(text.contains("Nothing was written"))
    }

    // MARK: - Logic's answer to the SELECT press, in the browse field

    /// Measured live 2026-09-03: the SELECT press before a browse paints the
    /// strip's full name across the three cells the browse field spans, and it
    /// stays there until the browse itself repaints the row. Counting it as
    /// catalog entry 1 is what put `Gain`, `LoPass ParEQ` and
    /// `Cha EQ Cha EQ Cha EQ Cha EQ` at position 1 of the catalog cache.
    func testTheStripsOwnNameInTheBrowseFieldIsTheSelectBannerNotAnEntry() {
        XCTAssertTrue(
            MCUController.browseCellIsStripBanner("Drum Synth Kit", trackName: "Drum Synth Kit")
        )
        XCTAssertTrue(
            MCUController.browseCellIsStripBanner("  Sweeps ", trackName: "Sweeps"),
            "the cell is read out of a padded LCD row"
        )
        // Truncated by the field's width, and still the name.
        XCTAssertTrue(
            MCUController.browseCellIsStripBanner("Drum Synth K", trackName: "Drum Synth Kit")
        )
    }

    func testACatalogEntryIsNeverMistakenForTheBanner() {
        XCTAssertFalse(
            MCUController.browseCellIsStripBanner("Parametric EQ (s/s)", trackName: "Sweeps")
        )
        XCTAssertFalse(MCUController.browseCellIsStripBanner("--", trackName: "Sweeps"))
        XCTAssertFalse(MCUController.browseCellIsStripBanner("", trackName: "Sweeps"))
        // A short head of the name is not enough: a real entry could open with
        // the same few letters, and skipping it would lose an ordinal.
        XCTAssertFalse(
            MCUController.browseCellIsStripBanner("Drum", trackName: "Drum Synth Kit")
        )
    }

    // MARK: - Why the MCU route bowed out

    func testTheBrowserUnavailabilityDetailPrefersTheBrowsersOwnRecord() {
        MCUController.lastBrowserRefusal = nil
        MCUController.lastPluginListRefusal = nil
        XCTAssertTrue(MCUController.browserUnavailabilityDetail.contains("did not answer"))
        MCUController.lastPluginListRefusal = "five presses did not bring the insert list up"
        XCTAssertEqual(
            MCUController.browserUnavailabilityDetail,
            "five presses did not bring the insert list up"
        )
        MCUController.lastBrowserRefusal = "the strip could not be resolved on the surface"
        XCTAssertEqual(
            MCUController.browserUnavailabilityDetail,
            "the strip could not be resolved on the surface"
        )
        MCUController.lastBrowserRefusal = nil
        MCUController.lastPluginListRefusal = nil
    }
}
