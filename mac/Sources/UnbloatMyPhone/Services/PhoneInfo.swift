import Foundation

/// Software, update and boot security facts about the phone. Read-only. Same readings as the Windows app.
struct PhoneInfo {
    var androidVersion = ""
    /// "REL" on a normal release, a dessert name ("CinnamonBun") on a preview or beta.
    var codename = ""
    var buildId = ""
    var securityPatch: Date?
    var isBeta = false
    /// Nil when the phone doesn't say (not every maker sets these).
    var bootloaderLocked: Bool?
    /// "green" (original software, verified), "yellow" (own signing key), "orange" (unlocked), "red", or "".
    var verifiedBoot = ""

    /// Whole months between the security patch and today; -1 if unknown.
    func patchAgeMonths(today: Date = Date()) -> Int {
        guard let p = securityPatch else { return -1 }
        return max(0, Calendar(identifier: .gregorian).dateComponents([.month], from: p, to: today).month ?? 0)
    }

    static func read(_ adb: Adb, serial: String) async -> PhoneInfo {
        let keys = [
            "ro.build.version.release", "ro.build.version.codename", "ro.build.display.id", "ro.build.version.security_patch",
            "ro.product.name", "ro.boot.flash.locked", "ro.boot.vbmeta.device_state", "ro.boot.verifiedbootstate",
        ]
        let out = await adb.shell(serial, keys.map { "echo \"\($0)=$(getprop \($0))\"" }.joined(separator: "; ")).output
        var props: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { props[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        func p(_ k: String) -> String { props[k] ?? "" }

        var info = PhoneInfo()
        info.androidVersion = p("ro.build.version.release")
        info.codename = p("ro.build.version.codename")
        info.buildId = p("ro.build.display.id")
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        info.securityPatch = f.date(from: p("ro.build.version.security_patch"))
        // Pixel betas also say so in the product name ("cheetah_beta").
        info.isBeta = (!info.codename.isEmpty && info.codename != "REL") || p("ro.product.name").hasSuffix("_beta")
        switch p("ro.boot.flash.locked") {
        case "1": info.bootloaderLocked = true
        case "0": info.bootloaderLocked = false
        default:
            switch p("ro.boot.vbmeta.device_state") {
            case "locked": info.bootloaderLocked = true
            case "unlocked": info.bootloaderLocked = false
            default: info.bootloaderLocked = nil
            }
        }
        info.verifiedBoot = p("ro.boot.verifiedbootstate")
        return info
    }
}
