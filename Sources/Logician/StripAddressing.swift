import AppKit
import ApplicationServices
import Foundation

// Addressing strips that are NOT tracks: Stereo Out, the Master fader, auxes
// and buses.
//
// Every mixing and plugin tool used to open with `selectTrack(trackName:)`,
// which resolves against TRACK HEADERS in the Tracks area. Output, aux and bus
// strips have no track header, so the call threw `trackNotFound` before either
// control plane was ever asked — even though the control surface addresses them
// as perfectly ordinary bank channels (FINDINGS 2026-08-25: "Stereo Out, auxar
// och busskanaler är vanliga bankkanaler").
//
// The routing rule: a name that IS a track header keeps the exact path it had.
// A name that is not one is resolved on the control surface instead, and the
// selection is proven from the mirror before anything is written.

/// Which plane can point at a strip.
enum StripPlane: String, Equatable {
    /// An ordinary track: Accessibility track selection resolves it.
    case trackHeader = "ax_track_header"
    /// An output/aux/bus strip: no track header exists, so the control
    /// surface's channel selection is the only way to point at it.
    case surfaceChannel = "mcu_channel"
}

/// True when a failed track lookup is the signature of a HEADERLESS strip
/// rather than of a typo or a stale name.
///
/// Only `trackNotFound` qualifies — "this name is not a track header at all".
/// `trackAmbiguous`, `trackMismatch` and every write/verification failure mean
/// the name IS a track and something else went wrong, and rerouting those to
/// the surface would paper over a real problem. A track NUMBER pins the request
/// to the header plane too: numbers exist only there, so a caller that passed
/// one is not talking about an output strip.
func isHeaderlessStripCandidate(_ error: LogicianError, trackNumberGiven: Bool) -> Bool {
    guard !trackNumberGiven else { return false }
    guard case .trackNotFound = error else { return false }
    return true
}

/// Turns a surface resolution that did not land into the right error, with the
/// track-header miss folded in — the agent asked for one name and deserves to
/// hear what BOTH planes saw.
func headerlessStripError(
    name: String,
    resolution: MCUController.ChannelResolution,
    visibleTracks: [String],
    trackMiss: LogicianError
) -> LogicianError {
    switch resolution {
    case .resolved:
        // Not an error at all; callers never build one from a resolved value.
        return trackMiss
    case .ambiguous(let cells):
        return .stripAmbiguous(name: name, cells: cells)
    case .notFound(let cells):
        return .stripNotFound(name: name, tracks: visibleTracks, cells: cells)
    case .unavailable(let reason):
        return .trackNotExposed(
            requested: "'\(name)' as an output/aux/bus strip",
            exposed: "it is not a track header, and the control surface could not be used to reach it: "
                + reason + ". Nothing was written."
        )
    }
}

extension LogicAccessibility {
    /// The inspector channel strip whose controls a mixing tool is about to
    /// read or write.
    ///
    /// Ordinary tracks are SELECTED first, exactly as before — that is what
    /// puts them in the left inspector, and the selection is the independent
    /// readback `trackSelectionVerified` relies on. A headerless strip cannot
    /// be selected, so it is addressed by name in whichever inspector strip is
    /// showing it (the right one shows the selected track's output), which is
    /// what `logic_survey_plugins` has been doing since v0.31.
    ///
    /// Note the asymmetry, which is why the MCU plane goes first everywhere:
    /// Accessibility can only see a headerless strip that happens to be ON
    /// SCREEN in an inspector, while the surface addresses every strip in the
    /// project (verified 2026-08-27: `Stereo Out` was visible as the selected
    /// track's output, `Master`, `Aux 1` and `Aux 2` were not).
    func stripForControls(
        trackName: String,
        trackNumber: Int?
    ) throws -> (strip: AXUIElement, plane: StripPlane) {
        do {
            _ = try selectTrack(trackName: trackName, trackNumber: trackNumber, expectedProjectPath: nil)
            return (try inspectorStrip(named: trackName), .trackHeader)
        } catch let error as LogicianError
        where isHeaderlessStripCandidate(error, trackNumberGiven: trackNumber != nil) {
            guard let strip = try? anyInspectorStrip(named: trackName) else {
                // Say what BOTH planes saw: "not a track" is only half of it,
                // and an agent that hears only that will retry the same name.
                throw LogicianError.trackNotExposed(
                    requested: "'\(trackName)' as an output/aux/bus channel strip",
                    exposed: "it is not a track header, and no inspector strip with that name is on screen."
                        + " Accessibility can only reach a headerless strip that an inspector is showing"
                        + " (select a track routed to it — opening the Mixer does NOT help, measured 2026-08-28)."
                        + " Use the logic_mcu_* tools for a strip no inspector shows. Nothing was written."
                )
            }
            return (strip, .surfaceChannel)
        }
    }
}

extension MCPServer {
    /// A tool's target strip, after selection.
    struct StripTarget {
        let name: String
        let plane: StripPlane
        /// The surface strip index, when the surface was used to select it.
        let channel: Int?
        /// The `selectTrack` result, verbatim, when the target was a track —
        /// so callers that used to return it keep returning the same thing.
        let selection: [String: Any]?
        /// What proved the surface selection, when the surface was used.
        let evidence: String?

        /// The fields every routed result carries, so an agent can always see
        /// WHICH plane pointed at the strip and what proved it.
        var resultFields: [String: Any] {
            var fields: [String: Any] = ["selection_route": plane.rawValue]
            if let channel { fields["mcu_strip"] = channel + 1 }
            if let evidence { fields["selection_readback_route"] = evidence }
            return fields
        }
    }

    /// Selects the strip a tool is about to act on, whichever plane can reach
    /// it. Tracks take the unchanged Accessibility path; output/aux/bus strips
    /// are selected on the control surface and LCD/LED-verified before the
    /// caller writes anything.
    func selectStripTarget(
        _ arguments: [String: Any],
        expectedProjectPath: String? = nil
    ) throws -> StripTarget {
        let name = try requiredString("track_name", in: arguments)
        let number = arguments["track_number"] as? Int
        do {
            let selection = try logic.selectTrack(
                trackName: name, trackNumber: number, expectedProjectPath: expectedProjectPath
            )
            return StripTarget(
                name: name, plane: .trackHeader, channel: nil,
                selection: selection, evidence: nil
            )
        } catch let error as LogicianError
        where isHeaderlessStripCandidate(error, trackNumberGiven: number != nil) {
            // `selectTrack` verified the project path before it looked at any
            // header, so that precondition is already honoured here.
            guard let channel = try MCUController.findChannel(trackName: name) else {
                throw headerlessStripError(
                    name: name,
                    resolution: MCUController.lastChannelResolution,
                    visibleTracks: ((try? logic.parsedTrackHeaders()) ?? []).map(\.name),
                    trackMiss: error
                )
            }
            let evidence = try MCUController.selectChannelVerified(
                channel: channel, expectedName: name
            )
            return StripTarget(
                name: name, plane: .surfaceChannel, channel: channel,
                selection: nil, evidence: evidence
            )
        }
    }
}
