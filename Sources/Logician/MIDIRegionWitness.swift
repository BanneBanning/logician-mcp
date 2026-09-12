import Foundation

/// A comparison of the fully displayed Note events, independent of clipboard
/// contents and arrangement bounds. Positions are relative quarter beats plus
/// untouched division/tick fields: no guessed project division setting.
struct MIDIRegionWitness: Equatable {
    let notes: [Data: Int]
    let parameters: Data

    static let columns = ["L", "M", "Position", "Status", "Ch", "Num", "Val", "Articulation", "Off Position/Info"]
    static let filters = ["Notes", "Progr. Change", "Pitch Bend", "Controller", "Aftertouch", "Poly Aftertouch", "Syst. Exclusive", "Additional Info"]
    static let viewOptions: [(String, Bool)] = [
        ("Relative Position", false), ("Event Position and Length as Time", false),
        ("Length as Absolute Position", true), ("Locked", true), ("Muted", true),
        ("Position", true), ("Status", true), ("Channel", true), ("Number", true),
        ("Value", true), ("Articulation", true), ("Length/Info", true)
    ]

    init(entries: [ListEditorEntry], velocities: [[Int]], columns: [String], declared: Int?,
         anchor: RegionTransfer.Position, meter: MeterMap, parameters: Data) throws {
        guard declared == entries.count, entries.count == velocities.count,
              Set(columns) == Set(Self.columns), columns.count == Self.columns.count,
              anchor.onBeat, meter.source == .signatureList,
              meter.events.first?.bar == 1,
              meter.events.allSatisfy({ $0.denominator == 4 && $0.numerator <= 99 }) else {
            throw RegionTransfer.Failure("the MIDI witness has missing rows, columns or position evidence")
        }
        func relative(_ text: String) throws -> [Int] {
            guard let parts = EventListWrite.parse(segments: text), parts.count == 4,
                  parts.allSatisfy({ $0 >= 1 && $0 <= 100_000 }),
                  Double(parts[1]) <= meter.beatsPerBar(atBar: parts[0]) else {
                throw RegionTransfer.Failure("an absolute MIDI position could not be read")
            }
            let beat = meter.beatOffset(bar: parts[0]) + Double(parts[1] - 1)
                - meter.beatOffset(bar: anchor.bar) - Double(anchor.beat - 1)
            guard beat.isFinite, abs(beat) < 10_000_000, beat == beat.rounded() else {
                throw RegionTransfer.Failure("MIDI position is outside the exact comparison range")
            }
            return [Int(beat), parts[2], parts[3]]
        }
        var notes: [Data: Int] = [:]
        for (index, entry) in entries.enumerated() {
            // SysEx and other event forms need their own complete-data reader.
            // All filters must be on, so they cause refusal rather than vanish.
            guard entry.fields["Status"] == "Note", velocities[index].count == 2,
                  velocities[index].allSatisfy({ (0...127).contains($0) }),
                  let channel = Int(entry.fields["Ch"] ?? ""), (1...16).contains(channel),
                  let pitch = entry.fields["Num"], !pitch.isEmpty,
                  entry.fields.count == Self.columns.count else {
                throw RegionTransfer.Failure("only fully readable Note events are currently supported by safe MIDI moves")
            }
            let start = try relative(entry.fields["Position"] ?? "")
            let end = try relative(entry.fields["Off Position/Info"] ?? "")
            guard start.lexicographicallyPrecedes(end) else {
                throw RegionTransfer.Failure("a note's absolute end does not follow its start")
            }
            var fields: [String: Any] = entry.fields.mapValues { $0 as Any }
            fields["Position"] = start
            fields["Off Position/Info"] = end
            // Joining the two display strings would confuse e.g. 11/22 with
            // 112/2. Read and compare the controls separately instead.
            fields["Val"] = velocities[index]
            let key = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            notes[key, default: 0] += 1
        }
        self.notes = notes
        self.parameters = parameters
    }
}
