using System.Collections.ObjectModel;
using UnbloatMyPhone.Localization;
using UnbloatMyPhone.Models;
using UnbloatMyPhone.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace UnbloatMyPhone.ViewModels;

public sealed record InfoRow(string Label, string Value);

/// <summary>
/// Software, updates, beta and boot security, with shortcuts to the phone's own screens and a restart menu.
/// Reading changes nothing; buttons only open screens on the phone, except Restart, which asks first.
/// </summary>
public sealed partial class PhoneInfoViewModel : PageViewModel
{
    public const string BetaPage = "https://www.google.com/android/beta";

    public override int StepIndex => 2;
    public PhoneDevice Device { get; }

    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private PhoneInfo? _info;
    [ObservableProperty] private string _error = "";
    [ObservableProperty] private string _status = "";
    [ObservableProperty] private bool _statusIsError;

    /// <summary>"", "normal", "recovery" or "bootloader": the restart waiting for a yes.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasPendingRestart), nameof(ConfirmText))]
    private string _pendingRestart = "";

    public ObservableCollection<HealthTip> Tips { get; } = [];
    public ObservableCollection<InfoRow> Software { get; } = [];
    public ObservableCollection<InfoRow> Boot { get; } = [];

    /// <param name="read">False only for screenshots, which set <see cref="Info"/> themselves.</param>
    public PhoneInfoViewModel(MainViewModel main, PhoneDevice device, bool read = true) : base(main)
    {
        Device = device;
        if (read) _ = RefreshAsync();
    }

    public bool HasInfo => Info is not null;
    public bool HasPendingRestart => PendingRestart.Length > 0;
    public string BetaText => Info is { IsBeta: true } i
        ? Loc.Format("Info_BetaOn", i.SecurityPatch?.ToString("MMMM yyyy", Loc.Culture) ?? Loc.Get("Info_Unknown"))
        : Loc.Get("Info_BetaOff");
    public string ConfirmText => PendingRestart switch
    {
        "" => "",
        "normal" => Loc.Get("Info_ConfirmNormal"),
        var mode => Loc.Format("Info_ConfirmMode",
            Loc.Get(mode == "recovery" ? "Info_RestartRecovery" : "Info_RestartBootloader").ToLower(Loc.Culture)),
    };

    partial void OnInfoChanged(PhoneInfo? value) => Rebuild();

    public override void OnLanguageChanged()
    {
        Rebuild();
        OnPropertyChanged(nameof(ConfirmText));
    }

    [RelayCommand]
    private async Task RefreshAsync()
    {
        IsLoading = true;
        Error = "";
        try { Info = await PhoneInfo.ReadAsync(Main.Adb, Device.Serial); }
        catch (Exception ex) { Error = ex.Message; }
        finally { IsLoading = false; }
    }

    private void Rebuild()
    {
        Tips.Clear();
        Software.Clear();
        Boot.Clear();
        OnPropertyChanged(nameof(HasInfo));
        OnPropertyChanged(nameof(BetaText));
        if (Info is not { } i) return;

        var unknown = Loc.Get("Info_Unknown");
        var age = i.PatchAgeMonths(DateOnly.FromDateTime(DateTime.Today));
        var ago = age switch { 0 => Loc.Get("Info_ThisMonth"), 1 => Loc.Get("Info_OneMonth"), _ => Loc.Format("Info_MonthsAgo", age) };

        Software.Add(new InfoRow(Loc.Get("Info_Android"), i.IsBeta
            ? Loc.Format("Info_AndroidBeta", i.AndroidVersion, i.Codename == "REL" ? "" : i.Codename).Replace(" ()", "")
            : Loc.Format("Info_AndroidValue", i.AndroidVersion)));
        Software.Add(new InfoRow(Loc.Get("Info_Patch"), i.SecurityPatch is { } p
            ? Loc.Format("Info_PatchValue", p.ToString("d MMMM yyyy", Loc.Culture), ago)
            : unknown));
        Software.Add(new InfoRow(Loc.Get("Info_Build"), i.BuildId.Length > 0 ? i.BuildId : unknown));

        Boot.Add(new InfoRow(Loc.Get("Info_Bootloader"),
            i.BootloaderLocked switch { true => Loc.Get("Info_Locked"), false => Loc.Get("Info_Unlocked"), _ => unknown }));
        Boot.Add(new InfoRow(Loc.Get("Info_Verified"), VerifiedText(i.VerifiedBoot)));

        if (i.IsBeta) Tips.Add(new HealthTip(Loc.Get("Info_TipBeta"), TipKind.Info));
        // A beta that is behind says nothing about the maker's support.
        if (age >= 6 && !i.IsBeta) Tips.Add(new HealthTip(Loc.Format("Info_TipPatchVeryOld", age), TipKind.Warn));
        else if (age >= 3) Tips.Add(new HealthTip(Loc.Format("Info_TipPatchOld", age), TipKind.Warn));
        else if (age >= 0) Tips.Add(new HealthTip(Loc.Get("Info_TipPatchOk"), TipKind.Ok));
        if (i.BootloaderLocked == false) Tips.Add(new HealthTip(Loc.Get("Info_TipUnlocked"), TipKind.Warn));
        else if (i.VerifiedBoot is not ("" or "green")) Tips.Add(new HealthTip(Loc.Format("Info_TipNotVerified", VerifiedText(i.VerifiedBoot)), TipKind.Warn));
        else if (i.BootloaderLocked == true && i.VerifiedBoot == "green") Tips.Add(new HealthTip(Loc.Get("Info_TipLocked"), TipKind.Ok));
    }

    private static string VerifiedText(string state) => state switch
    {
        "green" => Loc.Get("Info_VbGreen"),
        "yellow" => Loc.Get("Info_VbYellow"),
        "orange" => Loc.Get("Info_VbOrange"),
        "red" => Loc.Get("Info_VbRed"),
        _ => Loc.Get("Info_Unknown"),
    };

    [RelayCommand]
    private Task OpenUpdateAsync() =>
        OpenOnPhoneAsync("am start -a android.settings.SYSTEM_UPDATE_SETTINGS", "Info_UpdateOpened");

    /// <summary>Settings, System: "Reset options" is one tap away. Android doesn't let anything else open the reset screen itself.</summary>
    [RelayCommand]
    private async Task OpenSystemAsync()
    {
        if (!await OpenOnPhoneAsync("am start -n 'com.android.settings/.Settings$SystemDashboardActivity'", "Info_SystemOpened"))
            await OpenOnPhoneAsync("am start -a android.settings.SETTINGS", "Info_SystemOpened");
    }

    private async Task<bool> OpenOnPhoneAsync(string command, string okKey)
    {
        var r = await Main.Adb.ShellAsync(Device.Serial, command);
        var failed = r.All.Contains("Error", StringComparison.OrdinalIgnoreCase) || r.All.Contains("Exception");
        StatusIsError = failed;
        Status = failed ? Loc.Format("Info_OpenFailed", r.All.Split('\n').LastOrDefault(l => l.Trim().Length > 0)?.Trim() ?? "") : Loc.Get(okKey);
        return !failed;
    }

    [RelayCommand]
    private static void OpenBeta() => UpdateService.OpenInBrowser(BetaPage);

    [RelayCommand]
    private void AskRestart(string mode) => PendingRestart = mode;

    [RelayCommand]
    private void CancelRestart() => PendingRestart = "";

    [RelayCommand]
    private async Task RestartAsync()
    {
        var mode = PendingRestart;
        if (mode.Length == 0) return;
        PendingRestart = "";
        List<string> args = ["-s", Device.Serial, "reboot"];
        if (mode != "normal") args.Add(mode);
        await Main.Adb.RunAsync(args, 15000);
        // The phone is gone until it starts again; the Connect page finds it when it is back.
        if (Device.IsWireless) await Main.Adb.RunAsync(["disconnect", Device.Serial], 5000);
        Main.Device = null;
        Main.GoConnect();
    }
}

public sealed partial class AccessRow(AppAccess access, string name) : ObservableObject
{
    public AppAccess Access { get; } = access;
    public string Name { get; } = name;
    public string Package => Access.Package;
    public bool HasFriendlyName => Name != Package;
    public string Origin => Loc.Get(Access.IsThirdParty ? "Privacy_Yours" : "Privacy_Preinstalled");

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanRemove))]
    private bool _isRemoved;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanRemove))]
    private bool _isWorking;

    public bool CanRemove => !IsRemoved && !IsWorking;
    public void Refresh() => OnPropertyChanged(nameof(Origin));
}

public sealed partial class AccessGroup(AccessKind kind) : ObservableObject
{
    public AccessKind Kind { get; } = kind;
    public string Title => Loc.Get("Privacy_Kind_" + Kind.Key);
    public string Text => Loc.Get("Privacy_KindText_" + Kind.Key);
    public string CountText => Loc.Format("Privacy_Count", Rows.Count);
    public ObservableCollection<AccessRow> Rows { get; } = [];

    public void Refresh()
    {
        foreach (var name in new[] { nameof(Title), nameof(Text), nameof(CountText) }) OnPropertyChanged(name);
        foreach (var r in Rows) r.Refresh();
    }
}

/// <summary>Which apps can use location, microphone, camera and personal data, with one click to remove an access.</summary>
public sealed partial class PrivacyViewModel : PageViewModel
{
    public override int StepIndex => 2;
    public PhoneDevice Device { get; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsEmpty))]
    private bool _isLoading;

    [ObservableProperty] private string _error = "";
    [ObservableProperty] private string _status = "";
    [ObservableProperty] private bool _statusIsError;

    public ObservableCollection<AccessGroup> Groups { get; } = [];
    public bool IsEmpty => !IsLoading && Error.Length == 0 && Groups.Count == 0;

    /// <summary>One backup per visit, started on the first removal.</summary>
    private Backup? _backup;

    /// <param name="read">False only for screenshots, which call <see cref="Show"/> themselves.</param>
    public PrivacyViewModel(MainViewModel main, PhoneDevice device, bool read = true) : base(main)
    {
        Device = device;
        if (read) _ = RefreshAsync();
    }

    public override void OnLanguageChanged()
    {
        foreach (var g in Groups) g.Refresh();
    }

    [RelayCommand]
    private async Task RefreshAsync()
    {
        IsLoading = true;
        Error = "";
        Groups.Clear();
        try { Show(await Privacy.ReadAsync(Main.Adb, Device)); }
        catch (Exception ex) { Error = ex.Message; }
        finally
        {
            IsLoading = false;
            OnPropertyChanged(nameof(IsEmpty));
        }
    }

    /// <summary>One group per kind of access, your own apps first.</summary>
    public void Show(IReadOnlyList<AppAccess> all)
    {
        foreach (var kind in Privacy.Kinds)
        {
            var group = new AccessGroup(kind);
            foreach (var a in all.Where(a => a.Kind == kind)
                         .OrderBy(a => !a.IsThirdParty).ThenBy(a => Catalog.NameOf(a.Package) ?? a.Package))
                group.Rows.Add(new AccessRow(a, Catalog.NameOf(a.Package) ?? a.Package));
            if (group.Rows.Count > 0) Groups.Add(group);
        }
        OnPropertyChanged(nameof(IsEmpty));
    }

    [RelayCommand]
    private async Task RemoveAsync(AccessRow row)
    {
        if (!row.CanRemove) return;
        row.IsWorking = true;
        Status = "";
        StatusIsError = false;
        _backup ??= Backup.Start(Device);
        string? error = null;
        foreach (var perm in row.Access.Granted)
        {
            // Saved before the change, like every other change, so even an interrupted run can be undone.
            var change = new PermissionChange { Package = row.Package, Permission = perm };
            _backup.RevokedPermissions.Add(change);
            _backup.Save();
            error = await Privacy.RevokeAsync(Main.Adb, Device.Serial, row.Package, perm);
            if (error is null) continue;
            _backup.RevokedPermissions.Remove(change);
            _backup.Save();
            break;
        }
        row.IsWorking = false;
        if (error is not null)
        {
            StatusIsError = true;
            Status = Loc.Format("Privacy_Failed", row.Name, error);
            return;
        }
        row.IsRemoved = true;
        // Removing location also removed "all the time".
        if (row.Access.Kind.Key == "Location")
            foreach (var other in Groups.Where(g => g.Kind.Key == "BgLocation").SelectMany(g => g.Rows).Where(r => r.Package == row.Package))
                other.IsRemoved = true;
    }
}
