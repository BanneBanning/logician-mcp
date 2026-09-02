import XCTest
@testable import Logician

/// `logic_get_transport`'s never-a-missing-key contract, checked with Logic Pro
/// closed.
///
/// The tool's description promises *"Fields whose control bar element is
/// missing are null"*, and `logic_project_snapshot` serves this exact payload as
/// its `transport` section under a stricter one still: never a missing key,
/// because a diff would read a missing section as an empty project rather than
/// as a failed reader. Until 2026-09-02 the playhead pair and the
/// tempo/signature/key trio were assigned INSIDE the `if let` that found their
/// control bar group, so an unreadable control bar — a non-English Logic UI, a
/// collapsed window, a half-built tree — dropped five keys instead of nulling
/// them, and a snapshot diff across it would have said "the tempo was removed".
///
/// The hole is invisible on a healthy project, which is exactly why it needs a
/// test: the failing case is the one no live run reproduces.
final class TransportPayloadTests: XCTestCase {

    /// Every key the description names, and therefore every key the payload
    /// owes the caller on EVERY call. Written out here rather than read off the
    /// builder on purpose — a list that came from the code under test could
    /// never catch the code under test dropping one.
    private let documentedKeys = [
        "project_document",
        "playing",
        "recording",
        "cycle",
        "playhead_bar",
        "playhead_beat",
        "tempo",
        "time_signature",
        "key_signature",
        "metronome",
        "count_in",
        "solo_mode"
    ]

    // MARK: - The empty control bar

    func testAnEmptyControlBarStillPublishesEveryDocumentedKeyAsNull() {
        let payload = LogicAccessibility.transportPayload(ControlBarReading())
        for key in documentedKeys {
            guard let value = payload[key] else {
                return XCTFail("'\(key)' is MISSING from the payload; the contract is null, not absent")
            }
            XCTAssertTrue(value is NSNull, "'\(key)' should be null when its element is missing")
        }
    }

    /// The five that used to vanish, named one by one so a regression says
    /// which half of the walk broke.
    func testThePlayheadAndTheTempoTrioSurviveAMissingInnerGroup() {
        var reading = ControlBarReading()
        // The checkboxes read fine — only the inner "Control Bar" group is gone,
        // which is the shape a collapsed or non-English control bar produces.
        reading.playing = false
        reading.recording = false
        reading.cycle = true
        reading.metronome = false
        reading.countIn = true
        reading.soloMode = false
        let payload = LogicAccessibility.transportPayload(reading)
        for key in ["playhead_bar", "playhead_beat", "tempo", "time_signature", "key_signature"] {
            XCTAssertTrue(payload[key] is NSNull, "'\(key)' should be null, got \(payload[key] ?? "ABSENT")")
        }
        XCTAssertEqual(payload["cycle"] as? Bool, true)
        XCTAssertEqual(payload["count_in"] as? Bool, true)
        XCTAssertEqual(payload["playing"] as? Bool, false)
    }

    /// The key SET does not move with the reading — which is the property
    /// `logic_project_snapshot`'s diff actually depends on.
    func testAReadableAndAnUnreadableControlBarAgreeOnTheKeySet() {
        var full = ControlBarReading()
        full.projectDocument = "/Users/x/Music/Logic/Testlåt Copy.logicx"
        full.playing = false
        full.recording = false
        full.cycle = false
        full.metronome = false
        full.countIn = true
        full.soloMode = false
        full.playheadBar = 51
        full.playheadBeat = 1
        full.tempo = 121
        full.timeSignature = "5/4"
        full.keySignature = "C"
        let readable = Set(LogicAccessibility.transportPayload(full).keys)
        let unreadable = Set(LogicAccessibility.transportPayload(ControlBarReading()).keys)
        XCTAssertEqual(readable, unreadable, "the transport section's key set must not depend on what could be read")
    }

    // MARK: - Values pass through unchanged

    func testAFullReadingIsPublishedVerbatim() {
        var reading = ControlBarReading()
        reading.projectDocument = "/tmp/Song.logicx"
        reading.playing = true
        reading.playheadBar = 40
        reading.playheadBeat = 4
        reading.tempo = 121.5
        reading.timeSignature = "4/4"
        reading.keySignature = "Cmaj"
        let payload = LogicAccessibility.transportPayload(reading)
        XCTAssertEqual(payload["project_document"] as? String, "/tmp/Song.logicx")
        XCTAssertEqual(payload["playing"] as? Bool, true)
        XCTAssertEqual(payload["playhead_bar"] as? Int, 40)
        XCTAssertEqual(payload["playhead_beat"] as? Int, 4)
        XCTAssertEqual(payload["tempo"] as? Double, 121.5)
        XCTAssertEqual(payload["time_signature"] as? String, "4/4")
        XCTAssertEqual(payload["key_signature"] as? String, "Cmaj")
    }

    // MARK: - The conditional keys stay conditional, and say why

    /// `cycle_source` is an event, not a field: it appears only when the Cycle
    /// button was missing and the ruler answered instead. A null one would be a
    /// claim about a route that was never taken.
    func testCycleSourceAppearsOnlyWhenTheRulerAnsweredForTheButton() {
        XCTAssertNil(LogicAccessibility.transportPayload(ControlBarReading())["cycle_source"])
        var fromRuler = ControlBarReading()
        fromRuler.cycle = true
        fromRuler.cycleSource = "ruler_cycle_region"
        let payload = LogicAccessibility.transportPayload(fromRuler)
        XCTAssertEqual(payload["cycle_source"] as? String, "ruler_cycle_region")
        XCTAssertEqual(payload["cycle"] as? Bool, true)
    }

    /// An unknown Smart Tempo mode owes the caller the reason, on every call —
    /// the description promises the note whenever the mode is not reported, and
    /// that includes the case where the control bar published no group at all.
    func testAnUnknownModeIsANoteAndNeverAModeValue() {
        let payload = LogicAccessibility.transportPayload(ControlBarReading())
        XCTAssertNil(payload["project_tempo_mode"])
        XCTAssertNil(payload["project_tempo_mode_route"])
        let note = payload["project_tempo_mode_note"] as? String
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("Smart Tempo") == true, "the note should name the pane that answers it")
    }

    func testAKnownModeCarriesTheRouteItWasReadThrough() {
        var reading = ControlBarReading()
        reading.tempoMode = .keep
        reading.tempoModeRoute = "project_settings_window"
        let payload = LogicAccessibility.transportPayload(reading)
        XCTAssertEqual(payload["project_tempo_mode"] as? String, "keep")
        XCTAssertEqual(payload["project_tempo_mode_route"] as? String, "project_settings_window")
        XCTAssertNil(payload["project_tempo_mode_note"], "a clean window visit has nothing to confess")
    }

    /// A window visit that failed has to reach the caller ON TOP of the reason
    /// the cheap read could not answer, not instead of it.
    func testAFailedWindowFallbackIsAppendedToTheControlBarExplanation() {
        var reading = ControlBarReading()
        reading.tempoMode = .unreadable
        reading.tempoModeVisitNote = "the window opened but published no pop-up"
        let note = LogicAccessibility.transportPayload(reading)["project_tempo_mode_note"] as? String
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("publishes no value on it") == true)
        XCTAssertTrue(note?.contains("The Project Settings fallback also failed:") == true)
        XCTAssertTrue(note?.contains("published no pop-up") == true)
    }
}
