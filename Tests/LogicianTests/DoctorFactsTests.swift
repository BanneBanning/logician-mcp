import LogicMCUBridge
import XCTest

@testable import Logician

/// The doctor's judgements, pinned against port lists and clock readings this
/// Mac cannot be asked to produce. An orphaned twin port is the single most
/// confusing failure in this system and it is also the one state that cannot
/// be arranged on demand — so it is arranged here.
final class DoctorFactsTests: XCTestCase {

    // MARK: - Options

    func testDefaultsAreRedactedAndUnbundled() {
        guard case .success(let options) = DoctorFacts.parseOptions([]) else {
            return XCTFail("bare invocation must parse")
        }
        XCTAssertTrue(options.redact, "redaction must be the DEFAULT, not an opt-in")
        XCTAssertFalse(options.bundle)
        XCTAssertFalse(options.help)
    }

    func testFlagsParse() {
        guard case .success(let options) = DoctorFacts.parseOptions(["--no-redact", "--bundle"])
        else { return XCTFail("flags must parse") }
        XCTAssertFalse(options.redact)
        XCTAssertTrue(options.bundle)
    }

    /// `--redact` after `--no-redact` turns it back on: last wins, so a script
    /// can append the safe flag.
    func testExplicitRedactWinsWhenItComesLast() {
        guard case .success(let options) = DoctorFacts.parseOptions(["--no-redact", "--redact"])
        else { return XCTFail("flags must parse") }
        XCTAssertTrue(options.redact)
    }

    /// A typo answers with the flags, not a stack trace — and it names the
    /// option it did not understand.
    func testUnknownOptionIsRefusedByName() {
        guard case .failure(let error) = DoctorFacts.parseOptions(["--redcat"]) else {
            return XCTFail("an unknown option must be refused")
        }
        XCTAssertTrue(error.message.contains("--redcat"))
        XCTAssertTrue(error.message.contains("--no-redact"))
    }

    func testHelpIsAFlag() {
        guard case .success(let options) = DoctorFacts.parseOptions(["--help"]) else {
            return XCTFail("--help must parse")
        }
        XCTAssertTrue(options.help)
    }

    /// The usage text names every flag it accepts and the exit-code contract,
    /// because that contract is what a support reply is written against.
    func testUsageNamesEveryFlagAndTheExitCode() {
        for flag in ["--no-redact", "--bundle", "--help"] {
            XCTAssertTrue(DoctorFacts.usage.contains(flag), "usage does not mention \(flag)")
        }
        XCTAssertTrue(DoctorFacts.usage.contains("Exits 0"))
    }

    // MARK: - Architecture

    func testNativeArchitectureIsNotAWarning() {
        let line = DoctorFacts.architectureLine(
            binary: "arm64", translated: false, hardwareIsAppleSilicon: true
        )
        XCTAssertEqual(line.status, .ok)
        XCTAssertTrue(line.value.contains("Apple Silicon"))
        XCTAssertTrue(line.value.contains("native"))
    }

    func testIntelIsNamedAsIntelAndIsNotAWarning() {
        let line = DoctorFacts.architectureLine(
            binary: "x86_64", translated: false, hardwareIsAppleSilicon: false
        )
        XCTAssertEqual(line.status, .ok)
        XCTAssertTrue(line.value.contains("Intel"))
    }

    /// Rosetta is a NOTE. It works; it is merely slow and untested, and
    /// telling a user whose setup works that they have a problem is how a
    /// doctor loses their trust. The remedy still travels with the line.
    func testRosettaIsANoteThatNamesTheRebuild() {
        let line = DoctorFacts.architectureLine(
            binary: "x86_64", translated: true, hardwareIsAppleSilicon: true
        )
        XCTAssertEqual(line.status, .note)
        XCTAssertTrue(line.value.contains("ROSETTA"))
        XCTAssertTrue(line.value.contains("swift build -c release"))
    }

    // MARK: - Durations

    func testDurationsReadAsHumansReadThem() {
        XCTAssertEqual(DoctorFacts.humanDuration(seconds: 0.42), "420 ms")
        XCTAssertEqual(DoctorFacts.humanDuration(seconds: 12), "12 s")
        XCTAssertEqual(DoctorFacts.humanDuration(seconds: 600), "10 min")
        XCTAssertEqual(DoctorFacts.humanDuration(seconds: 7200), "2.0 h")
        XCTAssertEqual(DoctorFacts.humanDuration(seconds: 3600 * 72), "3.0 days")
    }

    /// A clock that went backwards, or a NaN out of a malformed state file,
    /// says "unknown" rather than printing nonsense with a unit on it.
    func testNonsenseDurationsSayUnknown() {
        XCTAssertEqual(DoctorFacts.humanDuration(seconds: -1), "unknown")
        XCTAssertEqual(DoctorFacts.humanDuration(seconds: .nan), "unknown")
    }

    // MARK: - The surface mirror

    /// Never any traffic is the SETUP fault, and it gets the Mackie Control
    /// instructions rather than a number.
    func testNeverAnyTrafficIsAProblemThatNamesTheMackieControl() {
        let line = DoctorFacts.mirrorLine(lastReceiveAge: nil, receivedEvents: 0)
        XCTAssertEqual(line.status, .problem)
        XCTAssertTrue(line.value.contains("Mackie Control"))
        XCTAssertTrue(line.value.contains("Logic MCP MCU"))
    }

    func testFreshMirrorIsFine() {
        let line = DoctorFacts.mirrorLine(lastReceiveAge: 3, receivedEvents: 4_812)
        XCTAssertEqual(line.status, .ok)
        XCTAssertTrue(line.value.contains("4812 events"))
    }

    /// An idle Logic is not a broken Logic. Past the server's own staleness
    /// ceiling it is a note that explains the wake probe, not a fault.
    func testIdleMirrorIsANoteNotAFault() {
        let line = DoctorFacts.mirrorLine(
            lastReceiveAge: MCUController.staleMirrorSeconds + 60, receivedEvents: 900
        )
        XCTAssertEqual(line.status, .note)
        XCTAssertTrue(line.value.contains("idle Logic"))
    }

    // MARK: - MIDI ports

    private func healthyCensus() -> [MIDIEndpointInfo] {
        expectedBridgeEndpoints + [
            MIDIEndpointInfo(name: "IAC Driver Bus 1", uniqueID: 55, isSource: true),
            MIDIEndpointInfo(name: "IAC Driver Bus 1", uniqueID: 56, isSource: false)
        ]
    }

    func testAHealthyPortListHasEverythingAndNoOrphans() {
        let verdict = DoctorFacts.classifyPorts(healthyCensus())
        XCTAssertEqual(verdict.present.count, expectedBridgeEndpoints.count)
        XCTAssertTrue(verdict.missing.isEmpty)
        XCTAssertTrue(verdict.orphans.isEmpty)
        XCTAssertEqual(verdict.sourceCount, 4)
        XCTAssertEqual(verdict.destinationCount, 2)
        XCTAssertEqual(verdict.otherNames.count, 2)
        let lines = DoctorFacts.portLines(verdict, bridgeRunning: true)
        XCTAssertTrue(lines.allSatisfy { $0.status == .ok })
    }

    /// The orphan: an endpoint with our NAME and an identity we never
    /// claimed. Everything looks connected while key commands fire into a
    /// dead port, so the fix has to include the relearn.
    func testAnOrphanedTwinIsAProblemAndNamesTheRelearn() {
        let census = healthyCensus() + [
            MIDIEndpointInfo(name: "Logic MCP Commands", uniqueID: 1_998_877, isSource: true)
        ]
        let verdict = DoctorFacts.classifyPorts(census)
        XCTAssertEqual(verdict.orphans.count, 1)
        XCTAssertEqual(verdict.duplicates, ["Logic MCP Commands"])
        let lines = DoctorFacts.portLines(verdict, bridgeRunning: true)
        let orphanLine = lines.first { $0.label == "stale twin ports" }
        XCTAssertEqual(orphanLine?.status, .problem)
        XCTAssertTrue(orphanLine?.value.contains("killall MIDIServer") == true)
        XCTAssertTrue(orphanLine?.value.contains("relearn: true") == true)
    }

    /// Missing ports with the daemon DOWN and missing ports with the daemon
    /// UP are different faults with different fixes, and the doctor must not
    /// give the same sentence for both.
    func testMissingPortsGetADifferentFixDependingOnTheDaemon() {
        let verdict = DoctorFacts.classifyPorts([])
        XCTAssertEqual(verdict.missing.count, expectedBridgeEndpoints.count)
        let down = DoctorFacts.portLines(verdict, bridgeRunning: false)[0]
        let up = DoctorFacts.portLines(verdict, bridgeRunning: true)[0]
        XCTAssertEqual(down.status, .problem)
        XCTAssertEqual(up.status, .problem)
        XCTAssertTrue(down.value.contains("logic_health"))
        XCTAssertTrue(up.value.contains("killall MIDIServer"))
        XCTAssertNotEqual(down.value, up.value)
    }

    /// The count of everything else is what makes a conflicting hardware desk
    /// visible without printing the user's device names by default.
    func testTheAllPortsLineCountsOtherDevicesWithoutNamingThem() {
        let verdict = DoctorFacts.classifyPorts(healthyCensus())
        let line = DoctorFacts.portLines(verdict, bridgeRunning: true).last
        XCTAssertEqual(line?.label, "all MIDI ports")
        XCTAssertTrue(line?.value.contains("4 inputs, 2 outputs") == true)
        XCTAssertTrue(line?.value.contains("--no-redact") == true)
        XCTAssertFalse(line?.value.contains("IAC Driver") == true)
        // …and it stops advertising the flag to a reader who already used it.
        let listed = DoctorFacts.portLines(verdict, bridgeRunning: true, namesListed: true).last
        XCTAssertFalse(listed?.value.contains("--no-redact") == true)
        XCTAssertTrue(listed?.value.contains("2 belong to other devices") == true)
    }

    /// A port carrying one of our unique IDs under a DIFFERENT name is not
    /// ours and is not an orphan — it is somebody else's device, and calling
    /// it a fault would send the user chasing a problem they do not have.
    func testAForeignPortIsNotMistakenForAnOrphan() {
        let census = expectedBridgeEndpoints + [
            MIDIEndpointInfo(name: "Push 3 Live Port", uniqueID: 4321, isSource: true)
        ]
        let verdict = DoctorFacts.classifyPorts(census)
        XCTAssertTrue(verdict.orphans.isEmpty)
        XCTAssertTrue(verdict.missing.isEmpty)
    }

    // MARK: - File names

    /// No colons and second resolution: the bundle has to survive being
    /// attached, mailed and unzipped.
    func testBundleFileNameIsSafeEverywhere() {
        let date = Date(timeIntervalSince1970: 1_788_000_000)
        let name = DoctorFacts.bundleFileName(
            at: date, timeZone: TimeZone(identifier: "UTC") ?? .current
        )
        XCTAssertEqual(name, "logician-doctor-20260829-104000.txt")
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains(" "))
    }

    /// Two reports an hour apart must sort, which means the header carries the
    /// offset as well as the wall clock.
    func testHeaderTimestampCarriesTheOffset() {
        let date = Date(timeIntervalSince1970: 1_788_000_000)
        let stamp = DoctorFacts.headerTimestamp(
            at: date, timeZone: TimeZone(identifier: "UTC") ?? .current
        )
        XCTAssertEqual(stamp, "2026-08-29 10:40:00 Z")
    }

    // MARK: - Build identity

    /// The build facts are compile-time or nothing: there is no runtime API
    /// for either, and a guess in a support report is worse than a range.
    func testBuildIdentityIsAlwaysAnswered() {
        XCTAssertTrue(["debug", "release"].contains(DoctorFacts.buildConfiguration))
        XCTAssertFalse(DoctorFacts.swiftCompilerVersion.isEmpty)
        XCTAssertTrue(["arm64", "x86_64", "unknown"].contains(DoctorFacts.binaryArchitecture))
    }
}
