using System.Collections.ObjectModel;
using System.Net;
using UnbloatMyPhone.Localization;
using UnbloatMyPhone.Models;
using UnbloatMyPhone.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace UnbloatMyPhone.ViewModels;

public enum ConnectState { Idle, Connecting, WaitingForApproval, Reading, Failed }

/// <summary>A phone adb can see: plugged in, connected over Wi-Fi, or announcing wireless debugging.</summary>
public sealed class FoundPhone(string serial, string state, string name, bool wireless)
{
    public string Serial { get; } = serial;
    /// <summary>"device", "unauthorized", "offline", or "announced" (wireless debugging is on, not connected yet).</summary>
    public string State { get; } = state;
    public string Name { get; } = name;
    public bool IsWireless { get; } = wireless;
    public bool CanUse => State is "device" or "announced";
    public bool NeedsApproval => State == "unauthorized";
    public string Detail => Loc.Get(NeedsApproval ? "Connect_RowApprove" : State == "offline" ? "Connect_RowOffline"
        : IsWireless ? "Connect_RowWifi" : "Connect_RowUsb");
    public string Key => $"{Serial}|{State}|{Name}";
}

public sealed partial class ConnectViewModel : PageViewModel
{
    public override int StepIndex => 1;

    public ObservableCollection<FoundPhone> Phones { get; } = [];
    public bool NoPhone => Phones.Count == 0;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsBusy), nameof(IsWaiting), nameof(HasError), nameof(StatusText), nameof(ShowStatus))]
    private ConnectState _state;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(StatusText))]
    private string _errorDetail = "";

    /// <summary>Filled in by itself while the phone shows "Pair device with pairing code".</summary>
    [ObservableProperty] private string _pairAddress = "";
    [ObservableProperty] private string _pairCode = "";
    [ObservableProperty] private string _pairResult = "";
    [ObservableProperty] private bool _pairingSeen;
    [ObservableProperty] private bool _isPairing;
    [ObservableProperty] private string _manualAddress = "";

    private string _autoPairAddress = "";
    private string _pairingName = "";
    private CancellationTokenSource? _cts;
    private readonly CancellationTokenSource _watch = new();

    public bool IsBusy => State is ConnectState.Connecting or ConnectState.WaitingForApproval or ConnectState.Reading;
    public bool IsWaiting => State == ConnectState.WaitingForApproval;
    public bool HasError => State == ConnectState.Failed;
    public bool ShowStatus => State is ConnectState.Connecting or ConnectState.Reading or ConnectState.Failed;

    public string StatusText => State switch
    {
        ConnectState.Connecting => Loc.Get("Connect_Connecting"),
        ConnectState.Reading => Loc.Get("Connect_Reading"),
        ConnectState.Failed => ErrorDetail,
        _ => "",
    };

    public ConnectViewModel(MainViewModel main) : base(main) => _ = WatchAsync(_watch.Token);

    public override void OnLeave()
    {
        _watch.Cancel();
        _cts?.Cancel();
    }

    public override void OnLanguageChanged()
    {
        OnPropertyChanged(nameof(StatusText));
        var rows = Phones.ToList();
        Phones.Clear();
        foreach (var r in rows) Phones.Add(r);
    }

    /// <summary>Every two seconds: phones plugged in or on Wi-Fi, and an open pairing screen.</summary>
    private async Task WatchAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await RefreshAsync(); } catch { /* adb busy or restarting: try again */ }
            try { await Task.Delay(2000, ct); } catch (OperationCanceledException) { return; }
        }
    }

    private async Task RefreshAsync()
    {
        var devices = await Main.Adb.ListDevicesAsync();
        var services = await Main.Adb.MdnsServicesAsync();

        var rows = devices
            .Select(d => new FoundPhone(d.Serial, d.State, d.Model.Length > 0 ? d.Model : d.Serial, AdbService.IsWirelessSerial(d.Serial)))
            .ToList();
        // Paired phones with wireless debugging on that adb hasn't connected to yet.
        foreach (var s in services.Where(s => !s.Pairing))
            if (!devices.Any(d => d.Serial == s.Address || d.Serial.StartsWith(s.Name + ".")))
                rows.Add(new FoundPhone(s.Address, "announced", Loc.Get("Connect_WifiPhone"), wireless: true));

        if (!rows.Select(r => r.Key).SequenceEqual(Phones.Select(p => p.Key)))
        {
            Phones.Clear();
            foreach (var r in rows) Phones.Add(r);
            OnPropertyChanged(nameof(NoPhone));
        }

        var pairing = services.FirstOrDefault(s => s.Pairing);
        PairingSeen = pairing is not null;
        if (pairing is not null)
        {
            _pairingName = pairing.Name;
            if (PairAddress.Length == 0 || PairAddress == _autoPairAddress) PairAddress = _autoPairAddress = pairing.Address;
        }
    }

    [RelayCommand]
    private Task UseAsync(FoundPhone phone) => ConnectToAsync(phone.Serial, connectFirst: phone.State == "announced");

    [RelayCommand]
    private Task ConnectManualAsync()
    {
        if (Normalize(ManualAddress) is not { } target)
        {
            Fail(Loc.Get("Connect_BadAddress"));
            return Task.CompletedTask;
        }
        return ConnectToAsync(target, connectFirst: true);
    }

    [RelayCommand]
    private void Cancel()
    {
        _cts?.Cancel();
        State = ConnectState.Idle;
    }

    private async Task ConnectToAsync(string serial, bool connectFirst)
    {
        _cts?.Cancel();
        _cts = new CancellationTokenSource();
        var ct = _cts.Token;
        State = ConnectState.Connecting;
        try
        {
            if (connectFirst)
            {
                var r = await Main.Adb.RunAsync(["connect", serial], 20000, ct);
                if (!r.All.Contains("connected to"))
                {
                    Fail(Loc.Format("Connect_Refused", serial) + "\n" + r.All);
                    return;
                }
            }

            // Wait for "Allow USB debugging?" to be accepted on the phone (up to 3 minutes).
            var deadline = DateTime.UtcNow.AddMinutes(3);
            while (DateTime.UtcNow < deadline)
            {
                ct.ThrowIfCancellationRequested();
                var state = await Main.Adb.GetStateAsync(serial);
                if (state == "device") break;
                if (state == "unauthorized") State = ConnectState.WaitingForApproval;
                await Task.Delay(1500, ct);
            }
            if (await Main.Adb.GetStateAsync(serial) != "device")
            {
                Fail(Loc.Get("Connect_ApprovalTimeout"));
                return;
            }

            State = ConnectState.Reading;
            Main.Device = await PhoneDevice.LoadAsync(Main.Adb, serial);
            await Main.GoChooseAsync();
        }
        catch (OperationCanceledException) { State = ConnectState.Idle; }
        catch (Exception ex) { Fail(ex.Message); }
    }

    /// <summary>Pair with the code the phone shows, then connect to it straight away.</summary>
    [RelayCommand]
    private async Task PairAsync()
    {
        PairResult = "";
        var code = new string(PairCode.Where(char.IsDigit).ToArray());
        if (Normalize(PairAddress) is not { } target || code.Length != 6)
        {
            PairResult = Loc.Get("Connect_PairBadInput");
            return;
        }
        IsPairing = true;
        try
        {
            var r = await Main.Adb.RunAsync(["pair", target, code], 30000);
            if (!r.All.Contains("Successfully paired"))
            {
                PairResult = Loc.Get("Connect_PairFailed") + "\n" + r.All;
                return;
            }
            PairResult = Loc.Get("Connect_PairOk");
            PairCode = "";

            // The phone now announces its debugging port under the same name; adb usually connects by itself.
            var name = target == _autoPairAddress ? _pairingName : "";
            var host = target[..target.LastIndexOf(':')];
            for (var i = 0; i < 15; i++)
            {
                var devices = await Main.Adb.ListDevicesAsync();
                var ready = devices.FirstOrDefault(d => d.State == "device" &&
                    ((name.Length > 0 && d.Serial.StartsWith(name + ".")) || d.Serial.StartsWith(host + ":")));
                if (ready is not null) { await ConnectToAsync(ready.Serial, connectFirst: false); return; }
                var svc = (await Main.Adb.MdnsServicesAsync()).FirstOrDefault(s => !s.Pairing &&
                    ((name.Length > 0 && s.Name == name) || s.Address.StartsWith(host + ":")));
                if (svc is not null) { await ConnectToAsync(svc.Address, connectFirst: true); return; }
                await Task.Delay(1000);
            }
            PairResult = Loc.Get("Connect_PairOkNoPort");
        }
        finally { IsPairing = false; }
    }

    private void Fail(string message)
    {
        ErrorDetail = message;
        State = ConnectState.Failed;
    }

    /// <summary>"192.168.1.20:41234". Wireless debugging always uses its own port, so it is required.
    /// Accepts a comma typed instead of a dot.</summary>
    public static string? Normalize(string input)
    {
        var s = input.Trim().Replace(',', '.').Replace(" ", "");
        var colon = s.LastIndexOf(':');
        if (colon <= 0 || !int.TryParse(s[(colon + 1)..], out var port) || port is < 1 or > 65535) return null;
        return IPAddress.TryParse(s[..colon], out var ip) && ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork
            ? $"{ip}:{port}"
            : null;
    }
}
