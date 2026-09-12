import Foundation

/// The destructive half of a clipboard move is permitted only after an exact
/// arrangement witness. No Cut and no automatic Undo: a failed copy leaves the
/// source available, and an uncertain Delete must never be replayed.
enum RegionTransfer {
    struct Position: Equatable, Hashable, Comparable {
        let bar: Int
        let beat: Int
        let division: Int
        let tick: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            [lhs.bar, lhs.beat, lhs.division, lhs.tick]
                .lexicographicallyPrecedes([rhs.bar, rhs.beat, rhs.division, rhs.tick])
        }
        var onBeat: Bool { division == 1 && tick == 1 }

        static func parse(_ raw: String) -> Self? {
            let pattern = #"^\s*(\d+) bars?(?:\s+(\d+) beats?)?(?:\s+(\d+) divisions?)?(?:\s+(\d+) ticks?)?\s*$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw))
            else { return nil }
            var values: [Int] = []
            for index in 1...4 {
                if let range = Range(match.range(at: index), in: raw) {
                    guard let value = Int(raw[range]), value >= 1, value <= 100_000 else { return nil }
                    values.append(value)
                } else { values.append(1) }
            }
            return Self(bar: values[0], beat: values[1], division: values[2], tick: values[3])
        }
    }

    struct Region: Hashable {
        let name: String
        let kind: String
        let start: Position
        let end: Position

        init?(name: String, help: String) {
            let pattern = #"^Region starts at (.*?)\s+and ends at (.*?)\s*,\s*([A-Za-z]+) region(?:\.|$)"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: help, range: NSRange(help.startIndex..., in: help)),
                  let startRange = Range(match.range(at: 1), in: help),
                  let endRange = Range(match.range(at: 2), in: help),
                  let typeRange = Range(match.range(at: 3), in: help),
                  let start = Position.parse(String(help[startRange])),
                  let end = Position.parse(String(help[endRange])), start < end else { return nil }
            self.init(name: name, kind: String(help[typeRange]).lowercased(), start: start, end: end)
        }

        init(name: String, kind: String, start: Position, end: Position) {
            self.name = name; self.kind = kind; self.start = start; self.end = end
        }
    }

    struct Row: Equatable {
        let name: String
        var regions: [Region: Int]
        init(name: String, regions: [Region]) {
            self.name = name
            self.regions = regions.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
    }
    typealias Snapshot = [Int: Row]

    struct Plan {
        let source: Region
        let sourceTrack: Int
        let destinationTrack: Int
        let destination: Region
        let copied: Snapshot
        let moved: Snapshot

        init(before: Snapshot, source: Region, sourceTrack: Int, destinationTrack: Int,
             toBar: Int, meter: MeterMap) throws {
            guard toBar >= 1, toBar <= 100_000,
                  before[sourceTrack]?.regions[source] == 1,
                  before[destinationTrack] != nil else {
                throw Failure("source or destination is missing or ambiguous")
            }
            // Fractional positions depend on project division settings that we
            // do not read. Audio can change musical length across tempo changes.
            // Neither may be rounded into a destructive verification.
            guard source.kind == "midi", source.start.onBeat, source.end.onBeat else {
                throw Failure("safe clipboard moves currently require a MIDI region with beat-aligned boundaries; audio and fractional boundaries need further compatibility verification")
            }
            guard meter.source == .signatureList, meter.events.first?.bar == 1,
                  Set(meter.bars).count == meter.events.count,
                  meter.events.allSatisfy({ $0.denominator == 4 && $0.numerator <= 99 }) else {
                throw Failure("a complete signature map with quarter-note beats is required for move verification")
            }
            func offset(_ p: Position) throws -> Double {
                guard Double(p.beat) <= meter.beatsPerBar(atBar: p.bar) else {
                    throw Failure("region position is inconsistent with the signature map")
                }
                return meter.beatOffset(bar: p.bar) + Double(p.beat - 1)
            }
            let duration = try offset(source.end) - offset(source.start)
            let startOffset = meter.beatOffset(bar: toBar)
            let endOffset = startOffset + duration
            let end = meter.position(atBeatOffset: endOffset)
            guard duration > 0, end.bar < 100_000,
                  end.beatInBar.rounded() == end.beatInBar else {
                throw Failure("destination length cannot be represented exactly")
            }
            for region in before[destinationTrack]!.regions.keys {
                let lower = try offset(region.start)
                // Enclose sub-beat neighbours conservatively. Unknown division
                // settings may refuse a close gap, but may never permit overlap.
                let upper = try offset(region.end) + (region.end.onBeat ? 0 : 1)
                if lower < endOffset && upper > startOffset {
                    throw Failure("destination overlaps or is too close to an existing region; nothing was pasted")
                }
            }
            let landed = Region(name: source.name, kind: source.kind,
                start: Position(bar: toBar, beat: 1, division: 1, tick: 1),
                end: Position(bar: end.bar, beat: Int(end.beatInBar), division: 1, tick: 1))
            var copied = before
            copied[destinationTrack]!.regions[landed, default: 0] += 1
            var moved = copied
            moved[sourceTrack]!.regions.removeValue(forKey: source)
            self.source = source; self.sourceTrack = sourceTrack
            self.destination = landed
            self.destinationTrack = destinationTrack; self.copied = copied; self.moved = moved
        }
    }

    struct Failure: LocalizedError, CustomStringConvertible {
        let description: String
        var errorDescription: String? { description }
        init(_ description: String) { self.description = description }
    }

    static func execute(
        plan: Plan, checkProject: () throws -> Void,
        copy: () throws -> Void, verifyCopy: () throws -> Void = {}, prepareDelete: () throws -> Void,
        snapshot: () throws -> Snapshot, delete: () throws -> Void,
        cancelled: () -> Bool = { Task.isCancelled }
    ) throws {
        var phase = "before Copy; no region edit was requested"
        do {
            func checkpoint() throws {
                if cancelled() { throw CancellationError() }
                try checkProject()
            }
            try checkpoint()
            phase = "Copy/Paste attempted; Delete was not sent, so this move has not removed the source. A destination copy may exist"
            try copy()
            try checkpoint()
            guard try snapshot() == plan.copied else {
                throw Failure("the copy or neighbouring region boundaries do not match the expected arrangement")
            }
            try verifyCopy()
            try prepareDelete()
            try checkpoint()
            guard try snapshot() == plan.copied else {
                throw Failure("the arrangement changed while preparing to remove the source")
            }
            phase = "Delete attempted after verifying the copy; its outcome is uncertain until the arrangement is checked"
            try delete()
            try checkpoint()
            guard try snapshot() == plan.moved else {
                throw Failure("the final arrangement does not match a single-region move")
            }
        } catch {
            throw Failure("\(phase). \(error.localizedDescription). Inspect both locations before retrying; no automatic Undo or retry was performed")
        }
    }
}
