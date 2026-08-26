import AppKit
import ApplicationServices
import Foundation
import LogicMCUBridge

extension MCUController {
    // MARK: Transport

    static func setPlaying(_ playing: Bool) throws -> [String: Any]? {
        guard let status = freshStatus() else { return nil }
        let playLED = 0x5E
        if ledLit(playLED, in: status) == playing {
            return [
                "success": true, "verified": true,
                "state": playing ? "already_playing" : "already_stopped",
                "playing": playing, "route": "mcu"
            ]
        }
        try press(playing ? "play" : "stop")
        guard pollStatus(until: { ledLit(playLED, in: $0) == playing }) != nil else {
            throw DemoError.verificationFailed(
                requested: "playing=\(playing)",
                actual: "MCU play LED did not change",
                restored: false
            )
        }
        return [
            "success": true, "verified": true,
            "state": playing ? "playing" : "stopped",
            "playing": playing,
            "route": "mcu",
            "readback_route": "mcu_transport_led"
        ]
    }

    static func setCycle(_ enabled: Bool) throws -> [String: Any]? {
        guard let status = freshStatus() else { return nil }
        let cycleLED = 0x56
        if ledLit(cycleLED, in: status) == enabled {
            return [
                "success": true, "verified": true,
                "state": "already_" + (enabled ? "cycle_on" : "cycle_off"),
                "cycle": enabled, "route": "mcu"
            ]
        }
        try press("cycle")
        guard pollStatus(until: { ledLit(cycleLED, in: $0) == enabled }) != nil else {
            throw DemoError.verificationFailed(
                requested: "cycle=\(enabled)",
                actual: "MCU cycle LED did not change",
                restored: false
            )
        }
        return [
            "success": true, "verified": true,
            "state": enabled ? "cycle_on" : "cycle_off",
            "cycle": enabled, "route": "mcu",
            "readback_route": "mcu_cycle_led"
        ]
    }

    // MARK: LCD helpers

    static func lcdFields(_ row: String) -> [String] {
        var fields: [String] = []
        let characters = Array(row.padding(toLength: 56, withPad: " ", startingAt: 0))
        for channel in 0..<8 {
            let slice = characters[(channel * 7)..<(channel * 7 + 7)]
            fields.append(String(slice).trimmingCharacters(in: .whitespaces))
        }
        return fields
    }

    /// Logic abbreviates track names on the MCU LCD by dropping characters
    /// ("Lofi Pad" -> "LofPad"); an ordered subsequence match recovers them.
    static func lcdNameMatches(track: String, lcd: String) -> Bool {
        guard !lcd.isEmpty else { return false }
        let target = track.replacingOccurrences(of: " ", with: "").lowercased()
        let shown = lcd.replacingOccurrences(of: " ", with: "").lowercased()
        guard let first = shown.first, target.first == first else { return false }
        var iterator = target.makeIterator()
        var pending = shown[...]
        while let character = pending.first {
            var found = false
            while let candidate = iterator.next() {
                if candidate == character { found = true; break }
            }
            if !found { return false }
            pending = pending.dropFirst()
        }
        return true
    }

    /// The assign_pan button TOGGLES between the multi-channel pan view (track
    /// names on top) and a single-channel view ("Pan    -      -   ..."), and
    /// the assignment display reads "PN" in both — so the mode must be verified
    /// by LCD content, never by blind presses.
    static func ensurePanNames() throws -> Bool {
        for _ in 0..<5 {
            guard let status = freshStatus(), let top = status["lcd_top"] as? String else { return false }
            let assignment = status["assignment"] as? String
            let fields = lcdFields(top)
            let dashes = fields.filter { $0 == "-" }.count
            if assignment == "PN" && dashes < 4 { return true }
            try press("assign_pan")
            if waitFor(seconds: 1.2, { status in
                guard let top = status["lcd_top"] as? String else { return false }
                return (status["assignment"] as? String) == "PN"
                    && lcdFields(top).filter({ $0 == "-" }).count < 4
            }) != nil { return true }
        }
        return false
    }

    static func ensureAssignment(_ code: String, button: String) throws -> [String: Any]? {
        for _ in 0..<3 {
            guard let status = freshStatus() else { return nil }
            if (status["assignment"] as? String) == code { return status }
            try press(button)
            if let reached = waitFor(seconds: 1.2, { ($0["assignment"] as? String) == code }) {
                return reached
            }
        }
        return freshStatus().flatMap { ($0["assignment"] as? String) == code ? $0 : nil }
    }

    static func debugLog(_ message: String) {
        FileHandle.standardError.write(Data("[mcu] \(message)\n".utf8))
    }

    /// Banks to the leftmost position, scans right for a channel whose LCD
    /// name matches, and leaves the surface banked at the match. Returns nil
    /// (nothing written that matters) when not found or ambiguous.
    static var bankCacheURL: URL {
        MCUBridge.directory.appendingPathComponent("bank-cache.json")
    }

    static func loadBankCache() -> [String]? {
        guard let data = try? Data(contentsOf: bankCacheURL),
              let tops = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return tops
    }

    static func resetToLeftmostBank() throws {
        for _ in 0..<8 {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            try press("bank_left")
            _ = awaitEvents(since: before, timeoutMs: 150)
        }
    }

    /// Navigates to a bank by index (from leftmost) and verifies the expected
    /// LCD content. Returns false on mismatch (stale cache).
    static func navigateToBank(_ index: Int, expecting expectedTop: String) throws -> Bool {
        try resetToLeftmostBank()
        for _ in 0..<index {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            try press("bank_right")
            _ = awaitEvents(since: before, timeoutMs: 250)
        }
        return waitFor(seconds: 1.5, { ($0["lcd_top"] as? String) == expectedTop }) != nil
    }

    static func findChannel(trackName: String, retryOnEmpty: Bool = true) throws -> Int? {
        guard try ensurePanNames() else { debugLog("pan multi-channel view failed"); return nil }

        // Fastest path: the track is unique on the bank already showing.
        if let status = freshStatus(), let top = status["lcd_top"] as? String,
           let cachedTops = loadBankCache(), cachedTops.contains(top) {
            let allMatches = cachedTops.flatMap { cachedTop in
                lcdFields(cachedTop).enumerated().filter {
                    lcdNameMatches(track: trackName, lcd: $0.element)
                }
            }
            if allMatches.count == 1 {
                let current = lcdFields(top).enumerated().filter {
                    lcdNameMatches(track: trackName, lcd: $0.element)
                }
                if current.count == 1, let hit = current.first {
                    return hit.offset
                }
            }
        }

        // Fast path: the cached bank map from the previous full scan.
        if let cachedTops = loadBankCache() {
            var cachedMatches: [(bank: Int, channel: Int)] = []
            for (bank, cachedTop) in cachedTops.enumerated() {
                for (channel, name) in lcdFields(cachedTop).enumerated()
                where lcdNameMatches(track: trackName, lcd: name) {
                    cachedMatches.append((bank, channel))
                }
            }
            if cachedMatches.count == 1, let match = cachedMatches.first,
               try navigateToBank(match.bank, expecting: cachedTops[match.bank]) {
                return match.channel
            }
            // stale or ambiguous cache: fall through to a full rescan
            try? FileManager.default.removeItem(at: bankCacheURL)
        }

        try resetToLeftmostBank()
        guard var top = try settledTop() else { debugLog("no settled top after reset"); return nil }
        var bankTops: [String] = []
        var matches: [(bank: Int, channel: Int)] = []
        for bank in 0..<10 {
            if bankTops.last == top { break }
            bankTops.append(top)
            for (channel, name) in lcdFields(top).enumerated()
            where lcdNameMatches(track: trackName, lcd: name) {
                matches.append((bank, channel))
            }
            try press("bank_right")
            guard let next = try settledTop(previous: top) else { debugLog("no settled top in scan"); return nil }
            top = next
        }
        if let encoded = try? JSONEncoder().encode(bankTops) {
            try? encoded.write(to: bankCacheURL)
        }
        // Right after a project switch Logic rebuilds the control surface for
        // a few seconds and a full scan can come up empty — settle and rescan
        // once before giving up.
        if matches.isEmpty, retryOnEmpty {
            debugLog("empty bank scan; settling and rescanning once")
            Thread.sleep(forTimeInterval: 2.5)
            try? FileManager.default.removeItem(at: bankCacheURL)
            return try findChannel(trackName: trackName, retryOnEmpty: false)
        }
        guard matches.count == 1, let match = matches.first else { debugLog("match count \(matches.count)"); return nil }
        // Navigate back: we are at bank bankTops.count-1 (or the repeat point).
        let currentBank = bankTops.count - 1
        for _ in 0..<(currentBank - match.bank) {
            let before = freshStatus()?["received_events"] as? Int ?? -1
            try press("bank_left")
            _ = awaitEvents(since: before, timeoutMs: 250)
        }
        if waitFor(seconds: 2.0, { ($0["lcd_top"] as? String) == bankTops[match.bank] }) != nil {
            return match.channel
        }
        debugLog("navigate-back verify failed")
        return nil
    }

    /// Waits until the LCD top row holds stable, non-transient channel content
    /// (two consecutive identical reads that are not a "-      " banner), and
    /// differs from `previous` when given (returns previous content on timeout,
    /// which scan loops interpret as "rightmost bank reached").
    static func settledTop(previous: String? = nil) throws -> String? {
        let deadline = Date().addingTimeInterval(3.0)
        var quietRepeats = 0
        while Date() < deadline {
            guard let status = freshStatus(), let top = status["lcd_top"] as? String else { return nil }
            let events = status["received_events"] as? Int ?? -1
            let transient = lcdFields(top).filter { $0 == "-" }.count >= 4
            if !transient {
                if previous == nil || top != previous {
                    // stable = 120 ms without new MIDI from Logic
                    if let after = awaitEvents(since: events, timeoutMs: 120),
                       after["timed_out"] as? Bool == true {
                        return top
                    }
                    continue
                }
                // same as previous: two quiet rounds means the display will not
                // change (e.g. rightmost bank reached)
                if let after = awaitEvents(since: events, timeoutMs: 200),
                   after["timed_out"] as? Bool == true {
                    quietRepeats += 1
                    if quietRepeats >= 2 { return previous }
                }
                continue
            }
            _ = awaitEvents(since: events, timeoutMs: 250)
        }
        return previous
    }

}
