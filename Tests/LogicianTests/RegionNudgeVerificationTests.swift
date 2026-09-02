import XCTest
@testable import Logician

/// What a nudge is allowed to call verified.
///
/// `logic_move_region` gated its ONLY positional check on `byBeats == 0` and
/// had no check on `start_beat` anywhere, so two things were live in the
/// shipped tool (profiled 2026-09-02 against the sandbox project): a
/// `by_beats`-only nudge that moved nothing at all came back `success: true,
/// verified: true, state: "moved"` — measured, `{by_beats: 1}` reported
/// `from_bar: 20, to_bar: 20, to_beat: 2, verified: true` — and
/// `{by_bars: 16, by_beats: 1}` switched the exact bar comparison off as well,
/// so a sixteen-bar move that travelled three bars would have passed.
///
/// The after-check also compared the rendered region TOTAL and then told the
/// caller the nudge "did not swallow a neighbour it landed on". That is true of
/// a neighbour swallowed WHOLE, which is the only case a count can see, while
/// the tool's own description warns about the likelier one: Logic TRIMS
/// whatever a nudged region is laid over, and a trim moves a neighbour's start
/// or end and leaves the count exactly where it was.
///
/// These pin both replacements without Logic running — the evidence they read
/// is what the two censuses either side of the nudge already hold.
final class RegionNudgeVerificationTests: XCTestCase {

    // MARK: The position check

    /// The whole-bar case, which is the one the description always promised.
    func testWholeBarMoveIsExactInBothTerms() {
        XCTAssertEqual(
            RegionEditGuard.nudgeVerdict(
                byBars: 1, byBeats: 0, fromBar: 20, fromBeat: 1, toBar: 21, toBeat: 1
            ),
            .exact
        )
        XCTAssertEqual(
            RegionEditGuard.nudgeVerdict(
                byBars: -16, byBeats: 0, fromBar: 36, fromBeat: 1, toBar: 20, toBeat: 1
            ),
            .exact
        )
    }

    /// THE DEFECT, in one assertion: a beat-only nudge that did not move the
    /// region. The shipped code found the region present, found it selected,
    /// found the region total unchanged and returned `verified: true`.
    func testBeatOnlyNudgeThatDidNotMoveIsUnmoved() {
        XCTAssertEqual(
            RegionEditGuard.nudgeVerdict(
                byBars: 0, byBeats: 1, fromBar: 20, fromBeat: 1, toBar: 20, toBeat: 1
            ),
            .unmoved
        )
        XCTAssertEqual(
            RegionEditGuard.nudgeVerdict(
                byBars: 0, byBeats: -1, fromBar: 20, fromBeat: 3, toBar: 20, toBeat: 3
            ),
            .unmoved
        )
    }

    /// And a beat-only nudge that DID move is verified against the beat, in
    /// both directions — the pair measured live on the reference project.
    func testBeatOnlyNudgeIsVerifiedAgainstTheBeat() {
        XCTAssertEqual(
            RegionEditGuard.nudgeVerdict(
                byBars: 0, byBeats: 1, fromBar: 20, fromBeat: 1, toBar: 20, toBeat: 2
            ),
            .exact
        )
        XCTAssertEqual(
            RegionEditGuard.nudgeVerdict(
                byBars: 0, byBeats: -1, fromBar: 20, fromBeat: 2, toBar: 20, toBeat: 1
            ),
            .exact
        )
    }

    /// A beat nudge that landed on the wrong beat is not a success either —
    /// two beats requested, one delivered.
    func testBeatNudgeThatStoppedShortIsWrong() {
        XCTAssertEqual(
            RegionEditGuard.nudgeVerdict(
                byBars: 0, byBeats: 2, fromBar: 20, fromBeat: 1, toBar: 20, toBeat: 2
            ),
            .wrongPosition
        )
    }

    /// The second consequence of the old gate: one beat in the request took the
    /// exact bar comparison with it, so a sixteen-bar move that travelled three
    /// bars passed. It does not any more.
    func testMixedBarAndBeatMoveVerifiesTheBarsToo() {
        XCTAssertEqual(
            RegionEditGuard.nudgeVerdict(
                byBars: 16, byBeats: 1, fromBar: 20, fromBeat: 1, toBar: 36, toBeat: 2
            ),
            .exact
        )
        XCTAssertEqual(
            RegionEditGuard.nudgeVerdict(
                byBars: 16, byBeats: 1, fromBar: 20, fromBeat: 1, toBar: 23, toBeat: 2
            ),
            .wrongPosition
        )
        XCTAssertEqual(
            RegionEditGuard.nudgeVerdict(
                byBars: 16, byBeats: 1, fromBar: 20, fromBeat: 1, toBar: 20, toBeat: 1
            ),
            .unmoved
        )
    }

    /// A move in the wrong DIRECTION is wrong, not "moved".
    func testWrongDirectionIsWrongPosition() {
        XCTAssertEqual(
            RegionEditGuard.nudgeVerdict(
                byBars: 1, byBeats: 0, fromBar: 20, fromBeat: 1, toBar: 19, toBeat: 1
            ),
            .wrongPosition
        )
    }

    /// Beats that carry across the bar line, with the meter INFERRED from the
    /// move rather than read from Logic: the reference project is 5/4, and beat
    /// 5 plus one beat is the next bar's beat 1.
    func testBeatsCarryingAcrossTheBarLineNameTheMeterTheyImply() {
        XCTAssertEqual(
            RegionEditGuard.nudgeVerdict(
                byBars: 0, byBeats: 1, fromBar: 20, fromBeat: 5, toBar: 21, toBeat: 1
            ),
            .carried(beatsPerBar: 5)
        )
        XCTAssertEqual(
            RegionEditGuard.nudgeVerdict(
                byBars: 0, byBeats: 5, fromBar: 20, fromBeat: 1, toBar: 21, toBeat: 1
            ),
            .carried(beatsPerBar: 5)
        )
        // Leftwards, which is where truncating integer division would put the
        // bar line one bar out.
        XCTAssertEqual(
            RegionEditGuard.nudgeVerdict(
                byBars: 0, byBeats: -1, fromBar: 21, fromBeat: 1, toBar: 20, toBeat: 5
            ),
            .carried(beatsPerBar: 5)
        )
        // Bars and beats together, the beats carrying.
        XCTAssertEqual(
            RegionEditGuard.nudgeVerdict(
                byBars: 2, byBeats: 1, fromBar: 20, fromBeat: 5, toBar: 23, toBeat: 1
            ),
            .carried(beatsPerBar: 5)
        )
    }

    /// A "carry" that no meter can explain is a failure, not an inference. One
    /// beat requested and a whole bar travelled needs a 1-beat bar, and a
    /// rightward beat cannot carry a region backwards.
    func testACarryNoMeterExplainsIsWrongPosition() {
        XCTAssertEqual(
            RegionEditGuard.nudgeVerdict(
                byBars: 0, byBeats: 1, fromBar: 20, fromBeat: 1, toBar: 21, toBeat: 1
            ),
            .wrongPosition
        )
        XCTAssertEqual(
            RegionEditGuard.nudgeVerdict(
                byBars: 0, byBeats: 1, fromBar: 20, fromBeat: 3, toBar: 19, toBeat: 3
            ),
            .wrongPosition
        )
        // Beat 7 in a bar the same move says holds 5 beats.
        XCTAssertEqual(
            RegionEditGuard.nudgeVerdict(
                byBars: 0, byBeats: 1, fromBar: 20, fromBeat: 7, toBar: 21, toBeat: 3
            ),
            .wrongPosition
        )
    }

    /// The request, in the words the refusal has to use.
    func testRequestSentenceReadsLikeTheArguments() {
        XCTAssertEqual(RegionEditGuard.nudgeRequestSentence(byBars: 1, byBeats: 0), "+1 bar")
        XCTAssertEqual(RegionEditGuard.nudgeRequestSentence(byBars: -16, byBeats: 0), "-16 bars")
        XCTAssertEqual(
            RegionEditGuard.nudgeRequestSentence(byBars: 16, byBeats: 1),
            "+16 bars and +1 beat"
        )
        XCTAssertEqual(RegionEditGuard.nudgeRequestSentence(byBars: 0, byBeats: -2), "-2 beats")
    }

    /// A region that did not move says so, and the sentence says the ONE thing
    /// the caller acts on: it is still where it started.
    func testUnmovedSentenceSaysItDidNotMoveAtAll() {
        let sentence = RegionEditGuard.nudgeSentence(
            verdict: .unmoved, byBars: 0, byBeats: 1,
            fromBar: 20, fromBeat: 1, toBar: 20, toBeat: 1
        )
        XCTAssertTrue(sentence.contains("did not move at all"))
        XCTAssertTrue(sentence.contains("bar 20 beat 1"))
        let wrong = RegionEditGuard.nudgeSentence(
            verdict: .wrongPosition, byBars: 16, byBeats: 0,
            fromBar: 20, fromBeat: 1, toBar: 23, toBeat: 1
        )
        XCTAssertTrue(wrong.contains("+16 bars"))
        XCTAssertTrue(wrong.contains("bar 23 beat 1"))
        XCTAssertTrue(wrong.contains("logic_list_regions"))
    }

    // MARK: The neighbours

    private func region(
        _ name: String, _ startBar: Int, _ endBar: Int,
        startBeat: Int? = nil, endBeat: Int? = nil, selected: Bool = false
    ) -> [String: Any] {
        // Shaped exactly like `parseRegion`: the beat keys are ABSENT on the
        // bar line, which is the shape that made every naive comparison here
        // wrong.
        var entry: [String: Any] = ["name": name, "start_bar": startBar, "end_bar": endBar]
        if let startBeat { entry["start_beat"] = startBeat }
        if let endBeat { entry["end_beat"] = endBeat }
        if selected { entry["selected"] = true }
        return entry
    }

    /// The move itself is not damage: the region that was supposed to travel is
    /// taken out of the comparison on both sides.
    func testTheMovedRegionIsNotItsOwnNeighbour() {
        let movedBefore = region("Crash", 20, 21, selected: true)
        let movedAfter = region("Crash", 21, 22, selected: true)
        let verdict = RegionEditGuard.neighbourVerdict(
            before: [movedBefore, region("Crash", 41, 44, endBeat: 3)],
            after: [movedAfter, region("Crash", 41, 44, endBeat: 3)],
            movedBefore: movedBefore, movedAfter: movedAfter
        )
        XCTAssertEqual(verdict, .untouched)
    }

    /// THE OTHER DEFECT: a trimmed neighbour. The region total is identical on
    /// both sides — the count check calls this clean and used to say in the
    /// result that no neighbour was swallowed — while the neighbour has lost
    /// three bars off its front.
    func testATrimmedNeighbourIsSeenWhileTheCountSaysNothingHappened() {
        let movedBefore = region("Crash", 20, 22, selected: true)
        let movedAfter = region("Crash", 24, 26, selected: true)
        let before = [movedBefore, region("Bas", 23, 30)]
        let after = [movedAfter, region("Bas", 26, 30, startBeat: 1)]
        XCTAssertEqual(
            RegionEditGuard.delta(expected: 0, before: before.count, after: after.count),
            .asExpected
        )
        guard case .changed(let lost, let gained) = RegionEditGuard.neighbourVerdict(
            before: before, after: after, movedBefore: movedBefore, movedAfter: movedAfter
        ) else { return XCTFail("a trimmed neighbour has to be a change") }
        XCTAssertEqual(lost, [RegionEditGuard.Span(name: "Bas", startBar: 23, endBar: 30)])
        XCTAssertEqual(gained, [RegionEditGuard.Span(name: "Bas", startBar: 26, endBar: 30)])
        let sentence = RegionEditGuard.neighbourSentence(lost: lost, gained: gained)
        XCTAssertTrue(sentence.contains("'Bas' bar 23 beat 1 to bar 30 beat 1"))
        XCTAssertTrue(sentence.contains("'Bas' bar 26 beat 1 to bar 30 beat 1"))
        XCTAssertTrue(sentence.contains("TRIMS"))
        XCTAssertTrue(sentence.contains("logic_list_regions"))
    }

    /// A trim of a single BEAT, which is the smallest damage a nudge can do and
    /// the one an `end_bar` comparison alone would miss.
    func testABeatOfTrimIsSeen() {
        let movedBefore = region("Crash", 20, 22, selected: true)
        let movedAfter = region("Crash", 20, 22, startBeat: 2, endBeat: 2, selected: true)
        let verdict = RegionEditGuard.neighbourVerdict(
            before: [movedBefore, region("Bas", 22, 30, startBeat: 2)],
            after: [movedAfter, region("Bas", 22, 30, startBeat: 3)],
            movedBefore: movedBefore, movedAfter: movedAfter
        )
        guard case .changed(let lost, let gained) = verdict else {
            return XCTFail("a beat of trim is still a trim")
        }
        XCTAssertEqual(lost.first?.startBeat, 2)
        XCTAssertEqual(gained.first?.startBeat, 3)
    }

    /// A neighbour swallowed whole: the count check catches that one too, and
    /// this NAMES it, which the count cannot.
    func testASwallowedNeighbourIsNamed() {
        let movedBefore = region("Crash", 20, 22, selected: true)
        let movedAfter = region("Crash", 23, 25, selected: true)
        let verdict = RegionEditGuard.neighbourVerdict(
            before: [movedBefore, region("Tamb", 23, 25)],
            after: [movedAfter],
            movedBefore: movedBefore, movedAfter: movedAfter
        )
        guard case .changed(let lost, let gained) = verdict else {
            return XCTFail("a swallowed neighbour is a change")
        }
        XCTAssertEqual(lost, [RegionEditGuard.Span(name: "Tamb", startBar: 23, endBar: 25)])
        XCTAssertTrue(gained.isEmpty)
        XCTAssertTrue(RegionEditGuard.neighbourSentence(lost: lost, gained: gained)
            .contains("'Tamb' bar 23 beat 1 to bar 25 beat 1 is gone"))
    }

    /// Two regions on one row can carry the same NAME — a copy of `Crash`
    /// beside `Crash`, which is exactly how the live proof of this tool is
    /// staged — so the comparison is a multiset of spans and not a name match.
    func testDuplicateNamesOnOneRowAreCountedNotMatched() {
        let movedBefore = region("Crash", 20, 21, selected: true)
        let movedAfter = region("Crash", 21, 22, selected: true)
        XCTAssertEqual(
            RegionEditGuard.neighbourVerdict(
                before: [movedBefore, region("Crash", 41, 44, endBeat: 3)],
                after: [region("Crash", 41, 44, endBeat: 3), movedAfter],
                movedBefore: movedBefore, movedAfter: movedAfter
            ),
            .untouched
        )
        // And the namesake being trimmed is still seen, though every name in
        // the two lists matches.
        guard case .changed = RegionEditGuard.neighbourVerdict(
            before: [movedBefore, region("Crash", 41, 44, endBeat: 3)],
            after: [movedAfter, region("Crash", 41, 43)],
            movedBefore: movedBefore, movedAfter: movedAfter
        ) else { return XCTFail("the namesake lost a bar") }
    }

    /// A region whose help sentence published no position at all is COUNTED,
    /// never compared — and when the two counts disagree the verdict says so
    /// instead of reporting "untouched" about regions it could not read.
    func testUnparsedPositionsAreReportedNotAssumedClean() {
        let movedBefore = region("Crash", 20, 21, selected: true)
        let movedAfter = region("Crash", 21, 22, selected: true)
        XCTAssertEqual(
            RegionEditGuard.neighbourVerdict(
                before: [movedBefore, ["name": "Bas"]],
                after: [movedAfter, ["name": "Bas"]],
                movedBefore: movedBefore, movedAfter: movedAfter
            ),
            .untouched
        )
        XCTAssertEqual(
            RegionEditGuard.neighbourVerdict(
                before: [movedBefore, ["name": "Bas"]],
                after: [movedAfter],
                movedBefore: movedBefore, movedAfter: movedAfter
            ),
            .unreadable(before: 1, after: 0)
        )
    }

    // MARK: The moved region's own length

    /// Whatever the nudge did to the start it must have done to the end. No
    /// meter needed, and it catches the overlay damage from the other side —
    /// the region that moved being the one that got trimmed.
    func testTheMovedRegionKeepsItsLength() {
        XCTAssertTrue(RegionEditGuard.nudgeLengthKept(
            before: RegionEditGuard.Span(name: "Crash", startBar: 20, endBar: 23, endBeat: 3),
            after: RegionEditGuard.Span(name: "Crash", startBar: 21, endBar: 24, endBeat: 3)
        ))
        // A beat nudge, the end carrying across the bar line with the start.
        XCTAssertTrue(RegionEditGuard.nudgeLengthKept(
            before: RegionEditGuard.Span(
                name: "Crash", startBar: 20, startBeat: 5, endBar: 23, endBeat: 5
            ),
            after: RegionEditGuard.Span(name: "Crash", startBar: 21, endBar: 24)
        ))
        // The start travelled and the end stayed: the region was trimmed.
        XCTAssertFalse(RegionEditGuard.nudgeLengthKept(
            before: RegionEditGuard.Span(name: "Crash", startBar: 20, endBar: 23),
            after: RegionEditGuard.Span(name: "Crash", startBar: 21, endBar: 23)
        ))
    }
}
