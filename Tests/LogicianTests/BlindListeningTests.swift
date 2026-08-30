import Foundation
import XCTest
@testable import Logician

/// `blind: true` and the epistemics line — the two halves of "make the model
/// actually listen".
///
/// The centre of this file is a FIELD CENSUS per tool: the exact key set each
/// producer builds, run through `Blind.applied`, with both the withheld set
/// and the kept set asserted whole. Asserting only the withheld half would let
/// a future edit quietly drop `warning` or `preview_path` and still pass —
/// and a blind result that lost its audio, or its honesty, is worse than no
/// blind mode at all.
///
/// Nothing here touches Logic or the user's captures directory:
/// `Captures.rootOverride` points the seal at a temporary one.
final class BlindListeningTests: XCTestCase {

    private var server = MCPServer()
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = MCPServer()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("logician-blind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Captures.rootOverride = root
    }

    override func tearDownWithError() throws {
        Captures.rootOverride = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    // MARK: Fixtures — the real key sets, as their producers build them

    /// `LogicAccessibility.bounceRange`, every optional key present: the
    /// options were changed, the file was measurable, and a solo was found.
    private func bouncePayload() -> [String: Any] {
        [
            "success": true, "verified": true, "state": "bounced",
            "path": "/captures/logicmcp-bounce-1.aif",
            "preview_path": "/captures/logicmcp-bounce-1.m4a",
            "start_bar": 5, "end_bar": 7, "bytes": 1_058_400,
            "write_route": "bounce_dialog_offline",
            "delivered_as": ["file_type": "AIFF", "bit_depth": "24-bit"],
            "note": "This result CARRIES the bounce as an MCP audio content block.",
            "options_changed": ["bit_depth": "24-bit"],
            "options_note": "These are the USER'S OWN bounce settings.",
            "metrics": ["rms_db": [-18.4, -18.1], "peak_db": [-3.2, -3.0],
                        "channels": 2, "bits": 24, "frames": 176_400],
            "soloed_tracks": ["Kick"],
            "warning": "Tracks currently SOLOED: Kick.",
            "_audio": ["data": "AAAA", "mimeType": "audio/mp4"]
        ]
    }

    /// `MCUController.renderSelectedTrack` plus what `handleRenderTrack` adds:
    /// the whole-file metrics, and a SLICE that carries its own nested ones
    /// beside the path the ear copy was encoded from.
    private func renderPayload() -> [String: Any] {
        [
            "success": true, "verified": true,
            "path": "/captures/kick.aif", "write_route": "freeze_render_headless",
            "unfrozen": true,
            "note": "Track rendered offline via Freeze and unfrozen again.",
            "preview_path": "/captures/kick.m4a",
            "preview_note": "Compressed stereo AAC copy.",
            "metrics": ["rms_db": [-14.0], "peak_db": [-1.1],
                        "channels": 1, "bits": 24, "frames": 882_000],
            "slice": [
                "path": "/captures/kick-slice.wav",
                "start_seconds": 8.0, "end_seconds": 11.2,
                "frames": 141_120, "sample_rate": 44_100.0, "channels": 1,
                "metrics": ["rms_db": [-14.2], "peak_db": [-1.3]]
            ],
            "track": "Kick", "track_name": "Kick",
            "slice_tempo": 120.0, "slice_beats_per_bar": 4.0,
            "tempo_map": ["events": []], "meter_map": ["events": []],
            "listen_note": "This result CARRIES the rendered audio as an MCP audio block.",
            "_audio": ["data": "AAAA", "mimeType": "audio/mp4"]
        ]
    }

    /// The A/B key set. All three methods build the SAME keys by design (see
    /// the "one shape across all three methods" comment in
    /// `evaluateChangeBounced`), so one fixture parameterised by method is the
    /// honest census rather than three near-copies.
    private func evaluatePayload(method: String) -> [String: Any] {
        var change: [String: Any] = [
            "track": "Kick", "track_name": "Kick",
            "parameter": "Threshold", "before": "-12.0 dB", "applied": "-18.0 dB"
        ]
        if method == "bounce" { change["plugin"] = "Compressor" } else { change["insert_slot"] = 2 }
        var payload: [String: Any] = [
            "success": true, "verified": true, "state": "evaluated",
            "method": method, "decision": "rolled_back",
            "change": change,
            "range": ["start_bar": 5, "end_bar": 9],
            "baseline_audio": "/captures/a.aif", "after_audio": "/captures/b.aif",
            "baseline_full_audio": "/captures/a.aif", "after_full_audio": "/captures/b.aif",
            "baseline_preview": "/captures/a.m4a", "after_preview": "/captures/b.m4a",
            "baseline_metrics": ["rms_db": [-18.4], "peak_db": [-3.2]],
            "after_metrics": ["rms_db": [-20.1], "peak_db": [-4.8]],
            "deltas": ["rms_delta_db": [-1.7], "peak_delta_db": [-1.6]],
            "note": "Offline 24-bit master renders; no playback occurred.",
            "listen_note": "This result CARRIES both versions as MCP audio blocks.",
            "_audio_list": [["data": "AAAA", "mimeType": "audio/mp4"]]
        ]
        if method == "solo_bounce" { payload["solo_restored"] = true }
        return payload
    }

    private func blinded(_ tool: String, _ payload: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(Blind.applied(toolName: tool, payload: payload) as? [String: Any])
    }

    // MARK: The census, per tool

    func testBounceRangeWithholdsOnlyItsMeasurementOfTheAudio() throws {
        let before = bouncePayload()
        let after = try blinded("logic_bounce_range", before)

        XCTAssertEqual(Set(before.keys).subtracting(after.keys), ["metrics"])
        // Everything else survives, named in full so a silent loss fails here.
        XCTAssertEqual(
            Set(after.keys),
            Set([
                "success", "verified", "state", "path", "preview_path",
                "start_bar", "end_bar", "bytes", "write_route", "delivered_as",
                "note", "options_changed", "options_note", "soloed_tracks",
                "warning", "_audio", "blind_note", "sealed_metrics_path"
            ])
        )
    }

    func testRenderTrackWithholdsTheNestedSliceMetricsAndKeepsTheSlicePath() throws {
        let after = try blinded("logic_render_track", renderPayload())

        XCTAssertNil(after["metrics"])
        let slice = try XCTUnwrap(after["slice"] as? [String: Any])
        XCTAssertNil(slice["metrics"], "the slice's own peak/RMS is a measurement too")
        // The slice is where the ear copy came from: losing its path would
        // withhold the audio, which blind must never do.
        XCTAssertEqual(slice["path"] as? String, "/captures/kick-slice.wav")
        XCTAssertEqual(
            Set(slice.keys),
            Set(["path", "start_seconds", "end_seconds", "frames", "sample_rate", "channels"])
        )
        XCTAssertEqual(Set(renderPayload().keys).subtracting(after.keys), ["metrics"])
        // The track name is the caller's OWN argument coming back; withholding
        // an echo hides nothing and breaks round-tripping into the next call.
        XCTAssertEqual(after["track_name"] as? String, "Kick")
        XCTAssertNotNil(after["unfrozen"], "the restore-state flag is safety-critical")
        XCTAssertNotNil(after["tempo_map"])
    }

    func testEveryEvaluateChangeMethodDefersBothSidesAndTheDeltas() throws {
        for method in ["render", "bounce", "solo_bounce"] {
            let before = evaluatePayload(method: method)
            let after = try blinded("logic_evaluate_change", before)

            XCTAssertEqual(
                Set(before.keys).subtracting(after.keys),
                ["baseline_metrics", "after_metrics", "deltas"], method
            )
            // The A/B is the whole reason the deltas are deferred rather than
            // simply hidden - both files must still be reachable.
            for key in ["baseline_audio", "after_audio", "baseline_preview", "after_preview"] {
                XCTAssertNotNil(after[key], "\(method).\(key)")
            }
            XCTAssertNotNil(after["_audio_list"], method)
            // What the project state IS now survives every time.
            XCTAssertEqual(after["decision"] as? String, "rolled_back", method)
            XCTAssertEqual(after["verified"] as? Bool, true, method)
            let change = try XCTUnwrap(after["change"] as? [String: Any], method)
            XCTAssertEqual(change["applied"] as? String, "-18.0 dB", method)
            if method == "solo_bounce" { XCTAssertNotNil(after["solo_restored"]) }
        }
    }

    /// Honesty beats blindness. The silent-bounce warning quotes the very RMS
    /// blind withholds, and it keeps it: a model inventing a description of a
    /// silent file is a worse outcome than one reading a number it did not ask
    /// for, and the warning is the only thing between those two.
    func testAWarningKeepsItsNumbersEvenThoughTheyAreMetrics() throws {
        var payload = bouncePayload()
        payload["warning"] = "THE BOUNCE IS SILENT (rms [-140.0, -140.0] dB)."
        let after = try blinded("logic_bounce_range", payload)
        XCTAssertEqual(
            after["warning"] as? String,
            "THE BOUNCE IS SILENT (rms [-140.0, -140.0] dB)."
        )
    }

    // MARK: The seal

    func testTheWithheldKeysAreSealedToDiskAndNotDiscarded() throws {
        let before = evaluatePayload(method: "bounce")
        let after = try blinded("logic_evaluate_change", before)

        let path = try XCTUnwrap(after["sealed_metrics_path"] as? String)
        XCTAssertTrue(path.hasPrefix(root.path), "the seal belongs beside the renders")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let document = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(document["tool"] as? String, "logic_evaluate_change")
        let withheld = try XCTUnwrap(document["withheld"] as? [String: Any])
        XCTAssertEqual(Set(withheld.keys), ["baseline_metrics", "after_metrics", "deltas"])
        // Deferred, not lost: the numbers are byte-identical to what the
        // un-blind result would have carried, so nothing is re-rendered.
        let deltas = try XCTUnwrap(withheld["deltas"] as? [String: Any])
        XCTAssertEqual(deltas["rms_delta_db"] as? [Double], [-1.7])
    }

    /// The seal is a `.json`, and the captures resource layer serves an
    /// audio-extension ALLOW-LIST — so the numbers cannot be pulled back
    /// through `resources/read` either. Reaching them is a deliberate file
    /// read, which is exactly the friction blind exists to create.
    func testTheSealIsNotFetchableThroughTheCapturesResourceFamily() throws {
        let after = try blinded("logic_bounce_range", bouncePayload())
        let path = try XCTUnwrap(after["sealed_metrics_path"] as? String)
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "json")
        XCTAssertNil(Captures.audioMIMETypes["json"])
    }

    func testNothingToWithholdStillSaysSoAndNamesNoFile() throws {
        // A WAVE bounce: the metrics reader parses AIFF only, so there is no
        // `metrics` key to withhold and therefore nothing to seal.
        var payload = bouncePayload()
        payload.removeValue(forKey: "metrics")
        let after = try blinded("logic_bounce_range", payload)
        XCTAssertNil(after["sealed_metrics_path"])
        let note = try XCTUnwrap(after["blind_note"] as? String)
        XCTAssertEqual(note, Blind.note, "no seal exists, so none may be promised")
    }

    func testTheBlindNoteAlwaysOpensWithTheStandingSentence() throws {
        for (tool, payload) in [
            ("logic_bounce_range", bouncePayload()),
            ("logic_render_track", renderPayload()),
            ("logic_evaluate_change", evaluatePayload(method: "render"))
        ] {
            let note = try XCTUnwrap(try blinded(tool, payload)["blind_note"] as? String)
            XCTAssertTrue(note.hasPrefix(Blind.note), tool)
            XCTAssertTrue(note.contains("sealed_metrics_path"), tool)
        }
    }

    func testAToolWithNoPolicyIsNeverTouched() throws {
        let payload = bouncePayload()
        let untouched = try XCTUnwrap(
            Blind.applied(toolName: "logic_get_audio_clip", payload: payload) as? [String: Any]
        )
        XCTAssertEqual(Set(untouched.keys), Set(payload.keys))
        XCTAssertNil(untouched["blind_note"])
    }

    // MARK: The advertised surface

    /// The schema and the withholding table are two lists that must not drift:
    /// a tool that advertises `blind` and withholds nothing is a lie, and a
    /// policy on a tool that does not take the argument is dead code.
    func testExactlyTheToolsThatAdvertiseBlindHaveAWithholdingPolicy() throws {
        let advertised = Set(server.toolRegistry().filter { tool in
            (tool.inputSchema["properties"] as? [String: Any])?["blind"] != nil
        }.map(\.name))
        XCTAssertEqual(
            advertised,
            ["logic_bounce_range", "logic_render_track", "logic_evaluate_change"]
        )
        XCTAssertEqual(advertised, Set(Blind.policies.keys))
    }

    func testTheBlindArgumentPointsAtTheWorkflowRatherThanRestatingIt() throws {
        for name in Blind.policies.keys {
            let tool = try XCTUnwrap(server.toolRegistry().first { $0.name == name })
            let properties = try XCTUnwrap(tool.inputSchema["properties"] as? [String: Any])
            let blind = try XCTUnwrap(properties["blind"] as? [String: Any], name)
            XCTAssertEqual(blind["type"] as? String, "boolean", name)
            let text = try XCTUnwrap(blind["description"] as? String, name)
            XCTAssertTrue(text.contains("sealed_metrics_path"), name)
            XCTAssertTrue(text.contains("LISTENING in the server instructions"), name)
        }
    }

    /// Both duties the LISTENING paragraph gained: pass blind on a first
    /// listen, and TELL YOUR USER when you cannot hear at all.
    func testTheInstructionsCarryTheListeningFirstAndCannotHearDuties() {
        let instructions = MCPServer.instructions
        XCTAssertTrue(instructions.contains("`blind: true`"))
        XCTAssertTrue(instructions.contains("sealed_metrics_path"))
        XCTAssertTrue(instructions.contains("pass blind: true on your FIRST listen"))
        XCTAssertTrue(instructions.contains("SAY THAT TO YOUR USER"))
        XCTAssertTrue(instructions.contains("never claim to have heard what you did not receive"))
    }

    // MARK: The epistemics line

    private func noteText(of result: [String: Any]) throws -> String {
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        return try XCTUnwrap(
            (object["listen_note"] as? String) ?? (object["note"] as? String)
        )
    }

    func testEveryAudioCarryingResultGainsTheEpistemicsSentenceExactlyOnce() throws {
        for payload in [bouncePayload(), renderPayload(), evaluatePayload(method: "render")] {
            let text = try noteText(of: server.toolResult(payload: payload, isError: false))
            XCTAssertEqual(
                text.components(separatedBy: Tool.epistemicsNote).count - 1, 1,
                "the sentence must land once, not zero or twice"
            )
        }
    }

    func testAResultWithNoAudioDoesNotGainIt() throws {
        let result = server.toolResult(
            payload: ["success": true, "note": "Nothing was rendered."], isError: false
        )
        XCTAssertFalse(try noteText(of: result).contains(Tool.epistemicsNote))
    }

    /// `include_audio: false` rewrites the note to say the blocks were
    /// omitted — and the agent is then sent to the file paths, so it owes the
    /// same separation of heard from read. The sentence survives the rewrite.
    func testTheSentenceSurvivesTheIncludeAudioOptOut() throws {
        let result = server.toolResult(
            payload: bouncePayload(), isError: false, includeAudio: false
        )
        let text = try noteText(of: result)
        XCTAssertTrue(text.contains("Audio blocks were OMITTED"))
        XCTAssertTrue(text.contains(Tool.epistemicsNote))
        // And no audio block actually rode along.
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertFalse(content.contains { $0["type"] as? String == "audio" })
    }

    func testABlindResultCarriesBothNotes() throws {
        let blind = try blinded("logic_evaluate_change", evaluatePayload(method: "bounce"))
        let result = server.toolResult(payload: blind, isError: false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("blind_note"))
        XCTAssertTrue(try noteText(of: result).contains(Tool.epistemicsNote))
        XCTAssertTrue(content.contains { $0["type"] as? String == "audio" })
    }
}
