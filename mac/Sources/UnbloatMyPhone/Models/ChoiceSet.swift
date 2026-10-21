import Foundation
import UniformTypeIdentifiers
import SwiftUI

struct SavedChoice: Codable {
    /// Tweak id: "pkg:<package>" for apps, the setting id otherwise.
    var id: String
    /// Value of the chosen option, for choices that have options.
    var option: String?
}

/// A set of ticked choices, to do the same on another phone. Same file format as the Windows app.
struct ChoiceSet: Codable {
    /// The phone the choices were made on.
    var name: String
    var created: String
    var choices: [SavedChoice]

    var createdText: String { DateText.display(created) }

    private static var lastURL: URL { AppPaths.dataDir.appendingPathComponent("last-choices.json") }

    static func from(phoneName: String, selected: [Tweak]) -> ChoiceSet {
        ChoiceSet(name: phoneName, created: DateText.now(),
                  choices: selected.map { SavedChoice(id: $0.id, option: $0.options.isEmpty ? nil : $0.selectedOption) })
    }

    /// Tick exactly these choices. Returns how many exist on this phone.
    @discardableResult
    func apply(to all: [Tweak]) -> Int {
        var wanted: [String: SavedChoice] = [:]
        for c in choices where wanted[c.id] == nil { wanted[c.id] = c }
        var found = 0
        for t in all {
            guard let c = wanted[t.id] else { t.isSelected = false; continue }
            t.isSelected = true
            found += 1
            if let value = c.option, t.options.contains(where: { $0.value == value }) { t.selectedOption = value }
        }
        return found
    }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    static func decode(_ data: Data) -> ChoiceSet? {
        guard let c = try? JSONDecoder().decode(ChoiceSet.self, from: data), !c.choices.isEmpty else { return nil }
        return c
    }

    func saveAsLast() {
        AppPaths.ensureDataDir()
        try? encoded().write(to: Self.lastURL, options: .atomic)
    }

    static func loadLast() -> ChoiceSet? {
        (try? Data(contentsOf: lastURL)).flatMap(decode)
    }
}

/// Lets SwiftUI's file exporter save a ChoiceSet.
struct ChoiceSetDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var set: ChoiceSet

    init(set: ChoiceSet) { self.set = set }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let s = ChoiceSet.decode(data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        set = s
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try set.encoded())
    }
}

/// A pre-filled "new issue" link listing apps the catalog doesn't know. Only model and package names.
enum IssueReport {
    private static let newIssue = "https://github.com/matguitarist/UnbloatMyPhone/issues/new"
    private static let maxURL = 7000

    static func build(_ dev: PhoneDevice, packages: [String], catalogVersion: Int) -> (url: URL, complete: Bool) {
        let title = "Unknown apps on \(dev.displayName) (Android \(dev.androidVersion))"
        func body(_ count: Int, _ left: Int) -> String {
            var b = "**Device:** \(dev.displayName), Android \(dev.androidVersion) (SDK \(dev.sdk))\n"
            b += "**Catalog version:** \(catalogVersion)\n\n"
            b += "Preinstalled apps that are not in the catalog yet:\n```\n"
            b += packages.prefix(count).joined(separator: "\n") + "\n```\n"
            if left > 0 { b += "…and \(left) more: the full list is on the clipboard, paste it here.\n" }
            b += "\nIf you know what some of them do, add a line about it.\n"
            return b
        }
        func make(_ body: String) -> String {
            var c = URLComponents(string: newIssue)!
            c.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
            return c.url!.absoluteString
        }
        var s = make(body(packages.count, 0))
        if s.count <= maxURL { return (URL(string: s)!, true) }
        var n = packages.count
        repeat { n -= 1; s = make(body(n, packages.count - n)) } while n > 0 && s.count > maxURL
        return (URL(string: s)!, false)
    }

    /// A pre-filled "App names" issue: only the package names and the names the user typed,
    /// one "package = Name" per line, ready for tools/add-names.py.
    @MainActor static func buildNames(_ names: [(package: String, name: String)]) -> (url: URL, complete: Bool) {
        let title = "App names (\(names.count))"
        func body(_ count: Int, _ left: Int) -> String {
            var b = "Names for apps the catalog doesn't know yet, sent from UnbloatMyPhone \(AppUpdater.currentVersion):\n```\n"
            b += names.prefix(count).map { "\($0.package) = \($0.name)" }.joined(separator: "\n") + "\n```\n"
            if left > 0 { b += "…and \(left) more: the full list is on the clipboard, paste it here.\n" }
            return b
        }
        func make(_ body: String) -> String {
            var c = URLComponents(string: newIssue)!
            c.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
            return c.url!.absoluteString
        }
        var s = make(body(names.count, 0))
        if s.count <= maxURL { return (URL(string: s)!, true) }
        var n = names.count
        repeat { n -= 1; s = make(body(n, names.count - n)) } while n > 0 && s.count > maxURL
        return (URL(string: s)!, false)
    }
}
