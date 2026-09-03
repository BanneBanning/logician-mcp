// Duplicate-endpoint detection.
//
// Virtual CoreMIDI endpoints outlive a daemon that dies without cleaning up
// (a crash, a kill -9, a build overwritten mid-run). The orphan keeps the
// name but carries a RANDOM unique ID, so the port list shows two identical
// "Logic MCP MCU" entries — and because Logic scopes both control-surface
// and key-command bindings to the unique ID, picking the wrong twin makes
// every key command silently stop firing while everything looks connected.
// That failure is expensive to diagnose from the outside, so the server
// reports it instead of leaving the user to guess.

import CoreMIDI
import Foundation

/// The fixed unique IDs this bridge claims for its endpoints.
public let expectedPortUniqueIDs: Set<Int32> = [0x4C4D_4330, 0x4C4D_4331, 0x4C4D_4332, 0x4C4D_4333]

private func endpointName(_ object: MIDIObjectRef) -> String {
    var value: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(object, kMIDIPropertyName, &value)
    return (value?.takeRetainedValue() as String?) ?? ""
}

private func endpointUniqueID(_ object: MIDIObjectRef) -> Int32 {
    var value: Int32 = 0
    MIDIObjectGetIntegerProperty(object, kMIDIPropertyUniqueID, &value)
    return value
}

/// The port key commands are learned onto and fired from.
public let commandsPortName = "Logic MCP Commands"

/// The unique ID the named virtual SOURCE currently carries, or nil when no
/// endpoint of that name exists (the daemon is down, or it never started).
///
/// Logic scopes a key-command assignment to this number, and the Key Commands
/// window's row text carries no port identity at all — so recording it at
/// learn time is the only way a later read can say that a binding was made
/// against an identity Logic no longer sees. Costs one CoreMIDI enumeration:
/// 0.8 ms warm, 16.6 ms cold (measured for `orphanedPortNames` in the
/// logic_health profile, same walk).
///
/// Ambiguity is reported as ambiguity: with an orphaned twin of the same name
/// present, two endpoints answer and this returns the one holding an EXPECTED
/// id, or nil if neither does. `orphanedPortNames()` is the check that says
/// the list is dirty.
public func sourceUniqueID(named name: String) -> Int32? {
    var matches: [Int32] = []
    for index in 0..<MIDIGetNumberOfSources() {
        let source = MIDIGetSource(index)
        guard endpointName(source) == name else { continue }
        matches.append(endpointUniqueID(source))
    }
    if matches.count == 1 { return matches[0] }
    return matches.first { expectedPortUniqueIDs.contains($0) }
}

/// One CoreMIDI endpoint as the port census sees it: what it is called, the
/// identity Logic binds to, and which direction it points.
///
/// A plain value type so the classification that reads it is pure and can be
/// unit-tested against a port list this Mac does not have — an orphaned twin
/// is exactly the state that cannot be arranged on demand.
public struct MIDIEndpointInfo: Equatable, Sendable {
    /// `kMIDIPropertyName`. Empty when CoreMIDI publishes none, which is
    /// reported as emptiness rather than guessed at.
    public let name: String
    /// `kMIDIPropertyUniqueID` — the number Logic scopes a control-surface or
    /// key-command binding to.
    public let uniqueID: Int32
    /// True for a SOURCE (Logic reads from it), false for a destination.
    public let isSource: Bool

    public init(name: String, uniqueID: Int32, isSource: Bool) {
        self.name = name
        self.uniqueID = uniqueID
        self.isSource = isSource
    }
}

/// The four endpoints a healthy bridge publishes, with the fixed identities
/// `setUpMIDI` claims for them. The list is the doctor's expectation, and the
/// same numbers `expectedPortUniqueIDs` holds as a set.
public let expectedBridgeEndpoints: [MIDIEndpointInfo] = [
    MIDIEndpointInfo(name: "Logic MCP MCU", uniqueID: 0x4C4D_4330, isSource: false),
    MIDIEndpointInfo(name: "Logic MCP MCU", uniqueID: 0x4C4D_4331, isSource: true),
    MIDIEndpointInfo(name: "Logic MCP Commands", uniqueID: 0x4C4D_4332, isSource: true),
    MIDIEndpointInfo(name: "Logic MCP MIDI In", uniqueID: 0x4C4D_4333, isSource: true)
]

/// Every CoreMIDI endpoint on this Mac, sources then destinations.
///
/// No MIDIClient is created: enumeration is a read of the CoreMIDI object
/// graph, so this costs the same 0.8 ms warm / 16.6 ms cold walk
/// `orphanedPortNames()` was measured at and does not make the doctor a MIDI
/// participant. That matters — a support tool must not add a port to the list
/// it is reporting on.
public func midiEndpointCensus() -> [MIDIEndpointInfo] {
    var census: [MIDIEndpointInfo] = []
    for index in 0..<MIDIGetNumberOfSources() {
        let source = MIDIGetSource(index)
        census.append(MIDIEndpointInfo(
            name: endpointName(source), uniqueID: endpointUniqueID(source), isSource: true
        ))
    }
    for index in 0..<MIDIGetNumberOfDestinations() {
        let destination = MIDIGetDestination(index)
        census.append(MIDIEndpointInfo(
            name: endpointName(destination), uniqueID: endpointUniqueID(destination), isSource: false
        ))
    }
    return census
}

/// Lists this bridge's ports that carry an unexpected unique ID, i.e. orphans
/// left behind by a dead daemon. Empty means the port list is clean.
public func orphanedPortNames() -> [String] {
    var orphans: [String] = []
    for index in 0..<MIDIGetNumberOfSources() {
        let source = MIDIGetSource(index)
        let name = endpointName(source)
        guard name.hasPrefix("Logic MCP") else { continue }
        if !expectedPortUniqueIDs.contains(endpointUniqueID(source)) { orphans.append("\(name) (input)") }
    }
    for index in 0..<MIDIGetNumberOfDestinations() {
        let destination = MIDIGetDestination(index)
        let name = endpointName(destination)
        guard name.hasPrefix("Logic MCP") else { continue }
        if !expectedPortUniqueIDs.contains(endpointUniqueID(destination)) { orphans.append("\(name) (output)") }
    }
    return orphans
}
