// The typed vocabulary of the server ⇄ bridge command channel.
//
// Both the MCP server and the bridge daemon import this module, so these
// types are compiled ONCE and checked on both sides. Before this file the
// channel was `[String: Any]` end to end: the daemon read `object["index"]
// as? Int` and the server read `response["final_value"] as? Double`, and a
// typo or a rename on either side degraded silently into a default value —
// `?? -1`, `?? false`, `?? 0` — instead of failing. Nothing crashed; the
// surface just quietly stopped converging.
//
// WIRE FORMAT IS FROZEN. The daemon and the server are separate processes
// that can be at different versions during an upgrade, and the surface
// snapshot is also the documented result of the `logic_mcu_status` tool.
// So every property here carries an explicit snake_case CodingKey matching
// the historical dictionary key exactly, and the encoders below use
// `.sortedKeys` so the bytes are deterministic. Adding a property is safe;
// renaming a CodingKey is a protocol break and needs bridgeProtocolVersion
// (Framing.swift) bumped.
//
// Decoding is DELIBERATELY LENIENT (see `lenient` below). The dictionary
// version used `as?`, which turns both "key absent" and "key present with
// the wrong type" into nil; strict Codable turns the second case into a
// thrown error that would have aborted the whole command with a different
// message. Leniency keeps the observable behaviour — including the exact
// error strings the daemon returns — identical.

import Foundation

// MARK: - Shared coders

/// `.sortedKeys` is what makes the output byte-deterministic. The old code
/// used it for state.json and left the socket replies in hash order; sorting
/// both is a superset of the previous guarantees (same keys, same types,
/// same values, and now a stable order too).
public let bridgeJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

public let bridgeJSONDecoder = JSONDecoder()

private extension KeyedDecodingContainer {
    /// `as?` semantics: a missing key AND a wrongly-typed value both yield
    /// nil. Reproduces exactly what `object["x"] as? T` did, so a malformed
    /// field still reaches the handler's own validation and gets the handler's
    /// own error message rather than a generic decode failure.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

// MARK: - Commands (server → bridge)

/// The command vocabulary. `BridgeCommand.cmd` stays a raw `String` rather
/// than this enum: an unrecognised name has to reach the daemon's default
/// branch so it can answer "unknown cmd X" the way it always did, instead of
/// failing to decode and answering "missing cmd".
public enum BridgeCommandName: String, Sendable, CaseIterable {
    case press
    case select
    case mute
    case solo
    case vpotPress = "vpot_press"
    case fader
    case vpot
    case raw
    case status
    case awaitEvents = "await"
    case converge
    case midiStream = "midi_stream"
    case midiAbort = "midi_abort"
    case keycmd
    case ping

    /// Whether the DAEMON puts bytes on a MIDI port for this command.
    ///
    /// This is the property the server's "did we touch the user's control
    /// surface?" flag is actually about, and it is answered here, next to the
    /// vocabulary, by an EXHAUSTIVE switch with no `default`: adding a case
    /// above is a compile error until someone says which side it belongs on.
    /// The previous answer was a name list of one (`!= .ping`) kept at the
    /// socket boundary, which is why `status` — a command the daemon serves
    /// out of its own snapshot with no MIDI at all (Bridge.swift, `case
    /// .status`) — counted as a touch and made a `readOnly` diagnostic press
    /// PAN on the way out (measured 2026-09-02: +145 ms and a real surface
    /// write when the user's view was not PN).
    ///
    /// The three false answers are read-shaped by construction: `ping`
    /// replies `pong`, `status` returns `state.snapshot()`, and `await`
    /// blocks until Logic sends something. Everything else either presses a
    /// button, moves a fader or vpot, or writes raw bytes to one of the three
    /// ports — `midi_stream` and `midi_abort` included, which reach Logic on
    /// the performance port rather than the surface: the flag's contract is
    /// "MIDI left this process", and a stuck-note abort is not a read.
    public var emitsMIDI: Bool {
        switch self {
        case .press, .select, .mute, .solo, .vpotPress, .fader, .vpot, .raw,
             .converge, .midiStream, .midiAbort, .keycmd:
            return true
        case .status, .awaitEvents, .ping:
            return false
        }
    }
}

/// One `midi_stream` event, on the wire as a flat array:
/// `[offset_ms, byte, byte, …]`.
///
/// The elements are kept as raw optional numbers instead of a validated
/// `(Double, [UInt8])` pair on purpose: the daemon distinguishes "too few
/// elements", "bad offset" and "byte out of range" with three different error
/// strings, so the decoder must hand it everything that arrived, including
/// the non-numeric elements (nil here), and let it judge.
public struct MIDIStreamEvent: Codable, Sendable, Equatable {
    public var elements: [Double?]

    public init(offsetMs: Double, bytes: [UInt8]) {
        elements = [offsetMs] + bytes.map(Double.init)
    }

    public init(elements: [Double?]) {
        self.elements = elements
    }

    /// Element 0, when it is a number.
    public var offsetMs: Double? { elements.first ?? nil }

    /// Elements 1…n as bytes, or nil when any of them is not an integer in
    /// 0...255 — matching the old `raw[i] as? Int` + range check, where
    /// NSNumber bridging accepted an integral double and rejected 94.5.
    public var bytes: [UInt8]? {
        var result: [UInt8] = []
        for element in elements.dropFirst() {
            guard let element, let byte = UInt8(exactly: element) else { return nil }
            result.append(byte)
        }
        return result
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Double?] = []
        while !container.isAtEnd {
            if let number = try? container.decode(Double.self) {
                values.append(number)
            } else {
                // Skip the element without losing its slot: the count is what
                // the "each event needs [offset_ms >= 0, byte, ...]" check
                // reads, so a string element must still occupy a position.
                _ = try? container.decode(AnyIgnored.self)
                values.append(nil)
            }
        }
        elements = values
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for (position, element) in elements.enumerated() {
            guard let element else { try container.encodeNil(); continue }
            // Offset is a JSON number (it was a Swift Double before); the
            // bytes were Ints. Both serialise identically for integral
            // values, but keeping the split means a fractional offset still
            // travels as 1234.5 rather than being truncated.
            if position > 0, let byte = Int(exactly: element) {
                try container.encode(byte)
            } else {
                try container.encode(element)
            }
        }
    }
}

/// Decodes and discards any JSON value, so an unkeyed container can step
/// past an element it could not interpret.
private struct AnyIgnored: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        if (try? container.decode(Bool.self)) != nil { return }
        if (try? container.decode(String.self)) != nil { return }
        if (try? container.decode([Double?].self)) != nil { return }
        _ = try? container.decode([String: String].self)
    }
}

/// Every field any bridge command can carry, in one struct.
///
/// A per-command enum with associated values would be tidier Swift but a
/// worse fit for the wire: the daemon has to accept a partially-specified
/// command and answer with its own "channel 0-7 required" style message, and
/// the `logic_mcu_command` tool forwards agent-authored objects. Optional
/// fields plus handler-side validation keep both of those intact while still
/// making every key a compiler-checked identifier at every construction site.
public struct BridgeCommand: Codable, Sendable, Equatable {
    public var cmd: String?
    public var button: String?
    public var note: Int?
    public var channel: Int?
    public var index: Int?
    public var delta: Int?
    public var value: Int?
    public var bytes: [Int]?
    public var since: Int?
    public var timeoutMs: Int?
    public var target: Double?
    public var field: Int?
    public var maxMs: Int?
    public var tolerance: Double?
    public var ratio: Double?
    public var events: [MIDIStreamEvent]?
    /// `fader` only: wait for Logic's own echo and report what it settled on.
    /// Off by default because the automation recorder fires faders on a
    /// musical clock and cannot afford the wait.
    public var verify: Bool?

    enum CodingKeys: String, CodingKey {
        case cmd, button, note, channel, index, delta, value, bytes, since
        case timeoutMs = "timeout_ms"
        case target, field
        case maxMs = "max_ms"
        case tolerance, ratio, events, verify
    }

    public init(cmd: String?) { self.cmd = cmd }

    public var name: BridgeCommandName? { cmd.flatMap(BridgeCommandName.init(rawValue:)) }

    /// See `BridgeCommandName.emitsMIDI`. A command this build does not model
    /// counts as one that emits: today's daemon answers "unknown cmd" and
    /// sends nothing, but `logic_mcu_command` forwards agent-authored objects
    /// verbatim and the daemon can be a NEWER build than this server, so the
    /// unknown case is the one where guessing "read-only" would silently skip
    /// a restore the user needed.
    public var emitsMIDI: Bool { name?.emitsMIDI ?? true }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cmd = container.lenient(String.self, .cmd)
        button = container.lenient(String.self, .button)
        note = container.lenient(Int.self, .note)
        channel = container.lenient(Int.self, .channel)
        index = container.lenient(Int.self, .index)
        delta = container.lenient(Int.self, .delta)
        value = container.lenient(Int.self, .value)
        bytes = container.lenient([Int].self, .bytes)
        since = container.lenient(Int.self, .since)
        timeoutMs = container.lenient(Int.self, .timeoutMs)
        target = container.lenient(Double.self, .target)
        field = container.lenient(Int.self, .field)
        maxMs = container.lenient(Int.self, .maxMs)
        tolerance = container.lenient(Double.self, .tolerance)
        ratio = container.lenient(Double.self, .ratio)
        events = container.lenient([MIDIStreamEvent].self, .events)
        verify = container.lenient(Bool.self, .verify)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // encodeIfPresent throughout: an absent field must stay ABSENT on the
        // wire, not become null. The daemon's `as?` reads treat null and
        // missing the same way, but an older daemon's may not.
        try container.encodeIfPresent(cmd, forKey: .cmd)
        try container.encodeIfPresent(button, forKey: .button)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(channel, forKey: .channel)
        try container.encodeIfPresent(index, forKey: .index)
        try container.encodeIfPresent(delta, forKey: .delta)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(bytes, forKey: .bytes)
        try container.encodeIfPresent(since, forKey: .since)
        try container.encodeIfPresent(timeoutMs, forKey: .timeoutMs)
        try container.encodeIfPresent(target, forKey: .target)
        try container.encodeIfPresent(field, forKey: .field)
        try container.encodeIfPresent(maxMs, forKey: .maxMs)
        try container.encodeIfPresent(tolerance, forKey: .tolerance)
        try container.encodeIfPresent(ratio, forKey: .ratio)
        try container.encodeIfPresent(events, forKey: .events)
        try container.encodeIfPresent(verify, forKey: .verify)
    }
}

public extension BridgeCommand {
    static let ping = BridgeCommand(cmd: BridgeCommandName.ping.rawValue)
    static let status = BridgeCommand(cmd: BridgeCommandName.status.rawValue)
    static let midiAbort = BridgeCommand(cmd: BridgeCommandName.midiAbort.rawValue)

    static func press(button: String) -> BridgeCommand {
        var command = BridgeCommand(cmd: BridgeCommandName.press.rawValue)
        command.button = button
        return command
    }

    static func press(note: Int) -> BridgeCommand {
        var command = BridgeCommand(cmd: BridgeCommandName.press.rawValue)
        command.note = note
        return command
    }

    /// `select` / `mute` / `solo` — the three commands whose only argument is
    /// a channel strip.
    static func channel(_ name: BridgeCommandName, _ channel: Int) -> BridgeCommand {
        var command = BridgeCommand(cmd: name.rawValue)
        command.channel = channel
        return command
    }

    static func vpotPress(index: Int) -> BridgeCommand {
        var command = BridgeCommand(cmd: BridgeCommandName.vpotPress.rawValue)
        command.index = index
        return command
    }

    /// `verify: true` costs up to ~400 ms waiting for Logic's echo and fills
    /// in `finalValue`/`followed`. The automation recorder leaves it off: it
    /// places faders against a musical clock, where the wait would be the
    /// error. Everything that writes a fader OUTSIDE real time should set it.
    static func fader(channel: Int, value: Int, verify: Bool = false) -> BridgeCommand {
        var command = BridgeCommand(cmd: BridgeCommandName.fader.rawValue)
        command.channel = channel
        command.value = value
        if verify { command.verify = true }
        return command
    }

    static func vpot(index: Int, delta: Int) -> BridgeCommand {
        var command = BridgeCommand(cmd: BridgeCommandName.vpot.rawValue)
        command.index = index
        command.delta = delta
        return command
    }

    static func raw(bytes: [Int]) -> BridgeCommand {
        var command = BridgeCommand(cmd: BridgeCommandName.raw.rawValue)
        command.bytes = bytes
        return command
    }

    static func awaitEvents(since: Int, timeoutMs: Int) -> BridgeCommand {
        var command = BridgeCommand(cmd: BridgeCommandName.awaitEvents.rawValue)
        command.since = since
        command.timeoutMs = timeoutMs
        return command
    }

    static func converge(
        index: Int, field: Int?, target: Double,
        tolerance: Double, maxMs: Int, ratio: Double?
    ) -> BridgeCommand {
        var command = BridgeCommand(cmd: BridgeCommandName.converge.rawValue)
        command.index = index
        command.field = field
        command.target = target
        command.tolerance = tolerance
        command.maxMs = maxMs
        command.ratio = ratio
        return command
    }

    static func midiStream(events: [MIDIStreamEvent]) -> BridgeCommand {
        var command = BridgeCommand(cmd: BridgeCommandName.midiStream.rawValue)
        command.events = events
        return command
    }

    static func keycmd(note: Int, channel: Int) -> BridgeCommand {
        var command = BridgeCommand(cmd: BridgeCommandName.keycmd.rawValue)
        command.note = note
        command.channel = channel
        return command
    }
}

// MARK: - Surface snapshot

/// The mirrored state of the Mackie Control surface.
///
/// This is both the `status`/`await` reply body and the entire contents of
/// state.json, and it is handed to agents verbatim as the `logic_mcu_status`
/// tool result — three consumers, one shape. Every field was previously read
/// as `status["lcd_top"] as? String`, which is why a renamed key showed up as
/// an empty LCD rather than an error.
public struct SurfaceSnapshot: Codable, Sendable, Equatable {
    /// When this snapshot was taken (unix seconds). Used by the server to
    /// decide whether the state FILE is stale enough to mean "bridge dead".
    public var updated: Double
    /// When Logic last sent us anything (unix seconds), 0 if never.
    public var lastReceive: Double
    /// Monotonic count of MIDI events received from Logic. The `await`
    /// command's `since` argument is a value of this counter.
    public var receivedEvents: Int
    /// Traffic within the last 10 s AND at least one event ever.
    public var online: Bool
    /// Row 1 of the LCD: 8 × 7 characters, channel names.
    public var lcdTop: String
    /// Row 2 of the LCD: 8 × 7 characters, the values every converge loop
    /// parses.
    public var lcdBottom: String
    /// The 10-digit 7-segment display (bars/beats or SMPTE).
    public var timecode: String
    /// The 2-digit assignment display: "PN", "IN", "EQ", …
    public var assignment: String
    /// 9 faders (8 strips + master) as 14-bit values; -1 = never reported.
    public var faders14bit: [Int]
    /// 8 vpot ring values as sent by Logic.
    public var vpotRings: [Int]
    /// The transport LEDs by name, so callers do not need the note numbers.
    public var transportLEDs: [String: Bool]
    /// Every lit button LED by note number, sorted.
    public var ledsLit: [Int]
    /// Logic's own per-strip meter segment (0...12), bank-relative, -1 where
    /// Logic has never reported one. NOT an audio measurement — see MCUMeter.
    /// Empty from a daemon older than protocol 5, which discarded the bytes.
    public var meterLevels: [Int]
    /// Logic's own per-strip overload flag, bank-relative. Empty from a
    /// daemon older than protocol 5.
    public var meterOverloads: [Bool]
    /// How many meter messages the daemon has decoded. 0 across a stretch of
    /// playback means Logic does not feed this surface meters at all.
    public var meterEvents: Int

    enum CodingKeys: String, CodingKey {
        case updated
        case lastReceive = "last_receive"
        case receivedEvents = "received_events"
        case online
        case lcdTop = "lcd_top"
        case lcdBottom = "lcd_bottom"
        case timecode
        case assignment
        case faders14bit = "faders_14bit"
        case vpotRings = "vpot_rings"
        case transportLEDs = "transport_leds"
        case ledsLit = "leds_lit"
        case meterLevels = "meter_levels"
        case meterOverloads = "meter_overloads"
        case meterEvents = "meter_events"
    }

    public init(
        updated: Double, lastReceive: Double, receivedEvents: Int, online: Bool,
        lcdTop: String, lcdBottom: String, timecode: String, assignment: String,
        faders14bit: [Int], vpotRings: [Int],
        transportLEDs: [String: Bool], ledsLit: [Int],
        meterLevels: [Int] = [], meterOverloads: [Bool] = [], meterEvents: Int = 0
    ) {
        self.updated = updated
        self.lastReceive = lastReceive
        self.receivedEvents = receivedEvents
        self.online = online
        self.lcdTop = lcdTop
        self.lcdBottom = lcdBottom
        self.timecode = timecode
        self.assignment = assignment
        self.faders14bit = faders14bit
        self.vpotRings = vpotRings
        self.transportLEDs = transportLEDs
        self.ledsLit = ledsLit
        self.meterLevels = meterLevels
        self.meterOverloads = meterOverloads
        self.meterEvents = meterEvents
    }

    /// Hand-written so the three meter fields, added at protocol 5, DEFAULT
    /// instead of throwing when the JSON comes from an older daemon.
    ///
    /// This matters more than it looks. `BridgeResponse` decodes the snapshot
    /// as `try? SurfaceSnapshot(from: decoder)`, so a single missing key does
    /// not degrade to "no meters" — it degrades to NO SNAPSHOT AT ALL, and
    /// every LCD read, fader read and LED read in the server would come back
    /// empty against a daemon one version behind. The synthesized decoder
    /// would have done exactly that. Everything that existed before protocol 5
    /// stays REQUIRED, so a genuinely malformed reply still fails loudly.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updated = try container.decode(Double.self, forKey: .updated)
        lastReceive = try container.decode(Double.self, forKey: .lastReceive)
        receivedEvents = try container.decode(Int.self, forKey: .receivedEvents)
        online = try container.decode(Bool.self, forKey: .online)
        lcdTop = try container.decode(String.self, forKey: .lcdTop)
        lcdBottom = try container.decode(String.self, forKey: .lcdBottom)
        timecode = try container.decode(String.self, forKey: .timecode)
        assignment = try container.decode(String.self, forKey: .assignment)
        faders14bit = try container.decode([Int].self, forKey: .faders14bit)
        vpotRings = try container.decode([Int].self, forKey: .vpotRings)
        transportLEDs = try container.decode([String: Bool].self, forKey: .transportLEDs)
        ledsLit = try container.decode([Int].self, forKey: .ledsLit)
        meterLevels = container.lenient([Int].self, .meterLevels) ?? []
        meterOverloads = container.lenient([Bool].self, .meterOverloads) ?? []
        meterEvents = container.lenient(Int.self, .meterEvents) ?? 0
    }
}

// MARK: - Responses (bridge → server)

/// Every field any bridge reply can carry.
///
/// The snapshot fields are FLATTENED into the same JSON object rather than
/// nested under a "snapshot" key — that is how `status` and `await` have
/// always replied, and `logic_mcu_status` results in the wild have that
/// shape. `encode(to:)` writes the snapshot into the top-level container to
/// preserve it.
public struct BridgeResponse: Sendable, Equatable {
    public var ok: Bool
    public var error: String?

    /// `press` echo: the button name, or the raw note when addressed by note.
    public var pressed: String?
    public var pressedNote: Int?

    /// `ping`
    public var pong: Bool?
    public var bridgeProtocol: Int?

    /// `keycmd` echo
    public var sentNote: Int?
    public var channel: Int?

    /// `midi_abort`
    public var aborted: Bool?

    /// `midi_stream`: how many events were accepted, and the last offset.
    public var eventCount: Int?
    public var durationMs: Int?

    /// `converge`
    public var finalText: String?
    public var finalValue: Double?
    public var iterations: Int?
    public var ratio: Double?

    /// `fader` with `verify`: whether Logic's echo moved to meet the write.
    /// `finalValue` then carries the value Logic SETTLED on, which is not
    /// necessarily the value asked for — Logic snaps a fader write to its own
    /// resolution (measured 2026-08-28: 5631…5635 all landed on 5628).
    /// Absent from a daemon older than protocol 5, which never verified.
    public var followed: Bool?

    /// `status`
    public var midiStreaming: Bool?
    /// `await`: true when the deadline passed with no new events.
    public var timedOut: Bool?

    /// Present on `status` and `await`; flattened into the same JSON object.
    public var snapshot: SurfaceSnapshot?

    enum CodingKeys: String, CodingKey {
        case ok, error, pressed
        case pressedNote = "pressed_note"
        case pong
        case bridgeProtocol = "bridge_protocol"
        case sentNote = "sent_note"
        case channel, aborted
        case eventCount = "events"
        case durationMs = "duration_ms"
        case finalText = "final_text"
        case finalValue = "final_value"
        case iterations, ratio, followed
        case midiStreaming = "midi_streaming"
        case timedOut = "timed_out"
    }

    public init(ok: Bool, error: String? = nil) {
        self.ok = ok
        self.error = error
    }

    /// The universal failure reply: `{"ok": false, "error": "…"}`.
    public static func failure(_ message: String) -> BridgeResponse {
        BridgeResponse(ok: false, error: message)
    }

    public static let success = BridgeResponse(ok: true)
}

extension BridgeResponse: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.lenient(Bool.self, .ok) ?? false
        error = container.lenient(String.self, .error)
        pressed = container.lenient(String.self, .pressed)
        pressedNote = container.lenient(Int.self, .pressedNote)
        pong = container.lenient(Bool.self, .pong)
        bridgeProtocol = container.lenient(Int.self, .bridgeProtocol)
        sentNote = container.lenient(Int.self, .sentNote)
        channel = container.lenient(Int.self, .channel)
        aborted = container.lenient(Bool.self, .aborted)
        eventCount = container.lenient(Int.self, .eventCount)
        durationMs = container.lenient(Int.self, .durationMs)
        finalText = container.lenient(String.self, .finalText)
        finalValue = container.lenient(Double.self, .finalValue)
        iterations = container.lenient(Int.self, .iterations)
        ratio = container.lenient(Double.self, .ratio)
        followed = container.lenient(Bool.self, .followed)
        midiStreaming = container.lenient(Bool.self, .midiStreaming)
        timedOut = container.lenient(Bool.self, .timedOut)
        // A reply without the snapshot keys (ping, press, …) simply has no
        // snapshot; that is not an error.
        snapshot = try? SurfaceSnapshot(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(pressed, forKey: .pressed)
        try container.encodeIfPresent(pressedNote, forKey: .pressedNote)
        try container.encodeIfPresent(pong, forKey: .pong)
        try container.encodeIfPresent(bridgeProtocol, forKey: .bridgeProtocol)
        try container.encodeIfPresent(sentNote, forKey: .sentNote)
        try container.encodeIfPresent(channel, forKey: .channel)
        try container.encodeIfPresent(aborted, forKey: .aborted)
        try container.encodeIfPresent(eventCount, forKey: .eventCount)
        try container.encodeIfPresent(durationMs, forKey: .durationMs)
        try container.encodeIfPresent(finalText, forKey: .finalText)
        try container.encodeIfPresent(finalValue, forKey: .finalValue)
        try container.encodeIfPresent(iterations, forKey: .iterations)
        try container.encodeIfPresent(ratio, forKey: .ratio)
        try container.encodeIfPresent(followed, forKey: .followed)
        try container.encodeIfPresent(midiStreaming, forKey: .midiStreaming)
        try container.encodeIfPresent(timedOut, forKey: .timedOut)
        // Flatten: same encoder, its own keyed container, merged output.
        try snapshot?.encode(to: encoder)
    }
}
