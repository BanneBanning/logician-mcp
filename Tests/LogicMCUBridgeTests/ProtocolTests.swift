import XCTest
@testable import LogicMCUBridge

/// The server ⇄ bridge wire format.
///
/// These types replaced `[String: Any]` on both sides of the socket, so the
/// thing worth pinning down is NOT that Swift can round-trip its own Codable
/// output — it is that the bytes still match what the untyped version wrote
/// and read. The daemon and the MCP server are separate processes that can be
/// at different versions during an upgrade, and the surface snapshot is also
/// the documented `logic_mcu_status` tool result.
///
/// So every test below either (a) decodes a literal captured from the OLD
/// dictionary-based format, or (b) encodes and compares against a literal.
/// A CodingKey rename fails here loudly instead of degrading into `?? -1`
/// three layers up.
final class ProtocolTests: XCTestCase {
    private func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try bridgeJSONEncoder.encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Snapshot

    /// Captured from the pre-typing daemon: `JSONSerialization` output of the
    /// dictionary that `snapshotObject()` built, with `.sortedKeys`. Every
    /// key and every JSON type here is load-bearing.
    private static let oldFormatSnapshot = """
    {"assignment":"PN",\
    "faders_14bit":[8192,-1,-1,-1,-1,-1,-1,-1,12000],\
    "last_receive":1756200000.5,\
    "lcd_bottom":"  0.0    -3.5   -oo                                    ",\
    "lcd_top":"Kick   Snare  Bass                                       ",\
    "leds_lit":[86,94],\
    "online":true,\
    "received_events":4211,\
    "timecode":"001 01 01 000",\
    "transport_leds":{"cycle":true,"forward":false,"play":true,"record":false,"rewind":false,"stop":false},\
    "updated":1756200001.25,\
    "vpot_rings":[0,1,2,3,4,5,6,7]}
    """

    func testDecodesASnapshotProducedByTheOldDictionaryFormat() throws {
        let data = Data(Self.oldFormatSnapshot.utf8)
        let snapshot = try bridgeJSONDecoder.decode(SurfaceSnapshot.self, from: data)

        XCTAssertEqual(snapshot.updated, 1756200001.25)
        XCTAssertEqual(snapshot.lastReceive, 1756200000.5)
        XCTAssertEqual(snapshot.receivedEvents, 4211)
        XCTAssertTrue(snapshot.online)
        XCTAssertTrue(snapshot.lcdTop.hasPrefix("Kick   Snare  Bass"))
        XCTAssertTrue(snapshot.lcdBottom.hasPrefix("  0.0    -3.5   -oo"))
        XCTAssertEqual(snapshot.timecode, "001 01 01 000")
        XCTAssertEqual(snapshot.assignment, "PN")
        XCTAssertEqual(snapshot.faders14bit, [8192, -1, -1, -1, -1, -1, -1, -1, 12000])
        XCTAssertEqual(snapshot.vpotRings, [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(snapshot.ledsLit, [86, 94])
        XCTAssertEqual(snapshot.transportLEDs["play"], true)
        XCTAssertEqual(snapshot.transportLEDs["cycle"], true)
        XCTAssertEqual(snapshot.transportLEDs["record"], false)
    }

    /// Re-encoding an old-format payload must reproduce every historical key
    /// BYTE for byte. This is the state.json guarantee: the file is read by
    /// whichever build happens to be running, and by the `logic_mcu_status`
    /// tool result.
    ///
    /// The check is per-key rather than whole-document because protocol 5 ADDS
    /// keys (the meter feed, G56), which is the one change the format allows —
    /// see the header comment. What must never happen is an existing key
    /// changing its spelling, its type, or its value on the way through, and
    /// that is what is asserted. `testSnapshotEncodesExactlyTheHistoricalKeys`
    /// pins the added keys themselves, so growth still cannot go unnoticed.
    func testReEncodingAnOldFormatSnapshotPreservesEveryHistoricalKey() throws {
        let original = Data(Self.oldFormatSnapshot.utf8)
        let snapshot = try bridgeJSONDecoder.decode(SurfaceSnapshot.self, from: original)
        let reencoded = try bridgeJSONEncoder.encode(snapshot)

        let before = try XCTUnwrap(
            JSONSerialization.jsonObject(with: original) as? [String: Any]
        )
        let after = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        )
        for (key, value) in before {
            XCTAssertNotNil(after[key], "historical key '\(key)' disappeared")
            XCTAssertEqual(
                String(describing: after[key] ?? "nil"), String(describing: value),
                "historical key '\(key)' changed on the way through"
            )
        }
        // Only the protocol-5 meter fields may be new.
        XCTAssertEqual(
            Set(after.keys).subtracting(before.keys),
            ["meter_levels", "meter_overloads", "meter_events"]
        )
    }

    /// ...and a CURRENT-format payload still round-trips byte for byte, which
    /// is the property state.json actually relies on day to day.
    func testReEncodingACurrentFormatSnapshotIsByteIdentical() throws {
        let snapshot = SurfaceSnapshot(
            updated: 1756200001.25, lastReceive: 1756200000.5, receivedEvents: 4211,
            online: true, lcdTop: "Kick", lcdBottom: "0.0", timecode: "001 01 01 000",
            assignment: "PN", faders14bit: [8192, -1], vpotRings: [0, 1],
            transportLEDs: ["play": true], ledsLit: [86, 94],
            meterLevels: [0, 12, -1, 4, 5, 6, 7, 8],
            meterOverloads: [false, true, false, false, false, false, false, false],
            meterEvents: 1234
        )
        let encoded = try bridgeJSONEncoder.encode(snapshot)
        let reencoded = try bridgeJSONEncoder.encode(
            try bridgeJSONDecoder.decode(SurfaceSnapshot.self, from: encoded)
        )
        XCTAssertEqual(
            String(data: reencoded, encoding: .utf8), String(data: encoded, encoding: .utf8)
        )
    }

    /// The key set is frozen. Adding one is fine; losing or renaming one is a
    /// protocol break that needs bridgeProtocolVersion bumped.
    func testSnapshotEncodesExactlyTheHistoricalKeys() throws {
        let snapshot = SurfaceSnapshot(
            updated: 1, lastReceive: 0, receivedEvents: 0, online: false,
            lcdTop: "", lcdBottom: "", timecode: "", assignment: "",
            faders14bit: [], vpotRings: [], transportLEDs: [:], ledsLit: []
        )
        XCTAssertEqual(Set(try encode(snapshot).keys), [
            "updated", "last_receive", "received_events", "online",
            "lcd_top", "lcd_bottom", "timecode", "assignment",
            "faders_14bit", "vpot_rings", "transport_leds", "leds_lit",
            // Added at protocol 5 (G56). Additive: an older SERVER reading a
            // newer daemon ignores them, an older DAEMON simply omits them.
            "meter_levels", "meter_overloads", "meter_events"
        ])
    }

    /// A `-1` fader (never reported by Logic) and a `0` timestamp must stay
    /// JSON numbers, not become strings or disappear.
    func testSnapshotPreservesSentinelValues() throws {
        let snapshot = SurfaceSnapshot(
            updated: 0, lastReceive: 0, receivedEvents: 0, online: false,
            lcdTop: "", lcdBottom: "", timecode: "", assignment: "",
            faders14bit: [Int](repeating: -1, count: 9), vpotRings: [Int](repeating: 0, count: 8),
            transportLEDs: [:], ledsLit: []
        )
        let json = String(data: try bridgeJSONEncoder.encode(snapshot), encoding: .utf8)
        XCTAssertEqual(json?.contains("\"last_receive\":0"), true)
        XCTAssertEqual(json?.contains("\"faders_14bit\":[-1,-1,-1,-1,-1,-1,-1,-1,-1]"), true)
    }

    // MARK: - Responses

    func testStatusResponseFlattensTheSnapshotAsItAlwaysDid() throws {
        var response = BridgeResponse.success
        response.midiStreaming = false
        response.snapshot = try bridgeJSONDecoder.decode(
            SurfaceSnapshot.self, from: Data(Self.oldFormatSnapshot.utf8)
        )
        let object = try encode(response)
        // Flat, NOT nested under a "snapshot" key.
        XCTAssertNil(object["snapshot"])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["midi_streaming"] as? Bool, false)
        XCTAssertEqual(object["received_events"] as? Int, 4211)
        XCTAssertEqual(object["assignment"] as? String, "PN")
    }

    func testStatusResponseRoundTrips() throws {
        var response = BridgeResponse.success
        response.midiStreaming = true
        response.snapshot = try bridgeJSONDecoder.decode(
            SurfaceSnapshot.self, from: Data(Self.oldFormatSnapshot.utf8)
        )
        let data = try bridgeJSONEncoder.encode(response)
        XCTAssertEqual(try bridgeJSONDecoder.decode(BridgeResponse.self, from: data), response)
    }

    /// A ping reply from an OLD daemon, verbatim. `ensureRunning()` reads
    /// `bridge_protocol` off this to decide whether to replace the daemon —
    /// a miss there silently downgrades to "0" and kills a healthy bridge.
    func testDecodesTheOldPingReply() throws {
        let data = Data(#"{"ok":true,"pong":true,"bridge_protocol":3}"#.utf8)
        let response = try bridgeJSONDecoder.decode(BridgeResponse.self, from: data)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.pong, true)
        // The fixture is a version-3 daemon's reply, and it stays one: what
        // this test proves is that the field ARRIVES, not that it happens to
        // match today's constant. Pinning it to `bridgeProtocolVersion` made
        // the test fail on every bump — the one moment the decode matters
        // most, since that is when `ensureRunning()` starts replacing daemons.
        XCTAssertEqual(response.bridgeProtocol, 3)
        XCTAssertGreaterThanOrEqual(bridgeProtocolVersion, 3)
        XCTAssertNil(response.snapshot) // no snapshot keys in a ping
    }

    func testDecodesTheOldConvergeReply() throws {
        let data = Data("""
        {"ok":true,"final_text":"-6.0","final_value":-6,"iterations":4,"ratio":2.5}
        """.utf8)
        let response = try bridgeJSONDecoder.decode(BridgeResponse.self, from: data)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.finalText, "-6.0")
        // -6 arrives as a JSON integer; the old reader did `as? Double` on an
        // NSNumber and got -6.0, so the typed reader must too.
        XCTAssertEqual(response.finalValue, -6.0)
        XCTAssertEqual(response.iterations, 4)
        XCTAssertEqual(response.ratio, 2.5)
    }

    func testDecodesTheOldMidiStreamAndKeycmdReplies() throws {
        let stream = try bridgeJSONDecoder.decode(
            BridgeResponse.self, from: Data(#"{"ok":true,"events":128,"duration_ms":7500}"#.utf8)
        )
        XCTAssertEqual(stream.eventCount, 128)
        XCTAssertEqual(stream.durationMs, 7500)

        let keycmd = try bridgeJSONDecoder.decode(
            BridgeResponse.self, from: Data(#"{"ok":true,"sent_note":24,"channel":16}"#.utf8)
        )
        XCTAssertEqual(keycmd.sentNote, 24)
        XCTAssertEqual(keycmd.channel, 16)

        let press = try bridgeJSONDecoder.decode(
            BridgeResponse.self, from: Data(#"{"ok":true,"pressed":"play"}"#.utf8)
        )
        XCTAssertEqual(press.pressed, "play")

        let pressNote = try bridgeJSONDecoder.decode(
            BridgeResponse.self, from: Data(#"{"ok":true,"pressed_note":94}"#.utf8)
        )
        XCTAssertEqual(pressNote.pressedNote, 94)
    }

    func testDecodesTheOldFailureReply() throws {
        let data = Data(#"{"ok":false,"error":"channel 0-7 required"}"#.utf8)
        let response = try bridgeJSONDecoder.decode(BridgeResponse.self, from: data)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "channel 0-7 required")
    }

    /// Forward skew: a NEWER daemon adds a key we do not model. The reply must
    /// still decode rather than throwing and being reported as "no response".
    func testIgnoresUnknownKeysFromANewerDaemon() throws {
        let data = Data(#"{"ok":true,"pong":true,"bridge_protocol":9,"future_field":[1,2]}"#.utf8)
        let response = try bridgeJSONDecoder.decode(BridgeResponse.self, from: data)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.bridgeProtocol, 9)
    }

    /// A failure reply carries no `pressed`/`snapshot`/etc, and encoding must
    /// OMIT them rather than emitting nulls: an older daemon's `as?` reads
    /// treat null and missing alike, but nothing guarantees a future one will.
    func testAbsentFieldsAreOmittedNotNulled() throws {
        let object = try encode(BridgeResponse.failure("missing cmd"))
        XCTAssertEqual(Set(object.keys), ["ok", "error"])
    }

    // MARK: - Commands

    func testCommandFactoriesProduceTheHistoricalWireObjects() throws {
        XCTAssertEqual(try encode(BridgeCommand.ping) as NSDictionary, ["cmd": "ping"])
        XCTAssertEqual(try encode(BridgeCommand.status) as NSDictionary, ["cmd": "status"])
        XCTAssertEqual(try encode(BridgeCommand.midiAbort) as NSDictionary, ["cmd": "midi_abort"])
        XCTAssertEqual(
            try encode(BridgeCommand.press(button: "play")) as NSDictionary,
            ["cmd": "press", "button": "play"]
        )
        XCTAssertEqual(
            try encode(BridgeCommand.press(note: 74)) as NSDictionary,
            ["cmd": "press", "note": 74]
        )
        XCTAssertEqual(
            try encode(BridgeCommand.channel(.mute, 3)) as NSDictionary,
            ["cmd": "mute", "channel": 3]
        )
        XCTAssertEqual(
            try encode(BridgeCommand.vpotPress(index: 5)) as NSDictionary,
            ["cmd": "vpot_press", "index": 5]
        )
        XCTAssertEqual(
            try encode(BridgeCommand.fader(channel: 2, value: 8192)) as NSDictionary,
            ["cmd": "fader", "channel": 2, "value": 8192]
        )
        XCTAssertEqual(
            try encode(BridgeCommand.vpot(index: 1, delta: -12)) as NSDictionary,
            ["cmd": "vpot", "index": 1, "delta": -12]
        )
        XCTAssertEqual(
            try encode(BridgeCommand.awaitEvents(since: 41, timeoutMs: 350)) as NSDictionary,
            ["cmd": "await", "since": 41, "timeout_ms": 350]
        )
        XCTAssertEqual(
            try encode(BridgeCommand.keycmd(note: 24, channel: 16)) as NSDictionary,
            ["cmd": "keycmd", "note": 24, "channel": 16]
        )
        XCTAssertEqual(
            try encode(BridgeCommand.raw(bytes: [0x90, 0x5E, 0x7F])) as NSDictionary,
            ["cmd": "raw", "bytes": [144, 94, 127]]
        )
    }

    /// `field` and `ratio` are optional on the wire because the bridge
    /// defaults them (field = index, ratio = 2.0). Sending a placeholder
    /// would silently override those defaults, so absent must mean absent.
    func testConvergeOmitsUnsetOptionalArguments() throws {
        let lean = try encode(BridgeCommand.converge(
            index: 4, field: nil, target: -6, tolerance: 0, maxMs: 3000, ratio: nil
        ))
        XCTAssertEqual(Set(lean.keys), ["cmd", "index", "target", "tolerance", "max_ms"])

        let full = try encode(BridgeCommand.converge(
            index: 4, field: 2, target: -6.5, tolerance: 0.1, maxMs: 4000, ratio: 3.25
        ))
        XCTAssertEqual(full as NSDictionary, [
            "cmd": "converge", "index": 4, "field": 2, "target": -6.5,
            "tolerance": 0.1, "max_ms": 4000, "ratio": 3.25
        ])
    }

    func testCommandRoundTrips() throws {
        for command in [
            BridgeCommand.ping,
            .status,
            .press(button: "stop"),
            .press(note: 74),
            .channel(.solo, 7),
            .fader(channel: 8, value: 0),
            .vpot(index: 0, delta: 60),
            .awaitEvents(since: -1, timeoutMs: 500),
            .converge(index: 3, field: 3, target: 0.5, tolerance: 0, maxMs: 15000, ratio: nil),
            .keycmd(note: 127, channel: 1),
            .raw(bytes: [0xF0, 0x00, 0xF7]),
            .midiStream(events: [MIDIStreamEvent(offsetMs: 0, bytes: [0x90, 0x3C, 0x64])])
        ] {
            let data = try bridgeJSONEncoder.encode(command)
            XCTAssertEqual(try bridgeJSONDecoder.decode(BridgeCommand.self, from: data), command)
        }
    }

    /// The daemon has to keep answering "unknown cmd X", which means an
    /// unrecognised name must DECODE rather than fail. `cmd` is therefore a
    /// raw String and `name` is the typed view of it.
    func testUnknownCommandNameStillDecodes() throws {
        let command = try bridgeJSONDecoder.decode(
            BridgeCommand.self, from: Data(#"{"cmd":"teleport","index":2}"#.utf8)
        )
        XCTAssertEqual(command.cmd, "teleport")
        XCTAssertNil(command.name)
        XCTAssertEqual(handleCommand(command).error, "unknown cmd teleport")
    }

    func testMissingCommandNameKeepsItsOwnErrorMessage() throws {
        let command = try bridgeJSONDecoder.decode(BridgeCommand.self, from: Data("{}".utf8))
        XCTAssertNil(command.cmd)
        XCTAssertEqual(handleCommand(command).error, "missing cmd")
    }

    /// The old daemon read every argument with `as?`, so a wrongly-typed
    /// value became nil and fell into the handler's OWN validation message.
    /// Strict Codable would have thrown instead, turning "index 0-7 and delta
    /// required" into "invalid JSON". Leniency keeps the old message.
    func testAWronglyTypedArgumentDegradesToNilNotToADecodeFailure() throws {
        let command = try bridgeJSONDecoder.decode(
            BridgeCommand.self, from: Data(#"{"cmd":"vpot","index":"two","delta":4}"#.utf8)
        )
        XCTAssertEqual(command.cmd, "vpot")
        XCTAssertNil(command.index)
        XCTAssertEqual(command.delta, 4)
        XCTAssertEqual(handleCommand(command).error, "index 0-7 and delta required")
    }

    // MARK: - midi_stream events

    func testMidiStreamEventsTravelAsFlatArrays() throws {
        let command = BridgeCommand.midiStream(events: [
            MIDIStreamEvent(offsetMs: 0, bytes: [0x90, 0x3C, 0x64]),
            MIDIStreamEvent(offsetMs: 1250.5, bytes: [0x80, 0x3C, 0x00])
        ])
        let json = String(data: try bridgeJSONEncoder.encode(command), encoding: .utf8)
        XCTAssertEqual(
            json,
            #"{"cmd":"midi_stream","events":[[0,144,60,100],[1250.5,128,60,0]]}"#
        )
    }

    func testDecodesOldFormatMidiStreamEvents() throws {
        // Integer and fractional offsets, exactly as JSONSerialization wrote
        // them from `[Double] + [Int]`.
        let command = try bridgeJSONDecoder.decode(BridgeCommand.self, from: Data(
            #"{"cmd":"midi_stream","events":[[0,144,60,100],[1250.5,128,60,0]]}"#.utf8
        ))
        let events = try XCTUnwrap(command.events)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].offsetMs, 0)
        XCTAssertEqual(events[0].bytes, [144, 60, 100])
        XCTAssertEqual(events[1].offsetMs, 1250.5)
        XCTAssertEqual(events[1].bytes, [128, 60, 0])
    }

    /// A byte out of range, a fractional byte and a non-numeric element each
    /// have their own error message in the daemon, so the decoder must hand
    /// all three through instead of rejecting them itself.
    func testMalformedStreamEventsReachTheDaemonsOwnValidation() throws {
        let outOfRange = try bridgeJSONDecoder.decode(BridgeCommand.self, from: Data(
            #"{"cmd":"midi_stream","events":[[0,144,300]]}"#.utf8
        ))
        XCTAssertEqual(handleCommand(outOfRange).error, "event bytes must be 0-255")

        let fractionalByte = try bridgeJSONDecoder.decode(BridgeCommand.self, from: Data(
            #"{"cmd":"midi_stream","events":[[0,144,60.5]]}"#.utf8
        ))
        XCTAssertEqual(handleCommand(fractionalByte).error, "event bytes must be 0-255")

        let negativeOffset = try bridgeJSONDecoder.decode(BridgeCommand.self, from: Data(
            #"{"cmd":"midi_stream","events":[[-5,144,60]]}"#.utf8
        ))
        XCTAssertEqual(
            handleCommand(negativeOffset).error, "each event needs [offset_ms >= 0, byte, ...]"
        )

        let tooShort = try bridgeJSONDecoder.decode(BridgeCommand.self, from: Data(
            #"{"cmd":"midi_stream","events":[[0]]}"#.utf8
        ))
        XCTAssertEqual(
            handleCommand(tooShort).error, "each event needs [offset_ms >= 0, byte, ...]"
        )

        // A string element keeps its slot, so the count check still sees two
        // elements and the offset check is what reports the problem.
        let nonNumeric = try bridgeJSONDecoder.decode(BridgeCommand.self, from: Data(
            #"{"cmd":"midi_stream","events":[["soon",144]]}"#.utf8
        ))
        XCTAssertEqual(try XCTUnwrap(nonNumeric.events)[0].elements.count, 2)
        XCTAssertEqual(
            handleCommand(nonNumeric).error, "each event needs [offset_ms >= 0, byte, ...]"
        )

        let empty = try bridgeJSONDecoder.decode(BridgeCommand.self, from: Data(
            #"{"cmd":"midi_stream","events":[]}"#.utf8
        ))
        XCTAssertEqual(
            handleCommand(empty).error, "events required: [[offset_ms, byte, ...], ...]"
        )
    }

    // MARK: - Daemon replies, end to end through the coders

    /// The exact path the socket takes: decode a request the old server would
    /// have sent, run the handler, encode the reply. Only the commands with
    /// no MIDI side effect are exercised here; the rest are covered by
    /// scripts/verify-bridge-wire-format.sh against a live daemon.
    func testHandlerRepliesEncodeToTheHistoricalShapes() throws {
        func reply(_ request: String) throws -> [String: Any] {
            let command = try bridgeJSONDecoder.decode(
                BridgeCommand.self, from: Data(request.utf8)
            )
            let data = try bridgeJSONEncoder.encode(handleCommand(command))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        XCTAssertEqual(try reply(#"{"cmd":"ping"}"#) as NSDictionary, [
            "ok": true, "pong": true, "bridge_protocol": bridgeProtocolVersion
        ])
        XCTAssertEqual(try reply(#"{"cmd":"select"}"#) as NSDictionary, [
            "ok": false, "error": "channel 0-7 required"
        ])
        XCTAssertEqual(try reply(#"{"cmd":"fader","channel":9,"value":0}"#) as NSDictionary, [
            "ok": false, "error": "channel 0-8 and value (14-bit) required"
        ])
        XCTAssertEqual(try reply(#"{"cmd":"raw","bytes":[144,94,999]}"#) as NSDictionary, [
            "ok": false, "error": "bytes array required"
        ])
        XCTAssertEqual(try reply(#"{"cmd":"press"}"#)["error"] as? String,
                       "unknown button; known: assign_eq,assign_instrument,assign_pan,"
                       + "assign_plugin,assign_send,assign_track,bank_left,bank_right,"
                       + "channel_left,channel_right,click,cycle,drop,flip,forward,"
                       + "global_view,marker,name_value,nudge,play,record,replace,rewind,"
                       + "smpte_beats,solo_global,stop")

        // status carries the flattened snapshot plus its two own keys.
        let status = try reply(#"{"cmd":"status"}"#)
        XCTAssertEqual(status["ok"] as? Bool, true)
        XCTAssertNotNil(status["midi_streaming"] as? Bool)
        XCTAssertNotNil(status["lcd_top"] as? String)
        XCTAssertNotNil(status["received_events"] as? Int)
        XCTAssertNotNil((status["transport_leds"] as? [String: Bool])?["play"])
    }
}
