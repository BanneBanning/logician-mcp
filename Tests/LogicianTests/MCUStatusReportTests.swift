import XCTest
@testable import Logician

/// `logic_mcu_status` used to hand the state FILE over verbatim. The file is
/// written only when Logic sends something and its `online` is computed at
/// write time, so a written file says `online: true` by construction and goes
/// on saying it after the daemon dies. These pin the derivations that replaced
/// the passthrough.
final class MCUStatusReportTests: XCTestCase {
    private let now: Double = 1_788_400_000

    private func mirror(
        updated: Double, lastReceive: Double, online: Bool = true,
        receivedEvents: Int = 4321, assignment: String = "PN",
        bridgeRunning: Bool = false
    ) -> [String: Any] {
        [
            "updated": updated,
            "last_receive": lastReceive,
            "online": online,
            "received_events": receivedEvents,
            "assignment": assignment,
            "lcd_top": "Kick   Snare  ",
            "bridge_running": bridgeRunning
        ]
    }

    // MARK: - Age: the reader has no clock, so the server does the subtraction

    func testAStaleMirrorReportsItsAgeInsteadOfABareTimestamp() {
        let payload = MCUStatusReport.payload(
            snapshot: mirror(updated: now - 197, lastReceive: now - 197),
            source: .stateFile, daemonPidAlive: nil, now: now
        )
        XCTAssertEqual(payload["age_seconds"] as? Double, 197)
        // `updated` survives - the raw timestamp is still the daemon's own
        // word, and the passthrough shape is deliberate.
        XCTAssertEqual(payload["updated"] as? Double, now - 197)
    }

    func testASocketAnswerIsReportedAsAgeZeroRatherThanAsNoAgeAtAll() {
        let payload = MCUStatusReport.payload(
            snapshot: mirror(updated: now, lastReceive: now - 0.25),
            source: .socket, daemonPidAlive: nil, now: now
        )
        XCTAssertEqual(payload["age_seconds"] as? Double, 0)
        XCTAssertEqual(payload["source"] as? String, "socket")
    }

    func testAClockThatRanBackwardsIsClampedRatherThanReportedAsNegativeAge() {
        // Two processes, one wall clock, and a daemon that wrote its file a
        // few hundred microseconds "after" this read started.
        let payload = MCUStatusReport.payload(
            snapshot: mirror(updated: now + 0.4, lastReceive: now),
            source: .socket, daemonPidAlive: nil, now: now
        )
        XCTAssertEqual(payload["age_seconds"] as? Double, 0)
    }

    func testASnapshotWithNoTimestampSaysSoInsteadOfClaimingAgeZero() {
        var snapshot = mirror(updated: 0, lastReceive: now)
        snapshot.removeValue(forKey: "updated")
        let payload = MCUStatusReport.payload(
            snapshot: snapshot, source: .stateFile, daemonPidAlive: nil, now: now
        )
        XCTAssertTrue(payload["age_seconds"] is NSNull)
    }

    // MARK: - online, recomputed at read time

    func testAFrozenOnlineTrueBecomesFalseOnceLogicHasBeenQuiet() {
        // The measured lie, 2026-09-02: a 117 s-old mirror still claiming
        // online while the daemon's live answer to the same question was no.
        let payload = MCUStatusReport.payload(
            snapshot: mirror(updated: now - 117, lastReceive: now - 117, online: true),
            source: .stateFile, daemonPidAlive: nil, now: now
        )
        XCTAssertEqual(payload["online"] as? Bool, false)
        XCTAssertEqual(payload["last_receive_age_seconds"] as? Double, 117)
    }

    func testRecentTrafficIsStillOnline() {
        let payload = MCUStatusReport.payload(
            snapshot: mirror(updated: now - 1, lastReceive: now - 1),
            source: .socket, daemonPidAlive: nil, now: now
        )
        XCTAssertEqual(payload["online"] as? Bool, true)
    }

    func testTheWindowIsTheDaemonsOwnTenSeconds() {
        let inside = MCUStatusReport.payload(
            snapshot: mirror(updated: now, lastReceive: now - 9.5),
            source: .socket, daemonPidAlive: nil, now: now
        )
        let outside = MCUStatusReport.payload(
            snapshot: mirror(updated: now, lastReceive: now - 10.5),
            source: .socket, daemonPidAlive: nil, now: now
        )
        XCTAssertEqual(inside["online"] as? Bool, true)
        XCTAssertEqual(outside["online"] as? Bool, false)
    }

    func testADaemonLogicHasNeverSpokenToIsNotOnlineHoweverFreshItIs() {
        let payload = MCUStatusReport.payload(
            snapshot: mirror(updated: now, lastReceive: 0, online: true, receivedEvents: 0),
            source: .socket, daemonPidAlive: nil, now: now
        )
        XCTAssertEqual(payload["online"] as? Bool, false)
        // "Never" is not "0 seconds ago".
        XCTAssertTrue(payload["last_receive_age_seconds"] is NSNull)
    }

    func testTrafficInsideTheWindowStillNeedsAnEventEverToCountAsOnline() {
        let payload = MCUStatusReport.payload(
            snapshot: mirror(updated: now, lastReceive: now - 1, receivedEvents: 0),
            source: .socket, daemonPidAlive: nil, now: now
        )
        XCTAssertEqual(payload["online"] as? Bool, false)
    }

    // MARK: - bridge_running means one thing, in both tools

    func testASocketAnswerIsTheProofThatTheBridgeIsRunning() {
        let payload = MCUStatusReport.payload(
            snapshot: mirror(updated: now, lastReceive: now),
            source: .socket, daemonPidAlive: nil, now: now
        )
        XCTAssertEqual(payload["bridge_running"] as? Bool, true)
        XCTAssertNil(payload["bridge_fix"])
        XCTAssertNil(payload["warning"])
    }

    func testADeadDaemonsMirrorReportsTheBridgeAsNotRunning() {
        let payload = MCUStatusReport.payload(
            snapshot: mirror(updated: now - 300, lastReceive: now - 300, bridgeRunning: false),
            source: .stateFile, daemonPidAlive: false, now: now
        )
        XCTAssertEqual(payload["bridge_running"] as? Bool, false)
        XCTAssertEqual(payload["source"] as? String, "state_file")
        XCTAssertTrue((payload["bridge_fix"] as? String ?? "").contains("logic_health"))
    }

    func testAWedgedDaemonIsNamedAsWedgedRatherThanAsAbsent() {
        let alive = MCUStatusReport.bridgeFix(pingAnswered: false, daemonPidAlive: true)
        XCTAssertTrue(alive.contains("alive"))
        XCTAssertTrue(alive.contains("logic_health"))
        let absent = MCUStatusReport.bridgeFix(pingAnswered: false, daemonPidAlive: nil)
        XCTAssertTrue(absent.contains("No bridge daemon answered"))
        let wedged = MCUStatusReport.bridgeFix(pingAnswered: true, daemonPidAlive: true)
        XCTAssertTrue(wedged.contains("ping"))
    }

    func testADaemonThatPingsButWillNotAnswerStatusIsStillReportedRunning() {
        // The ping is the same probe logic_health's `bridge_running` reports,
        // so the two tools must not disagree about the word.
        let payload = MCUStatusReport.payload(
            snapshot: mirror(updated: now - 40, lastReceive: now - 40, bridgeRunning: true),
            source: .stateFile, daemonPidAlive: true, now: now
        )
        XCTAssertEqual(payload["bridge_running"] as? Bool, true)
        // …and the snapshot's age is still called out separately.
        XCTAssertEqual(payload["age_seconds"] as? Double, 40)
        XCTAssertTrue((payload["warning"] as? String ?? "").contains("40 s OLD"))
    }

    // MARK: - The staleness warning

    func testAMirrorInsideTheWindowIsNotShoutedAbout() {
        let payload = MCUStatusReport.payload(
            snapshot: mirror(updated: now - 2, lastReceive: now - 2),
            source: .stateFile, daemonPidAlive: false, now: now
        )
        XCTAssertNil(payload["warning"])
    }

    func testAMinutesOldMirrorCarriesItsAgeInTheWarningText() {
        let payload = MCUStatusReport.payload(
            snapshot: mirror(updated: now - 411, lastReceive: now - 411),
            source: .stateFile, daemonPidAlive: false, now: now
        )
        let warning = payload["warning"] as? String ?? ""
        XCTAssertTrue(warning.contains("411 s OLD"))
        XCTAssertTrue(warning.contains("assignment"))
    }

    // MARK: - The assignment display, decoded

    func testPanIsNamedAndFlaggedSafe() {
        let payload = MCUStatusReport.payload(
            snapshot: mirror(updated: now, lastReceive: now, assignment: "PN"),
            source: .socket, daemonPidAlive: nil, now: now
        )
        XCTAssertEqual(payload["assignment_view"] as? String, "pan")
        XCTAssertEqual(payload["assignment_plugin_edit"] as? Bool, false)
        XCTAssertEqual(payload["assignment_send_view"] as? Bool, false)
        // The raw code stays, for anything that already reads it.
        XCTAssertEqual(payload["assignment"] as? String, "PN")
    }

    func testTheSendViewIsFlaggedBecauseABrowseCanFallOutOfIt() {
        let payload = MCUStatusReport.payload(
            snapshot: mirror(updated: now, lastReceive: now, assignment: "SE"),
            source: .socket, daemonPidAlive: nil, now: now
        )
        XCTAssertEqual(payload["assignment_view"] as? String, "send")
        XCTAssertEqual(payload["assignment_send_view"] as? Bool, true)
        XCTAssertEqual(payload["assignment_plugin_edit"] as? Bool, false)
    }

    func testTheLeakedPluginEditFamilyIsFlagged() {
        for code in ["IN", "P1", "P8", "P_"] {
            let payload = MCUStatusReport.payload(
                snapshot: mirror(updated: now, lastReceive: now, assignment: code),
                source: .socket, daemonPidAlive: nil, now: now
            )
            XCTAssertEqual(
                payload["assignment_plugin_edit"] as? Bool, true,
                "\(code) opens a plugin window on the next track selection"
            )
        }
    }

    func testAnInsertBankIsNamedBySlot() {
        XCTAssertEqual(MCUStatusReport.viewName("P3"), "insert 3 parameters")
        XCTAssertEqual(MCUStatusReport.viewName("IN"), "instrument edit")
        XCTAssertEqual(MCUStatusReport.viewName("CS"), "channel strip")
        XCTAssertEqual(MCUStatusReport.viewName("EQ"), "EQ")
    }

    func testAnUnknownCodeIsReportedAsUnknownRatherThanGuessedAt() {
        XCTAssertEqual(MCUStatusReport.viewName("P_"), "unrecognised (P_)")
        XCTAssertEqual(MCUStatusReport.viewName("ZZ"), "unrecognised (ZZ)")
        // …and P_ is still a plugin-edit hazard, decoded name or not.
        XCTAssertTrue(MCUController.isPluginEditAssignment("P_"))
    }

    func testAnEmptyAssignmentIsNotDecodedIntoAFalseAllClear() {
        var snapshot = mirror(updated: now, lastReceive: now)
        snapshot["assignment"] = ""
        let payload = MCUStatusReport.payload(
            snapshot: snapshot, source: .socket, daemonPidAlive: nil, now: now
        )
        XCTAssertNil(payload["assignment_view"])
        XCTAssertNil(payload["assignment_plugin_edit"])
    }

    // MARK: - The result contract, on every branch

    func testEveryBranchCarriesTheSuccessAndStateEnvelope() {
        let branches: [[String: Any]] = [
            MCUStatusReport.payload(
                snapshot: mirror(updated: now, lastReceive: now),
                source: .socket, daemonPidAlive: nil, now: now
            ),
            MCUStatusReport.payload(
                snapshot: mirror(updated: now - 200, lastReceive: now - 200),
                source: .stateFile, daemonPidAlive: false, now: now
            ),
            MCUStatusReport.payload(
                snapshot: ["bridge_running": false, "note": "no state file yet"],
                source: .unavailable, daemonPidAlive: nil, now: now
            )
        ]
        for payload in branches {
            XCTAssertEqual(payload["success"] as? Bool, true)
            XCTAssertEqual(payload["state"] as? String, "read")
            XCTAssertNotNil(payload["source"])
            XCTAssertNotNil(payload["bridge_running"])
        }
    }

    func testTheNoStateFileBranchKeepsItsReasonAndInventsNoSnapshot() {
        let payload = MCUStatusReport.payload(
            snapshot: [
                "bridge_running": false,
                "note": "no state file yet; the bridge starts automatically - call logic_health"
            ],
            source: .unavailable, daemonPidAlive: nil, now: now
        )
        XCTAssertEqual(payload["source"] as? String, "unavailable")
        XCTAssertEqual(payload["bridge_running"] as? Bool, false)
        XCTAssertTrue((payload["note"] as? String ?? "").contains("logic_health"))
        // No fabricated age, no fabricated online, no fabricated view.
        XCTAssertNil(payload["age_seconds"])
        XCTAssertNil(payload["online"])
        XCTAssertNil(payload["assignment_view"])
    }
}
