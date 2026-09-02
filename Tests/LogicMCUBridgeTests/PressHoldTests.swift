import XCTest
@testable import LogicMCUBridge

/// The button hold.
///
/// `pressButton` slept a flat 50 ms between its two note edges, and that sleep
/// was 99.4% of what a press cost the whole server — paid by `press`,
/// `select`, `mute`, `solo` and `vpot_press` alike, twelve times per mixer
/// census, with the daemon's global command lock held throughout. The live
/// sweep of 2026-09-02 found Logic honours the press at every hold from
/// ~0.2 ms to 50 ms, 16 transitions out of 16, with its echo landing 102-106 ms
/// later regardless. So the hold became a parameter that defaults to zero.
///
/// These tests hold three things: that zero really is the default, that the
/// field is ADDITIVE on the wire (an older daemon must be able to ignore it),
/// and that a caller who asks for a hold still gets one — because Logic
/// Control's long-press behaviours were never swept and `assign_send` is timed
/// on that promise.
///
/// No CoreMIDI endpoints exist in a test process, so the `send` calls inside
/// `pressButton` reach an invalid endpoint and put nothing on any wire.
final class PressHoldTests: XCTestCase {
    // MARK: - Zero is the default

    func testACommandThatSaysNothingAboutTheHoldAsksForNone() throws {
        let command = try bridgeJSONDecoder.decode(
            BridgeCommand.self, from: Data(#"{"cmd":"press","button":"bank_left"}"#.utf8)
        )
        XCTAssertNil(command.holdMs)
        XCTAssertEqual(command.pressHoldMs, 0)
    }

    func testTheFactoriesLeaveAZeroHoldOffTheWireEntirely() throws {
        func encoded(_ command: BridgeCommand) throws -> [String: Any] {
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: try bridgeJSONEncoder.encode(command))
                    as? [String: Any]
            )
        }
        // A default press is the three keys it has always been: a build that
        // does not need a hold must not start describing one.
        XCTAssertEqual(
            try encoded(.press(button: "bank_left")) as NSDictionary,
            ["cmd": "press", "button": "bank_left"]
        )
        XCTAssertEqual(
            try encoded(.press(note: 74)) as NSDictionary,
            ["cmd": "press", "note": 74]
        )
        XCTAssertEqual(
            try encoded(.press(button: "assign_send", holdMs: BridgeCommand.unsweptPressHoldMs))
                as NSDictionary,
            ["cmd": "press", "button": "assign_send", "hold_ms": 50]
        )
    }

    /// Additive means additive: the key is new, nothing else about a press
    /// moved, and a daemon that has never heard of it decodes the same command
    /// it always did. That is why this shipped without a protocol bump.
    func testHoldMsIsAnAdditiveFieldOnAnOtherwiseUnchangedCommand() throws {
        let withHold = try bridgeJSONDecoder.decode(
            BridgeCommand.self,
            from: Data(#"{"cmd":"press","button":"assign_send","hold_ms":50}"#.utf8)
        )
        XCTAssertEqual(withHold.cmd, "press")
        XCTAssertEqual(withHold.button, "assign_send")
        XCTAssertEqual(withHold.pressHoldMs, 50)

        var stripped = withHold
        stripped.holdMs = nil
        let old = try bridgeJSONDecoder.decode(
            BridgeCommand.self,
            from: Data(#"{"cmd":"press","button":"assign_send"}"#.utf8)
        )
        XCTAssertEqual(stripped, old)
    }

    /// Leniency, like every other field: a wrongly-typed hold is "no hold",
    /// not a thrown decode that would change the daemon's error message.
    func testAWronglyTypedHoldIsNoHold() throws {
        let command = try bridgeJSONDecoder.decode(
            BridgeCommand.self,
            from: Data(#"{"cmd":"press","button":"play","hold_ms":"long"}"#.utf8)
        )
        XCTAssertEqual(command.pressHoldMs, 0)
    }

    // MARK: - The ceiling

    /// A hold is time the daemon's global command lock is held, so it is time
    /// every OTHER client on this surface spends blocked. An agent cannot ask
    /// for a minute of it, and cannot ask for a negative one either.
    func testTheHoldIsClampedAtBothEnds() {
        var command = BridgeCommand(cmd: "press")
        command.holdMs = -5
        XCTAssertEqual(command.pressHoldMs, 0)
        command.holdMs = BridgeCommand.maxPressHoldMs + 60_000
        XCTAssertEqual(command.pressHoldMs, BridgeCommand.maxPressHoldMs)
        command.holdMs = 25
        XCTAssertEqual(command.pressHoldMs, 25)
    }

    // MARK: - What the daemon actually does with it

    /// The saving itself. A press with no hold must not sleep, and one that
    /// asks for a hold must still take it — the two bounds are 45 ms apart, so
    /// no plausible scheduler noise can make either read the other's answer.
    func testTheDefaultPressDoesNotSleepAndAnExplicitHoldStillDoes() {
        func elapsedMs(_ body: () -> Void) -> Double {
            let started = Date()
            body()
            return Date().timeIntervalSince(started) * 1000
        }

        XCTAssertLessThan(elapsedMs { pressButton(note: 0x2E) }, 25)
        XCTAssertGreaterThanOrEqual(
            elapsedMs { pressButton(note: 0x2E, holdMs: BridgeCommand.unsweptPressHoldMs) }, 45
        )
    }

    /// Every command that presses a button reads the hold from the same field,
    /// so `hold_ms` cannot mean one thing on `press` and another on `mute`.
    func testEveryButtonPressingCommandHonoursTheSameHold() throws {
        for request in [
            #"{"cmd":"press","note":46,"hold_ms":50}"#,
            #"{"cmd":"select","channel":0,"hold_ms":50}"#,
            #"{"cmd":"mute","channel":0,"hold_ms":50}"#,
            #"{"cmd":"solo","channel":0,"hold_ms":50}"#,
            #"{"cmd":"vpot_press","index":0,"hold_ms":50}"#
        ] {
            let command = try bridgeJSONDecoder.decode(
                BridgeCommand.self, from: Data(request.utf8)
            )
            let started = Date()
            XCTAssertTrue(handleCommand(command).ok, request)
            XCTAssertGreaterThanOrEqual(
                Date().timeIntervalSince(started) * 1000, 45, request
            )
        }
    }

    func testTheSameCommandsWithoutAHoldReturnImmediately() throws {
        for request in [
            #"{"cmd":"press","note":46}"#,
            #"{"cmd":"select","channel":0}"#,
            #"{"cmd":"mute","channel":0}"#,
            #"{"cmd":"solo","channel":0}"#,
            #"{"cmd":"vpot_press","index":0}"#
        ] {
            let command = try bridgeJSONDecoder.decode(
                BridgeCommand.self, from: Data(request.utf8)
            )
            let started = Date()
            XCTAssertTrue(handleCommand(command).ok, request)
            XCTAssertLessThan(Date().timeIntervalSince(started) * 1000, 25, request)
        }
    }

    /// The hold changes the timing and nothing else: the reply is the same
    /// object either way, which is what lets the wire format stay frozen.
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
            try reply(#"{"cmd":"press","button":"bank_left","hold_ms":50}"#) as NSDictionary,
            try reply(#"{"cmd":"press","button":"bank_left"}"#) as NSDictionary
        )
    }
}
