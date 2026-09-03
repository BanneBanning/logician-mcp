import XCTest
@testable import Logician

/// `logic_set_track_routing`'s pure half, pinned after the live profile of
/// 2026-09-03 (profiles/logic_set_track_routing.md) found three ways it could
/// waste a caller's time or mislead them: a menu that was open where the
/// shallow walk could not see it, a "destination" that is really a category,
/// and a confirm-poll that spent 6.7 s re-reading a slot that had already
/// settled on the wrong answer.
///
/// The AX halves of that fix (the deep menu walk, the tracking-menu press)
/// need live Logic; what is decidable without it is here.
final class RoutingWriteTests: XCTestCase {

    // MARK: - The confirm-poll's settle rule

    private func watch(target: String = "Bus 4", limit: Int = 5) -> ChannelStrip.SettleWatch {
        ChannelStrip.SettleWatch(target: target, limit: limit)
    }

    /// An EMPTY label is a repaint, not an answer — the case that made a
    /// landed write report `verification_failed` back in August. It must never
    /// count towards the settle rule, however many times it comes back.
    func testAnEmptyReadIsARepaintAndCountsForNothing() {
        var poll = watch()
        for _ in 0..<40 {
            XCTAssertEqual(poll.observe(""), .repainting)
        }
        XCTAssertEqual(poll.repeats, 0)
        XCTAssertEqual(poll.last, "")
    }

    /// Logic's own decorated title is the same destination as its head.
    func testTheRequestedDestinationLandsInEitherOfLogicsSpellings() {
        var poll = watch()
        XCTAssertEqual(poll.observe("Bus 4 → Aux 4"), .landed)
        XCTAssertEqual(poll.last, "Bus 4 → Aux 4")

        var head = watch()
        XCTAssertEqual(head.observe("Bus 4"), .landed)
    }

    /// The empty pair: the menu says `No Output`, the slot then reads the bare
    /// placeholder `Output`, and that is a landed write — not a mismatch.
    func testTheEmptyPairLandsUnderEitherName() {
        var poll = watch(target: "No Output")
        XCTAssertEqual(poll.observe("Output"), .landed)
    }

    /// The D2 shape: the slot answers the SAME wrong label over and over. The
    /// poll stops at the limit instead of running the whole 25-look budget.
    func testTheSameWrongLabelFiveTimesEndsThePoll() {
        var poll = watch()
        for look in 1...4 {
            XCTAssertEqual(poll.observe("Stereo Output"), .keepLooking, "look \(look)")
        }
        XCTAssertEqual(poll.observe("Stereo Output"), .settledOnAnother)
        XCTAssertEqual(poll.last, "Stereo Output")
        XCTAssertEqual(poll.repeats, 5)
    }

    /// A slot that is still MOVING is still polled: the run of identical reads
    /// restarts every time the label changes, so a strip that repaints through
    /// two or three intermediate labels keeps its full budget.
    func testALabelThatKeepsChangingNeverCountsAsSettled() {
        var poll = watch()
        for label in ["Stereo Output", "Output", "Stereo Output", "Bus 3", "Stereo Output"] {
            XCTAssertEqual(poll.observe(label), .keepLooking, label)
        }
        XCTAssertEqual(poll.repeats, 1)
    }

    /// Empty reads in the middle of a run of identical labels do not break the
    /// run — a repaint between two identical answers is still one answer,
    /// twice — but they do not advance it either.
    func testRepaintsBetweenIdenticalReadsNeitherBreakNorAdvanceTheRun() {
        var poll = watch(limit: 3)
        XCTAssertEqual(poll.observe("Stereo Output"), .keepLooking)
        XCTAssertEqual(poll.observe(""), .repainting)
        XCTAssertEqual(poll.observe("Stereo Output"), .keepLooking)
        XCTAssertEqual(poll.observe(""), .repainting)
        XCTAssertEqual(poll.observe("Stereo Output"), .settledOnAnother)
    }

    /// A write that lands LATE — after the slot has held its old value a few
    /// times — is still a landed write, as long as it lands inside the limit.
    func testALateArrivalStillLands() {
        var poll = watch(limit: 5)
        XCTAssertEqual(poll.observe("Stereo Output"), .keepLooking)
        XCTAssertEqual(poll.observe("Stereo Output"), .keepLooking)
        XCTAssertEqual(poll.observe("Bus 4 → Aux 4"), .landed)
    }

    /// The production numbers: the budget did not shrink, only the pointless
    /// tail of it, and the first look is free.
    func testTheShippedPollKeepsItsFullBudgetAndLooksBeforeItSleeps() {
        XCTAssertEqual(LogicAccessibility.routingConfirmAttempts, 25)
        XCTAssertEqual(LogicAccessibility.routingConfirmInterval, 0.12)
        XCTAssertEqual(LogicAccessibility.routingSettledMisses, 5)
        XCTAssertFalse(lookFirstShouldSleep(attempt: 0))
    }

    // MARK: - Categories are not destinations

    func testACategoryRefusalNamesWhatIsInsideIt() {
        let message = ChannelStrip.categoryRefusal(
            requested: "Mono", category: "Mono", leaves: ["Output 1", "Output 2"]
        )
        XCTAssertTrue(message.contains("CATEGORY"), message)
        XCTAssertTrue(message.contains("Output 1, Output 2"), message)
        XCTAssertTrue(message.contains("nothing was written"), message)
    }

    /// The caller asked by head ("Mono") and Logic titles it differently: the
    /// refusal says both, so a retry can be spelled the way Logic spells it.
    func testACategoryRefusalNamesLogicsOwnTitleWhenItDiffers() {
        let message = ChannelStrip.categoryRefusal(
            requested: "Mono", category: "Mono Output", leaves: ["Output 1"]
        )
        XCTAssertTrue(message.contains("'Mono Output'"), message)
    }

    /// Same word, different case, is not a different title worth reporting.
    func testACategoryRefusalDoesNotRepeatTheSameTitleBack() {
        let message = ChannelStrip.categoryRefusal(
            requested: "mono", category: "Mono", leaves: ["Output 1"]
        )
        XCTAssertFalse(message.contains("Logic titles it"), message)
    }

    /// A category whose contents Logic has not published yet (measured: `Mono`
    /// answers with an AXMenu holding nothing until the submenu is opened)
    /// falls back to the rest of the slot's menu rather than trailing off.
    func testACategoryWithNoPublishedContentsOffersTheRestOfTheMenu() {
        let message = ChannelStrip.categoryRefusal(
            requested: "Mono", category: "Mono", leaves: [],
            offered: ["Stereo Output", "No Output", "Mono", "Bus 1 → Aux 1"]
        )
        XCTAssertTrue(message.contains("until the submenu is opened"), message)
        XCTAssertTrue(message.contains("Bus 1 → Aux 1"), message)
        XCTAssertFalse(message.contains("it holds:"), message)
    }

    /// And it does not offer the category back as the way out of itself.
    func testTheCategoryIsNotOfferedAsAnAlternativeToItself() {
        let message = ChannelStrip.categoryRefusal(
            requested: "Mono", category: "Mono", leaves: [],
            offered: ["Stereo Output", "Mono", "No Output"]
        )
        let tail = message.components(separatedBy: "menu is: ").last ?? ""
        XCTAssertFalse(tail.contains("Mono"), tail)
        XCTAssertTrue(tail.contains("Stereo Output"), tail)
    }

    /// With nothing to offer at all, it still says what to do next.
    func testACategoryWithNothingToOfferStillOffersAWayOn() {
        let message = ChannelStrip.categoryRefusal(
            requested: "Surround", category: "Surround", leaves: []
        )
        XCTAssertTrue(message.contains("open the slot in Logic"), message)
        XCTAssertFalse(message.contains("it holds:"), message)
    }

    /// The output menu of a 256-bus project must not paste itself into an
    /// error message.
    func testALongCategoryListIsCapped() {
        let leaves = (1...64).map { "Output \($0)" }
        let message = ChannelStrip.categoryRefusal(
            requested: "Mono", category: "Mono", leaves: leaves
        )
        XCTAssertTrue(message.contains("Output 20"), message)
        XCTAssertFalse(message.contains("Output 21"), message)
        XCTAssertTrue(message.contains("64 in all"), message)
    }

    // MARK: - The failure that opened no menu

    /// The sentence a caller gets when no menu ever came up has to carry the
    /// two facts it can act on: nothing was written, and it is retryable.
    func testTheMenuFailureSaysNothingWasWrittenAndHowManyTriesItTook() {
        let message = ChannelStrip.slotMenuFailure(attempts: LogicAccessibility.slotMenuAttempts)
        XCTAssertTrue(message.contains("3 presses"), message)
        XCTAssertTrue(message.contains("NOTHING was written"), message)
        XCTAssertTrue(message.contains("retry"), message)
    }

    /// Three attempts, not five: the two extra ones only ever bought a longer
    /// walk to the same failure (21 s of it, measured live 2026-09-03).
    func testTheMenuOpenBudgetIsThreeAttemptsWithALookFirstPoll() {
        XCTAssertEqual(LogicAccessibility.slotMenuAttempts, 3)
        XCTAssertEqual(LogicAccessibility.slotMenuShallowDeadline, 0.4)
        XCTAssertEqual(LogicAccessibility.slotMenuPollInterval, 0.025)
    }

    // MARK: - "Restored" means what it says

    /// The D2 wording defect: a failure that never attempted an inverse write
    /// used to report `Restored: false`, which reads as "it was attempted and
    /// it failed".
    func testAFailureThatAttemptedNoRestoreDoesNotClaimOne() {
        let message = LogicianError.verificationFailed(
            requested: "output = Mono",
            actual: "the slot reads 'Stereo Output'",
            restored: nil
        ).errorDescription ?? ""
        XCTAssertTrue(message.contains("No restore was attempted."), message)
        XCTAssertFalse(message.contains("Restored:"), message)
    }

    /// And a failure that DID attempt one still reports it either way.
    func testAFailureThatAttemptedARestoreStillReportsIt() {
        for restored in [true, false] {
            let message = LogicianError.verificationFailed(
                requested: "output = Bus 4", actual: "the slot reads 'Stereo Output'",
                restored: restored
            ).errorDescription ?? ""
            XCTAssertTrue(message.contains("Restored: \(restored)."), message)
        }
    }

    /// The error code agents branch on is unchanged by any of this.
    func testTheVerificationFailedCodeIsUnchanged() {
        XCTAssertEqual(
            LogicianError.verificationFailed(requested: "a", actual: "b", restored: nil).code,
            "verification_failed"
        )
    }
}
