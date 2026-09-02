import XCTest

import LogicMCUBridge
@testable import Logician

/// `logic_mcu_command` is the server's one raw escape hatch to the control
/// surface, and it had drifted away from itself in three directions at once:
/// the description advertised an argument the schema refused, the schema
/// advertised commands whose arguments it did not declare, and the result said
/// `ok: true` for a press that provably did nothing.
///
/// These tests hold the three agreements that keep it honest — the schema
/// against the wire type, the description against the schema, and the result
/// against what actually happened — and every one of them is pure: the shape
/// of an answer must not need a live Mackie Control to pin down.
final class McuCommandContractTests: XCTestCase {
    private var server = MCPServer()

    override func setUp() {
        super.setUp()
        server = MCPServer()
        MCPServer.activeToolsets = Toolset.all
    }

    private var tool: Tool {
        get throws {
            try XCTUnwrap(server.toolRegistry().first { $0.name == "logic_mcu_command" })
        }
    }

    private func properties() throws -> [String: Any] {
        try XCTUnwrap(tool.inputSchema["properties"] as? [String: Any])
    }

    // MARK: - The schema against the wire type

    /// The fix for the two structural defects, expressed as the invariant that
    /// caused them: a field the daemon reads and this schema does not declare
    /// is a field no caller can ever send, because `additionalProperties` is
    /// false. `verify` (the tool's ONLY readback) and the eight arguments of
    /// `converge`/`midi_stream`/`await` were all in that hole.
    func testTheSchemaDeclaresEveryFieldTheDaemonCanRead() throws {
        let declared = Set(try properties().keys)
        let onTheWire = Set(BridgeCommand.CodingKeys.allCases.map(\.stringValue))

        XCTAssertEqual(
            onTheWire.subtracting(declared), [],
            "the daemon reads these and no caller can send them"
        )
        // The other direction, minus the one property that is the server's own
        // and never forwarded.
        XCTAssertEqual(
            declared.subtracting(onTheWire), ["expected_project_path"],
            "the schema declares an argument the bridge command has no field for"
        )
    }

    func testEveryAdvertisedCommandNameIsOneTheDaemonKnows() throws {
        let advertised = try XCTUnwrap(
            (try properties()["cmd"] as? [String: Any])?["enum"] as? [String]
        )
        XCTAssertEqual(Set(advertised), Set(BridgeCommandName.allCases.map(\.rawValue)))
    }

    func testAdditionalPropertiesStaysClosed() throws {
        XCTAssertEqual(try tool.inputSchema["additionalProperties"] as? Bool, false)
    }

    /// `expected_project_path` was filtered by the handler and forbidden by the
    /// schema, so the guard could never fire — on the one `.destructive` tool
    /// that had no other project check at all.
    func testTheProjectGuardIsDeclaredSoItCanBePassed() throws {
        XCTAssertNotNil(try properties()["expected_project_path"])
    }

    func testTheHoldIsCappedInTheSchemaAtTheDaemonsOwnCeiling() throws {
        let hold = try XCTUnwrap(try properties()["hold_ms"] as? [String: Any])
        XCTAssertEqual(hold["minimum"] as? Int, 0)
        XCTAssertEqual(hold["maximum"] as? Int, BridgeCommand.maxPressHoldMs)
    }

    // MARK: - The description against the schema

    /// Seven buttons — marker, nudge, drop, replace, solo_global, global_view
    /// and smpte_beats — were in the enum and named nowhere in prose, behind a
    /// truncating `|...`.
    func testTheDescriptionNamesEveryButtonTheDaemonAccepts() throws {
        let description = try tool.description
        for button in buttonNames.keys.sorted() {
            XCTAssertTrue(
                description.contains(button),
                "\(button) is callable and the description never names it"
            )
        }
    }

    /// The old text sent callers to `logic_mcu_status`, which reads the state
    /// FILE — a mirror measured minutes old. The live snapshot is on this tool
    /// and costs the same.
    func testTheDescriptionPointsAtTheLiveSnapshotNotTheStateFile() throws {
        let description = try tool.description
        XCTAssertTrue(description.contains("{\"cmd\": \"status\"}"))
        XCTAssertFalse(
            description.contains("Read logic_mcu_status afterwards"),
            "the state file is not the plane that proves a press landed"
        )
    }

    func testTheDescriptionExplainsTheHoldDefault() throws {
        XCTAssertTrue(try tool.description.contains("hold_ms"))
    }

    // MARK: - The result contract

    private func result(
        cmd: String?, arguments: [String: Any] = [:], reply: [String: Any]
    ) -> [String: Any] {
        var full = arguments
        full["cmd"] = cmd
        return MCPServer.mcuCommandResult(cmd: cmd, arguments: full, reply: reply)
    }

    /// The measurement this contract exists for: pressing an MCU note Logic
    /// has nothing bound to answered `ok: true` six times with the surface
    /// byte-identical. `sent` and `verified: false` are the honest reading of
    /// that reply, and they are the same words a press that DID land gets.
    func testAPressReportsBytesLeftTheProcessAndNothingMore() {
        let answer = result(cmd: "press", reply: ["ok": true, "pressed_note": 127])

        XCTAssertEqual(answer["success"] as? Bool, true)
        XCTAssertEqual(answer["state"] as? String, "sent")
        XCTAssertEqual(answer["verified"] as? Bool, false)
        XCTAssertEqual(answer["ok"] as? Bool, true, "the daemon's own reply survives intact")
        XCTAssertEqual(answer["pressed_note"] as? Int, 127)
    }

    func testARefusalIsNotASuccessAndClaimsNoVerification() {
        let answer = result(cmd: "select", reply: ["ok": false, "error": "channel 0-7 required"])

        XCTAssertEqual(answer["success"] as? Bool, false)
        XCTAssertEqual(answer["state"] as? String, "refused")
        XCTAssertNil(answer["verified"])
        XCTAssertEqual(answer["error"] as? String, "channel 0-7 required")
    }

    /// A read changes nothing, so there is no outcome to verify. Absent beats
    /// a `verified: true` that would mean "the read read".
    func testAReadIsMarkedReadAndCarriesNoVerifiedField() {
        for cmd in ["status", "ping", "await"] {
            let answer = result(cmd: cmd, reply: ["ok": true])
            XCTAssertEqual(answer["state"] as? String, "read", cmd)
            XCTAssertNil(answer["verified"], cmd)
        }
    }

    func testAFaderWithVerifyReportsWhatLogicsEchoSaid() {
        let followed = result(
            cmd: "fader", arguments: ["verify": true],
            reply: ["ok": true, "followed": true, "final_value": 5628.0]
        )
        XCTAssertEqual(followed["state"] as? String, "verified")
        XCTAssertEqual(followed["verified"] as? Bool, true)

        let ignored = result(
            cmd: "fader", arguments: ["verify": true],
            reply: ["ok": true, "followed": false, "final_value": 12000.0]
        )
        XCTAssertEqual(ignored["state"] as? String, "unconfirmed")
        XCTAssertEqual(ignored["verified"] as? Bool, false)
    }

    /// Without `verify` the daemon reads nothing back, and the answer must not
    /// borrow the credit of the branch above.
    func testABlindFaderWriteIsOnlySent() {
        let answer = result(cmd: "fader", reply: ["ok": true])
        XCTAssertEqual(answer["state"] as? String, "sent")
        XCTAssertEqual(answer["verified"] as? Bool, false)
    }

    func testConvergeIsJudgedAgainstTheTargetItWasGiven() {
        let arrived = result(
            cmd: "converge", arguments: ["target": -6.0, "tolerance": 0.2],
            reply: ["ok": true, "final_value": -6.1, "iterations": 3]
        )
        XCTAssertEqual(arrived["state"] as? String, "verified")
        XCTAssertEqual(arrived["verified"] as? Bool, true)

        let missed = result(
            cmd: "converge", arguments: ["target": -6.0, "tolerance": 0.2],
            reply: ["ok": true, "final_value": -3.0, "iterations": 9]
        )
        XCTAssertEqual(missed["state"] as? String, "unconfirmed")
        XCTAssertEqual(missed["verified"] as? Bool, false)
    }

    /// A target typed as JSON `-6` arrives as Int, not Double. Reading it as
    /// `as? Double` alone would silently drop the whole converge branch back
    /// to "sent".
    func testAnIntegerTargetIsStillANumber() {
        let answer = result(
            cmd: "converge", arguments: ["target": -6],
            reply: ["ok": true, "final_value": -6.0]
        )
        XCTAssertEqual(answer["state"] as? String, "verified")
    }

    /// The keycmd route answers through MCUController, which already speaks
    /// `success` and never says `ok`.
    func testTheKeyCommandRouteKeepsItsOwnSuccessAndIsStillOnlySent() {
        let answer = result(
            cmd: "keycmd",
            reply: ["success": true, "command": "Save", "note": 105, "route": "midi_key_command"]
        )
        XCTAssertEqual(answer["success"] as? Bool, true)
        XCTAssertEqual(answer["state"] as? String, "sent")
        XCTAssertEqual(answer["verified"] as? Bool, false)
    }

    /// The daemon can be a NEWER build than this server. A command this build
    /// cannot classify counts as one that emitted — guessing "read" is the
    /// guess that hides a write, exactly as `BridgeCommand.emitsMIDI` decides
    /// it for the surface-touched flag.
    func testACommandThisBuildDoesNotKnowCountsAsAWrite() {
        let answer = result(cmd: "teleport", reply: ["ok": true])
        XCTAssertEqual(answer["state"] as? String, "sent")
        XCTAssertEqual(answer["verified"] as? Bool, false)
    }
}
