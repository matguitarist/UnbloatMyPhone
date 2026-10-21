import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum PhoneMode { case none, android, bootloader, fastbootd, recovery, sideload }

/// A line in an image list: one of Google's images, or a file picked on this computer.
struct ImageChoice: Hashable, Identifiable {
    var image: PixelImage?
    var file: URL?
    var label: String
    var id: String { image?.url.absoluteString ?? file?.path ?? label }
    var fileName: String { image?.fileName ?? file?.lastPathComponent ?? "" }
}

/// Flash and repair, for Pixel phones: official updates and betas, factory images, bootloader lock, and custom
/// images. Works with the phone in Android, recovery or bootloader mode: it is followed by its serial number,
/// which stays the same in every mode. Every job waits for a yes on the page first.
@MainActor @Observable
final class FlashModel: FlashLog {
    weak var app: AppModel?
    let serialNo: String
    let name: String

    var mode = PhoneMode.none
    var codename = ""
    /// From Android ("Google" on a Pixel); unknown in bootloader mode.
    var manufacturer = ""
    /// Nil until the phone says: from ro.boot.flash.locked in Android, or the bootloader itself.
    var unlocked: Bool?
    var oemAllowed: Bool?
    var build = ""
    /// Reached over Wi-Fi only: the phone leaves Wi-Fi when it restarts, so jobs need a cable.
    var wifiOnly = false
    var batteryOk = true

    var isRunning = false
    var status = ""
    var statusIsError = false
    var statusIsDone = false
    var progressValue: Double?
    var canStop = false
    var log: [String] = []

    var termsAccepted = UserDefaults.standard.bool(forKey: "acceptedImageTerms")
    var loadingImages = false
    var imagesFailed = false
    private var images: [PixelImage] = []
    var showOlder = false { didSet { fillChoices() } }
    var otaChoices: [ImageChoice] = []
    var factoryChoices: [ImageChoice] = []
    var selectedOta: ImageChoice?
    var selectedFactory: ImageChoice?
    var wipe = true { didSet { if !wipe { lockAfter = false } } }
    var lockAfter = false { didSet { if lockAfter { wipe = true } } }

    var partition = "boot"
    var bothSlots = false
    var disableVerity = false
    var customFile: URL?
    var zipFile: URL?

    /// "", "ota", "factory", "unlock", "lock", "image", "boot" or "zip": waiting for a yes.
    var pending = ""

    private var watch: Task<Void, Never>?
    private var job: Task<Void, Never>?
    private var loadedFor = ""

    init(app: AppModel, serialNo: String, name: String) {
        self.app = app
        self.serialNo = serialNo
        self.name = name
    }

    // MARK: What the page shows

    var found: Bool { mode != .none }
    var inAndroid: Bool { mode == .android }
    var inBootloader: Bool { mode == .bootloader || mode == .fastbootd }
    var notPixel: Bool { !manufacturer.isEmpty && manufacturer.lowercased() != "google" }
    var isUnlocked: Bool { unlocked == true }
    var isLocked: Bool { unlocked == false }
    var oemOff: Bool { oemAllowed == false && unlocked == false }
    var canAct: Bool { found && !isRunning && batteryOk }
    var canOta: Bool { canAct && selectedOta != nil }
    var canFactory: Bool { canAct && isUnlocked && selectedFactory != nil }
    var canCustom: Bool { canAct && isUnlocked }
    var canUnlock: Bool { canAct && isLocked && oemAllowed != false }
    var canLock: Bool { canAct && isUnlocked && Flasher.canLock(serialNo) }

    var modeText: String {
        switch mode {
        case .android: L("Flash_ModeAndroid")
        case .bootloader: L("Flash_ModeBootloader")
        case .fastbootd: L("Flash_ModeFastbootd")
        case .recovery: L("Flash_ModeRecovery")
        case .sideload: L("Flash_ModeSideload")
        case .none: L("Flash_ModeNone")
        }
    }
    var lockText: String { unlocked.map { $0 ? L("Flash_Unlocked") : L("Flash_Locked") } ?? L("Flash_SeeInBootloader") }
    var oemText: String { oemAllowed.map { $0 ? L("Flash_OemOn") : L("Flash_OemOff") } ?? L("Flash_SeeInBootloader") }

    var confirmText: String {
        switch pending {
        case "ota": L("Flash_OtaConfirm", selectedOta?.label ?? "")
        case "factory": L(wipe ? "Flash_FactoryConfirmWipe" : "Flash_FactoryConfirm", selectedFactory?.label ?? "")
        case "unlock": L("Flash_UnlockConfirm")
        case "lock": L("Flash_LockConfirm")
        case "image": L("Flash_CustomConfirm", customFile?.lastPathComponent ?? "", partition)
        case "boot": L("Flash_BootOnceConfirm", customFile?.lastPathComponent ?? "")
        case "zip": L("Flash_ZipConfirm", zipFile?.lastPathComponent ?? "")
        default: ""
        }
    }

    // MARK: Following the phone

    /// Every few seconds while the page is open, unless a job is running: which mode the phone is in.
    func startWatching() {
        guard watch == nil else { return }
        watch = Task { [weak self] in
            while !Task.isCancelled {
                if let self, !self.isRunning { await self.readState() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopWatching() {
        watch?.cancel()
        watch = nil
    }

    func readState() async {
        if await Fastboot.list().contains(serialNo) {
            guard let b = await Fastboot.read(serialNo) else { return }
            wifiOnly = false
            mode = b.isUserspace ? .fastbootd : .bootloader
            codename = b.product
            unlocked = b.unlocked
            batteryOk = b.batteryOk
            if !b.unlocked, !b.isUserspace { oemAllowed = await Fastboot.canUnlock(serialNo) }
            await loadImages()
            return
        }
        let device = await Adb.shared.devices().first { $0.serial == serialNo || $0.serial.hasPrefix("adb-\(serialNo)-") }
        switch device?.state {
        case "device":
            wifiOnly = Adb.isWireless(device!.serial)
            let p = await Adb.shared.shell(device!.serial,
                "getprop ro.product.device; getprop ro.build.id; getprop ro.product.manufacturer; getprop ro.boot.flash.locked; getprop sys.oem_unlock_allowed; dumpsys battery | grep level")
                .output.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            func line(_ i: Int) -> String { i < p.count ? p[i] : "" }
            mode = .android
            codename = line(0)
            build = line(1)
            manufacturer = line(2)
            unlocked = line(3) == "1" ? false : line(3) == "0" ? true : nil
            // Pixels don't say in Android (the property stays empty either way): the bootloader tells.
            oemAllowed = line(4) == "1" || unlocked == true ? true : nil
            batteryOk = (Int(line(5).replacingOccurrences(of: "level:", with: "").trimmingCharacters(in: .whitespaces)) ?? 100) >= 30
            await loadImages()
        case "recovery": mode = .recovery
        case "sideload": mode = .sideload
        default: mode = .none
        }
    }

    // MARK: Google's images

    func acceptTerms() {
        termsAccepted = true
        UserDefaults.standard.set(true, forKey: "acceptedImageTerms")
        Task { await loadImages() }
    }

    func readTerms() { NSWorkspace.shared.open(URL(string: "https://developers.google.com/android/images")!) }

    private func loadImages() async {
        guard termsAccepted, !codename.isEmpty, loadedFor != codename, !loadingImages else { return }
        loadingImages = true
        imagesFailed = false
        await Catalog.refreshFromGitHub()
        images = await PixelImages.list(codename)
        loadedFor = codename
        imagesFailed = images.isEmpty
        loadingImages = false
        fillChoices()
    }

    /// Carrier builds say so in their label: "16.0.0 (CP1A.260405.005.B1, Apr 2026, Telia)".
    private static func isCarrier(_ i: PixelImage) -> Bool { !i.isBeta && i.label.filter { $0 == "," }.count >= 2 }

    /// Newest first. By default only the latest stable version, the betas and what is already downloaded;
    /// updates only if newer than what the phone runs (recovery refuses older ones).
    private func fillChoices() {
        let current = build.split(separator: ".").dropFirst().first.map(String.init) ?? ""
        func pick(_ ota: Bool) -> [PixelImage] {
            let list = images.filter { $0.isOta == ota }
            if showOlder { return list }
            let latest = list.first { !$0.isBeta && !Self.isCarrier($0) }
            return list.filter { $0 == latest || $0.isBeta || PixelImages.isDownloaded($0) }
        }
        func label(_ i: PixelImage) -> String {
            var tags: [String] = []
            if i.isBeta { tags.append(L("Flash_Beta")) }
            if !build.isEmpty, i.build.lowercased().hasPrefix(build.lowercased()) { tags.append(L("Flash_Current")) }
            if PixelImages.isDownloaded(i) { tags.append(L("Flash_Downloaded")) }
            return tags.isEmpty ? i.label : "\(i.label) · \(tags.joined(separator: " · "))"
        }
        func fill(_ list: [PixelImage], keep: ImageChoice?) -> ([ImageChoice], ImageChoice?) {
            var choices = list.map { ImageChoice(image: $0, label: label($0)) }
            if let keep, keep.image == nil { choices.append(keep) }
            let selected = keep.flatMap { k in choices.first { $0.fileName == k.fileName } } ?? choices.first
            return (choices, selected)
        }
        (otaChoices, selectedOta) = fill(pick(true).filter { current.isEmpty || $0.date >= current }, keep: selectedOta)
        (factoryChoices, selectedFactory) = fill(pick(false), keep: selectedFactory)
    }

    // MARK: Files

    private func pick(_ types: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func pickOta() {
        guard let url = pick(["zip"]) else { return }
        let c = ImageChoice(file: url, label: L("Flash_FileChosen", url.lastPathComponent))
        otaChoices.append(c)
        selectedOta = c
    }

    func pickFactory() {
        guard let url = pick(["zip"]) else { return }
        let c = ImageChoice(file: url, label: L("Flash_FileChosen", url.lastPathComponent))
        factoryChoices.append(c)
        selectedFactory = c
    }

    func pickImage() { if let url = pick(["img"]) { customFile = url } }
    func pickZip() { if let url = pick(["zip"]) { zipFile = url } }

    // MARK: Jobs

    func stop() { job?.cancel() }

    func toBootloader() { run(nil) { m in try await Flasher.toBootloader(m.serialNo, m) } }

    func toAndroid() {
        run(nil) { m in
            if m.inBootloader { await Flasher.rebootFromBootloader(m.serialNo, "") }
            else { _ = await Adb.shared.run(["-s", m.serialNo, "reboot"], timeout: 30) }
        }
    }

    func confirm() {
        let what = pending
        pending = ""
        switch what {
        case "ota":
            guard let c = selectedOta else { return }
            run(c) { m in try await Flasher.sideload(m.serialNo, m.path(c), official: true, m) }
        case "factory":
            guard let c = selectedFactory else { return }
            let wipe = wipe, lockAfter = lockAfter
            run(c) { m in
                try await Flasher.toBootloader(m.serialNo, m)
                try await Flasher.factory(m.serialNo, m.path(c), wipe: wipe, lockAfter: lockAfter, m)
            }
        case "unlock":
            run(nil) { m in
                try await Flasher.toBootloader(m.serialNo, m)
                try await Flasher.unlock(m.serialNo, m)
            }
        case "lock":
            run(nil) { m in
                try await Flasher.toBootloader(m.serialNo, m)
                try await Flasher.lock(m.serialNo, m)
            }
        case "image":
            guard let file = customFile else { return }
            let partition = partition, both = bothSlots, verity = partition == "vbmeta" && disableVerity
            run(nil) { m in
                try await Flasher.toBootloader(m.serialNo, m)
                try await Flasher.flashImage(m.serialNo, partition: partition, file: file, bothSlots: both, disableVerity: verity, m)
            }
        case "boot":
            guard let file = customFile else { return }
            run(nil) { m in
                try await Flasher.toBootloader(m.serialNo, m)
                try await Flasher.bootOnce(m.serialNo, file: file, m)
            }
        case "zip":
            guard let file = zipFile else { return }
            run(nil) { m in try await Flasher.sideload(m.serialNo, file, official: false, m) }
        default: break
        }
    }

    /// Set by `run` once a Google image is downloaded and checked.
    private var paths: [ImageChoice: URL] = [:]
    private func path(_ c: ImageChoice) -> URL { c.file ?? paths[c]! }

    /// Download the image if needed (the only part that can be stopped), then run the job.
    private func run(_ image: ImageChoice?, _ work: @escaping @MainActor (FlashModel) async throws -> Void) {
        guard !isRunning else { return }
        isRunning = true
        log = []
        statusIsError = false
        statusIsDone = false
        job = Task {
            defer {
                canStop = false
                isRunning = false
                progressValue = nil
                job = nil
                fillChoices()
            }
            do {
                if let c = image, let img = c.image {
                    if PixelImages.isDownloaded(img) {
                        paths[c] = PixelImages.localURL(img)
                    } else {
                        canStop = true
                        let size = await PixelImages.size(img)
                        // A factory image is unpacked next to itself before flashing.
                        let need = img.isOta ? size : size * 2
                        if need > 0, PixelImages.freeSpace() < need + (1 << 30) { throw FlashError("Flash_NotEnoughSpace", AppRow.size(need)) }
                        progressValue = 0
                        status = L("Flash_Downloading", img.fileName, "")
                        paths[c] = try await PixelImages.download(img) { [weak self] p in
                            self?.progressValue = p
                            self?.status = p >= 0.95 ? L("Flash_Checking")
                                : L("Flash_Downloading", img.fileName, "\(Int((p / 0.95 * 100).rounded())) %")
                        }
                    }
                }
                try Task.checkCancellation()
                canStop = false
                status = L("Flash_Working")
                // From here on the phone is changing: the job isn't stopped any more.
                try await Task { try await work(self) }.value
                statusIsDone = true
                if log.isEmpty { status = L("Flash_Done") }
            } catch let e as FlashError {
                fail(e.message)
            } catch is PixelImages.ChecksumError {
                fail(L("Flash_ErrChecksum"))
            } catch is CancellationError {
                status = L("Flash_Cancelled")
            } catch {
                if Task.isCancelled { status = L("Flash_Cancelled") } else { fail(error.localizedDescription) }
            }
        }
    }

    private func fail(_ message: String) {
        statusIsError = true
        statusIsDone = false
        status = L("Flash_Failed", message)
    }

    // FlashLog

    func step(_ key: String, _ args: String...) {
        let format = L(key)
        status = args.isEmpty ? format : String(format: format, locale: Lang.locale, arguments: args.map { $0 as NSString })
        add("› " + status)
    }

    func line(_ text: String) { add(text) }
    func progress(_ value: Double?) { progressValue = value }

    private func add(_ line: String) {
        log.append(line)
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }
}
