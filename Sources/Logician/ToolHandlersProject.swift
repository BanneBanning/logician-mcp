import Foundation

// Project lifecycle and windows: open, close, save, duplicate, new.
extension MCPServer {
    func handleListWindows(_ arguments: [String: Any]) throws -> Any {
        return ["success": true, "state": "listed", "windows": try logic.listWindows()]
    }

    func handleSaveProject(_ arguments: [String: Any]) throws -> Any {
        return try logic.saveProject(
            expectedProjectPath: arguments["expected_project_path"] as? String
        )
    }

    func handleNewProject(_ arguments: [String: Any]) throws -> Any {
        return try openAndForgetTheOldProject(
            path: requiredString("path", in: arguments),
            createFromTemplate: true,
            ifCurrentModified: (arguments["if_current_modified"] as? String) ?? "fail",
            // The one track Logic insists on before it will show the project.
            // Optional, and absent means "whatever the sheet already had
            // selected" — which is the kind last used on that Mac, reported
            // back either way in `initial_track`.
            initialTrackType: (arguments["initial_track"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    func handleOpenProject(_ arguments: [String: Any]) throws -> Any {
        return try openAndForgetTheOldProject(
            path: requiredString("path", in: arguments),
            createFromTemplate: false,
            ifCurrentModified: (arguments["if_current_modified"] as? String) ?? "fail"
        )
    }

    /// The open, plus the four per-project caches — the pairing
    /// `logic_close_project` (above) and `logic_reset_to`
    /// (`ProjectReset.invalidateAllProjectCaches`) already make, and the one
    /// `logic_new_project` and `logic_open_project` were missing until
    /// 2026-09-02.
    ///
    /// The caches are stamped `cacheScopeToken(projectPath:)` =
    /// `v<version>|<path>`, so a switch to a DIFFERENT path invalidates them by
    /// construction — and that is exactly the case the token CAN see. What it
    /// cannot see is the same path holding a different project: delete a
    /// project and create a new one at that path, which is the eval-loop shape
    /// and what `logic_new_project` exists for. A bank map, a meter map, the
    /// parameter names and a tempo map measured against the project that used
    /// to live there then match by scope and describe nothing — the cache that
    /// is not stale but WRONG. A create from the empty template makes any
    /// surviving bank map wrong by definition: the new project has one bank.
    ///
    /// Cleared AFTER the open rather than before, unlike the reset's (which
    /// clears between its own close and open so a racing read cannot
    /// re-populate from the old scope): nothing on this path reads or writes
    /// them — the open is a `/usr/bin/open`, an Accessibility walk and two
    /// Apple Events, no MCU — so there is no race to lose, and clearing after
    /// means a REFUSED open (nothing written, nothing closed) does not cost the
    /// still-open project its caches and a 5–12 s rescan it did not need.
    /// A verification TIMEOUT is the one failure where the project may have
    /// switched anyway, so that one clears too, on the way out.
    ///
    /// Cost: 0.5–2.5 ms, measured. `caches_cleared` names what was actually
    /// there to forget.
    private func openAndForgetTheOldProject(
        path: String, createFromTemplate: Bool, ifCurrentModified: String,
        initialTrackType: String? = nil
    ) throws -> [String: Any] {
        do {
            var result = try logic.openProject(
                path: path,
                createFromTemplate: createFromTemplate,
                ifCurrentModified: ifCurrentModified,
                initialTrackType: initialTrackType
            )
            result["caches_cleared"] = invalidateAllProjectCaches()
            return result
        } catch LogicianError.verificationFailed(let requested, let actual, let restored) {
            // The open may well have LANDED and only the proof failed, so the
            // caches can already be describing the wrong project. Clearing
            // costs a rescan; keeping them costs correctness.
            _ = invalidateAllProjectCaches()
            throw LogicianError.verificationFailed(
                requested: requested,
                actual: actual + ". Every per-project cache was cleared anyway — the open may"
                    + " have happened and only the proof failed, and a cache describing the"
                    + " wrong project is worse than an absent one",
                restored: restored
            )
        }
    }

    func handleDuplicateProject(_ arguments: [String: Any]) throws -> Any {
        return try logic.duplicateProject(
            destinationPath: arguments["destination_path"] as? String,
            saveFirst: arguments["save_first"] as? Bool ?? false,
            openCopy: arguments["open_copy"] as? Bool ?? true,
            // 'fail', as logic_open_project and logic_new_project default —
            // one guard, one default, one refusal, across every tool that
            // closes the current project.
            //
            // It used to default to 'save' "since the original is the project
            // being closed", which meant duplicating a MODIFIED project
            // committed the user's in-progress edits to their own file while
            // the same result said the original was untouched. That is a
            // silent, unrepeatable write on the tool an agent is told to reach
            // for BEFORE making changes nobody approved (AGENT-GUIDE,
            // "Experiment safely on a copy") — failing toward writing, on the
            // one tool whose entire purpose is not to. A default cannot be
            // asked whether it meant it; a refusal can, and it costs one round
            // trip and names four ways forward.
            ifCurrentModified: (arguments["if_current_modified"] as? String) ?? "fail"
        )
    }

    func handleCloseProject(_ arguments: [String: Any]) throws -> Any {
        var result = try logic.closeProject(
            saving: requiredString("saving", in: arguments),
            expectedProjectPath: arguments["expected_project_path"] as? String,
            timeoutSeconds: ProjectReset.closeTimeoutSeconds(arguments)
        )
        // The same four caches `logic_reset_to` clears between its close and
        // its open, for the same reason (ProjectReset.invalidateAllProjectCaches):
        // they are stamped with `cacheScopeToken(projectPath:)`, which catches
        // a switch to a DIFFERENT project but is IDENTICAL across a close and
        // reopen of the SAME path — and close-then-open of the same path is
        // exactly what an agent does with this tool. A bank map measured
        // against tracks that only existed unsaved would otherwise survive and
        // be trusted: a cache that is not stale but WRONG.
        //
        // Cleared on any close that returned, verified or not: a close that
        // could not be confirmed may well have happened, and a cleared cache
        // costs one rescan while a wrong one costs correctness. A close that
        // was REFUSED throws before this line and clears nothing.
        result["caches_cleared"] = invalidateAllProjectCaches()
        return result
    }
}
