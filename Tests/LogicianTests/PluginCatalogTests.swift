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
}
