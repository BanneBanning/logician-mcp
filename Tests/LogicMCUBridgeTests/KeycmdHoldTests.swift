import XCTest
@testable import LogicMCUBridge

/// The key-command hold — `pressButton`'s UNSWEPT sibling.
///
/// `keycmd` slept a flat 40 ms between its note-on and note-off, unnamed and
/// unconfigurable, and it is ~96% of `logic_trigger_key_command`'s 50-52 ms
/// wall clock (KEY-COMMANDS-REVIEW.md, 2026-09-03). The MCU button press hold
/// next to it was swept live 2026-09-02 (`bf511e5`) and its default dropped
/// to a measured 0 ms; the key-command hold has had NO equivalent live sweep
/// yet, so this change is plumbing only — a named constant, settable per
/// message and by an environment override — with the default left at its
/// historical 40 ms. `keycmd_hold_sweep.py` (scratchpad) is the harness that
/// will make the live measurement these tests deliberately do not attempt.
///
/// These tests hold: that an absent hold_ms resolves to the DAEMON'S default
/// (not zero, unlike `pressHoldMs`), that a caller who asks for a hold —
/// including zero — gets exactly that, that the field stays additive and
/// lenient the same way `pressHoldMs` is, that the ceiling still applies, and
/// that the environment-override resolver is a pure function of its input.
///
/// No CoreMIDI endpoints exist in a test process, so the `sendCommandPort`
/// calls inside `handleCommand`'s `.keycmd` branch reach an invalid endpoint
/// and put nothing on any wire — the same setup `PressHoldTests` relies on.
final class KeycmdHoldTests: XCTestCase {
    // MARK: - Absent means the DAEMON's default, not zero

    func testACommandThatSaysNothingAboutTheHoldGetsTheGivenDefault() throws {
        let command = try bridgeJSONDecoder.decode(
            BridgeCommand.self, from: Data(#"{"cmd":"keycmd","note":104,"channel":16}"#.utf8)
        )
        XCTAssertNil(command.holdMs)
        XCTAssertEqual(command.keycmdHoldMs(default: 40), 40)
        // Unlike pressHoldMs, silence does NOT mean zero: the default is
        // whatever the daemon was told to use.
        XCTAssertEqual(command.keycmdHoldMs(default: 0), 0)
        XCTAssertEqual(command.keycmdHoldMs(default: 25), 25)
    }

    /// A caller who explicitly asks for zero is not "silent" — the request
    /// wins over whatever default the daemon would otherwise apply. This is
    /// the call `keycmd_hold_sweep.py` makes at the bottom of its sweep.
    func testAnExplicitZeroHoldOverridesTheDefault() throws {
        let command = try bridgeJSONDecoder.decode(
            BridgeCommand.self, from: Data(#"{"cmd":"keycmd","note":104,"hold_ms":0}"#.utf8)
        )
        XCTAssertEqual(command.holdMs, 0)
        XCTAssertEqual(command.keycmdHoldMs(default: 40), 0)
    }

    // MARK: - The factory

    func testTheFactoryLeavesAnUnrequestedHoldOffTheWireEntirely() throws {
        func encoded(_ command: BridgeCommand) throws -> [String: Any] {
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: try bridgeJSONEncoder.encode(command))
                    as? [String: Any]
            )
        }
        XCTAssertEqual(
            try encoded(.keycmd(note: 104, channel: 16)) as NSDictionary,
            ["cmd": "keycmd", "note": 104, "channel": 16]
        )
        // Explicit zero DOES go on the wire — it is a request, not silence.
        XCTAssertEqual(
            try encoded(.keycmd(note: 104, channel: 16, holdMs: 0)) as NSDictionary,
            ["cmd": "keycmd", "note": 104, "channel": 16, "hold_ms": 0]
        )
        XCTAssertEqual(
            try encoded(.keycmd(note: 104, channel: 16, holdMs: 5)) as NSDictionary,
            ["cmd": "keycmd", "note": 104, "channel": 16, "hold_ms": 5]
        )
    }

    /// Additive: the key is new, nothing else about a keycmd moved, and a
    /// daemon that has never heard of it decodes the same command it always
    /// did.
    func testHoldMsIsAnAdditiveFieldOnAnOtherwiseUnchangedKeycmd() throws {
        let withHold = try bridgeJSONDecoder.decode(
            BridgeCommand.self, from: Data(#"{"cmd":"keycmd","note":104,"hold_ms":10}"#.utf8)
        )
        XCTAssertEqual(withHold.cmd, "keycmd")
        XCTAssertEqual(withHold.note, 104)
        XCTAssertEqual(withHold.keycmdHoldMs(default: 40), 10)

        var stripped = withHold
        stripped.holdMs = nil
        let old = try bridgeJSONDecoder.decode(
            BridgeCommand.self, from: Data(#"{"cmd":"keycmd","note":104}"#.utf8)
        )
        XCTAssertEqual(stripped, old)
    }

    /// Leniency, like every other field: a wrongly-typed hold is "no
    /// opinion", which for keycmd resolves to the default, not to zero.
    func testAWronglyTypedHoldFallsBackToTheDefault() throws {
        let command = try bridgeJSONDecoder.decode(
            BridgeCommand.self,
            from: Data(#"{"cmd":"keycmd","note":104,"hold_ms":"long"}"#.utf8)
        )
        XCTAssertEqual(command.keycmdHoldMs(default: 40), 40)
    }

    // MARK: - The ceiling

    func testTheHoldIsClampedAtBothEnds() {
        var command = BridgeCommand(cmd: "keycmd")
        command.holdMs = -5
        XCTAssertEqual(command.keycmdHoldMs(default: 40), 0)
        command.holdMs = BridgeCommand.maxPressHoldMs + 60_000
        XCTAssertEqual(command.keycmdHoldMs(default: 40), BridgeCommand.maxPressHoldMs)
        command.holdMs = 12
        XCTAssertEqual(command.keycmdHoldMs(default: 40), 12)
    }

    // MARK: - What the daemon actually does with it

    /// The saving itself, mirroring PressHoldTests' timing proof: a keycmd
    /// with no hold_ms takes the compiled 40 ms default, and one that asks
    /// for zero returns immediately. The two bounds are 15 ms apart, well
    /// clear of scheduler noise.
    func testTheDefaultKeycmdSleepsFortyMsAndAnExplicitZeroDoesNot() throws {
        func elapsedMs(_ request: String) throws -> Double {
            let command = try bridgeJSONDecoder.decode(
                BridgeCommand.self, from: Data(request.utf8)
            )
            let started = Date()
            XCTAssertTrue(handleCommand(command).ok, request)
            return Date().timeIntervalSince(started) * 1000
        }
        XCTAssertGreaterThanOrEqual(try elapsedMs(#"{"cmd":"keycmd","note":104}"#), 35)
        XCTAssertLessThan(try elapsedMs(#"{"cmd":"keycmd","note":104,"hold_ms":0}"#), 25)
    }

    /// A hold explicitly requested still takes it, distinct from both the
    /// default and from zero.
    func testAnExplicitHoldIsHonoured() throws {
        let command = try bridgeJSONDecoder.decode(
            BridgeCommand.self, from: Data(#"{"cmd":"keycmd","note":104,"hold_ms":60}"#.utf8)
        )
        let started = Date()
        XCTAssertTrue(handleCommand(command).ok)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started) * 1000, 55)
    }

    /// The hold changes the timing and nothing else: the reply is the same
    /// object either way, so the wire format stays frozen.
    func testAHoldDoesNotChangeTheReply() throws {
        func reply(_ request: String) throws -> [String: Any] {
            let command = try bridgeJSONDecoder.decode(
                BridgeCommand.self, from: Data(request.utf8)
            )
            return try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: try bridgeJSONEncoder.encode(handleCommand(command))
                ) as? [String: Any]
            )
        }
        XCTAssertEqual(
            try reply(#"{"cmd":"keycmd","note":104,"hold_ms":0}"#) as NSDictionary,
            try reply(#"{"cmd":"keycmd","note":104}"#) as NSDictionary
        )
    }

    // MARK: - The environment override resolver

    /// Pure: no override string resolves to the historical 40 ms.
    func testNoOverrideResolvesToTheHistoricalDefault() {
        XCTAssertEqual(resolveKeycmdDefaultHoldMs(envOverride: nil), 40)
    }

    /// A valid override — including zero — replaces the compiled default.
    /// This is the lever `keycmd_hold_sweep.py` would use to change the
    /// daemon's default without touching every message, if a future sweep
    /// wants that instead of per-message hold_ms.
    func testAValidOverrideReplacesTheDefault() {
        XCTAssertEqual(resolveKeycmdDefaultHoldMs(envOverride: "0"), 0)
        XCTAssertEqual(resolveKeycmdDefaultHoldMs(envOverride: "20"), 20)
    }

    /// A malformed override is not a crash and not a wrong number — it is
    /// "no opinion", the same leniency every other field on this wire gets.
    func testAMalformedOverrideFallsBackToTheDefault() {
        XCTAssertEqual(resolveKeycmdDefaultHoldMs(envOverride: "fast"), 40)
        XCTAssertEqual(resolveKeycmdDefaultHoldMs(envOverride: ""), 40)
    }
}
