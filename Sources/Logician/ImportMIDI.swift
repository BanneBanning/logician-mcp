import Foundation

// MARK: - logic_import_midi, everything about it that is not Logic

/// The pure half of `logic_import_midi`: arguments in, an arrangement out; a
/// census before and after, differenced; the tempo prompt's grammar; and the
/// note-for-note comparison that turns "three regions appeared" into "the notes
/// that appeared are the notes that were written".
///
/// It is separate from the Accessibility route for the usual reason — none of
/// this needs Logic running to be trusted, and the parts that decide what gets
/// written and what counts as proof are exactly the parts that should be pinned
/// by tests rather than by a live session.
enum ImportMIDI {

    // MARK: - Arguments to an arrangement

    /// The `tracks` array as `SMFTrack`s, in the order given.
    ///
    /// Ranges are NOT checked here: `SMFWriter.init` validates every value
    /// against the format and names the track and event index it came from, so
    /// duplicating those bounds would be two places to keep in agreement. What
    /// this does is the parsing Swift cannot do implicitly — the pitch
    /// vocabulary, the JSON number shapes — and the two rules that are about
    /// the IMPORT rather than about the file.
    ///
    /// - Throws: `LogicianError.invalidArguments` naming the track.
    static func tracks(from raw: [[String: Any]]) throws -> [SMFTrack] {
        guard !raw.isEmpty else {
            throw LogicianError.invalidArguments("tracks must hold at least one track")
        }
        var seen: Set<String> = []
        return try raw.enumerated().map { index, entry in
            let ordinal = "tracks[\(index)]"
            guard let name = entry["name"] as? String,
                  !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw LogicianError.invalidArguments(
                    "\(ordinal) needs a non-empty name. The SMF track name is the ONLY handle"
                        + " Logic hands back: it becomes the REGION's name, while the new TRACK"
                        + " is named after whatever default patch Logic loaded."
                )
            }
            // Two regions with one name cannot be told apart afterwards, and
            // this tool's verification AND its cleanup both address by name.
            let key = name.lowercased()
            guard seen.insert(key).inserted else {
                throw LogicianError.invalidArguments(
                    "two tracks are both named '\(name)'. Every track name must be unique: the"
                        + " import identifies what it created by region name, and two regions"
                        + " sharing one could not be verified or cleaned up apart."
                )
            }
            var track = SMFTrack(name: name)
            if let channel = integer(entry["channel"]) { track.channel = channel }
            track.notes = try (array(entry["notes"], of: ordinal, called: "notes"))
                .enumerated().map { noteIndex, raw in
                    let what = "\(ordinal).notes[\(noteIndex)]"
                    var note = SMFNote(pitch: try SMFWriter.pitch(raw["pitch"]),
                                       bar: try bar(raw, what: what))
                    note.beat = number(raw["beat"]) ?? 1
                    note.durationBeats = number(raw["duration_beats"]) ?? 1
                    note.velocity = integer(raw["velocity"]) ?? 100
                    note.channel = integer(raw["channel"])
                    return note
                }
            track.controlChanges = try (array(entry["control_changes"], of: ordinal, called: "control_changes"))
                .enumerated().map { changeIndex, raw in
                    let what = "\(ordinal).control_changes[\(changeIndex)]"
                    // `cc` is `logic_record_midi`'s spelling and the documented
                    // one; `controller` is accepted because it is the SMF's.
                    guard let controller = integer(raw["cc"]) ?? integer(raw["controller"]),
                          let value = integer(raw["value"]) else {
                        throw LogicianError.invalidArguments("\(what) needs cc and value (0-127)")
                    }
                    return SMFControlChange(
                        controller: controller, value: value,
                        bar: try bar(raw, what: what), beat: number(raw["beat"]) ?? 1,
                        channel: integer(raw["channel"])
                    )
                }
            track.pitchBends = try (array(entry["pitch_bends"], of: ordinal, called: "pitch_bends"))
                .enumerated().map { bendIndex, raw in
                    let what = "\(ordinal).pitch_bends[\(bendIndex)]"
                    guard let value = integer(raw["value"]) else {
                        throw LogicianError.invalidArguments(
                            "\(what) needs value (-8192..8191, 0 = centre)"
                        )
                    }
                    return SMFPitchBend(
                        value: value, bar: try bar(raw, what: what),
                        beat: number(raw["beat"]) ?? 1, channel: integer(raw["channel"])
                    )
                }
            track.programChanges = try (array(entry["program_changes"], of: ordinal, called: "program_changes"))
                .enumerated().map { programIndex, raw in
                    let what = "\(ordinal).program_changes[\(programIndex)]"
                    guard let program = integer(raw["program"]) else {
                        throw LogicianError.invalidArguments(
                            "\(what) needs program (0-127 on the wire; Logic's UI counts from 1)"
                        )
                    }
                    return SMFProgramChange(
                        program: program, bar: try bar(raw, what: what),
                        beat: number(raw["beat"]) ?? 1, channel: integer(raw["channel"])
                    )
                }
            return track
        }
    }

    private static func array(
        _ value: Any?, of ordinal: String, called key: String
    ) throws -> [[String: Any]] {
        guard let value else { return [] }
        guard let list = value as? [[String: Any]] else {
            throw LogicianError.invalidArguments("\(ordinal).\(key) must be an array of objects")
        }
        return list
    }

    private static func bar(_ raw: [String: Any], what: String) throws -> Int {
        guard let bar = integer(raw["bar"]) else {
            throw LogicianError.invalidArguments("\(what) needs bar (an absolute project bar)")
        }
        return bar
    }

    /// A JSON number as an Int, whichever way the client typed it.
    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double, number == number.rounded() { return Int(number) }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init)
    }

    // MARK: - The file's name

    /// Where the generated file goes, named so a human scrolling the captures
    /// directory can tell what it was and when.
    ///
    /// The arrangement's first track names it, run through the same
    /// `sanitizedFilenameComponent` every render uses — an agent picks these
    /// names, and a track called `../../.ssh/authorized_keys` must become a
    /// filename, not a path.
    static func fileName(firstTrack: String?, timestamp: Int) -> String {
        let label = sanitizedFilenameComponent(firstTrack ?? "", fallback: "arrangement")
        return "logicmcp-import-\(label)-\(timestamp).mid"
    }

    // MARK: - The tempo prompt

    /// Logic's "Also import tempo information?" alert, whose buttons are
    /// identified and NOT titled (the titles are localisable; the identifiers
    /// were measured 2026-08-30).
    enum TempoPrompt: String, Equatable {
        /// "No" — the default, and the only answer that cannot touch the
        /// project's tempo map.
        case no = "action-button-1"
        /// "Import Tempo" — a WRITE to the tempo map in the file's range.
        case importTempo = "action-button-2"
        /// "Cancel" — aborts the import. Used by the cleanup path only.
        case cancel = "action-button-3"
    }

    /// Which button an import answers with. One line, so the policy is a
    /// value the tests can assert instead of a branch inside the AX route.
    static func answer(importTempo: Bool) -> TempoPrompt {
        importTempo ? .importTempo : .no
    }

    /// The alert's own words. Addressed by its FIRST line rather than by the
    /// window title, which is empty (measured 2026-08-30 §3.5).
    ///
    /// A modal that is not this one must never be pressed on a guess — the
    /// house rule `logic_reset_to` already follows — so this is the gate.
    static func isTempoPrompt(texts: [String]) -> Bool {
        texts.contains {
            $0.trimmingCharacters(in: .whitespaces)
                .lowercased()
                .hasPrefix("also import tempo")
        }
    }

    // MARK: - The census

    /// Every region in the project, flattened, as the thing a before/after diff
    /// is taken over.
    struct RegionCensus: Equatable {
        struct Entry: Hashable {
            let trackNumber: Int
            let trackName: String
            let name: String
            let startBar: Int?

            var payload: [String: Any] {
                [
                    "track_number": trackNumber,
                    "track_name": trackName,
                    "region_name": name,
                    "start_bar": startBar ?? NSNull()
                ]
            }
        }

        let entries: [Entry]

        /// From `logic_list_regions`' payload.
        static func parse(_ payload: [String: Any]) -> RegionCensus {
            var entries: [Entry] = []
            for track in (payload["tracks"] as? [[String: Any]]) ?? [] {
                let number = track["track_number"] as? Int ?? 0
                let name = track["track_name"] as? String ?? ""
                for region in (track["regions"] as? [[String: Any]]) ?? [] {
                    entries.append(Entry(
                        trackNumber: number, trackName: name,
                        name: region["name"] as? String ?? "",
                        startBar: region["start_bar"] as? Int
                    ))
                }
            }
            return RegionCensus(entries: entries)
        }

        /// What is here that was not there before.
        ///
        /// A SET difference, not an index one: the import inserts tracks at the
        /// END of the list but Logic renumbers nothing, and comparing by
        /// position would call every region below an insertion "new".
        func added(since before: RegionCensus) -> [Entry] {
            let known = Set(before.entries)
            return entries.filter { !known.contains($0) }
        }
    }

    /// Track numbers present after that were not present before.
    static func addedTrackNumbers(before: [[String: Any]], after: [[String: Any]]) -> [Int] {
        let known = Set(before.compactMap { $0["track_number"] as? Int })
        return after.compactMap { $0["track_number"] as? Int }.filter { !known.contains($0) }.sorted()
    }

    // MARK: - The note diff

    /// One expected note against one observed row: same bar, same beat, same
    /// pitch. Deliberately NOT the division and tick — Logic's Event List
    /// prints a 1/16 grid position that a fractional beat lands inside, and a
    /// diff that demanded those would report drift the writer did not create.
    private struct NoteKey: Hashable {
        let bar: Int
        let beat: Int
        let pitch: Int
    }

    /// What a `verify: "events"` pass found for one track.
    struct NoteDiff: Equatable {
        let expected: Int
        let observed: Int
        /// Expected notes with no row to match them, as "bar 62 beat 1 C3".
        let missing: [String]
        /// Rows with no expected note, same spelling.
        let unexpected: [String]
        /// Notes that landed but not at the velocity they were written with.
        let velocityMismatches: [String]

        var matches: Bool {
            expected == observed && missing.isEmpty && unexpected.isEmpty
                && velocityMismatches.isEmpty
        }

        var payload: [String: Any] {
            var result: [String: Any] = [
                "expected_notes": expected,
                "observed_notes": observed,
                "matches": matches
            ]
            if !missing.isEmpty { result["missing"] = missing }
            if !unexpected.isEmpty { result["unexpected"] = unexpected }
            if !velocityMismatches.isEmpty { result["velocity_mismatches"] = velocityMismatches }
            return result
        }
    }

    /// The written notes against the Event List's rows.
    ///
    /// Non-note rows are ignored rather than counted as unexpected: a program
    /// change or a CC the same call wrote is a row too, and reporting it as an
    /// extra note would make a correct import look wrong.
    static func diff(expected: [SMFNote], observed rows: [EventRow]) -> NoteDiff {
        func describe(bar: Int, beat: Int, pitch: Int, velocity: Int?) -> String {
            "bar \(bar) beat \(beat) \(EventListWrite.noteName(pitch))"
                + (velocity.map { " vel \($0)" } ?? "")
        }
        var wanted: [NoteKey: [Int]] = [:] // key -> velocities, so a unison pair is two entries
        for note in expected {
            let key = NoteKey(bar: note.bar, beat: Int(note.beat.rounded(.down)), pitch: note.pitch)
            wanted[key, default: []].append(note.velocity)
        }
        var missing: [String] = []
        var unexpected: [String] = []
        var velocityMismatches: [String] = []
        var noteRows = 0
        for row in rows where row.isNote {
            noteRows += 1
            guard row.position.count == 4, let pitch = row.pitch else {
                unexpected.append(row.describedBriefly)
                continue
            }
            let key = NoteKey(bar: row.position[0], beat: row.position[1], pitch: pitch)
            guard var velocities = wanted[key], !velocities.isEmpty else {
                unexpected.append(describe(
                    bar: key.bar, beat: key.beat, pitch: pitch, velocity: row.velocity
                ))
                continue
            }
            // Prefer the expected note whose velocity actually matches, so a
            // unison of two velocities is not reported as two mismatches.
            let index = velocities.firstIndex(where: { $0 == row.velocity }) ?? 0
            let velocity = velocities.remove(at: index)
            wanted[key] = velocities
            if let observed = row.velocity, observed != velocity {
                velocityMismatches.append(
                    describe(bar: key.bar, beat: key.beat, pitch: pitch, velocity: nil)
                        + ": wrote \(velocity), Logic shows \(observed)"
                )
            }
        }
        for (key, velocities) in wanted.sorted(by: { ($0.key.bar, $0.key.beat, $0.key.pitch) < ($1.key.bar, $1.key.beat, $1.key.pitch) }) {
            for velocity in velocities {
                missing.append(describe(
                    bar: key.bar, beat: key.beat, pitch: key.pitch, velocity: velocity
                ))
            }
        }
        return NoteDiff(
            expected: expected.count, observed: noteRows,
            missing: missing, unexpected: unexpected.sorted(),
            velocityMismatches: velocityMismatches.sorted()
        )
    }
}
