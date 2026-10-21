import AppKit
import Foundation
import Observation

enum Page { case welcome, connect, choose, apply, restore, info, health, privacy, apps, install }

/// The whole app's state: which page is showing, the connected phone, and each page's model.
@MainActor @Observable
final class AppModel {
    let adb = Adb.shared
    var page: Page = .welcome
    var device: PhoneDevice?

    var welcome = WelcomeModel()
    var connect: ConnectModel!
    var choose: ChooseModel?
    var apply: ApplyModel?
    var restore: RestoreModel?
    var info: PhoneInfoModel?
    var health: HealthModel?
    var privacy: PrivacyModel?
    var apps: AppsModel?
    var install: InstallModel?

    init() {
        connect = ConnectModel(app: self)
    }

    static let steps = ["Step_Prepare", "Step_Connect", "Step_Choose", "Step_Apply"]

    var stepIndex: Int {
        switch page {
        case .welcome: 0
        case .connect: 1
        case .choose, .restore, .info, .health, .privacy, .apps, .install: 2
        case .apply: apply?.isFinished == true ? 4 : 3
        }
    }

    /// Changes are being made to the phone: don't let the user leave the page.
    var isBusy: Bool {
        (page == .apply && apply?.isFinished == false) || (page == .restore && restore?.isBusy == true)
    }

    func canNavigate(toStep n: Int) -> Bool {
        // From a tool page (step 3 too), "Choose" leads back to the list.
        let onTool = [.restore, .info, .health, .privacy, .apps, .install].contains(page)
        return (n < stepIndex || (n == 2 && onTool)) && !isBusy && n < 3 && (n != 2 || device != nil)
    }

    func go(toStep n: Int) {
        guard canNavigate(toStep: n) else { return }
        switch n {
        case 0: page = .welcome
        case 1: goConnect()
        case 2: Task { await goChoose(reload: true) }
        default: break
        }
    }

    func goConnect() {
        connect = ConnectModel(app: self)
        page = .connect
    }

    func goChoose(reload: Bool = false) async {
        guard var dev = device else { goConnect(); return }
        if reload {
            dev = await PhoneDevice.load(adb, serial: dev.serial)
            device = dev
        }
        await Catalog.refreshFromGitHub() // the app may have stayed open since the list changed
        choose = ChooseModel(app: self, device: dev)
        page = .choose
    }

    func goApply(_ selected: [Tweak], reboot: Bool) {
        guard let dev = device else { return }
        ChoiceSet.from(phoneName: dev.displayName, selected: selected).saveAsLast()
        let model = ApplyModel(app: self, device: dev, selected: selected, reboot: reboot)
        apply = model
        page = .apply
        Task { await model.run() }
    }

    func goRestore() {
        guard let dev = device, !isBusy else { return }
        restore = RestoreModel(app: self, device: dev)
        page = .restore
    }

    func goInfo() {
        guard let dev = device, !isBusy else { return }
        info = PhoneInfoModel(app: self, device: dev)
        page = .info
    }

    func goPrivacy() {
        guard let dev = device, !isBusy else { return }
        privacy = PrivacyModel(device: dev)
        page = .privacy
    }

    func goApps() {
        guard let dev = device, !isBusy else { return }
        apps = AppsModel(app: self, device: dev)
        page = .apps
    }

    func goHealth() {
        guard let dev = device, !isBusy else { return }
        health = HealthModel(device: dev)
        page = .health
    }

    func goInstall() {
        guard let dev = device, !isBusy else { return }
        install = InstallModel(device: dev)
        page = .install
    }

    /// Back to the first page with no phone connected, e.g. to clean another one.
    func startOver() async {
        if let d = device, d.isWireless { _ = await adb.run(["disconnect", d.serial], timeout: 5) }
        device = nil
        welcome = WelcomeModel()
        page = .welcome
    }
}

// MARK: - Prepare

@MainActor @Observable
final class WelcomeModel {
    var isDownloading = false
    var progress = 0.0
    var error = ""
    var toolsReady = Adb.shared.isInstalled

    func continueTapped(_ app: AppModel) async {
        error = ""
        if !Adb.shared.isInstalled {
            isDownloading = true
            defer { isDownloading = false; toolsReady = Adb.shared.isInstalled }
            do {
                try await Adb.shared.ensureInstalled { p in Task { @MainActor in self.progress = p * 100 } }
            } catch {
                self.error = L("Welcome_DownloadFailed", error.localizedDescription)
                return
            }
        }
        app.goConnect()
    }
}

// MARK: - Connect

/// A phone adb can see: plugged in, connected over Wi-Fi, or announcing wireless debugging.
struct FoundPhone: Identifiable, Hashable {
    var serial: String
    /// "device", "unauthorized", "offline", or "announced" (wireless debugging is on, not connected yet).
    var state: String
    var name: String
    var isWireless: Bool
    var id: String { serial }
    var canUse: Bool { state == "device" || state == "announced" }
    var detail: String {
        L(state == "unauthorized" ? "Connect_RowApprove" : state == "offline" ? "Connect_RowOffline"
          : isWireless ? "Connect_RowWifi" : "Connect_RowUsb")
    }
}

enum ConnectState { case idle, connecting, waitingForApproval, reading, failed }

@MainActor @Observable
final class ConnectModel {
    weak var app: AppModel?
    var phones: [FoundPhone] = []
    var state: ConnectState = .idle
    var errorDetail = ""
    /// Filled in by itself while the phone shows "Pair device with pairing code".
    var pairAddress = ""
    var pairCode = ""
    var pairResult = ""
    var pairingSeen = false
    var isPairing = false
    var manualAddress = ""
    private var autoPairAddress = ""
    private var pairingName = ""
    private var task: Task<Void, Never>?
    private var watch: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        // Development aid: UMP_CONNECT=<serial> connects straight away.
        if let auto = ProcessInfo.processInfo.environment["UMP_CONNECT"], !auto.isEmpty {
            use(FoundPhone(serial: auto, state: "device", name: auto, isWireless: Adb.isWireless(auto)))
        }
    }

    var isBusy: Bool { [.connecting, .waitingForApproval, .reading].contains(state) }
    var showStatus: Bool { [.connecting, .reading, .failed].contains(state) }

    var statusText: String {
        switch state {
        case .connecting: L("Connect_Connecting")
        case .reading: L("Connect_Reading")
        case .failed: errorDetail
        default: ""
        }
    }

    /// Every two seconds while the page is open: phones plugged in or on Wi-Fi, and an open pairing screen.
    func startWatching() {
        guard watch == nil else { return }
        watch = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopWatching() {
        watch?.cancel()
        watch = nil
    }

    private func refresh() async {
        let adb = Adb.shared
        let devices = await adb.devices()
        let services = await adb.mdnsServices()
        // A phone reached both by address and by its announced name is one phone: keep the name.
        let twice = Set(services.filter { s in !s.pairing && devices.contains { $0.serial.hasPrefix(s.name + ".") } }.map(\.address))
        var rows = devices.filter { !twice.contains($0.serial) }.map {
            FoundPhone(serial: $0.serial, state: $0.state, name: $0.model.isEmpty ? $0.serial : $0.model, isWireless: Adb.isWireless($0.serial))
        }
        // Paired phones with wireless debugging on that adb hasn't connected to yet.
        for s in services where !s.pairing && !devices.contains(where: { $0.serial == s.address || $0.serial.hasPrefix(s.name + ".") }) {
            rows.append(FoundPhone(serial: s.address, state: "announced", name: L("Connect_WifiPhone"), isWireless: true))
        }
        if rows != phones { phones = rows }

        let pairing = services.first(where: \.pairing)
        pairingSeen = pairing != nil
        if let pairing {
            pairingName = pairing.name
            if pairAddress.isEmpty || pairAddress == autoPairAddress {
                autoPairAddress = pairing.address
                pairAddress = pairing.address
            }
        }
    }

    func use(_ phone: FoundPhone) {
        task?.cancel()
        task = Task { await connectNow(phone.serial, connectFirst: phone.state == "announced") }
    }

    func connectManual() {
        guard let target = Self.normalize(manualAddress) else { fail(L("Connect_BadAddress")); return }
        task?.cancel()
        task = Task { await connectNow(target, connectFirst: true) }
    }

    func cancel() {
        task?.cancel()
        state = .idle
    }

    private func connectNow(_ serial: String, connectFirst: Bool) async {
        guard let app else { return }
        state = .connecting
        let adb = app.adb
        if connectFirst {
            let r = await adb.run(["connect", serial], timeout: 20)
            guard r.all.contains("connected to") else { fail(L("Connect_Refused", serial) + "\n" + r.all); return }
        }

        // Wait for "Allow USB debugging?" to be accepted on the phone (up to 3 minutes).
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if Task.isCancelled { state = .idle; return }
            let s = await adb.state(serial)
            if s == "device" { break }
            if s == "unauthorized" { state = .waitingForApproval }
            try? await Task.sleep(for: .milliseconds(1500))
        }
        if Task.isCancelled { state = .idle; return }
        guard await adb.state(serial) == "device" else { fail(L("Connect_ApprovalTimeout")); return }

        state = .reading
        app.device = await PhoneDevice.load(adb, serial: serial)
        stopWatching()
        await app.goChoose()
        // Development aid, with UMP_CONNECT: UMP_PAGE=info|health|privacy|apps|install|restore opens a tool page (read-only).
        switch ProcessInfo.processInfo.environment["UMP_PAGE"] {
        case "info": app.goInfo()
        case "privacy": app.goPrivacy()
        case "apps": app.goApps()
        case "health": app.goHealth()
        case "install": app.goInstall()
        case "restore": app.goRestore()
        default: break
        }
    }

    /// Pair with the code the phone shows, then connect to it straight away.
    func pair() async {
        guard let app else { return }
        pairResult = ""
        let code = pairCode.filter(\.isNumber)
        guard let target = Self.normalize(pairAddress), code.count == 6 else {
            pairResult = L("Connect_PairBadInput")
            return
        }
        isPairing = true
        defer { isPairing = false }
        let r = await app.adb.run(["pair", target, code], timeout: 30)
        guard r.all.contains("Successfully paired") else {
            pairResult = L("Connect_PairFailed") + "\n" + r.all
            return
        }
        pairResult = L("Connect_PairOk")
        pairCode = ""

        // The phone now announces its debugging port under the same name; adb usually connects by itself.
        let name = target == autoPairAddress ? pairingName : ""
        let host = String(target[..<target.lastIndex(of: ":")!])
        for _ in 0..<15 {
            if let ready = await app.adb.devices().first(where: {
                $0.state == "device" && ((!name.isEmpty && $0.serial.hasPrefix(name + ".")) || $0.serial.hasPrefix(host + ":"))
            }) {
                await connectNow(ready.serial, connectFirst: false)
                return
            }
            if let svc = await app.adb.mdnsServices().first(where: {
                !$0.pairing && ((!name.isEmpty && $0.name == name) || $0.address.hasPrefix(host + ":"))
            }) {
                await connectNow(svc.address, connectFirst: true)
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        pairResult = L("Connect_PairOkNoPort")
    }

    private func fail(_ message: String) {
        errorDetail = message
        state = .failed
    }

    /// "192.168.1.20:41234". Wireless debugging always uses its own port, so it is required.
    /// Accepts a comma typed instead of a dot.
    static func normalize(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")
        guard let colon = s.lastIndex(of: ":"), let port = Int(s[s.index(after: colon)...]), (1...65535).contains(port) else { return nil }
        let parts = s[..<colon].split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else { return nil }
        return "\(parts.map { String(Int($0)!) }.joined(separator: ".")):\(port)"
    }
}

// MARK: - Choose

@MainActor @Observable
final class ChooseModel {
    weak var app: AppModel?
    let device: PhoneDevice
    let groups: [TweakGroup]
    let unknownApps: [String]
    var rebootAfter = true
    var lastChoices: ChoiceSet?
    var choicesStatus = ""
    /// Things earlier runs changed that are back (usually after a system update).
    var returned: ReturnedItems?

    init(app: AppModel, device: PhoneDevice) {
        self.app = app
        self.device = device
        groups = Catalog.build(device)
        unknownApps = Catalog.unknownSystemApps(device)
        lastChoices = ChoiceSet.loadLast()
        Task { await checkReturned() }
    }

    private func checkReturned() async {
        guard let r = await ReturnedItems.find(Adb.shared, device: device), !matchingTweaks(r).isEmpty else { return }
        returned = r
        lastChoices = nil // one suggestion at a time
    }

    private func matchingTweaks(_ r: ReturnedItems) -> [(Tweak, SettingChange?)] {
        allTweaks.compactMap { t in
            if let p = t.packageName, r.packages.contains(p) { return (t, nil) }
            if let s = r.settings.first(where: { t.settingKeys.contains($0.key) }) { return (t, s) }
            return nil
        }
    }

    /// Counts only what can be ticked again, so they match the list below.
    var returnedText: String {
        guard let r = returned else { return "" }
        let matches = matchingTweaks(r)
        return L("Choose_ReturnedText", DateText.display(r.since),
                 matches.filter { $0.1 == nil }.count, matches.filter { $0.1 != nil }.count)
    }

    var returnedNames: [String] {
        guard let r = returned else { return [] }
        return matchingTweaks(r).map { $0.0.title.text }
    }

    /// Tick exactly what came back, with the values chosen last time.
    func tickReturned() {
        guard let r = returned else { return }
        let matches = matchingTweaks(r)
        for t in allTweaks { t.isSelected = false }
        for (t, setting) in matches {
            t.isSelected = true
            // Pick the option that gives the value set last time ("16" or "max_cached_processes=16").
            if let s = setting, let o = t.options.first(where: { s.newValue == $0.value || s.newValue.hasSuffix("=" + $0.value) }) {
                t.selectedOption = o.value
            }
        }
        choicesStatus = L("Choose_ReturnedTicked", matches.count)
        returned = nil
    }

    var allTweaks: [Tweak] { groups.flatMap(\.tweaks) }
    var selected: [Tweak] { allTweaks.filter(\.isSelected) }
    var selectedCount: Int { selected.count }
    var selectedText: String { selectedCount == 1 ? L("Choose_SelectedOne") : L("Choose_Selected", selectedCount) }

    var infoLine: String {
        var parts = [L("Choose_Android", device.androidVersion), L("Choose_Ram", Self.oneDecimal(Double(device.ramMb) / 1024))]
        if device.storageTotalMb > 0 { parts.append(L("Choose_Storage", Self.oneDecimal(Double(device.storageFreeMb) / 1024))) }
        if !device.disabled.isEmpty {
            parts.append(device.disabled.count == 1 ? L("Choose_AlreadyOffOne") : L("Choose_AlreadyOff", device.disabled.count))
        }
        return parts.joined(separator: "  ·  ")
    }

    static func oneDecimal(_ v: Double) -> String {
        let f = NumberFormatter()
        f.locale = Lang.locale
        f.maximumFractionDigits = 1
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// A chosen option that needs an app unticks turning that app off.
    func enforceKeeps(_ tweak: Tweak) {
        let kept = tweak.keptPackages
        guard !kept.isEmpty else { return }
        for t in allTweaks where t.packageName.map(kept.contains) == true { t.isSelected = false }
    }

    func selectRecommended() {
        for t in allTweaks { t.isSelected = t.recommended }
        choicesStatus = ""
    }

    func selectNone() {
        for t in allTweaks { t.isSelected = false }
        choicesStatus = ""
    }

    func use(_ set: ChoiceSet) {
        let found = set.apply(to: allTweaks)
        let missing = set.choices.count - found
        choicesStatus = missing == 0 ? L("Choose_UsedAll", found) : L("Choose_UsedSome", found, missing)
    }

    func useLastChoices() {
        if let set = lastChoices { use(set) }
        lastChoices = nil
    }

    var currentChoices: ChoiceSet { ChoiceSet.from(phoneName: device.displayName, selected: selected) }

    func reportUnknown() {
        let (url, complete) = IssueReport.build(device, packages: unknownApps, catalogVersion: Catalog.version)
        if !complete { copyUnknown() }
        NSWorkspace.shared.open(url)
    }

    func copyUnknown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(unknownApps.joined(separator: "\n"), forType: .string)
    }
}

// MARK: - Apply

enum StepState { case pending, running, done, failed, skipped }

@Observable
final class StepItem: Identifiable {
    let id = UUID()
    var text: String
    var detail = ""
    var state: StepState = .pending
    init(_ text: String) { self.text = text }
}

@MainActor @Observable
final class ApplyModel {
    weak var app: AppModel?
    private(set) var device: PhoneDevice
    let selected: [Tweak]
    let reboot: Bool

    var items: [StepItem] = []
    var isFinished = false
    var problemCount = 0
    var progress = 0.0
    var backupPath = ""
    var appsOff = 0
    var settingsChanged = 0
    var debugOff = false
    var isTurningOffDebug = false
    var debugStatus = ""

    init(app: AppModel, device: PhoneDevice, selected: [Tweak], reboot: Bool) {
        self.app = app; self.device = device; self.selected = selected; self.reboot = reboot
    }

    var hasProblems: Bool { problemCount > 0 }
    var title: String { !isFinished ? L("Apply_Working") : hasProblems ? L("Apply_DoneWithProblems") : L("Apply_DoneTitle") }
    var subtitle: String { !isFinished ? L("Apply_WorkingSub") : hasProblems ? L("Apply_ProblemsSub", problemCount) : L("Apply_DoneSub") }
    var checkValue: String { hasProblems ? "\(problemCount)" : "OK" }
    var checkLabel: String { L(hasProblems ? "Apply_StatProblems" : reboot ? "Apply_StatChecks" : "Apply_StatChecksNoReboot") }

    private func add(_ text: String) -> StepItem {
        let s = StepItem(text)
        items.append(s)
        return s
    }

    func run() async {
        guard let app else { return }
        let adb = app.adb
        let backupStep = add(L("Apply_Backup"))
        let tweakSteps = selected.map { ($0, add($0.title.text)) }
        let rebootStep = reboot ? add(L("Apply_Reboot")) : nil
        let checkStep = add(L("Apply_Check"))
        let total = Double(items.count)
        var done = 0.0
        func tick() { done += 1; progress = 100 * done / total }

        // 1. Backup. No backup, no changes.
        backupStep.state = .running
        let backup = Backup.start(device)
        do {
            try backup.save()
            await saveSnapshot(backup)
            backupPath = backup.fileURL.deletingLastPathComponent().path
            backupStep.state = .done
        } catch {
            backupStep.detail = error.localizedDescription
            backupStep.state = .failed
            for (_, s) in tweakSteps { s.state = .skipped }
            problemCount = 1
            isFinished = true
            return
        }
        tick()

        // 2. Changes, packages first.
        let ctx = ApplyContext(adb: adb, device: device, backup: backup)
        let kept = Set(selected.flatMap(\.keptPackages))
        for (tweak, step) in tweakSteps.sorted(by: { $0.0.isPackage && !$1.0.isPackage }) {
            if let pkg = tweak.packageName, kept.contains(pkg) {
                // A choice in the same run needs this app: leave it on.
                step.detail = L("Apply_Kept")
                step.state = .skipped
                tick()
                continue
            }
            step.state = .running
            let r = await tweak.apply(ctx)
            step.detail = r.detail
            step.state = r.success ? .done : .failed
            if !r.success { problemCount += 1 }
            else if tweak.isPackage { appsOff += 1 }
            else if !tweak.isMaintenance { settingsChanged += 1 }
            try? backup.save()
            tick()
        }

        // 3. Restart and wait for the phone to come back.
        if let rebootStep {
            rebootStep.state = .running
            let back = await rebootAndWait(rebootStep)
            rebootStep.state = back ? .done : .failed
            if !back { problemCount += 1 }
            tick()
        }

        // 4. Check the essentials: home screen, internet, name lookups.
        checkStep.state = .running
        let problems = await check()
        checkStep.detail = problems.isEmpty ? L("Apply_CheckOk") : problems.joined(separator: "\n")
        checkStep.state = problems.isEmpty ? .done : .failed
        if !problems.isEmpty { problemCount += 1 }
        tick()

        isFinished = true
        device = await PhoneDevice.load(adb, serial: device.serial)
        app.device = device
    }

    /// Raw lists of packages and settings next to the change file, for reference.
    private func saveSnapshot(_ backup: Backup) async {
        guard let adb = app?.adb else { return }
        var parts: [String] = []
        for (title, cmd) in [("packages (all)", "pm list packages --user 0 -f"), ("packages (disabled)", "pm list packages --user 0 -d"),
                             ("settings global", "settings list global"), ("settings secure", "settings list secure"),
                             ("settings system", "settings list system")] {
            let r = await adb.shell(device.serial, cmd, timeout: 30)
            parts.append("===== \(title) =====\n\(r.output)")
        }
        let name = backup.fileURL.lastPathComponent.replacingOccurrences(of: "changes-", with: "snapshot-")
            .replacingOccurrences(of: ".json", with: ".txt")
        try? parts.joined(separator: "\n").write(to: backup.fileURL.deletingLastPathComponent().appendingPathComponent(name),
                                                 atomically: true, encoding: .utf8)
    }

    private func rebootAndWait(_ step: StepItem) async -> Bool {
        guard let adb = app?.adb else { return false }
        _ = await adb.run(["-s", device.serial, "reboot"], timeout: 15)
        try? await Task.sleep(for: .seconds(8))
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            // Over Wi-Fi the phone comes back on another port.
            if let serial = await adb.findAgain(device.serial, serialNo: device.serialNo) {
                guard await adb.shell(serial, "getprop sys.boot_completed", timeout: 8).output
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "1" else {
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }
                step.detail = L("Apply_RebootSettle")
                try? await Task.sleep(for: .seconds(20)) // let apps and the network settle
                step.detail = ""
                if serial != device.serial { device = await PhoneDevice.load(adb, serial: serial) }
                return true
            }
            try? await Task.sleep(for: .seconds(3))
        }
        step.detail = L("Apply_RebootTimeout")
        return false
    }

    private func check() async -> [String] {
        guard let adb = app?.adb else { return [] }
        let serial = device.serial
        var problems: [String] = []
        if await PhoneDevice.currentHome(adb, serial: serial).isEmpty { problems.append(L("Apply_CheckNoHome")) }
        let ip = await adb.shell(serial, "ping -c 1 -W 3 8.8.8.8", timeout: 10)
        if !ip.output.contains(" 0% packet loss") { problems.append(L("Apply_CheckNoInternet")) }
        else if !(await adb.shell(serial, "ping -c 1 -W 3 connectivitycheck.gstatic.com", timeout: 10)).output.contains("PING ") {
            problems.append(L("Apply_CheckNoDns"))
        }
        return problems
    }

    func openBackupFolder() {
        guard !backupPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: backupPath))
    }

    /// Turns USB and wireless debugging off. adbd stops as soon as the setting is written, so success
    /// is "the phone no longer answers", not the command's output.
    func turnOffDebugging() async {
        guard let app else { return }
        isTurningOffDebug = true
        debugStatus = ""
        defer { isTurningOffDebug = false }
        let serial = device.serial
        _ = await app.adb.shell(serial, "settings put global adb_wifi_enabled 0; settings put global adb_enabled 0", timeout: 8)
        try? await Task.sleep(for: .seconds(3))
        let wireless = Adb.isWireless(serial)
        if wireless {
            _ = await app.adb.run(["disconnect", serial], timeout: 5)
            _ = await app.adb.run(["connect", serial], timeout: 8)
        }
        debugOff = await app.adb.state(serial) != "device"
        if debugOff {
            if wireless { _ = await app.adb.run(["disconnect", serial], timeout: 5) }
            app.device = nil
        }
        debugStatus = L(debugOff ? "Apply_DebugOffDone" : "Apply_DebugOffFailed")
    }
}

// MARK: - Restore

@MainActor @Observable
final class RestoreModel {
    weak var app: AppModel?
    private(set) var device: PhoneDevice
    var backups: [Backup] = []
    var isBusy = false
    var status = ""
    var statusIsError = false

    init(app: AppModel, device: PhoneDevice) {
        self.app = app
        self.device = device
        backups = Backup.list(for: device)
    }

    func summary(_ b: Backup) -> String {
        L("Restore_Summary", b.disabledPackages.count, b.settings.count, b.revokedPermissions.count)
    }

    /// Undo one run: re-enable its apps, put every setting back as it was, and give back removed accesses.
    func restore(_ b: Backup) async {
        await runBusy { adb, serial in
            for pkg in b.disabledPackages { _ = await adb.shell(serial, "pm enable --user 0 \(pkg)") }
            for s in b.settings.reversed() { await SettingsIO.restore(adb, serial, s.namespace, s.key, s.oldValue) }
            for pkg in b.enabledPackages { _ = await adb.shell(serial, "pm disable-user --user 0 \(pkg)") }
            for p in b.revokedPermissions { _ = await adb.shell(serial, "pm grant --user 0 \(p.package) \(p.permission)") }
            // Keep the file for reference, but stop offering it.
            let renamed = b.fileURL.deletingLastPathComponent()
                .appendingPathComponent(b.fileURL.lastPathComponent.replacingOccurrences(of: "changes-", with: "restored-"))
            try? FileManager.default.removeItem(at: renamed)
            try? FileManager.default.moveItem(at: b.fileURL, to: renamed)
            return L("Restore_Done")
        }
    }

    /// Safety net: re-enable every app disabled by a user (not the ones the maker turned off).
    func enableAll() async {
        let disabled = device.disabled
        await runBusy { adb, serial in
            var count = 0
            for pkg in disabled.sorted() {
                // enabled=3 is COMPONENT_ENABLED_STATE_DISABLED_USER, i.e. disabled by someone, not by the firmware.
                let state = await adb.shell(serial, "dumpsys package \(pkg) | grep -m1 -oE 'enabled=[0-9]'")
                guard state.output.contains("enabled=3") else { continue }
                _ = await adb.shell(serial, "pm enable --user 0 \(pkg)")
                count += 1
            }
            return L("Restore_AllDone", count)
        }
    }

    private func runBusy(_ work: (Adb, String) async -> String) async {
        guard let app else { return }
        isBusy = true
        status = ""
        statusIsError = false
        status = await work(app.adb, device.serial)
        device = await PhoneDevice.load(app.adb, serial: device.serial)
        app.device = device
        backups = Backup.list(for: device)
        isBusy = false
    }
}
