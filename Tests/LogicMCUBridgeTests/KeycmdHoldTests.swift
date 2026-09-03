import XCTest
@testable import LogicMCUBridge

/// The key-command hold — `pressButton`'s formerly-unswept sibling.
///
/// `keycmd` used to sleep a flat 40 ms between its note-on and note-off,
/// unnamed and unconfigurable, ~96% of `logic_trigger_key_command`'s 50-52 ms
/// wall clock (KEY-COMMANDS-REVIEW.md, 2026-09-03). The MCU button press hold
/// next to it was swept live 2026-09-02 (`bf511e5`) and its default dropped
/// to a measured 0 ms; a first pass here added the plumbing — a named
/// constant, settable per message and by an environment override — while
/// leaving the default at its historical 40 ms pending the key-command
/// plane's own sweep. That sweep has now run, live, 2026-09-03
/// (`keycmd_hold_sweep.py`, sandbox "Testlåt Copy"): firing
/// `Create Marker` at hold_ms 0, 1, 5, 10, 20 and 40, plus ten more fires at
/// 0, created exactly one marker every time — sixteen fires at 0 ms, sixteen
/// markers, zero duplicates, zero drops. The compiled default moves to that
/// measured 0 ms (`resolveKeycmdDefaultHoldMs`'s doc comment carries the
/// table). The ~0.2 ms point the button sweep also cleared is not reachable
/// through `hold_ms` (an `Int` count of milliseconds) and was not attempted.
///
/// These tests hold: that an absent hold_ms resolves to the DAEMON'S default
/// (not zero, unlike `pressHoldMs`, though the two now happen to agree at
/// 0 ms), that a caller who asks for a hold — including zero — gets exactly
/// that, that the field stays additive and lenient the same way `pressHoldMs`
/// is, that the ceiling still applies, and that the environment-override
/// resolver is a pure function of its input.
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

    /// The saving itself, mirroring PressHoldTests' timing proof: measured
    /// live 2026-09-03, the compiled default dropped from 40 ms to 0 ms, so
    /// a keycmd with no hold_ms now returns near-instantly, same as one that
    /// explicitly asks for zero — both stay well clear of the 35 ms an
    /// explicit hold below is asked to clear.
    func testTheDefaultKeycmdIsNearInstantAndAnExplicitHoldSleeps() throws {
        func elapsedMs(_ request: String) throws -> Double {
            let command = try bridgeJSONDecoder.decode(
                BridgeCommand.self, from: Data(request.utf8)
            )
            let started = Date()
            XCTAssertTrue(handleCommand(command).ok, request)
            return Date().timeIntervalSince(started) * 1000
        }
        XCTAssertLessThan(try elapsedMs(#"{"cmd":"keycmd","note":104}"#), 25)
        XCTAssertLessThan(try elapsedMs(#"{"cmd":"keycmd","note":104,"hold_ms":0}"#), 25)
        XCTAssertGreaterThanOrEqual(try elapsedMs(#"{"cmd":"keycmd","note":104,"hold_ms":40}"#), 35)
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

    /// Pure: no override string resolves to the measured default, 0 ms as
    /// of the 2026-09-03 sweep (was 40 ms before it).
    func testNoOverrideResolvesToTheMeasuredDefault() {
        XCTAssertEqual(resolveKeycmdDefaultHoldMs(envOverride: nil), 0)
    }

    /// A valid override — including a non-zero one — still replaces the
    /// compiled default. This is the lever the next sweep of some other
    /// surface would use to change the daemon's default without touching
    /// every message, instead of per-message hold_ms.
    func testAValidOverrideReplacesTheDefault() {
        XCTAssertEqual(resolveKeycmdDefaultHoldMs(envOverride: "0"), 0)
        XCTAssertEqual(resolveKeycmdDefaultHoldMs(envOverride: "20"), 20)
    }

    /// A malformed override is not a crash and not a wrong number — it is
    /// "no opinion", the same leniency every other field on this wire gets,
    /// and falls back to the same measured default an absent override does.
    func testAMalformedOverrideFallsBackToTheDefault() {
        XCTAssertEqual(resolveKeycmdDefaultHoldMs(envOverride: "fast"), 0)
        XCTAssertEqual(resolveKeycmdDefaultHoldMs(envOverride: ""), 0)
    }
}
