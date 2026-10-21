import Foundation

/// An app the owner installed, with what the phone says about it.
struct InstalledApp {
    var package: String
    var version: String
    /// The app store or app that installed it ("com.android.vending" for Google Play); "" when unknown.
    var installer: String
    var installed: Date?
    var updated: Date?
    var appBytes: Int64
    var dataBytes: Int64
    var cacheBytes: Int64
    var isEnabled: Bool
    var hasIcon: Bool

    var totalBytes: Int64 { appBytes + dataBytes + cacheBytes }
    var fromPlay: Bool { installer == "com.android.vending" }
    /// A website added to the home screen. Chrome's ("WebAPKs") are made by Google Play and show no installer.
    var isWebApp: Bool { installer == "com.android.chrome" || package.hasPrefix("org.chromium.webapk.") }
}

/// The apps installed by the phone's owner (not the work profile), and what can be done with them. Same rules as the Windows app.
enum UserApps {
    static let archiveMinSdk = 35

    /// Reading changes nothing.
    static func read(_ adb: Adb, serial: String) async -> [InstalledApp] {
        // Listed again rather than taken from the device: apps may have come and gone since it was read.
        let ours = await list(adb, serial, "-3")
        let off = await list(adb, serial, "-d")

        let launcher = await adb.shell(serial,
            "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER", timeout: 30).output
        let withIcon = Set(launcher.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("/") && !$0.contains(" ") }
            .map { String($0.split(separator: "/")[0]) })

        let dump = await adb.shell(serial,
            "dumpsys package packages | grep -E '^Hidden|^  Package \\[|^    versionName=|^    lastUpdateTime=|" +
            "^    installerPackageName=|^    User [0-9]+:|^      firstInstallTime='", timeout: 60).output
            .replacingOccurrences(of: "\r", with: "")
        let text = "\n" + (dump.components(separatedBy: "\nHidden").first ?? "")
        var facts: [String: (version: String, installer: String, installed: Date?, updated: Date?)] = [:]
        for block in text.components(separatedBy: "\n  Package [").dropFirst() {
            guard let end = block.firstIndex(of: "]") else { continue }
            let pkg = String(block[..<end])
            guard ours.contains(pkg) else { continue }
            // The install date is per user: the owner's is the first one after "User 0:".
            let user0 = block.range(of: "\n    User 0:").map { String(block[$0.lowerBound...]) } ?? ""
            let installer = field(block, "installerPackageName")
            facts[pkg] = (field(block, "versionName"), installer == "null" ? "" : installer,
                          date(field(user0, "firstInstallTime")), date(field(block, "lastUpdateTime")))
        }

        let sizes = await readSizes(adb, serial)
        return ours.map { pkg in
            let f = facts[pkg] ?? ("", "", nil, nil)
            let s = sizes[pkg] ?? (0, 0, 0)
            return InstalledApp(package: pkg, version: f.version, installer: f.installer, installed: f.installed, updated: f.updated,
                                appBytes: s.app, dataBytes: s.data, cacheBytes: s.cache,
                                isEnabled: !off.contains(pkg), hasIcon: withIcon.contains(pkg))
        }
    }

    /// Sizes from "dumpsys diskstats", which the phone works out from time to time (not live).
    /// "Package Names: [...]", then "App Sizes", "App Data Sizes" and "Cache Sizes" in the same order.
    private static func readSizes(_ adb: Adb, _ serial: String) async -> [String: (app: Int64, data: Int64, cache: Int64)] {
        let out = await adb.shell(serial, "dumpsys diskstats", timeout: 30).output
        func list(_ name: String) -> [String] {
            guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix(name + ": [") }),
                  let open = line.firstIndex(of: "["), let close = line.lastIndex(of: "]") else { return [] }
            return line[line.index(after: open)..<close].split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
        }
        func at(_ l: [String], _ i: Int) -> Int64 { i < l.count ? Int64(l[i]) ?? 0 : 0 }

        let names = list("Package Names"), app = list("App Sizes"), data = list("App Data Sizes"), cache = list("Cache Sizes")
        var result: [String: (Int64, Int64, Int64)] = [:]
        for (i, n) in names.enumerated() { result[n] = (at(app, i), at(data, i), at(cache, i)) }
        return result
    }

    private static func list(_ adb: Adb, _ serial: String, _ flag: String) async -> Set<String> {
        let r = await adb.shell(serial, "pm list packages --user 0 \(flag)", timeout: 30)
        return Set(r.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("package:") }
            .map { String($0.dropFirst("package:".count)) })
    }

    private static func field(_ block: String, _ name: String) -> String {
        guard let r = block.range(of: "\(name)=") else { return "" }
        return String(block[r.upperBound...].prefix { $0 != "\n" }).trimmingCharacters(in: .whitespaces)
    }

    /// "2025-09-11 13:37:13" in the phone's time. Never-set dates read as 1970 (or the day before, west of Greenwich).
    private static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let d = f.date(from: s), Calendar.current.component(.year, from: d) > 1970 else { return nil }
        return d
    }

    // Each returns nil when it worked, else the phone's answer.

    /// Starts the app on the phone, as if its icon was tapped.
    static func open(_ adb: Adb, _ serial: String, _ pkg: String) async -> String? {
        await run(adb, serial, "monkey -p \(pkg) -c android.intent.category.LAUNCHER 1", expected: "Events injected: 1")
    }

    /// The app's page in the phone's Settings (storage, notifications, battery…).
    static func showInfo(_ adb: Adb, _ serial: String, _ pkg: String) async -> String? {
        await run(adb, serial, "am start -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:\(pkg)")
    }

    static func stop(_ adb: Adb, _ serial: String, _ pkg: String) async -> String? {
        await run(adb, serial, "am force-stop --user 0 \(pkg)")
    }

    static func setEnabled(_ adb: Adb, _ serial: String, _ pkg: String, on: Bool) async -> String? {
        await run(adb, serial, on ? "pm enable --user 0 \(pkg)" : "pm disable-user --user 0 \(pkg)", expected: "new state:")
    }

    /// For the owner only: the same app in the work profile stays.
    static func uninstall(_ adb: Adb, _ serial: String, _ pkg: String) async -> String? {
        await run(adb, serial, "pm uninstall --user 0 \(pkg)", expected: "Success")
    }

    /// Android 15 and later: removes the app but keeps its data and its icon. Tapping the icon
    /// downloads it again from the store that installed it.
    static func archive(_ adb: Adb, _ serial: String, _ pkg: String) async -> String? {
        await run(adb, serial, "pm archive --user 0 \(pkg)")
    }

    private static func run(_ adb: Adb, _ serial: String, _ command: String, expected: String? = nil) async -> String? {
        let r = await adb.shell(serial, command, timeout: 60)
        let all = r.all
        let failed = !r.ok || all.contains("Exception") || all.localizedCaseInsensitiveContains("error") || all.contains("Failure")
            || (expected.map { !all.contains($0) } ?? false)
        guard failed else { return nil }
        return all.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? all
    }
}
