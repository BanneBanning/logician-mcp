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
        return try logic.openProject(
            path: requiredString("path", in: arguments),
            createFromTemplate: true,
            ifCurrentModified: (arguments["if_current_modified"] as? String) ?? "fail"
        )
    }

    func handleOpenProject(_ arguments: [String: Any]) throws -> Any {
        return try logic.openProject(
            path: requiredString("path", in: arguments),
            createFromTemplate: false,
            ifCurrentModified: (arguments["if_current_modified"] as? String) ?? "fail"
        )
    }

    func handleDuplicateProject(_ arguments: [String: Any]) throws -> Any {
        return try logic.duplicateProject(
            destinationPath: arguments["destination_path"] as? String,
            saveFirst: arguments["save_first"] as? Bool ?? false,
            openCopy: arguments["open_copy"] as? Bool ?? true,
            ifCurrentModified: (arguments["if_current_modified"] as? String) ?? "save"
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
