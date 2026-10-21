import AppKit
import Foundation
import Observation

// MARK: - Phone info

struct InfoRow: Identifiable {
    var label: String
    var value: String
    var id: String { label }
}

/// Software, updates, beta and boot security, with shortcuts to the phone's own screens and a restart menu.
/// Reading changes nothing; buttons only open screens on the phone, except Restart, which asks first.
@MainActor @Observable
final class PhoneInfoModel {
    static let betaPage = URL(string: "https://www.google.com/android/beta")!

    weak var app: AppModel?
    let device: PhoneDevice
    var isLoading = false
    var info: PhoneInfo?
    var status = ""
    var statusIsError = false
    /// "", "normal", "recovery" or "bootloader": the restart waiting for a yes.
    var pendingRestart = ""

    init(app: AppModel, device: PhoneDevice) {
        self.app = app
        self.device = device
        Task { await refresh() }
    }

    func refresh() async {
        isLoading = true
        info = await PhoneInfo.read(Adb.shared, serial: device.serial)
        isLoading = false
    }

    private static func date(_ d: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Lang.locale
        f.setLocalizedDateFormatFromTemplate(format)
        return f.string(from: d)
    }

    var software: [InfoRow] {
        guard let i = info else { return [] }
        let age = i.patchAgeMonths()
        let ago = age == 0 ? L("Info_ThisMonth") : age == 1 ? L("Info_OneMonth") : L("Info_MonthsAgo", age)
        let version = i.isBeta
            ? L("Info_AndroidBeta", i.androidVersion, i.codename == "REL" ? "" : i.codename).replacingOccurrences(of: " ()", with: "")
            : L("Info_AndroidValue", i.androidVersion)
        return [
            InfoRow(label: L("Info_Android"), value: version),
            InfoRow(label: L("Info_Patch"), value: i.securityPatch.map { L("Info_PatchValue", Self.date($0, "dMMMMyyyy"), ago) } ?? L("Info_Unknown")),
            InfoRow(label: L("Info_Build"), value: i.buildId.isEmpty ? L("Info_Unknown") : i.buildId),
        ]
    }

    var boot: [InfoRow] {
        guard let i = info else { return [] }
        let locked = i.bootloaderLocked.map { $0 ? L("Info_Locked") : L("Info_Unlocked") } ?? L("Info_Unknown")
        return [
            InfoRow(label: L("Info_Bootloader"), value: locked),
            InfoRow(label: L("Info_Verified"), value: Self.verifiedText(i.verifiedBoot)),
        ]
    }

    var betaText: String {
        guard let i = info, i.isBeta else { return L("Info_BetaOff") }
        return L("Info_BetaOn", i.securityPatch.map { Self.date($0, "MMMMyyyy") } ?? L("Info_Unknown"))
    }

    var tips: [HealthTip] {
        guard let i = info else { return [] }
        var tips: [HealthTip] = []
        let age = i.patchAgeMonths()
        if i.isBeta { tips.append(HealthTip(text: L("Info_TipBeta"), kind: .info)) }
        // A beta that is behind says nothing about the maker's support.
        if age >= 6 && !i.isBeta { tips.append(HealthTip(text: L("Info_TipPatchVeryOld", age), kind: .warn)) }
        else if age >= 3 { tips.append(HealthTip(text: L("Info_TipPatchOld", age), kind: .warn)) }
        else if age >= 0 { tips.append(HealthTip(text: L("Info_TipPatchOk"), kind: .ok)) }
        if i.bootloaderLocked == false { tips.append(HealthTip(text: L("Info_TipUnlocked"), kind: .warn)) }
        else if !["", "green"].contains(i.verifiedBoot) { tips.append(HealthTip(text: L("Info_TipNotVerified", Self.verifiedText(i.verifiedBoot)), kind: .warn)) }
        else if i.bootloaderLocked == true && i.verifiedBoot == "green" { tips.append(HealthTip(text: L("Info_TipLocked"), kind: .ok)) }
        return tips
    }

    private static func verifiedText(_ state: String) -> String {
        switch state {
        case "green": L("Info_VbGreen")
        case "yellow": L("Info_VbYellow")
        case "orange": L("Info_VbOrange")
        case "red": L("Info_VbRed")
        default: L("Info_Unknown")
        }
    }

    var confirmText: String {
        switch pendingRestart {
        case "": ""
        case "normal": L("Info_ConfirmNormal")
        case let mode: L("Info_ConfirmMode", L(mode == "recovery" ? "Info_RestartRecovery" : "Info_RestartBootloader").lowercased(with: Lang.locale))
        }
    }

    func openUpdate() async {
        _ = await openOnPhone("am start -a android.settings.SYSTEM_UPDATE_SETTINGS", ok: "Info_UpdateOpened")
    }

    /// Settings, System: "Reset options" is one tap away. Android doesn't let anything else open the reset screen itself.
    func openSystem() async {
        if await !openOnPhone("am start -n 'com.android.settings/.Settings$SystemDashboardActivity'", ok: "Info_SystemOpened") {
            _ = await openOnPhone("am start -a android.settings.SETTINGS", ok: "Info_SystemOpened")
        }
    }

    private func openOnPhone(_ command: String, ok: String) async -> Bool {
        let r = await Adb.shared.shell(device.serial, command)
        let failed = r.all.localizedCaseInsensitiveContains("error") || r.all.contains("Exception")
        statusIsError = failed
        status = failed ? L("Info_OpenFailed", r.all.split(separator: "\n").last.map(String.init) ?? "") : L(ok)
        return !failed
    }

    func openBeta() { NSWorkspace.shared.open(Self.betaPage) }

    func restart() async {
        let mode = pendingRestart
        guard !mode.isEmpty, let app else { return }
        pendingRestart = ""
        var args = ["-s", device.serial, "reboot"]
        if mode != "normal" { args.append(mode) }
        _ = await app.adb.run(args, timeout: 15)
        // The phone is gone until it starts again; the Connect page finds it when it is back.
        if device.isWireless { _ = await app.adb.run(["disconnect", device.serial], timeout: 5) }
        app.device = nil
        app.goConnect()
    }
}

// MARK: - Privacy check-up

@MainActor @Observable
final class AccessRow: Identifiable {
    let access: AppAccess
    let name: String
    var isRemoved = false
    var isWorking = false
    nonisolated let id: String
    var package: String { access.package }

    init(access: AppAccess, name: String) {
        self.access = access
        self.name = name
        id = access.package + "/" + access.kind.key
    }
}

struct AccessGroup: Identifiable {
    var kind: AccessKind
    var rows: [AccessRow]
    var id: String { kind.key }
}

/// Which apps can use location, microphone, camera and personal data, with one click to remove an access.
@MainActor @Observable
final class PrivacyModel {
    let device: PhoneDevice
    var isLoading = false
    var groups: [AccessGroup] = []
    var status = ""
    /// One backup per visit, started on the first removal.
    private var backup: Backup?

    init(device: PhoneDevice) {
        self.device = device
        Task { await refresh() }
    }

    func refresh() async {
        isLoading = true
        let all = await Privacy.read(Adb.shared, device: device)
        func name(_ a: AppAccess) -> String { Catalog.name(of: a.package) ?? a.package }
        groups = Privacy.kinds.compactMap { kind in
            let rows = all.filter { $0.kind == kind }
                .sorted { ($0.isThirdParty ? 0 : 1, name($0).lowercased()) < ($1.isThirdParty ? 0 : 1, name($1).lowercased()) }
                .map { AccessRow(access: $0, name: name($0)) }
            return rows.isEmpty ? nil : AccessGroup(kind: kind, rows: rows)
        }
        isLoading = false
    }

    func remove(_ row: AccessRow) async {
        guard !row.isRemoved, !row.isWorking else { return }
        row.isWorking = true
        status = ""
        let b = backup ?? Backup.start(device)
        backup = b
        var error: String?
        for perm in row.access.granted {
            // Saved before the change, like every other change, so even an interrupted run can be undone.
            b.revokedPermissions.append(PermissionChange(package: row.package, permission: perm))
            try? b.save()
            error = await Privacy.revoke(Adb.shared, serial: device.serial, package: row.package, permission: perm)
            if error == nil { continue }
            b.revokedPermissions.removeLast()
            try? b.save()
            break
        }
        row.isWorking = false
        if let error {
            status = L("Privacy_Failed", row.name, error)
            return
        }
        row.isRemoved = true
        // Removing location also removed "all the time".
        if row.access.kind.key == "Location" {
            for g in groups where g.kind.key == "BgLocation" {
                for r in g.rows where r.package == row.package { r.isRemoved = true }
            }
        }
    }
}
