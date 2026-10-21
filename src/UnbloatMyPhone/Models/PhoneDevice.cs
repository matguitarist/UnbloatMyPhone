using UnbloatMyPhone.Services;

namespace UnbloatMyPhone.Models;

/// <summary>What we know about the connected phone. Read-only queries only.</summary>
public sealed class PhoneDevice
{
    public required string Serial { get; init; }
    public string Manufacturer { get; init; } = "";
    public string Brand { get; init; } = "";
    public string Model { get; init; } = "";
    public string SerialNo { get; init; } = "";
    public string AndroidVersion { get; init; } = "";
    public int Sdk { get; init; }
    public long RamMb { get; init; }
    public string HomePackage { get; init; } = "";
    /// <summary>Every app that can act as the home screen, not just the current one.</summary>
    public HashSet<string> HomeCapable { get; init; } = [];
    public string InputMethodPackage { get; init; } = "";
    /// <summary>The default Phone and SMS apps: turning them off would leave the phone unable to call or text.</summary>
    public HashSet<string> RoleHolders { get; init; } = [];
    public bool SetupComplete { get; init; }
    public long StorageTotalMb { get; init; }
    public long StorageFreeMb { get; init; }

    public HashSet<string> Enabled { get; init; } = [];
    public HashSet<string> Disabled { get; init; } = [];
    public HashSet<string> ThirdParty { get; init; } = [];

    public bool IsInstalled(string pkg) => Enabled.Contains(pkg) || Disabled.Contains(pkg);

    public string DisplayName
    {
        get
        {
            var maker = string.IsNullOrWhiteSpace(Manufacturer) ? Brand : Manufacturer;
            if (maker.Length > 0) maker = char.ToUpperInvariant(maker[0]) + maker[1..];
            return Model.StartsWith(maker, StringComparison.OrdinalIgnoreCase) || maker.Length == 0
                ? Model
                : $"{maker} {Model}";
        }
    }

    /// <summary>Connected over Wi-Fi ("192.168.1.20:41234", or the name wireless debugging announces).</summary>
    public bool IsWireless => AdbService.IsWirelessSerial(Serial);

    /// <summary>Shown under the phone's name: its address on Wi-Fi, "USB" otherwise.</summary>
    public string ConnectionText => !IsWireless ? "USB"
        : Serial.Contains(':') ? Serial[..Serial.LastIndexOf(':')] : "Wi-Fi";

    /// <summary>Packages that must never be disabled, whatever the catalog says.</summary>
    public bool IsProtected(string pkg) =>
        pkg == HomePackage || HomeCapable.Contains(pkg) || pkg == InputMethodPackage || RoleHolders.Contains(pkg) ||
        ProtectedPackages.Contains(pkg);

    private static readonly HashSet<string> ProtectedPackages =
    [
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
    ];

    public static async Task<PhoneDevice> LoadAsync(AdbService adb, string serial)
    {
        var props = await adb.ShellAsync(serial,
            "getprop ro.product.manufacturer; getprop ro.product.brand; getprop ro.product.model; " +
            "getprop ro.serialno; getprop ro.build.version.release; getprop ro.build.version.sdk");
        var p = props.Output.Split('\n');
        string Prop(int i) => i < p.Length ? p[i].Trim() : "";

        var mem = await adb.ShellAsync(serial, "grep MemTotal /proc/meminfo");
        var ramKb = long.TryParse(new string(mem.Output.Where(char.IsDigit).ToArray()), out var kb) ? kb : 0;

        var home = await adb.ShellAsync(serial,
            "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME");
        var homeLine = home.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "";
        var homePkg = homeLine.Contains('/') ? homeLine[..homeLine.IndexOf('/')].Trim() : "";

        var homes = await adb.ShellAsync(serial,
            "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME");
        var homeCapable = homes.Output.Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.Contains('/') && !l.Contains('=') && !l.Contains(' '))
            .Select(l => l[..l.IndexOf('/')])
            .ToHashSet();

        var ime = await adb.ShellAsync(serial, "settings get secure default_input_method");
        var imeLine = ime.Output.Trim();
        var imePkg = imeLine.Contains('/') ? imeLine[..imeLine.IndexOf('/')] : "";

        var roles = await adb.ShellAsync(serial,
            "cmd role get-role-holders android.app.role.DIALER; cmd role get-role-holders android.app.role.SMS");
        var roleHolders = roles.Output.Split(['\n', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(l => l.Contains('.') && !l.Contains(' '))
            .ToHashSet();

        var setup = await adb.ShellAsync(serial, "settings get secure user_setup_complete");
        var storage = await ReadStorageAsync(adb, serial);

        return new PhoneDevice
        {
            Serial = serial,
            Manufacturer = Prop(0),
            Brand = Prop(1),
            Model = Prop(2),
            SerialNo = Prop(3),
            AndroidVersion = Prop(4),
            Sdk = int.TryParse(Prop(5), out var sdk) ? sdk : 0,
            RamMb = ramKb / 1024,
            HomePackage = homePkg,
            HomeCapable = homeCapable,
            InputMethodPackage = imePkg,
            RoleHolders = roleHolders,
            SetupComplete = setup.Output.Trim() == "1",
            StorageTotalMb = storage.TotalMb,
            StorageFreeMb = storage.FreeMb,
            Enabled = await ListPackagesAsync(adb, serial, "-e"),
            Disabled = await ListPackagesAsync(adb, serial, "-d"),
            ThirdParty = await ListPackagesAsync(adb, serial, "-3"),
        };
    }

    /// <summary>Size and free space of the app storage (/data), from "df -k". Zeros if unreadable.</summary>
    public static async Task<(long TotalMb, long FreeMb)> ReadStorageAsync(AdbService adb, string serial)
    {
        var r = await adb.ShellAsync(serial, "df -k /data");
        var last = r.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "";
        var cols = last.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        // Filesystem 1K-blocks Used Available Use% Mounted-on
        return cols.Length >= 4 && long.TryParse(cols[1], out var total) && long.TryParse(cols[3], out var free)
            ? (total / 1024, free / 1024)
            : (0, 0);
    }

    private static async Task<HashSet<string>> ListPackagesAsync(AdbService adb, string serial, string flag)
    {
        var r = await adb.ShellAsync(serial, $"pm list packages {flag}", 30000);
        return r.Output.Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.StartsWith("package:"))
            .Select(l => l["package:".Length..])
            .ToHashSet();
    }
}
