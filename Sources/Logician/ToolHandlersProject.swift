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
        return try logic.closeProject(
            saving: requiredString("saving", in: arguments),
            expectedProjectPath: arguments["expected_project_path"] as? String
        )
    }
}
