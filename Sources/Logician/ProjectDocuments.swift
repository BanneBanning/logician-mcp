import Foundation

/// The document-list wire format is all-or-nothing: a malformed row must not
/// disappear and turn an unreadable open project into a verified empty list.
enum ProjectDocuments {
    typealias Document = (name: String, path: String?, modified: Bool)

    static func parse(_ raw: String) -> [Document]? {
        if raw.isEmpty { return [] }
        let entries = raw.split(separator: "\u{1E}", omittingEmptySubsequences: false)
        guard entries.last?.isEmpty == true else { return nil }
        var documents: [Document] = []
        for entry in entries.dropLast() {
            let parts = entry.components(separatedBy: "\u{1F}")
            guard parts.count == 3, !parts[0].isEmpty,
                  parts[2] == "true" || parts[2] == "false" else { return nil }
            documents.append((
                name: parts[0].precomposedStringWithCanonicalMapping,
                path: parts[1].isEmpty ? nil : parts[1].precomposedStringWithCanonicalMapping,
                modified: parts[2] == "true"
            ))
        }
        return documents
    }
}
