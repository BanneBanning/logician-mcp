import XCTest

@testable import Logician

/// The redactor is the reason `logician doctor` exists rather than "paste
/// logic_health". Every test here is a leak that would otherwise reach a
/// public issue thread, so they are written as the leak, not as the API.
final class DoctorRedactionTests: XCTestCase {
    /// A representative Mac: a short name that appears inside the home path
    /// and again inside a device name.
    private let redactor = DoctorRedactor(
        homeDirectory: "/Users/annalindqvist", userName: "annalindqvist", enabled: true
    )

    private let open = DoctorRedactor(
        homeDirectory: "/Users/annalindqvist", userName: "annalindqvist", enabled: false
    )

    // MARK: - The four the brief named

    /// A path containing the user's short name. The name is the thing: an
    /// issue thread that carries it is a searchable link between a bug report
    /// and a person.
    func testHomePathCollapsesToTilde() {
        XCTAssertEqual(
            redactor.redact("/Users/annalindqvist/logician-mcp/.build/release/logician"),
            "~/logician-mcp/.build/release/logician"
        )
        XCTAssertFalse(
            redactor.redact("/Users/annalindqvist/Desktop").contains("annalindqvist")
        )
    }

    /// A project name with spaces AND diacritics — the two things a
    /// character-class-based redactor gets wrong first. The whole path goes,
    /// not just the name: the folders above a project name it too.
    func testProjectPathWithSpacesAndDiacriticsIsFullyRemoved() {
        let text = "/Users/annalindqvist/Music/Logic/Testlåt Copy.logicx"
        XCTAssertEqual(redactor.redact(text), "<project>.logicx")
    }

    /// A capture file name. The folder survives (it is ours and it is useful);
    /// the name the user gave their bounce does not.
    func testCaptureFileNameIsReplacedButItsFolderSurvives() {
        let text = "/Users/annalindqvist/Music/Logician/captures/rough mix for Jonas.wav"
        XCTAssertEqual(redactor.redact(text), "~/Music/Logician/captures/<file>.wav")
    }

    /// An absolute path inside a quoted JSON string — the shape every MCP
    /// client config carries, and the one place a naive line-based redactor
    /// eats the closing quote.
    func testAbsolutePathInsideAQuotedJSONString() {
        let text = #"{"command":"/Users/annalindqvist/logician-mcp/.build/release/logician"}"#
        XCTAssertEqual(
            redactor.redact(text),
            #"{"command":"~/logician-mcp/.build/release/logician"}"#
        )
    }

    // MARK: - The rules around them

    /// `--no-redact` is byte-for-byte, or the maintainer cannot trust what
    /// they asked for.
    func testDisabledRedactorReturnsTheTextUnchanged() {
        let text = "/Users/annalindqvist/Music/Logic/Testlåt Copy.logicx"
        XCTAssertEqual(open.redact(text), text)
    }

    /// Applied twice, the same answer. The collectors redact known values
    /// early and the renderer redacts every value again; doubling the tokens
    /// would make the report unreadable.
    func testRedactionIsIdempotent() {
        let samples = [
            "/Users/annalindqvist/Music/Logic/Demo för Sony.logicx",
            "~/Music/Logician/captures/take 3.wav",
            #"{"command":"/Users/annalindqvist/bin/logician"}"#,
            "annalindqvist's MPK mini"
        ]
        for sample in samples {
            let once = redactor.redact(sample)
            XCTAssertEqual(redactor.redact(once), once, "not idempotent: \(sample)")
        }
    }

    /// A second account's home is somebody else's identity and goes the same
    /// way, even though it is not the home this redactor was built for.
    func testAnotherUsersHomeIsAlsoCollapsed() {
        XCTAssertEqual(redactor.redact("/Users/jonas/Desktop/notes.txt"), "~/Desktop/notes.txt")
    }

    /// A system path is NOT a personal path. Over-redacting Logic's own
    /// location would cost the maintainer the one fact that identifies a
    /// non-App-Store install.
    func testSystemPathsAreLeftAlone() {
        let text = "/Applications/Logic Pro.app"
        XCTAssertEqual(redactor.redact(text), text)
    }

    /// The short name outside a path: MIDI devices are named after their
    /// owner more often than anyone expects.
    func testShortNameIsRemovedFromADeviceName() {
        XCTAssertEqual(
            redactor.redact("annalindqvist's Keystation (input)"),
            "<user>'s Keystation (input)"
        )
    }

    /// Case-insensitively — macOS spells the home path lowercase and the
    /// user spells their device name however they like.
    func testShortNameMatchIsCaseInsensitive() {
        XCTAssertEqual(redactor.redact("AnnaLindqvist-MBP.local"), "<user>-MBP.local")
    }

    /// A short name below the threshold is left alone: substituting `al`
    /// everywhere would shred the report to protect a string nobody could
    /// identify anybody from.
    func testVeryShortNamesAreNotSubstituted() {
        let short = DoctorRedactor(homeDirectory: "/Users/al", userName: "al", enabled: true)
        XCTAssertEqual(short.redact("the fader value is normal"), "the fader value is normal")
        // The home path still collapses — that rule is literal, not fuzzy.
        XCTAssertEqual(short.redact("/Users/al/Music"), "~/Music")
    }

    /// An account called `user` would otherwise rewrite its own replacement
    /// token forever. Skipping it is the deliberate choice, and the leak is a
    /// word the reader would have guessed.
    func testAccountNamesThatCollideWithATokenAreSkipped() {
        XCTAssertTrue(DoctorRedactor.userNameCollidesWithAToken("user"))
        XCTAssertTrue(DoctorRedactor.userNameCollidesWithAToken("project"))
        XCTAssertFalse(DoctorRedactor.userNameCollidesWithAToken("annalindqvist"))
        let colliding = DoctorRedactor(
            homeDirectory: "/Users/user", userName: "user", enabled: true
        )
        XCTAssertEqual(colliding.redact("~/Music/<file>.wav"), "~/Music/<file>.wav")
    }

    /// Two projects on one line are two matches, not one greedy sweep from
    /// the first to the last.
    func testTwoProjectPathsOnOneLineBothGo() {
        let text = "~/Music/Logic/A.logicx and ~/Music/Logic/B.logicx"
        XCTAssertEqual(redactor.redact(text), "<project>.logicx and <project>.logicx")
    }

    /// A bare project name with no path at all — a window title, or the way a
    /// log line names the document.
    func testBareProjectNameWithNoPath() {
        XCTAssertEqual(redactor.redact("Testlåt Copy.logicx"), "<project>.logicx")
    }

    /// Every line of a multi-line value (the daemon log tail is one) is
    /// redacted, not just the first.
    func testEveryLineOfAMultiLineValueIsRedacted() {
        let text = """
            opened /Users/annalindqvist/Music/Logic/Demo.logicx
            wrote /Users/annalindqvist/Music/Logician/captures/bounce 1.wav
            """
        let result = redactor.redact(text)
        XCTAssertFalse(result.contains("annalindqvist"))
        XCTAssertFalse(result.contains("Demo"))
        XCTAssertFalse(result.contains("bounce 1"))
    }

    /// The property that matters more than any single case: nothing the
    /// redactor emits carries the account name or the project name. Written as
    /// a sweep so a future rule change cannot pass the specific cases and
    /// still leak.
    func testNoOutputEverCarriesTheIdentity() {
        let samples = [
            "/Users/annalindqvist",
            "/Users/annalindqvist/Music/Logic/Testlåt Copy.logicx",
            "file:///Users/annalindqvist/Music/Logic/CS%20Copy.logicx",
            #"{"mcpServers":{"logician":{"command":"/Users/annalindqvist/bin/logician"}}}"#,
            "port 'annalindqvist iRig' (input)",
            "ANNALINDQVIST"
        ]
        for sample in samples {
            let result = redactor.redact(sample)
            XCTAssertFalse(
                result.lowercased().contains("annalindqvist"), "leaked the account name: \(result)"
            )
        }
    }

    /// A `.logicx` path never survives in any form, however it is written.
    func testProjectExtensionNeverSurvives() {
        let samples = [
            "~/Music/Logic/X.logicx",
            "/Volumes/Audio SSD/Sessions/Album 2 - final.logicx",
            "project at /Users/annalindqvist/Desktop/Untitled.logicx now",
            "Untitled.logicx"
        ]
        for sample in samples {
            let result = redactor.redact(sample)
            XCTAssertTrue(
                result.contains("<project>.logicx"), "no project token in: \(result)"
            )
            XCTAssertFalse(result.contains("Album"), "leaked a project name: \(result)")
            XCTAssertFalse(result.contains("Untitled.logicx") && !result.contains("<project>"),
                           "leaked a project name: \(result)")
        }
    }

    /// An empty value is not a crash and not a token.
    func testEmptyTextIsUntouched() {
        XCTAssertEqual(redactor.redact(""), "")
    }

    /// The pattern is built from a list at run time; a broken pattern must
    /// leave the text alone rather than trap the whole doctor.
    func testAnUnbuildablePatternLeavesTheTextAlone() {
        XCTAssertEqual(DoctorRedactor.replace("([", in: "unchanged", with: "x"), "unchanged")
    }
}
