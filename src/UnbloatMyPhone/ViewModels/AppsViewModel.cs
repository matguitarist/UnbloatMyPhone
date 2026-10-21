using System.Collections.ObjectModel;
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using UnbloatMyPhone.Localization;
using UnbloatMyPhone.Models;
using UnbloatMyPhone.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace UnbloatMyPhone.ViewModels;

/// <summary>One installed app, with its actions. Uninstall and Archive wait for a yes on the row.</summary>
public sealed partial class AppRow : ObservableObject
{
    private readonly AppsViewModel _page;

    public AppRow(AppsViewModel page, InstalledApp app, bool isProtected)
    {
        _page = page;
        _app = app;
        IsProtected = isProtected;
        _name = Catalog.NameOf(app.Package) ?? app.Package;
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Details), nameof(IsOff), nameof(CanOpen), nameof(CanTurnOff), nameof(CanTurnOn), nameof(CanStop))]
    private InstalledApp _app;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasFriendlyName))]
    private string _name;

    /// <summary>What the user is typing in "Name this app".</summary>
    [ObservableProperty] private string _nameDraft = "";
    public string Package => App.Package;
    public bool HasFriendlyName => Name != Package;
    public bool IsProtected { get; }
    public bool IsOff => !App.IsEnabled && !IsGone;

    /// <summary>"Uninstalled" or "Archived" once done; the row stays until the next refresh.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(GoneText), nameof(IsGone), nameof(IsPresent), nameof(IsOff), nameof(CanOpen), nameof(CanTurnOff), nameof(CanTurnOn),
        nameof(CanStop), nameof(CanRemove), nameof(CanArchive))]
    private string _goneKey = "";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanOpen), nameof(CanTurnOff), nameof(CanTurnOn), nameof(CanStop), nameof(CanRemove), nameof(CanArchive))]
    private bool _isWorking;

    /// <summary>"", "uninstall", "archive" (waiting for a yes) or "name" (typing a name).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasPending), nameof(IsNaming), nameof(ConfirmText), nameof(ConfirmButton))]
    private string _pending = "";

    public string GoneText => IsGone ? Loc.Get(GoneKey) : "";
    public bool IsGone => GoneKey.Length > 0;
    public bool IsPresent => !IsGone;
    private bool Ready => !IsGone && !IsWorking;
    public bool CanOpen => Ready && App.IsEnabled && App.HasIcon;
    public bool CanStop => Ready && App.IsEnabled;
    public bool CanTurnOff => Ready && App.IsEnabled && !IsProtected;
    public bool CanTurnOn => Ready && !App.IsEnabled;
    public bool CanRemove => Ready && !IsProtected;
    public bool CanArchive => CanRemove && _page.ArchiveSupported && App.FromPlay;
    public bool HasPending => Pending is "uninstall" or "archive";
    public bool IsNaming => Pending == "name";

    public string ConfirmText => Pending switch
    {
        "uninstall" => Loc.Format("Apps_ConfirmUninstall", Name),
        "archive" => Loc.Format("Apps_ConfirmArchive", Name),
        _ => "",
    };
    public string ConfirmButton => Loc.Get(Pending == "archive" ? "Apps_Archive" : "Apps_Uninstall");

    /// <summary>"4.16.8 · 245 MB · Google Play · installed 11 Sep 2025"</summary>
    public string Details
    {
        get
        {
            var parts = new List<string>();
            if (App.Version.Length > 0) parts.Add(Loc.Format("Apps_Version", App.Version));
            if (App.TotalBytes > 0) parts.Add(Size(App.TotalBytes));
            parts.Add(Origin(App.Installer));
            if (App.Installed is { } d) parts.Add(Loc.Format("Apps_InstalledOn", d.ToString("d MMM yyyy", Loc.Culture)));
            return string.Join(" · ", parts);
        }
    }

    public static string Size(long bytes)
    {
        var mb = bytes / 1024.0 / 1024.0;
        return mb < 1 ? Loc.Get("Apps_LessThanMb")
            : mb < 1000 ? Loc.Format("Apps_Mb", mb.ToString("0", Loc.Culture))
            : Loc.Format("Apps_Gb", (mb / 1024).ToString("0.0", Loc.Culture));
    }

    public static string Origin(string installer) => installer switch
    {
        "com.android.vending" => "Google Play",
        "com.android.chrome" => Loc.Get("Apps_FromWeb"),
        "" or "com.android.shell" or "com.google.android.packageinstaller" or "com.android.packageinstaller" => Loc.Get("Apps_FromFile"),
        "org.fdroid.fdroid" or "org.fdroid.basic" => "F-Droid",
        "com.aurora.store" => "Aurora Store",
        "com.amazon.venezia" => "Amazon Appstore",
        "com.sec.android.app.samsungapps" => "Galaxy Store",
        "dev.imranr.obtainium" => "Obtainium",
        _ => installer,
    };

    public void Refresh()
    {
        foreach (var name in new[] { nameof(Details), nameof(ConfirmText), nameof(ConfirmButton), nameof(GoneText) }) OnPropertyChanged(name);
    }

    [RelayCommand] private Task OpenAsync() => _page.RunAsync(this, "Apps_Opened", UserApps.OpenAsync);
    [RelayCommand] private Task ShowInfoAsync() => _page.RunAsync(this, "Apps_InfoOpened", UserApps.ShowInfoAsync);
    [RelayCommand] private Task StopAsync() => _page.RunAsync(this, "Apps_Stopped", UserApps.StopAsync);
    [RelayCommand] private Task TurnOffAsync() => _page.SetEnabledAsync(this, false);
    [RelayCommand] private Task TurnOnAsync() => _page.SetEnabledAsync(this, true);
    [RelayCommand] private void AskUninstall() => Pending = "uninstall";
    [RelayCommand] private void AskArchive() => Pending = "archive";
    [RelayCommand] private void Cancel() => Pending = "";

    [RelayCommand]
    private void AskName()
    {
        NameDraft = HasFriendlyName ? Name : "";
        Pending = "name";
    }

    [RelayCommand]
    private void SaveName()
    {
        LocalNames.Set(Package, NameDraft);
        Name = Catalog.NameOf(Package) ?? Package;
        Pending = "";
        _page.NamesChanged();
    }
    [RelayCommand] private Task ConfirmAsync() => _page.RemoveAsync(this);
}

/// <summary>The apps the owner installed: size, origin, and open, stop, turn off, uninstall or archive.</summary>
public sealed partial class AppsViewModel : PageViewModel
{
    public override int StepIndex => 2;
    public PhoneDevice Device { get; }
    public bool ArchiveSupported => Device.Sdk >= UserApps.ArchiveMinSdk;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsEmpty))]
    private bool _isLoading;

    [ObservableProperty] private string _error = "";
    [ObservableProperty] private string _status = "";
    [ObservableProperty] private bool _statusIsError;
    [ObservableProperty] private string _search = "";
    /// <summary>0 name, 1 size, 2 most recently installed.</summary>
    [ObservableProperty] private int _sortIndex;

    private List<AppRow> _all = [];
    public ObservableCollection<AppRow> Rows { get; } = [];
    public bool IsEmpty => !IsLoading && Error.Length == 0 && _all.Count == 0;
    public bool NoMatch => _all.Count > 0 && Rows.Count == 0;
    public string Summary => Loc.Format("Apps_Summary", _all.Count(r => !r.IsGone), AppRow.Size(_all.Where(r => !r.IsGone).Sum(r => r.App.TotalBytes)));
    /// <summary>Apps shown by their technical name only.</summary>
    public string UnnamedText
    {
        get
        {
            var n = _all.Count(r => !r.IsGone && !r.HasFriendlyName);
            return n == 0 ? "" : Loc.Format("Apps_Unnamed", n);
        }
    }

    public int ShareCount => LocalNames.NotInCatalog().Count;
    public bool CanShare => ShareCount > 0;
    public string ShareText => Loc.Format("Apps_ShareText", ShareCount);

    public string[] SortOptions => [Loc.Get("Apps_SortName"), Loc.Get("Apps_SortSize"), Loc.Get("Apps_SortNewest")];

    /// <summary>Apps that came from a file or another store, not from Google Play or as a web app.</summary>
    public string OutsideText
    {
        get
        {
            var n = _all.Count(r => !r.IsGone && !r.App.FromPlay && r.App.Installer != "com.android.chrome");
            return n == 0 ? "" : Loc.Format("Apps_Outside", n);
        }
    }

    /// <summary>One backup per visit, started on the first app turned off or on.</summary>
    private Backup? _backup;

    public AppsViewModel(MainViewModel main, PhoneDevice device) : base(main)
    {
        Device = device;
        _ = RefreshAsync();
    }

    partial void OnSearchChanged(string value) => Filter();
    partial void OnSortIndexChanged(int value) => Filter();

    public override void OnLanguageChanged()
    {
        var sort = SortIndex;
        OnPropertyChanged(nameof(SortOptions));
        SortIndex = sort;
        foreach (var r in _all) r.Refresh();
        Counts();
    }

    [RelayCommand]
    private async Task RefreshAsync()
    {
        IsLoading = true;
        Error = "";
        Status = "";
        try
        {
            var apps = await UserApps.ReadAsync(Main.Adb, Device);
            _all = apps.Select(a => new AppRow(this, a, IsNeeded(a))).ToList();
        }
        catch (Exception ex)
        {
            Error = ex.Message;
            _all = [];
        }
        finally
        {
            IsLoading = false;
            Filter();
        }
    }

    /// <summary>
    /// The home screen, keyboard, SMS app and so on, and the parts of Android that Google installs
    /// through Play (Health Connect, Connectivity Services…): those have no icon and aren't in the catalog.
    /// </summary>
    private bool IsNeeded(InstalledApp a) =>
        Device.IsProtected(a.Package) || Catalog.IsKeep(a.Package) ||
        (!a.HasIcon && a.Package.StartsWith("com.google.android.") && Catalog.NameOf(a.Package) is null);

    private void Filter()
    {
        var q = Search.Trim();
        IEnumerable<AppRow> rows = _all.Where(r => q.Length == 0
            || r.Name.Contains(q, StringComparison.OrdinalIgnoreCase) || r.Package.Contains(q, StringComparison.OrdinalIgnoreCase));
        rows = SortIndex switch
        {
            1 => rows.OrderByDescending(r => r.App.TotalBytes),
            2 => rows.OrderByDescending(r => r.App.Installed ?? DateTime.MinValue),
            _ => rows.OrderBy(r => r.Name, StringComparer.Create(Loc.Culture, true)),
        };
        Rows.Clear();
        foreach (var r in rows) Rows.Add(r);
        Counts();
    }

    private void Counts()
    {
        foreach (var name in new[] { nameof(IsEmpty), nameof(NoMatch), nameof(Summary), nameof(OutsideText), nameof(UnnamedText),
                     nameof(ShareCount), nameof(CanShare), nameof(ShareText) }) OnPropertyChanged(name);
    }

    /// <summary>The row keeps its place until the next refresh, so it doesn't jump away while you look at it.</summary>
    public void NamesChanged() => Counts();

    /// <summary>Open a pre-filled GitHub issue with the names typed here. Nothing is posted until the user submits it there.</summary>
    [RelayCommand]
    private async Task ShareNamesAsync()
    {
        var names = LocalNames.NotInCatalog();
        if (names.Count == 0) return;
        var (url, complete) = IssueReport.BuildNames(names);
        if (!complete && (Application.Current?.ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)?.MainWindow?.Clipboard is { } clipboard)
            await clipboard.SetTextAsync(string.Join("\n", names.Select(n => $"{n.Key} = {n.Value}")));
        UpdateService.OpenInBrowser(url);
    }

    private void Report(string? error, string okKey, AppRow row)
    {
        StatusIsError = error is not null;
        Status = error is null ? Loc.Format(okKey, row.Name) : Loc.Format("Apps_Failed", row.Name, error);
    }

    public async Task RunAsync(AppRow row, string okKey, Func<AdbService, string, string, Task<string?>> action)
    {
        if (row.IsWorking) return;
        row.IsWorking = true;
        var error = await action(Main.Adb, Device.Serial, row.Package);
        row.IsWorking = false;
        Report(error, okKey, row);
    }

    /// <summary>Saved in a backup before the change, like every other change, so Restore can undo it.</summary>
    public async Task SetEnabledAsync(AppRow row, bool on)
    {
        if (row.IsWorking) return;
        row.IsWorking = true;
        _backup ??= Backup.Start(Device);
        var list = on ? _backup.EnabledPackages : _backup.DisabledPackages;
        list.Add(row.Package);
        _backup.Save();
        var error = await UserApps.SetEnabledAsync(Main.Adb, Device.Serial, row.Package, on);
        row.IsWorking = false;
        if (error is not null)
        {
            list.Remove(row.Package);
            _backup.Save();
        }
        else
        {
            row.App = row.App with { IsEnabled = on };
            // Keep the connected phone's lists in step, for the other pages.
            (on ? Device.Disabled : Device.Enabled).Remove(row.Package);
            (on ? Device.Enabled : Device.Disabled).Add(row.Package);
        }
        Report(error, on ? "Apps_TurnedOn" : "Apps_TurnedOff", row);
    }

    /// <summary>Uninstall or archive, after the yes on the row. Neither can be undone from Restore.</summary>
    public async Task RemoveAsync(AppRow row)
    {
        var archive = row.Pending == "archive";
        row.Pending = "";
        if (archive ? !row.CanArchive : !row.CanRemove) return;
        row.IsWorking = true;
        var error = archive
            ? await UserApps.ArchiveAsync(Main.Adb, Device.Serial, row.Package)
            : await UserApps.UninstallAsync(Main.Adb, Device.Serial, row.Package);
        row.IsWorking = false;
        if (error is null)
        {
            row.GoneKey = archive ? "Apps_Archived" : "Apps_Uninstalled";
            Device.Enabled.Remove(row.Package);
            Device.Disabled.Remove(row.Package);
            Device.ThirdParty.Remove(row.Package);
            Counts();
        }
        Report(error, archive ? "Apps_ArchivedDone" : "Apps_UninstalledDone", row);
    }
}
