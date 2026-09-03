import Foundation

// The shape of a `logician doctor` report, and how it renders.
//
// Kept apart from the collectors on purpose: everything in this file is a
// value and a pure function of values, so the report's contract — a failure is
// never blank, a problem always carries its fix, the exit code follows the
// problems — is pinned by unit tests instead of by running the thing on a
// broken Mac.

/// How a single fact reads to a maintainer.
enum DoctorStatus: Equatable {
    /// Nothing to do. Reported because its ABSENCE would be a question.
    case ok
    /// Worth knowing, not worth fixing: Logic closed, a surface idle, a
    /// non-default toolset. Never affects the exit code.
    case note
    /// Something essential is missing or wrong. Sets the exit code, and the
    /// value MUST name the fix in the same sentence.
    case problem
}

/// One labelled fact.
struct DoctorLine: Equatable {
    let label: String
    let value: String
    let status: DoctorStatus

    static func ok(_ label: String, _ value: String) -> DoctorLine {
        DoctorLine(label: label, value: value, status: .ok)
    }

    static func note(_ label: String, _ value: String) -> DoctorLine {
        DoctorLine(label: label, value: value, status: .note)
    }

    /// A problem. `fix` is appended to `value` as one sentence, because a
    /// report where the symptoms are in one column and the remedies in
    /// another is a report the reader has to assemble themselves.
    static func problem(_ label: String, _ value: String, fix: String) -> DoctorLine {
        DoctorLine(label: label, value: value + " — " + fix, status: .problem)
    }

    /// The honest empty. A fact that could not be read says WHY it could not
    /// be read; nothing in this report is ever a blank column.
    static func unavailable(_ label: String, _ reason: String) -> DoctorLine {
        DoctorLine(label: label, value: "unavailable: " + reason, status: .note)
    }

    /// `unavailable`, but the missing fact is one the server cannot work
    /// without, so it counts against the exit code and carries a fix.
    static func missing(_ label: String, _ reason: String, fix: String) -> DoctorLine {
        DoctorLine(label: label, value: "unavailable: " + reason + " — " + fix, status: .problem)
    }

    /// The value with the redactor applied. The LABEL is never redacted: it is
    /// the doctor's own text, and a redactor that rewrote it could turn a
    /// heading into `<user>`.
    func redacted(by redactor: DoctorRedactor) -> DoctorLine {
        DoctorLine(label: label, value: redactor.redact(value), status: status)
    }
}

/// A titled group of lines.
struct DoctorSection: Equatable {
    let title: String
    let lines: [DoctorLine]
}

/// The whole report.
struct DoctorReport: Equatable {
    let sections: [DoctorSection]

    var allLines: [DoctorLine] { sections.flatMap(\.lines) }

    var problems: [DoctorLine] { allLines.filter { $0.status == .problem } }

    /// 0 when every essential fact is present, 1 when something is missing —
    /// so a support reply can be "run `logician doctor`; if it exits non-zero
    /// paste the output" and a CI-style check can gate on it.
    var exitCode: Int32 { problems.isEmpty ? 0 : 1 }

    /// A copy with every value passed through the redactor.
    func redacted(by redactor: DoctorRedactor) -> DoctorReport {
        DoctorReport(sections: sections.map { section in
            DoctorSection(title: section.title, lines: section.lines.map { $0.redacted(by: redactor) })
        })
    }

    /// The marker column. ASCII on purpose: this text is pasted into issue
    /// bodies, chat windows and terminals whose fonts we do not control.
    static func marker(_ status: DoctorStatus) -> String {
        switch status {
        case .ok: return "   "
        case .note: return " . "
        case .problem: return "!! "
        }
    }

    /// The finished text: header, sections, verdict, redaction legend.
    ///
    /// `timestamp` and `version` are arguments rather than reads so the whole
    /// renderer is pure and a test can compare bytes.
    func rendered(version: String, timestamp: String, redacted: Bool) -> String {
        let width = allLines.map(\.label.count).max() ?? 0
        var out = "Logician doctor — logician \(version) — \(timestamp)\n"
        out += "Paste this whole report into an issue: "
            + "https://github.com/BanneBanning/logician-mcp/issues\n"
        for section in sections {
            out += "\n" + section.title.uppercased() + "\n"
            for line in section.lines {
                let padding = String(repeating: " ", count: max(0, width - line.label.count))
                out += "  " + Self.marker(line.status) + line.label + padding + "   " + line.value + "\n"
            }
        }
        out += "\n" + verdict() + "\n"
        out += redacted ? Self.redactionLegend : Self.noRedactionWarning
        out += "\n"
        return out
    }

    /// The one line a maintainer reads first.
    func verdict() -> String {
        guard !problems.isEmpty else {
            return "No problems found. Everything Logician needs is present on this Mac."
        }
        let count = problems.count
        let noun = count == 1 ? "problem" : "problems"
        return "\(count) \(noun), marked !! above; each one names its own fix. "
            + "Doing them in order is the fastest route, and rerunning `logician doctor` checks your work."
    }

    static let redactionLegend =
        "Redacted: your home folder reads as ~, your account name as <user>, the open project as "
            + "<project> and audio or MIDI file names as <file>. Nothing above names your projects "
            + "or your files. If the maintainer asks for a real path, rerun with "
            + "`logician doctor --no-redact` and check the output before you paste it.\n"

    static let noRedactionWarning =
        "NOT REDACTED (--no-redact): the report above carries your home folder, your account name "
            + "and the names of your project and files. Read it before you paste it anywhere public; "
            + "`logician doctor` on its own redacts all of that.\n"
}
