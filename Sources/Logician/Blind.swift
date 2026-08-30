import Foundation

/// `blind: true` — the listening-first opt-in for the three tools that carry
/// audio back.
///
/// A live multimodal round proved the audio loop works end to end and exposed
/// the one failure it cannot detect: handed BOTH the audio and the metadata,
/// the model anchored on the metadata and presented region names it had READ
/// as things it had HEARD. Deleting the metadata would be the wrong fix — the
/// numbers are how a mix decision gets CONFIRMED, and this server's whole
/// result contract is built on reporting them. So the caller can DEFER them
/// for one call instead.
///
/// WHAT IS WITHHELD is exactly one class of fact: MEASUREMENTS OF THE AUDIO —
/// per-file peak/RMS, and the dB deltas of an A/B. Those are the only keys a
/// model can paraphrase into a listening impression while lying about nothing
/// else ("it got louder" reads identically whether it was heard or read off
/// `rms_delta_db`). Everything else stays, and each category is a deliberate
/// keep:
///
///  - THE AUDIO and every path that leads to it (`_audio`, `_audio_list`,
///    `path`, `preview_path`, `slice.path`, `baseline_audio`, `after_audio`,
///    the full/preview variants). A blind result that could not be listened to
///    would defeat its own purpose.
///  - THE SAFETY-CRITICAL FIELDS, whatever they cost the blind: `success`,
///    `verified`, `state`, `warning`, `write_route`, plus each tool's
///    restore-state flag (`unfrozen`, `solo_restored`, `decision`).
///    HONESTY BEATS BLINDNESS is the tie-breaker, and `warning` is where it
///    bites: the silent-bounce warning quotes the very RMS this withholds. It
///    keeps its numbers. A model inventing a description of a silent file is a
///    far worse outcome than a model reading one number it would rather not
///    have had — and the warning is the only thing standing between those two.
///  - WHAT THE CALLER ALREADY KNOWS, because withholding an argument's echo
///    hides nothing: `start_bar`/`end_bar`, `track`/`track_name`, `range`,
///    `method`, and the `change` block (its `parameter`, `before` and
///    `applied` are the compare-and-set values the call itself named).
///  - CONTAINER AND PROJECT FACTS that describe the FILE rather than the
///    sound: `bytes`, `delivered_as`, `slice`'s frames/sample_rate/channels,
///    `tempo_map`, `meter_map`, `options_changed`. None of these can be
///    restated as an impression of music.
///
/// SEALED, NOT DESTROYED. The withheld keys are written to a JSON file and the
/// result names it in `sealed_metrics_path`. That is the load-bearing design
/// decision here, and it is driven by `logic_evaluate_change`: an A/B costs
/// 30–50 s and two full renders, so "re-run without blind" would charge a
/// second A/B for numbers the first one already computed — and
/// `logic_get_audio_clip` cannot recompute them (it encodes a clip, it does
/// not measure one). Meanwhile a PATH is inert in a way a key is not: an agent
/// reading the result it just received cannot trip over the numbers by
/// accident, but opening one named file afterwards costs nothing and
/// re-renders nothing. The seal lands in the captures directory, whose
/// resource layer serves an audio-extension ALLOW-LIST — so a `.json` there is
/// deliberately NOT fetchable through `resources/read` either. The agent opens
/// it with its own file tool, on purpose, after it has said what it heard.
enum Blind {
    /// The sentence that replaces every withheld section. One note, not one
    /// per removed key: the agent needs to know the shape of the result
    /// changed, not to be reminded five times.
    static let note = "Metadata withheld at your request — describe the audio from"
        + " LISTENING, then re-run without blind (or call the read tools) for the numbers."

    /// Appended when the seal was written, so the deferral is visibly a
    /// deferral rather than a loss.
    static let sealedNote = " The withheld keys were NOT discarded — they are sealed in the"
        + " JSON file at `sealed_metrics_path`. Open it with your own file tool AFTER you have"
        + " written down what you heard; nothing needs re-rendering."

    /// Appended when the seal could not be written. Never silent: an agent
    /// that was promised a file it will not find would waste a turn looking.
    static let unsealedNote = " The withheld keys could NOT be written to disk, so they are"
        + " gone from this result entirely — re-run without blind to recompute them."

    /// The withheld keys per tool, as dotted paths into the result.
    ///
    /// A table rather than a rule ("anything called metrics") on purpose: each
    /// entry below is a decision that had to be defended against the keeps
    /// listed in this type's documentation, and a new audio-carrying key must
    /// be argued about rather than swept up by a pattern match.
    static let policies: [String: [String]] = [
        // The only measurement in the payload. `soloed_tracks` is NOT here:
        // it is the fact that this bounce contains one track instead of the
        // mix, the `warning` beside it already names those tracks, and hiding
        // the key while the warning spells it out would be theatre.
        "logic_bounce_range": ["metrics"],
        // Two measurements: the whole render's, and the bar-range slice's.
        // `slice.path` is the audio the ear copy was encoded from and stays.
        "logic_render_track": ["metrics", "slice.metrics"],
        // Both sides and the comparison. The deltas are the point of the
        // deferral: an A/B decided from `rms_delta_db` is not an A/B by ear.
        // Identical across all three methods, which build the same key set.
        "logic_evaluate_change": ["baseline_metrics", "after_metrics", "deltas"]
    ]

    /// The blind form of a result, or the result unchanged when this tool has
    /// no policy or the payload is not a dictionary.
    static func applied(toolName: String, payload: Any) -> Any {
        guard let paths = policies[toolName], var result = payload as? [String: Any] else {
            return payload
        }
        var sealed: [String: Any] = [:]
        for path in paths {
            if let value = remove(path: path.components(separatedBy: "."), from: &result) {
                sealed[path] = value
            }
        }
        var blindNote = note
        // Nothing to withhold is a real outcome, not a bug: a WAVE bounce has
        // no `metrics` because the reader parses AIFF only. Say the truth —
        // no seal exists, and none was needed.
        if !sealed.isEmpty {
            if let path = seal(sealed, toolName: toolName) {
                result["sealed_metrics_path"] = path
                blindNote += sealedNote
            } else {
                blindNote += unsealedNote
            }
        }
        result["blind_note"] = blindNote
        return result
    }

    /// Removes one dotted path, returning what was there. Recursive so a
    /// nested measurement (`slice.metrics`) is withheld without taking the
    /// audio path beside it.
    private static func remove(path: [String], from object: inout [String: Any]) -> Any? {
        guard let head = path.first else { return nil }
        if path.count == 1 {
            return object.removeValue(forKey: head)
        }
        guard var child = object[head] as? [String: Any] else { return nil }
        let taken = remove(path: Array(path.dropFirst()), from: &child)
        // Write the pruned child back only when something actually left it,
        // so a miss cannot silently rewrite the branch.
        if taken != nil { object[head] = child }
        return taken
    }

    /// Writes the seal beside the renders it describes. Returns nil rather
    /// than throwing: a seal that cannot be written must not fail the call —
    /// the audio is already made, and `unsealedNote` reports the loss.
    private static func seal(_ withheld: [String: Any], toolName: String) -> String? {
        let document: [String: Any] = [
            "tool": toolName,
            "sealed_at": ISO8601DateFormatter().string(from: Date()),
            "why": "Withheld from the tool result because the call passed blind: true."
                + " Read this AFTER describing the audio.",
            "withheld": withheld
        ]
        guard JSONSerialization.isValidJSONObject(document),
              let data = try? JSONSerialization.data(
                  withJSONObject: document, options: [.prettyPrinted, .sortedKeys]
              ) else { return nil }
        let destination = Captures.ensureRoot().appendingPathComponent(
            "sealed-metrics-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
        )
        guard (try? data.write(to: destination)) != nil else { return nil }
        return destination.path
    }
}
