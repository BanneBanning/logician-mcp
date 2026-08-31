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
/// Two signatures qualify. `trackNotFound` — "this name is not a track header
/// at all". And the one `windowNotFound` that means the header COLUMN itself
/// was unreadable: a non-English Logic publishes a localized description on
/// it, so EVERY track name used to die at that gate before the surface was
/// asked — while the surface, which is language-independent, could find the
/// same track by its LCD name in the same session (measured 2026-08-30,
/// French Logic). "The header column cannot be read" must fall through to the
/// surface exactly as "this name is not a header" does, or language_note's
/// promise that the surface plane survives any UI language is false.
///
/// Every other failure stays on the header plane. `trackAmbiguous`,
/// `trackMismatch` and the write/verification failures mean the name IS a
/// track and something else went wrong, and rerouting those to the surface
/// would paper over a real problem. Other `windowNotFound` reasons mean the
/// plane's own preconditions failed — a missing PROJECT window means the
/// project-path check never ran, so a rerouted write could land in the wrong
/// project. A track NUMBER pins the request to the header plane too: numbers
/// exist only there, so a caller that passed one is not talking about an
/// output strip.
func isHeaderlessStripCandidate(_ error: LogicianError, trackNumberGiven: Bool) -> Bool {
    guard !trackNumberGiven else { return false }
    switch error {
    case .trackNotFound:
        return true
    case .windowNotFound(let missing):
        return missing == LogicAccessibility.tracksHeaderGroupMissing
    default:
        return false
    }
}

/// The header-plane half of a two-plane error message: what the track lookup
/// actually established. "It is not a track header" is only true when the
/// header column was readable; on a non-English Logic the honest half is that
/// the column could not be read at all.
func headerPlaneMiss(_ trackMiss: LogicianError) -> String {
    if case .windowNotFound = trackMiss {
        return "the track-header column could not be read (a non-English Logic"
            + " publishes a localized description on it), so the name could not"
            + " be checked against track headers"
    }
    return "it is not a track header"
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
            exposed: headerPlaneMiss(trackMiss)
                + ", and the control surface could not be used to reach it: "
                + reason + ". Nothing was written."
        )
    }
}

/// The error for a focus divergence that could not be repaired: the track
/// header says one strip, the focused channel is another, and the realigning
/// reselection was impossible or failed — so the disagreement is REPORTED
/// with both halves and the manual fix, never read through.
func focusRealignmentFailure(
    name: String,
    focusedOn: String,
    reason: String
) -> LogicianError {
    .verificationFailed(
        requested: "Logic's focused channel on '\(name)' before trusting a control-surface view",
        actual: "the track header '\(name)' is selected, but Logic's focused channel is"
            + " '\(focusedOn)' — the surface's plugin and send views follow the focused"
            + " CHANNEL, not the header, so reading through it would return"
            + " '\(focusedOn)''s data under '\(name)''s name. Realigning by reselection"
            + " did not work: \(reason)."
            + " Select a different track and then '\(name)' again in Logic to realign."
            + " Nothing was read or written",
        restored: true
    )
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
                    exposed: headerPlaneMiss(error)
                        + ", and no inspector strip with that name is on screen."
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
            // The `already_selected` fast path proves the HEADER, not the
            // focused CHANNEL — and the surface's follow-views (plugin list,
            // plugin edit, sends) follow the channel. A surface select of a
            // headerless strip moves the channel while the header stays put,
            // which is how `logic_list_inserts {Bas, mcu}` once returned
            // Stereo Out's chain as Bas's (observed live 2026-08-31). So the
            // fast path is only trusted when neither the live mirror nor this
            // process's own record says the focus is elsewhere; a divergence
            // is realigned by a REAL track reselection, or reported — never
            // read through.
            //
            // The realign is deliberately NOT a surface channel select. That
            // select verifiably moves Logic's selection (the SELECT LED, the
            // fader bank and the rec-arm echo all follow) and STILL leaves
            // the plugin-list view latched to the strip it last showed —
            // measured live 2026-08-31, LED lit on Bas while the PL row kept
            // Stereo Out's chain. What provably resets the latch is a real
            // track-HEADER selection change (the documented manual repair):
            // select another track, then the requested one again.
            if selection["state"] as? String == "already_selected",
               case .diverged(let focusedOn) = MCUController.currentFocusVerdict(requested: name) {
                let headers = (try? logic.parsedTrackHeaders()) ?? []
                guard let partner = headers.first(where: { $0.name != name }) else {
                    throw focusRealignmentFailure(
                        name: name,
                        focusedOn: focusedOn,
                        reason: "no other track header exists to bounce the selection through"
                    )
                }
                let realigned: [String: Any]
                do {
                    _ = try logic.selectTrack(
                        trackName: partner.name, trackNumber: partner.number,
                        expectedProjectPath: expectedProjectPath
                    )
                    realigned = try logic.selectTrack(
                        trackName: name, trackNumber: number,
                        expectedProjectPath: expectedProjectPath
                    )
                } catch let bounceError as LogicianError {
                    throw focusRealignmentFailure(
                        name: name,
                        focusedOn: focusedOn,
                        reason: "the reselection via '\(partner.name)' failed"
                            + " (\(bounceError.errorDescription ?? bounceError.code))"
                    )
                }
                return StripTarget(
                    name: name, plane: .trackHeader, channel: nil,
                    selection: realigned, evidence: "realigned_ax_reselect"
                )
            }
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
