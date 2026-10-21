import CryptoKit
import Foundation

// Flash and repair for Pixel phones. Same rules and steps as the Windows/Linux app (Services/Flasher.cs).

extension Adb {
    var fastbootURL: URL { toolsDir.appendingPathComponent("fastboot") }
}

extension Shell {
    /// Run a long job (flashing, sideload), passing each line of output as it comes. Progress lines end
    /// in "\r", so those count as lines too.
    static func stream(_ path: String, _ args: [String], timeout: TimeInterval, onLine: @escaping @Sendable (String) -> Void) async -> AdbResult {
        await withCheckedContinuation { (cont: CheckedContinuation<AdbResult, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            let all = Buffer()
            final class Lines: @unchecked Sendable {
                private var pending = Data()
                private let lock = NSLock()
                func feed(_ d: Data, _ emit: (String) -> Void) {
                    let lines: [String] = lock.withLock {
                        pending.append(d)
                        var found: [String] = []
                        while let i = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                            let line = String(decoding: pending[pending.startIndex..<i], as: UTF8.self)
                            pending.removeSubrange(pending.startIndex...i)
                            if !line.isEmpty { found.append(line) }
                        }
                        return found
                    }
                    lines.forEach(emit)
                }
                func flush(_ emit: (String) -> Void) {
                    let rest: String = lock.withLock { defer { pending = Data() }; return String(decoding: pending, as: UTF8.self) }
                    if !rest.isEmpty { emit(rest) }
                }
            }
            let outLines = Lines(), errLines = Lines()
            let emit: @Sendable (String) -> Void = { line in
                all.append(Data((line + "\n").utf8))
                onLine(line)
            }
            p.standardOutput = out
            p.standardError = err
            out.fileHandleForReading.readabilityHandler = { h in outLines.feed(h.availableData, emit) }
            err.fileHandleForReading.readabilityHandler = { h in errLines.feed(h.availableData, emit) }
            let once = Once()
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                outLines.feed(out.fileHandleForReading.readDataToEndOfFile(), emit)
                errLines.feed(err.fileHandleForReading.readDataToEndOfFile(), emit)
                outLines.flush(emit)
                errLines.flush(emit)
                once.run { cont.resume(returning: AdbResult(exitCode: proc.terminationStatus, output: all.string, error: "")) }
            }
            do { try p.run() } catch {
                once.run { cont.resume(returning: AdbResult(exitCode: -1, output: "", error: error.localizedDescription)) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard p.isRunning else { return }
                p.terminate()
                once.run { cont.resume(returning: AdbResult(exitCode: -1, output: all.string, error: "timeout")) }
            }
        }
    }
}

// MARK: - Bootloader mode

/// What a phone in bootloader mode says about itself ("fastboot getvar all").
struct BootloaderInfo: Sendable {
    var product = ""
    var unlocked = false
    var slot = ""
    var batteryOk = true
    var bootloaderVersion = ""
    var basebandVersion = ""
    var isUserspace = false
}

/// Talks to phones in bootloader mode. Reading changes nothing.
enum Fastboot {
    static func run(_ args: [String], timeout: TimeInterval = 15, onLine: @escaping @Sendable (String) -> Void = { _ in }) async -> AdbResult {
        let path = Adb.shared.fastbootURL.path
        guard FileManager.default.isExecutableFile(atPath: path) else { return AdbResult(exitCode: -1, output: "", error: "fastboot missing") }
        return await Shell.stream(path, args, timeout: timeout, onLine: onLine)
    }

    /// Serial numbers of the phones in bootloader mode or fastbootd.
    static func list() async -> [String] {
        await run(["devices"], timeout: 10).output.split(separator: "\n").compactMap { line in
            let p = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            return p.count >= 2 && (p[1] == "fastboot" || p[1] == "fastbootd") ? String(p[0]) : nil
        }
    }

    static func read(_ serial: String) async -> BootloaderInfo? {
        var vars: [String: String] = [:]
        for raw in await run(["-s", serial, "getvar", "all"]).output.split(separator: "\n") {
            // "(bootloader) unlocked:no", sometimes with a space after the colon
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("(bootloader)") { line = String(line.dropFirst("(bootloader)".count)).trimmingCharacters(in: .whitespaces) }
            guard let colon = line.firstIndex(of: ":"), colon > line.startIndex else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            if vars[key] == nil { vars[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
        }
        guard !vars.isEmpty else { return nil }
        return BootloaderInfo(product: vars["product"] ?? "", unlocked: vars["unlocked"] == "yes", slot: vars["current-slot"] ?? "",
                              batteryOk: vars["battery-soc-ok"] != "no", bootloaderVersion: vars["version-bootloader"] ?? "",
                              basebandVersion: vars["version-baseband"] ?? "", isUserspace: vars["is-userspace"] == "yes")
    }

    /// Whether "OEM unlocking" is on, asked of the bootloader: nil if it doesn't say.
    static func canUnlock(_ serial: String) async -> Bool? {
        guard let line = await run(["-s", serial, "flashing", "get_unlock_ability"], timeout: 10).output
            .split(separator: "\n").first(where: { $0.contains("get_unlock_ability") }) else { return nil }
        return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
    }

    /// Wait for the phone to show up in bootloader mode, after a restart.
    static func wait(_ serial: String, seconds: TimeInterval) async -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if await list().contains(serial) { return true }
            try? await Task.sleep(for: .milliseconds(1500))
        }
        return false
    }
}

// MARK: - Google's images

/// One of Google's official images for a Pixel: a full factory image or an OTA update.
struct PixelImage: Hashable, Sendable {
    var isOta: Bool
    var isBeta: Bool
    /// "CP3A.261005.002.A1"
    var build: String
    /// "17.0.0 (CP3A.261005.002.A1, Oct 2026)" or "Android 17 QPR3 Beta (DP11.261002.005)"
    var label: String
    var url: URL
    var sha256: String
    var fileName: String { url.lastPathComponent }
    /// "261005" from "CP3A.261005.002.A1": the build date, to sort by.
    var date: String { build.split(separator: ".").dropFirst().first.map(String.init) ?? "" }
}

/// Finds Google's images for a Pixel on Google's own pages (listed in the catalog) and downloads them,
/// with their checksum checked.
enum PixelImages {
    static var folder: URL { AppPaths.dataDir.appendingPathComponent("images", isDirectory: true) }

    /// Google shows its terms before the lists; this cookie is what the page sets when you accept them.
    /// The app asks the user to accept the same terms first.
    private static let acceptedTerms = "devsite_wall_acks=nexus-image-tos,nexus-ota-tos"

    /// Every image for this codename, newest first. Pages that can't be read are skipped.
    @MainActor static func list(_ codename: String) async -> [PixelImage] {
        var found: [PixelImage] = []
        for page in Catalog.imagePages {
            var req = URLRequest(url: page.url, timeoutInterval: 40)
            req.setValue(acceptedTerms, forHTTPHeaderField: "Cookie")
            guard let (data, _) = try? await URLSession.shared.data(for: req) else { continue }
            found += parse(String(decoding: data, as: UTF8.self), codename: codename, isOta: page.isOta, isBeta: page.isBeta, betaName: page.name)
        }
        var seen = Set<URL>()
        return found.filter { seen.insert($0.url).inserted }
            .sorted { $0.date != $1.date ? $0.date > $1.date : (!$0.isBeta && $1.isBeta) }
    }

    /// The images on one page for this codename. A file's checksum is the first one after its name with
    /// no other file in between; beta pages put the link elsewhere and the name on a button.
    static func parse(_ html: String, codename: String, isOta: Bool, isBeta: Bool, betaName: String) -> [PixelImage] {
        let urls = html.matches(of: #/https:\/\/dl\.google\.com\/[^"'\s<>]+\.zip/#).map { String($0.output) }
        var seen = Set<String>(), list: [PixelImage] = []
        for url in urls where seen.insert(url).inserted {
            let file = String(url[url.index(after: url.lastIndex(of: "/")!)...])
            guard file.hasPrefix(codename + "-") || file.hasPrefix(codename + "_beta-"), file.contains("-ota-") == isOta else { continue }
            let parts = file.split(separator: "-")
            let index = isOta ? 2 : 1
            guard parts.count > index, let link = URL(string: url) else { continue }
            let build = parts[index].uppercased()
            var sha: String?, label: String?
            var from = html.startIndex
            while sha == nil, let r = html.range(of: file, range: from..<html.endIndex) {
                let after = html[r.upperBound..<(html.index(r.upperBound, offsetBy: 600, limitedBy: html.endIndex) ?? html.endIndex)]
                if let m = after.firstMatch(of: #/\b[0-9a-f]{64}\b/#), !after[..<m.range.lowerBound].contains(".zip") { sha = String(m.output) }
                // Stable pages: "17.0.0 (CP3A.261005.002.A1, Oct 2026)" a little before the link.
                let before = html[(html.index(r.lowerBound, offsetBy: -700, limitedBy: html.startIndex) ?? html.startIndex)..<r.lowerBound]
                if let l = before.matches(of: #/<td>\s*([^<]*\([A-Z0-9.]+[^<]*\))\s*<\/td>/#).last, l.output.1.localizedCaseInsensitiveContains(build) {
                    label = String(l.output.1).trimmingCharacters(in: .whitespaces)
                }
                from = r.upperBound
            }
            guard let sha else { continue }
            list.append(PixelImage(isOta: isOta, isBeta: isBeta, build: build, label: isBeta ? "\(betaName) (\(build))" : label ?? build, url: link, sha256: sha))
        }
        return list
    }

    static func localURL(_ image: PixelImage) -> URL { folder.appendingPathComponent(image.fileName) }
    static func isDownloaded(_ image: PixelImage) -> Bool { FileManager.default.fileExists(atPath: localURL(image).path) }

    static func freeSpace() -> Int64 {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let v = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    static func size(_ image: PixelImage) async -> Int64 {
        var req = URLRequest(url: image.url)
        req.httpMethod = "HEAD"
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return 0 }
        return resp.expectedContentLength
    }

    struct ChecksumError: Error {}

    /// Download the image, resuming a partial download, and check its SHA-256 against Google's.
    /// A file that doesn't match is deleted. Progress is 0 to 1.
    static func download(_ image: PixelImage, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = localURL(image)
        if fm.fileExists(atPath: dest.path) { return dest }
        let part = dest.appendingPathExtension("part")
        var have = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        var req = URLRequest(url: image.url)
        if have > 0 { req.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if (resp as? HTTPURLResponse)?.statusCode != 206 { have = 0 }
        let total = have + max(0, resp.expectedContentLength)
        if have == 0 { fm.createFile(atPath: part.path, contents: nil) }
        let out = try FileHandle(forWritingTo: part)
        defer { try? out.close() }
        if have > 0 { try out.seekToEnd() } else { try out.truncate(atOffset: 0) }
        var buffer = Data(capacity: 1 << 20)
        var read = have
        var last = Date.distantPast
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try out.write(contentsOf: buffer)
                read += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0, Date().timeIntervalSince(last) > 0.3 {
                    last = Date()
                    let p = 0.95 * Double(read) / Double(total)
                    await progress(p)
                }
            }
        }
        try out.write(contentsOf: buffer)
        try out.close()
        guard try await matches(part, image.sha256) else {
            try? fm.removeItem(at: part)
            throw ChecksumError()
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
        await progress(1)
        return dest
    }

    static func matches(_ file: URL, _ sha256: String) async throws -> Bool {
        try await Task.detached {
            let h = try FileHandle(forReadingFrom: file)
            defer { try? h.close() }
            var hasher = SHA256()
            while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined() == sha256.lowercased()
        }.value
    }
}

// MARK: - Flashing

/// A job stopped: `key` is a string key, `args` its values.
struct FlashError: Error {
    var key: String
    var args: [String] = []
    init(_ key: String, _ args: String...) { self.key = key; self.args = args }
    var message: String {
        let format = L(key)
        return args.isEmpty ? format : String(format: format, locale: Lang.locale, arguments: args.map { $0 as NSString })
    }
}

/// What a flashing job reports: steps (string keys, shown translated), raw tool output, and progress.
@MainActor protocol FlashLog: AnyObject {
    func step(_ key: String, _ args: String...)
    func line(_ text: String)
    /// 0 to 1, or nil when there's no way to tell.
    func progress(_ value: Double?)
}

/// Flashing and sideloading for Pixel phones, the way Google's own scripts do it. Every job checks the phone
/// is the one the file is for, that the battery is fine, and stops at the first error. The phone is found by
/// its serial number, which is the same in Android, recovery and bootloader mode.
@MainActor enum Flasher {
    /// Partitions a custom image can go to, from bootloader mode.
    static let partitions = ["boot", "init_boot", "vendor_boot", "vendor_kernel_boot", "dtbo", "recovery", "vbmeta"]

    private static func fastboot(_ serialNo: String, _ args: [String], _ log: FlashLog?, timeout: TimeInterval) async -> AdbResult {
        await Fastboot.run(["-s", serialNo] + args, timeout: timeout) { line in Task { @MainActor in log?.line(line) } }
    }

    private static func must(_ r: AdbResult) throws {
        // fastboot can exit 0 after a "FAILED" from the phone on some versions.
        if r.exitCode != 0 || r.output.contains("FAILED") { throw FlashError("Flash_ErrTool", lastLine(r)) }
    }

    private static func lastLine(_ r: AdbResult) -> String {
        (r.output + "\n" + r.error).split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("Finished") })
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    // Restarts

    /// From Android (adb) or bootloader (fastboot) into bootloader mode, then wait for it.
    static func toBootloader(_ serialNo: String, _ log: FlashLog) async throws {
        if await Fastboot.list().contains(serialNo) { return }
        log.step("Flash_StepToBootloader")
        let devices = await Adb.shared.devices()
        let serial = devices.first(where: { $0.serial == serialNo })?.serial
            ?? devices.first(where: { $0.serial.hasPrefix("adb-\(serialNo)-") })?.serial ?? serialNo
        _ = await Adb.shared.run(["-s", serial, "reboot", "bootloader"], timeout: 30)
        guard await Fastboot.wait(serialNo, seconds: 120) else { throw FlashError("Flash_ErrNoBootloader") }
    }

    /// From bootloader mode: "" starts Android, "bootloader" or "recovery" restarts into that mode.
    @discardableResult
    static func rebootFromBootloader(_ serialNo: String, _ mode: String) async -> AdbResult {
        await fastboot(serialNo, mode == "bootloader" ? ["reboot-bootloader"] : mode == "recovery" ? ["reboot", "recovery"] : ["reboot"], nil, timeout: 30)
    }

    // Sideload

    /// What an official OTA zip says about itself, in META-INF/com/android/metadata.
    struct OtaInfo { var devices: [String]; var build: String }

    static func otaMetadata(_ zip: URL) async -> OtaInfo? {
        let r = (try? await Shell.run("/usr/bin/unzip", ["-p", zip.path, "META-INF/com/android/metadata"], timeout: 60)) ?? AdbResult(exitCode: -1, output: "", error: "")
        guard r.exitCode == 0 else { return nil }
        var meta: [String: String] = [:]
        for line in r.output.split(separator: "\n") {
            let p = line.split(separator: "=", maxSplits: 1)
            if p.count == 2, meta[String(p[0])] == nil { meta[String(p[0]).trimmingCharacters(in: .whitespaces)] = String(p[1]).trimmingCharacters(in: .whitespaces) }
        }
        // post-build=google/cheetah/cheetah:17/CP3A.261005.002.A1/16269273:user/release-keys
        let build = (meta["post-build"] ?? "").split(separator: "/").dropFirst(3).first.map(String.init) ?? ""
        let devices = (meta["pre-device"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return build.isEmpty || devices.isEmpty ? nil : OtaInfo(devices: devices, build: build)
    }

    private static func codename(_ serialNo: String) async -> String {
        if await Adb.shared.state(serialNo) == "device" {
            return await Adb.shared.shell(serialNo, "getprop ro.product.device").output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return await Fastboot.read(serialNo)?.product ?? ""
    }

    private static func waitForAdbState(_ serialNo: String, _ state: String, seconds: TimeInterval) async -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if await Adb.shared.state(serialNo) == state { return true }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    /// Wait for Android to have started, and say which build it runs.
    private static func waitForAndroid(_ serialNo: String, seconds: TimeInterval) async -> String? {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            try? await Task.sleep(for: .seconds(10))
            guard await Adb.shared.state(serialNo) == "device" else { continue }
            let r = await Adb.shared.shell(serialNo, "getprop sys.boot_completed; getprop ro.build.id").output.split(separator: "\n")
            if r.first?.trimmingCharacters(in: .whitespaces) == "1" { return r.dropFirst().first?.trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// Restart into recovery and send an update zip with "adb sideload". Official OTAs go in by themselves
    /// ("sideload-auto-reboot") and are checked before and after; for a custom recovery, the user starts
    /// sideload on the phone. Needs a USB cable: the phone leaves Wi-Fi when it restarts.
    static func sideload(_ serialNo: String, _ zip: URL, official: Bool, _ log: FlashLog) async throws {
        let ota = official ? await otaMetadata(zip) : nil
        if official {
            guard let ota else { throw FlashError("Flash_ErrNotOta") }
            let code = await codename(serialNo)
            if !code.isEmpty, !ota.devices.contains(code) { throw FlashError("Flash_ErrWrongPhone", zip.lastPathComponent, code) }
        }
        let adb = Adb.shared
        if await adb.state(serialNo) != "sideload" {
            let inBootloader = await Fastboot.list().contains(serialNo)
            if !inBootloader, !(await adb.devices().contains { $0.serial == serialNo }) { throw FlashError("Flash_ErrNeedUsb") }
            log.step(official ? "Flash_StepToSideload" : "Flash_StepToRecovery")
            if inBootloader { await rebootFromBootloader(serialNo, "recovery") }
            else { _ = await adb.run(["-s", serialNo, "reboot", official ? "sideload-auto-reboot" : "sideload"], timeout: 30) }
            if !official { log.step("Flash_StepStartSideload") }
            guard await waitForAdbState(serialNo, "sideload", seconds: official ? 180 : 600) else { throw FlashError("Flash_ErrNoSideload") }
        }
        log.step("Flash_StepSending", zip.lastPathComponent)
        log.progress(0)
        final class Sent: @unchecked Sendable { var percent = 0 }
        let sent = Sent()
        let r = await Shell.stream(adb.adbURL.path, ["-s", serialNo, "sideload", zip.path], timeout: 90 * 60) { line in
            if let m = line.firstMatch(of: #/\(~?(\d+)%\)/#), let p = Int(m.output.1) {
                sent.percent = p
                Task { @MainActor in log.progress(Double(p) / 100) }
            } else {
                Task { @MainActor in log.line(line) }
            }
        }
        // Pixels stop reading once they have what they need (often near 50%): adb then says
        // "failed to read command" although all went well. Only the result on the phone tells.
        if r.exitCode != 0, !r.output.contains("Total xfer"), sent.percent == 0 { throw FlashError("Flash_ErrSideload", lastLine(r)) }
        log.progress(nil)
        guard let ota else { log.step("Flash_StepSideloadDone"); return }
        log.step("Flash_StepInstalling")
        guard let build = await waitForAndroid(serialNo, seconds: 40 * 60) else { throw FlashError("Flash_ErrNoAndroid") }
        guard build.caseInsensitiveCompare(ota.build) == .orderedSame else { throw FlashError("Flash_ErrNotUpdated", ota.build, build) }
        log.progress(1)
        log.step("Flash_StepUpdated", build)
    }

    // Factory images

    /// A step of flash-all.sh: "flash bootloader file.img", "reboot-bootloader" or "update image.zip".
    struct ScriptStep { var command: String; var partition = ""; var file = "" }

    /// "cheetah" from "cheetah-cp3a.261005.002.a1-factory-5b5b06ad.zip" or "cheetah_beta-…".
    static func codename(ofFile name: String) -> String {
        String(name.split(separator: "-").first ?? "").replacingOccurrences(of: "_beta", with: "")
    }

    /// The steps of the zip's flash-all.sh, so each Pixel gets exactly what Google's script does.
    /// Anything the app doesn't know how to do safely stops it before it starts.
    static func readScript(_ zip: URL) async throws -> (steps: [ScriptStep], entries: [String]) {
        let list = (try? await Shell.run("/usr/bin/unzip", ["-Z1", zip.path], timeout: 120))?.output ?? ""
        let entries = list.split(separator: "\n").map(String.init)
        guard let script = entries.first(where: { $0 == "flash-all.sh" || $0.hasSuffix("/flash-all.sh") }),
              let text = try? await Shell.run("/usr/bin/unzip", ["-p", zip.path, script], timeout: 60).output
        else { throw FlashError("Flash_ErrNotFactory") }
        var steps: [ScriptStep] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("fastboot ") else { continue }
            let w = line.split(separator: " ").dropFirst().map(String.init)
            if w.count == 3, w[0] == "flash" { steps.append(ScriptStep(command: "flash", partition: w[1], file: w[2])) }
            else if w == ["reboot-bootloader"] { steps.append(ScriptStep(command: "reboot-bootloader")) }
            else if w.count >= 2, w[w.count - 2] == "update", w.dropLast(2).allSatisfy({ $0 == "-w" }) { steps.append(ScriptStep(command: "update", file: w[w.count - 1])) }
            else if w.first == "--version" { continue }
            else { throw FlashError("Flash_ErrScript", line) }
        }
        guard steps.contains(where: { $0.command == "update" }) else { throw FlashError("Flash_ErrNotFactory") }
        return (steps, entries)
    }

    /// The phone is in bootloader mode, charged enough, unlocked if needed, and the file is for it.
    @discardableResult
    private static func checkBootloader(_ serialNo: String, file: String?, needUnlocked: Bool) async throws -> BootloaderInfo {
        guard let info = await Fastboot.read(serialNo) else { throw FlashError("Flash_ErrNoBootloader") }
        if info.isUserspace { throw FlashError("Flash_ErrFastbootd") }
        if !info.batteryOk { throw FlashError("Flash_ErrBattery") }
        if needUnlocked, !info.unlocked { throw FlashError("Flash_ErrLocked") }
        if let file, codename(ofFile: file) != info.product { throw FlashError("Flash_ErrWrongPhone", file, info.product) }
        return info
    }

    /// Flash a full factory image from bootloader mode, as flash-all.sh does: bootloader, radio, then the system.
    /// With `wipe` everything on the phone is erased; `lockAfter` needs it.
    static func factory(_ serialNo: String, _ zip: URL, wipe: Bool, lockAfter: Bool, _ log: FlashLog) async throws {
        if lockAfter, !wipe { throw FlashError("Flash_ErrLockNeedsWipe") }
        try await checkBootloader(serialNo, file: zip.lastPathComponent, needUnlocked: true)
        let fm = FileManager.default
        let work = PixelImages.folder.appendingPathComponent("work", isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        log.step("Flash_StepUnpacking")
        log.progress(nil)
        let (steps, entries) = try await readScript(zip)
        for file in Set(steps.map(\.file).filter { !$0.isEmpty }) {
            guard let entry = entries.first(where: { $0 == file || $0.hasSuffix("/" + file) }) else { throw FlashError("Flash_ErrMissingFile", file) }
            let r = try await Shell.run("/usr/bin/unzip", ["-o", "-j", zip.path, entry, "-d", work.path], timeout: 1800)
            guard r.exitCode == 0 else { throw FlashError("Flash_ErrMissingFile", file) }
        }

        for (i, s) in steps.enumerated() {
            log.progress(Double(i) / Double(steps.count))
            switch s.command {
            case "flash":
                log.step("Flash_StepFlashing", s.partition)
                try must(await fastboot(serialNo, ["flash", s.partition, work.appendingPathComponent(s.file).path], log, timeout: 600))
            case "reboot-bootloader":
                log.step("Flash_StepRestartBootloader")
                try must(await fastboot(serialNo, ["reboot-bootloader"], log, timeout: 60))
                try? await Task.sleep(for: .seconds(3))
                guard await Fastboot.wait(serialNo, seconds: 120) else { throw FlashError("Flash_ErrNoBootloader") }
            default:
                log.step(wipe ? "Flash_StepSystemWipe" : "Flash_StepSystem")
                var args: [String] = []
                if wipe { args.append("-w") }
                if lockAfter { args.append("--skip-reboot") }
                args += ["update", work.appendingPathComponent(s.file).path]
                try must(await fastboot(serialNo, args, log, timeout: 40 * 60))
            }
        }
        FlashState.set(serialNo, stock: wipe, image: zip.lastPathComponent)
        log.progress(1)
        if lockAfter { try await lock(serialNo, log) } else { log.step("Flash_StepStarting") }
    }

    // Bootloader lock

    /// "fastboot flashing lock/unlock" returns at once; the phone then waits for its buttons. Ask the bootloader
    /// until it says the new state, for up to 5 minutes. Once confirmed, a Pixel may erase itself and restart
    /// straight away: leaving bootloader mode counts as confirmed too ("Do not lock" stays in the bootloader menu).
    private static func waitForLockState(_ serialNo: String, unlocked: Bool) async -> Bool {
        let until = Date().addingTimeInterval(300)
        while Date() < until {
            try? await Task.sleep(for: .seconds(3))
            if !(await Fastboot.list().contains(serialNo)) {
                // Gone for good, or just a restart of the bootloader: give it a moment to come back.
                try? await Task.sleep(for: .seconds(8))
                if !(await Fastboot.list().contains(serialNo)) { return true }
                continue
            }
            if await Fastboot.read(serialNo)?.unlocked == unlocked { return true }
        }
        return false
    }

    /// Erases the phone. The phone asks for a confirmation with its buttons.
    static func unlock(_ serialNo: String, _ log: FlashLog) async throws {
        let info = try await checkBootloader(serialNo, file: nil, needUnlocked: false)
        if info.unlocked { return }
        if await Fastboot.canUnlock(serialNo) == false { throw FlashError("Flash_ErrOemUnlock") }
        log.step("Flash_StepConfirmOnPhone")
        try must(await fastboot(serialNo, ["flashing", "unlock"], log, timeout: 300))
        guard await waitForLockState(serialNo, unlocked: true) else { throw FlashError("Flash_ErrNotConfirmed") }
        FlashState.set(serialNo, stock: false, image: "")
        log.step("Flash_StepUnlocked")
    }

    /// Only after this app put untouched Google software on the phone with everything erased:
    /// locking anything else stops the phone from starting.
    static func canLock(_ serialNo: String) -> Bool { FlashState.get(serialNo)?.stock == true }

    static func lock(_ serialNo: String, _ log: FlashLog) async throws {
        guard canLock(serialNo) else { throw FlashError("Flash_ErrNotStock") }
        let info = try await checkBootloader(serialNo, file: nil, needUnlocked: false)
        if !info.unlocked { return }
        log.step("Flash_StepConfirmLock")
        try must(await fastboot(serialNo, ["flashing", "lock"], log, timeout: 300))
        guard await waitForLockState(serialNo, unlocked: false) else { throw FlashError("Flash_ErrNotConfirmed") }
        if await Fastboot.list().contains(serialNo) { await rebootFromBootloader(serialNo, "") }
        log.step("Flash_StepLocked")
    }

    // Custom images

    static func flashImage(_ serialNo: String, partition: String, file: URL, bothSlots: Bool, disableVerity: Bool, _ log: FlashLog) async throws {
        guard partitions.contains(partition) else { throw FlashError("Flash_ErrScript", partition) }
        try await checkBootloader(serialNo, file: nil, needUnlocked: true)
        var args = ["flash"]
        if bothSlots { args.append("--slot=all") }
        if partition == "vbmeta", disableVerity { args += ["--disable-verity", "--disable-verification"] }
        args += [partition, file.path]
        // Saved first: from here on, the phone may not be running Google's software any more.
        FlashState.set(serialNo, stock: false, image: "")
        log.step("Flash_StepFlashing", partition)
        try must(await fastboot(serialNo, args, log, timeout: 600))
        log.step("Flash_StepFlashed", partition)
    }

    /// Start the phone once from an image, without writing it anywhere.
    static func bootOnce(_ serialNo: String, file: URL, _ log: FlashLog) async throws {
        try await checkBootloader(serialNo, file: nil, needUnlocked: true)
        log.step("Flash_StepBootOnce", file.lastPathComponent)
        try must(await fastboot(serialNo, ["boot", file.path], log, timeout: 300))
    }
}

/// What this computer last put on each phone, by serial number: whether it is untouched Google software flashed
/// with everything erased (the only time locking the bootloader is offered). Same file as the Windows/Linux app.
enum FlashState {
    /// Same keys as the Windows/Linux app writes (the two share this folder on a Mac).
    struct Entry: Codable {
        var stock: Bool
        var image: String
        var when: String
        enum CodingKeys: String, CodingKey { case stock = "Stock", image = "Image", when = "When" }
    }

    private static var url: URL { AppPaths.dataDir.appendingPathComponent("flash-state.json") }

    private static func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    static func get(_ serialNo: String) -> Entry? { load()[serialNo] }

    static func set(_ serialNo: String, stock: Bool, image: String) {
        var all = load()
        all[serialNo] = Entry(stock: stock, image: image, when: ISO8601DateFormatter().string(from: Date()))
        AppPaths.ensureDataDir()
        let e = JSONEncoder()
        e.outputFormatting = .prettyPrinted
        try? e.encode(all).write(to: url, options: .atomic)
    }
}
