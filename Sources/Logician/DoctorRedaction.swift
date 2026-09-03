import Foundation

// Redaction for `logician doctor`.
//
// WHY IT EXISTS. The support report a musician pastes into a public issue is
// the one place this project asks a stranger for their computer. The old ask
// — "paste logic_health" — shipped the open project's FULL PATH and NAME to a
// GitHub thread that is indexed forever: `/Users/annalindqvist/Music/Logic/
// Demo for Sony A&R.logicx` names the user, their filing habits and their
// unreleased work, and answers no question the maintainer had. So the doctor
// redacts by DEFAULT and says, in the report itself, that it did and how to
// turn it off.
//
// THE BIAS IS DELIBERATE. Every rule here is written to over-redact rather
// than under-redact: a match runs from the leftmost path start on the line, so
// a sentence that happens to share a line with a project path loses some of
// the sentence. Losing a word of prose costs a support round trip. Leaking a
// path costs the user something they cannot take back.

/// Turns a value the doctor is about to print into one that is safe in a
/// public issue. Pure — construct it with the identity to hide and it
/// rewrites strings, nothing else.
///
/// Applied to VALUES, never to whole rendered lines: the label column is the
/// doctor's own text and must survive intact, while the value is the only
/// half that can carry the user's identity.
struct DoctorRedactor {
    /// The absolute home directory to collapse to `~`, e.g. `/Users/anna`.
    let homeDirectory: String
    /// The account short name, e.g. `anna`. Substituted only when it is at
    /// least `minimumUserNameLength` characters — a one- or two-letter name is
    /// a substring of half the English language, and replacing it everywhere
    /// would shred the report while protecting nothing a reader could not
    /// already guess.
    let userName: String
    /// `false` under `--no-redact`, where every rule is skipped and the text
    /// is returned byte for byte.
    let enabled: Bool

    /// Below this length a short name is not substituted. Three characters is
    /// the shortest run that is more likely to be a name than a coincidence.
    static let minimumUserNameLength = 3

    /// The replacement tokens, named once so the report's own legend and the
    /// rules cannot drift apart.
    static let homeToken = "~"
    static let projectToken = "<project>"
    static let fileToken = "<file>"
    static let userToken = "<user>"

    /// Extensions whose FILE NAME is the user's material: a bounce, a stem, a
    /// captured take, a MIDI export. The directory around them survives (it is
    /// already `~`-collapsed and is usually ours); the name does not.
    /// `.logicx` is absent on purpose — a project is redacted PATH AND ALL by
    /// `projectPathPattern`, not name-only.
    static let mediaExtensions = [
        "wav", "aiff", "aif", "caf", "mp3", "m4a", "aac", "flac", "mid", "midi", "mov", "mp4"
    ]

    init(homeDirectory: String, userName: String, enabled: Bool) {
        self.homeDirectory = homeDirectory
        self.userName = userName
        self.enabled = enabled
    }

    /// The redactor for the Mac this is running on.
    static func forThisMac(enabled: Bool) -> DoctorRedactor {
        DoctorRedactor(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            userName: NSUserName(),
            enabled: enabled
        )
    }

    /// The one entry point. Idempotent: redacting an already-redacted string
    /// returns it unchanged, which is what lets the collectors redact a value
    /// early and the renderer redact it again without doubling the tokens.
    func redact(_ text: String) -> String {
        guard enabled, !text.isEmpty else { return text }
        var result = text
        // 1. The home directory, literally, before anything else — every later
        //    rule then works on `~/…` and never has to know this Mac's layout.
        if !homeDirectory.isEmpty, homeDirectory != "/" {
            result = result.replacingOccurrences(of: homeDirectory, with: Self.homeToken)
        }
        // 2. Any OTHER `/Users/<someone>` — a second account, a path copied
        //    from a colleague's machine, a log line from before a rename.
        result = Self.replace(Self.otherHomePattern, in: result, with: Self.homeToken)
        // 3. The project: path and all. A `.logicx` path is the single most
        //    sensitive string this report can touch. The NAME goes first —
        //    it is the rule that cannot cross a `/`, so it settles each
        //    project on the line separately — and the PATH rule then eats the
        //    directories that led to it.
        result = Self.replace(Self.projectNamePattern, in: result, with: Self.projectToken + ".logicx")
        result = Self.replace(Self.projectPathPattern, in: result, with: Self.projectToken + ".logicx")
        // 4. Bounces, stems, captures, MIDI exports: the NAME, not the folder.
        result = Self.replace(Self.mediaNamePattern, in: result, with: Self.fileToken + ".$1")
        // 5. Whatever is left carrying the account short name — a MIDI port
        //    called "anna's MPK", a hostname, a comment in a log line.
        if userName.count >= Self.minimumUserNameLength, !Self.userNameCollidesWithAToken(userName) {
            result = Self.replace(
                NSRegularExpression.escapedPattern(for: userName),
                in: result, with: Self.userToken, caseInsensitive: true
            )
        }
        return result
    }

    /// Convenience for a value that is already known to be a bare project
    /// name (a window title, say) rather than a path.
    func redactProjectName(_ name: String) -> String {
        guard enabled else { return name }
        return Self.projectToken
    }

    /// True when substituting the short name would eat one of the replacement
    /// tokens — an account called `user`, `file` or `project`. Skipping the
    /// substitution there keeps `redact` idempotent, and the cost is a leaked
    /// short name that says nothing about anybody: those three are the names a
    /// reader would have guessed.
    static func userNameCollidesWithAToken(_ userName: String) -> Bool {
        [homeToken, projectToken, fileToken, userToken].contains {
            $0.range(of: userName, options: .caseInsensitive) != nil
        }
    }

    // MARK: - The patterns

    /// `/Users/<someone>` where the name is a single path component. Bounded
    /// by the character class, so `/Users/anna/Music` collapses to `~/Music`
    /// and `/Users` on its own is left alone.
    static let otherHomePattern = #"/Users/[^/\s"'\n\r\t]+"#

    /// A path ending in `.logicx`, from the leftmost path start on the line.
    ///
    /// Lazy on the right (stop at the FIRST `.logicx`, so two projects on one
    /// line are two matches) and leftmost on the left (start at the first `/`
    /// or `~` that can reach it without crossing a quote or a newline). The
    /// left rule is the over-redacting one: prose between an earlier path and
    /// this one is swallowed. That is the trade named at the top of this file.
    static let projectPathPattern = #"(?:~|/)[^"'\n\r\t]*?\.logicx"#

    /// A bare `Some Project.logicx` with no path at all — a window title, a
    /// name in a log line. Spaces are allowed INSIDE the name (project names
    /// have them) but the run cannot cross a `/`, a quote or a line break.
    static let projectNamePattern = nameRun + #"\.logicx"#

    /// A media file NAME, with or without a directory in front of it. `/` is
    /// excluded from the run, so the match starts after the last slash and the
    /// folder survives.
    static var mediaNamePattern: String {
        nameRun + #"\.("# + mediaExtensions.joined(separator: "|") + #")\b"#
    }

    /// One file name, spaces and all: a first word, then any number of
    /// space-separated words.
    ///
    /// `<` and `>` are excluded along with the quotes and the slash, and that
    /// exclusion is load-bearing rather than cosmetic: it is what stops a
    /// second pass from swallowing `<project>.logicx and <project>.logicx` as
    /// ONE spaced name and collapsing two facts into one. The cost is a
    /// project literally named with an angle bracket, where the redaction
    /// starts one character late — and `projectPathPattern` still removes the
    /// path around it.
    static let nameRun = #"[^\s"'/<>\n\r\t]+(?: [^\s"'/<>\n\r\t]+)*"#

    /// `NSRegularExpression`, not Swift's `Regex`: these patterns are data
    /// (one of them is assembled from a list) and a construction failure must
    /// leave the text ALONE rather than trap — a redactor that crashes on an
    /// odd log line is a redactor nobody runs.
    static func replace(
        _ pattern: String, in text: String, with template: String, caseInsensitive: Bool = false
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []
        ) else { return text }
        return expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: template
        )
    }
}
