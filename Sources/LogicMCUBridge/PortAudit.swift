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
