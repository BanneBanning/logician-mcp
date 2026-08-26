import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {
    // MARK: Instrument slot (assign_instrument, assignment code "IN")

    /// Enters the instrument edit mode for a track: bank to the track's
    /// channel in the pan view, switch to the instrument bank view, then
    /// vpot-press the channel. Never turns vpots in the bank view (that is
    /// the instrument browser). Returns nil when unavailable/no instrument.
    static func enterInstrumentEdit(trackName: String) throws -> (channel: Int, name: String)? {
        guard freshStatus() != nil else { return nil }
        guard let channel = try findChannel(trackName: trackName) else { return nil }
        try press("assign_instrument")
        guard let inView = waitFor(seconds: 2.0, { ($0["assignment"] as? String) == "IN" }),
              let instrumentBankTop = inView["lcd_top"] as? String else {
            exitToPan()
            return nil
        }
        // Empty instrument slot shows "--"; entering it would be pointless.
        var instrumentName = ""
        if let status = freshStatus(), let bottom = status["lcd_bottom"] as? String {
            instrumentName = lcdFields(bottom)[channel].trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if instrumentName.isEmpty || instrumentName == "--" {
                exitToPan()
                return nil
            }
        }
        let response = try MCUBridge.send(["cmd": "vpot_press", "index": channel])
        guard response["ok"] as? Bool == true else {
            exitToPan()
            return nil
        }
        if waitFor(seconds: 2.5, { status in
            guard (status["assignment"] as? String) == "IN",
                  let top = status["lcd_top"] as? String else { return false }
            return top != instrumentBankTop
        }) != nil {
            return (channel, instrumentName)
        }
        exitToPan()
        return nil
    }

    static func setInstrumentParameter(
        trackName: String,
        parameter: String,
        targetValue: String,
        expectedCurrentValue: String?,
        tolerance: Double?
    ) throws -> [String: Any]? {
        guard let entered = try enterInstrumentEdit(trackName: trackName) else { return nil }
        defer { exitToPan() }
        guard var result = try searchAndSetParameter(
            parameter: parameter,
            targetValue: targetValue,
            expectedCurrentValue: expectedCurrentValue,
            tolerance: tolerance,
            cacheKey: "instrument:" + entered.name
        ) else { return nil }
        result["slot_type"] = "instrument"
        return result
    }

    /// Shared core for plugin and instrument edit modes: search every
    /// parameter page for the match, navigate to its page, then converge.
    /// Page read for searching: cached names + instant value row when the
    /// cache matches this plugin, otherwise the fade-waiting settled read.
    static func pageForSearch(
        cacheKey: String?, pageNumber: Int, totalPages: Int
    ) -> [(name: String, value: String)]? {
        if let key = cacheKey {
            let cached = loadNameCache()[key]
            if let names = cached, names.count == max(totalPages, 1),
               pageNumber <= names.count, names[pageNumber - 1].count == 8 {
                _ = quiescentStatus()
                if let status = freshStatus(), let bottom = status["lcd_bottom"] as? String {
                    return zip(names[pageNumber - 1], lcdFields(bottom)).map { ($0, $1) }
                }
            }
        }
        return settledParameterPage()
    }

    static func searchAndSetParameter(
        parameter: String,
        targetValue: String,
        expectedCurrentValue: String?,
        tolerance: Double?,
        cacheKey: String? = nil
    ) throws -> [String: Any]? {
        // Search all parameter pages; remember where the match lives.
        let totalPages = try normalizeToPageOne()
        var found: (page: Int, index: Int, name: String, value: String)?
        var duplicates = 0
        var allNames: [String] = []
        for pageNumber in 1...max(totalPages, 1) {
            guard let raw = pageForSearch(
                cacheKey: cacheKey, pageNumber: pageNumber, totalPages: totalPages
            ) else { return nil }
            for (index, entry) in raw.enumerated() where !entry.name.isEmpty {
                allNames.append(entry.name)
                let hit = entry.name.localizedCaseInsensitiveCompare(parameter) == .orderedSame
                    || lcdNameMatches(track: parameter, lcd: entry.name)
                guard hit else { continue }
                if let existing = found {
                    // The end-aligned last page repeats the previous page's tail;
                    // an identical name+value there is the same parameter.
                    if pageNumber == totalPages
                        && existing.name == entry.name && existing.value == entry.value {
                        continue
                    }
                    duplicates += 1
                } else {
                    found = (pageNumber, index, entry.name, entry.value)
                }
            }
            if pageNumber < totalPages { try pageRight() }
        }
        guard duplicates == 0, let match = found else {
            throw DemoError.parameterAmbiguous(
                "\(parameter) (MCU parameters: \(allNames.joined(separator: ", ")))",
                found == nil ? 0 : duplicates + 1
            )
        }
        // Navigate back to the match's page (we are on the last page now).
        for _ in 0..<(max(totalPages, 1) - match.page) {
            try pressNote(0x62)
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let landed = pageForSearch(
                  cacheKey: cacheKey, pageNumber: match.page, totalPages: totalPages
              ),
              landed.indices.contains(match.index),
              landed[match.index].name == match.name else {
            throw DemoError.openVerificationFailed(
                "the parameter page shifted while navigating to '\(match.name)'"
            )
        }
        let index = match.index
        let entry = (name: match.name, value: landed[match.index].value)
        let originalText = entry.value
        if let expected = expectedCurrentValue {
            let matchesText = originalText.localizedCaseInsensitiveCompare(expected) == .orderedSame
            let matchesNumber = parseNumber(originalText) != nil && parseNumber(expected) != nil
                && abs(parseNumber(originalText)! - parseNumber(expected)!) < 0.0001
            guard matchesText || matchesNumber else {
                throw DemoError.currentValueMismatch(expected: expected, actual: originalText)
            }
        }

        func currentText() -> String? {
            parameterPage().map { $0[index].value }
        }
        func turn(_ ticks: Int) throws {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            let response = try MCUBridge.send(["cmd": "vpot", "index": index, "delta": ticks])
            guard response["ok"] as? Bool == true else {
                throw DemoError.writeFailed("MCU vpot failed: \(response["error"] ?? "?")")
            }
            _ = awaitEvents(since: before, timeoutMs: 350)
        }

        let finalText: String
        if let targetNumber = parseNumber(targetValue), parseNumber(originalText) != nil,
           let fast = fastConverge(index: index, target: targetNumber,
                                   tolerance: tolerance ?? 0, maxMs: 4000) {
            finalText = fast.text
        } else if let targetNumber = parseNumber(targetValue), parseNumber(originalText) != nil {
            finalText = try convergeNumeric(
                target: targetNumber,
                tolerance: tolerance,
                read: { currentText().flatMap(parseNumber) },
                readText: { currentText() },
                turn: turn
            )
        } else {
            finalText = try stepToText(
                target: targetValue,
                original: originalText,
                read: { currentText() },
                turn: turn
            )
        }

        return [
            "success": true,
            "verified": true,
            "state": "confirmed",
            "parameter_field": entry.name,
            "before": originalText,
            "requested": targetValue,
            "after": finalText,
            "route": "mcu",
            "write_route": "mcu_vpot_converge",
            "readback_route": "mcu_lcd_echo"
        ]
    }

    static func convergeNumeric(
        target: Double,
        tolerance: Double?,
        read: () -> Double?,
        readText: () -> String?,
        turn: (Int) throws -> Void
    ) throws -> String {
        guard var current = read() else {
            throw DemoError.openVerificationFailed("the parameter value is not readable on the LCD")
        }
        let original = current
        // Probe with a single tick to learn the parameter's step size.
        var ticksPerUnit = 10.0
        var probed = false
        var effectiveTolerance = tolerance ?? 0.05
        var stuck = 0
        for _ in 0..<36 {
            let difference = target - current
            if abs(difference) <= effectiveTolerance { break }
            let ticks: Int
            if probed {
                ticks = max(1, min(50, Int((abs(difference) * ticksPerUnit).rounded())))
            } else {
                ticks = 1
            }
            try turn(difference > 0 ? ticks : -ticks)
            guard let updated = read() else { break }
            let moved = abs(updated - current)
            if moved < 1e-9 {
                stuck += 1
                if stuck >= 3 {
                    _ = try? convergeBack(to: original, ticksPerUnit: ticksPerUnit, read: read, turn: turn)
                    throw DemoError.verificationFailed(
                        requested: "\(target)",
                        actual: "parameter stuck at \(updated)",
                        restored: true
                    )
                }
            } else {
                stuck = 0
                ticksPerUnit = min(400, max(0.2, Double(ticks) / moved))
                if !probed {
                    probed = true
                    if tolerance == nil {
                        effectiveTolerance = max(moved * 0.55, 0.0001)
                    }
                }
            }
            current = updated
        }
        guard abs(current - target) <= effectiveTolerance * 2 else {
            _ = try? convergeBack(to: original, ticksPerUnit: ticksPerUnit, read: read, turn: turn)
            throw DemoError.verificationFailed(
                requested: "\(target)",
                actual: "\(current)",
                restored: true
            )
        }
        return readText() ?? "\(current)"
    }

    static func convergeBack(
        to original: Double,
        ticksPerUnit: Double,
        read: () -> Double?,
        turn: (Int) throws -> Void
    ) throws {
        for _ in 0..<24 {
            guard let current = read() else { return }
            let difference = original - current
            if abs(difference) < 0.0001 { return }
            let ticks = max(1, min(50, Int((abs(difference) * ticksPerUnit).rounded())))
            try turn(difference > 0 ? ticks : -ticks)
        }
    }

    static func stepToText(
        target: String,
        original: String,
        read: () -> String?,
        turn: (Int) throws -> Void
    ) throws -> String {
        func matches(_ text: String?) -> Bool {
            text?.localizedCaseInsensitiveCompare(target) == .orderedSame
        }
        if matches(original) { return original }
        var net = 0
        // Search upward, then downward past the start. Enum boundaries can be
        // wider than one vpot tick, so escalate the step size when the display
        // does not move, and treat sustained silence at max step as the end stop.
        for direction in [1, -1] {
            var previous = read()
            var unchanged = 0
            var step = 1
            let limit = direction == 1 ? 24 : 48
            for _ in 0..<limit {
                try turn(direction * step)
                net += direction * step
                let text = read()
                if matches(text) { return text ?? target }
                if text == previous {
                    unchanged += 1
                    if unchanged >= 3 && step >= 8 { break } // end stop
                    step = min(step * 2, 8)
                } else {
                    unchanged = 0
                    step = 1
                    previous = text
                }
            }
        }
        // No match: undo the net movement.
        if net != 0 { try turn(-net) }
        throw DemoError.verificationFailed(
            requested: target,
            actual: read() ?? "unknown",
            restored: true
        )
    }
}
