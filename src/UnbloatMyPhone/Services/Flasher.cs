using System.IO.Compression;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace UnbloatMyPhone.Services;

/// <summary>What a flashing job reports: steps (string keys, shown translated), raw tool output, and progress.</summary>
public interface IFlashLog
{
    void Step(string key, params object[] args);
    void Line(string text);
    /// <summary>0 to 1, or null when there's no way to tell.</summary>
    void Progress(double? value);
}

/// <summary>A job stopped: <see cref="Exception.Message"/> is a string key, <see cref="Args"/> its values.</summary>
public sealed class FlashException(string key, params object[] args) : Exception(key)
{
    public object[] Args { get; } = args;
}

/// <summary>
/// Flashing and sideloading for Pixel phones, the way Google's own scripts do it. Every job checks the phone
/// is the one the file is for, that the battery is fine, and stops at the first error.
/// The phone is found by its serial number, which is the same in Android, recovery and bootloader mode.
/// </summary>
public static partial class Flasher
{
    /// <summary>Partitions a custom image can go to, from bootloader mode.</summary>
    public static readonly string[] Partitions = ["boot", "init_boot", "vendor_boot", "vendor_kernel_boot", "dtbo", "recovery", "vbmeta"];

    // ---------- Restarts ----------

    /// <summary>From Android (adb) or bootloader (fastboot) into bootloader mode, then wait for it.</summary>
    public static async Task ToBootloaderAsync(AdbService adb, string serialNo, IFlashLog log, CancellationToken ct)
    {
        if ((await Fastboot.ListAsync(adb)).Contains(serialNo)) return;
        log.Step("Flash_StepToBootloader");
        await adb.RunAsync(["-s", await AdbSerialAsync(adb, serialNo), "reboot", "bootloader"], 30000, ct);
        if (!await Fastboot.WaitAsync(adb, serialNo, TimeSpan.FromMinutes(2), ct))
            throw new FlashException("Flash_ErrNoBootloader");
    }

    /// <summary>From bootloader mode: "" starts Android, "bootloader" or "recovery" restarts into that mode.</summary>
    public static Task<AdbResult> RebootFromBootloaderAsync(AdbService adb, string serialNo, string mode, CancellationToken ct) =>
        RunFastboot(adb, serialNo, mode switch { "bootloader" => ["reboot-bootloader"], "recovery" => ["reboot", "recovery"], _ => ["reboot"] }, null, 30000, ct);

    /// <summary>The adb serial for this phone over USB, or any connection if that's all there is.</summary>
    private static async Task<string> AdbSerialAsync(AdbService adb, string serialNo)
    {
        var devices = await adb.ListDevicesAsync();
        return devices.FirstOrDefault(d => d.Serial == serialNo)?.Serial
            ?? devices.FirstOrDefault(d => d.Serial.StartsWith($"adb-{serialNo}-"))?.Serial
            ?? serialNo;
    }

    // ---------- Sideload (OTA updates and zips, from recovery) ----------

    [GeneratedRegex(@"\(~?(\d+)%\)")]
    private static partial Regex Percent();

    /// <summary>
    /// Restart into recovery and send an update zip with "adb sideload". Official OTAs go in by themselves
    /// ("sideload-auto-reboot"); for a custom recovery, the user starts sideload on the phone.
    /// Needs a USB cable: the phone leaves Wi-Fi when it restarts.
    /// </summary>
    public static async Task SideloadAsync(AdbService adb, string serialNo, string zip, bool official, IFlashLog log, CancellationToken ct)
    {
        // An official update says which phone it is for and what it installs: check before sending, and after.
        var ota = official ? ReadOtaMetadata(zip) ?? throw new FlashException("Flash_ErrNotOta") : null;
        if (ota is not null)
        {
            var codename = await CodenameAsync(adb, serialNo);
            if (codename.Length > 0 && !ota.Devices.Contains(codename))
                throw new FlashException("Flash_ErrWrongPhone", Path.GetFileName(zip), codename);
        }
        if (await adb.GetStateAsync(serialNo) != "sideload")
        {
            if ((await adb.ListDevicesAsync()).All(d => d.Serial != serialNo) && !(await Fastboot.ListAsync(adb)).Contains(serialNo))
                throw new FlashException("Flash_ErrNeedUsb");
            log.Step(official ? "Flash_StepToSideload" : "Flash_StepToRecovery");
            if ((await Fastboot.ListAsync(adb)).Contains(serialNo))
                await RebootFromBootloaderAsync(adb, serialNo, "recovery", ct);
            else
                await adb.RunAsync(["-s", serialNo, "reboot", official ? "sideload-auto-reboot" : "sideload"], 30000, ct);
            if (!official) log.Step("Flash_StepStartSideload");
            if (!await WaitForAdbStateAsync(adb, serialNo, "sideload", TimeSpan.FromMinutes(official ? 3 : 10), ct))
                throw new FlashException("Flash_ErrNoSideload");
        }
        log.Step("Flash_StepSending", Path.GetFileName(zip));
        log.Progress(0);
        var sent = 0;
        var r = await adb.RunStreamingAsync(adb.AdbPath, ["-s", serialNo, "sideload", zip], line =>
        {
            if (Percent().Match(line) is { Success: true } m) log.Progress((sent = int.Parse(m.Groups[1].Value)) / 100.0);
            else log.Line(line);
        }, (int)TimeSpan.FromMinutes(90).TotalMilliseconds, ct);
        // Pixels stop reading once they have what they need (often near 50%): adb then says
        // "failed to read command" although all went well. Only the result on the phone tells.
        if (r.ExitCode != 0 && !r.Output.Contains("Total xfer") && sent == 0)
            throw new FlashException("Flash_ErrSideload", LastLine(r));
        log.Progress(null);
        if (ota is null)
        {
            log.Step("Flash_StepSideloadDone");
            return;
        }
        log.Step("Flash_StepInstalling");
        var build = await WaitForAndroidAsync(adb, serialNo, TimeSpan.FromMinutes(40), ct);
        if (build is null) throw new FlashException("Flash_ErrNoAndroid");
        if (!build.Equals(ota.Build, StringComparison.OrdinalIgnoreCase)) throw new FlashException("Flash_ErrNotUpdated", ota.Build, build);
        log.Progress(1);
        log.Step("Flash_StepUpdated", build);
    }

    /// <summary>What an official OTA zip says about itself, in META-INF/com/android/metadata.</summary>
    /// <param name="Devices">"cheetah"; some updates list several.</param>
    /// <param name="Build">The build it installs, "CP3A.261005.002.A1".</param>
    public sealed record OtaInfo(string[] Devices, string Build);

    public static OtaInfo? ReadOtaMetadata(string zipPath)
    {
        try
        {
            using var zip = ZipFile.OpenRead(zipPath);
            if (zip.GetEntry("META-INF/com/android/metadata") is not { } entry) return null;
            using var r = new StreamReader(entry.Open());
            var meta = r.ReadToEnd().Split('\n').Select(l => l.Split('=', 2)).Where(p => p.Length == 2)
                .GroupBy(p => p[0].Trim()).ToDictionary(g => g.Key, g => g.First()[1].Trim());
            // post-build=google/cheetah/cheetah:17/CP3A.261005.002.A1/16269273:user/release-keys
            var build = meta.GetValueOrDefault("post-build", "").Split('/').ElementAtOrDefault(3) ?? "";
            var devices = meta.GetValueOrDefault("pre-device", "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            return build.Length == 0 || devices.Length == 0 ? null : new OtaInfo(devices, build);
        }
        catch (InvalidDataException) { return null; }
    }

    /// <summary>The phone's codename, from Android or the bootloader; "" if it can't be asked right now.</summary>
    private static async Task<string> CodenameAsync(AdbService adb, string serialNo)
    {
        if (await adb.GetStateAsync(serialNo) == "device")
            return (await adb.ShellAsync(serialNo, "getprop ro.product.device")).Output.Trim();
        return (await Fastboot.ReadAsync(adb, serialNo))?.Product ?? "";
    }

    /// <summary>Wait for Android to have started, and say which build it runs.</summary>
    private static async Task<string?> WaitForAndroidAsync(AdbService adb, string serialNo, TimeSpan timeout, CancellationToken ct)
    {
        var until = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < until)
        {
            await Task.Delay(10000, ct);
            if (await adb.GetStateAsync(serialNo) != "device") continue;
            var r = (await adb.ShellAsync(serialNo, "getprop sys.boot_completed; getprop ro.build.id")).Output.Split('\n');
            if (r.ElementAtOrDefault(0)?.Trim() == "1") return r.ElementAtOrDefault(1)?.Trim();
        }
        return null;
    }

    private static async Task<bool> WaitForAdbStateAsync(AdbService adb, string serialNo, string state, TimeSpan timeout, CancellationToken ct)
    {
        var until = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < until)
        {
            if (await adb.GetStateAsync(serialNo) == state) return true;
            await Task.Delay(2000, ct);
        }
        return false;
    }

    // ---------- Factory images (back to stock, repair) ----------

    /// <summary>A step of flash-all.sh: "flash bootloader file.img", "reboot-bootloader" or "update image.zip".</summary>
    public sealed record ScriptStep(string Command, string Partition, string File);

    /// <summary>
    /// The steps of the zip's flash-all.sh, so each Pixel gets exactly what Google's script does.
    /// Anything the app doesn't know how to do safely stops it before it starts.
    /// </summary>
    public static List<ScriptStep> ReadScript(ZipArchive zip)
    {
        var entry = zip.Entries.FirstOrDefault(e => e.FullName.EndsWith("/flash-all.sh") || e.FullName == "flash-all.sh")
            ?? throw new FlashException("Flash_ErrNotFactory");
        using var r = new StreamReader(entry.Open());
        var steps = new List<ScriptStep>();
        foreach (var raw in r.ReadToEnd().Split('\n'))
        {
            var line = raw.Trim();
            if (!line.StartsWith("fastboot ")) continue;
            var w = line.Split(' ', StringSplitOptions.RemoveEmptyEntries).Skip(1).ToList();
            if (w is ["flash", var part, var file]) steps.Add(new("flash", part, file));
            else if (w is ["reboot-bootloader"]) steps.Add(new("reboot-bootloader", "", ""));
            else if (w.Count >= 2 && w[^2] == "update" && w.Take(w.Count - 2).All(x => x == "-w")) steps.Add(new("update", "", w[^1]));
            else if (w.Count >= 1 && w[0] == "--version") continue;
            else throw new FlashException("Flash_ErrScript", line);
        }
        if (!steps.Any(s => s.Command == "update")) throw new FlashException("Flash_ErrNotFactory");
        return steps;
    }

    /// <summary>"cheetah" from "cheetah-cp3a.261005.002.a1-factory-5b5b06ad.zip" or "cheetah_beta-…".</summary>
    public static string CodenameOf(string fileName) => Path.GetFileName(fileName).Split('-')[0].Replace("_beta", "");

    /// <summary>
    /// Flash a full factory image from bootloader mode, as flash-all.sh does: bootloader, radio, then the system.
    /// With <paramref name="wipe"/> everything on the phone is erased; <paramref name="lockAfter"/> needs it.
    /// </summary>
    public static async Task FactoryAsync(AdbService adb, string serialNo, string zipPath, bool wipe, bool lockAfter, IFlashLog log, CancellationToken ct)
    {
        if (lockAfter && !wipe) throw new FlashException("Flash_ErrLockNeedsWipe");
        var info = await CheckBootloaderAsync(adb, serialNo, Path.GetFileName(zipPath), needUnlocked: true);

        var work = Path.Combine(PixelImages.Folder, "work");
        if (Directory.Exists(work)) Directory.Delete(work, true);
        Directory.CreateDirectory(work);
        try
        {
            List<ScriptStep> steps;
            log.Step("Flash_StepUnpacking");
            log.Progress(null);
            using (var zip = ZipFile.OpenRead(zipPath))
            {
                steps = ReadScript(zip);
                foreach (var file in steps.Where(s => s.File.Length > 0).Select(s => s.File).Distinct())
                {
                    var entry = zip.Entries.FirstOrDefault(e => e.FullName.EndsWith("/" + file) || e.FullName == file)
                        ?? throw new FlashException("Flash_ErrMissingFile", file);
                    await Task.Run(() => entry.ExtractToFile(Path.Combine(work, file), true), ct);
                }
            }

            for (var i = 0; i < steps.Count; i++)
            {
                ct.ThrowIfCancellationRequested();
                var s = steps[i];
                log.Progress((double)i / steps.Count);
                switch (s.Command)
                {
                    case "flash":
                        log.Step("Flash_StepFlashing", s.Partition);
                        await MustAsync(RunFastboot(adb, serialNo, ["flash", s.Partition, Path.Combine(work, s.File)], log, 600000, ct));
                        break;
                    case "reboot-bootloader":
                        log.Step("Flash_StepRestartBootloader");
                        await MustAsync(RunFastboot(adb, serialNo, ["reboot-bootloader"], log, 60000, ct));
                        await Task.Delay(3000, ct);
                        if (!await Fastboot.WaitAsync(adb, serialNo, TimeSpan.FromMinutes(2), ct))
                            throw new FlashException("Flash_ErrNoBootloader");
                        break;
                    case "update":
                        log.Step(wipe ? "Flash_StepSystemWipe" : "Flash_StepSystem");
                        List<string> args = [];
                        if (wipe) args.Add("-w");
                        if (lockAfter) args.Add("--skip-reboot");
                        args.AddRange(["update", Path.Combine(work, s.File)]);
                        await MustAsync(RunFastboot(adb, serialNo, args, log, (int)TimeSpan.FromMinutes(40).TotalMilliseconds, ct));
                        break;
                }
            }
            FlashState.Set(serialNo, stock: wipe, Path.GetFileName(zipPath));
            log.Progress(1);
            if (lockAfter) await LockAsync(adb, serialNo, log, ct, afterFactory: true);
            else log.Step("Flash_StepStarting");
        }
        finally
        {
            try { Directory.Delete(work, true); } catch { }
        }
    }

    /// <summary>The phone is in bootloader mode, charged enough, unlocked if needed, and the file is for it.</summary>
    private static async Task<BootloaderInfo> CheckBootloaderAsync(AdbService adb, string serialNo, string? fileName, bool needUnlocked)
    {
        var info = await Fastboot.ReadAsync(adb, serialNo) ?? throw new FlashException("Flash_ErrNoBootloader");
        if (info.IsUserspace) throw new FlashException("Flash_ErrFastbootd");
        if (!info.BatteryOk) throw new FlashException("Flash_ErrBattery");
        if (needUnlocked && !info.Unlocked) throw new FlashException("Flash_ErrLocked");
        if (fileName is not null && CodenameOf(fileName) != info.Product)
            throw new FlashException("Flash_ErrWrongPhone", fileName, info.Product);
        return info;
    }

    // ---------- Bootloader lock ----------

    /// <summary>Erases the phone. The phone asks for a confirmation with its buttons.</summary>
    public static async Task UnlockAsync(AdbService adb, string serialNo, IFlashLog log, CancellationToken ct)
    {
        var info = await CheckBootloaderAsync(adb, serialNo, null, needUnlocked: false);
        if (info.Unlocked) return;
        if (await Fastboot.CanUnlockAsync(adb, serialNo) == false) throw new FlashException("Flash_ErrOemUnlock");
        log.Step("Flash_StepConfirmOnPhone");
        await MustAsync(RunFastboot(adb, serialNo, ["flashing", "unlock"], log, (int)TimeSpan.FromMinutes(5).TotalMilliseconds, ct));
        if (!await WaitForLockStateAsync(adb, serialNo, unlocked: true, ct)) throw new FlashException("Flash_ErrNotConfirmed");
        FlashState.Set(serialNo, stock: false, "");
        log.Step("Flash_StepUnlocked");
    }

    /// <summary>
    /// "fastboot flashing lock/unlock" returns at once; the phone then waits for its buttons. Ask the bootloader
    /// until it says the new state, for up to 5 minutes. Once confirmed, a Pixel may erase itself and restart
    /// straight away: leaving bootloader mode counts as confirmed too ("Do not lock" stays in the bootloader menu).
    /// </summary>
    private static async Task<bool> WaitForLockStateAsync(AdbService adb, string serialNo, bool unlocked, CancellationToken ct)
    {
        var until = DateTime.UtcNow + TimeSpan.FromMinutes(5);
        while (DateTime.UtcNow < until)
        {
            await Task.Delay(3000, ct);
            if (!(await Fastboot.ListAsync(adb)).Contains(serialNo))
            {
                // Gone for good, or just a restart of the bootloader: give it a moment to come back.
                await Task.Delay(8000, ct);
                if (!(await Fastboot.ListAsync(adb)).Contains(serialNo)) return true;
                continue;
            }
            if ((await Fastboot.ReadAsync(adb, serialNo))?.Unlocked == unlocked) return true;
        }
        return false;
    }

    /// <summary>
    /// Only after this app put untouched Google software on the phone with everything erased:
    /// locking anything else stops the phone from starting.
    /// </summary>
    public static bool CanLock(string serialNo) => FlashState.Get(serialNo)?.Stock == true;

    public static async Task LockAsync(AdbService adb, string serialNo, IFlashLog log, CancellationToken ct, bool afterFactory = false)
    {
        if (!CanLock(serialNo)) throw new FlashException("Flash_ErrNotStock");
        var info = await CheckBootloaderAsync(adb, serialNo, null, needUnlocked: false);
        if (!info.Unlocked) return;
        log.Step("Flash_StepConfirmLock");
        await MustAsync(RunFastboot(adb, serialNo, ["flashing", "lock"], log, (int)TimeSpan.FromMinutes(5).TotalMilliseconds, ct));
        if (!await WaitForLockStateAsync(adb, serialNo, unlocked: false, ct)) throw new FlashException("Flash_ErrNotConfirmed");
        if ((await Fastboot.ListAsync(adb)).Contains(serialNo)) await RebootFromBootloaderAsync(adb, serialNo, "", ct);
        // Locking a phone with anything but Google's software would stop it from starting: never offer it again
        // until the next untouched factory image.
        FlashState.Set(serialNo, stock: true, FlashState.Get(serialNo)?.Image ?? "");
        log.Step("Flash_StepLocked");
    }

    // ---------- Custom images ----------

    public static async Task FlashImageAsync(AdbService adb, string serialNo, string partition, string file, bool bothSlots, bool disableVerity,
        IFlashLog log, CancellationToken ct)
    {
        if (!Partitions.Contains(partition)) throw new FlashException("Flash_ErrScript", partition);
        await CheckBootloaderAsync(adb, serialNo, null, needUnlocked: true);
        List<string> args = ["flash"];
        if (bothSlots) args.Add("--slot=all");
        if (partition == "vbmeta" && disableVerity) args.AddRange(["--disable-verity", "--disable-verification"]);
        args.AddRange([partition, file]);
        // Saved first: from here on, the phone may not be running Google's software any more.
        FlashState.Set(serialNo, stock: false, "");
        log.Step("Flash_StepFlashing", partition);
        await MustAsync(RunFastboot(adb, serialNo, args, log, 600000, ct));
        log.Step("Flash_StepFlashed", partition);
    }

    /// <summary>Start the phone once from an image, without writing it anywhere.</summary>
    public static async Task BootOnceAsync(AdbService adb, string serialNo, string file, IFlashLog log, CancellationToken ct)
    {
        await CheckBootloaderAsync(adb, serialNo, null, needUnlocked: true);
        log.Step("Flash_StepBootOnce", Path.GetFileName(file));
        await MustAsync(RunFastboot(adb, serialNo, ["boot", file], log, 300000, ct));
    }

    // ---------- Helpers ----------

    private static Task<AdbResult> RunFastboot(AdbService adb, string serialNo, IEnumerable<string> args, IFlashLog? log, int timeoutMs, CancellationToken ct) =>
        adb.RunStreamingAsync(adb.FastbootPath, ["-s", serialNo, .. args], line => log?.Line(line), timeoutMs, ct);

    private static async Task MustAsync(Task<AdbResult> run)
    {
        var r = await run;
        // fastboot can exit 0 after a "FAILED" from the phone on some versions.
        if (r.ExitCode != 0 || r.Output.Contains("FAILED")) throw new FlashException("Flash_ErrTool", LastLine(r));
    }

    private static string LastLine(AdbResult r) =>
        (r.Output + "\n" + r.Error).Split('\n').LastOrDefault(l => l.Trim().Length > 0 && !l.StartsWith("Finished"))?.Trim() ?? "";
}

/// <summary>
/// What this computer last put on each phone, by serial number: whether it is untouched Google software
/// flashed with everything erased (the only time locking the bootloader is offered).
/// </summary>
public static class FlashState
{
    public sealed class Entry
    {
        public bool Stock { get; set; }
        public string Image { get; set; } = "";
        public DateTime When { get; set; }
    }

    private static string FilePath => Path.Combine(AdbService.DataDir, "flash-state.json");

    private static Dictionary<string, Entry> Load()
    {
        try { return File.Exists(FilePath) ? JsonSerializer.Deserialize<Dictionary<string, Entry>>(File.ReadAllText(FilePath)) ?? [] : []; }
        catch { return []; }
    }

    public static Entry? Get(string serialNo) => Load().GetValueOrDefault(serialNo);

    public static void Set(string serialNo, bool stock, string image)
    {
        var all = Load();
        all[serialNo] = new Entry { Stock = stock, Image = image, When = DateTime.Now };
        Directory.CreateDirectory(AdbService.DataDir);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(all, new JsonSerializerOptions { WriteIndented = true }));
    }
}
