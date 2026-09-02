import Foundation
import XCTest
@testable import Logician

/// The captures directory's retention policy.
///
/// Nothing pruned that folder before 2026-09-02 and a freeze render writes the
/// whole PROJECT length whatever bars were asked for: measured on the
/// development machine, 169 files / 1.2 GB, of which 71 render leftovers /
/// 1.1 GB, at ~46 MB per call. The policy every writer now shares is "the
/// newest N captures within M bytes, oldest first" — and the two things it
/// must never do are eat the file the current call just wrote and touch
/// anything that is not audio.
///
/// `Captures.rootOverride` keeps every byte of this inside a temporary
/// directory: a test that swept the real folder would delete someone's music.
final class CapturesRetentionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("logician-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Captures.rootOverride = root
    }

    override func tearDownWithError() throws {
        Captures.rootOverride = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - The decision, as arithmetic

    func testNothingIsRemovedInsideBudget() {
        let captures = (0..<10).map { capture("render-\($0).aif", bytes: 100, age: $0) }
        XCTAssertTrue(Captures.retentionPlan(
            captures, byteBudget: 10_000, fileBudget: 50, alwaysKeepNewest: 2
        ).isEmpty)
        XCTAssertTrue(Captures.retentionPlan([]).isEmpty)
    }

    func testTheByteBudgetDropsTheOldestFirst() {
        // Ten 100-byte captures, 550 bytes of budget: the five newest fit,
        // the sixth does not, and it and everything older goes.
        let captures = (0..<10).map { capture("render-\($0).aif", bytes: 100, age: $0) }
        let removed = Captures.retentionPlan(
            captures, byteBudget: 550, fileBudget: 50, alwaysKeepNewest: 2
        )
        // Reported oldest first, so a caller reads a sweep in the order it
        // happened.
        XCTAssertEqual(removed.map(\.name), [
            "render-9.aif", "render-8.aif", "render-7.aif", "render-6.aif", "render-5.aif"
        ])
    }

    func testTheFileBudgetBindsOnItsOwn() {
        let captures = (0..<10).map { capture("render-\($0).aif", bytes: 10, age: $0) }
        let removed = Captures.retentionPlan(
            captures, byteBudget: 1_000_000, fileBudget: 4, alwaysKeepNewest: 2
        )
        XCTAssertEqual(Set(removed.map(\.name)), Set((4...9).map { "render-\($0).aif" }))
    }

    func testTheNewestCapturesSurviveAnyBudget() {
        // The render that is being written right now is the newest, and a
        // sweep that deletes it has eaten the result it made room for. Four
        // files, a budget of one byte: the floor still keeps three.
        let captures = (0..<4).map { capture("render-\($0).aif", bytes: 50_000_000, age: $0) }
        let removed = Captures.retentionPlan(
            captures, byteBudget: 1, fileBudget: 1, alwaysKeepNewest: 3
        )
        XCTAssertEqual(removed.map(\.name), ["render-3.aif"])
    }

    func testEqualTimestampsBreakByNameSoTwoSweepsAgree() {
        let same = Date(timeIntervalSince1970: 1_000)
        let captures = ["a.aif", "b.aif", "c.aif"].map {
            Captures.Capture(name: $0, bytes: 100, modified: same)
        }
        let first = Captures.retentionPlan(
            captures, byteBudget: 100, fileBudget: 50, alwaysKeepNewest: 1
        )
        let second = Captures.retentionPlan(
            captures.reversed(), byteBudget: 100, fileBudget: 50, alwaysKeepNewest: 1
        )
        XCTAssertEqual(first.map(\.name), second.map(\.name))
        XCTAssertEqual(first.map(\.name), ["a.aif", "b.aif"])
    }

    // MARK: - The sweep, on a real directory

    func testTheSweepRemovesTheOldestAudioAndReportsIt() throws {
        for index in 0..<6 { try write("render-\(index).aif", bytes: 100, age: index) }
        let report = try XCTUnwrap(Captures.makeRoom(
            byteBudget: 250, fileBudget: 50, alwaysKeepNewest: 1
        ))
        XCTAssertEqual(report["removed_files"] as? Int, 4)
        XCTAssertEqual(report["removed_bytes"] as? Int, 400)
        XCTAssertEqual(try names(), ["render-0.aif", "render-1.aif"])
    }

    func testTheSweepIsSilentWhenItRemovesNothing() throws {
        for index in 0..<3 { try write("render-\(index).aif", bytes: 100, age: index) }
        // nil, not an empty block: the normal answer must not appear in every
        // render result.
        XCTAssertNil(Captures.makeRoom(byteBudget: 10_000, fileBudget: 50, alwaysKeepNewest: 1))
        XCTAssertEqual(try names().count, 3)
    }

    func testTheSweepLeavesEverythingThatIsNotAudioAlone() throws {
        // The sealed-metrics JSON a blind listen writes lives here too, and a
        // retention policy for audio has no business deleting it.
        try write("render-old.aif", bytes: 1_000, age: 100)
        try write("sealed-metrics-1.json", bytes: 1_000, age: 100)
        try write("notes.txt", bytes: 1_000, age: 100)
        try write("render-new.aif", bytes: 100, age: 0)
        let report = try XCTUnwrap(Captures.makeRoom(
            byteBudget: 100, fileBudget: 50, alwaysKeepNewest: 1
        ))
        XCTAssertEqual(report["removed_files"] as? Int, 1)
        XCTAssertEqual(try names(), ["notes.txt", "render-new.aif", "sealed-metrics-1.json"])
    }

    func testTheShippedBudgetsAreAboveWhatTheFolderAlreadyHeld() {
        // Deliberate: shipping a retention policy must not delete the renders
        // a user already has. 169 files / 1.2 GB was the measured state on
        // 2026-09-02, so the budgets bound what arrives NEXT.
        XCTAssertGreaterThan(Captures.retentionFileBudget, 169)
        XCTAssertGreaterThan(Captures.retentionByteBudget, 1_200_000_000)
    }

    // MARK: - Helpers

    private func capture(_ name: String, bytes: Int64, age: Int) -> Captures.Capture {
        Captures.Capture(
            name: name, bytes: bytes,
            modified: Date(timeIntervalSince1970: 1_000_000 - Double(age) * 60)
        )
    }

    private func write(_ name: String, bytes: Int, age: Int) throws {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0x11, count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000 - Double(age) * 60)],
            ofItemAtPath: url.path
        )
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }
}
