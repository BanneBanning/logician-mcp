import ApplicationServices
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

    // MARK: - Routing an imported track onto a track that already exists

    /// One `tracks[]` entry's request to land somewhere other than the new
    /// track Logic makes for it.
    ///
    /// `track` is the SMF track name, which is also the REGION name Logic hands
    /// back — the only correspondence between "what was asked for" and "what
    /// appeared" that the import gives (R2 §5). `destination` is a track that
    /// already exists in the project.
    struct Routing: Equatable {
        /// The SMF track name = the imported region's name.
        let track: String
        /// The existing track the region is moved onto.
        let destination: String
        /// Disambiguates duplicate destination names; nil when the name is
        /// unique enough on its own.
        let destinationNumber: Int?
    }

    /// The `to_track` / `to_track_number` pairs out of the `tracks[]` array, in
    /// order, with the three argument-level refusals that do not need Logic.
    ///
    /// PER TRACK, not top level: a multi-track import routes drums onto Drums
    /// and bass onto Bas in one call, and any subset may be left out — those
    /// entries keep the new track Logic makes for them.
    static func routings(from raw: [[String: Any]]) throws -> [Routing] {
        var routings: [Routing] = []
        var claimed: [String: String] = [:] // destination key -> the track that claimed it
        for (index, entry) in raw.enumerated() {
            let ordinal = "tracks[\(index)]"
            let name = (entry["name"] as? String) ?? ordinal
            let number = integer(entry["to_track_number"])
            guard let destination = entry["to_track"] as? String,
                  !destination.trimmingCharacters(in: .whitespaces).isEmpty else {
                guard number == nil else {
                    throw LogicianError.invalidArguments(
                        "\(ordinal) has to_track_number but no to_track. The number only"
                            + " disambiguates duplicate destination NAMES; pass to_track as well,"
                            + " or leave both out and this track lands on a new track of its own."
                    )
                }
                continue
            }
            // Two imported tracks onto one destination would stack both regions
            // on the same lane at the same bar — audible as one part playing
            // over another, and impossible to tell apart afterwards.
            let key = destination.lowercased() + "#" + (number.map(String.init) ?? "")
            if let earlier = claimed[key] {
                throw LogicianError.invalidArguments(
                    "'\(earlier)' and '\(name)' both route to '\(destination)'. Two imported"
                        + " tracks cannot share one destination: both regions would land on that"
                        + " track at the same bar, on top of each other. Give one of them its own"
                        + " destination, or leave its to_track out so it keeps a new track."
                )
            }
            claimed[key] = name
            routings.append(Routing(
                track: name, destination: destination, destinationNumber: number
            ))
        }
        return routings
    }

    /// A track header, as the destination resolver sees one.
    struct TrackHeader: Equatable {
        let number: Int
        let name: String

        init(number: Int, name: String) {
            self.number = number
            self.name = name
        }

        /// From `logic_list_tracks`' rows.
        init?(row: [String: Any]) {
            guard let number = row["track_number"] as? Int,
                  let name = row["track_name"] as? String else { return nil }
            self.number = number
            self.name = name
        }
    }

    /// What resolving one destination against the visible track headers found.
    enum DestinationResolution: Equatable {
        case resolved(TrackHeader)
        /// No header carries the name. Carries what IS there, so the retry is
        /// informed rather than a second guess.
        case notFound(candidates: [String])
        /// Several headers carry it and no `to_track_number` said which.
        case ambiguous(numbers: [Int])
        /// A `to_track_number` was given and that track is named something else.
        case mismatch(number: Int, actual: String)
    }

    /// Resolves one destination BEFORE anything is imported.
    ///
    /// Early on purpose: a destination that turns out not to exist after the
    /// import has already run leaves temp tracks and default patches behind to
    /// clean up, and the cleanup is the part that can fail. Resolving first
    /// makes the refusal free — nothing has been written when it fires.
    static func resolve(
        destination: String, number: Int?, in headers: [TrackHeader]
    ) -> DestinationResolution {
        if let number {
            guard let row = headers.first(where: { $0.number == number }) else {
                return .notFound(candidates: headers.map(\.name))
            }
            guard row.name.caseInsensitiveCompare(destination) == .orderedSame else {
                return .mismatch(number: number, actual: row.name)
            }
            return .resolved(row)
        }
        let hits = headers.filter {
            $0.name.caseInsensitiveCompare(destination) == .orderedSame
        }
        switch hits.count {
        case 0: return .notFound(candidates: headers.map(\.name))
        case 1: return .resolved(hits[0])
        default: return .ambiguous(numbers: hits.map(\.number).sorted())
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
    /// house rule `logic_reset_to` already follows — so this is one of the two
    /// gates; `recognise(texts:shapeMatches:)` is the one callers use.
    static func isTempoPrompt(texts: [String]) -> Bool {
        texts.contains {
            $0.trimmingCharacters(in: .whitespaces)
                .lowercased()
                .hasPrefix(LogicUIStrings.AlertMarker.alsoImportTempo)
        }
    }

    /// WHY the tempo prompt was recognised — or that it was not.
    ///
    /// Two independent witnesses, and the result says which spoke:
    ///
    /// * **shape** — three buttons identified `action-button-1…3` plus a
    ///   `supression-checkbox`. Identifiers, so this holds in any language.
    ///   It is what separates the tempo prompt from the OTHER alert an import
    ///   can meet — the save-changes prompt, which has the same three buttons
    ///   and NO checkbox (R2 §3.5, §8).
    /// * **text** — the alert's first line, "Also import tempo information?".
    ///   English only.
    ///
    /// Either alone is enough to answer. Reporting which one fired is the
    /// point: on an English Logic both do, and the day only the shape does is
    /// the day this server learns it is talking to a translated Logic.
    enum PromptRecognition: String, Equatable {
        case shapeAndText = "shape+text"
        case shapeOnly = "shape"
        case textOnly = "text"
        case unrecognised = "unrecognised"

        var recognised: Bool { self != .unrecognised }
    }

    static func recognise(texts: [String], shapeMatches: Bool) -> PromptRecognition {
        switch (shapeMatches, isTempoPrompt(texts: texts)) {
        case (true, true): return .shapeAndText
        case (true, false): return .shapeOnly
        case (false, true): return .textOnly
        case (false, false): return .unrecognised
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

// MARK: - Reading the RIGHT region back

extension ImportMIDI {

    /// Which region a `verify: "events"` pass must read for one written track,
    /// and the ADDRESS to read it by.
    ///
    /// The track NUMBER is the whole point. An unrouted import lands on a track
    /// Logic names after the default patch it loaded, so EVERY unrouted import
    /// in a project produces another track called `Studio Grand` — twelve of
    /// them in one measured session. Addressing the read by track NAME
    /// therefore resolves the wrong region from the second import onwards
    /// (measured 2026-09-02: the pass read `IMPPROF-C1` while claiming to check
    /// `IMPPROF-E1`, and then reported a mismatch in notes it had never
    /// looked at). The census diff already carries the number; this is where it
    /// gets used.
    struct VerifyTarget: Equatable {
        let regionName: String
        let trackName: String
        let trackNumber: Int
        let startBar: Int?
    }

    /// The landed region carrying this written track's name, addressed by row.
    /// `nil` when nothing landed under that name — which the census guard has
    /// already refused, so it means "report it unverified", never "skip it
    /// quietly".
    static func verifyTarget(
        forTrackNamed name: String, in landed: [RegionCensus.Entry]
    ) -> VerifyTarget? {
        guard let entry = landed.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { return nil }
        return VerifyTarget(
            regionName: entry.name, trackName: entry.trackName,
            trackNumber: entry.trackNumber, startBar: entry.startBar
        )
    }

    /// How one region's note check came out.
    ///
    /// `unverified` is NOT `mismatched`, and keeping the two apart is the fix
    /// for a measured lie: the tool warned that "the NOTES do not all match"
    /// about notes no read had ever returned. A read that did not happen is a
    /// gap in the evidence, not evidence of a difference.
    enum NoteCheck: String {
        case matched
        case mismatched
        case unverified
    }

    /// The verdict a `verify: "events"` pass reports, and the warning that goes
    /// with it — separate sentences for "these are wrong" and "these were never
    /// read", because they ask the caller to do different things.
    static func noteVerdict(_ checks: [NoteCheck]) -> (verified: Bool, warning: String?) {
        let wrong = checks.filter { $0 == .mismatched }.count
        let unread = checks.filter { $0 == .unverified }.count
        guard wrong > 0 || unread > 0 else { return (true, nil) }
        var sentences: [String] = []
        if wrong > 0 {
            sentences.append(
                "The regions landed, but the NOTES in \(wrong) of them do not match what was"
                    + " written — see note_verification. The import itself completed; nothing"
                    + " was rolled back."
            )
        }
        if unread > 0 {
            sentences.append(
                "\(unread) region(s) could not be READ BACK, so their notes are UNVERIFIED —"
                    + " note_verification says why for each. That is a gap in the evidence and"
                    + " not a mismatch: the census still proved the regions are there, at the"
                    + " bar they were asked for."
            )
        }
        return (false, sentences.joined(separator: " "))
    }
}

// MARK: - Waiting for a dialog to go away

extension ImportMIDI {

    /// Whether an Accessibility read means "this element no longer exists".
    ///
    /// Split out from the AX call so the RULE is pinned by a test: only
    /// `.invalidUIElement` is gone. `.cannotComplete` (the app is busy, which
    /// is exactly what Logic is during an import) and `.notImplemented` are
    /// elements that did not ANSWER, and calling those "closed" would report a
    /// dialog still on screen as dismissed.
    static func elementIsGone(_ status: AXError) -> Bool {
        status == .invalidUIElement
    }
}

/// Waits for a dialog the caller HOLDS to leave the screen: the cheap probe on
/// the retained element every `interval`, the expensive search no more often
/// than every `patience`, and the search always gets the last word.
///
/// Why two clocks (measured 2026-09-02). Searching the tree for something that
/// is ALREADY GONE cannot early-exit, so it walks everything under the root
/// every single time it is asked — 1 811-1 980 ms for the Go-to-Folder sheet
/// and 565-580 ms for the panel window, per look. Asking the retained element
/// for one attribute is a single round trip that answers `invalidUIElement`
/// the moment the window is destroyed.
///
/// But an AppKit panel can be closed and KEPT (its element stays valid), and a
/// probe that never fires must not turn a dismissed dialog into a verification
/// failure. So `confirm` — the search — remains the authority: it runs on the
/// slow clock while waiting, and once more before this returns `false`.
///
/// - Returns: `true` when the dialog is gone, by either witness.
func waitForDisappearance(
    timeout: Double,
    patience: Double,
    interval: Double = 0.1,
    probe: () -> Bool,
    confirm: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var nextConfirm = Date().addingTimeInterval(patience)
    while true {
        if probe() { return true }
        var confirmedJustNow = false
        if Date() >= nextConfirm {
            if confirm() { return true }
            confirmedJustNow = true
            nextConfirm = Date().addingTimeInterval(patience)
        }
        if Date() >= deadline { return confirmedJustNow ? false : confirm() }
        Thread.sleep(forTimeInterval: interval)
    }
}
