import Foundation

/// What we know about the connected phone. Read-only queries only.
struct PhoneDevice: Sendable {
    var serial: String
    var manufacturer = ""
    var brand = ""
    var model = ""
    var serialNo = ""
    var androidVersion = ""
    var sdk = 0
    var ramMb: Int64 = 0
    var homePackage = ""
    /// Every app that can act as the home screen, not just the current one.
    var homeCapable: Set<String> = []
    var inputMethodPackage = ""
    /// The default Phone and SMS apps: turning them off would leave the phone unable to call or text.
    var roleHolders: Set<String> = []
    var setupComplete = false
    var storageTotalMb: Int64 = 0
    var storageFreeMb: Int64 = 0
    var enabled: Set<String> = []
    var disabled: Set<String> = []
    var thirdParty: Set<String> = []

    func isInstalled(_ pkg: String) -> Bool { enabled.contains(pkg) || disabled.contains(pkg) }

    var displayName: String {
        var maker = manufacturer.trimmingCharacters(in: .whitespaces).isEmpty ? brand : manufacturer
        if let first = maker.first { maker = first.uppercased() + maker.dropFirst() }
        return maker.isEmpty || model.lowercased().hasPrefix(maker.lowercased()) ? model : "\(maker) \(model)"
    }

    /// Connected over Wi-Fi ("192.168.1.20:41234", or the name wireless debugging announces).
    var isWireless: Bool { Adb.isWireless(serial) }

    /// Shown under the phone's name: its address on Wi-Fi, "USB" otherwise.
    var connectionText: String {
        guard isWireless else { return "USB" }
        guard let i = serial.lastIndex(of: ":") else { return "Wi-Fi" }
        return String(serial[..<i])
    }

    /// Packages that must never be disabled, whatever the catalog says.
    func isProtected(_ pkg: String) -> Bool {
        pkg == homePackage || homeCapable.contains(pkg) || pkg == inputMethodPackage || roleHolders.contains(pkg)
            || Self.protectedPackages.contains(pkg)
    }

    static let protectedPackages: Set<String> = [
        "android", "com.android.systemui", "com.android.settings", "com.android.providers.settings",
        "com.android.shell", "com.android.packageinstaller", "com.google.android.packageinstaller",
        "com.google.android.gms", "com.google.android.gsf", "com.android.vending",
        "com.google.android.webview", "com.android.webview", "com.google.android.trichromelibrary",
        "com.google.android.permissioncontroller", "com.android.permissioncontroller",
        "com.android.phone", "com.android.server.telecom", "com.android.providers.telephony",
        "com.android.providers.contacts", "com.android.providers.media.module", "com.google.android.providers.media.module",
        "com.android.bluetooth", "com.google.android.bluetooth", "com.android.nfc", "com.android.se",
        "com.google.android.networkstack", "com.google.android.networkstack.tethering", "com.android.networkstack.tethering",
        "com.google.android.cellbroadcastreceiver", "com.google.android.cellbroadcastservice", "com.android.cellbroadcastreceiver",
        "com.android.emergency", "com.google.android.apps.nexuslauncher", "com.android.launcher3",
        "com.google.android.inputmethod.latin", "com.android.inputdevices", "com.android.keychain",
        "com.google.android.documentsui", "com.android.documentsui", "com.android.externalstorage",
        "com.google.android.ext.services", "com.google.android.ext.shared", "com.android.location.fused",
    ]

    static func load(_ adb: Adb, serial: String) async -> PhoneDevice {
        var d = PhoneDevice(serial: serial)
        let props = await adb.shell(serial,
            "getprop ro.product.manufacturer; getprop ro.product.brand; getprop ro.product.model; " +
            "getprop ro.serialno; getprop ro.build.version.release; getprop ro.build.version.sdk")
        let p = props.output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func prop(_ i: Int) -> String { i < p.count ? p[i] : "" }
        d.manufacturer = prop(0); d.brand = prop(1); d.model = prop(2)
        d.serialNo = prop(3); d.androidVersion = prop(4); d.sdk = Int(prop(5)) ?? 0

        let mem = await adb.shell(serial, "grep MemTotal /proc/meminfo")
        d.ramMb = (Int64(mem.output.filter(\.isNumber)) ?? 0) / 1024

        d.homePackage = await currentHome(adb, serial: serial)
        let homes = await adb.shell(serial,
            "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME")
        d.homeCapable = Set(homes.output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("/") && !$0.contains("=") && !$0.contains(" ") }
            .map { String($0.split(separator: "/")[0]) })

        let ime = await adb.shell(serial, "settings get secure default_input_method").output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        d.inputMethodPackage = ime.contains("/") ? String(ime.split(separator: "/")[0]) : ""

        let roles = await adb.shell(serial,
            "cmd role get-role-holders android.app.role.DIALER; cmd role get-role-holders android.app.role.SMS").output
        d.roleHolders = Set(roles.split(whereSeparator: { $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains(".") && !$0.contains(" ") })

        d.setupComplete = await adb.shell(serial, "settings get secure user_setup_complete").output
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1"

        let storage = await readStorage(adb, serial: serial)
        d.storageTotalMb = storage.totalMb
        d.storageFreeMb = storage.freeMb

        d.enabled = await listPackages(adb, serial: serial, flag: "-e")
        d.disabled = await listPackages(adb, serial: serial, flag: "-d")
        d.thirdParty = await listPackages(adb, serial: serial, flag: "-3")
        return d
    }

    static func currentHome(_ adb: Adb, serial: String) async -> String {
        let r = await adb.shell(serial,
            "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME")
        let line = r.output.split(separator: "\n").last.map(String.init) ?? ""
        return line.contains("/") ? String(line.split(separator: "/")[0]).trimmingCharacters(in: .whitespaces) : ""
    }

    /// Size and free space of the app storage (/data), from "df -k". Zeros if unreadable.
    static func readStorage(_ adb: Adb, serial: String) async -> (totalMb: Int64, freeMb: Int64) {
        let r = await adb.shell(serial, "df -k /data")
        let last = r.output.split(separator: "\n").last.map(String.init) ?? ""
        let cols = last.split(separator: " ")
        // Filesystem 1K-blocks Used Available Use% Mounted-on
        guard cols.count >= 4, let total = Int64(cols[1]), let free = Int64(cols[3]) else { return (0, 0) }
        return (total / 1024, free / 1024)
    }

    private static func listPackages(_ adb: Adb, serial: String, flag: String) async -> Set<String> {
        let r = await adb.shell(serial, "pm list packages \(flag)", timeout: 30)
        return Set(r.output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("package:") }
            .map { String($0.dropFirst("package:".count)) })
    }
}
