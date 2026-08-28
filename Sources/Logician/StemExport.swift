import Foundation

/// G54: stems. The pure half — what a stem request has to satisfy before
/// anything is bounced, and whether the files that came out are actually
/// aligned. Kept separate from the choreography for the usual reason: this is
/// arithmetic and argument hygiene, and neither should need Logic running to
/// be trusted.
enum StemExport {
    /// The most tracks one call will bounce. Each stem is a full offline
    /// master render of the range, so a 30-track request is half an hour of
    /// dialog driving during which nothing else may touch Logic — better
    /// refused with the number named than discovered at stem 19.
    static let maximumTracks = 16

    /// Cleans and checks the track list. Duplicates are refused rather than
    /// de-duplicated: a repeated name in a stem request usually means the
    /// caller believes two different tracks share it, and silently bouncing
    /// one of them twice would produce a stem set that looks complete and is
    /// not.
    static func normalizedTracks(_ raw: [String]) throws -> [String] {
        let tracks = raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !tracks.isEmpty else {
            throw LogicianError.invalidArguments("tracks must list at least one track name")
        }
        guard tracks.count <= maximumTracks else {
            throw LogicianError.invalidArguments(
                "\(tracks.count) tracks is more than this tool bounces in one call "
                    + "(limit \(maximumTracks)): every stem is a full offline master render, so "
                    + "the call would hold Logic for a long time. Split the list."
            )
        }
        var seen = Set<String>()
        for track in tracks {
            guard seen.insert(track.lowercased()).inserted else {
                throw LogicianError.invalidArguments(
                    "'\(track)' is listed twice. Nothing was bounced - a duplicate name would "
                        + "produce two identical stems while a real track went missing. Use "
                        + "logic_list_tracks to get the exact names."
                )
            }
        }
        return tracks
    }

    /// Are the stems the same length? Stems that are not sample-aligned are
    /// not stems — a mixer lining them up at zero would hear the difference —
    /// so this is the tool's own verification, and it answers "cannot tell"
    /// as its own case rather than as agreement.
    static func frameAlignment(_ frames: [Int?]) -> (aligned: Bool, note: String) {
        let known = frames.compactMap { $0 }
        guard !known.isEmpty else {
            return (false, "no stem's frame count could be read, so alignment is UNVERIFIED - the files exist but nothing proves they line up.")
        }
        guard known.count == frames.count else {
            return (false, "only \(known.count) of \(frames.count) stems published a frame count; alignment is UNVERIFIED for the rest.")
        }
        guard let first = known.first, known.allSatisfy({ $0 == first }) else {
            let spread = (known.max() ?? 0) - (known.min() ?? 0)
            return (false, "the stems are NOT the same length (spread \(spread) frames, \(known.min() ?? 0)-\(known.max() ?? 0)). They will not line up at zero; bounce them again.")
        }
        return (true, "all \(known.count) stems are \(first) frames long.")
    }

    /// What a solo-bounced stem actually contains. One sentence, in one place,
    /// because it is the thing an agent will get wrong: these are not
    /// per-track renders, they are the MASTER OUTPUT heard one track at a time.
    static let contentsNote =
        "WHAT THESE STEMS CONTAIN: each file is a full offline bounce of the MASTER OUTPUT with "
        + "only that one track soloed. So each stem is POST-fader, POST-pan, POST-insert, includes "
        + "the return of anything that track sends to a bus (its reverb tail travels with it), and "
        + "has the master chain applied. That is what a mixer usually means by a stem - and it has "
        + "two consequences worth saying out loud: (1) summing the stems reproduces the mix only "
        + "while the master chain is LINEAR; a master limiter or compressor reacts to the full mix "
        + "and cannot react to one stem, so the sum will be louder and less controlled than the "
        + "real bounce. (2) A bus fed by SEVERAL of these tracks contributes to each of their "
        + "stems, so those tracks' shared reverb is counted more than once in the sum. "
        + "logic_render_track is the other kind of file - a PRE-fader freeze of the track alone, "
        + "no sends, no master chain - and it is not a stem."
}
