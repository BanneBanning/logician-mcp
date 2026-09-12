import XCTest
@testable import Logician

final class ProjectDocumentReadbackTests: XCTestCase {
    private func row(_ name: String, _ path: String = "", _ modified: String = "true") -> String {
        "\(name)\u{1F}\(path)\u{1F}\(modified)\u{1E}"
    }

    func testEmptyAnswerIsAnEmptyList() throws {
        XCTAssertTrue(try XCTUnwrap(ProjectDocuments.parse("")).isEmpty)
    }

    func testCompleteListPreservesUnsavedPathsAndNormalizesUnicode() throws {
        let documents = try XCTUnwrap(ProjectDocuments.parse(
            row("Untitled") + row("Sma\u{308}llare", "/Music/Sma\u{308}llare.logicx", "false")
        ))
        XCTAssertEqual(documents.count, 2)
        XCTAssertNil(documents[0].path)
        XCTAssertTrue(documents[0].modified)
        XCTAssertEqual(documents[1].name, "Smällare")
        XCTAssertEqual(documents[1].path, "/Music/Smällare.logicx")
        XCTAssertFalse(documents[1].modified)
    }

    func testMalformedRowsInvalidateTheWholeListRatherThanDisappearing() {
        for invalid in [
            "Mine\u{1F}/Mine.logicx\u{1E}",
            row("Mine", "/Mine.logicx", "unknown"),
            row("Mine", "/Mine.logicx", ""),
            row("", "/Mine.logicx"),
            row("Mine\u{1F}extra", "/Mine.logicx"),
            "\u{1E}",
            "Mine\u{1F}/Mine.logicx\u{1F}true"
        ] {
            XCTAssertNil(ProjectDocuments.parse(invalid), invalid.debugDescription)
            XCTAssertNil(ProjectDocuments.parse(row("Other", "/Other.logicx", "false") + invalid),
                         invalid.debugDescription)
        }
    }

    func testMalformedCloseReadbackCannotCertifyThatAProjectClosed() {
        let parsed = ProjectDocuments.parse("Mine\u{1F}/Mine.logicx\u{1E}")
        XCTAssertFalse(ProjectClose.closeVerified(
            documentName: "Mine", remaining: parsed?.map(\.name)
        ).verified)
    }

    func testMissingOrUnreadableTargetCannotCertifyASave() {
        let normalize = ProjectReset.normalizedTargetPath
        for documents: [ProjectDocuments.Document]? in [
            nil, [], [("Mine", nil, false)], [("Mine", "/Elsewhere/Mine.logicx", false)]
        ] {
            XCTAssertFalse(ProjectSave.documentIsSaved(
                in: documents, targetPath: "/Music/Mine.logicx", normalize: normalize
            ))
        }
    }

    func testSaveReadbackUsesTargetPathRegardlessOfDocumentOrder() {
        let target: ProjectDocuments.Document = ("Mine", "/Music/Mine.logicx", true)
        let other: ProjectDocuments.Document = ("Other", "/Music/Other.logicx", false)
        for documents in [[other, target], [target, other]] {
            XCTAssertFalse(ProjectSave.documentIsSaved(
                in: documents, targetPath: "/Music/Mine.logicx",
                normalize: ProjectReset.normalizedTargetPath
            ))
        }
        XCTAssertTrue(ProjectSave.documentIsSaved(
            in: [other, ("Mine", "/Music/Mine.logicx", false)],
            targetPath: "/Music/Mine.logicx/", normalize: ProjectReset.normalizedTargetPath
        ))
    }

    func testConflictingDuplicateTargetEntriesCannotCertifyASave() {
        XCTAssertFalse(ProjectSave.documentIsSaved(
            in: [("Mine", "/Mine.logicx", false), ("Mine", "/Mine.logicx", true)],
            targetPath: "/Mine.logicx", normalize: ProjectReset.normalizedTargetPath
        ))
    }
}
