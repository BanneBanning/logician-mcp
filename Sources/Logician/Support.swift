import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

let protocolVersion = "2025-06-18"
let serverName = "logician"
let serverVersion = "0.61.0"

/// Schema version stamped into every on-disk cache. Deliberately tied to
/// `serverVersion`: these files hold measurements of Logic's MCU LCD, and a
/// build that changes how the LCD is read, sliced or settled must not inherit
/// the previous build's map. Bumping the server version therefore retires
/// every cache automatically - no separate constant to forget.
let cacheSchemaVersion = serverVersion

/// Identity an on-disk cache is valid for. The maps in these files describe
/// ONE open project as read by ONE build; a file that merely *decodes* in
/// another context is not stale, it is WRONG - and a confidently wrong answer
/// is the single failure mode this server exists to prevent.
func cacheScopeToken(projectPath: String) -> String {
    "v\(cacheSchemaVersion)|\(projectPath)"
}

/// A cache payload stamped with the scope it was measured in.
struct ScopedCache<Payload: Codable>: Codable {
    let scope: String
    let payload: Payload
}

/// Reads `url` only when its stamp matches this build and this project.
/// A nil `projectPath` means the scope cannot be established at all (Logic
/// closed, no Accessibility trust, no document window), and an unscopable
/// cache is treated as absent rather than guessed at. Pre-scope files from
/// older builds simply fail to decode, which is the same answer.
func loadScopedCache<Payload: Codable>(
    _ url: URL, projectPath: String?, as: Payload.Type = Payload.self
) -> Payload? {
    loadScopedCache(url, scope: projectPath.map { cacheScopeToken(projectPath: $0) })
}

/// Writes `payload` stamped with the current scope. A no-op without a project
/// path: an unstamped file could never be validated on the way back in, so it
/// would be a trap for the next run rather than a cache.
func saveScopedCache<Payload: Codable>(
    _ payload: Payload, to url: URL, projectPath: String?
) {
    saveScopedCache(payload, to: url, scope: projectPath.map { cacheScopeToken(projectPath: $0) })
}

/// The same discipline for a cache whose identity is NOT the open project.
/// The plug-in catalog, for instance, is a property of the Logic INSTALL: it
/// must survive opening another project and must not survive installing a
/// plug-in, which is the opposite of what `projectPath` scoping would do.
/// `deleteOnMismatch` is for the caller who would rather retire a file it can
/// never use again than leave it lying around to be re-read and re-rejected.
func loadScopedCache<Payload: Codable>(
    _ url: URL, scope: String?, as: Payload.Type = Payload.self,
    deleteOnMismatch: Bool = false
) -> Payload? {
    guard let scope, let data = try? Data(contentsOf: url) else { return nil }
    guard let decoded = try? JSONDecoder().decode(ScopedCache<Payload>.self, from: data),
          decoded.scope == scope else {
        if deleteOnMismatch { try? FileManager.default.removeItem(at: url) }
        return nil
    }
    return decoded.payload
}

func saveScopedCache<Payload: Codable>(_ payload: Payload, to url: URL, scope: String?) {
    guard let scope,
          let data = try? JSONEncoder().encode(ScopedCache(scope: scope, payload: payload))
    else { return }
    try? data.write(to: url)
}

/// Reduces an agent-supplied string to a safe single filename component:
/// keeps `[A-Za-z0-9._-]`, collapses everything else (including `/` and `..`
/// path separators) to `-`, and caps the length. Used for every tool label
/// that is glued into an output path, so a label like `../../etc/x` or a
/// track named with a slash can never escape the captures directory.
func sanitizedFilenameComponent(_ raw: String, fallback: String = "clip") -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    var out = String(raw.map { allowed.contains($0) ? $0 : "-" }.prefix(64))
    // A component that is only dots ("." / "..") still resolves as traversal.
    while out.first == "." { out.removeFirst() }
    let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? fallback : trimmed
}

// MARK: - Two-point tempo sampling (tempo-map honesty)

/// How far two tempo readings may differ and still count as the same tempo.
///
/// The control bar's Tempo slider is *written* in whole BPM (`setTempo` rounds
/// its target, and its own compare-and-set uses 0.5), but the value it
/// *publishes* is parsed as a Double and a project whose tempo came from the
/// tempo track can carry decimals — so the epsilon has to sit below any real
/// tempo step and above read noise. 0.05 BPM is that gap: a disagreement that
/// small moves a bar-33 boundary at 120 BPM in 4/4 by roughly 27 ms — inside the
/// ~45 ms sync compensation the MIDI path already lives with — while any
/// deliberate tempo change is at least 0.1 BPM and lands far outside it.
let tempoSampleEpsilonBPM = 0.05

/// A BPM as a result string: "120" for a whole tempo, "120.5" when it isn't.
func formattedBPM(_ value: Double) -> String {
    String(format: "%g", value)
}

/// Two readings of the control bar's *position-dependent* tempo, taken at the
/// two ends of a bar range.
///
/// The control bar shows the tempo AT THE PLAYHEAD, which is exactly what makes
/// this cheap: park the playhead twice and "is the tempo constant across these
/// bars?" becomes two reads — the position-dependence that made the bar math
/// wrong is the sensor that detects it.
///
/// Two points cannot PROVE a constant tempo. A map that leaves both ends alike
/// (up at bar 20, back down before bar 40) reads as constant here, so agreement
/// is evidence, not a guarantee — and no message built from this claims more.
struct TempoSpan: Equatable {
    let startBar: Int
    let endBar: Int
    let startTempo: Double
    let endTempo: Double

    var isConstant: Bool { abs(startTempo - endTempo) <= tempoSampleEpsilonBPM }

    /// "the tempo changes across bars 5-33 (120 BPM at bar 5, 140 BPM at bar 33)"
    var mismatchClause: String {
        "the tempo changes across bars \(startBar)-\(endBar) "
            + "(\(formattedBPM(startTempo)) BPM at bar \(startBar), "
            + "\(formattedBPM(endTempo)) BPM at bar \(endBar))"
    }
}

/// The outcome of a two-point sample. "Could not check" is a first-class case
/// for the same reason `ProjectTempoMode` has one: a check that silently fails
/// open is indistinguishable from a check that passed, and the caller has to be
/// able to say which it got.
enum TempoSpanSample: Equatable {
    case constant(TempoSpan)
    case varying(TempoSpan)
    case unverified(reason: String)

    var span: TempoSpan? {
        switch self {
        case .constant(let span), .varying(let span): return span
        case .unverified: return nil
        }
    }

    var isVarying: Bool {
        if case .varying = self { return true }
        return false
    }
}

/// The tempo-safe alternatives, named the same way in every message so an agent
/// reading a warning and an agent reading a refusal are pointed at one thing.
let tempoSafeAlternatives =
    "use logic_bounce_range, or logic_evaluate_change method \"bounce\"/\"solo_bounce\""
    + " — those hand Logic the bar numbers and let Logic interpret them, so they are"
    + " correct under any tempo map"

/// The `warning` a seconds-sliced result has to carry for a given sample, or nil
/// when the sample came back constant. `sliced` names what was cut, in the words
/// of the tool whose result this lands on.
func tempoSpanWarning(_ sample: TempoSpanSample, sliced: String) -> String? {
    switch sample {
    case .constant:
        return nil
    case .varying(let span):
        return "TEMPO MAP DETECTED: \(span.mismatchClause), read off the control bar with"
            + " the playhead parked at each bar. \(sliced) was computed as"
            + " (bar - 1) x beats x 60/BPM from ONE tempo, so its boundaries drift from the"
            + " first tempo change onward and are unreliable — do not trust them, and do not"
            + " compare this audio against anything cut the same way. For tempo-accurate"
            + " ranges, \(tempoSafeAlternatives)."
    case .unverified(let reason):
        return "TEMPO CONSTANCY NOT VERIFIED: \(reason). \(sliced) assumed a CONSTANT project"
            + " tempo; on a project with a tempo change its boundaries are wrong from that"
            + " change onward. For tempo-accurate ranges, \(tempoSafeAlternatives)."
    }
}

/// The warning a *tempo write* carries when the two-point check could not run.
///
/// Deliberately not `tempoSpanWarning`'s text: nothing was sliced here, and the
/// consequence is not an unreliable boundary but a write that may have landed on
/// a single tempo node. A `.varying` sample never reaches this — that one is
/// refused before the write.
func tempoWriteUnverifiedWarning(_ sample: TempoSpanSample) -> String? {
    guard case .unverified(let reason) = sample else { return nil }
    return "TEMPO MAP NOT VERIFIED: \(reason). The tempo was written to the control bar's"
        + " slider, which shows and sets the tempo AT THE PLAYHEAD — so if this project has a"
        + " tempo map, this write changed the tempo node at the playhead rather than the whole"
        + " project. Check the tempo track (or the Tempo List) and Undo in Logic if that is not"
        + " what you wanted."
}

/// What a live two-point sample came back with: the verdict, plus the one thing
/// that can go wrong while taking it.
///
/// Sampling MOVES the playhead (twice) and puts it back. When the restore fails,
/// the tempo verdict is still valid but the project has been left with its
/// playhead somewhere else — and this codebase does not report a restoration
/// that did not happen, so the leak travels with the verdict instead of being
/// swallowed by it.
struct TempoSample {
    let sample: TempoSpanSample
    let playheadLeak: String?

    static func verdict(_ sample: TempoSpanSample) -> TempoSample {
        TempoSample(sample: sample, playheadLeak: nil)
    }

    var isVarying: Bool { sample.isVarying }
    var span: TempoSpan? { sample.span }

    /// Everything this sample obliges a result to say, or nil when it obliges
    /// nothing (constant tempo, playhead back where it started).
    func warning(sliced: String) -> String? {
        let parts = [tempoSpanWarning(sample, sliced: sliced), playheadLeak].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ALSO: ")
    }

    /// The tempo-write flavour of `warning(sliced:)`, for the one caller that
    /// writes a tempo instead of slicing seconds.
    var writeWarning: String? {
        let parts = [tempoWriteUnverifiedWarning(sample), playheadLeak].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ALSO: ")
    }

    /// The same facts for a refusal's detail: no "use bounce instead" tail
    /// (the refusal names its own alternative) but never without the leak.
    var refusalDetail: String? {
        // Only a VARYING sample gets the mismatch clause: a constant sample's
        // readings would otherwise be narrated as "the tempo changes", which is
        // the one thing it just proved they do not.
        var clause: String?
        if case .varying(let span) = sample { clause = span.mismatchClause }
        let parts = [clause, playheadLeak].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }
}

/// What one tool invocation knows about the project's tempo across the bars it
/// is about to slice: the MAP when Logic's Tempo List could be read, and the
/// two-point sample when it could not.
///
/// The two are not equal evidence and this type never lets them look it. A read
/// map is the whole tempo track, so the boundaries computed from it are exact
/// for step changes and no playhead is moved to get them. A sample is two
/// readings that cannot prove constancy. So: a readable map replaces the sample
/// entirely (and every refusal built on the sample lifts), while an unreadable
/// map falls back to exactly the behavior that shipped before it.
struct TempoKnowledge {
    let startBar: Int
    let endBar: Int
    let beatsPerBar: Double
    /// Non-nil only when the Tempo List read succeeded.
    let map: TempoMap?
    /// Why the read did not succeed — carried into warnings so the fix is
    /// nameable, never swallowed.
    let mapFailure: TempoListFailure?
    /// Taken ONLY when the map is unreadable: with a map there is nothing to
    /// sample for, and the playhead stays where the user left it.
    let sample: TempoSample?

    /// The map, but only if it came from the Tempo List. A one-event
    /// `.singleReading` map is the constant-tempo assumption, not knowledge.
    var readMap: TempoMap? {
        guard let map, map.source == .tempoList else { return nil }
        return map
    }

    /// Does the tempo change across this range, as best this invocation knows?
    /// Nil when nothing could be established either way.
    var isVarying: Bool? {
        if let readMap { return !readMap.isConstant }
        guard let sample else { return nil }
        switch sample.sample {
        case .constant: return false
        case .varying: return true
        case .unverified: return nil
        }
    }

    /// Seconds a tempo CURVE the Tempo List cannot report could move these
    /// boundaries by. Zero when the map has no tempo change at all, and zero
    /// without a read map (that case has its own, larger warning).
    var curveUncertaintySeconds: Double {
        readMap?.curveUncertaintySeconds(
            startBar: startBar, endBar: endBar, beatsPerBar: beatsPerBar
        ) ?? 0
    }

    /// The `tempo_map` block a result carries when the map was actually read.
    var payload: [String: Any]? {
        guard let readMap else { return nil }
        var block: [String: Any] = [
            "source": "tempo_list",
            "events": readMap.events.count,
            "tempos": readMap.tempos,
            "constant": readMap.isConstant,
            "integrated": true
        ]
        if readMap.subBeatPositions {
            block["sub_beat_positions"] = true
        }
        return block
    }

    /// Everything this knowledge obliges a seconds-slicing result to say.
    ///
    /// A CONSTANT read map says nothing at all: it is the one case where the
    /// boundaries are simply right and there is no caveat to carry.
    func warning(sliced: String) -> String? {
        if let readMap {
            guard !readMap.isConstant else { return nil }
            var text = "TEMPO MAP READ AND INTEGRATED: Logic's Tempo List holds"
                + " \(readMap.events.count) tempo events"
                + " (\(readMap.tempos.map(formattedBPM).joined(separator: ", ")) BPM), and"
                + " \(sliced) was computed by integrating them piecewise instead of assuming one"
                + " tempo — exact for step tempo changes."
            let uncertainty = curveUncertaintySeconds
            if uncertainty > 0.001 {
                text += " CAVEAT: Logic's Tempo List publishes only Position, Tempo and SMPTE"
                    + " Position — no curve column (probed 2026-08-27), so a pair of points joined"
                    + " by a tempo CURVE (a continuous ramp) is read as a step. These boundaries"
                    + " are measured from project start, so if any such pair up to bar"
                    + " \(endBar) is actually a curve they move by up to"
                    + " \(Int((uncertainty * 1000).rounded())) ms; check the tempo track for"
                    + " ramps between tempo points."
            }
            if readMap.subBeatPositions {
                text += " One or more tempo points sit OFF the beat; their sub-beat position was"
                    + " converted assuming Logic's default 1/16 division and 960 ppq."
            }
            return text
        }
        guard let sample else { return nil }
        var parts = [sample.warning(sliced: sliced)].compactMap { $0 }
        if let mapFailure {
            parts.append("The tempo map itself could not be read either: \(mapFailure.reason).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The facts a refusal built on this knowledge should carry.
    var refusalDetail: String? { sample?.refusalDetail }
}

/// What one tool invocation knows about the project's METER — the last
/// assumption the bar math carried after the tempo map landed (ROADMAP item 3,
/// "Meter is the last assumption").
///
/// Deliberately smaller than `TempoKnowledge`: there is no two-point fallback to
/// weigh against the map, because there is nothing to sample. The control bar
/// publishes the signature at the playhead, which cannot tell a constant-meter
/// project from a mapped one, so the Signature List either answers or it does
/// not — and when it does not, the bar math keeps the single beats-per-bar it
/// has always used.
struct MeterKnowledge {
    /// Non-nil only when the Signature List read succeeded.
    let map: MeterMap?
    /// Why it did not — carried into the payload so an unread map is visible as
    /// an unread map, never as a constant one.
    let failure: ListEditorFailure?

    /// The map, but only when it came from the Signature List AND actually
    /// changes the arithmetic. This is what every consumer passes down; see the
    /// constant-meter contract on `MeterMap`.
    var integratedMap: MeterMap? {
        guard let map, map.source == .signatureList, map.isVariable else { return nil }
        return map
    }

    /// The `meter_map` block a result carries. Present whenever a read was
    /// ATTEMPTED — a failed read is a fact worth reporting, because it is the
    /// case where the constant-meter assumption is still live.
    var payload: [String: Any] {
        guard let map, map.source == .signatureList else {
            return [
                "read": false,
                "reason": failure?.reason ?? "the Signature List was not read",
                "integrated": false,
                "note": "bar math assumed one beats-per-bar, as it always has"
            ]
        }
        return [
            "read": true,
            "source": "signature_list",
            "events": map.events.count,
            "signatures": map.signatures,
            "bars": map.bars,
            "constant": map.isConstant,
            // A constant map is reported and NOT used: the caller's own
            // beats_per_bar (control bar, or an explicit override) stays
            // authoritative, which keeps a constant-meter project's boundaries
            // bit-for-bit what they have always been.
            "integrated": map.isVariable
        ]
    }

    /// What a VARYING meter obliges a seconds-slicing result to say.
    func warning(sliced: String) -> String? {
        guard let map = integratedMap else { return nil }
        let changes = zip(map.bars, map.signatures)
            .map { "bar \($0.0): \($0.1)" }
            .joined(separator: ", ")
        return "METER MAP READ AND INTEGRATED: Logic's Signature List holds"
            + " \(map.events.count) time signatures (\(changes)), so the bars in this range are"
            + " not all the same length, and \(sliced) was computed by summing each bar's own"
            + " length instead of multiplying by one beats-per-bar. An explicit beats_per_bar"
            + " argument does NOT override a varying meter map — the map is the project's own"
            + " grid."
    }
}

/// Logic's project tempo mode (Smart Tempo): what a recording is allowed to do
/// to the project's tempo map. `Keep` leaves the map alone (the classic
/// behavior), `Adapt` REWRITES it to follow the recording, and `Auto` decides
/// per take — leaning Adapt when the metronome is off and no tempo reference
/// exists. Since Logic 10.4.2 this applies to MIDI recordings too, which is why
/// it is a write-protection concern for `logic_record_midi` and not merely a
/// timing detail: an Adapt-mode take destroys the user's tempo track as a side
/// effect, on a constant-tempo project, silently.
///
/// The two non-mode cases are deliberate. A mode this destructive must never be
/// *assumed* to be Keep just because it could not be read, so "I could not
/// read it" is a first-class answer that callers have to handle.
enum ProjectTempoMode: Equatable {
    case keep
    case adapt
    case auto
    /// The control bar's Project Tempo pop-up button is there, but Logic
    /// publishes no value on it (see `projectTempoMode()` for the probe).
    case unreadable
    /// No Project Tempo pop-up button in the control bar at all.
    case absent

    /// The mode as a result-payload string, nil when it is not known.
    var name: String? {
        switch self {
        case .keep: return "keep"
        case .adapt: return "adapt"
        case .auto: return "auto"
        case .unreadable, .absent: return nil
        }
    }

    /// Why the mode is missing, in the words an agent needs to act on it.
    /// Nil for the three real modes, which need no excuse.
    var explanation: String? {
        switch self {
        case .keep, .adapt, .auto:
            return nil
        case .unreadable:
            return "Logic's control bar does expose the Project Tempo pop-up button (Smart Tempo: Keep/Adapt/Auto), but publishes no value on it through Accessibility — no AXValue, no AXTitle, no AXValueDescription (probed 2026-08-27, Logic Pro 12.3.1, with the LCD in 'Beats & Project', the display mode that shows the mode) — so the mode cannot be read from here. Read it off the LCD's tempo display, or in File → Project Settings → Smart Tempo."
        case .absent:
            return "No Project Tempo pop-up button is present in the control bar, so the Smart Tempo mode (Keep/Adapt/Auto) cannot be read from here. Read it in File → Project Settings → Smart Tempo."
        }
    }
}

/// Maps whatever text Logic puts on the Project Tempo control to a mode.
///
/// Pure and separately tested precisely because the live AX route currently
/// yields nothing (FINDINGS, 2026-08-27): the day Logic starts publishing that
/// value — or the day the pop-up menu route lands — this mapping is what the
/// guard hangs on, and it must be right before it is ever exercised.
func normalizedProjectTempoMode(_ raw: String) -> ProjectTempoMode? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !text.isEmpty else { return nil }
    // The LCD and the menu both label the modes with a single word; match that
    // exactly first, so a longer sentence can never outvote the label itself.
    switch text {
    case "keep": return .keep
    case "adapt": return .adapt
    case "auto": return .auto
    default: break
    }
    // Longer wordings ("Adapt Project Tempo", "Automatic") still resolve, with
    // adapt/auto tested before keep: a string that names more than one mode
    // then errs toward the refusal rather than toward a destructive recording.
    if text.contains("adapt") { return .adapt }
    if text.contains("auto") { return .auto }
    if text.contains("keep") { return .keep }
    return nil
}

/// Uppercases the leading letter so a call-site phrase ("the Mackie Control
/// bridge") can open a sentence. A phrase that starts with a quote or a
/// capital passes through unchanged.
private func sentenceCased(_ text: String) -> String {
    guard let first = text.first, first.isLowercase else { return text }
    return first.uppercased() + text.dropFirst()
}

/// The product's error taxonomy. Every tool failure is one of these, and the
/// `code` values (not_found, precondition_failed, ambiguous,
/// verification_failed, …) are the vocabulary agents branch on — they are
/// documented in docs/AGENT-GUIDE.md, so renaming one is an API change.
enum LogicianError: LocalizedError {
    case accessibilityNotTrusted
    case logicNotRunning
    case windowNotFound(String)
    case parameterNotFound(String)
    case parameterAmbiguous(String, Int)
    case valueNotWritable(String)
    case currentValueMismatch(expected: String, actual: String)
    case writeFailed(String)
    case confirmationFailed(String)
    case verificationFailed(requested: String, actual: String, restored: Bool)
    case invalidArguments(String)
    case projectMismatch(expected: String, actual: String)
    /// Something the operation needed could not be reached. `requested` names
    /// what was needed (a noun phrase: "the Mackie Control bridge", "the
    /// channel strip for track 'Drums'"); `exposed` says what was found
    /// instead. Both render verbatim into the message, so any remedy — "select
    /// the track first", "see logic_health" — belongs in the call site's
    /// `exposed`, where it can be true, not in the template.
    case trackNotExposed(requested: String, exposed: String)
    case insertNotFound(track: String, plugin: String, available: [String])
    /// One display name occupies several insert slots. `parameter` names the
    /// disambiguating argument of the route that hit this — "insert_index"
    /// (Accessibility ordinal) or "insert_slot" (Mackie physical slot) — so
    /// the remedy in the message is the one the failing route actually takes,
    /// never an invitation to convert between the two numberings.
    case insertAmbiguous(track: String, plugin: String, slots: [Int], parameter: String)
    case insertMismatch(slot: Int, expected: String, actual: String)
    case openVerificationFailed(String)
    case windowNotClosable(String)
    case windowAmbiguous(String, Int)
    case pluginNotOpen(String)
    case trackNotFound(String, available: [String])
    case trackAmbiguous(String, numbers: [Int])
    case trackMismatch(number: Int, expected: String, actual: String)
    case selectionFailed(requested: String, actual: String, restored: Bool)
    case trackNotStack(String)
    /// Several control-surface strips answer to one name (duplicate track
    /// names, or two names Logic abbreviates into the same six characters).
    /// Distinct from `trackAmbiguous`, which can offer track NUMBERS as the
    /// way out — an output/aux/bus strip has no number to offer.
    case stripAmbiguous(name: String, cells: [String])
    /// The name is neither a track header nor a control-surface strip: both
    /// planes were asked, and the message says so.
    case stripNotFound(name: String, tracks: [String], cells: [String])
    /// A precondition for a write was not met and the message says exactly
    /// which — for the cases the specific mismatches above do not fit. The
    /// string IS the whole message: it is written for the agent that has to
    /// decide what to do next, so it names the state that was found and the
    /// move out of it.
    case preconditionUnmet(String)
    case projectTempoModeUnsafe(mode: String, detail: String)
    case tempoMapUnsafe(operation: String, detail: String)
    /// The requested plugin setting is not in the setting menu. Carries the
    /// names that ARE there, so the agent's retry is informed instead of a
    /// second guess — the list is capped, because a Compressor offers 156.
    case presetNotFound(plugin: String, requested: String, available: [String])
    /// Two categories of the same plugin hold a setting with this name; the
    /// qualified `Category/Name` paths say which.
    case presetAmbiguous(requested: String, paths: [String])
    /// No row in Logic's Key Commands window carries this name. Carries the
    /// search term that was used and the rows the panel WAS showing, because
    /// command names drift between Logic versions and a bare `not_found`
    /// leaves the caller guessing at spellings (COVERAGE open question 7).
    case keyCommandNotFound(requested: String, searched: String, candidates: [String])

    var code: String {
        switch self {
        case .accessibilityNotTrusted: return "not_trusted"
        case .logicNotRunning: return "not_running"
        case .windowNotFound, .parameterNotFound, .insertNotFound, .trackNotFound,
             .stripNotFound, .presetNotFound, .keyCommandNotFound: return "not_found"
        case .parameterAmbiguous, .insertAmbiguous, .windowAmbiguous, .trackAmbiguous,
             .stripAmbiguous, .presetAmbiguous: return "ambiguous"
        case .valueNotWritable, .trackNotExposed, .windowNotClosable, .trackNotStack: return "not_exposed"
        case .currentValueMismatch, .projectMismatch, .insertMismatch, .pluginNotOpen, .trackMismatch,
             .preconditionUnmet, .projectTempoModeUnsafe, .tempoMapUnsafe: return "precondition_failed"
        case .writeFailed, .confirmationFailed: return "write_failed"
        case .verificationFailed, .openVerificationFailed, .selectionFailed: return "verification_failed"
        case .invalidArguments: return "invalid_arguments"
        }
    }

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "Accessibility permission is not granted to the MCP process."
        case .logicNotRunning:
            return "Logic Pro is not running."
        case .windowNotFound(let title):
            return "Logic window not found: \(title)"
        case .parameterNotFound(let name):
            return "Accessible plugin parameter not found: \(name)"
        case .parameterAmbiguous(let name, let count):
            return "Accessible plugin parameter is ambiguous: \(name) matched \(count) controls."
        case .valueNotWritable(let name):
            return "The accessible value is not writable: \(name)"
        case .currentValueMismatch(let expected, let actual):
            return "Current value mismatch. Expected \(expected), found \(actual). No write was attempted."
        case .writeFailed(let detail):
            return "Accessibility write failed: \(detail)"
        case .confirmationFailed(let detail):
            return "Accessibility confirmation failed: \(detail)"
        case .verificationFailed(let requested, let actual, let restored):
            return "Readback mismatch. Requested \(requested), found \(actual). Restored: \(restored)."
        case .invalidArguments(let detail):
            return "Invalid arguments: \(detail)"
        case .preconditionUnmet(let detail):
            return detail
        case .projectMismatch(let expected, let actual):
            return "Open project mismatch. Expected \(expected), found \(actual). No action was taken."
        case .trackNotExposed(let requested, let exposed):
            return sentenceCased(requested) + " is not available. "
                + sentenceCased(exposed) + (exposed.hasSuffix(".") ? "" : ".")
        case .insertNotFound(let track, let plugin, let available):
            return "No insert matching '\(plugin)' on track '\(track)'. Available inserts: \(available.joined(separator: ", "))."
        case .insertAmbiguous(let track, let plugin, let slots, let parameter):
            return "Insert '\(plugin)' on track '\(track)' is ambiguous; it occupies slots "
                + slots.map(String.init).joined(separator: ", ")
                + " (\(parameter) numbering). Pass \(parameter) to disambiguate — "
                + "see INSERT NUMBERING in the server instructions."
        case .insertMismatch(let slot, let expected, let actual):
            return "Insert slot \(slot) holds '\(actual)', not '\(expected)'. No action was taken."
        case .openVerificationFailed(let detail):
            return "Could not verify that the plugin window state changed as requested: \(detail)"
        case .windowNotClosable(let title):
            return "Refusing to close window '\(title)': only plugin windows (dialogs without a document) may be closed."
        case .windowAmbiguous(let title, let count):
            return "\(count) windows share the title '\(title)'. Use logic_close_plugin with track, plugin and insert index instead."
        case .pluginNotOpen(let detail):
            return "The plugin window was not open: \(detail)"
        case .trackNotFound(let name, let available):
            return "No visible track header matches '\(name)'. Visible tracks: \(available.joined(separator: ", ")). Scrolled-out tracks are not exposed."
        case .trackAmbiguous(let name, let numbers):
            return "Track name '\(name)' is ambiguous; it matches track numbers \(numbers.map(String.init).joined(separator: ", ")). Pass track_number to disambiguate."
        case .trackMismatch(let number, let expected, let actual):
            return "Track \(number) is named '\(actual)', not '\(expected)'. No action was taken."
        case .selectionFailed(let requested, let actual, let restored):
            return "Track selection could not be verified. Requested '\(requested)', selection is '\(actual)'. Restored previous selection: \(restored)."
        case .trackNotStack(let name):
            return "Track '\(name)' exposes no track stack disclosure arrow; it is not a track stack."
        case .stripNotFound(let name, let tracks, let cells):
            return "'\(name)' is neither a visible track header nor a strip the control surface shows. "
                + "Track headers: \(tracks.isEmpty ? "none readable" : tracks.joined(separator: ", ")). "
                + "Surface strips (names as the 6-character LCD abbreviates them): "
                + "\(cells.isEmpty ? "none readable" : cells.joined(separator: ", ")). Nothing was written."
        case .stripAmbiguous(let name, let cells):
            return "'\(name)' matches \(cells.count) control-surface strips (LCD cells: "
                + "\(cells.joined(separator: ", "))). Nothing was selected or written. "
                + "Rename one of them, or address a track by track_number instead."
        case .projectTempoModeUnsafe(let mode, let detail):
            return "Refusing to record: the project tempo mode is \(mode). \(detail)"
        case .tempoMapUnsafe(let operation, let detail):
            return "Refusing \(operation): the project tempo is not constant. \(detail)"
        case .presetNotFound(let plugin, let requested, let available):
            return "'\(plugin)' has no setting named '\(requested)'. Nothing was loaded. "
                + (available.isEmpty
                    ? "Its setting menu lists no factory settings at all."
                    : "It lists: \(presetNameSample(available)).")
                + " Call logic_plugin_preset with action 'list' for the full menu."
        case .presetAmbiguous(let requested, let paths):
            return "'\(requested)' names \(paths.count) settings of this plugin "
                + "(\(paths.joined(separator: ", "))). Nothing was loaded. "
                + "Pass the qualified 'Category/Name' instead."
        case .keyCommandNotFound(let requested, let searched, let candidates):
            return "Logic's Key Commands window has no command named '\(requested)' "
                + "(searched for '\(searched)'). NOTHING was bound. "
                + (candidates.isEmpty
                    ? "The search matched no rows at all - try a shorter 'search' term."
                    : "Rows the panel showed: \(candidates.joined(separator: ", ")). "
                        + "Command names differ between Logic versions; call again with one of these, exactly.")
        }
    }
}

/// Adds a `warning` to a result without overwriting one that is already there —
/// several results can carry more than one honest complaint at once (a silent
/// render AND a tempo map), and the first one written must not be lost. Extra
/// warnings are joined into the same string so an agent that reads only
/// `warning` still sees all of them.
func appendWarning(_ text: String?, to result: inout [String: Any]) {
    guard let text, !text.isEmpty else { return }
    if let existing = result["warning"] as? String, !existing.isEmpty {
        guard !existing.contains(text) else { return }
        result["warning"] = existing + " ALSO: " + text
    } else {
        result["warning"] = text
    }
}

struct AccessibleParameter {
    let name: String
    let help: String
    let identifier: String
    let rawValue: String
    let minimum: String
    let maximum: String
    let valueDescription: String
    let valueSettable: Bool

    var dictionary: [String: Any] {
        [
            "name": name,
            "help": help,
            "ax_identifier": identifier,
            "raw_value": rawValue,
            "raw_min": minimum,
            "raw_max": maximum,
            "value_description": valueDescription,
            "writable": valueSettable
        ]
    }
}

struct InsertSlot {
    let index: Int
    let name: String
    let bypassed: Bool
    let group: AXUIElement
    let openButton: AXUIElement?

    var dictionary: [String: Any] {
        [
            "insert_index": index,
            "plugin_display_name": name,
            "bypassed": bypassed,
            "can_open": openButton != nil
        ]
    }
}

struct WindowKey: Hashable {
    let element: AXUIElement

    static func == (lhs: WindowKey, rhs: WindowKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

