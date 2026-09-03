import Foundation
import XCTest
@testable import Logician

/// The two folds RELEASE-PLAN step 3 asked for (2026-09-03 token audit, cuts #4
/// and #5): `logic_set_track_volume`/`_pan`/`_mute`/`_solo` became one
/// PATCH-style `logic_set_track_mix`, and `logic_select_region` was folded into
/// `logic_select_regions` behind its `mode`.
///
/// Both write paths are untouched, so what is new — and what these tests are
/// for — is entirely SURFACE: the argument parsing that decides which writes go
/// out and in what order, the roll-up that turns four independent verdicts into
/// one `success`/`verified`, and the two refusals that keep a folded tool from
/// silently dropping an argument that only made sense to the tool it replaced.
final class TrackMixFoldTests: XCTestCase {
    private var server = MCPServer()

    override func setUp() {
        super.setUp()
        server = MCPServer()
        MCPServer.activeToolsets = Toolset.all
    }

    // MARK: - The fold is real: the old names are gone, the new ones are there

    func testTheFoldedToolsReplacedTheirOriginalsInTheRegistry() {
        let names = Set(server.toolRegistry().map(\.name))
        for gone in [
            "logic_set_track_volume", "logic_set_track_pan", "logic_set_track_mute",
            "logic_set_track_solo", "logic_select_region"
        ] {
            XCTAssertFalse(names.contains(gone), "\(gone) is still advertised")
        }
        XCTAssertTrue(names.contains("logic_set_track_mix"))
        XCTAssertTrue(names.contains("logic_select_regions"))
    }

    /// Every parameter the four tools took has a home on the folded one, and
    /// the four compare-and-set guards stay SEPARATE — one `expected_current`
    /// standing for a dB, a knob position and two booleans is exactly the
    /// overload the audit flagged as this fold's concentrated risk.
    func testTheMixToolCarriesEveryParameterAndFourSeparateGuards() throws {
        let tool = try XCTUnwrap(
            server.toolRegistry().first { $0.name == "logic_set_track_mix" }
        )
        let properties = try XCTUnwrap(tool.inputSchema["properties"] as? [String: Any])
        for key in [
            "track_name", "track_number", "volume_db", "relative_volume_db", "tolerance_db",
            "pan", "mute", "solo", "expected_current_volume_db", "expected_current_pan",
            "expected_current_mute", "expected_current_solo"
        ] {
            XCTAssertNotNil(properties[key], key)
        }
        XCTAssertNil(properties["expected_current"], "the overloaded guard must not exist")
        XCTAssertEqual(tool.inputSchema["required"] as? [String], ["track_name"])
    }

    // MARK: - TrackMixPlan: what one call asks for, before anything is written

    func testASubsetIsAppliedInTheFixedOrderVolumePanMuteSolo() throws {
        let all = try TrackMixPlan(arguments: [
            "solo": true, "mute": false, "pan": -12, "volume_db": -6.0
        ])
        XCTAssertEqual(all.order, [.volume, .pan, .mute, .solo])
        // Mute before solo is the rule, not the dictionary's order: a solo this
        // same call sets would put the mute readback inside the blink window.
        let both = try TrackMixPlan(arguments: ["solo": true, "mute": true])
        XCTAssertEqual(both.order, [.mute, .solo])
        let one = try TrackMixPlan(arguments: ["pan": 0])
        XCTAssertEqual(one.order, [.pan])
    }

    func testACallThatNamesNoParameterIsRefusedNamingAllOfThem() {
        XCTAssertThrowsError(try TrackMixPlan(arguments: ["track_name": "Bas"])) { error in
            XCTAssertEqual((error as? LogicianError)?.code, "invalid_arguments")
            let message = error.localizedDescription
            for parameter in ["volume_db", "relative_volume_db", "pan", "mute", "solo"] {
                XCTAssertTrue(message.contains(parameter), "the refusal does not name \(parameter)")
            }
            XCTAssertTrue(message.contains("NOTHING was written"))
        }
    }

    func testAnAbsoluteAndARelativeVolumeTargetAreStillMutuallyExclusive() {
        XCTAssertThrowsError(
            try TrackMixPlan(arguments: ["volume_db": -6.0, "relative_volume_db": 2.0])
        ) { error in
            XCTAssertEqual((error as? LogicianError)?.code, "invalid_arguments")
            XCTAssertTrue(error.localizedDescription.contains("relative_volume_db"))
        }
    }

    /// A guard for a write this call does not make is a typo, and dropping it
    /// would tell the caller a precondition had been checked that never was —
    /// the same rule `additionalProperties: false` enforces for the schema.
    func testAGuardWithoutItsOwnParameterIsRefusedRatherThanIgnored() throws {
        // Each guard passed alongside a parameter that is NOT its own, so
        // "nothing to set" is never what refuses it.
        let orphans: [(guardKey: String, arguments: [String: Any])] = [
            ("expected_current_volume_db", ["pan": 0, "expected_current_volume_db": -6.0]),
            ("expected_current_pan", ["mute": true, "expected_current_pan": 3]),
            ("expected_current_mute", ["solo": true, "expected_current_mute": false]),
            ("expected_current_solo", ["volume_db": -6.0, "expected_current_solo": true])
        ]
        for (guardKey, arguments) in orphans {
            XCTAssertThrowsError(try TrackMixPlan(arguments: arguments)) { error in
                XCTAssertEqual((error as? LogicianError)?.code, "invalid_arguments", guardKey)
                XCTAssertTrue(error.localizedDescription.contains(guardKey), guardKey)
                XCTAssertTrue(error.localizedDescription.contains("NOTHING was written"), guardKey)
            }
        }
        // And each guard rides along fine with the parameter it belongs to.
        let plan = try TrackMixPlan(arguments: [
            "volume_db": -6.0, "expected_current_volume_db": -12.0,
            "pan": 10, "expected_current_pan": 0,
            "mute": true, "expected_current_mute": false,
            "solo": false, "expected_current_solo": true
        ])
        XCTAssertEqual(plan.pan, TrackMixPlan.PanWrite(position: 10, expectedCurrent: 0))
        XCTAssertEqual(plan.mute, TrackMixPlan.ToggleWrite(enabled: true, expectedCurrent: false))
        XCTAssertEqual(plan.solo, TrackMixPlan.ToggleWrite(enabled: false, expectedCurrent: true))
        XCTAssertEqual(plan.volume?.expectedCurrentDb, -12.0)
        XCTAssertEqual(try XCTUnwrap(plan.volume).target(currentDb: -12.0), -6.0)
    }

    /// `pan` sits beside `volume_db`, a genuine JSON `number`, so a client that
    /// sends `5.0` for the knob must not be refused for it — and `5.5`, which
    /// is not a position at all, must be.
    func testAKnobPositionIsReadWhicheverWayTheClientTypedIt() throws {
        XCTAssertEqual(try TrackMixPlan(arguments: ["pan": 5]).pan?.position, 5)
        XCTAssertEqual(try TrackMixPlan(arguments: ["pan": 5.0]).pan?.position, 5)
        XCTAssertEqual(try TrackMixPlan(arguments: ["pan": -64.0]).pan?.position, -64)
        XCTAssertThrowsError(try TrackMixPlan(arguments: ["pan": 5.5])) { error in
            XCTAssertEqual((error as? LogicianError)?.code, "invalid_arguments")
            XCTAssertTrue(error.localizedDescription.contains("whole knob position"))
        }
    }

    // MARK: - The roll-up: four verdicts, one result

    private func section(
        _ parameter: String, state: String, success: Bool = true, verified: Bool = true,
        extra: [String: Any] = [:]
    ) -> (parameter: String, payload: [String: Any]) {
        var payload: [String: Any] = ["success": success, "verified": verified, "state": state]
        for (key, value) in extra { payload[key] = value }
        return (parameter, payload)
    }

    func testEveryWriteThatLandedIsNamedAndTheCallIsVerified() throws {
        let verdict = TrackMixPlan.verdict(sections: [
            section("volume", state: "volume_set", extra: ["after_db": -6.0]),
            section("pan", state: "pan_set", extra: ["after": 10])
        ])
        XCTAssertEqual(verdict["success"] as? Bool, true)
        XCTAssertEqual(verdict["verified"] as? Bool, true)
        XCTAssertEqual(verdict["state"] as? String, "set")
        XCTAssertEqual(verdict["written"] as? [String], ["volume", "pan"])
        XCTAssertNil(verdict["unchanged"])
        XCTAssertNil(verdict["warning"])
        // Each section is kept whole, with its own readback and its own words.
        XCTAssertEqual((verdict["volume"] as? [String: Any])?["after_db"] as? Double, -6.0)
    }

    /// A call whose every parameter was already where it was asked to be
    /// changed nothing, so the result must not carry "you changed how the song
    /// SOUNDS" (`Tool.changedNothing` reads exactly this `state`).
    func testACallThatChangedNothingSaysSoAndOwesNoListenNote() {
        let verdict = TrackMixPlan.verdict(sections: [
            section("mute", state: "already_off"),
            section("solo", state: "already_off")
        ])
        XCTAssertEqual(verdict["state"] as? String, "already_set")
        XCTAssertEqual(verdict["unchanged"] as? [String], ["mute", "solo"])
        XCTAssertNil(verdict["written"])
        XCTAssertTrue(Tool.changedNothing(verdict))
    }

    func testARefusedParameterFailsTheCallAndTheWarningNamesWhatDidLand() throws {
        let verdict = TrackMixPlan.verdict(sections: [
            section("volume", state: "volume_set"),
            section(
                "pan", state: "refused", success: false, verified: false,
                extra: [
                    "error_code": "precondition_failed",
                    "error": "Current value mismatch. Expected pan 0, found pan 12."
                ]
            )
        ])
        XCTAssertEqual(verdict["success"] as? Bool, false)
        XCTAssertEqual(verdict["verified"] as? Bool, false)
        XCTAssertEqual(verdict["refused"] as? [String], ["pan"])
        XCTAssertEqual(verdict["written"] as? [String], ["volume"])
        // Something DID land, so the state is `set` even though the call failed.
        XCTAssertEqual(verdict["state"] as? String, "set")
        let warning = try XCTUnwrap(verdict["warning"] as? String)
        XCTAssertTrue(warning.contains("precondition_failed"))
        XCTAssertTrue(warning.contains("These WERE written: volume"))
        // The refused section stays refused, and stays readable.
        XCTAssertEqual((verdict["pan"] as? [String: Any])?["state"] as? String, "refused")
    }

    func testAFailureStopsTheCallAndTheParametersBehindItSayTheyWereNotAttempted() throws {
        let verdict = TrackMixPlan.verdict(sections: [
            section(
                "volume", state: "refused", success: false, verified: false,
                extra: ["error_code": "not_exposed", "error": "no readable dB value"]
            ),
            section(
                "mute", state: "not_attempted", success: false, verified: false,
                extra: ["reason": "the volume write failed with not_exposed"]
            )
        ])
        XCTAssertEqual(verdict["success"] as? Bool, false)
        XCTAssertEqual(verdict["not_attempted"] as? [String], ["mute"])
        let warning = try XCTUnwrap(verdict["warning"] as? String)
        XCTAssertTrue(warning.contains("Nothing was written."))
        XCTAssertTrue(warning.contains("Not attempted after that: mute"))
    }

    /// A call where NOTHING landed must not report `state: "set"` just because
    /// a write was tried — measured live 2026-09-03 on the sandbox: a refused
    /// compare-and-set on `pan` came back `state: "set"` beside
    /// `success: false` and `"Nothing was written."`.
    func testACallWhereNothingLandedSaysRefusedRatherThanSet() {
        let onlyRefusal = TrackMixPlan.verdict(sections: [
            section(
                "pan", state: "refused", success: false, verified: false,
                extra: ["error_code": "precondition_failed", "error": "Current value mismatch."]
            )
        ])
        XCTAssertEqual(onlyRefusal["state"] as? String, "refused")
        XCTAssertEqual(onlyRefusal["success"] as? Bool, false)
        // A refusal beside a verified NO-OP is still nothing landed.
        let withNoOp = TrackMixPlan.verdict(sections: [
            section(
                "volume", state: "refused", success: false, verified: false,
                extra: ["error_code": "precondition_failed", "error": "Current value mismatch."]
            ),
            section("mute", state: "already_off")
        ])
        XCTAssertEqual(withNoOp["state"] as? String, "refused")
        XCTAssertEqual(withNoOp["unchanged"] as? [String], ["mute"])
    }

    /// A fader that moved but stopped short is the one case where `success` and
    /// `verified` legitimately disagree — the fold must not lose that, because
    /// `verified` is the term an agent decides on.
    func testAWriteThatLandedOutOfToleranceKeepsSuccessAndLosesVerified() {
        let verdict = TrackMixPlan.verdict(sections: [
            section(
                "volume", state: "volume_set", verified: false,
                extra: ["deviation_db": 0.4, "verification_note": "the fader landed 0.4 dB out"]
            )
        ])
        XCTAssertEqual(verdict["success"] as? Bool, true)
        XCTAssertEqual(verdict["verified"] as? Bool, false)
        XCTAssertEqual(verdict["written"] as? [String], ["volume"])
    }

    // MARK: - End to end through tools/call, without touching Logic

    /// The refusals both folds owe are argument-level, so they answer before
    /// any Accessibility or control-surface call — which is what makes them
    /// testable here, and what makes them cheap for an agent that got the call
    /// wrong.
    private func refusal(_ tool: String, _ arguments: [String: Any]) throws -> String {
        let result = server.callTool(name: tool, arguments: arguments)
        XCTAssertEqual(result["isError"] as? Bool, true, tool)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }

    func testTheMixToolRefusesAnEmptyCallThroughToolsCall() throws {
        let text = try refusal("logic_set_track_mix", ["track_name": "Bas"])
        XCTAssertTrue(text.contains("nothing to set"))
        XCTAssertTrue(text.contains("invalid_arguments"))
    }

    func testTheMixToolStillRefusesAnArgumentItDoesNotDeclare() throws {
        let text = try refusal("logic_set_track_mix", ["track_name": "Bas", "db": -6.0])
        XCTAssertTrue(text.contains("does not accept: db"))
        XCTAssertTrue(text.contains("volume_db"), "the refusal names the argument that replaced it")
    }

    /// `exclusive` means something only to the single-region mode: the command
    /// modes select their anchor exclusively and extend from it, so there is no
    /// additive form of "the whole track" to ask for. Dropping it silently
    /// would leave a caller believing their selection had been kept.
    func testExclusiveIsRefusedWithTheCommandModesAndNamesTheWayToAdd() throws {
        let text = try refusal("logic_select_regions", ["mode": "all", "exclusive": false])
        XCTAssertTrue(text.contains("exclusive belongs to mode 'region'"))
        XCTAssertTrue(text.contains("NOTHING was selected"))
    }

    func testTheFoldedSelectToolDefaultsToOneRegionAndStillNeedsATrack() throws {
        let tool = try XCTUnwrap(
            server.toolRegistry().first { $0.name == "logic_select_regions" }
        )
        let properties = try XCTUnwrap(tool.inputSchema["properties"] as? [String: Any])
        let mode = try XCTUnwrap(properties["mode"] as? [String: Any])
        XCTAssertEqual(
            mode["enum"] as? [String],
            ["region", "track", "following", "following_same_track", "all", "none"]
        )
        XCTAssertNotNil(properties["exclusive"])
        // `mode` is optional now — the single-region call the old tool took
        // works under the new name unchanged — so nothing is required, and a
        // call with no track at all says which argument is missing.
        XCTAssertNil(tool.inputSchema["required"])
        XCTAssertTrue(try refusal("logic_select_regions", [:]).contains("track_name"))
    }
}
