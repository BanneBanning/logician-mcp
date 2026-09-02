import AppKit
import Foundation

// MARK: - Which language is Logic's UI in, and what does that cost?

/// `logic_health`'s `logic_ui_language` block.
///
/// WHY IT EXISTS. Two of this server's three planes read Logic's own English
/// words (see `LogicUIStrings`), and until now nothing told anyone. A Swedish
/// Logic did not produce an error saying "these tools cannot work here"; it
/// produced tools that timed out, dialogs that were never answered and an
/// arrangement map with no bar numbers in it — the failure mode this whole
/// server exists to avoid. A doctor tool that audits the MIDI ports and the
/// Accessibility permission and then says nothing about the one property that
/// silently disables a third of the surface is not finished.
///
/// WHAT IT IS NOT. It is not a measurement of Logic's running UI. There is no
/// API that asks a foreign process "what language are you drawing in?", and
/// reading a word out of Logic's menu bar and guessing at it would be worse
/// than the inference below, not better. So this is explicitly an INFERENCE,
/// it says how it was made, and it reports `unknown` rather than `en` when it
/// cannot make it.
enum LogicUILanguage {

    // MARK: The pure half

    /// The facts the inference is made from — everything gathered from disk
    /// and from the preferences domain, before any interpretation.
    struct Evidence: Equatable {
        /// The `.lproj` languages Logic's own app bundle ships, e.g.
        /// `["en", "de", "fr", "ja", …]`. Empty when the bundle could not be
        /// read at all (Logic not installed, or not where we looked).
        let appLocalizations: [String]
        /// The language preference order that applies to Logic, most
        /// preferred first.
        let preferenceOrder: [String]
        /// True when that order came from Logic's OWN preference domain — the
        /// per-app language macOS lets a user set in System Settings >
        /// General > Language & Region > Applications. When false it is the
        /// system-wide `AppleLanguages`.
        let perApplicationOverride: Bool
        /// What CoreFoundation's own matcher picks out of `appLocalizations`
        /// for `preferenceOrder`. This is the same matching a launching Logic
        /// does, which is what makes the inference worth anything.
        let matched: [String]
        /// The bundle's development region — the language it falls back to
        /// when nothing matches.
        let developmentRegion: String?
    }

    /// The languages this server's English string table is correct for.
    /// One entry today, and a list rather than a constant because "English"
    /// is `en`, `en-GB`, `en-US`… and they all read `Cancel`.
    static let englishPrefix = "en"

    /// The verdict.
    struct Report: Equatable {
        /// The inferred language code, or nil when it could not be inferred.
        let language: String?
        /// nil when `language` is nil — "cannot tell" is not "not English".
        let isEnglish: Bool?
        /// One sentence naming the route the inference took.
        let method: String
        /// Present whenever `isEnglish` is not `true`: what degrades and what
        /// does not. Absent on an English Logic, where there is nothing to
        /// warn about.
        let note: String?

        var payload: [String: Any] {
            var result: [String: Any] = [
                "language": language ?? NSNull(),
                "is_english": isEnglish ?? NSNull(),
                "determined_by": method
            ]
            if let note { result["language_note"] = note }
            return result
        }

        /// The one-line form `logic_health` promotes to the TOP level of its
        /// result. nil when there is nothing to warn about.
        ///
        /// The promotion is deliberate — an agent skimming the doctor must not
        /// miss a non-English Logic — but it used to be the full note copied
        /// verbatim, so the same 1 371 characters travelled twice in one
        /// response (measured 2026-09-02: ~2.75 kB of identical prose, more
        /// than doubling a non-English Mac's report to make one point). The
        /// long form stays exactly where it was, in
        /// `logic_ui_language.language_note`; this is the pointer to it.
        var noteSummary: String? {
            guard note != nil else { return nil }
            guard let language else {
                return "Logic's UI LANGUAGE could not be determined, so this server cannot say"
                    + " whether its English-string assumptions hold — see"
                    + " logic_ui_language.language_note."
            }
            return "Logic's UI LANGUAGE appears to be '\(language)', not English."
                + " The Accessibility plane can fail on a perfectly healthy Logic;"
                + " the control-surface plane speaks MIDI and is unaffected. Read"
                + " logic_ui_language.language_note for the plane-by-plane detail."
        }
    }

    /// Turns evidence into a verdict. Pure — no Logic, no filesystem — so the
    /// three outcomes can be pinned by tests instead of by a live session.
    static func report(_ evidence: Evidence) -> Report {
        guard !evidence.appLocalizations.isEmpty else {
            return Report(
                language: nil,
                isEnglish: nil,
                method: "Logic Pro's application bundle could not be read, so its"
                    + " localizations are unknown. Nothing is claimed about the UI language.",
                note: unknownNote
            )
        }
        let chosen = evidence.matched.first ?? evidence.developmentRegion
        guard let chosen else {
            return Report(
                language: nil,
                isEnglish: nil,
                method: "Logic Pro's bundle publishes \(evidence.appLocalizations.count)"
                    + " localizations but neither the preference order"
                    + " (\(evidence.preferenceOrder.joined(separator: ", "))) nor a development"
                    + " region picked one.",
                note: unknownNote
            )
        }
        let english = chosen.lowercased() == englishPrefix
            || chosen.lowercased().hasPrefix(englishPrefix + "-")
            || chosen.lowercased().hasPrefix(englishPrefix + "_")
        let source = evidence.perApplicationOverride
            ? "Logic Pro's own per-application language setting"
            : "the system-wide language order (AppleLanguages)"
        // Two different stories end in the same word, and they are worth
        // telling apart: the preferred language IS one Logic ships, versus
        // the preferred language is one Logic does NOT ship and it falls back
        // to the language it was written in. The second is the common case on
        // a Mac set to a language Apple never localised Logic into — where the
        // system says Swedish and Logic is nevertheless drawing in English.
        let matchedAPreference = !evidence.matched.isEmpty
        let method = matchedAPreference
            ? "Logic Pro's app bundle ships \(evidence.appLocalizations.count)"
                + " localizations; matched against \(source)"
                + " [\(evidence.preferenceOrder.prefix(3).joined(separator: ", "))]"
                + " this resolves to '\(chosen)'."
            : "Logic Pro's app bundle ships \(evidence.appLocalizations.count)"
                + " localizations and NONE of them matches \(source)"
                + " [\(evidence.preferenceOrder.prefix(3).joined(separator: ", "))],"
                + " so Logic falls back to the language it was written in,"
                + " its development region '\(chosen)'."
        return Report(
            language: chosen,
            isEnglish: english,
            method: method,
            note: english ? nil : degradedNote(language: chosen)
        )
    }

    /// What a non-English Logic actually costs, plane by plane. Written to be
    /// read by an agent deciding what to attempt, not by a developer.
    static func degradedNote(language: String) -> String {
        "Logic's UI appears to be in '\(language)', and this server's Accessibility plane"
            + " matches some of Logic's own ENGLISH words (v1 assumption)."
            + " WHAT DEGRADES: (1) modal dialogs — several are recognised by their English"
            + " text, so they may not be answered; an unanswered modal blocks Logic, and the"
            + " symptom is every later tool reporting that its command fired and nothing"
            + " happened. (2) element lookups by name — the control bar, the track header"
            + " column, the inspector strips, the List Editors tabs and the menu paths are"
            + " addressed by English descriptions and menu titles, so the tools that use them"
            + " may report 'not found' on a perfectly healthy Logic. (3) region bar positions"
            + " — logic_list_regions parses an English sentence out of each region's help"
            + " text, so bars and types can come back missing. (4) key-command learning by"
            + " name — logic_learn_key_command searches Logic's Key Commands window for a"
            + " command spelled in English. WHAT IS UNAFFECTED: the control-surface plane."
            + " Everything routed through the Mackie Control (transport, faders, sends, pan,"
            + " plugin parameters via vpots, record-arm, metronome, and every already-learned"
            + " key command) speaks MIDI, not words, and works in any language."
            + " Nothing here is a guarantee in either direction — it is an inference from"
            + " Logic's bundle and the language preference order, so treat a failure as"
            + " possibly-locale and a success as real."
    }

    static let unknownNote =
        "The UI language could not be determined, so this server cannot say whether its"
            + " English-string assumptions hold. If Accessibility-plane tools report 'not"
            + " found' against a healthy Logic, or a dialog is never answered, suspect a"
            + " non-English Logic UI; the control-surface plane is unaffected either way."

    // MARK: The gathering half

    /// Reads the evidence off this Mac. Touches the filesystem and the
    /// preferences domain; does NOT touch Logic — it works with Logic closed,
    /// which is exactly when `logic_health` is most often run.
    /// `runningBundleURL` is the RUNNING Logic's bundle URL when the caller
    /// already resolved the process (it is the copy actually in use, which
    /// need not be the one Launch Services would resolve). Pass nil and the
    /// Launch Services lookup answers instead.
    static func evidence(bundleIdentifier: String, runningBundleURL: URL?) -> Evidence {
        // `??` is an autoclosure, so the Launch Services lookup is only paid
        // when there is no running copy to prefer. It used to be computed
        // unconditionally and thrown away: 2.3 ms of a 92.9 ms cold call
        // (measured 2026-09-02).
        let bundle = (runningBundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier))
            .flatMap { Bundle(url: $0) }
        let localizations = bundle?.localizations ?? []

        // The per-application language override (System Settings > General >
        // Language & Region > Applications) lives in the app's OWN domain and
        // beats the system order, so it is checked first.
        //
        // `persistentDomain(forName:)` and NOT `UserDefaults(suiteName:)`:
        // a suite is ADDED to the standard search list, so asking a suite for
        // `AppleLanguages` happily answers with NSGlobalDomain's value. That
        // read reported "per-application override" on this machine for a
        // system-wide Swedish setting Logic had never been given (measured
        // 2026-08-30) — the answer was still right, the reason it gave was a
        // lie. This domain read sees only what was written for Logic itself.
        let perApp = UserDefaults.standard
            .persistentDomain(forName: bundleIdentifier)?["AppleLanguages"] as? [String]
        let system = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
        let order = (perApp?.isEmpty == false ? perApp : nil) ?? system

        // CoreFoundation's own matcher, not a hand-rolled prefix compare: it
        // is what CFBundle uses when an app launches, dialects and all.
        let matched = localizations.isEmpty
            ? []
            : Bundle.preferredLocalizations(from: localizations, forPreferences: order)

        return Evidence(
            appLocalizations: localizations,
            preferenceOrder: order,
            perApplicationOverride: perApp?.isEmpty == false,
            matched: matched,
            developmentRegion: bundle?.developmentLocalization
        )
    }

    /// Evidence + verdict, as the block `logic_health` publishes, plus the
    /// one-line form of the warning it promotes to the top level.
    struct HealthBlock {
        let payload: [String: Any]
        /// `logic_health["language_note"]`, or nil on an English Logic.
        let topLevelNote: String?
    }

    static func healthBlock(bundleIdentifier: String, runningBundleURL: URL?) -> HealthBlock {
        let facts = evidence(bundleIdentifier: bundleIdentifier, runningBundleURL: runningBundleURL)
        let verdict = report(facts)
        var payload = verdict.payload
        payload["preference_order"] = Array(facts.preferenceOrder.prefix(5))
        payload["per_application_override"] = facts.perApplicationOverride
        payload["app_localizations_count"] = facts.appLocalizations.count
        return HealthBlock(payload: payload, topLevelNote: verdict.noteSummary)
    }
}
