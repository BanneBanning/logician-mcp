import ApplicationServices
import Foundation
import LogicMCUBridge

extension LogicAccessibility {
    private func transferSnapshot() throws -> RegionTransfer.Snapshot {
        var snapshot: RegionTransfer.Snapshot = [:]
        for row in try regionRows() {
            guard snapshot[row.number] == nil else {
                throw RegionTransfer.Failure("duplicate track number in arrangement")
            }
            let regions = try row.regions.map { element in
                let name = parseRegion(element)["name"] as? String ?? ""
                guard !name.isEmpty, let region = RegionTransfer.Region(
                    name: name, help: stringAttribute(element, kAXHelpAttribute as String)
                ) else {
                    throw RegionTransfer.Failure("exact region bounds are unavailable on track \(row.number)")
                }
                return region
            }
            snapshot[row.number] = RegionTransfer.Row(name: row.track, regions: regions)
        }
        return snapshot
    }

    func transferRegion(
        trackName: String, regionName: String?, startBar: Int?, toBar: Int,
        toTrack: String?, fromTrackNumber: Int?, toTrackNumber: Int?
    ) throws -> [String: Any] {
        let window = try projectWindow()
        let project = documentPath(of: window)
        let tabs = tempoListTabs(in: window)
        let previous = tabs.first(where: \.selected)?.name
        if !tabs.isEmpty {
            // An open Event List can retain keyboard focus even after the
            // track header was selected. Close it while region commands run;
            // each content read temporarily opens and restores its own pane.
            guard listEditorsPaneHold == nil else {
                throw RegionTransfer.Failure("a held List Editors pane prevents safe region focus")
            }
            try pressMenuItem(containing: LogicUIStrings.Menu.listEditors,
                              underMenu: LogicUIStrings.Menu.view)
            guard tempoListTabs(in: window).isEmpty else {
                throw RegionTransfer.Failure("the Event List retained focus; no region was moved")
            }
        }
        let result = Result<[String: Any], Error> {
            guard documentPath(of: try projectWindow()) == project else {
                throw RegionTransfer.Failure("the project changed before the move")
            }
            return try performRegionTransfer(trackName: trackName, regionName: regionName,
                startBar: startBar, toBar: toBar, toTrack: toTrack,
                fromTrackNumber: fromTrackNumber, toTrackNumber: toTrackNumber)
        }
        if !tabs.isEmpty {
            do {
                guard documentPath(of: try projectWindow()) == project else {
                    throw RegionTransfer.Failure("the project changed before restoring the editor")
                }
                if tempoListTabs(in: window).isEmpty {
                    try pressMenuItem(containing: LogicUIStrings.Menu.listEditors,
                                      underMenu: LogicUIStrings.Menu.view)
                }
                let restored = settleForListEditorsPane(tab: previous ?? "Event", in: window)
                guard let tab = restored.first(where: { $0.name == previous }) else {
                    throw RegionTransfer.Failure("the original editor tab is unavailable")
                }
                if !tab.selected { _ = AXUIElementPerformAction(tab.element, kAXPressAction as CFString) }
                guard tempoListTabs(in: window).contains(where: { $0.name == previous && $0.selected }) else {
                    throw RegionTransfer.Failure("the original editor tab did not restore")
                }
            } catch {
                let outcome: String
                switch result {
                case .success: outcome = "the move completed"
                case .failure(let failure): outcome = "the move failed: \(failure.localizedDescription)"
                }
                throw RegionTransfer.Failure("\(outcome), but the original List Editors view could not be restored: \(error.localizedDescription)")
            }
        }
        return try result.get()
    }

    private func performRegionTransfer(
        trackName: String, regionName: String?, startBar: Int?, toBar: Int,
        toTrack: String?, fromTrackNumber: Int?, toTrackNumber: Int?
    ) throws -> [String: Any] {
        guard let project = documentPath(of: try projectWindow()) else {
            throw RegionTransfer.Failure("the active project cannot be identified; nothing was moved")
        }
        func checkProject() throws {
            guard documentPath(of: try projectWindow()) == project else {
                throw RegionTransfer.Failure("the active project changed")
            }
        }
        do {
            let headers = try parsedTrackHeaders()
            let sourceTrack = try resolveTrack(headers, name: trackName, number: fromTrackNumber)
            let destination = try resolveTrack(headers, name: toTrack ?? trackName,
                number: toTrack == nil ? fromTrackNumber : toTrackNumber)
            let meter = readMeterMap()
            guard let map = meter.map else {
                throw RegionTransfer.Failure("the signature map could not be read; nothing was moved")
            }
            try checkProject()
            let before = try transferSnapshot()
            let candidates = before[sourceTrack.number]?.regions.keys.filter { region in
                let matchesName = regionName.map {
                    RegionNameAnnotation.matches(name: region.name, request: $0)
                } ?? true
                return matchesName && (startBar == nil || region.start.bar == startBar)
            } ?? []
            guard candidates.count == 1, let source = candidates.first else {
                throw RegionTransfer.Failure("the source region is missing or ambiguous; specify its name and start_bar")
            }
            let plan = try RegionTransfer.Plan(before: before, source: source,
                sourceTrack: sourceTrack.number, destinationTrack: destination.number,
                toBar: toBar, meter: map)
            let sourceContents = try midiRegionWitness(trackName: sourceTrack.name,
                trackNumber: sourceTrack.number, region: source, meter: map)
            var result: [String: Any] = [:]
            var deleteSent = false
            try RegionTransfer.execute(plan: plan, checkProject: checkProject, copy: {
                // Recheck the whole baseline after all preflight UI work.
                guard try self.transferSnapshot() == before else {
                    throw RegionTransfer.Failure("the arrangement changed before Copy")
                }
                result = try self.copyRegion(trackName: sourceTrack.name,
                    regionName: source.name, startBar: source.start.bar, toBar: toBar,
                    toTrack: destination.name, move: false,
                    fromTrackNumber: sourceTrack.number, toTrackNumber: destination.number)
            }, verifyCopy: {
                let contents = try self.midiRegionWitness(trackName: destination.name,
                    trackNumber: destination.number, region: plan.destination, meter: map)
                guard contents == sourceContents else {
                    throw RegionTransfer.Failure("the pasted MIDI notes or region parameters differ from the source")
                }
            }, prepareDelete: {
                let contents = try self.midiRegionWitness(trackName: sourceTrack.name,
                    trackNumber: sourceTrack.number, region: source, meter: map)
                guard contents == sourceContents else {
                    throw RegionTransfer.Failure("the source MIDI contents changed before Delete")
                }
                let census = try self.arrangementCensus(trackName: sourceTrack.name,
                    trackNumber: sourceTrack.number)
                let (_, selectionPlan) = try self.regionEditPlan(.delete,
                    regionRowNumbers: census.rowNumbers)
                let selected = try self.establishExclusiveRegionSelection(.delete,
                    plan: selectionPlan, trackName: sourceTrack.name,
                    regionName: source.name, startBar: source.start.bar,
                    trackNumber: sourceTrack.number)
                guard selected.region["name"] as? String == source.name,
                      selected.region["start_bar"] as? Int == source.start.bar else {
                    throw RegionTransfer.Failure("the source selection changed")
                }
            }, snapshot: {
                var snapshot = try self.transferSnapshot()
                if deleteSent {
                    let deadline = ProcessInfo.processInfo.systemUptime + 2
                    while snapshot == plan.copied && ProcessInfo.processInfo.systemUptime < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                        try checkProject()
                        snapshot = try self.transferSnapshot()
                    }
                }
                return snapshot
            }, delete: {
                deleteSent = true
                try self.fireKeyCommand(KeyCommandRegistry.Name.delete)
            })
            result["state"] = "moved_via_clipboard"
            result["project_regions_after"] = result["project_regions_before"]
            result["verification_scope"] = "rendered region names, types and exact boundaries; fully displayed MIDI Note events including absolute note ends, attack/release velocities and articulation; published region inspector rows"
            result["note"] = "Copied and independently compared MIDI notes and region parameters before deleting the unchanged source. Copy/Paste and Delete are separate undo steps. This does not prove musical equivalence on a different instrument track or expose every possible internal Logic property."
            return result
        } catch {
            throw LogicianError.verificationFailed(requested: "a verified clipboard move",
                actual: error.localizedDescription, restored: false)
        }
    }
}
