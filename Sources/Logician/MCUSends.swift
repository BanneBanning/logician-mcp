import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {
    // MARK: Sends (assign_send channel view, assignment code "SE")

    /// The selected track's sends laid out as 4 fields per send, 2 sends per
    /// page: SenNIn (destination), Send N (level), SenNPo (position),
    /// SenNMu (status). NOTE: the multi-channel send view (code "S1") puts
    /// DESTINATION on the vpots — never turn vpots there.
    static func ensureSendView() throws -> Bool {
        for _ in 0..<4 {
            guard let status = freshStatus(),
                  let assignment = status["assignment"] as? String else { return false }
            if assignment == "SE" { return true }
            let before = status["received_events"] as? Int ?? -1
            try press("assign_send")
            _ = awaitEvents(since: before, timeoutMs: 400)
            _ = quiescentStatus()
        }
        return (freshStatus()?["assignment"] as? String) == "SE"
    }

    static func sendViewLeftmost() throws {
        for _ in 0..<4 {
            try pressNote(0x62)
            Thread.sleep(forTimeInterval: 0.15)
        }
        _ = quiescentStatus()
    }

    /// Creates a send by browsing the destination field of the first empty
    /// send slot (1 entry per tick in THIS browser, unlike the plugin
    /// browser's 1-per-2), settle-verifying the shown name, and confirming.
    static func addSend(
        logic: LogicAccessibility, trackName: String, destination: String
    ) throws -> [String: Any]? {
        guard freshStatus() != nil else { return nil }
        guard let channel = try findChannel(trackName: trackName) else { return nil }
        guard try selectFoundChannel(channel) else { return nil }
        guard try ensureSendView() else { return nil }
        defer { exitToPan() }
        try sendViewLeftmost()
        // find first empty slot across the pages
        var slotNumber: Int?
        for page in 0..<4 {
            guard let status = freshStatus(),
                  let top = status["lcd_top"] as? String,
                  let bottom = status["lcd_bottom"] as? String else { break }
            for half in 0..<2 {
                let base = half * 4
                if lcdFields(top)[base].hasPrefix("Sen"),
                   ["", "--"].contains(lcdFields(bottom)[base]) {
                    slotNumber = page * 2 + half + 1
                    break
                }
            }
            if slotNumber != nil { break }
            try pressNote(0x63)
            Thread.sleep(forTimeInterval: 0.2)
            _ = quiescentStatus()
        }
        guard let slot = slotNumber else {
            throw LogicianError.trackNotExposed(
                requested: "an empty send slot", exposed: "all 8 send slots are occupied"
            )
        }
        let destIndex = ((slot - 1) % 2) * 4
        func shownDestination() -> String {
            guard let status = freshStatus(),
                  let bottom = status["lcd_bottom"] as? String else { return "" }
            let start = bottom.index(bottom.startIndex, offsetBy: min(destIndex * 7, bottom.count))
            let raw = String(bottom[start...])
            return (raw.range(of: "    ").map { String(raw[..<$0.lowerBound]) } ?? raw)
                .trimmingCharacters(in: .whitespaces)
        }
        var entries: [String] = []
        var found = false
        for _ in 0..<80 {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            let response = try MCUBridge.send(.vpot(index: destIndex, delta: 1))
            guard response.ok else { return nil }
            _ = awaitEvents(since: before, timeoutMs: 300)
            _ = quiescentStatus()
            let name = shownDestination()
            guard !name.isEmpty, name != "--" else { continue }
            if name.caseInsensitiveCompare(destination) == .orderedSame { found = true; break }
            if name == entries.last { continue }
            if let firstEntry = entries.first, name == firstEntry, entries.count > 2 {
                exitToPan()
                throw LogicianError.trackNotExposed(
                    requested: "destination '\(destination)'",
                    exposed: "the browser wrapped; entries: " + entries.joined(separator: ", ")
                )
            }
            entries.append(name)
        }
        guard found else {
            throw LogicianError.openVerificationFailed(
                "the destination browser never showed '\(destination)'"
            )
        }
        Thread.sleep(forTimeInterval: 0.3)
        _ = quiescentStatus()
        guard shownDestination().caseInsensitiveCompare(destination) == .orderedSame else {
            throw LogicianError.verificationFailed(
                requested: "'\(destination)' shown at confirmation time",
                actual: "the entry drifted to '\(shownDestination())'; aborted",
                restored: true
            )
        }
        let confirm = try MCUBridge.send(.vpotPress(index: destIndex))
        guard confirm.ok else { return nil }
        Thread.sleep(forTimeInterval: 1.0)
        guard let sends = try readSends(),
              sends.contains(where: {
                  ($0["send"] as? Int) == slot
                      && (($0["destination"] as? String) ?? "").caseInsensitiveCompare(destination) == .orderedSame
              }) else {
            throw LogicianError.verificationFailed(
                requested: "send \(slot) -> \(destination)",
                actual: "the send list does not show it after confirmation",
                restored: false
            )
        }
        return [
            "success": true, "verified": true, "state": "added",
            "send": slot, "destination": destination,
            "level": "-oo dB (new sends start silent; set with logic_mcu_set_send)",
            "write_route": "mcu_send_destination_browser"
        ]
    }

    /// Pages the send channel view to the page holding the given send slot.
    static func sendViewToPage(forSend send: Int) throws {
        try sendViewLeftmost()
        for _ in 0..<((send - 1) / 2) {
            try pressNote(0x63)
            Thread.sleep(forTimeInterval: 0.2)
            _ = quiescentStatus()
        }
    }

    /// Walks the plugin-edit parameter pages until the named parameter is on
    /// screen; returns its vpot index and LEAVES the view on that page.
    static func locateParameter(named name: String) throws -> Int? {
        let total = try normalizeToPageOne()
        for page in 1...max(total, 1) {
            if let entries = settledParameterPage() {
                for (index, entry) in entries.enumerated() where !entry.name.isEmpty {
                    if entry.name.localizedCaseInsensitiveCompare(name) == .orderedSame
                        || lcdNameMatches(track: name, lcd: entry.name) {
                        return index
                    }
                }
            }
            if page < max(total, 1) { try pageRight() }
        }
        return nil
    }

    /// Reads all sends of the selected track. Returns nil when the MCU route
    /// is unavailable; an empty array when the track simply has no sends.
    static func readSends() throws -> [[String: Any]]? {
        guard try ensureSendView() else { return nil }
        defer { exitToPan() }
        try sendViewLeftmost()
        var sends: [[String: Any]] = []
        for page in 0..<4 {
            guard let fields = parameterPage() else { break }
            var pageHadSend = false
            for half in 0..<2 {
                let base = half * 4
                let number = page * 2 + half + 1
                guard fields[base].name.hasPrefix("Sen") else { continue }
                let destination = fields[base].value
                guard !destination.isEmpty, destination != "--" else { continue }
                pageHadSend = true
                sends.append([
                    "send": number,
                    "destination": destination,
                    "level": fields[base + 1].value,
                    "position": fields[base + 2].value,
                    "status": fields[base + 3].value
                ])
            }
            if !pageHadSend { break }
            try pressNote(0x63)
            Thread.sleep(forTimeInterval: 0.2)
            _ = quiescentStatus()
        }
        return sends
    }

    /// Sets one send's level in dB by converging its vpot against the LCD
    /// echo, with the same compare-and-set/readback discipline as the plugin
    /// parameters. Touches ONLY the level vpot, never the destination.
    static func setSendLevel(
        sendNumber: Int, targetDb: Double, expectedCurrentValue: String?
    ) throws -> [String: Any]? {
        guard (1...8).contains(sendNumber) else {
            throw LogicianError.invalidArguments("send must be 1-8")
        }
        guard try ensureSendView() else { return nil }
        defer { exitToPan() }
        try sendViewLeftmost()
        let page = (sendNumber - 1) / 2
        for _ in 0..<page {
            try pressNote(0x63)
            Thread.sleep(forTimeInterval: 0.2)
            _ = quiescentStatus()
        }
        guard let fields = parameterPage() else { return nil }
        let base = ((sendNumber - 1) % 2) * 4
        let levelIndex = base + 1
        let destination = fields[base].value
        guard fields[base].name.hasPrefix("Sen"), !destination.isEmpty, destination != "--" else {
            throw LogicianError.trackNotExposed(
                requested: "send \(sendNumber)",
                exposed: "the selected track has no send in slot \(sendNumber)"
            )
        }
        guard fields[levelIndex].name == "Send \(sendNumber)" else {
            return nil // unexpected layout: refuse rather than turn a stranger's vpot
        }
        let originalText = fields[levelIndex].value
        if let expected = expectedCurrentValue {
            let matchesText = originalText.localizedCaseInsensitiveCompare(expected) == .orderedSame
            let matchesNumber = parseNumber(originalText) != nil && parseNumber(expected) != nil
                && abs(parseNumber(originalText)! - parseNumber(expected)!) < 0.0001
            guard matchesText || matchesNumber else {
                throw LogicianError.currentValueMismatch(expected: expected, actual: originalText)
            }
        }
        func currentText() -> String? {
            parameterPage().map { $0[levelIndex].value }
        }
        func turn(_ ticks: Int) throws {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            let response = try MCUBridge.send(.vpot(index: levelIndex, delta: ticks))
            guard response.ok else {
                throw LogicianError.writeFailed("MCU vpot failed: \(response.error ?? "?")")
            }
            _ = awaitEvents(since: before, timeoutMs: 350)
        }
        let finalText: String
        if let fast = fastConverge(index: levelIndex, target: targetDb, maxMs: 4000) {
            finalText = fast.text
        } else {
            finalText = try convergeNumeric(
                target: targetDb,
                tolerance: nil,
                read: { currentText().flatMap(parseNumber) },
                readText: { currentText() },
                turn: turn
            )
        }
        return [
            "success": true,
            "verified": true,
            "state": "confirmed",
            "send": sendNumber,
            "destination": destination,
            "before": originalText,
            "after": finalText,
            "route": "mcu",
            "write_route": "mcu_vpot_converge",
            "readback_route": "mcu_lcd_echo"
        ]
    }

}
