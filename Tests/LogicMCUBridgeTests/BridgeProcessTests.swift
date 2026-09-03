import XCTest
@testable import LogicMCUBridge

/// Deciding which process is the bridge daemon. This is a KILL LIST, and it
/// has been wrong in both directions in this project's history — once too
/// broad (a `pkill -f` that could hit unrelated processes, closed as a
/// security finding) and once too narrow (an absolute-path match that never
/// fired, so every daemon upgrade silently no-opped while a second bridge was
/// spawned anyway). Both failure directions are pinned here.
final class BridgeProcessTests: XCTestCase {

    private let own: Int32 = 4242

    private func candidate(_ pid: Int32, _ arguments: String) -> BridgeProcess.Candidate {
        BridgeProcess.Candidate(pid: pid, arguments: arguments)
    }

    // MARK: The regression that prompted this

    /// The exact shape observed live on 2026-08-28: the daemon was started as
    /// `./.build/release/logician --bridge`, and the old matcher looked for
    /// the server's ABSOLUTE path, so it matched nothing.
    func testADaemonStartedWithARelativePathIsFound() {
        let candidates = [candidate(900, "./.build/release/logician --bridge")]
        XCTAssertEqual(BridgeProcess.daemonPids(among: candidates, excluding: own), [900])
    }

    func testTheSameDaemonStartedWithAnAbsolutePathIsAlsoFound() {
        let candidates = [candidate(901, "/Users/x/proj/.build/release/logician --bridge")]
        XCTAssertEqual(BridgeProcess.daemonPids(among: candidates, excluding: own), [901])
    }

    /// This project's own directory contains spaces, so an absolute
    /// invocation splits into several "words" — a matcher that took argv[0]
    /// as "everything up to the first space" would miss it.
    func testAnExecutablePathContainingSpacesIsFound() {
        let candidates = [
            candidate(902, "/Users/b/Desktop/Progg/Random Projekt/Logic MCP/.build/release/logician --bridge")
        ]
        XCTAssertEqual(BridgeProcess.daemonPids(among: candidates, excluding: own), [902])
    }

    func testTheLegacyStandaloneDaemonIsStillFound() {
        let candidates = [candidate(903, "logic-mcu-bridge --bridge")]
        XCTAssertEqual(BridgeProcess.daemonPids(among: candidates, excluding: own), [903])
    }

    // MARK: The other failure direction — never kill a bystander

    /// The MCP SERVER is the very same binary, with no `--bridge`. Killing it
    /// would be killing ourselves by another name.
    func testTheServerItselfIsNotADaemon() {
        let candidates = [candidate(904, "/Users/x/proj/.build/release/logician")]
        XCTAssertEqual(BridgeProcess.daemonPids(among: candidates, excluding: own), [])
    }

    func testUnrelatedProcessesMentioningBridgeAreNotDaemons() {
        let candidates = [
            candidate(905, "vim Sources/LogicMCUBridge/Bridge.swift --bridge"),
            candidate(906, "tail -f bridge.log --bridge"),
            candidate(907, "zsh -c 'logician --bridge'"),
            candidate(908, "grep -r logician --bridge")
        ]
        XCTAssertEqual(BridgeProcess.daemonPids(among: candidates, excluding: own), [],
                       "matching on the argument alone is the security bug this replaces")
    }

    func testOurOwnPidIsNeverATarget() {
        let candidates = [candidate(own, "./.build/release/logician --bridge")]
        XCTAssertEqual(BridgeProcess.daemonPids(among: candidates, excluding: own), [])
    }

    func testInitAndPidZeroAreNeverTargets() {
        let candidates = [
            candidate(1, "/sbin/logician --bridge"),
            candidate(0, "/kernel/logician --bridge")
        ]
        XCTAssertEqual(BridgeProcess.daemonPids(among: candidates, excluding: own), [])
    }

    // MARK: Whole-argument matching

    func testBridgeMustBeAWholeArgument() {
        XCTAssertTrue(BridgeProcess.hasBridgeArgument("logician --bridge"))
        XCTAssertTrue(BridgeProcess.hasBridgeArgument("logician --bridge --verbose"))
        XCTAssertFalse(BridgeProcess.hasBridgeArgument("logician --bridgeless"))
        XCTAssertFalse(BridgeProcess.hasBridgeArgument("logician /tmp/my--bridge-notes.txt"))
        XCTAssertFalse(BridgeProcess.hasBridgeArgument("logician"))
        XCTAssertFalse(BridgeProcess.hasBridgeArgument(""))
    }

    func testDaemonNameMustBePathFinal() {
        XCTAssertTrue(BridgeProcess.invokesDaemonExecutable("./x/logician --bridge"))
        XCTAssertTrue(BridgeProcess.invokesDaemonExecutable("logician --bridge"))
        XCTAssertTrue(BridgeProcess.invokesDaemonExecutable("/opt/logician"))
        XCTAssertFalse(BridgeProcess.invokesDaemonExecutable("logicianx --bridge"))
        XCTAssertFalse(BridgeProcess.invokesDaemonExecutable("mylogician --bridge"))
        XCTAssertFalse(BridgeProcess.invokesDaemonExecutable("cat logician.log"))
    }

    // MARK: ps parsing

    /// Verbatim from the user's machine on 2026-08-28, `ps -axww -o
    /// pid=,args=`. The daemon really is invoked relatively and the server
    /// really does live under a path containing spaces, so both quirks are
    /// pinned against real output rather than an invented fixture.
    func testParsesTheRealMachinesPSOutput() {
        let output = """
        24761 ./.build/release/logician --bridge
         7662 /Users/dev/Projects/Random Projekt/Logic MCP/.build/release/logician
         1234 vim notes.txt
        """
        let parsed = BridgeProcess.parsePS(output)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].pid, 24761)
        XCTAssertEqual(parsed[0].arguments, "./.build/release/logician --bridge")
        // Only the daemon; the server on the space-containing path is spared
        // because it carries no `--bridge`.
        XCTAssertEqual(BridgeProcess.daemonPids(among: parsed, excluding: own), [24761])
    }

    /// `ps -o comm=` truncates to 16 characters on macOS, which is why this
    /// code reads the binary name out of the argument vector instead. The
    /// truncated value for the real daemon was `./.build/release` — the
    /// binary name, the only part that identifies it, cut clean off.
    func testTruncatedCommWouldNotHaveIdentifiedTheDaemon() {
        let truncated = "./.build/release" // exactly what ps reported, 16 chars
        XCTAssertEqual(truncated.count, 16)
        XCTAssertFalse(
            BridgeProcess.daemonExecutableNames.contains(
                (truncated as NSString).lastPathComponent
            ),
            "matching on ps's comm field is what this design deliberately avoids"
        )
    }

    func testUnparseableRowsAreDroppedRatherThanGuessedAt() {
        let output = """
        not-a-pid /usr/bin/logician --bridge

           777
        """
        let parsed = BridgeProcess.parsePS(output)
        XCTAssertEqual(BridgeProcess.daemonPids(among: parsed, excluding: own), [])
    }

    func testEmptyPSOutputYieldsNoTargets() {
        XCTAssertEqual(BridgeProcess.parsePS(""), [])
        XCTAssertEqual(BridgeProcess.daemonPids(among: [], excluding: own), [])
    }

    // MARK: The pid file

    func testReadsAPidWrittenByADaemon() {
        XCTAssertEqual(BridgeProcess.parsePidFile("24761\n"), 24761)
        XCTAssertEqual(BridgeProcess.parsePidFile("  24761  "), 24761)
    }

    /// A pre-pid-file daemon leaves the lockfile EMPTY — which is exactly the
    /// daemon an upgrade meets, so this path has to fall through to the scan
    /// rather than resolving to a bogus target.
    func testAnEmptyOrMalformedLockFileYieldsNoPid() {
        XCTAssertNil(BridgeProcess.parsePidFile(""))
        XCTAssertNil(BridgeProcess.parsePidFile("\n"))
        XCTAssertNil(BridgeProcess.parsePidFile("not a pid"))
        XCTAssertNil(BridgeProcess.parsePidFile("0"))
        XCTAssertNil(BridgeProcess.parsePidFile("1"), "pid 1 is launchd, never our daemon")
        XCTAssertNil(BridgeProcess.parsePidFile("-5"))
    }
}
