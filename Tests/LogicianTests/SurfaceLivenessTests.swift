import XCTest
@testable import Logician

/// Why the control surface could not be read — four faults that used to wear
/// one message, and the one of them that is not a fault at all.
///
/// Measured 2026-09-02, at the start of a profiling session: every MCU tool
/// refused in 3.9 ms with "The bridge is not running or Logic has never talked
/// to it (see logic_health)" while the daemon was running (pid 3459),
/// `logic_health` reported `bridge_running: true, mcu_connected: true,
/// logic_running: true`, and the mirror held 890 received events — it was just
/// 3 413 s old, because nobody had touched Logic in an hour. The message was
/// wrong on both counts it offered and pointed at a tool that said everything
/// was fine. One `bank_left` press woke it.
///
/// An idle hour cannot be arranged in a test, so the classification is a pure
/// function of the snapshot plus a clock and lives here.
final class SurfaceLivenessTests: XCTestCase {

    private let now: Double = 1_756_000_000

    /// The mirror as it actually was: answering, 890 events, an hour old.
    private func idleMirror(ageSeconds: Double) -> [String: Any] {
        ["ok": true, "received_events": 890, "last_receive": now - ageSeconds]
    }

    func testAnIdleSurfaceIsSilentAndNotBroken() {
        let why = MCUController.surfaceUnavailability(
            status: idleMirror(ageSeconds: 3413), logicRunning: true, now: now
        )
        XCTAssertEqual(why, .logicSilent(seconds: 3413))
        let detail = MCUController.surfaceUnavailabilityDetail(why)
        // The two things the old message asserted, and neither was true.
        XCTAssertTrue(detail.contains("the bridge IS running"))
        XCTAssertFalse(detail.contains("has never talked"))
        // It names how long, in minutes, because that is the fact an agent
        // needs to decide whether to worry.
        XCTAssertTrue(detail.contains("57 minute(s)"), detail)
    }

    func testNoDaemonIsTheOnlyCaseTheOldMessageDescribed() {
        XCTAssertEqual(
            MCUController.surfaceUnavailability(status: nil, logicRunning: true, now: now),
            .bridgeNotAnswering
        )
        // A snapshot that came back saying nothing is running is the same fault.
        XCTAssertEqual(
            MCUController.surfaceUnavailability(
                status: ["ok": false, "bridge_running": false], logicRunning: true, now: now
            ),
            .bridgeNotAnswering
        )
        let detail = MCUController.surfaceUnavailabilityDetail(.bridgeNotAnswering)
        XCTAssertTrue(detail.contains("no Mackie Control bridge daemon answered"))
        XCTAssertTrue(detail.contains("logic_health"))
    }

    func testADaemonWithNoLogicBehindItSaysSo() {
        let why = MCUController.surfaceUnavailability(
            status: idleMirror(ageSeconds: 3413), logicRunning: false, now: now
        )
        XCTAssertEqual(why, .logicNotRunning)
        let detail = MCUController.surfaceUnavailabilityDetail(why)
        XCTAssertTrue(detail.contains("Logic Pro is not running"))
        XCTAssertFalse(detail.contains("bridge is not running"))
    }

    /// A daemon Logic has never spoken to is a SETUP problem, and it is a
    /// different repair from every other case here.
    func testALogicThatNeverTalkedIsASetupProblem() {
        let why = MCUController.surfaceUnavailability(
            status: ["ok": true, "received_events": 0], logicRunning: true, now: now
        )
        XCTAssertEqual(why, .logicNeverTalked)
        XCTAssertTrue(
            MCUController.surfaceUnavailabilityDetail(why).contains("Control Surfaces")
        )
    }

    /// The age guard's threshold is a documented constant, not a literal
    /// buried in the middle of `freshStatus`.
    func testTheStaleThresholdIsTenMinutes() {
        XCTAssertEqual(MCUController.staleMirrorSeconds, 600)
    }
}
