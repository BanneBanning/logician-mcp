import Foundation
import XCTest
@testable import Logician

/// The two things `logic_evaluate_change` decides without touching audio: what
/// it refuses before it writes anything, and what it says afterwards about the
/// solo it worked under.
///
/// Both were wrong in ways nothing could see (profile `logic_evaluate_change`
/// §8, 2026-09-01). `expected_project_path` was honoured by one of the three
/// methods and silently dropped by the other two — on a tool that writes a
/// plugin parameter and renders audio. A solo left up got `solo_restored:
/// false` and no `warning`, on a tool registered `mayWarn: true`. A solo
/// already up on ANOTHER track was never looked for, while the note went on
/// claiming the bounces held this track alone.
///
/// Nothing here runs Logic: the project check is injected, and the report
/// composer is pure.
final class EvaluateChangeGuardTests: XCTestCase {

    // MARK: The project guard

    /// Records what the handler asked the project check, so "was it asked at
    /// all" and "was it asked FIRST" are both observable.
    private final class GuardSpy {
        private(set) var calls: [String?] = []
        var refuseWith: LogicianError?
        func verify(_ expected: String?) throws {
            calls.append(expected)
            if let refuseWith { throw refuseWith }
        }
    }

    private let mismatch = LogicianError.projectMismatch(
        expected: "/Music/Other.logicx", actual: "/Music/Testlåt Copy.logicx"
    )

    private func arguments(
        method: String?, slot: Int? = 4, path: String? = "/Music/Other.logicx",
        bars: Bool = true
    ) -> [String: Any] {
        var arguments: [String: Any] = [
            "track_name": "Bas", "parameter": "MakeUp",
            "expected_current_value": "0.0 dB", "target_value": "3.0 dB"
        ]
        if let method { arguments["method"] = method }
        if let slot { arguments["insert_slot"] = slot }
        if let path { arguments["expected_project_path"] = path }
        if bars { arguments["start_bar"] = 10; arguments["end_bar"] = 12 }
        return arguments
    }

    private func resolve(
        _ arguments: [String: Any], spy: GuardSpy
    ) throws -> EvaluateChangePreflight.Request {
        try EvaluateChangePreflight.resolve(arguments) { try spy.verify($0) }
    }

    /// The regression this fix exists for: all three methods hand the argument
    /// to the check. Two of them used to ignore the key entirely.
    func testEveryMethodPutsTheProjectPathThroughTheGuard() throws {
        for (method, slot) in [("render", 4), ("solo_bounce", 4), ("bounce", nil)] {
            let spy = GuardSpy()
            _ = try resolve(arguments(method: method, slot: slot), spy: spy)
            XCTAssertEqual(spy.calls.count, 1, "\(method) must ask exactly once")
            XCTAssertEqual(spy.calls.first ?? nil, "/Music/Other.logicx", "\(method)")
        }
    }

    /// A wrong project is refused on every method, and the refusal is the
    /// mismatch — not a shape complaint about something further down.
    func testAWrongProjectRefusesAllThreeMethods() {
        for (method, slot) in [("render", 4), ("solo_bounce", 4), ("bounce", nil)] {
            let spy = GuardSpy()
            spy.refuseWith = mismatch
            XCTAssertThrowsError(try resolve(arguments(method: method, slot: slot), spy: spy)) {
                guard case LogicianError.projectMismatch = $0 else {
                    return XCTFail("\(method) refused with \($0), not a project mismatch")
                }
            }
        }
    }

    /// The ordering, pinned: a call that is BOTH pointed at the wrong project
    /// and malformed learns about the project first. Being aimed at the wrong
    /// document is the fact worth having, and the shape complaint would send
    /// the agent to fix the wrong thing and hit the mismatch on its retry.
    func testTheProjectGuardRunsAheadOfEveryShapeCheck() {
        let spy = GuardSpy()
        spy.refuseWith = mismatch
        let malformed = arguments(method: nil, slot: nil, bars: false)
        XCTAssertThrowsError(try resolve(malformed, spy: spy)) {
            guard case LogicianError.projectMismatch = $0 else {
                return XCTFail("expected the project mismatch, got \($0)")
            }
        }
        XCTAssertEqual(spy.calls.count, 1, "the guard ran even though nothing else parsed")
    }

    /// The ordinary call passes no path, and the check is still asked — it is
    /// `verifyProjectPath` that decides `nil` means "no opinion", not the
    /// handler deciding to skip it.
    func testAnAbsentPathStillReachesTheGuardAsNil() throws {
        let spy = GuardSpy()
        let request = try resolve(arguments(method: "render", path: nil), spy: spy)
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertNil(spy.calls.first ?? "not nil")
        XCTAssertNil(request.expectedProjectPath)
    }

    // MARK: The shape checks behind it

    func testTheSlotMethodsCarryTheirSlotAndBounceDoesNot() throws {
        let spy = GuardSpy()
        XCTAssertEqual(
            try resolve(arguments(method: "render", slot: 4), spy: spy).plan,
            .render(insertSlot: 4)
        )
        XCTAssertEqual(
            try resolve(arguments(method: "solo_bounce", slot: 7), spy: spy).plan,
            .soloBounce(insertSlot: 7)
        )
        XCTAssertEqual(
            try resolve(arguments(method: "bounce", slot: nil), spy: spy).plan, .bounce
        )
    }

    func testTheSlotMethodsRefuseWithoutASlotAndNameTheArgument() {
        for method in ["render", "solo_bounce"] {
            XCTAssertThrowsError(
                try resolve(arguments(method: method, slot: nil), spy: GuardSpy())
            ) {
                guard case LogicianError.invalidArguments(let message) = $0 else {
                    return XCTFail("\(method): \($0)")
                }
                XCTAssertTrue(message.contains("insert_slot"), message)
                XCTAssertTrue(message.contains(method), message)
            }
        }
    }

    func testAnUnknownMethodIsRefusedWithAllThreeNames() {
        for method in ["freeze", ""] {
            XCTAssertThrowsError(
                try resolve(arguments(method: method), spy: GuardSpy())
            ) {
                guard case LogicianError.invalidArguments(let message) = $0 else {
                    return XCTFail(String(describing: $0))
                }
                for name in ["render", "bounce", "solo_bounce"] {
                    XCTAssertTrue(message.contains(name), message)
                }
            }
        }
    }

    func testMissingBarsIsStillTheSameRefusal() {
        XCTAssertThrowsError(
            try resolve(arguments(method: "render", bars: false), spy: GuardSpy())
        ) {
            guard case LogicianError.invalidArguments(let message) = $0 else {
                return XCTFail(String(describing: $0))
            }
            XCTAssertEqual(message, "missing integers: start_bar, end_bar")
        }
    }

    func testTheOptionalFlagsKeepTheirDefaults() throws {
        let spy = GuardSpy()
        let plain = try resolve(arguments(method: "render"), spy: spy)
        XCTAssertFalse(plain.keepChange)
        XCTAssertTrue(plain.includeAudio, "audio is attached unless the caller opts out")

        var opted = arguments(method: "render")
        opted["keep_change"] = true
        opted["include_audio"] = false
        let request = try resolve(opted, spy: spy)
        XCTAssertTrue(request.keepChange)
        XCTAssertFalse(request.includeAudio)
    }

    // MARK: What the solo-bounced A/B says about the solo

    private func report(
        solos: [String]?, wasAlreadySoloed: Bool = false, soloRestored: Bool = true
    ) -> SoloBounceReport.Report {
        SoloBounceReport.compose(
            trackName: "Bas", preexistingSolos: solos,
            wasAlreadySoloed: wasAlreadySoloed, soloRestored: soloRestored
        )
    }

    /// The clean run says exactly what it always said, word for word.
    func testACleanRunKeepsTheOldNoteAndWarnsAboutNothing() {
        let clean = report(solos: [])
        XCTAssertEqual(clean.note, SoloBounceReport.exclusiveNote)
        XCTAssertNil(clean.warning)
        XCTAssertNil(clean.listenSuffix)
        XCTAssertEqual(clean.context["other_tracks_soloed"] as? [String], [])
    }

    /// A solo already on the track under test is not contamination — it is the
    /// state this tool was going to create anyway.
    func testThisTracksOwnSoloIsNotAForeignSolo() {
        let own = report(solos: ["bas"], wasAlreadySoloed: true)
        XCTAssertEqual(own.note, SoloBounceReport.exclusiveNote)
        XCTAssertNil(own.warning)
        XCTAssertEqual(own.context["other_tracks_soloed"] as? [String], [])
    }

    /// D3: the bounces contain another track. Not a refusal — the deltas hold —
    /// but the note may not claim exclusivity, and the agent must be told the
    /// ear copies are not what they were advertised as.
    func testAForeignSoloRewritesTheNoteWarnsAndMarksTheEarCopies() throws {
        let shared = report(solos: ["Kick"])
        XCTAssertFalse(shared.note.contains("only this track soloed"))
        XCTAssertTrue(shared.note.contains("Kick"))
        XCTAssertTrue(shared.note.contains("still honest"), shared.note)
        let warning = try XCTUnwrap(shared.warning)
        XCTAssertTrue(warning.contains("Kick"))
        XCTAssertTrue(warning.contains("already soloed"))
        XCTAssertTrue(try XCTUnwrap(shared.listenSuffix).contains("Kick"))
        XCTAssertEqual(shared.context["other_tracks_soloed"] as? [String], ["Kick"])
    }

    func testSeveralForeignSolosReadAsPlural() throws {
        let shared = report(solos: ["Kick", "Snare", "bas"])
        XCTAssertEqual(shared.context["other_tracks_soloed"] as? [String], ["Kick", "Snare"])
        let warning = try XCTUnwrap(shared.warning)
        XCTAssertTrue(warning.contains("Kick, Snare were already soloed"), warning)
        XCTAssertTrue(shared.note.contains("Kick, Snare"), shared.note)
    }

    /// Unreadable headers answer "unknown", never "nobody" — the same rule
    /// `logic_export_stems` follows — and the result says so in a shape that
    /// is not an empty dictionary.
    func testUnreadableHeadersSayUnknownRatherThanClean() throws {
        let blind = report(solos: nil)
        XCTAssertNotEqual(blind.note, SoloBounceReport.exclusiveNote)
        XCTAssertTrue(blind.note.contains("could NOT be read"), blind.note)
        XCTAssertTrue(try XCTUnwrap(blind.warning).contains("UNKNOWN"))
        XCTAssertTrue(try XCTUnwrap(blind.listenSuffix).contains("could not be read"))
        XCTAssertNil(blind.context["other_tracks_soloed"])
        XCTAssertNotNil(blind.context["unavailable"])
        XCTAssertFalse(blind.context.isEmpty)
    }

    /// D1: a solo this tool switched on and could not switch off warns, in the
    /// same words the sibling tool with the same hazard uses.
    func testALeftoverSoloWarnsInTheSameWordsAsExportStems() throws {
        let leftover = report(solos: [], soloRestored: false)
        XCTAssertEqual(
            try XCTUnwrap(leftover.warning),
            "'Bas' is still soloed - every later bounce contains only it until that is fixed."
        )
    }

    /// A solo the USER had already put up is not this tool's to take down, so
    /// leaving it there is not a leftover.
    func testASoloThatWasAlreadyUpIsNotReportedAsLeftBehind() {
        XCTAssertNil(report(solos: ["bas"], wasAlreadySoloed: true, soloRestored: false).warning)
    }

    func testBothFailuresAtOnceAreJoinedNotOverwritten() throws {
        let both = report(solos: ["Kick"], soloRestored: false)
        let warning = try XCTUnwrap(both.warning)
        XCTAssertTrue(warning.contains("Kick"), warning)
        XCTAssertTrue(warning.contains("is still soloed"), warning)
        XCTAssertTrue(warning.contains(" ALSO: "), warning)
    }

    // MARK: The ear copies nobody asked for

    /// `include_audio: false` now skips the two base64 encodes instead of
    /// building them for the transport to drop (134–289 ms). The agent-visible
    /// result must not be able to tell: same omission note, same epistemics
    /// line, no audio block, and no trace of the marker key.
    func testASuppressedEncodeLooksExactlyLikeADroppedBlock() throws {
        let server = MCPServer()
        let suppressed = MCUController.attachABAudio(
            to: ["success": true, "note": "Two offline master bounces."],
            baselinePath: "/captures/a.aif", afterPath: "/captures/b.aif",
            includeAudio: false
        )
        XCTAssertNil(suppressed["_audio_list"], "nothing was encoded")
        XCTAssertEqual(suppressed["_audio_suppressed"] as? Bool, true)

        let result = server.toolResult(payload: suppressed, isError: false, includeAudio: false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertFalse(content.contains { $0["type"] as? String == "audio" })
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertFalse(text.contains("_audio_suppressed"), "transport key must never ship")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        let listen = try XCTUnwrap(object["listen_note"] as? String)
        XCTAssertTrue(listen.contains("Audio blocks were OMITTED"), listen)
        XCTAssertTrue(listen.contains(Tool.epistemicsNote), listen)
    }

    /// With the flag on, the same call still builds a real payload — the skip
    /// is the opt-out's doing, not a new default.
    func testTheEncodeStillHappensWhenTheAgentWantsToListen() {
        let attached = MCUController.attachABAudio(
            to: ["success": true], baselinePath: "/nonexistent/a.aif",
            afterPath: "/nonexistent/b.aif", includeAudio: true
        )
        // The files do not exist, so the encode fails and nothing is attached -
        // what matters is that the suppression marker was NOT the reason.
        XCTAssertNil(attached["_audio_suppressed"])
    }
}
