// logic-mcu-bridge — persistent Mackie Control (MCU) bridge for Logic Pro.
//
// Owns a pair of virtual CoreMIDI endpoints that Logic is configured to use
// as a Mackie Control surface. Mirrors everything Logic sends (LCD text,
// fader positions, button LEDs, 7-segment displays) into a JSON state file,
// and accepts commands over a unix socket. This is the documented,
// UI-independent control plane: no Accessibility, no windows, no focus.
//
// State file: ~/Library/Application Support/LogicMCPMCU/state.json
// Command socket: ~/Library/Application Support/LogicMCPMCU/command.sock

import CoreMIDI
import Foundation

let portName = "Logic MCP MCU"
let directory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/LogicMCPMCU")
let statePath = directory.appendingPathComponent("state.json")
let socketPath = directory.appendingPathComponent("command.sock").path

// MARK: - Mirrored surface state

final class SurfaceState {
    private let lock = NSLock()
    var lcd = [UInt8](repeating: 0x20, count: 112) // 2 x 56 chars
    var timecode = [UInt8](repeating: 0x20, count: 10)
    var assignment = [UInt8](repeating: 0x20, count: 2)
    var faders = [Int](repeating: -1, count: 9) // 14-bit, -1 = never reported
    var leds: [Int: Bool] = [:] // note number -> lit
    var vpotRings = [Int](repeating: 0, count: 8)
    var lastReceive: Double = 0
    var receivedCount: Int = 0
    var dirty = true

    func update(_ mutate: (SurfaceState) -> Void) {
        lock.lock()
        mutate(self)
        lastReceive = Date().timeIntervalSince1970
        receivedCount += 1
        dirty = true
        lock.unlock()
    }

    /// One 7-char LCD cell from the bottom (value) row, trimmed.
    func lcdBottomField(_ field: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        let start = 56 + field * 7
        guard start + 7 <= 112 else { return "" }
        return (String(bytes: lcd[start..<start + 7], encoding: .ascii) ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    func snapshotObject() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return snapshotObjectLocked()
    }

    private func snapshotObjectLocked() -> [String: Any] {
        let namedLEDs: [String: Int] = [
            "play": 0x5E, "stop": 0x5D, "record": 0x5F,
            "rewind": 0x5B, "forward": 0x5C, "cycle": 0x56
        ]
        var object: [String: Any] = [
            "updated": Date().timeIntervalSince1970,
            "last_receive": lastReceive,
            "received_events": receivedCount,
            "online": Date().timeIntervalSince1970 - lastReceive < 10 && receivedCount > 0,
            "lcd_top": String(bytes: lcd[0..<56], encoding: .ascii) ?? "",
            "lcd_bottom": String(bytes: lcd[56..<112], encoding: .ascii) ?? "",
            "timecode": String(bytes: timecode, encoding: .ascii) ?? "",
            "assignment": String(bytes: assignment, encoding: .ascii) ?? "",
            "faders_14bit": faders,
            "vpot_rings": vpotRings
        ]
        object["transport_leds"] = namedLEDs.mapValues { leds[$0] ?? false }
        object["leds_lit"] = leds.filter(\.value).keys.sorted()
        return object
    }

    var eventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return receivedCount
    }

    func snapshotJSON() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        dirty = false
        let namedLEDs: [String: Int] = [
            "play": 0x5E, "stop": 0x5D, "record": 0x5F,
            "rewind": 0x5B, "forward": 0x5C, "cycle": 0x56
        ]
        var object: [String: Any] = [
            "updated": Date().timeIntervalSince1970,
            "last_receive": lastReceive,
            "received_events": receivedCount,
            "online": Date().timeIntervalSince1970 - lastReceive < 10 && receivedCount > 0,
            "lcd_top": String(bytes: lcd[0..<56], encoding: .ascii) ?? "",
            "lcd_bottom": String(bytes: lcd[56..<112], encoding: .ascii) ?? "",
            "timecode": String(bytes: timecode, encoding: .ascii) ?? "",
            "assignment": String(bytes: assignment, encoding: .ascii) ?? "",
            "faders_14bit": faders,
            "vpot_rings": vpotRings
        ]
        object["transport_leds"] = namedLEDs.mapValues { leds[$0] ?? false }
        object["leds_lit"] = leds.filter(\.value).keys.sorted()
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    var isDirty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dirty
    }
}

let state = SurfaceState()

// MARK: - MIDI parsing (from Logic)

final class MIDIParser {
    private var sysex: [UInt8] = []
    private var inSysex = false
    private var runningStatus: UInt8 = 0

    func feed(_ bytes: [UInt8]) {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if inSysex {
                if byte == 0xF7 {
                    inSysex = false
                    handleSysex(sysex)
                    sysex.removeAll()
                } else if byte < 0x80 {
                    sysex.append(byte)
                } else {
                    inSysex = false
                    sysex.removeAll()
                    continue // reprocess as status
                }
                index += 1
                continue
            }
            if byte == 0xF0 {
                inSysex = true
                sysex.removeAll()
                index += 1
                continue
            }
            if byte >= 0x80 {
                runningStatus = byte
                index += 1
                continue
            }
            // data byte under running status
            let status = runningStatus & 0xF0
            let channel = Int(runningStatus & 0x0F)
            switch status {
            case 0x90, 0x80: // note on/off = button LEDs
                guard index + 1 < bytes.count else { index += 1; continue }
                let note = Int(byte)
                let velocity = Int(bytes[index + 1])
                state.update { s in
                    s.leds[note] = status == 0x90 && velocity > 0
                }
                index += 2
            case 0xB0: // CC: 7-seg displays, vpot rings
                guard index + 1 < bytes.count else { index += 1; continue }
                let controller = Int(byte)
                let value = UInt8(bytes[index + 1])
                state.update { s in
                    switch controller {
                    case 0x30...0x37:
                        s.vpotRings[controller - 0x30] = Int(value)
                    case 0x40...0x49: // timecode digits, right to left
                        let position = 9 - (controller - 0x40)
                        s.timecode[position] = segChar(value)
                    case 0x4A...0x4B: // assignment digits
                        s.assignment[1 - (controller - 0x4A)] = segChar(value)
                    default:
                        break
                    }
                }
                index += 2
            case 0xE0: // pitch bend = fader position feedback
                guard index + 1 < bytes.count else { index += 1; continue }
                let value = Int(byte) | (Int(bytes[index + 1]) << 7)
                state.update { s in
                    if channel < s.faders.count { s.faders[channel] = value }
                }
                index += 2
            case 0xA0: // channel pressure pairs used for meters — ignore payload
                index += 2
            case 0xD0:
                index += 1
            default:
                index += 1
            }
        }
    }

    private func handleSysex(_ payload: [UInt8]) {
        // Mackie header: 00 00 66 <device> <command> ...
        guard payload.count >= 5, payload[0] == 0x00, payload[1] == 0x00, payload[2] == 0x66 else {
            return
        }
        let command = payload[4]
        if command == 0x12, payload.count > 5 { // LCD write: offset + chars
            let offset = Int(payload[5])
            let characters = payload.dropFirst(6)
            state.update { s in
                for (position, character) in characters.enumerated() {
                    let target = offset + position
                    if target < s.lcd.count { s.lcd[target] = character }
                }
            }
        }
    }

    private func segChar(_ value: UInt8) -> UInt8 {
        // 7-segment encoding: low 6 bits map into ASCII (0x00-0x3F -> '@'..'?')
        let base = value & 0x3F
        return base < 0x20 ? base + 0x40 : base
    }
}

let parser = MIDIParser()

// MARK: - MIDI setup

var client = MIDIClientRef()
var source = MIDIEndpointRef()      // we transmit to Logic through this (MCU)
var destination = MIDIEndpointRef() // Logic transmits to us through this
var commandSource = MIDIEndpointRef() // dedicated port for key-command triggers
var midiInSource = MIDIEndpointRef() // plain MIDI input: Logic records/plays this

func setUpMIDI() -> Bool {
    guard MIDIClientCreateWithBlock("LogicMCPMCUBridge" as CFString, &client, nil) == noErr else {
        return false
    }
    guard MIDISourceCreate(client, portName as CFString, &source) == noErr else {
        return false
    }
    // Separate source so key-command notes never collide with the MCU
    // protocol on the control-surface port.
    guard MIDISourceCreate(client, "Logic MCP Commands" as CFString, &commandSource) == noErr else {
        return false
    }
    // Plain performance-MIDI source: no control-surface role and no key
    // command assignments, so Logic treats it as a normal keyboard — notes
    // sound through the selected instrument and are recorded.
    guard MIDISourceCreate(client, "Logic MCP MIDI In" as CFString, &midiInSource) == noErr else {
        return false
    }
    // FIXED unique IDs: Logic binds its control-surface/assignment config to
    // the endpoint's kMIDIPropertyUniqueID. Random IDs (the default) break
    // every binding on bridge restart; stable IDs reconnect instantly.
    MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, 0x4C4D4331)
    MIDIObjectSetIntegerProperty(commandSource, kMIDIPropertyUniqueID, 0x4C4D4332)
    MIDIObjectSetIntegerProperty(midiInSource, kMIDIPropertyUniqueID, 0x4C4D4333)
    let status = MIDIDestinationCreateWithBlock(client, portName as CFString, &destination) { packetList, _ in
        let packets = packetList.pointee
        var packet = packets.packet
        for _ in 0..<packets.numPackets {
            let length = Int(packet.length)
            let bytes = withUnsafeBytes(of: packet.data) { raw in
                Array(raw.prefix(length))
            }
            parser.feed(bytes)
            packet = MIDIPacketNext(&packet).pointee
        }
    }
    if status == noErr {
        MIDIObjectSetIntegerProperty(destination, kMIDIPropertyUniqueID, 0x4C4D4330)
    }
    return status == noErr
}

func send(_ bytes: [UInt8]) {
    var packetList = MIDIPacketList()
    let packet = MIDIPacketListInit(&packetList)
    _ = MIDIPacketListAdd(&packetList, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, bytes)
    MIDIReceived(source, &packetList)
}

func sendCommandPort(_ bytes: [UInt8]) {
    var packetList = MIDIPacketList()
    let packet = MIDIPacketListInit(&packetList)
    _ = MIDIPacketListAdd(&packetList, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, bytes)
    MIDIReceived(commandSource, &packetList)
}

func sendMIDIIn(_ bytes: [UInt8]) {
    var packetList = MIDIPacketList()
    let packet = MIDIPacketListInit(&packetList)
    _ = MIDIPacketListAdd(&packetList, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, bytes)
    MIDIReceived(midiInSource, &packetList)
}

let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

func hostTicks(fromMs ms: Double) -> UInt64 {
    UInt64(ms * 1_000_000 * Double(timebase.denom) / Double(timebase.numer))
}

/// Sends with an explicit CoreMIDI timestamp: the receiver's recording
/// engine places the event at the stamped host time, not the arrival time,
/// which removes our scheduling jitter from the recorded positions.
func sendMIDIInStamped(_ bytes: [UInt8], atHostTime hostTime: UInt64) {
    var packetList = MIDIPacketList()
    let packet = MIDIPacketListInit(&packetList)
    _ = MIDIPacketListAdd(&packetList, MemoryLayout<MIDIPacketList>.size, packet, hostTime, bytes.count, bytes)
    MIDIReceived(midiInSource, &packetList)
}

// MARK: - MIDI stream scheduler (timed playback on the MIDI In port)

let midiStreamLock = NSLock()
var midiStreamActive = false
var midiStreamGeneration = 0

func isMIDIStreamActive() -> Bool {
    midiStreamLock.lock(); defer { midiStreamLock.unlock() }
    return midiStreamActive
}

/// Plays timestamped events on the MIDI In port from a background thread.
/// Offsets are milliseconds from stream start; pacing via usleep is well
/// under a millisecond of jitter, which recording quantization dwarfs.
func playMIDIStream(_ events: [(offsetMs: Double, bytes: [UInt8])]) {
    midiStreamLock.lock()
    midiStreamActive = true
    midiStreamGeneration += 1
    let generation = midiStreamGeneration
    midiStreamLock.unlock()
    Thread.detachNewThread {
        // Each packet carries an exact host-time stamp and is handed to
        // CoreMIDI ~80 ms ahead of its due time: pacing jitter then never
        // reaches the recorded positions, only the stamps do.
        let anchor = mach_absolute_time()
        let leadMs = 80.0
        for event in events {
            midiStreamLock.lock()
            let cancelled = midiStreamGeneration != generation
            midiStreamLock.unlock()
            if cancelled { return }
            let due = anchor &+ hostTicks(fromMs: event.offsetMs)
            let sendAt = event.offsetMs > leadMs
                ? anchor &+ hostTicks(fromMs: event.offsetMs - leadMs)
                : anchor
            let now = mach_absolute_time()
            if sendAt > now {
                let waitNs = (sendAt - now) * UInt64(timebase.numer) / UInt64(timebase.denom)
                usleep(UInt32(min(waitNs / 1000, 1_000_000)))
            }
            sendMIDIInStamped(event.bytes, atHostTime: due)
        }
        midiStreamLock.lock()
        if midiStreamGeneration == generation { midiStreamActive = false }
        midiStreamLock.unlock()
    }
}

/// All-notes-off on every channel, used by midi_abort.
func silenceMIDIIn() {
    for channel: UInt8 in 0..<16 {
        sendMIDIIn([0xB0 | channel, 123, 0]) // all notes off
        sendMIDIIn([0xB0 | channel, 64, 0])  // sustain off
    }
}

// MARK: - MCU commands (to Logic)

func pressButton(note: UInt8) {
    send([0x90, note, 0x7F])
    Thread.sleep(forTimeInterval: 0.05)
    send([0x90, note, 0x00])
}

func setFader(channel: Int, value14: Int) {
    let clamped = max(0, min(16383, value14))
    let touch = UInt8(0x68 + channel)
    send([0x90, touch, 0x7F]) // fader touch on
    Thread.sleep(forTimeInterval: 0.02)
    send([UInt8(0xE0 + channel), UInt8(clamped & 0x7F), UInt8((clamped >> 7) & 0x7F)])
    Thread.sleep(forTimeInterval: 0.02)
    send([0x90, touch, 0x00]) // touch off commits
}

func turnVPot(index: Int, delta: Int) {
    let steps = min(abs(delta), 63)
    let value = UInt8(delta < 0 ? 0x40 + steps : steps)
    send([0xB0, UInt8(0x10 + index), value])
}

let buttonNames: [String: UInt8] = [
    "play": 0x5E, "stop": 0x5D, "record": 0x5F, "rewind": 0x5B, "forward": 0x5C,
    "cycle": 0x56, "marker": 0x54, "nudge": 0x55, "drop": 0x57, "replace": 0x58,
    "click": 0x59, "solo_global": 0x5A,
    "bank_left": 0x2E, "bank_right": 0x2F, "channel_left": 0x30, "channel_right": 0x31,
    "flip": 0x32, "global_view": 0x33, "name_value": 0x34, "smpte_beats": 0x35,
    "assign_track": 0x28, "assign_send": 0x29, "assign_pan": 0x2A,
    "assign_plugin": 0x2B, "assign_eq": 0x2C, "assign_instrument": 0x2D
]

func handleCommand(_ object: [String: Any]) -> [String: Any] {
    guard let command = object["cmd"] as? String else {
        return ["ok": false, "error": "missing cmd"]
    }
    switch command {
    case "press":
        if let name = object["button"] as? String, let note = buttonNames[name] {
            pressButton(note: note)
            return ["ok": true, "pressed": name]
        }
        if let note = object["note"] as? Int, (0...127).contains(note) {
            pressButton(note: UInt8(note))
            return ["ok": true, "pressed_note": note]
        }
        return ["ok": false, "error": "unknown button; known: \(buttonNames.keys.sorted().joined(separator: ","))"]
    case "select":
        guard let channel = object["channel"] as? Int, (0...7).contains(channel) else {
            return ["ok": false, "error": "channel 0-7 required"]
        }
        pressButton(note: UInt8(0x18 + channel))
        return ["ok": true]
    case "mute":
        guard let channel = object["channel"] as? Int, (0...7).contains(channel) else {
            return ["ok": false, "error": "channel 0-7 required"]
        }
        pressButton(note: UInt8(0x10 + channel))
        return ["ok": true]
    case "solo":
        guard let channel = object["channel"] as? Int, (0...7).contains(channel) else {
            return ["ok": false, "error": "channel 0-7 required"]
        }
        pressButton(note: UInt8(0x08 + channel))
        return ["ok": true]
    case "vpot_press":
        guard let index = object["index"] as? Int, (0...7).contains(index) else {
            return ["ok": false, "error": "index 0-7 required"]
        }
        pressButton(note: UInt8(0x20 + index))
        return ["ok": true]
    case "fader":
        guard let channel = object["channel"] as? Int, (0...8).contains(channel),
              let value = object["value"] as? Int else {
            return ["ok": false, "error": "channel 0-8 and value (14-bit) required"]
        }
        setFader(channel: channel, value14: value)
        return ["ok": true]
    case "vpot":
        guard let index = object["index"] as? Int, (0...7).contains(index),
              let delta = object["delta"] as? Int else {
            return ["ok": false, "error": "index 0-7 and delta required"]
        }
        turnVPot(index: index, delta: delta)
        return ["ok": true]
    case "raw":
        guard let bytes = object["bytes"] as? [Int], bytes.allSatisfy({ (0...255).contains($0) }) else {
            return ["ok": false, "error": "bytes array required"]
        }
        send(bytes.map(UInt8.init))
        return ["ok": true]
    case "status":
        var snapshot = state.snapshotObject()
        snapshot["ok"] = true
        snapshot["midi_streaming"] = isMIDIStreamActive()
        return snapshot
    case "await":
        // Event-driven wait: returns as soon as new MIDI arrived from Logic
        // after `since` (a received_events value), or after timeout_ms.
        let since = object["since"] as? Int ?? -1
        let timeoutMs = min(object["timeout_ms"] as? Int ?? 500, 5000)
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while state.eventCount <= since && Date() < deadline {
            usleep(5000) // 5 ms
        }
        var snapshot = state.snapshotObject()
        snapshot["ok"] = true
        snapshot["timed_out"] = state.eventCount <= since
        return snapshot
    case "converge":
        // Server-side convergence pays a socket round trip plus a fat await
        // per tick; here the LCD echo lands in-process and can be polled
        // every few milliseconds. Adaptive tick ratio, same discipline as
        // the server's convergeNumeric.
        guard let index = object["index"] as? Int, (0...7).contains(index),
              let target = (object["target"] as? Double) ?? (object["target"] as? Int).map(Double.init) else {
            return ["ok": false, "error": "index 0-7 and target (number) required"]
        }
        let field = object["field"] as? Int ?? index
        let maxMs = min(object["max_ms"] as? Int ?? 3000, 15000)
        let tolerance = (object["tolerance"] as? Double) ?? 0.0
        var ratio = (object["ratio"] as? Double) ?? 2.0
        func parseValue(_ text: String) -> Double? {
            let normalized = text.replacingOccurrences(of: ",", with: ".")
            if normalized.hasPrefix("-oo") { return -70.0 }
            let numeric = normalized.prefix { "+-0123456789.".contains($0) }
            guard !numeric.isEmpty, numeric != "-", numeric != "+" else { return nil }
            return Double(numeric.hasSuffix(".") ? String(numeric.dropLast()) : String(numeric))
        }
        let deadline = Date().addingTimeInterval(Double(maxMs) / 1000)
        guard var current = parseValue(state.lcdBottomField(field)) else {
            return ["ok": false, "error": "field \(field) is not numeric: '\(state.lcdBottomField(field))'"]
        }
        var iterations = 0
        while Date() < deadline {
            let step = max(tolerance, abs(0.5 / max(abs(ratio), 0.01)))
            if abs(current - target) <= step { break }
            var ticks = Int(((target - current) * ratio).rounded())
            if ticks == 0 { ticks = (target - current) * ratio > 0 ? 1 : -1 }
            ticks = max(-60, min(60, ticks))
            let before = state.eventCount
            turnVPot(index: index, delta: ticks)
            iterations += 1
            // wait for the echo: new events + the field's value changing,
            // polled at millisecond granularity
            let echoDeadline = Date().addingTimeInterval(0.25)
            var updated: Double?
            while Date() < echoDeadline {
                usleep(3000)
                if state.eventCount != before,
                   let value = parseValue(state.lcdBottomField(field)), value != current {
                    updated = value
                    break
                }
            }
            guard let now = updated else {
                // no movement: either done (clamped at an end stop) or stuck
                if let value = parseValue(state.lcdBottomField(field)) { current = value }
                if abs(current - target) <= max(tolerance, 0.5) { break }
                continue
            }
            let change = now - current
            if abs(change) > 0.0001 {
                let observed = Double(ticks) / change
                if observed.isFinite, abs(observed) < 1000 {
                    ratio = 0.5 * ratio + 0.5 * observed
                }
            }
            current = now
        }
        usleep(30000)
        let finalText = state.lcdBottomField(field)
        return [
            "ok": true,
            "final_text": finalText,
            "final_value": parseValue(finalText) ?? current,
            "iterations": iterations,
            "ratio": ratio
        ]
    case "midi_stream":
        // Timed performance MIDI on the "Logic MCP MIDI In" port. events is
        // an array of [offset_ms, byte, byte, ...]; playback is asynchronous
        // (poll status.midi_streaming or wait duration_ms).
        guard let rawEvents = object["events"] as? [[Any]], !rawEvents.isEmpty else {
            return ["ok": false, "error": "events required: [[offset_ms, byte, ...], ...]"]
        }
        guard rawEvents.count <= 20000 else {
            return ["ok": false, "error": "too many events (max 20000)"]
        }
        var events: [(offsetMs: Double, bytes: [UInt8])] = []
        for raw in rawEvents {
            guard raw.count >= 2,
                  let offset = (raw[0] as? Double) ?? (raw[0] as? Int).map(Double.init),
                  offset >= 0 else {
                return ["ok": false, "error": "each event needs [offset_ms >= 0, byte, ...]"]
            }
            var bytes: [UInt8] = []
            for value in raw.dropFirst() {
                guard let byte = value as? Int, (0...255).contains(byte) else {
                    return ["ok": false, "error": "event bytes must be 0-255"]
                }
                bytes.append(UInt8(byte))
            }
            events.append((offset, bytes))
        }
        if isMIDIStreamActive() {
            return ["ok": false, "error": "a MIDI stream is already playing; midi_abort first"]
        }
        events.sort { $0.offsetMs < $1.offsetMs }
        playMIDIStream(events)
        return [
            "ok": true,
            "events": events.count,
            "duration_ms": Int(events.last?.offsetMs ?? 0)
        ]
    case "midi_abort":
        midiStreamLock.lock()
        midiStreamGeneration += 1 // cancels the playback thread
        midiStreamActive = false
        midiStreamLock.unlock()
        silenceMIDIIn()
        return ["ok": true, "aborted": true]
    case "keycmd":
        // Note on channel 16 on the dedicated Commands port; Logic's key
        // command MIDI assignments intercept these before any track input.
        guard let note = object["note"] as? Int, (0...127).contains(note) else {
            return ["ok": false, "error": "note 0-127 required"]
        }
        let channel = UInt8((object["channel"] as? Int ?? 16) - 1) & 0x0F
        sendCommandPort([0x90 | channel, UInt8(note), 0x7F])
        usleep(40000)
        sendCommandPort([0x80 | channel, UInt8(note), 0x00])
        return ["ok": true, "sent_note": note, "channel": Int(channel) + 1]
    case "ping":
        return ["ok": true, "pong": true, "bridge_protocol": 2]
    default:
        return ["ok": false, "error": "unknown cmd \(command)"]
    }
}

// MARK: - Command socket

func startSocketServer() {
    unlink(socketPath)
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fatalError("socket() failed") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    socketPath.withCString { path in
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: UnsafeRawBufferPointer(start: path, count: min(strlen(path) + 1, raw.count)))
        }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
    }
    guard bound == 0, Darwin.listen(fd, 4) == 0 else { fatalError("bind/listen failed") }
    Thread.detachNewThread {
        while true {
            let connection = Darwin.accept(fd, nil, nil)
            guard connection >= 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(connection, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer[0..<count])
                let response: [String: Any]
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    response = handleCommand(object)
                } else {
                    response = ["ok": false, "error": "invalid JSON"]
                }
                if let out = try? JSONSerialization.data(withJSONObject: response) {
                    out.withUnsafeBytes { _ = Darwin.write(connection, $0.baseAddress, out.count) }
                }
            }
            Darwin.close(connection)
        }
    }
}

// MARK: - Main

/// Runs the bridge daemon until killed. The MCP server calls this when
/// launched with `--bridge`; the library form means one distributable binary.
public func bridgeMain() -> Never {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard setUpMIDI() else {
        FileHandle.standardError.write(Data("failed to create virtual MIDI endpoints\n".utf8))
        exit(1)
    }
    startSocketServer()
    FileHandle.standardError.write(Data("logic-mcu-bridge running; ports '\(portName)'\n".utf8))

    let timer = DispatchSource.makeTimerSource()
    timer.schedule(deadline: .now(), repeating: .milliseconds(150))
    timer.setEventHandler {
        if state.isDirty, let json = state.snapshotJSON() {
            try? json.write(to: statePath, options: .atomic)
        }
    }
    timer.resume()

    // Also write an initial state so readers see the bridge even before Logic talks.
    if let json = state.snapshotJSON() {
        try? json.write(to: statePath, options: .atomic)
    }

    withExtendedLifetime(timer) {
        RunLoop.main.run()
    }
    exit(0)
}
