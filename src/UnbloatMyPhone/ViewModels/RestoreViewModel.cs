using System.Collections.ObjectModel;
using UnbloatMyPhone.Localization;
using UnbloatMyPhone.Models;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace UnbloatMyPhone.ViewModels;

public sealed partial class BackupItem(Backup backup) : ObservableObject
{
    public Backup Backup { get; } = backup;
    public string When => Backup.CreatedText;
    public string Summary => Loc.Format("Restore_Summary", Backup.DisabledPackages.Count, Backup.Settings.Count, Backup.RevokedPermissions.Count);
    public void Refresh() => OnPropertyChanged(nameof(Summary));
}

public sealed partial class RestoreViewModel : PageViewModel
{
    public override int StepIndex => 2;

    public PhoneDevice Device { get; private set; }
    public ObservableCollection<BackupItem> Backups { get; } = [];

    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private string _status = "";
    [ObservableProperty] private bool _statusIsError;

    public bool HasBackups => Backups.Count > 0;

    public RestoreViewModel(MainViewModel main, PhoneDevice device) : base(main)
    {
        Device = device;
        Reload();
    }

    partial void OnIsBusyChanged(bool value) => Main.RefreshSteps();

    private void Reload()
    {
        Backups.Clear();
        foreach (var b in Backup.ListFor(Device)) Backups.Add(new BackupItem(b));
        OnPropertyChanged(nameof(HasBackups));
    }

    public override void OnLanguageChanged()
    {
        foreach (var b in Backups) b.Refresh();
    }

    /// <summary>Undo one run: re-enable its apps, put every setting back as it was, and give back removed accesses.</summary>
    [RelayCommand]
    private async Task RestoreAsync(BackupItem item)
    {
        await RunBusy(async () =>
        {
            var b = item.Backup;
            var adb = Main.Adb;
            var serial = Device.Serial;
            foreach (var pkg in b.DisabledPackages)
                await adb.ShellAsync(serial, $"pm enable --user 0 {pkg}");
            foreach (var s in Enumerable.Reverse(b.Settings))
                await SettingsIO.RestoreAsync(adb, serial, s.Namespace, s.Key, s.OldValue);
            foreach (var pkg in b.EnabledPackages)
                await adb.ShellAsync(serial, $"pm disable-user --user 0 {pkg}");
            foreach (var p in b.RevokedPermissions)
                await adb.ShellAsync(serial, $"pm grant --user 0 {p.Package} {p.Permission}");

            // Keep the file for reference, but stop offering it.
            File.Move(b.FilePath, b.FilePath.Replace("changes-", "restored-"), true);
            return Loc.Get("Restore_Done");
        });
    }

    /// <summary>Safety net: re-enable every app disabled by a user (not the ones the maker turned off).</summary>
    [RelayCommand]
    private async Task EnableAllAsync()
    {
        await RunBusy(async () =>
        {
            var adb = Main.Adb;
            var serial = Device.Serial;
            var count = 0;
            foreach (var pkg in Device.Disabled)
            {
                // enabled=3 is COMPONENT_ENABLED_STATE_DISABLED_USER, i.e. disabled by someone, not by the firmware.
                var state = await adb.ShellAsync(serial, $"dumpsys package {pkg} | grep -m1 -oE 'enabled=[0-9]'");
                if (!state.Output.Contains("enabled=3")) continue;
                await adb.ShellAsync(serial, $"pm enable --user 0 {pkg}");
                count++;
            }
            return Loc.Format("Restore_AllDone", count);
        });
    }

    private async Task RunBusy(Func<Task<string>> work)
    {
        IsBusy = true;
        Status = "";
        StatusIsError = false;
        try
        {
            Status = await work();
            Device = await PhoneDevice.LoadAsync(Main.Adb, Device.Serial);
            Main.Device = Device;
            Reload();
        }
        catch (Exception ex)
        {
            Status = ex.Message;
            StatusIsError = true;
        }
        finally { IsBusy = false; }
    }

    [RelayCommand]
    private Task BackAsync() => Main.GoChooseAsync(reload: true);
}
