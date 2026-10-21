using System.Collections.ObjectModel;
using UnbloatMyPhone.Localization;
using UnbloatMyPhone.Models;
using UnbloatMyPhone.Services;
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace UnbloatMyPhone.ViewModels;

public enum TipKind { Ok, Info, Warn }

public sealed record HealthTip(string Text, TipKind Kind)
{
    public bool IsOk => Kind == TipKind.Ok;
    public bool IsWarn => Kind == TipKind.Warn;
    public bool IsInfo => Kind == TipKind.Info;
}

public sealed record ProcessRow(string Name, string Package, string Size)
{
    /// <summary>Show the package line only under a friendly name.</summary>
    public bool HasFriendlyName => Name != Package;
}

/// <summary>Read-only check-up: memory, storage, processor, biggest apps, crash loops, with advice.</summary>
public sealed partial class HealthViewModel : PageViewModel
{
    public override int StepIndex => 2;
    public PhoneDevice Device { get; }

    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private HealthReport? _report;
    [ObservableProperty] private string _error = "";

    public ObservableCollection<HealthTip> Tips { get; } = [];
    public ObservableCollection<ProcessRow> TopMemory { get; } = [];

    /// <param name="read">False only for screenshots, which set <see cref="Report"/> themselves.</param>
    public HealthViewModel(MainViewModel main, PhoneDevice device, bool read = true) : base(main)
    {
        Device = device;
        if (read) _ = RefreshAsync();
    }

    public bool HasReport => Report is not null;
    public double MemoryUsedPercent => Report is { MemTotalMb: > 0 } r ? 100.0 * (r.MemTotalMb - r.MemAvailableMb) / r.MemTotalMb : 0;
    public double StorageUsedPercent => Report is { StorageTotalMb: > 0 } r ? 100.0 * (r.StorageTotalMb - r.StorageFreeMb) / r.StorageTotalMb : 0;
    public string MemoryText => Report is null ? "" : Loc.Format("Health_MemoryText", Gb(Report.MemAvailableMb), Gb(Report.MemTotalMb));
    public string StorageText => Report is null ? "" : Loc.Format("Health_StorageText", Gb(Report.StorageFreeMb), Gb(Report.StorageTotalMb));
    public string CpuText => Report is null ? "" : Loc.Format("Health_CpuText", Report.Load.ToString("0.#", Loc.Culture), Report.Cores, Uptime(Report.UptimeHours));

    private static string Uptime(double hours) => hours switch
    {
        < 0.5 => Loc.Get("Health_UnderHour"),
        < 1.5 => Loc.Get("Health_OneHour"),
        < 48 => Loc.Format("Health_Hours", Math.Round(hours)),
        _ => Loc.Format("Health_Days", Math.Round(hours / 24)),
    };

    private static string Gb(long mb) => (mb / 1024.0).ToString("0.#", Loc.Culture);

    partial void OnReportChanged(HealthReport? value)
    {
        foreach (var name in new[] { nameof(HasReport), nameof(MemoryUsedPercent), nameof(StorageUsedPercent), nameof(MemoryText), nameof(StorageText), nameof(CpuText) })
            OnPropertyChanged(name);
        Rebuild();
    }

    public override void OnLanguageChanged() => OnReportChanged(Report);

    [RelayCommand]
    private async Task RefreshAsync()
    {
        IsLoading = true;
        Error = "";
        try { Report = await PhoneHealth.ReadAsync(Main.Adb, Device.Serial); }
        catch (Exception ex) { Error = ex.Message; }
        finally { IsLoading = false; }
    }

    private void Rebuild()
    {
        Tips.Clear();
        TopMemory.Clear();
        if (Report is not { } r) return;

        foreach (var p in r.TopMemory)
            TopMemory.Add(new ProcessRow(Catalog.NameOf(p.Name) ?? p.Name, p.Name, Loc.Format("Health_Mb", p.Mb)));

        if (r.MemTotalMb > 0 && r.MemAvailableMb * 100 < r.MemTotalMb * 15)
            Tips.Add(new HealthTip(Loc.Get("Health_TipMemory"), TipKind.Warn));
        if (r.StorageTotalMb > 0 && r.StorageFreeMb * 100 < r.StorageTotalMb * 15)
            Tips.Add(new HealthTip(Loc.Get("Health_TipStorage"), TipKind.Warn));
        if (r.Cores > 0 && r.Load / r.Cores > 1.0)
            Tips.Add(new HealthTip(Loc.Get("Health_TipCpu"), TipKind.Warn));
        foreach (var c in r.Crashing)
        {
            var name = Catalog.NameOf(c.Package) ?? c.Package;
            var key = Catalog.IsKeep(c.Package) ? "Health_TipCrashKeep"
                : Catalog.IsOffered(Device, c.Package) ? "Health_TipCrashOffered" : "Health_TipCrash";
            Tips.Add(new HealthTip(Loc.Format(key, name, c.Restarts), TipKind.Warn));
        }
        if (Tips.Count == 0) Tips.Add(new HealthTip(Loc.Get("Health_TipAllGood"), TipKind.Ok));
    }

    [RelayCommand]
    private Task GoChooseAsync() => Main.GoChooseAsync(reload: true);
}

/// <summary>Install an .apk from this computer.</summary>
public sealed partial class InstallViewModel(MainViewModel main, PhoneDevice device) : PageViewModel(main)
{
    public override int StepIndex => 2;
    public PhoneDevice Device { get; } = device;

    [ObservableProperty] private bool _isInstalling;
    [ObservableProperty] private string _status = "";
    [ObservableProperty] private bool _statusIsError;

    [RelayCommand]
    private async Task PickAsync()
    {
        var window = (Application.Current?.ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)?.MainWindow;
        if (window?.StorageProvider is not { } storage) return;
        var files = await storage.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = Loc.Get("Install_Pick"),
            FileTypeFilter = [new FilePickerFileType("Android app (.apk)") { Patterns = ["*.apk"], MimeTypes = ["application/vnd.android.package-archive"] }],
        });
        if (files.Count > 0 && files[0].TryGetLocalPath() is { } path) await InstallAsync(path);
    }

    /// <summary>Also called when a file is dropped on the page.</summary>
    public async Task InstallAsync(string path)
    {
        if (IsInstalling) return;
        if (!path.EndsWith(".apk", StringComparison.OrdinalIgnoreCase))
        {
            StatusIsError = true;
            Status = Loc.Get("Install_NotApk");
            return;
        }
        IsInstalling = true;
        StatusIsError = false;
        Status = Loc.Format("Install_Installing", Path.GetFileName(path));
        try
        {
            var r = await Main.Adb.RunAsync(["-s", Device.Serial, "install", "-r", path], 10 * 60 * 1000);
            var ok = r.All.Contains("Success");
            StatusIsError = !ok;
            Status = ok ? Loc.Format("Install_Done", Path.GetFileName(path))
                : Loc.Format("Install_Failed", r.All.Split('\n').LastOrDefault(l => l.Contains("Failure") || l.Contains("INSTALL_")) ?? r.All);
        }
        finally { IsInstalling = false; }
    }
}
