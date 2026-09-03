import XCTest

@testable import Logician

/// The report's contract: never a blank, always a fix, and an exit code a
/// support reply can lean on.
final class DoctorReportTests: XCTestCase {
    private func report(_ lines: [DoctorLine]) -> DoctorReport {
        DoctorReport(sections: [DoctorSection(title: "Section", lines: lines)])
    }

    /// The whole point of the exit code: "run it and paste the output" needs
    /// the tool to know whether there is anything to paste.
    func testExitCodeIsZeroOnlyWhenNothingIsAProblem() {
        XCTAssertEqual(report([.ok("a", "fine"), .note("b", "worth knowing")]).exitCode, 0)
        XCTAssertEqual(report([.ok("a", "fine"), .problem("b", "broken", fix: "do this")]).exitCode, 1)
    }

    /// A note is information, not a fault. Logic being closed must not make a
    /// healthy install exit non-zero.
    func testNotesDoNotCountAsProblems() {
        XCTAssertTrue(report([.note("running", "no")]).problems.isEmpty)
    }

    /// The fix travels with the symptom, in one sentence, because a reader
    /// scanning a wall of text reads one line and acts on it.
    func testAProblemCarriesItsFixInTheSameValue() {
        let line = DoctorLine.problem("ports", "missing", fix: "run killall MIDIServer")
        XCTAssertEqual(line.value, "missing — run killall MIDIServer")
        XCTAssertEqual(line.status, .problem)
    }

    /// `unavailable: reason`, never a blank column. A missing reading that
    /// says nothing is indistinguishable from a reading of nothing.
    func testUnavailableAlwaysCarriesItsReason() {
        let line = DoctorLine.unavailable("uptime", "no pid file")
        XCTAssertEqual(line.value, "unavailable: no pid file")
        XCTAssertEqual(line.status, .note)
        XCTAssertFalse(line.value.hasSuffix(": "))
    }

    /// `missing` is `unavailable` for something essential: it reads the same
    /// and it counts.
    func testMissingIsAnUnavailableThatCountsAndFixes() {
        let line = DoctorLine.missing("installed", "no Logic Pro", fix: "install it")
        XCTAssertEqual(line.value, "unavailable: no Logic Pro — install it")
        XCTAssertEqual(line.status, .problem)
    }

    /// Every problem the report can produce names a remedy. Enforced as a
    /// property so a future line cannot be added without one.
    func testEveryProblemLineNamesARemedy() {
        let built = report([
            .problem("a", "broken", fix: "restart the client"),
            .missing("b", "absent", fix: "install it")
        ])
        for line in built.problems {
            XCTAssertTrue(line.value.contains(" — "), "no fix clause: \(line.value)")
        }
    }

    /// The label is the doctor's own text and must survive the redactor —
    /// a heading rewritten to `<user>` would be worse than a leak.
    func testRedactionRewritesValuesAndNeverLabels() {
        let redactor = DoctorRedactor(
            homeDirectory: "/Users/anna", userName: "anna", enabled: true
        )
        let line = DoctorLine.ok("anna", "/Users/anna/Music").redacted(by: redactor)
        XCTAssertEqual(line.label, "anna")
        XCTAssertEqual(line.value, "~/Music")
    }

    /// The rendered text carries the marker, the version, the timestamp, the
    /// verdict and the legend — the five things a maintainer looks for before
    /// reading anything else.
    func testRenderedTextCarriesTheHeaderVerdictAndLegend() {
        let text = report([
            .ok("version", "0.61.0"),
            .problem("ports", "missing", fix: "run killall MIDIServer")
        ]).rendered(version: "0.61.0", timestamp: "2026-09-04 21:03:11 +02:00", redacted: true)
        XCTAssertTrue(text.contains("logician 0.61.0"))
        XCTAssertTrue(text.contains("2026-09-04 21:03:11 +02:00"))
        XCTAssertTrue(text.contains("SECTION"))
        XCTAssertTrue(text.contains("!! ports"))
        XCTAssertTrue(text.contains("1 problem, marked !! above"))
        XCTAssertTrue(text.contains("Redacted:"))
        XCTAssertFalse(text.contains("NOT REDACTED"))
    }

    /// `--no-redact` says so IN the report, loudly, because the file outlives
    /// the decision to make it.
    func testUnredactedReportWarnsInsideItself() {
        let text = report([.ok("a", "b")])
            .rendered(version: "0.61.0", timestamp: "t", redacted: false)
        XCTAssertTrue(text.contains("NOT REDACTED (--no-redact)"))
    }

    /// A clean Mac gets a sentence that says so, not an empty verdict.
    func testCleanReportSaysSo() {
        XCTAssertEqual(
            report([.ok("a", "b")]).verdict(),
            "No problems found. Everything Logician needs is present on this Mac."
        )
        XCTAssertTrue(report([
            .problem("a", "x", fix: "y"), .problem("b", "x", fix: "y")
        ]).verdict().hasPrefix("2 problems"))
    }

    /// Values are column-aligned off the longest label in the whole report,
    /// so the sections read as one table rather than nine.
    func testValueColumnIsAlignedAcrossSections() {
        let built = DoctorReport(sections: [
            DoctorSection(title: "One", lines: [.ok("a", "1")]),
            DoctorSection(title: "Two", lines: [.ok("a much longer label", "2")])
        ])
        let rows = built.rendered(version: "v", timestamp: "t", redacted: true)
            .split(separator: "\n")
        let first = rows.first { $0.hasSuffix(" 1") }
        let second = rows.first { $0.hasSuffix(" 2") }
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(first?.count, second?.count, "the value column is ragged")
    }
}
