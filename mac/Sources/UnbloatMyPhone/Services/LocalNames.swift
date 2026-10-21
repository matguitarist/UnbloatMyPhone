import Foundation

/// Names the user gave to apps the catalog doesn't know, in app-names.json next to the backups
/// (the same file the Windows app uses). Shown everywhere an app name is, and offered for sharing.
@MainActor
enum LocalNames {
    private static var fileURL: URL { AppPaths.dataDir.appendingPathComponent("app-names.json") }
    private static var names: [String: String] = load()

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func get(_ pkg: String) -> String? { names[pkg] }

    /// An empty name forgets it.
    static func set(_ pkg: String, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[pkg] = n.isEmpty ? nil : String(n.prefix(60))
        AppPaths.ensureDataDir()
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(names).write(to: fileURL, options: .atomic)
    }

    /// The names the catalog doesn't have yet: what is worth sharing.
    static func notInCatalog() -> [(package: String, name: String)] {
        names.filter { Catalog.catalogName(of: $0.key) == nil }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}
