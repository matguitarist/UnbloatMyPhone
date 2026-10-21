namespace UnbloatMyPhone.Services;

/// <summary>What a phone in bootloader mode says about itself ("fastboot getvar all").</summary>
public sealed class BootloaderInfo
{
    public string Serial { get; init; } = "";
    /// <summary>The device codename, "cheetah" for a Pixel 7 Pro.</summary>
    public string Product { get; init; } = "";
    public bool Unlocked { get; init; }
    public string Slot { get; init; } = "";
    /// <summary>False when the bootloader says the battery is too low to flash.</summary>
    public bool BatteryOk { get; init; } = true;
    public string BootloaderVersion { get; init; } = "";
    public string BasebandVersion { get; init; } = "";
    /// <summary>True in fastbootd (Android's own fastboot), false in the real bootloader.</summary>
    public bool IsUserspace { get; init; }
    public Dictionary<string, string> Vars { get; init; } = [];
}

/// <summary>Talks to phones in bootloader mode. Reading changes nothing.</summary>
public static class Fastboot
{
    /// <summary>Serial numbers of the phones in bootloader mode or fastbootd.</summary>
    public static async Task<List<string>> ListAsync(AdbService adb)
    {
        if (!File.Exists(adb.FastbootPath)) return [];
        var r = await adb.RunStreamingAsync(adb.FastbootPath, ["devices"], _ => { }, 10000, CancellationToken.None);
        return r.Output.Split('\n')
            .Select(l => l.Split(['\t', ' '], StringSplitOptions.RemoveEmptyEntries))
            .Where(p => p.Length >= 2 && p[1] is "fastboot" or "fastbootd")
            .Select(p => p[0]).ToList();
    }

    public static async Task<BootloaderInfo?> ReadAsync(AdbService adb, string serial)
    {
        var r = await adb.RunStreamingAsync(adb.FastbootPath, ["-s", serial, "getvar", "all"], _ => { }, 15000, CancellationToken.None);
        var vars = new Dictionary<string, string>();
        foreach (var raw in r.Output.Split('\n'))
        {
            // "(bootloader) unlocked:no", sometimes with a space after the colon
            var line = raw.Trim();
            if (line.StartsWith("(bootloader)")) line = line["(bootloader)".Length..].Trim();
            var colon = line.IndexOf(':');
            if (colon <= 0) continue;
            vars.TryAdd(line[..colon].Trim(), line[(colon + 1)..].Trim());
        }
        if (vars.Count == 0) return null;
        string V(string k) => vars.GetValueOrDefault(k, "");
        return new BootloaderInfo
        {
            Serial = serial,
            Product = V("product"),
            Unlocked = V("unlocked") == "yes",
            Slot = V("current-slot"),
            BatteryOk = V("battery-soc-ok") != "no",
            BootloaderVersion = V("version-bootloader"),
            BasebandVersion = V("version-baseband"),
            IsUserspace = V("is-userspace") == "yes",
            Vars = vars,
        };
    }

    /// <summary>Whether "OEM unlocking" is on, asked of the bootloader: null if it doesn't say.</summary>
    public static async Task<bool?> CanUnlockAsync(AdbService adb, string serial)
    {
        var r = await adb.RunStreamingAsync(adb.FastbootPath, ["-s", serial, "flashing", "get_unlock_ability"], _ => { }, 10000, CancellationToken.None);
        var line = r.Output.Split('\n').FirstOrDefault(l => l.Contains("get_unlock_ability"));
        return line is null ? null : line.TrimEnd().EndsWith('1');
    }

    /// <summary>Wait for the phone to show up in bootloader mode, after a restart.</summary>
    public static async Task<bool> WaitAsync(AdbService adb, string serial, TimeSpan timeout, CancellationToken ct)
    {
        var until = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < until)
        {
            if ((await ListAsync(adb)).Contains(serial)) return true;
            await Task.Delay(1500, ct);
        }
        return false;
    }
}
