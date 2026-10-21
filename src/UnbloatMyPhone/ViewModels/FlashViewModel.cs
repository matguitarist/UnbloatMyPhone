using System.Collections.ObjectModel;
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using UnbloatMyPhone.Localization;
using UnbloatMyPhone.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace UnbloatMyPhone.ViewModels;

public enum PhoneMode { None, Android, Bootloader, Fastbootd, Recovery, Sideload }

/// <summary>A line in an image list: one of Google's images, or a file picked on this computer.</summary>
public sealed class ImageChoice(PixelImage? image, string? path, string label)
{
    public PixelImage? Image { get; } = image;
    public string? Path { get; } = path;
    public string Label { get; } = label;
    public string FileName => Image?.FileName ?? System.IO.Path.GetFileName(Path ?? "");
    public override string ToString() => Label;
}

/// <summary>
/// Flash and repair, for Pixel phones: official updates and betas, factory images, bootloader lock,
/// and custom images. Works with the phone in Android, recovery or bootloader mode: it is followed by
/// its serial number, which stays the same in every mode. Every job waits for a yes on the page first.
/// </summary>
public sealed partial class FlashViewModel : PageViewModel, IFlashLog
{
    public override int StepIndex => 2;
    public string SerialNo { get; }
    public string Name { get; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ModeText), nameof(InAndroid), nameof(InBootloader), nameof(Found), nameof(CanAct), nameof(IsUnlocked),
        nameof(IsLocked), nameof(LockText), nameof(CanFactory), nameof(CanCustom), nameof(CanUnlock), nameof(CanLock))]
    private PhoneMode _mode;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasCodename))]
    private string _codename = "";

    /// <summary>From Android ("Google" on a Pixel); unknown in bootloader mode.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(NotPixel))]
    private string _manufacturer = "";

    /// <summary>Null until the phone says: from ro.boot.flash.locked in Android, or the bootloader itself.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsUnlocked), nameof(IsLocked), nameof(LockText), nameof(CanFactory), nameof(CanCustom), nameof(CanUnlock), nameof(CanLock))]
    private bool? _unlocked;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(OemText), nameof(OemOff), nameof(CanUnlock))]
    private bool? _oemAllowed;

    [ObservableProperty] private string _build = "";
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(BatteryText), nameof(CanAct))]
    private bool _batteryOk = true;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanAct), nameof(CanFactory), nameof(CanCustom), nameof(CanUnlock), nameof(CanLock), nameof(CanOta))]
    private bool _isRunning;

    [ObservableProperty] private string _status = "";
    [ObservableProperty] private bool _statusIsError;
    [ObservableProperty] private bool _statusIsDone;
    [ObservableProperty] private double _progress;
    [ObservableProperty] private bool _progressKnown;
    [ObservableProperty] private bool _canStop;
    public ObservableCollection<string> Log { get; } = [];
    [ObservableProperty] private string _logText = "";

    // Images
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(NeedTerms))]
    private bool _termsAccepted = AppSettings.Current.AcceptedImageTerms;
    [ObservableProperty] private bool _loadingImages;
    [ObservableProperty] private bool _imagesFailed;
    private List<PixelImage> _images = [];
    [ObservableProperty] private bool _showOlder;
    public ObservableCollection<ImageChoice> OtaChoices { get; } = [];
    public ObservableCollection<ImageChoice> FactoryChoices { get; } = [];
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanOta))]
    private ImageChoice? _selectedOta;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanFactory))]
    private ImageChoice? _selectedFactory;

    [ObservableProperty] private bool _wipe = true;
    [ObservableProperty] private bool _lockAfter;

    // Custom images
    public string[] Partitions => Flasher.Partitions;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsVbmeta), nameof(FlashImageText))]
    private string _partition = "boot";
    [ObservableProperty] private bool _bothSlots;
    [ObservableProperty] private bool _disableVerity;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CustomFileText), nameof(HasCustomFile))]
    private string _customFile = "";
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ZipFileText), nameof(HasZipFile))]
    private string _zipFile = "";

    /// <summary>"", "ota", "factory", "unlock", "lock", "image", "boot" or "zip": waiting for a yes.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasPending), nameof(ConfirmText), nameof(PendingOta), nameof(PendingFactory),
        nameof(PendingLock), nameof(PendingCustom))]
    private string _pending = "";

    private readonly CancellationTokenSource _watch = new();
    private CancellationTokenSource? _job;

    public FlashViewModel(MainViewModel main, string serialNo, string name, bool watch = true) : base(main)
    {
        SerialNo = serialNo;
        Name = name;
        if (watch) _ = WatchAsync(_watch.Token);
    }

    public override void OnLeave() => _watch.Cancel();

    public override void OnLanguageChanged()
    {
        foreach (var n in new[] { nameof(ModeText), nameof(LockText), nameof(OemText), nameof(BatteryText), nameof(ConfirmText),
                     nameof(CustomFileText), nameof(ZipFileText), nameof(FlashImageText) }) OnPropertyChanged(n);
        FillChoices();
    }

    // ---------- What the page shows ----------

    public bool Found => Mode != PhoneMode.None;
    public bool InAndroid => Mode == PhoneMode.Android;
    public bool InBootloader => Mode is PhoneMode.Bootloader or PhoneMode.Fastbootd;
    public bool HasCodename => Codename.Length > 0;
    public bool NotPixel => Manufacturer.Length > 0 && !Manufacturer.Equals("Google", StringComparison.OrdinalIgnoreCase);
    public bool NeedTerms => !TermsAccepted;
    public bool IsUnlocked => Unlocked == true;
    public bool IsLocked => Unlocked == false;
    public bool OemOff => OemAllowed == false && Unlocked == false;
    public bool CanAct => Found && !IsRunning && BatteryOk;
    public bool CanOta => CanAct && SelectedOta is not null;
    public bool CanFactory => CanAct && IsUnlocked && SelectedFactory is not null;
    public bool CanCustom => CanAct && IsUnlocked;
    public bool CanUnlock => CanAct && IsLocked && OemAllowed != false;
    public bool CanLock => CanAct && IsUnlocked && Flasher.CanLock(SerialNo);
    public bool IsVbmeta => Partition == "vbmeta";
    public bool HasCustomFile => CustomFile.Length > 0;
    public bool HasZipFile => ZipFile.Length > 0;
    public string CustomFileText => Loc.Format("Flash_FileChosen", Path.GetFileName(CustomFile));
    public string ZipFileText => Loc.Format("Flash_FileChosen", Path.GetFileName(ZipFile));
    public string FlashImageText => Loc.Format("Flash_FlashImage", Partition);

    public string ModeText => Loc.Get(Mode switch
    {
        PhoneMode.Android => "Flash_ModeAndroid",
        PhoneMode.Bootloader => "Flash_ModeBootloader",
        PhoneMode.Fastbootd => "Flash_ModeFastbootd",
        PhoneMode.Recovery => "Flash_ModeRecovery",
        PhoneMode.Sideload => "Flash_ModeSideload",
        _ => "Flash_ModeNone",
    });
    public string LockText => Unlocked switch { true => Loc.Get("Flash_Unlocked"), false => Loc.Get("Flash_Locked"), _ => Loc.Get("Flash_SeeInBootloader") };
    public string OemText => OemAllowed switch { true => Loc.Get("Flash_OemOn"), false => Loc.Get("Flash_OemOff"), _ => Loc.Get("Flash_SeeInBootloader") };
    public string BatteryText => Loc.Get(BatteryOk ? "Flash_BatteryOk" : "Flash_BatteryLow");

    public bool HasPending => Pending.Length > 0;
    public bool PendingOta => Pending == "ota";
    public bool PendingFactory => Pending == "factory";
    public bool PendingLock => Pending is "unlock" or "lock";
    public bool PendingCustom => Pending is "image" or "boot" or "zip";
    public string ConfirmText => Pending switch
    {
        "ota" => Loc.Format("Flash_OtaConfirm", SelectedOta?.Label ?? ""),
        "factory" => Loc.Format(Wipe ? "Flash_FactoryConfirmWipe" : "Flash_FactoryConfirm", SelectedFactory?.Label ?? ""),
        "unlock" => Loc.Get("Flash_UnlockConfirm"),
        "lock" => Loc.Get("Flash_LockConfirm"),
        "image" => Loc.Format("Flash_CustomConfirm", Path.GetFileName(CustomFile), Partition),
        "boot" => Loc.Format("Flash_BootOnceConfirm", Path.GetFileName(CustomFile)),
        "zip" => Loc.Format("Flash_ZipConfirm", Path.GetFileName(ZipFile)),
        _ => "",
    };

    partial void OnWipeChanged(bool value)
    {
        if (!value) LockAfter = false;
        OnPropertyChanged(nameof(ConfirmText));
    }

    partial void OnLockAfterChanged(bool value)
    {
        if (value) Wipe = true;
    }

    partial void OnShowOlderChanged(bool value) => FillChoices();

    // ---------- Following the phone ----------

    /// <summary>Every few seconds, unless a job is running: which mode the phone is in, and what it says.</summary>
    private async Task WatchAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            if (!IsRunning)
                try { await ReadStateAsync(); } catch { /* adb or fastboot busy: next time */ }
            try { await Task.Delay(3000, ct); } catch (OperationCanceledException) { return; }
        }
    }

    [RelayCommand]
    private Task RefreshAsync() => ReadStateAsync();

    private async Task ReadStateAsync()
    {
        var adb = Main.Adb;
        if ((await Fastboot.ListAsync(adb)).Contains(SerialNo))
        {
            if (await Fastboot.ReadAsync(adb, SerialNo) is not { } b) return;
            Mode = b.IsUserspace ? PhoneMode.Fastbootd : PhoneMode.Bootloader;
            Codename = b.Product;
            Unlocked = b.Unlocked;
            BatteryOk = b.BatteryOk;
            if (!b.Unlocked && !b.IsUserspace) OemAllowed = await Fastboot.CanUnlockAsync(adb, SerialNo);
            await LoadImagesAsync();
            return;
        }
        var device = (await adb.ListDevicesAsync()).FirstOrDefault(d => d.Serial == SerialNo || d.Serial.StartsWith($"adb-{SerialNo}-"));
        switch (device?.State)
        {
            case "device":
                var p = (await adb.ShellAsync(device.Serial,
                    "getprop ro.product.device; getprop ro.build.id; getprop ro.product.manufacturer; getprop ro.boot.flash.locked; getprop sys.oem_unlock_allowed; dumpsys battery | grep level")).Output.Split('\n');
                string Line(int i) => p.ElementAtOrDefault(i)?.Trim() ?? "";
                Mode = PhoneMode.Android;
                Codename = Line(0);
                Build = Line(1);
                Manufacturer = Line(2);
                Unlocked = Line(3) switch { "1" => false, "0" => true, _ => null };
                // Pixels don't say in Android (the property stays empty either way): the bootloader tells.
                OemAllowed = Line(4) == "1" || Unlocked == true ? true : null;
                BatteryOk = !int.TryParse(Line(5).Replace("level:", "").Trim(), out var level) || level >= 30;
                await LoadImagesAsync();
                break;
            case "recovery": Mode = PhoneMode.Recovery; break;
            case "sideload": Mode = PhoneMode.Sideload; break;
            default: Mode = PhoneMode.None; break;
        }
    }

    // ---------- Google's images ----------

    [RelayCommand]
    private Task AcceptTermsAsync()
    {
        TermsAccepted = true;
        AppSettings.Current.AcceptedImageTerms = true;
        AppSettings.Current.Save();
        return LoadImagesAsync();
    }

    [RelayCommand]
    private static void ReadTerms() => UpdateService.OpenInBrowser("https://developers.google.com/android/images");

    private string _loadedFor = "";

    private async Task LoadImagesAsync()
    {
        if (!TermsAccepted || Codename.Length == 0 || _loadedFor == Codename || LoadingImages) return;
        LoadingImages = true;
        ImagesFailed = false;
        try
        {
            await Models.Catalog.RefreshFromGitHubAsync();
            _images = await PixelImages.ListAsync(Codename);
            _loadedFor = Codename;
            ImagesFailed = _images.Count == 0;
        }
        catch { ImagesFailed = true; }
        finally
        {
            LoadingImages = false;
            FillChoices();
        }
    }

    /// <summary>Carrier builds say so in their label: "16.0.0 (CP1A.260405.005.B1, Apr 2026, Telia)".</summary>
    private static bool IsCarrier(PixelImage i) => !i.IsBeta && i.Label.Count(c => c == ',') >= 2;

    /// <summary>
    /// Newest first. By default only the latest stable version, the betas and what is already downloaded;
    /// updates only if newer than what the phone runs (recovery refuses older ones).
    /// </summary>
    private void FillChoices()
    {
        var current = Build.Split('.').ElementAtOrDefault(1) ?? "";
        IEnumerable<PixelImage> Pick(bool ota)
        {
            var list = _images.Where(i => i.IsOta == ota).ToList();
            if (ShowOlder) return list;
            var latest = list.FirstOrDefault(i => !i.IsBeta && !IsCarrier(i));
            return list.Where(i => i == latest || i.IsBeta || PixelImages.IsDownloaded(i));
        }
        string Label(PixelImage i)
        {
            var tags = new List<string>();
            if (i.IsBeta) tags.Add(Loc.Get("Flash_Beta"));
            if (Build.Length > 0 && i.Build.StartsWith(Build, StringComparison.OrdinalIgnoreCase)) tags.Add(Loc.Get("Flash_Current"));
            if (PixelImages.IsDownloaded(i)) tags.Add(Loc.Get("Flash_Downloaded"));
            return tags.Count == 0 ? i.Label : $"{i.Label} · {string.Join(" · ", tags)}";
        }
        void Fill(ObservableCollection<ImageChoice> into, IEnumerable<PixelImage> images, ImageChoice? keep, Action<ImageChoice?> select)
        {
            var file = keep?.Image is null ? keep : null;
            into.Clear();
            foreach (var i in images) into.Add(new ImageChoice(i, null, Label(i)));
            if (file is not null) into.Add(file);
            select(keep is null ? into.FirstOrDefault()
                : into.FirstOrDefault(c => c.FileName == keep.FileName) ?? into.FirstOrDefault());
        }
        Fill(OtaChoices, Pick(true).Where(i => current.Length == 0 || string.CompareOrdinal(i.Date, current) >= 0), SelectedOta, c => SelectedOta = c);
        Fill(FactoryChoices, Pick(false), SelectedFactory, c => SelectedFactory = c);
    }

    // ---------- Files ----------

    private static async Task<string?> PickAsync(string title, string[] patterns)
    {
        var window = (Application.Current?.ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)?.MainWindow;
        if (window?.StorageProvider is not { } storage) return null;
        var files = await storage.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = title,
            FileTypeFilter = [new FilePickerFileType(string.Join(", ", patterns)) { Patterns = patterns }],
        });
        return files.Count > 0 ? files[0].TryGetLocalPath() : null;
    }

    [RelayCommand]
    private async Task PickOtaAsync()
    {
        if (await PickAsync(Loc.Get("Flash_UseFile"), ["*.zip"]) is not { } path) return;
        var c = new ImageChoice(null, path, Loc.Format("Flash_FileChosen", Path.GetFileName(path)));
        OtaChoices.Add(c);
        SelectedOta = c;
    }

    [RelayCommand]
    private async Task PickFactoryAsync()
    {
        if (await PickAsync(Loc.Get("Flash_UseFile"), ["*.zip"]) is not { } path) return;
        var c = new ImageChoice(null, path, Loc.Format("Flash_FileChosen", Path.GetFileName(path)));
        FactoryChoices.Add(c);
        SelectedFactory = c;
    }

    [RelayCommand]
    private async Task PickImageAsync()
    {
        if (await PickAsync(Loc.Get("Flash_PickImage"), ["*.img"]) is { } path) CustomFile = path;
    }

    [RelayCommand]
    private async Task PickZipAsync()
    {
        if (await PickAsync(Loc.Get("Flash_PickZip"), ["*.zip"]) is { } path) ZipFile = path;
    }

    // ---------- Jobs ----------

    [RelayCommand] private void Ask(string what) => Pending = what;
    [RelayCommand] private void Cancel() => Pending = "";
    [RelayCommand] private void Stop() => _job?.Cancel();

    [RelayCommand] private Task ToBootloaderAsync() => RunAsync(null, (log, ct) => Flasher.ToBootloaderAsync(Main.Adb, SerialNo, log, ct));
    [RelayCommand] private Task ToAndroidAsync() => RunAsync(null, async (_, ct) =>
    {
        if (InBootloader) await Flasher.RebootFromBootloaderAsync(Main.Adb, SerialNo, "", ct);
        else await Main.Adb.RunAsync(["-s", SerialNo, "reboot"], 30000, ct);
    });

    [RelayCommand]
    private Task ConfirmAsync()
    {
        var what = Pending;
        Pending = "";
        var adb = Main.Adb;
        return what switch
        {
            "ota" when SelectedOta is { } c => RunAsync(c, (log, ct) => Flasher.SideloadAsync(adb, SerialNo, PathOf(c), official: true, log, ct)),
            "factory" when SelectedFactory is { } c => RunAsync(c, async (log, ct) =>
            {
                await Flasher.ToBootloaderAsync(adb, SerialNo, log, ct);
                await Flasher.FactoryAsync(adb, SerialNo, PathOf(c), Wipe, LockAfter, log, ct);
            }),
            "unlock" => RunAsync(null, async (log, ct) =>
            {
                await Flasher.ToBootloaderAsync(adb, SerialNo, log, ct);
                await Flasher.UnlockAsync(adb, SerialNo, log, ct);
            }),
            "lock" => RunAsync(null, async (log, ct) =>
            {
                await Flasher.ToBootloaderAsync(adb, SerialNo, log, ct);
                await Flasher.LockAsync(adb, SerialNo, log, ct);
            }),
            "image" => RunAsync(null, async (log, ct) =>
            {
                await Flasher.ToBootloaderAsync(adb, SerialNo, log, ct);
                await Flasher.FlashImageAsync(adb, SerialNo, Partition, CustomFile, BothSlots, IsVbmeta && DisableVerity, log, ct);
            }),
            "boot" => RunAsync(null, async (log, ct) =>
            {
                await Flasher.ToBootloaderAsync(adb, SerialNo, log, ct);
                await Flasher.BootOnceAsync(adb, SerialNo, CustomFile, log, ct);
            }),
            "zip" => RunAsync(null, (log, ct) => Flasher.SideloadAsync(adb, SerialNo, ZipFile, official: false, log, ct)),
            _ => Task.CompletedTask,
        };
    }

    /// <summary>Set by <see cref="RunAsync"/> once a Google image is downloaded and checked.</summary>
    private readonly Dictionary<ImageChoice, string> _paths = [];
    private string PathOf(ImageChoice c) => c.Path ?? _paths[c];

    /// <summary>Download the image if needed (the only part that can be stopped), then run the job.</summary>
    private async Task RunAsync(ImageChoice? image, Func<IFlashLog, CancellationToken, Task> job)
    {
        if (IsRunning) return;
        IsRunning = true;
        Main.RefreshSteps();
        Log.Clear();
        LogText = "";
        StatusIsError = StatusIsDone = false;
        _job = new CancellationTokenSource();
        var ct = _job.Token;
        try
        {
            if (image?.Image is { } img && !PixelImages.IsDownloaded(img))
            {
                CanStop = true;
                var size = await PixelImages.SizeAsync(img, ct);
                // A factory image is unpacked next to itself before flashing.
                var need = img.IsOta ? size : size * 2;
                if (need > 0 && PixelImages.FreeSpace() < need + (1L << 30))
                    throw new FlashException("Flash_NotEnoughSpace", AppRow.Size(need));
                ProgressKnown = true;
                Status = Loc.Format("Flash_Downloading", img.FileName, "");
                var progress = new Progress<double>(p =>
                {
                    Progress = p;
                    Status = p >= 0.95 ? Loc.Get("Flash_Checking") : Loc.Format("Flash_Downloading", img.FileName, $"{p / 0.95:P0}");
                });
                _paths[image] = await PixelImages.DownloadAsync(img, progress, ct);
            }
            else if (image?.Image is { } have) _paths[image] = PixelImages.LocalPath(have);
            CanStop = false;
            Status = Loc.Get("Flash_Working");
            await job(this, CancellationToken.None);
            StatusIsDone = true;
            if (!Log.Any()) Status = Loc.Get("Flash_Done");
        }
        catch (FlashException e) { Fail(Loc.Format(e.Message, e.Args)); }
        catch (InvalidDataException) { Fail(Loc.Get("Flash_ErrChecksum")); }
        catch (OperationCanceledException) { StatusIsError = false; Status = Loc.Get("Flash_Cancelled"); }
        catch (Exception e) { Fail(e.Message); }
        finally
        {
            CanStop = false;
            IsRunning = false;
            ProgressKnown = false;
            _job = null;
            Main.RefreshSteps();
            FillChoices();
        }
    }

    private void Fail(string message)
    {
        StatusIsError = true;
        StatusIsDone = false;
        Status = Loc.Format("Flash_Failed", message);
    }

    // IFlashLog, called from any thread.
    void IFlashLog.Step(string key, params object[] args) => Dispatcher.UIThread.Post(() =>
    {
        Status = Loc.Format(key, args);
        AddLog("› " + Status);
    });

    void IFlashLog.Line(string text) => Dispatcher.UIThread.Post(() => AddLog(text));

    void IFlashLog.Progress(double? value) => Dispatcher.UIThread.Post(() =>
    {
        ProgressKnown = value is not null;
        Progress = value ?? 0;
    });

    private void AddLog(string line)
    {
        Log.Add(line);
        while (Log.Count > 300) Log.RemoveAt(0);
        LogText = string.Join("\n", Log);
    }
}
