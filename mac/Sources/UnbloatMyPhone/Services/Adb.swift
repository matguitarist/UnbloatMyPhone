import Foundation

/// One line of "adb devices -l". State is device, unauthorized or offline.
struct AdbDevice: Sendable, Hashable { let serial: String; let state: String; let model: String }

/// A phone announcing wireless debugging: its pairing dialog, or its debugging port once paired.
struct MdnsService: Sendable, Hashable { let name: String; let address: String; let pairing: Bool }

struct AdbResult: Sendable {
    let exitCode: Int32
    let output: String
    let error: String
    var ok: Bool { exitCode == 0 }
    var all: String { (output + "\n" + error).trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Where the app keeps adb, backups and settings. Same folder the Windows/Linux app uses on a Mac.
enum AppPaths {
    static let dataDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("UnbloatMyPhone", isDirectory: true)
    static var backupDir: URL { dataDir.appendingPathComponent("backups", isDirectory: true) }

    static func ensureDataDir() {
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }
}

/// Owns a private copy of Google's platform-tools (downloaded on first run) and runs adb.
final class Adb: @unchecked Sendable {
    static let shared = Adb()

    var toolsDir: URL { AppPaths.dataDir.appendingPathComponent("platform-tools", isDirectory: true) }
    var adbURL: URL { toolsDir.appendingPathComponent("adb") }
    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: adbURL.path) }

    private let lock = NSLock()
    private var serverStarted = false

    private static let downloadURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!

    /// Download and unpack platform-tools from Google if they are not there yet.
    func ensureInstalled(progress: @escaping @Sendable (Double) -> Void) async throws {
        if isInstalled { progress(1); return }
        AppPaths.ensureDataDir()
        let zip = AppPaths.dataDir.appendingPathComponent("platform-tools.zip")
        let tmp = AppPaths.dataDir.appendingPathComponent("platform-tools.tmp", isDirectory: true)

        try await Downloader.download(Self.downloadURL, to: zip, progress: { progress(min(0.99, $0)) })

        let fm = FileManager.default
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let unzip = try await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, tmp.path], timeout: 120)
        guard unzip.ok else { throw AppError.message(unzip.all) }
        try? fm.removeItem(at: toolsDir)
        try fm.moveItem(at: tmp.appendingPathComponent("platform-tools"), to: toolsDir)
        try? fm.removeItem(at: tmp)
        try? fm.removeItem(at: zip)
        progress(1)
    }

    /// Start the server with no pipes: it outlives the call and would hold them open forever.
    private func startServerIfNeeded() async {
        let needed: Bool = lock.withLock {
            if serverStarted { return false }
            serverStarted = true
            return true
        }
        guard needed else { return }
        _ = try? await Shell.run(adbURL.path, ["start-server"], timeout: 30, capture: false)
    }

    func run(_ args: [String], timeout: TimeInterval = 20) async -> AdbResult {
        await startServerIfNeeded()
        do { return try await Shell.run(adbURL.path, args, timeout: timeout) }
        catch { return AdbResult(exitCode: -1, output: "", error: error.localizedDescription) }
    }

    func shell(_ serial: String, _ command: String, timeout: TimeInterval = 20) async -> AdbResult {
        await run(["-s", serial, "shell", command], timeout: timeout)
    }

    /// State of one device in "adb devices": device, unauthorized, offline, or nil if absent.
    func state(_ serial: String) async -> String? {
        let r = await run(["devices"], timeout: 10)
        for line in r.output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if parts.count >= 2, parts[0] == serial { return String(parts[1]) }
        }
        return nil
    }

    /// "192.168.1.20:41234", or "adb-SERIAL-xyz._adb-tls-connect._tcp" when adb found the phone on its own.
    static func isWireless(_ serial: String) -> Bool { serial.contains(":") || serial.contains("._adb-tls-connect.") }

    /// Every phone adb sees, from "adb devices -l".
    func devices() async -> [AdbDevice] {
        let r = await run(["devices", "-l"], timeout: 10)
        return r.output.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ") } ?? ""
            return AdbDevice(serial: parts[0], state: parts[1], model: model)
        }
    }

    /// What wireless debugging announces on the network ("adb mdns services").
    func mdnsServices() async -> [MdnsService] {
        let r = await run(["mdns", "services"], timeout: 10)
        return r.output.split(separator: "\n").compactMap { line in
            // adb-SERIAL-xyz	_adb-tls-pairing._tcp	192.168.1.20:37099
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard parts.count >= 3, parts[2].contains(":") else { return nil }
            if parts[1].hasPrefix("_adb-tls-pairing") { return MdnsService(name: parts[0], address: parts[2], pairing: true) }
            if parts[1].hasPrefix("_adb-tls-connect") { return MdnsService(name: parts[0], address: parts[2], pairing: false) }
            return nil
        }
    }

    /// The serial a phone answers on now. Over Wi-Fi the port changes when the phone restarts,
    /// so look for it again by its hardware serial number and reconnect.
    func findAgain(_ serial: String, serialNo: String) async -> String? {
        let list = await devices()
        if list.contains(where: { $0.serial == serial && $0.state == "device" }) { return serial }
        guard !serialNo.isEmpty else { return nil }
        if let same = list.first(where: { $0.state == "device" && ($0.serial == serialNo || $0.serial.hasPrefix("adb-\(serialNo)-")) }) {
            return same.serial
        }
        if let svc = await mdnsServices().first(where: { !$0.pairing && $0.name.hasPrefix("adb-\(serialNo)-") }) {
            _ = await run(["connect", svc.address], timeout: 10)
            if await state(svc.address) == "device" { return svc.address }
        }
        return nil
    }

    func killServer() {
        guard isInstalled, lock.withLock({ serverStarted }) else { return }
        let p = Process()
        p.executableURL = adbURL
        p.arguments = ["kill-server"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// Runs a program and collects its output, killing it after a timeout.
enum Shell {
    static func run(_ path: String, _ args: [String], timeout: TimeInterval, capture: Bool = true) async throws -> AdbResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AdbResult, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            let outBuf = Buffer(), errBuf = Buffer()
            if capture {
                p.standardOutput = out
                p.standardError = err
                out.fileHandleForReading.readabilityHandler = { h in outBuf.append(h.availableData) }
                err.fileHandleForReading.readabilityHandler = { h in errBuf.append(h.availableData) }
            } else {
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
            }
            let once = Once()
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                if capture {
                    outBuf.append(out.fileHandleForReading.readDataToEndOfFile())
                    errBuf.append(err.fileHandleForReading.readDataToEndOfFile())
                }
                once.run {
                    cont.resume(returning: AdbResult(exitCode: proc.terminationStatus,
                                                     output: outBuf.string, error: errBuf.string))
                }
            }
            do { try p.run() } catch {
                once.run { cont.resume(throwing: error) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard p.isRunning else { return }
                p.terminate()
                once.run { cont.resume(returning: AdbResult(exitCode: -1, output: "", error: "timeout")) }
            }
        }
    }

    final class Buffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ d: Data) { lock.withLock { data.append(d) } }
        var bytes: Data { lock.withLock { data } }
        var string: String {
            lock.withLock { String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "") }
        }
    }
}

/// Runs a closure at most once, from any thread.
final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            if done { return false }
            done = true
            return true
        }
        if first { body() }
    }
}

/// File download with progress.
enum Downloader {
    static func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var observation: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                observation?.invalidate()
                observation = nil
                if let error { cont.resume(throwing: error); return }
                guard let tmp, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    cont.resume(throwing: AppError.message("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"))
                    return
                }
                // The temporary file is deleted when this handler returns, so move it now.
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: tmp, to: destination)
                    cont.resume()
                } catch { cont.resume(throwing: error) }
            }
            observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            task.resume()
        }
    }
}
