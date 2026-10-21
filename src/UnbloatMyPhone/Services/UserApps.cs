using System.Globalization;
using System.Text.RegularExpressions;
using UnbloatMyPhone.Models;

namespace UnbloatMyPhone.Services;

/// <summary>An app the owner installed, with what the phone says about it.</summary>
/// <param name="Installer">The app store or app that installed it ("com.android.vending" for Google Play); "" when unknown.</param>
public sealed record InstalledApp(
    string Package,
    string Version,
    string Installer,
    DateTime? Installed,
    DateTime? Updated,
    long AppBytes,
    long DataBytes,
    long CacheBytes,
    bool IsEnabled,
    bool HasIcon)
{
    public long TotalBytes => AppBytes + DataBytes + CacheBytes;
    public bool FromPlay => Installer == "com.android.vending";
    /// <summary>A website added to the home screen. Chrome's ("WebAPKs") are made by Google Play and show no installer.</summary>
    public bool IsWebApp => Installer == "com.android.chrome" || Package.StartsWith("org.chromium.webapk.");
}

/// <summary>The apps installed by the phone's owner (not the work profile), and what can be done with them.</summary>
public static partial class UserApps
{
    /// <summary>Reading changes nothing.</summary>
    public static async Task<List<InstalledApp>> ReadAsync(AdbService adb, PhoneDevice dev)
    {
        // Listed again rather than taken from the device: apps may have come and gone since it was read.
        var ours = await ListAsync(adb, dev.Serial, "-3");
        var off = await ListAsync(adb, dev.Serial, "-d");

        var launcher = await adb.ShellAsync(dev.Serial,
            "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER", 30000);
        var withIcon = launcher.Output.Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.Contains('/') && !l.Contains(' '))
            .Select(l => l[..l.IndexOf('/')])
            .ToHashSet();

        var dump = await adb.ShellAsync(dev.Serial,
            "dumpsys package packages | grep -E '^Hidden|^  Package \\[|^    versionName=|^    lastUpdateTime=|" +
            "^    installerPackageName=|^    User [0-9]+:|^      firstInstallTime='", 60000);
        var text = "\n" + dump.Output.Replace("\r", "").Split("\nHidden")[0];
        var facts = new Dictionary<string, (string Version, string Installer, DateTime? Installed, DateTime? Updated)>();
        foreach (var block in text.Split("\n  Package [").Skip(1))
        {
            var pkg = block[..block.IndexOf(']')];
            if (!ours.Contains(pkg)) continue;
            // The install date is per user: the owner's is the first one after "User 0:".
            var user0 = block.IndexOf("\n    User 0:", StringComparison.Ordinal);
            var installer = Field(block, "installerPackageName");
            facts[pkg] = (
                Field(block, "versionName"),
                installer == "null" ? "" : installer,
                Date(user0 < 0 ? "" : Field(block[user0..], "firstInstallTime")),
                Date(Field(block, "lastUpdateTime")));
        }

        var sizes = await ReadSizesAsync(adb, dev.Serial);
        return ours.Select(pkg =>
        {
            var f = facts.GetValueOrDefault(pkg, ("", "", null, null));
            var s = sizes.GetValueOrDefault(pkg);
            return new InstalledApp(pkg, f.Version, f.Installer, f.Installed, f.Updated, s.App, s.Data, s.Cache,
                !off.Contains(pkg), withIcon.Contains(pkg));
        }).ToList();
    }

    /// <summary>
    /// Sizes from "dumpsys diskstats", which the phone works out from time to time (not live).
    /// "Package Names: [...]", then "App Sizes", "App Data Sizes" and "Cache Sizes" in the same order.
    /// </summary>
    private static async Task<Dictionary<string, (long App, long Data, long Cache)>> ReadSizesAsync(AdbService adb, string serial)
    {
        var r = await adb.ShellAsync(serial, "dumpsys diskstats", 30000);
        string[] List(string name)
        {
            var m = Regex.Match(r.Output, "^" + name + @": \[(.*)\]", RegexOptions.Multiline);
            return m.Success ? m.Groups[1].Value.Split(',').Select(x => x.Trim().Trim('"')).ToArray() : [];
        }
        long At(string[] list, int i) => i < list.Length && long.TryParse(list[i], out var v) ? v : 0;

        var names = List("Package Names");
        var app = List("App Sizes");
        var data = List("App Data Sizes");
        var cache = List("Cache Sizes");
        var result = new Dictionary<string, (long, long, long)>();
        for (var i = 0; i < names.Length; i++) result[names[i]] = (At(app, i), At(data, i), At(cache, i));
        return result;
    }

    private static async Task<HashSet<string>> ListAsync(AdbService adb, string serial, string flag)
    {
        var r = await adb.ShellAsync(serial, $"pm list packages --user 0 {flag}", 30000);
        return r.Output.Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.StartsWith("package:"))
            .Select(l => l["package:".Length..])
            .ToHashSet();
    }

    private static string Field(string block, string name)
    {
        var m = Regex.Match(block, @"\n\s+" + name + "=([^\n]*)");
        return m.Success ? m.Groups[1].Value.Trim() : "";
    }

    /// <summary>"2025-09-11 13:37:13" in the phone's time. Never-set dates read as 1970 (or the day before, west of Greenwich).</summary>
    private static DateTime? Date(string s) =>
        DateTime.TryParseExact(s, "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) && d.Year > 1970
            ? d : null;

    // Each returns null when it worked, else the phone's answer.

    /// <summary>Starts the app on the phone, as if its icon was tapped.</summary>
    public static Task<string?> OpenAsync(AdbService adb, string serial, string pkg) =>
        Run(adb, serial, $"monkey -p {pkg} -c android.intent.category.LAUNCHER 1", "Events injected: 1");

    /// <summary>The app's page in the phone's Settings (storage, notifications, battery…).</summary>
    public static Task<string?> ShowInfoAsync(AdbService adb, string serial, string pkg) =>
        Run(adb, serial, $"am start -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:{pkg}", null);

    public static Task<string?> StopAsync(AdbService adb, string serial, string pkg) =>
        Run(adb, serial, $"am force-stop --user 0 {pkg}", null);

    public static Task<string?> SetEnabledAsync(AdbService adb, string serial, string pkg, bool on) =>
        Run(adb, serial, on ? $"pm enable --user 0 {pkg}" : $"pm disable-user --user 0 {pkg}", "new state:");

    /// <summary>For the owner only: the same app in the work profile stays.</summary>
    public static Task<string?> UninstallAsync(AdbService adb, string serial, string pkg) =>
        Run(adb, serial, $"pm uninstall --user 0 {pkg}", "Success");

    /// <summary>
    /// Android 15 and later: removes the app but keeps its data and its icon. Tapping the icon
    /// downloads it again from the store that installed it.
    /// </summary>
    public static Task<string?> ArchiveAsync(AdbService adb, string serial, string pkg) =>
        Run(adb, serial, $"pm archive --user 0 {pkg}", null);

    public const int ArchiveMinSdk = 35;

    private static async Task<string?> Run(AdbService adb, string serial, string command, string? expected)
    {
        var r = await adb.ShellAsync(serial, command, 60000);
        var failed = r.ExitCode != 0 || r.All.Contains("Exception") || r.All.Contains("Error", StringComparison.OrdinalIgnoreCase)
            || r.All.Contains("Failure") || (expected is not null && !r.All.Contains(expected));
        return failed ? r.All.Split('\n').LastOrDefault(l => l.Trim().Length > 0)?.Trim() ?? r.All : null;
    }
}
