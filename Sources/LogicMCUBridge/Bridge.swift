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
    /// Per-strip meter segment as Logic paints it on the surface, 0...12,
    /// -1 = never reported. See `MCUMeter` for the grammar.
    var meterLevels = [Int](repeating: -1, count: MCUMeter.channelCount)
    /// Per-strip overload ("clip") flag, latched by Logic and cleared by Logic.
    var meterOverloads = [Bool](repeating: false, count: MCUMeter.channelCount)
    /// How many meter messages have been decoded. `0` after a stretch of
    /// playback is the evidence that Logic does not feed this surface meters
    /// at all — which is the whole reason the counter is on the wire.
    var meterCount: Int = 0
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

    /// Meter updates go through their OWN mutator, which deliberately does not
    /// touch `receivedCount` or `lastReceive`.
    ///
    /// Both of those are load-bearing for silence detection: `awaitEvents`
    /// counts `receivedCount`, and `ensurePanNames`/`settledTop` classify the
    /// display by waiting for Logic to go quiet. Meters arrive continuously
    /// while the transport rolls, so counting them as ordinary events would
    /// make "quiet" unreachable during playback — the exact failure the
    /// blinking record LED already caused once (FINDINGS 2026-08-28, fynd 2),
    /// where every MCU tool stopped resolving names. `dirty` is set only when
    /// the decoded state actually CHANGES, so a stream of identical meter
    /// frames does not rewrite state.json 7 times a second.
    func updateMeters(_ mutate: (SurfaceState) -> Void) {
        lock.lock()
        let beforeLevels = meterLevels
        let beforeOverloads = meterOverloads
        mutate(self)
        meterCount += 1
        if meterLevels != beforeLevels || meterOverloads != beforeOverloads { dirty = true }
        lock.unlock()
    }

    /// One strip's value cell from the bottom (value) row — the echo the
    /// convergence below steers by. Sliced through `MCULCDRow.valueCell`, so
    /// the rightmost cell keeps the sign character Logic shifts one column
    /// left into cell 6; reading that cell literally dropped the minus and
    /// sent the convergence the wrong way (see MCULCDRow.valueCell).
    func lcdBottomValueField(_ field: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard (0..<MCULCDRow.cellCount).contains(field) else { return "" }
        let row = String(bytes: lcd[56..<112], encoding: .ascii) ?? ""
        return MCULCDRow.valueCell(row, field)
    }

    func snapshot() -> SurfaceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    private static let namedLEDs: [String: Int] = [
        "play": 0x5E, "stop": 0x5D, "record": 0x5F,
        "rewind": 0x5B, "forward": 0x5C, "cycle": 0x56
    ]

    private func snapshotLocked() -> SurfaceSnapshot {
        SurfaceSnapshot(
            updated: Date().timeIntervalSince1970,
            lastReceive: lastReceive,
            receivedEvents: receivedCount,
            online: Date().timeIntervalSince1970 - lastReceive < 10 && receivedCount > 0,
            lcdTop: String(bytes: lcd[0..<56], encoding: .ascii) ?? "",
            lcdBottom: String(bytes: lcd[56..<112], encoding: .ascii) ?? "",
            timecode: String(bytes: timecode, encoding: .ascii) ?? "",
            assignment: String(bytes: assignment, encoding: .ascii) ?? "",
            faders14bit: faders,
            vpotRings: vpotRings,
            transportLEDs: Self.namedLEDs.mapValues { leds[$0] ?? false },
            ledsLit: leds.filter(\.value).keys.sorted(),
            meterLevels: meterLevels,
            meterOverloads: meterOverloads,
            meterEvents: meterCount
        )
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
        // Same snapshot the socket serves — this used to be a second,
        // hand-maintained copy of the dictionary above, which is exactly the
        // kind of drift the shared type removes.
        return try? bridgeJSONEncoder.encode(snapshotLocked())
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
            case 0xA0: // polyphonic aftertouch: two data bytes, unused by the MCU
                index += 2
            case 0xD0: // channel pressure = the per-strip meters (see MCUMeter)
                let event = MCUMeter.decode(byte)
                state.updateMeters { s in
                    MCUMeter.apply(event, levels: &s.meterLevels, overloads: &s.meterOverloads)
                }
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
    // These writes MUST be checked: if an ID is already taken (a second
    // daemon, a stale endpoint) CoreMIDI keeps the random ID it assigned and
    // every Logic binding — control surface AND key commands — silently
    // stops matching, while everything still looks healthy. Failing loudly
    // here is strictly better than running with the wrong identity.
    for (endpoint, uniqueID, label) in [
        (source, MIDIUniqueID(0x4C4D4331), portName),
        (commandSource, MIDIUniqueID(0x4C4D4332), "Logic MCP Commands"),
        (midiInSource, MIDIUniqueID(0x4C4D4333), "Logic MCP MIDI In")
    ] {
        let status = MIDIObjectSetIntegerProperty(endpoint, kMIDIPropertyUniqueID, uniqueID)
        guard status == noErr else {
            let message = "could not claim the fixed unique ID for '\(label)' (OSStatus \(status)); "
                + "another bridge instance or a stale endpoint holds it. Refusing to run "
                + "with a random ID, which would silently break Logic's bindings.\n"
            FileHandle.standardError.write(Data(message.utf8))
            return false
        }
    }
    let status = MIDIDestinationCreateWithBlock(client, portName as CFString, &destination) { packetList, _ in
        for bytes in midiPacketBytes(in: packetList) { parser.feed(bytes) }
    }
    guard status == noErr else { return false }
    let destinationID = MIDIObjectSetIntegerProperty(
        destination, kMIDIPropertyUniqueID, MIDIUniqueID(0x4C4D4330)
    )
    guard destinationID == noErr else {
        let message = "could not claim the fixed unique ID for the '\(portName)' destination "
            + "(OSStatus \(destinationID)); another bridge instance holds it.\n"
        FileHandle.standardError.write(Data(message.utf8))
        return false
    }
    return true
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

/// Sleeps until `hostTime` in short slices, re-checking cancellation between
/// them; returns false as soon as the stream was cancelled.
///
/// The wait used to be a SINGLE usleep capped at 1 s per event, with no
/// re-check of the deadline afterwards — so every gap longer than that fell
/// straight through and the event went to CoreMIDI far ahead of its due time
/// (sparse pads, held chords, slow tempi, rests). CoreMIDI cannot un-send a
/// stamped packet it already holds, so midi_abort — the emergency stop for
/// stuck notes — had nothing left to cancel. Slicing the wait keeps at most
/// one slice of dispatch beyond the documented ~80 ms lead.
func waitForMIDIStream(until hostTime: UInt64, generation: Int) -> Bool {
    let sliceUs: UInt64 = 20_000 // ceiling on how long midi_abort can lag
    while true {
        midiStreamLock.lock()
        let cancelled = midiStreamGeneration != generation
        midiStreamLock.unlock()
        if cancelled { return false }
        let now = mach_absolute_time()
        guard hostTime > now else { return true }
        let waitNs = (hostTime - now) * UInt64(timebase.numer) / UInt64(timebase.denom)
        usleep(UInt32(max(1, min(waitNs / 1000, sliceUs))))
    }
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
            let due = anchor &+ hostTicks(fromMs: event.offsetMs)
            let sendAt = event.offsetMs > leadMs
                ? anchor &+ hostTicks(fromMs: event.offsetMs - leadMs)
                : anchor
            // Cancellation is now re-checked DURING the wait, not only
            // between events: an abort in a long gap is honoured within one
            // slice instead of after the whole gap has been slept through.
            guard waitForMIDIStream(until: sendAt, generation: generation) else { return }
            sendMIDIInStamped(event.bytes, atHostTime: due)
        }
        // The final packets are handed over one lead ahead of when they
        // sound, so the thread waits out that lead before clearing the flag:
        // otherwise midiStreamActive (and midi_stream's busy check) reported
        // idle while notes were still pending in CoreMIDI.
        _ = waitForMIDIStream(
            until: anchor &+ hostTicks(fromMs: events.last?.offsetMs ?? 0),
            generation: generation
        )
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

/// Presses and releases one MCU button. `holdMs` is how long it stays down,
/// and the default is ZERO.
///
/// This line used to sleep a flat 50 ms, and it was 99.4% of what a button
/// press cost the whole server: 51-56 ms of a 51-56 ms round trip, paid by
/// every `press`, `select`, `mute`, `solo` and `vpot_press` in it — twelve of
/// them per mixer census — while the global `commandHandlingLock` held every
/// other client off the surface for the duration.
///
/// Swept live 2026-09-02 (Logic Pro, real Mackie Control emulation): the two
/// edges were driven as separate `raw` sends so the gap was the client's to
/// choose, and holds of ~0.2, 1, 2, 5, 10, 25 and 50 ms all changed the
/// assignment view, 16 transitions out of 16, with Logic's echo arriving
/// 102-106 ms after the press EVERY time. The sleep bought no reliability and
/// no latency. What it is not is optional in the other direction: a note-on
/// with no release left the display half-changed for 1348 ms of polling, so
/// both `send` calls stay.
///
/// A caller that wants Logic Control's HOLD semantics — held SEND opens the
/// submode chooser — passes its own `holdMs`; those were not swept.
func pressButton(note: UInt8, holdMs: Int = 0) {
    send([0x90, note, 0x7F])
    if holdMs > 0 { Thread.sleep(forTimeInterval: Double(holdMs) / 1000) }
    send([0x90, note, 0x00])
}

/// The environment variable the live sweep can set to change the
/// key-command plane's compiled-in hold default without editing every
/// message it sends — see `resolveKeycmdDefaultHoldMs`.
let keycmdHoldEnvVar = "LOGICIAN_KEYCMD_HOLD_MS"

/// Resolves the key-command plane's hold DEFAULT — the hold a `keycmd`
/// message gets when it names no `hold_ms` of its own — against an
/// optional environment-variable string, already read by the caller. Pure
/// on purpose: it takes the raw value rather than reading `ProcessInfo`
/// itself, so it is testable without touching a real process environment.
///
/// 0 ms IS THE MEASURED DEFAULT, swept live 2026-09-03 (sandbox
/// "Testlåt Copy", daemon at `1e393a7`) with `keycmd_hold_sweep.py`, the
/// same method the MCU button hold used the day before (`bf511e5`):
/// `Create Marker` fired via `logic_mcu_command {cmd:"keycmd", note:104,
/// channel:16, hold_ms:…}` on the dedicated "Logic MCP Commands" port,
/// playhead parked on an unmarked bar, markers counted and deleted after
/// every fire.
///
/// | hold_ms | wall ms | created | duplicated | dropped |
/// |---|---|---|---|---|
/// | 0 | 1 | 1/1 | 0 | 0 |
/// | 1 | 2 | 1/1 | 0 | 0 |
/// | 5 | 7 | 1/1 | 0 | 0 |
/// | 10 | 15 | 1/1 | 0 | 0 |
/// | 20 | 25 | 1/1 | 0 | 0 |
/// | 40 | 50 | 1/1 | 0 | 0 |
/// | 0, ten more fires | 0.9-3.0 (median 1.1) | 10/10 | 0 | 0 |
///
/// Sixteen fires at a 0 ms hold, sixteen markers, zero duplicates, zero
/// drops — the same 16/16 result the button sweep got. The 0.2 ms point
/// the button sweep also cleared is NOT reachable through `hold_ms` (an
/// `Int` count of milliseconds) and was not measured here; the honest
/// claim this table supports is "0-40 ms all work," not "anything smaller
/// would too." `pressButton`'s hold dropped the day before for the same
/// reason on the button-based plane; this is the note-based plane's own
/// measurement, not an assumption that it would behave the same way.
///
/// A malformed or missing override falls back to this 0 ms default rather
/// than failing the command — the same leniency every other field on this
/// wire gets. The environment override and any per-message `hold_ms`
/// still work exactly as before, for whichever surface gets swept next.
func resolveKeycmdDefaultHoldMs(envOverride raw: String?) -> Int {
    guard let raw, let ms = Int(raw) else { return 0 }
    return ms
}

/// Moves a motor fader to an absolute 14-bit position, as a hand on the
/// surface would: touch on, position, touch off.
///
/// The touch notes are NOT decoration and they are NOT the thing that makes
/// Logic obey. Measured live 2026-08-28 on Logic Pro 12.3.1: a bare pitch bend
/// with no touch note at all moves the fader just as reliably (master fader
/// 12443 → 11009, ordinary strip 6135 → 4130 and back, both bit-exact on the
/// way home). The touch pair is kept because it is what the MCU convention
/// says a real surface sends, and because Logic uses fader-touch to punch
/// automation — but the roadmap's claim that its absence is why "Logic ignores
/// the position" was wrong on both halves: the bridge already sent the notes,
/// and Logic follows either framing.
///
/// What DOES surprise a caller is that Logic SNAPS the position to its own
/// fader resolution. 5631, 5632, 5633, 5634 and 5635 all came back as 5628.
/// So an equality check against the value you asked for reads as failure on a
/// write that worked; compare with a tolerance, or — better — write back a
/// value Logic itself reported, which is on the grid by construction and
/// round-trips exactly.
func setFader(channel: Int, value14: Int) {
    let clamped = max(0, min(16383, value14))
    let touch = UInt8(0x68 + channel)
    send([0x90, touch, 0x7F]) // fader touch on
    Thread.sleep(forTimeInterval: 0.02)
    send([UInt8(0xE0 + channel), UInt8(clamped & 0x7F), UInt8((clamped >> 7) & 0x7F)])
    Thread.sleep(forTimeInterval: 0.02)
    send([0x90, touch, 0x00]) // touch off commits
}

/// Waits for Logic's own echo on `channel` to stop moving, and reports where
/// it landed. `nil` when the mirror has never seen that fader.
///
/// This is the piece the `fader` command was missing. It used to answer a bare
/// `{"ok": true}` — the write had no readback of any kind, so "Logic followed"
/// and "Logic did nothing" were indistinguishable, and a session in v0.54.1
/// concluded the write was ignored when it had in fact worked and snapped.
func awaitFaderEcho(channel: Int, timeoutMs: Int = 400) -> Int? {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    var last: Int?
    var stableSince = Date()
    while Date() < deadline {
        let current = state.snapshot().faders14bit
        guard channel < current.count, current[channel] >= 0 else { return nil }
        if current[channel] != last {
            last = current[channel]
            stableSince = Date()
        } else if Date().timeIntervalSince(stableSince) > 0.08 {
            return last // held still long enough to call it settled
        }
        usleep(10000)
    }
    return last
}

func turnVPot(index: Int, delta: Int) {
    let steps = min(abs(delta), 63)
    let value = UInt8(delta < 0 ? 0x40 + steps : steps)
    send([0xB0, UInt8(0x10 + index), value])
}

/// Public so the server's `logic_mcu_command` schema can advertise exactly
/// the button names this daemon accepts, instead of a hand-kept copy that
/// could drift from the map the `press` handler actually looks in.
public let buttonNames: [String: UInt8] = [
    "play": 0x5E, "stop": 0x5D, "record": 0x5F, "rewind": 0x5B, "forward": 0x5C,
    "cycle": 0x56, "marker": 0x54, "nudge": 0x55, "drop": 0x57, "replace": 0x58,
    "click": 0x59, "solo_global": 0x5A,
    "bank_left": 0x2E, "bank_right": 0x2F, "channel_left": 0x30, "channel_right": 0x31,
    "flip": 0x32, "global_view": 0x33, "name_value": 0x34, "smpte_beats": 0x35,
    "assign_track": 0x28, "assign_send": 0x29, "assign_pan": 0x2A,
    "assign_plugin": 0x2B, "assign_eq": 0x2C, "assign_instrument": 0x2D
]

func handleCommand(_ object: BridgeCommand) -> BridgeResponse {
    guard let command = object.cmd else {
        return .failure("missing cmd")
    }
    // `name` is nil for anything outside the vocabulary, which falls through
    // to the same "unknown cmd" reply the string switch used to produce.
    // Every button-pressing command reads its hold from the same place, so
    // `hold_ms` cannot mean one thing on `press` and another on `mute`.
    let holdMs = object.pressHoldMs
    switch object.name {
    case .press:
        if let name = object.button, let note = buttonNames[name] {
            pressButton(note: note, holdMs: holdMs)
            var response = BridgeResponse.success
            response.pressed = name
            return response
        }
        if let note = object.note, (0...127).contains(note) {
            pressButton(note: UInt8(note), holdMs: holdMs)
            var response = BridgeResponse.success
            response.pressedNote = note
            return response
        }
        return .failure("unknown button; known: \(buttonNames.keys.sorted().joined(separator: ","))")
    case .select:
        guard let channel = object.channel, (0...7).contains(channel) else {
            return .failure("channel 0-7 required")
        }
        pressButton(note: UInt8(0x18 + channel), holdMs: holdMs)
        return .success
    case .mute:
        guard let channel = object.channel, (0...7).contains(channel) else {
            return .failure("channel 0-7 required")
        }
        pressButton(note: UInt8(0x10 + channel), holdMs: holdMs)
        return .success
    case .solo:
        guard let channel = object.channel, (0...7).contains(channel) else {
            return .failure("channel 0-7 required")
        }
        pressButton(note: UInt8(0x08 + channel), holdMs: holdMs)
        return .success
    case .vpotPress:
        guard let index = object.index, (0...7).contains(index) else {
            return .failure("index 0-7 required")
        }
        pressButton(note: UInt8(0x20 + index), holdMs: holdMs)
        return .success
    case .fader:
        guard let channel = object.channel, (0...8).contains(channel),
              let value = object.value else {
            return .failure("channel 0-8 and value (14-bit) required")
        }
        let before = state.snapshot().faders14bit
        setFader(channel: channel, value14: value)
        guard object.verify == true else { return .success }
        // Opt-in readback: Logic's echo is the only evidence that the write
        // landed, and the value it settles on is its own snapped one.
        var response = BridgeResponse.success
        let settled = awaitFaderEcho(channel: channel)
        response.finalValue = settled.map(Double.init)
        let started = channel < before.count ? before[channel] : -1
        // "Followed" means Logic's echo now agrees with the request within its
        // own snapping grain — NOT that it equals the requested value.
        response.followed = settled.map { abs($0 - max(0, min(16383, value))) <= 64 }
            ?? (started >= 0 ? false : nil)
        return response
    case .vpot:
        guard let index = object.index, (0...7).contains(index),
              let delta = object.delta else {
            return .failure("index 0-7 and delta required")
        }
        turnVPot(index: index, delta: delta)
        return .success
    case .raw:
        guard let bytes = object.bytes, bytes.allSatisfy({ (0...255).contains($0) }) else {
            return .failure("bytes array required")
        }
        send(bytes.map(UInt8.init))
        return .success
    case .status:
        var response = BridgeResponse.success
        response.snapshot = state.snapshot()
        response.midiStreaming = isMIDIStreamActive()
        // ADDITIVE (2026-09-02), and the reason `logic_health` can now prove
        // liveness, protocol level and surface state in ONE round trip
        // instead of a ping followed by a status. A daemon older than this
        // simply omits the key; the server reads that as "cannot tell from
        // here" and falls back to the ping it always sent.
        response.bridgeProtocol = bridgeProtocolVersion
        return response
    case .awaitEvents:
        // Event-driven wait: returns as soon as new MIDI arrived from Logic
        // after `since` (a received_events value), or after timeout_ms.
        let since = object.since ?? -1
        let timeoutMs = min(object.timeoutMs ?? 500, 5000)
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while state.eventCount <= since && Date() < deadline {
            usleep(5000) // 5 ms
        }
        var response = BridgeResponse.success
        response.snapshot = state.snapshot()
        response.timedOut = state.eventCount <= since
        return response
    case .converge:
        // Server-side convergence pays a socket round trip plus a fat await
        // per tick; here the LCD echo lands in-process and can be polled
        // every few milliseconds. Adaptive tick ratio, same discipline as
        // the server's convergeNumeric.
        guard let index = object.index, (0...7).contains(index),
              let target = object.target else {
            return .failure("index 0-7 and target (number) required")
        }
        let field = object.field ?? index
        let maxMs = min(object.maxMs ?? 3000, 15000)
        let tolerance = object.tolerance ?? 0.0
        var ratio = object.ratio ?? 2.0
        func parseValue(_ text: String) -> Double? {
            let normalized = text.replacingOccurrences(of: ",", with: ".")
            if normalized.hasPrefix(MCULCDStrings.minusInfinity) {
                return MCULCDStrings.minusInfinityDb
            }
            let numeric = normalized.prefix { "+-0123456789.".contains($0) }
            guard !numeric.isEmpty, numeric != "-", numeric != "+" else { return nil }
            return Double(numeric.hasSuffix(".") ? String(numeric.dropLast()) : String(numeric))
        }
        let deadline = Date().addingTimeInterval(Double(maxMs) / 1000)
        guard var current = parseValue(state.lcdBottomValueField(field)) else {
            return .failure("field \(field) is not numeric: '\(state.lcdBottomValueField(field))'")
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
                   let value = parseValue(state.lcdBottomValueField(field)), value != current {
                    updated = value
                    break
                }
            }
            guard let now = updated else {
                // no movement: either done (clamped at an end stop) or stuck
                if let value = parseValue(state.lcdBottomValueField(field)) { current = value }
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
        let finalText = state.lcdBottomValueField(field)
        var response = BridgeResponse.success
        response.finalText = finalText
        response.finalValue = parseValue(finalText) ?? current
        response.iterations = iterations
        response.ratio = ratio
        return response
    case .midiStream:
        // Timed performance MIDI on the "Logic MCP MIDI In" port. events is
        // an array of [offset_ms, byte, byte, ...]; playback is asynchronous
        // (poll status.midi_streaming or wait duration_ms).
        guard let rawEvents = object.events, !rawEvents.isEmpty else {
            return .failure("events required: [[offset_ms, byte, ...], ...]")
        }
        guard rawEvents.count <= 20000 else {
            return .failure("too many events (max 20000)")
        }
        var events: [(offsetMs: Double, bytes: [UInt8])] = []
        for raw in rawEvents {
            guard raw.elements.count >= 2, let offset = raw.offsetMs, offset >= 0 else {
                return .failure("each event needs [offset_ms >= 0, byte, ...]")
            }
            guard let bytes = raw.bytes else {
                return .failure("event bytes must be 0-255")
            }
            events.append((offset, bytes))
        }
        if isMIDIStreamActive() {
            return .failure("a MIDI stream is already playing; midi_abort first")
        }
        events.sort { $0.offsetMs < $1.offsetMs }
        playMIDIStream(events)
        var response = BridgeResponse.success
        response.eventCount = events.count
        response.durationMs = Int(events.last?.offsetMs ?? 0)
        return response
    case .midiAbort:
        midiStreamLock.lock()
        midiStreamGeneration += 1 // cancels the playback thread
        midiStreamActive = false
        midiStreamLock.unlock()
        silenceMIDIIn()
        var response = BridgeResponse.success
        response.aborted = true
        return response
    case .keycmd:
        // Note on channel 16 on the dedicated Commands port; Logic's key
        // command MIDI assignments intercept these before any track input.
        guard let note = object.note, (0...127).contains(note) else {
            return .failure("note 0-127 required")
        }
        // truncatingIfNeeded, not UInt8(_:): channel 0 made the old
        // conversion evaluate UInt8(-1), which TRAPS and takes the whole
        // daemon down. Every valid channel (1...16) is unaffected.
        let channel = UInt8(truncatingIfNeeded: (object.channel ?? 16) - 1) & 0x0F
        let holdMs = object.keycmdHoldMs(
            default: resolveKeycmdDefaultHoldMs(
                envOverride: ProcessInfo.processInfo.environment[keycmdHoldEnvVar]
            )
        )
        sendCommandPort([0x90 | channel, UInt8(note), 0x7F])
        if holdMs > 0 { usleep(UInt32(holdMs * 1000)) }
        sendCommandPort([0x80 | channel, UInt8(note), 0x00])
        var response = BridgeResponse.success
        response.sentNote = note
        response.channel = Int(channel) + 1
        return response
    case .ping:
        var response = BridgeResponse.success
        response.pong = true
        response.bridgeProtocol = bridgeProtocolVersion
        return response
    case nil:
        return .failure("unknown cmd \(command)")
    }
}

// MARK: - Command socket

/// Held for the process lifetime by the single live daemon.
private var instanceLockDescriptor: Int32 = -1

/// Takes an exclusive flock on a lockfile. Two MCP clients starting at once
/// (Claude Code and Antigravity, say) would otherwise both spawn a daemon:
/// the second unlinks and rebinds the socket, so every command reaches a
/// bridge whose MIDI endpoints could not claim the fixed unique IDs — the
/// silent-orphaning failure the fixed IDs exist to prevent, with no error
/// anywhere. Must run BEFORE unlink(socketPath).
func acquireInstanceLock() -> Bool {
    let lockPath = directory.appendingPathComponent(BridgeProcess.lockFileName).path
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return true } // cannot lock: do not block startup
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        close(fd)
        return false
    }
    instanceLockDescriptor = fd // held until the process exits
    // Publish our pid into the file we now exclusively hold, so an upgrading
    // server can address this daemon by NUMBER instead of guessing at how its
    // command line was spelled. Matching a command line is what made every
    // "replacing outdated bridge daemon" a silent no-op when the daemon had
    // been started with a relative path (FINDINGS 2026-08-28).
    ftruncate(fd, 0)
    lseek(fd, 0, SEEK_SET)
    let pid = Data("\(getpid())\n".utf8)
    _ = pid.withUnsafeBytes { raw in
        raw.baseAddress.map { Darwin.write(fd, $0, raw.count) }
    }
    return true
}

/// One command in flight at a time, exactly as the old single-threaded loop
/// guaranteed by construction. Handlers sleep and steer real MIDI (converge
/// holds a vpot for seconds); two of them interleaving on the same surface
/// would fight over it.
private let commandHandlingLock = NSLock()

/// How long a connected peer gets to deliver its whole command, and then to
/// drain the reply. A healthy client does both in milliseconds (it writes,
/// half-closes, and is already reading); ten seconds is pure slack. This is a
/// deadline on the socket I/O only — command HANDLING time (converge can
/// legitimately run 15 s) is not under it.
let connectionIOTimeout: TimeInterval = 10

/// Serves one accepted connection: read the frame, run the command, write the
/// reply, close. Runs on its own thread with every socket wait deadlined, so
/// the worst a stuck or dead peer can do is hold THIS thread for ~20 s —
/// never the accept loop, and never another client's command.
///
/// This used to run inline in the accept loop with an unbounded read, and on
/// 2026-08-31 a client that connected without ever completing its transaction
/// wedged the daemon for good: every later connect() succeeded (the backlog
/// accepted it) and then hung forever. The socket is owner-only (0600), so
/// the peer is a buggy local client, not an adversary — but buggy is enough.
func serveConnection(_ connection: Int32) {
    defer { Darwin.close(connection) }
    // Non-blocking so the deadlined read/write in Framing.swift are actually
    // bounded: poll supplies the waiting, EAGAIN comes back instead of a stall.
    let flags = fcntl(connection, F_GETFL)
    _ = fcntl(connection, F_SETFL, flags | O_NONBLOCK)
    // A peer that disconnects before its reply is written must cost the
    // daemon an EPIPE on that one fd — not a process-wide SIGPIPE, which is
    // fatal by default and was a second, latent way for the daemon to die.
    var noSigpipe: Int32 = 1
    setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
               socklen_t(MemoryLayout<Int32>.size))
    guard case .complete(let data) = readToEOF(
        connection, deadline: Date().addingTimeInterval(connectionIOTimeout)
    ), !data.isEmpty else {
        return // timed out, errored, or empty: drop it without a reply
    }
    let response: BridgeResponse
    if let object = try? bridgeJSONDecoder.decode(BridgeCommand.self, from: data) {
        commandHandlingLock.lock()
        response = handleCommand(object)
        commandHandlingLock.unlock()
    } else {
        // Only a payload that is not a JSON object at all lands here:
        // BridgeCommand decodes every field leniently, so a wrongly-typed or
        // unknown key still reaches the handler and gets the handler's own
        // error, exactly as before.
        response = .failure("invalid JSON (\(data.count) bytes received)")
    }
    if let out = try? bridgeJSONEncoder.encode(response) {
        _ = writeAll(connection, out, deadline: Date().addingTimeInterval(connectionIOTimeout))
    }
}

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
    // Owner-only: anyone who can reach the socket can drive Logic (faders,
    // transport, raw MIDI). ~/Library being 0700 already blocks other users;
    // this makes the restriction explicit rather than inherited.
    chmod(socketPath, 0o600)
    Thread.detachNewThread {
        // The accept loop does NOTHING but accept and hand off. All per-peer
        // I/O lives in serveConnection on its own deadlined thread, so no
        // single connection — however stuck — can stop the next accept().
        while true {
            let connection = Darwin.accept(fd, nil, nil)
            guard connection >= 0 else {
                // EINTR is routine; anything persistent (EMFILE, say) must
                // not spin this loop hot at 100% CPU.
                if errno != EINTR { usleep(10_000) }
                continue
            }
            Thread.detachNewThread { serveConnection(connection) }
        }
    }
}

// MARK: - Main

/// Runs the bridge daemon until killed. The MCP server calls this when
/// launched with `--bridge`; the library form means one distributable binary.
public func bridgeMain() -> Never {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard acquireInstanceLock() else {
        FileHandle.standardError.write(Data(
            "another logic-mcu-bridge instance is already running; exiting\n".utf8
        ))
        exit(0) // not an error: the live daemon owns the ports
    }
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
