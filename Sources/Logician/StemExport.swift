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

    // MARK: - Is anything soloed? (the question this tool exists to answer)

    /// The solo state of the WHOLE project, assembled from the two planes that
    /// can be asked and honest about what each one proves.
    ///
    /// The reason this is a type rather than a boolean: the two planes do not
    /// see the same project. `parsedTrackHeaders()` publishes only the track
    /// headers Logic has currently RENDERED, so a solo on a hidden track, a
    /// scrolled-out row, or a subtrack of a collapsed stack is invisible to it —
    /// and that used to be the whole census. Measured live 2026-09-02 on
    /// `Testlåt Copy`: `Kick Tight` (track 10, inside the collapsed
    /// `Drum Synth Kit` stack) soloed, the stack collapsed, and
    /// `logic_export_stems` walked past its own pre-flight refusal, bounced a
    /// stem containing both tracks, and returned `verified: true` — on the one
    /// tool whose entire contract is one track per file.
    ///
    /// The control surface's rude-solo indicator does see the whole project
    /// (`MCUController.rudeSoloLED`), so it is the plane that gets to say
    /// "clear". The headers are kept because they are the only plane that can
    /// say WHICH tracks — a name is what an agent needs to fix the problem.
    struct SoloCensus: Equatable {
        /// Names read from the rendered track headers. `nil` means the Tracks
        /// area could not be read at all, which is never `[]`.
        let namedByHeaders: [String]?
        /// The surface's project-wide solo indicator: `true` something is
        /// soloed somewhere, `false` nothing is anywhere, `nil` the surface
        /// could not be asked.
        let surfaceSaysSoloed: Bool?

        /// Positive evidence that a solo is up somewhere. Either plane can
        /// raise it; neither is required to.
        var soloed: Bool { surfaceSaysSoloed == true || !(namedByHeaders ?? []).isEmpty }

        /// Neither plane answered, so nothing at all is known.
        var blind: Bool { surfaceSaysSoloed == nil && namedByHeaders == nil }

        /// The only thing that counts as PROOF the project is solo-clean. A
        /// header walk cannot supply it at any length: absence of evidence
        /// there is not evidence of absence (see `TrackListCompleteness`).
        var provenClear: Bool { surfaceSaysSoloed == false }

        /// A solo the surface can see and the Tracks area cannot — the exact
        /// hole this census was added to close.
        var hiddenSolo: Bool { surfaceSaysSoloed == true && (namedByHeaders ?? []).isEmpty }

        /// The evidence block a result carries, so the verdict can be audited
        /// rather than believed.
        var evidence: [String: Any] {
            [
                "surface_indicator": surfaceSaysSoloed
                    .map { $0 ? "soloed" : "clear" } ?? "unavailable",
                "rendered_headers_soloed": namedByHeaders as Any? ?? "unavailable",
                "route": "mcu_rude_solo_led + ax_track_headers",
                "note": "Only surface_indicator covers the whole project; the header list"
                    + " covers only the rows Logic has currently rendered."
            ]
        }
    }

    /// Why the run must not start, or nil to go ahead. Pure, so the decision is
    /// tested without Logic.
    static func soloRefusal(_ census: SoloCensus) -> String? {
        if let named = census.namedByHeaders, !named.isEmpty {
            var reason = "\(named.joined(separator: ", ")) already soloed."
            if census.surfaceSaysSoloed == nil {
                reason += " (The control surface could not be asked, so there may be more.)"
            }
            return reason + " Nothing was bounced - every stem would have contained those"
                + " tracks too. Unsolo and call again."
        }
        if census.hiddenSolo {
            return "the control surface's project-wide solo indicator is LIT while no RENDERED"
                + " track header is soloed - so the soloed track is one Logic is not showing:"
                + " hidden, scrolled out of the Tracks area, or inside a collapsed track stack."
                + " Nothing was bounced; every stem would have contained it. logic_list_tracks"
                + " names the rows that are missing, logic_set_track_stack expands a stack, and"
                + " logic_list_strips walks every strip the surface can reach - unsolo it there"
                + " and call again."
        }
        if census.blind {
            return "neither Logic's track headers nor the control surface could be asked whether"
                + " anything is soloed. Nothing was bounced - a stem set whose one-track-per-file"
                + " claim cannot be checked is worse than no stem set. Run logic_health and call"
                + " again."
        }
        return nil
    }

    /// What the post-run census has to say out loud. Empty when the surface
    /// proved the project solo-clean; otherwise one sentence per problem, in
    /// the words the result carries.
    static func soloWarnings(after census: SoloCensus) -> [String] {
        var warnings: [String] = []
        if let named = census.namedByHeaders, !named.isEmpty {
            warnings.append(
                "Tracks still SOLOED after the run: \(named.joined(separator: ", "))."
                    + " Fix before any further bounce."
            )
        } else if census.hiddenSolo {
            warnings.append(
                "A solo is STILL UP somewhere after the run: the control surface's project-wide"
                    + " indicator is lit though no rendered track header shows one, so it is on a"
                    + " track Logic is not showing. Fix before any further bounce."
            )
        }
        if census.surfaceSaysSoloed == nil {
            warnings.append(
                "The control surface's project-wide solo indicator could not be read after the"
                    + " run, so whether a solo is still up ANYWHERE is UNKNOWN and verified is"
                    + " false. Logic's track headers only cover the rows it has rendered - check"
                    + " the mixer before any further bounce."
            )
        }
        if census.namedByHeaders == nil {
            warnings.append(
                "Logic's track headers could not be read after the run, so no soloed track could"
                    + " be NAMED."
            )
        }
        return warnings
    }

    /// The per-stem `warning`, composed rather than overwritten.
    ///
    /// The two conditions used to write the same key one after the other, so a
    /// stem that both failed to unsolo AND came back silent reported only the
    /// silence — and they co-occur exactly when it matters, because a solo that
    /// will not switch off is what makes the NEXT stems wrong while a silent
    /// stem is what an agent stops to investigate. The more serious sentence
    /// leads and neither is lost.
    static func stemWarning(track: String, soloRestored: Bool, silentRms: [Double]?) -> String? {
        var parts: [String] = []
        if !soloRestored {
            parts.append("the solo on '\(track)' could NOT be switched off again")
        }
        if let silentRms {
            parts.append("this stem is SILENT (rms \(silentRms) dB)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ALSO: ")
    }

    /// Whether a stem's channel RMS values mean silence. One place, so the
    /// per-stem warning and the top-level one cannot drift apart.
    static func silentRms(_ metrics: [String: Any]?) -> [Double]? {
        guard let rms = metrics?["rms_db"] as? [Double], !rms.isEmpty,
              rms.allSatisfy({ $0 <= -65 }) else { return nil }
        return rms
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
