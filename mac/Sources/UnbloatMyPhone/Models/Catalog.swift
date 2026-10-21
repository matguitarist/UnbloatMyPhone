import Foundation

/// Builds the list of choices for one phone from shared/catalog.json: the copy in the app bundle, or a
/// newer one downloaded from GitHub. Same file and same rules as the Windows/Linux app.
enum Catalog {
    /// Catalog format this version understands.
    private static let schema = 1
    private static let remoteURL = URL(string: "https://raw.githubusercontent.com/matguitarist/UnbloatMyPhone/main/shared/catalog.json")!
    private static var cacheURL: URL { AppPaths.dataDir.appendingPathComponent("catalog.json") }

    struct GroupDef: Codable { var id: String; var title: LocText; var description: LocText }
    struct PackageDef: Codable {
        var id: String?
        var prefix: String?
        var group: String
        var recommended: Bool?
        var requiresSetupComplete: Bool?
        var name: LocText
        var description: LocText
        var warning: LocText?
    }
    struct OptionDef: Codable {
        var label: LocText
        var value: String
        /// Offered only when this app is installed (it is turned back on if needed).
        var installed: String?
        var keeps: [String]?
    }
    /// A known system part that must stay on: never offered, never reported as unknown.
    struct KeepDef: Codable { var id: String }
    struct WhenDef: Codable {
        var minSdk: Int?
        var maxSdk: Int?
        var installed: String?
        var storageFreeBelowPercent: Int?
    }
    struct SettingDef: Codable {
        var id: String
        var kind: String?
        var group: String
        var recommended: Bool?
        var when: WhenDef?
        var recommendedWhen: WhenDef?
        var name: LocText
        var description: LocText
        var warning: LocText?
        var options: [OptionDef]?
        var writes: [SettingWrite]?
    }
    struct File: Codable {
        var schema: Int
        var version: Int
        var groups: [GroupDef]
        var packages: [PackageDef]
        var settings: [SettingDef]?
        var keep: [KeepDef]?
        var names: [NameDef]?
    }
    /// A readable name for a system part (Health page). Never offered.
    struct NameDef: Codable { var id: String; var name: LocText }

    /// Nil if the data isn't a catalog this version can use.
    static func parse(_ data: Data) -> File? {
        guard let c = try? JSONDecoder().decode(File.self, from: data), c.schema == schema, !c.groups.isEmpty else { return nil }
        let groups = Set(c.groups.map(\.id))
        guard c.packages.allSatisfy({ groups.contains($0.group) && ($0.id != nil || !($0.prefix ?? "").isEmpty) }),
              (c.settings ?? []).allSatisfy({ groups.contains($0.group) }) else { return nil }
        return c
    }

    private static let embedded: File = {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url), let c = parse(data) else {
            fatalError("catalog.json missing from the app bundle")
        }
        return c
    }()

    @MainActor private static var current: File = {
        if let data = try? Data(contentsOf: cacheURL), let cached = parse(data), cached.version > embedded.version { return cached }
        return embedded
    }()

    @MainActor static var version: Int { current.version }

    @MainActor private static var lastRefresh = Date.distantPast

    /// Fetch the latest list from GitHub; it is used from the next phone list on.
    /// Called at start and before each Choose page, at most once a minute.
    @MainActor static func refreshFromGitHub() async {
        guard Date().timeIntervalSince(lastRefresh) >= 60 else { return }
        lastRefresh = Date()
        guard let (data, response) = try? await URLSession.shared.data(from: remoteURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let remote = parse(data), remote.version > current.version else { return }
        AppPaths.ensureDataDir()
        try? data.write(to: cacheURL, options: .atomic)
        current = remote
    }

    private static func isKeep(_ c: File, _ pkg: String) -> Bool { (c.keep ?? []).contains { $0.id == pkg } }

    @MainActor static func isKeep(_ pkg: String) -> Bool { isKeep(current, pkg) }

    /// A readable name for an app or process ("com.google.android.gms:snet" counts as its app):
    /// the catalog's, in the current language, else the one the user gave it.
    @MainActor static func name(of pkg: String) -> String? {
        catalogName(of: pkg) ?? LocalNames.get(String(pkg.split(separator: ":").first ?? ""))
    }

    /// The catalog's name for an app, in the current language, if it has one.
    @MainActor static func catalogName(of pkg: String) -> String? {
        for id in [pkg, String(pkg.split(separator: ":").first ?? "")] {
            if let def = current.packages.first(where: { $0.id == id }) { return def.name.text }
            if let n = current.names?.first(where: { $0.id == id }) { return n.name.text }
        }
        return nil
    }

    /// Whether the Choose page would offer to turn this app off on this phone.
    @MainActor static func isOffered(_ dev: PhoneDevice, _ pkg: String) -> Bool {
        dev.enabled.contains(pkg) && !dev.isProtected(pkg) && !isKeep(current, pkg) &&
            current.packages.contains { $0.id == pkg || ($0.prefix.map { !$0.isEmpty && pkg.hasPrefix($0) } ?? false) }
    }

    private static func isKnown(_ c: File, _ pkg: String) -> Bool {
        isKeep(c, pkg) || c.packages.contains { $0.id == pkg || ($0.prefix.map { !$0.isEmpty && pkg.hasPrefix($0) } ?? false) }
    }

    @MainActor static func build(_ dev: PhoneDevice) -> [TweakGroup] {
        let c = current
        var groups: [String: TweakGroup] = [:]
        for g in c.groups { groups[g.id] = TweakGroup(id: g.id, title: g.title, description: g.description) }
        var used = Set<String>()

        // Apps from the catalog, only those installed, enabled and not protected on this phone.
        for def in c.packages {
            if def.requiresSetupComplete == true && !dev.setupComplete { continue }
            let matches: [String]
            if let id = def.id { matches = dev.enabled.contains(id) ? [id] : [] }
            else { matches = dev.enabled.filter { $0.hasPrefix(def.prefix!) }.sorted() }
            for pkg in matches where !dev.isProtected(pkg) && used.insert(pkg).inserted {
                groups[def.group]?.tweaks.append(Tweak(
                    id: "pkg:" + pkg, groupId: def.group, recommended: def.recommended ?? false,
                    title: def.name, description: def.description, warning: def.warning, kind: .package(pkg)))
            }
        }

        for def in c.settings ?? [] where matches(def.when, dev) {
            if let t = makeSetting(def, dev) { groups[def.group]?.tweaks.append(t) }
        }

        return c.groups.compactMap { groups[$0.id] }.filter { !$0.tweaks.isEmpty }
    }

    private static func matches(_ w: WhenDef?, _ dev: PhoneDevice) -> Bool {
        guard let w else { return true }
        if let sdk = w.minSdk, dev.sdk < sdk { return false }
        if let max = w.maxSdk, dev.sdk > max { return false }
        if let pkg = w.installed, !dev.isInstalled(pkg) { return false }
        if let pct = w.storageFreeBelowPercent,
           dev.storageTotalMb == 0 || dev.storageFreeMb * 100 >= dev.storageTotalMb * Int64(pct) { return false }
        return true
    }

    /// A setting from the catalog, or nil for a kind this version doesn't know.
    private static func makeSetting(_ def: SettingDef, _ dev: PhoneDevice) -> Tweak? {
        var description = def.description
        if description.en.contains("{storage}") {
            description = description.replacing("{storage}", en: storageText(dev, "en"), fr: storageText(dev, "fr"))
        }
        let options = (def.options ?? [])
            .filter { $0.installed.map(dev.isInstalled) ?? true }
            .map { TweakOption(label: $0.label, value: $0.value, keeps: $0.keeps ?? []) }
        let recommended = (def.recommended ?? false) || (def.recommendedWhen.map { matches($0, dev) } ?? false)
        let kind: Tweak.Kind
        switch def.kind ?? "settings" {
        case "settings":
            guard let writes = def.writes, !writes.isEmpty else { return nil }
            kind = .settings(writes)
        case "optimizeApps": kind = .optimizeApps
        case "privateDns": kind = .privateDns
        case "trimCaches":
            guard dev.storageTotalMb > 0 else { return nil }
            kind = .trimCaches
        default: return nil
        }
        return Tweak(id: def.id, groupId: def.group, recommended: recommended, title: def.name,
                     description: description, warning: def.warning, options: options, kind: kind)
    }

    private static func storageText(_ dev: PhoneDevice, _ lang: String) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: lang)
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        func gb(_ mb: Int64) -> String { f.string(from: NSNumber(value: Double(mb) / 1024)) ?? "\(mb / 1024)" }
        return lang == "fr"
            ? "\(gb(dev.storageFreeMb)) Go libres sur \(gb(dev.storageTotalMb)) Go"
            : "\(gb(dev.storageFreeMb)) GB free of \(gb(dev.storageTotalMb)) GB"
    }

    private static let corePrefixes = [
        "android.", "com.android.", "com.google.android.", "com.qualcomm.", "com.qti.", "org.codeaurora.",
        "com.mediatek.", "vendor.", "com.amlogic.", "com.realtek.", "com.broadcom.",
    ]

    /// Preinstalled apps the catalog doesn't know yet, for the "help improve the list" report.
    @MainActor static func unknownSystemApps(_ dev: PhoneDevice) -> [String] {
        dev.enabled.union(dev.disabled)
            .filter { !dev.thirdParty.contains($0) && !dev.isProtected($0) && !isKnown(current, $0) }
            // Google's own apps (com.google.android.apps.*) are worth reporting; its system parts are not.
            .filter { p in p != "android" && (!corePrefixes.contains { p.hasPrefix($0) } || p.hasPrefix("com.google.android.apps.")) }
            .filter { p in
                let l = p.lowercased()
                return !l.contains("overlay") && !l.contains("auto_generated_rro") && !l.hasSuffix("rro")
            }
            .sorted()
    }

}
