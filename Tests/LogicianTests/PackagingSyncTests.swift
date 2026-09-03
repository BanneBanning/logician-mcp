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

        // A pre-release suffix is part of the version and part of the tag:
        // `1.0.0-beta.1` is tagged `v1.0.0-beta.1`, so the pattern has to
        // accept one or the first beta release fails this guard for being
        // spelled correctly.
        let pattern = #"archive/refs/tags/v([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.\-]+)?)\.tar\.gz"#
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

    /// The formula's `sha256` is a 64-zero PLACEHOLDER until the tag exists
    /// and step 4 hashes the tarball GitHub builds for it. Nothing can ship
    /// past it by accident - Homebrew verifies the download against the value
    /// and aborts on the mismatch - so this is not a failure, it is the
    /// release checklist speaking up: the test SKIPS, loudly, naming the step
    /// that fills it in. Once a real hash is in, it is checked for shape
    /// instead, because a truncated or upper-cased paste is a `brew install`
    /// that fails on someone else's machine.
    func testFormulaChecksumIsEitherThePlaceholderOrAWellFormedHash() throws {
        let formulaPath = repositoryRoot.appendingPathComponent("packaging/homebrew/logician.rb")
        let formula = try String(contentsOf: formulaPath, encoding: .utf8)

        let pattern = #"^\s*sha256\s+"([^"]*)""#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let range = NSRange(formula.startIndex..<formula.endIndex, in: formula)
        guard let match = regex.firstMatch(in: formula, range: range),
            let shaRange = Range(match.range(at: 1), in: formula)
        else {
            XCTFail("packaging/homebrew/logician.rb has no `sha256` line")
            return
        }
        let sha = String(formula[shaRange])

        if sha == String(repeating: "0", count: 64) {
            throw XCTSkip(
                "packaging/homebrew/logician.rb still carries the 64-zero placeholder sha256, so "
                    + "`brew install bannebanning/logician/logician` CANNOT work yet - Homebrew "
                    + "aborts on the checksum mismatch. Expected until the release tag is pushed: "
                    + "cut the tag, then follow packaging/README.md steps 4-6 (download the tag's "
                    + "tarball, `shasum -a 256` it, paste the hash into the formula, copy the "
                    + "formula into the tap)."
            )
        }

        XCTAssertEqual(sha.count, 64, "packaging/homebrew/logician.rb's sha256 is not 64 characters")
        XCTAssertTrue(
            sha.allSatisfy { $0.isHexDigit && !$0.isUppercase },
            "packaging/homebrew/logician.rb's sha256 must be lowercase hex - `shasum -a 256` "
                + "output, pasted whole (see packaging/README.md step 4)"
        )
    }

    /// `install.sh` no longer builds whatever `main` holds: it checks out the
    /// tag named by `DEFAULT_REF` (`LOGICIAN_REF` overrides it). That makes it
    /// a second copy of the version, with the same drift risk the formula has
    /// - and a worse failure, because the script is served raw from `main`, so
    /// a stale ref silently installs the PREVIOUS release.
    func testInstallScriptPinsTheCurrentReleaseTag() throws {
        let scriptPath = repositoryRoot.appendingPathComponent("packaging/install.sh")
        let script = try String(contentsOf: scriptPath, encoding: .utf8)

        let pattern = #"(?m)^DEFAULT_REF="([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(script.startIndex..<script.endIndex, in: script)
        guard let match = regex.firstMatch(in: script, range: range),
            let refRange = Range(match.range(at: 1), in: script)
        else {
            XCTFail("packaging/install.sh no longer defines DEFAULT_REF - it must pin a release tag")
            return
        }

        XCTAssertEqual(
            String(script[refRange]), "v" + serverVersion,
            "packaging/install.sh's DEFAULT_REF does not name this version's tag - a `curl | bash` "
                + "user would install a different release than the formula does "
                + "(packaging/README.md step 1)"
        )
    }

    /// The third copy of the version: the Gemini extension manifest, which is
    /// what `gemini extensions install` reports and what a user quotes back in
    /// a bug report.
    func testGeminiExtensionVersionMatchesServerVersion() throws {
        let manifestPath = repositoryRoot.appendingPathComponent("gemini-extension.json")
        let data = try Data(contentsOf: manifestPath)
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(
            manifest?["version"] as? String, serverVersion,
            "gemini-extension.json's version does not match Sources/Logician/Support.swift's "
                + "serverVersion (packaging/README.md step 1)"
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
