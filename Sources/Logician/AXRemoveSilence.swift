import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

/// G30's pure half: reading Logic's own live preview off the Remove Silence
/// window, naming the four numeric fields by the labels Logic printed next to
/// them, and deciding whether the window that appeared is the one this tool
/// asked for.
enum RemoveSilence {
    /// "9 Regions" / "1 Region" -> 9 / 1. nil for anything else, because a
    /// preview that cannot be read must not be reported as a number.
    static func previewCount(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().contains("region") else { return nil }
        let digits = trimmed.prefix { $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
        return Int(digits)
    }

    // MARK: - The window's direct children, as data

    /// One direct child of the Remove Silence window, in tree order. The
    /// window is FLAT — all 20 controls are direct children, measured 5/5 on
    /// 2026-09-02 — so a single-level read sees everything, and this is the
    /// whole input the reading below needs.
    struct Child: Equatable {
        let role: String
        let value: String
        let title: String

        init(role: String, value: String = "", title: String = "") {
            self.role = role
            self.value = value
            self.title = title
        }
    }

    // MARK: - Naming the four numbers

    /// The stable key each numeric field is published under, and the fragment
    /// of Logic's printed label that identifies it.
    ///
    /// WHY THE KEYS EXIST AT ALL. The tool used to ship the four values as
    /// `numeric_fields_in_order` and describe that order in prose — in two
    /// places, BOTH of them wrong. The array is
    /// `[minimum silence, post release, pre attack, threshold]` (measured 5/5,
    /// labels read off the window); the result note and the tool description
    /// both said `(threshold, minimum silence, pre-attack, post-release)`, so
    /// an agent following either read the −28 dB threshold as a post-release
    /// TIME and the 0,1 s minimum silence as a threshold in dB. Both readings
    /// are physically absurd and both were silent.
    ///
    /// So order is no longer the contract. The window prints a label beside
    /// every value, as a static-text sibling the reader already walks past;
    /// each value is published WITH its label, and the stable key is added on
    /// top for the labels this server recognises.
    enum FieldKey: String, CaseIterable {
        case thresholdDb = "threshold_db"
        case minimumSilenceSeconds = "minimum_silence_seconds"
        case preAttackSeconds = "pre_attack_seconds"
        case postReleaseSeconds = "post_release_seconds"

        /// Compared lowercased against the printed label, so the trailing
        /// colon and Logic's `-Time` suffix are not part of the gate.
        var labelFragment: String {
            switch self {
            case .thresholdDb: return LogicUIStrings.Element.RemoveSilenceLabel.threshold
            case .minimumSilenceSeconds:
                return LogicUIStrings.Element.RemoveSilenceLabel.minimumSilence
            case .preAttackSeconds: return LogicUIStrings.Element.RemoveSilenceLabel.preAttack
            case .postReleaseSeconds: return LogicUIStrings.Element.RemoveSilenceLabel.postRelease
            }
        }
    }

    static func fieldKey(forLabel label: String) -> FieldKey? {
        let lowered = label.lowercased()
        return FieldKey.allCases.first { lowered.contains($0.labelFragment) }
    }

    /// Logic prints these in the SYSTEM's locale, so on the reference Mac they
    /// carry a decimal COMMA (`"0,1000"`) even though the UI language is
    /// English. Anything that parses them as a float has to be told, which is
    /// why the parsed number ships alongside the string rather than instead of
    /// it.
    static func numericValue(_ raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        for separator in LogicUIStrings.Format.decimalSeparators where separator != "." {
            text = text.replacingOccurrences(of: String(separator), with: ".")
        }
        return Double(text)
    }

    /// One numeric field: what Logic printed, what it printed beside it, and
    /// the two derived answers.
    struct Field: Equatable {
        let label: String
        let text: String
        let key: FieldKey?
        let number: Double?

        var payload: [String: Any] {
            var entry: [String: Any] = ["label": label, "value": text]
            if let key { entry["key"] = key.rawValue }
            if let number { entry["number"] = number }
            return entry
        }
    }

    /// Everything the window says, as a value.
    struct Reading: Equatable {
        let previewText: String?
        let previewRegions: Int?
        let zeroCrossing: Bool?
        let zeroCrossingLabel: String?
        let fields: [Field]

        /// True only when every one of the four keys was resolved from a
        /// printed label — the honest gate on publishing `threshold_db` and
        /// friends at all.
        var allFieldsNamed: Bool {
            Set(fields.compactMap(\.key)).count == FieldKey.allCases.count
        }

        var payload: [String: Any] {
            var state: [String: Any] = [:]
            if let previewRegions { state["preview_regions"] = previewRegions }
            if let previewText { state["preview_text"] = previewText }
            // D5: keyed by something stable. This used to be keyed by the
            // checkbox's own TITLE, so the payload read
            // `"Search Zero Crossing": true` — a key that is a different
            // string on a translated Logic and that no caller can address on
            // any Logic.
            if let zeroCrossing { state["zero_crossing"] = zeroCrossing }
            if let zeroCrossingLabel { state["zero_crossing_label"] = zeroCrossingLabel }
            guard !fields.isEmpty else { return state }
            state["fields"] = fields.map(\.payload)
            // Kept for compatibility, and now described in the order it is
            // actually in: minimum silence, post release, pre attack,
            // threshold. Read `fields` instead — the order is Logic's, not a
            // contract.
            state["numeric_fields_in_order"] = fields.map(\.text)
            if allFieldsNamed {
                state["fields_identified_by"] = "label"
                for field in fields {
                    guard let key = field.key else { continue }
                    state[key.rawValue] = field.number ?? field.text
                }
            } else {
                state["fields_identified_by"] = "unrecognised"
                state["fields_note"] = "Logic's labels for these fields did not match the ones "
                    + "this server knows (a translated Logic does that), so the values are "
                    + "reported ONLY with the label Logic printed beside each one - read "
                    + "`fields[].label`. No threshold_db / minimum_silence_seconds / "
                    + "pre_attack_seconds / post_release_seconds key is published, because "
                    + "guessing which is which off their position is exactly the wrong answer "
                    + "this tool used to ship."
            }
            state["decimal_note"] = "`value` is the string Logic printed and uses the SYSTEM's "
                + "decimal separator - a comma on the reference Mac (\"0,1000\"). `number` is "
                + "that value parsed; do not run Double() over `value` yourself."
            return state
        }
    }

    /// Pairs each numeric value with the label that follows it.
    ///
    /// The pairing is positional but LOCAL: the window emits an `AXGroup`
    /// carrying the value and then the `AXStaticText` naming it (measured 5/5,
    /// 2026-09-02). Values queue up and each label claims the OLDEST unclaimed
    /// one, so a window that emitted all four groups before all four labels
    /// would still pair correctly. The preview count is a static text too and
    /// is taken out of the label stream first — it names nothing.
    static func read(_ children: [Child]) -> Reading {
        var previewText: String?
        var previewRegions: Int?
        var zeroCrossing: Bool?
        var zeroCrossingLabel: String?
        var pendingValues: [String] = []
        var fields: [Field] = []
        for child in children {
            switch child.role {
            case "AXStaticText":
                if let count = previewCount(child.value) {
                    previewRegions = count
                    previewText = child.value
                    continue
                }
                let label = child.value.trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty, !pendingValues.isEmpty else { continue }
                let text = pendingValues.removeFirst()
                fields.append(
                    Field(
                        label: label, text: text,
                        key: fieldKey(forLabel: label), number: numericValue(text)
                    )
                )
            case "AXCheckBox":
                zeroCrossing = child.value == "1"
                zeroCrossingLabel = child.title
            case "AXGroup":
                if !child.value.isEmpty { pendingValues.append(child.value) }
            default:
                break
            }
        }
        // A value nothing labelled is still a value, and dropping it would
        // silently shorten `numeric_fields_in_order`.
        for text in pendingValues {
            fields.append(Field(label: "", text: text, key: nil, number: numericValue(text)))
        }
        return Reading(
            previewText: previewText, previewRegions: previewRegions,
            zeroCrossing: zeroCrossing, zeroCrossingLabel: zeroCrossingLabel, fields: fields
        )
    }

    // MARK: - Whether OK is worth pressing at all

    /// What the apply path should do with Logic's own preview count.
    enum Commit: Equatable {
        /// Logic says the current settings leave the region whole. Pressing OK
        /// would write nothing, so it is not pressed: a verified no-op, and the
        /// modal is cancelled instead.
        case nothingToStrip
        /// Press OK. `expectedDelta` is how far the project's rendered region
        /// total must move — the preview's count minus the one region that was
        /// there — and nil when the preview could not be read at all, which
        /// leaves "the total moved" as the only available check.
        case press(expectedDelta: Int?)
    }

    static func commit(previewRegions: Int?) -> Commit {
        guard let previewRegions else { return .press(expectedDelta: nil) }
        if previewRegions <= 1 { return .nothingToStrip }
        return .press(expectedDelta: previewRegions - 1)
    }

    // MARK: - Is the window that appeared the right one?

    /// What was read off the window that opened, as the pure decision's input.
    struct WindowEvidence: Equatable {
        let title: String
        let numericFieldCount: Int
        let checkBoxCount: Int
        let radioButtonCount: Int
        let popUpButtonCount: Int
        let publishesDefaultButton: Bool
        let publishesCancelButton: Bool
    }

    /// How this call knows what it is looking at.
    enum Identification: Equatable {
        /// The window's title is Logic's own `Remove Silence`.
        case title
        /// The title said nothing, but a window APPEARED when the command
        /// fired and its shape is the Remove Silence window's.
        case appeared
        /// Something else opened. Cancel it and refuse — never press OK.
        case unrecognised(String)

        var word: String {
            switch self {
            case .title: return "title"
            case .appeared: return "appeared"
            case .unrecognised: return "unrecognised"
            }
        }
    }

    /// MEASURED SHAPE, identical on 5/5 openings 2026-09-02: four numeric
    /// `AXGroup`s, one checkbox, no radio buttons, no pop-ups, and the window
    /// publishes both `AXDefaultButton` and `AXCancelButton`.
    ///
    /// The preview TEXT is deliberately not part of the gate. It is the one
    /// piece of this window that is words ("8 Regions"), so requiring it would
    /// make the shape route fail on exactly the translated Logic the shape
    /// route exists for.
    static func identify(_ evidence: WindowEvidence) -> Identification {
        if evidence.title == LogicUIStrings.Window.removeSilence { return .title }
        let shapeMatches = evidence.numericFieldCount == FieldKey.allCases.count
            && evidence.checkBoxCount == 1
            && evidence.radioButtonCount == 0
            && evidence.popUpButtonCount == 0
            && evidence.publishesDefaultButton
            && evidence.publishesCancelButton
        if shapeMatches { return .appeared }
        return .unrecognised(
            "a window titled '\(evidence.title)' opened when 'Remove Silence from Audio Region…' "
                + "fired, and it is not the Remove Silence window: that one publishes four "
                + "numeric fields, one checkbox, no radio buttons, no pop-up buttons and both a "
                + "default and a cancel button, while this one publishes "
                + "\(evidence.numericFieldCount) numeric field(s), \(evidence.checkBoxCount) "
                + "checkbox(es), \(evidence.radioButtonCount) radio button(s), "
                + "\(evidence.popUpButtonCount) pop-up button(s), "
                + (evidence.publishesDefaultButton ? "a default button" : "no default button")
                + " and "
                + (evidence.publishesCancelButton ? "a cancel button" : "no cancel button")
        )
    }
}

extension LogicAccessibility {
    // MARK: - Remove Silence (G30 — Logic 12's "strip silence")

    /// COVERAGE calls this row "strip silence". Logic Pro 12.3.1 has no
    /// command by that name at all: the Key Commands window's own row is
    /// **`Remove Silence from Audio Region…`** (⌃X, in the "Windows Showing
    /// Audio Files" group), verified 2026-08-28. It opens a floating window
    /// titled `Remove Silence`.
    static let removeSilenceCommand = KeyCommandRegistry.Name.removeSilenceFromAudioRegion

    /// How long to wait for the modal after the key command. The window was
    /// found on the FIRST look 5/5 warm (1 ms) and cost 90–175 ms cold
    /// (measured 2026-09-02), so this is a deadline, not a charge — but it is
    /// kept at the 6 s this tool has always budgeted rather than shortened to
    /// the 2 s house default, because nothing has measured how long Logic
    /// takes to raise it over a long region.
    static let removeSilenceWindowDeadline: TimeInterval = 6

    /// The Remove Silence floating window, found by APPEARANCE.
    ///
    /// IT USED TO BE FOUND BY ITS ENGLISH TITLE, and the comment here said that
    /// was safe. It was not. Measured 2026-09-02: the window is
    /// `AXModal = 1`. So on a Logic whose UI language is not English the
    /// sequence was — command fires, modal opens, title never matches, 6 s of
    /// polling, `windowNotFound` thrown, the teardown searches for the same
    /// title and finds nothing, presses nothing — and the MODAL IS STILL UP,
    /// swallowing Logic's keyboard and every later tool call with it until a
    /// human clicks it.
    ///
    /// `pollNewWindow(before:)` reads no words: snapshot the window list before
    /// the command, take the window that was not there afterwards. The title is
    /// then corroboration (`identified_by: "title"`) rather than the gate, the
    /// shape is the fallback (`"appeared"`), and a window that is NEITHER is
    /// cancelled and refused rather than left standing.
    func removeSilenceWindow(before: Set<WindowKey>) throws -> AXUIElement? {
        try pollNewWindow(before: before, deadline: Self.removeSilenceWindowDeadline)
    }

    /// The window's whole state as data: Logic's live region-count preview, the
    /// zero-crossing flag, and the four numeric fields with the LABEL Logic
    /// printed beside each one. The numbers are per-digit steppers (`AXSlider`
    /// `Segment N`, `AXIncrement`/`AXDecrement`), the same species as the bounce
    /// dialog's position fields, and this server does not write them — see the
    /// tool description.
    func readRemoveSilenceWindow(_ window: AXUIElement) -> RemoveSilence.Reading {
        RemoveSilence.read(
            children(of: window).map { child in
                RemoveSilence.Child(
                    role: stringAttribute(child, kAXRoleAttribute as String),
                    value: stringAttribute(child, kAXValueAttribute as String),
                    title: stringAttribute(child, kAXTitleAttribute as String)
                )
            }
        )
    }

    /// Presses Cancel and PROVES the modal went away.
    ///
    /// The window element is passed in, not searched for again: the teardown
    /// used to re-run the whole window-list walk for a window it was already
    /// holding (3 ms warm, 240 ms on the one cold sample where the walk
    /// missed — and a miss meant the modal stayed up).
    ///
    /// The 0.3 s `Thread.sleep` that used to follow the press was 56% of the
    /// whole default-mode call. It is a look-first poll now, on the house
    /// pattern: an AX press's effect has been readable on the first look in
    /// every measured sample of this server.
    @discardableResult
    func cancelRemoveSilenceWindow(_ window: AXUIElement) -> [String: Any] {
        let title = stringAttribute(window, kAXTitleAttribute as String)
        guard let cancel = abortButton(of: window, maximumDepth: 1) else {
            return [
                "pressed": false, "window_gone": false,
                "problem": "the window publishes no AXCancelButton and no button titled "
                    + "'\(LogicUIStrings.Button.cancel)', so this modal could not be dismissed - "
                    + "it is STILL OPEN and will swallow Logic's keyboard until it is closed by "
                    + "hand"
            ]
        }
        let pressed = AXUIElementPerformAction(cancel, kAXPressAction as CFString) == .success
        let key = WindowKey(element: window)
        // Identity is the precise question; the title is only added when the
        // window published one, because "no remaining window has an empty
        // title" is not a statement about this window at all.
        func vanished() -> Bool {
            let current = ((try? logicWindows()) ?? []).map {
                (key: WindowKey(element: $0), title: stringAttribute($0, kAXTitleAttribute as String))
            }
            return title.isEmpty
                ? !current.contains { $0.key == key }
                : pressedWindowIsGone(target: key, title: title, current: current)
        }
        // Look FIRST, then every 100 ms — not the 25 ms the window-close polls
        // use. MEASURED 2026-09-02: at 25 ms this teardown took 64 ms on some
        // calls and 561–568 ms on others, and the slow ones are the poll's own
        // doing — re-enumerating Logic's window list twenty times a second
        // while Logic tears a modal down contends with the teardown. The old
        // shape here was a flat 0.3 s `Thread.sleep` that verified NOTHING; a
        // proof that the modal is gone is worth more than the sleep it
        // replaces, and it must not be a proof that slows down what it watches.
        let deadline = Date().addingTimeInterval(2)
        var gone = vanished()
        while !gone && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            gone = vanished()
        }
        return ["pressed": pressed, "window_gone": gone]
    }

    /// Runs Logic's Remove Silence on ONE audio region.
    ///
    /// `apply: false` (the default) is the interesting mode: the window
    /// publishes a LIVE preview of how many regions the current settings would
    /// produce, so an agent can ask "what would this do?" and get a number
    /// without touching the arrangement. `apply: true` presses OK and verifies
    /// against the arrangement map.
    ///
    /// TWO MODES, TWO CONTRACTS, and the difference is deliberate.
    ///
    /// The apply path fires a command that acts on Logic's PROJECT-WIDE
    /// selection, so it takes the guard the other five region commands share:
    /// Logic's own `Deselect All`, proven by the rendered selection falling to
    /// zero, then the target selected back, and an after-check against the
    /// region total across every rendered row rather than the target track's.
    /// Without it — and it shipped without it — a Remove Silence that also
    /// stripped a selected region on one of this sandbox's ten unrendered rows
    /// passed every check and came back `success: true, verified: true`.
    ///
    /// The preview path presses CANCEL. Nothing is written, so there is nothing
    /// for a project-wide clear to protect, and it is not paid: the preview
    /// says `selection_scope: "rendered_rows"` and names the one thing that
    /// scope costs it (Logic's count is of the whole selection, so a region
    /// selected on an unrendered row is in the number).
    ///
    /// ONE arrangement walk serves the whole pre-write half of both modes. It
    /// resolves the region, feeds the type refusal, hands the guard its row
    /// numbers, carries the project's region total (a sum over rows already in
    /// hand, no extra Accessibility read) and is passed to the selection pass
    /// instead of being walked again — the tool used to take TWO walks on a
    /// preview and three on an apply, for a snapshot the preview never read.
    /// It is deliberately NOT `arrangementCensus`: that one also reads
    /// `AXSelected` off all 54 regions, and the only selection count worth
    /// having here is the one taken AFTER the strip.
    ///
    /// The walk is handed on to the selection pass (`alreadyWalkedRows`), which
    /// is sound here because nothing has been written between the two — the
    /// type refusal above is a read. MEASURED 2026-09-02: it takes the
    /// selection phase from 70 ms to 8 ms, one of the two walks this rewrite
    /// removed from the preview.
    ///
    /// - Parameter trackNumber: addresses the ROW by number instead of
    ///   trusting the name to be unique (see `resolveRegionRow`).
    func removeSilence(
        trackName: String, regionName: String?, startBar: Int?, apply: Bool,
        trackNumber: Int? = nil
    ) throws -> [String: Any] {
        let rows = try regionRows()
        if rows.isEmpty {
            // Whether an arrangement with no rendered rows is EMPTY or merely
            // unreadable is `listRegions`' verdict, and it refuses on both.
            _ = try listRegions(trackName: trackName)
        }
        let targetRow = try resolveRegionRow(rows, trackName: trackName, trackNumber: trackNumber)
        let rowNumbers = rows.map(\.number)
        let totalRegionsBefore = rows.reduce(0) { $0 + $1.regions.count }
        let before = LogicAccessibility.typedRowRegions(targetRow.regions.map(parseRegion))
        let candidates = before.filter { entry in
            if let regionName,
               !RegionNameAnnotation.matches(
                   name: (entry["name"] as? String) ?? "", request: regionName
               ) {
                return false
            }
            if let startBar, entry["start_bar"] as? Int != startBar { return false }
            return true
        }
        guard let target = candidates.first else {
            throw LogicianError.trackNotExposed(
                requested: RegionAddressing.request(regionName: regionName, startBar: startBar)
                    + " on '\(trackName)'",
                exposed: "that row holds: "
                    + (before.isEmpty
                        ? "no regions"
                        : RegionAddressing.candidates(before).joined(separator: ", "))
                    + ". Nothing was opened and nothing was selected. A region's start_bar changes"
                    + " with every edit, so re-read logic_list_regions rather than reusing an"
                    + " earlier one"
            )
        }
        guard candidates.count == 1 else {
            throw LogicianError.regionAmbiguous(
                track: trackName,
                requested: RegionAddressing.request(regionName: regionName, startBar: startBar),
                candidates: RegionAddressing.candidates(candidates)
            )
        }
        // An audio-only function: on a MIDI region the command does nothing and
        // the window never appears, which would look like a bug.
        //
        // REFUSED BEFORE THE FIRST WRITE, which is new and is the whole of D6.
        // The check used to run AFTER `selectRegion(exclusive: true)` and the
        // message still said "No write was attempted" — while that call had
        // already deselected whatever was selected and selected the MIDI region
        // instead. Resolving the region off the census costs nothing extra and
        // makes the sentence true again.
        if let type = target["type"] as? String, type != "audio" {
            throw LogicianError.currentValueMismatch(
                expected: "an AUDIO region",
                actual: "'\(target["name"] ?? "?")' is a \(type) region"
                    + (target["type_from"] as? String == "track_row"
                        ? " (inferred from the other regions on that row)" : "")
                    + ". Remove Silence only works on audio. Nothing was opened, and nothing was "
                    + "selected either - the SELECTION is exactly as this call found it."
            )
        }
        let targetName = target["name"] as? String
        let targetStartBar = target["start_bar"] as? Int
        var coverage: RegionEditGuard.Coverage?
        var exclusive: LogicAccessibility.ExclusiveRegionSelection?
        let selection: [String: Any]
        if apply {
            let (readCoverage, plan) = try regionEditPlan(
                .removeSilence, regionRowNumbers: rowNumbers
            )
            coverage = readCoverage
            let established = try establishExclusiveRegionSelection(
                .removeSilence, plan: plan,
                trackName: trackName, regionName: targetName, startBar: targetStartBar,
                trackNumber: trackNumber, alreadyWalkedRows: rows
            )
            exclusive = established
            selection = established.region
        } else {
            selection = try selectRegion(
                trackName: trackName, regionName: targetName, startBar: targetStartBar,
                exclusive: true, trackNumber: trackNumber, alreadyWalkedRows: rows
            )
        }

        // The modal this call is about to raise must never outlive it, and
        // whatever it is must be dismissed with the element in hand rather than
        // with a second search.
        var openWindow: AXUIElement?
        defer { if let openWindow { cancelRemoveSilenceWindow(openWindow) } }

        let windowsBefore = Set(try logicWindows().map(WindowKey.init))
        try fireKeyCommand(
            LogicAccessibility.removeSilenceCommand,
            learnIfMissing: true, source: "logic_remove_silence"
        )
        guard let window = try removeSilenceWindow(before: windowsBefore) else {
            throw LogicianError.windowNotFound(
                "the Remove Silence window - no window at all appeared in "
                    + "\(Int(LogicAccessibility.removeSilenceWindowDeadline)) s (the command "
                    + "fired; a region Logic considers empty opens nothing). Nothing is left "
                    + "standing, and the selection now holds '\(targetName ?? "?")'"
            )
        }
        openWindow = window
        let reading = readRemoveSilenceWindow(window)
        let shape = dialogShape(of: window, maximumDepth: 1)
        let identification = RemoveSilence.identify(
            RemoveSilence.WindowEvidence(
                title: stringAttribute(window, kAXTitleAttribute as String),
                numericFieldCount: reading.fields.count,
                checkBoxCount: shape.checkBoxCount,
                radioButtonCount: shape.radioButtonCount,
                popUpButtonCount: shape.popUpButtonCount,
                publishesDefaultButton: shape.publishesDefaultButton,
                publishesCancelButton: shape.publishesCancelButton
            )
        )
        if case .unrecognised(let reason) = identification {
            let receipt = cancelRemoveSilenceWindow(window)
            openWindow = nil
            throw LogicianError.verificationFailed(
                requested: "Logic's Remove Silence window",
                actual: reason + ". Cancel was "
                    + ((receipt["pressed"] as? Bool) == true ? "pressed" : "NOT pressed")
                    + " and the window "
                    + ((receipt["window_gone"] as? Bool) == true
                        ? "is gone"
                        : "IS STILL OPEN - it is modal, so it will swallow every later tool call "
                            + "until it is closed by hand")
                    + ". OK was not pressed, so nothing was stripped; the selection holds "
                    + "'\(targetName ?? "?")'",
                restored: false
            )
        }
        var state = reading.payload
        state["identified_by"] = identification.word
        let expected = reading.previewRegions
        guard apply else {
            // Cancelled HERE rather than in the teardown, so the result can
            // carry the receipt: a preview that says "NOTHING WAS CHANGED"
            // while leaving a modal standing would be the worst kind of true.
            let receipt = cancelRemoveSilenceWindow(window)
            openWindow = nil
            var result: [String: Any] = [
                "success": true, "verified": true, "state": "previewed",
                "applied": false,
                "track_name": trackName,
                "region": selection["name"] ?? NSNull(),
                "selection_scope": "rendered_rows",
                "settings": state,
                "note": "NOTHING WAS CHANGED. `settings.preview_regions` is Logic's own live count "
                    + "of how many regions the CURRENT threshold and time settings would leave, "
                    + "and `settings.fields` reports each numeric field with the LABEL Logic "
                    + "printed beside it (in Logic's own order: minimum silence, post release, "
                    + "pre attack, threshold - read the labels, not the order). Those four are "
                    + "per-digit steppers this server does not write; change them in Logic's "
                    + "window if the preview is wrong. Call again with apply: true to commit - "
                    + "that path clears the project-wide selection first and verifies against the "
                    + "whole arrangement, which this one does not: Logic's count is of the "
                    + "SELECTION, so a region still selected on a row this walk cannot see is in "
                    + "the number."
            ]
            result["window_closed"] = receipt
            if (receipt["window_gone"] as? Bool) != true {
                result["verified"] = false
                appendWarning(
                    "Cancel was pressed and the Remove Silence window was still in Logic's window "
                        + "list when this call gave up looking. It is MODAL: while it stands, every "
                        + "later tool call will report that its command fired and nothing happened. "
                        + "Close it by hand before calling anything else.",
                    to: &result
                )
            }
            return result
        }
        guard let exclusive else {
            throw LogicianError.verificationFailed(
                requested: "an established exclusive selection before Remove Silence",
                actual: "the apply path reached the OK press without one", restored: false
            )
        }
        // A preview of ONE region is Logic saying the settings find nothing
        // silent enough to strip. Pressing OK there writes nothing, so it is
        // not pressed: a verified no-op, reported as one, with the modal
        // cancelled by the teardown below.
        let commit = RemoveSilence.commit(previewRegions: expected)
        if commit == .nothingToStrip {
            var result: [String: Any] = [
                "success": true, "verified": true, "state": "already_one_region",
                "applied": false,
                "track_name": trackName,
                "region": selection["name"] ?? NSNull(),
                "regions_before": before.count,
                "project_regions_before": totalRegionsBefore,
                "preview_regions": expected ?? NSNull(),
                "settings": state,
                "note": "OK was NOT pressed and nothing was changed: Logic's own preview says the "
                    + "current settings leave the region whole (1 region), so the command would "
                    + "have written nothing. Lower the threshold or shorten the minimum silence "
                    + "time in Logic's window and preview again. "
                    + LogicAccessibility.exclusivityNote(
                        scope: exclusive.scope, command: .removeSilence
                    )
            ]
            exclusive.decorate(&result)
            if let coverage { annotateCoverage(coverage, in: &result) }
            return result
        }
        guard let ok = confirmButton(of: window, maximumDepth: 1) else {
            throw LogicianError.windowNotFound("the OK button in the Remove Silence window")
        }
        _ = AXUIElementPerformAction(ok, kAXPressAction as CFString)
        openWindow = nil

        // LOOK BEFORE SLEEPING. The 0.4 s that used to run in FRONT of this
        // walk was 53% of the whole apply. MEASURED 2026-09-02: a walk taken
        // immediately after the OK press already saw all eight new regions
        // (1/1) — Logic's arrangement update is synchronous with the command at
        // AX-read granularity, the same result Delete (3/3), Paste (5/5) and
        // Nudge (8/8) gave. That first walk does cost more while Logic repaints
        // the new regions (294 ms against 85 ms for one taken after the sleep),
        // so the saving is ~190 ms, not the full 400.
        //
        // And the count it compares is the PROJECT's rendered total, not the
        // target row's: a Remove Silence that also stripped a selected region
        // on another row leaves the target row showing exactly the number this
        // check used to ask for.
        var expectedDelta: Int?
        if case .press(let delta) = commit { expectedDelta = delta }
        var afterCensus = try arrangementCensus(
            trackName: trackName, trackNumber: trackNumber
        )
        var verdict = RegionEditGuard.DeltaVerdict.pending
        let deadline = Date().addingTimeInterval(12)
        var firstLook = true
        while true {
            if firstLook {
                firstLook = false
            } else {
                afterCensus = try arrangementCensus(
                    trackName: trackName, trackNumber: trackNumber
                )
            }
            if let expectedDelta {
                verdict = RegionEditGuard.delta(
                    expected: expectedDelta,
                    before: totalRegionsBefore, after: afterCensus.totalRegions
                )
            } else if afterCensus.totalRegions != totalRegionsBefore {
                verdict = .asExpected
            }
            if verdict != .pending || Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let after = afterCensus.targetRegions
        switch verdict {
        case .asExpected:
            break
        case .pending:
            throw LogicianError.verificationFailed(
                requested: expected.map { "\($0) regions where '\(targetName ?? "?")' was" }
                    ?? "the region total to move",
                actual: "OK was pressed and the region total across every rendered row is "
                    + "unchanged at \(afterCensus.totalRegions). Either the window did not accept "
                    + "the press, or the settings strip nothing. NOTHING WAS UNDONE - if the "
                    + "strip DID happen and only the map is stale, re-read logic_list_regions "
                    + "before firing Undo",
                restored: false
            )
        case .unexpected:
            throw LogicianError.verificationFailed(
                requested: "one region stripped into \(expected ?? 0)",
                actual: RegionEditGuard.unexpectedTotalSentence(
                    command: .removeSilence, expectedDelta: expectedDelta ?? 0,
                    before: totalRegionsBefore, after: afterCensus.totalRegions
                ),
                restored: false
            )
        }
        // N3: the regions Logic MADE, named. They come back SELECTED — all
        // eight of them, measured — and the result used to say neither, so the
        // caller had to diff two censuses to find out what it had just created
        // and the next selection-based command inherited a selection nobody
        // had reported.
        let beforeIdentities = Set(before.map(Self.regionIdentity))
        let produced = after.filter { !beforeIdentities.contains(Self.regionIdentity($0)) }
        let rowDelta = after.count - before.count + 1
        let projectDelta = afterCensus.totalRegions - totalRegionsBefore
        let note = "One region became \(rowDelta), and the region total across every rendered row "
            + "rose by exactly \(projectDelta) - not just the target track's. Undo restores the "
            + "single region. The gaps are gone from the ARRANGEMENT, not from the audio file - "
            + "the file is untouched. All \(produced.count) new region(s) are left SELECTED "
            + "(`produced_regions` names them): the next selection-based command - Delete, Nudge, "
            + "Split, another Remove Silence - would act on every one of them. "
            + "logic_select_regions {mode: \"none\"} clears them. "
            + LogicAccessibility.exclusivityNote(scope: exclusive.scope, command: .removeSilence)
        var result: [String: Any] = [
            "success": true, "verified": true, "state": "applied",
            "applied": true,
            "track_name": trackName,
            "region": selection["name"] ?? NSNull(),
            "regions_before": before.count,
            "regions_after": after.count,
            "regions_produced": rowDelta,
            "project_regions_before": totalRegionsBefore,
            "project_regions_after": afterCensus.totalRegions,
            "preview_regions": expected ?? NSNull(),
            "produced_regions": produced,
            "selected_after": afterCensus.selectedRegions,
            "settings": state,
            "note": note
        ]
        exclusive.decorate(&result)
        if let coverage { annotateCoverage(coverage, in: &result) }
        if let keyFocus = exclusive.anchor["key_focus"] { result["key_focus"] = keyFocus }
        return result
    }

    /// A region's identity for the before/after diff: name plus where it
    /// starts, because Remove Silence names its output after the region it cut
    /// up and several of them can share a bar.
    private static func regionIdentity(_ region: [String: Any]) -> String {
        [
            region["name"] as? String ?? "?",
            String(region["start_bar"] as? Int ?? -1),
            String(region["start_beat"] as? Int ?? 1)
        ].joined(separator: "|")
    }
}
