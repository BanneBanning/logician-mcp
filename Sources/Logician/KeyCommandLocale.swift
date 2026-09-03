import Foundation

/// Whether a key-command LEARN can address Logic's Key Commands window in the
/// language Logic is drawing in, and what to type if it can.
///
/// The problem this closes, stated exactly. `logic_trigger_key_command` is
/// locale-free and that was proven live (French, R4 2026-08-30: note 119 still
/// opened the inline rename editor). `logic_setup_key_commands` and
/// `logic_learn_key_command` are not: they type an English search term into
/// Logic's filter field and match an English row name. On a translated Logic
/// every one of them comes back `not_found` — separately, several seconds
/// each, each with a `candidates` list of rows in a language the caller never
/// asked about — and since Logic 12.2 refuses plist Key Commands import there
/// is no other route to the bindings at all. Nineteen silent mismatches is the
/// worst possible answer to "this is not translated yet".
///
/// So this is the gate: ONE refusal, before the Key Commands window is opened
/// and before anything is written into the user's persisted key command set,
/// that names the language, names what is missing, and names what still
/// works. When someone captures a language into
/// `LogicUIStrings.KeyCommandRow.translations` the same gate turns into the
/// route — it hands back the localized row names to type.
///
/// Pure: the language comes in as a value (`LogicUILanguage` infers it from
/// Logic's bundle and the preference order), so every branch is a unit test.
enum KeyCommandLocalePlan {

    /// One (search term, row name, preferred note) triple, as
    /// `setupKeyCommands` takes them. A struct rather than the driver's tuple
    /// so the outcome can be `Equatable` and compared in a test.
    struct Target: Equatable {
        let search: String
        let name: String
        let preferredNote: Int

        init(search: String, name: String, preferredNote: Int) {
            self.search = search
            self.name = name
            self.preferredNote = preferredNote
        }
    }

    enum Outcome: Equatable {
        /// Open the window and learn these. `warning` is non-nil when the
        /// caller should know something about how the names were chosen — it
        /// is never a reason not to proceed.
        case proceed(targets: [Target], warning: String?)
        /// Do not open the window and do not write anything. The string is the
        /// whole message.
        case refuse(String)
    }

    /// - Parameters:
    ///   - targets: what the caller asked to learn.
    ///   - language: Logic's inferred UI language (`LogicUILanguage.Report
    ///     .language`), nil when it could not be inferred.
    ///   - isEnglish: the same report's verdict. **nil means "could not
    ///     tell", which is not "not English"** — the codebase's standing rule,
    ///     and the reason an unknown language proceeds with a warning instead
    ///     of refusing. Refusing there would break every English machine whose
    ///     Logic bundle happens to be unreadable.
    ///   - ownNames: the names THIS SERVER spells (`KeyCommandRegistry.Name
    ///     .all`). A name outside that set was typed by the caller, who is
    ///     looking at their own Logic in their own language, so it is passed
    ///     through verbatim and never refused — `logic_learn_key_command
    ///     {name: "Diviser les régions…"}` is a perfectly good call on a
    ///     French Logic and always was.
    ///   - translations: the captured row-name tables. Defaulted to the
    ///     shipped one; a parameter so the CAPTURED-language branch has a test
    ///     without a guessed translation being shipped to make it pass.
    static func plan(
        targets: [Target],
        language: String?,
        isEnglish: Bool?,
        ownNames: Set<String>,
        translations: [String: [String: String]] = LogicUIStrings.KeyCommandRow.translations
    ) -> Outcome {
        guard isEnglish == false, let language else {
            return .proceed(
                targets: targets,
                warning: isEnglish == nil ? unknownLanguageWarning : nil
            )
        }
        if LogicUIStrings.KeyCommandRow.isEnglish(language) {
            return .proceed(targets: targets, warning: nil)
        }
        let ours = targets.filter { ownNames.contains($0.name) }
        guard !ours.isEmpty else { return .proceed(targets: targets, warning: nil) }
        let missing = LogicUIStrings.KeyCommandRow.missingNames(
            ours.map(\.name), language: language, in: translations
        )
        guard missing.isEmpty else {
            return .refuse(refusal(
                language: language, missing: missing, asked: ours.count, translations: translations
            ))
        }
        let localized = targets.map { target -> Target in
            guard ownNames.contains(target.name),
                  let spelling = LogicUIStrings.KeyCommandRow.spelling(
                      of: target.name, language: language, in: translations
                  ), spelling != target.name
            else { return target }
            // The search TERM is the localized row name itself. The English
            // terms are short substrings chosen against English rows ("nudge
            // region"), and a substring of an English name filters nothing in
            // another language; a row's own full text always matches its own
            // row.
            return Target(search: spelling, name: spelling, preferredNote: target.preferredNote)
        }
        return .proceed(
            targets: localized,
            warning: "Logic's UI is in '\(language)', so the Key Commands rows were addressed "
                + "with that language's captured spellings rather than the English ones. The "
                + "registry records the row's OWN text, which is what logic_list_key_commands "
                + "will show."
        )
    }

    static let unknownLanguageWarning =
        "Logic's UI language could not be determined, so the Key Commands window was addressed "
            + "in ENGLISH. If commands come back not_found on a healthy Logic, that is the first "
            + "thing to suspect - logic_health reports what the inference saw."

    /// Names the language, the evidence and the way forward — never just
    /// "unsupported".
    static func refusal(
        language: String, missing: [String], asked: Int,
        translations: [String: [String: String]] = LogicUIStrings.KeyCommandRow.translations
    ) -> String {
        let shown = missing.prefix(6).joined(separator: ", ")
        let more = missing.count > 6 ? ", and \(missing.count - 6) more" : ""
        return "refused: Logic's UI appears to be in '\(language)' and this server has no "
            + "captured Key Commands row names for that language, so NOTHING WAS OPENED and "
            + "NOTHING WAS BOUND. Learning works by typing a command's name into Logic's Key "
            + "Commands filter field and matching the row it returns; \(missing.count) of the "
            + "\(asked) requested commands are spelled here only in English (\(shown)\(more)), "
            + "and searching an English name on a translated Logic silently matches nothing. "
            + "WHAT STILL WORKS: every key command already learned - triggering is a MIDI note "
            + "and is language-free (proven live on a French Logic), so logic_trigger_key_command "
            + "and every tool that rides it are unaffected, and logic_list_key_commands shows "
            + "what is bound. WHAT TO DO: bind by the name YOUR Logic shows - open Logic's Key "
            + "Commands window, read the row, and call logic_learn_key_command {name: \"<that "
            + "exact row text>\"} (add dry_run: true first to see the rows a search term "
            + "returns); a name this server does not itself spell is passed straight through and "
            + "never refused. Switching Logic to English for the one-time setup round also "
            + "works, and the bindings survive switching back. Languages this server can drive "
            + "the window in today: \(LogicUIStrings.KeyCommandRow.supportedLanguages(in: translations).joined(separator: ", "))."
    }
}
