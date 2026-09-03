import Foundation
import XCTest

@testable import Logician

/// The packaging DRIFT GUARD. `packaging/homebrew/logician.rb` pins an exact
/// tagged tarball by version, and `packaging/install.sh` is shipped as raw
/// text through `curl | bash` with no build step of its own to catch a typo
/// - neither file is ever compiled, so nothing else here would notice either
/// one rotting out from under a release. This is cheap insurance, not a
/// packaging test suite: it does not install anything or touch the network.
final class PackagingSyncTests: XCTestCase {

    /// Repository root, found the same way `MCPResourceTests`'s embedded-guide
    /// drift guard does: three levels up from this file (LogicianTests, Tests,
    /// repository root).
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LogicianTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }

    /// The formula's `url` line names the release tag (`.../vX.Y.Z.tar.gz`);
    /// that tag is only ever cut from `serverVersion` (see
    /// `packaging/README.md` step 1 and step 3). If someone bumps
    /// `serverVersion` for a release and forgets the formula - or edits the
    /// formula's version without a matching release - this catches it before
    /// `brew install` fetches a tarball that does not contain what the
    /// formula thinks it does.
    func testFormulaVersionMatchesServerVersion() throws {
        let formulaPath = repositoryRoot.appendingPathComponent("packaging/homebrew/logician.rb")
        let formula = try String(contentsOf: formulaPath, encoding: .utf8)

        let pattern = #"archive/refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(formula.startIndex..<formula.endIndex, in: formula)
        guard let match = regex.firstMatch(in: formula, range: range),
            let versionRange = Range(match.range(at: 1), in: formula)
        else {
            XCTFail("packaging/homebrew/logician.rb's `url` does not name a vX.Y.Z release tag")
            return
        }

        XCTAssertEqual(
            String(formula[versionRange]), serverVersion,
            "packaging/homebrew/logician.rb points at a different version than "
                + "Sources/Logician/Support.swift's serverVersion - update the formula's "
                + "url/sha256 per packaging/README.md before releasing"
        )
    }

    /// `install.sh` runs unmodified on whatever `bash` the user has via
    /// `curl -fsSL ... | bash` - there is no compiler to catch a syntax slip
    /// before it ships. `bash -n` parses without executing, so this is a
    /// pure syntax check: no network, no clone, no build, no write outside
    /// bash's own parser.
    func testInstallScriptIsSyntacticallyValid() throws {
        let scriptPath = repositoryRoot.appendingPathComponent("packaging/install.sh").path
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: scriptPath), "packaging/install.sh is missing")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", scriptPath]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(
            process.terminationStatus, 0,
            "packaging/install.sh failed `bash -n`: \(stderr)"
        )
    }
}
