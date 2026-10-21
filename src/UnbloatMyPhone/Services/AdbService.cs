using System.Diagnostics;
using System.IO.Compression;

namespace UnbloatMyPhone.Services;

public sealed record AdbResult(int ExitCode, string Output, string Error)
{
    public bool Ok => ExitCode == 0;
    public string All => (Output + "\n" + Error).Trim();
}

/// <summary>One line of "adb devices -l". State is device, unauthorized or offline.</summary>
public sealed record AdbDevice(string Serial, string State, string Model);

/// <summary>A phone announcing wireless debugging: its pairing dialog, or its debugging port once paired.</summary>
public sealed record MdnsService(string Name, string Address, bool Pairing);

/// <summary>
/// Owns a private copy of Google's platform-tools (downloaded on first run) and runs adb.
/// </summary>
public sealed class AdbService
{
    public static string DataDir { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "UnbloatMyPhone");

    public static string BackupDir => Path.Combine(DataDir, "backups");

    public string ToolsDir => Path.Combine(DataDir, "platform-tools");
    public string AdbPath => Path.Combine(ToolsDir, OperatingSystem.IsWindows() ? "adb.exe" : "adb");
    public bool IsInstalled => File.Exists(AdbPath);

    private bool _serverStarted;

    private static string DownloadUrl
    {
        get
        {
            var os = OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsMacOS() ? "darwin" : "linux";
            return $"https://dl.google.com/android/repository/platform-tools-latest-{os}.zip";
        }
    }

    /// <summary>Download and unpack platform-tools from Google if they are not there yet.</summary>
    public async Task EnsureInstalledAsync(IProgress<double>? progress, CancellationToken ct = default)
    {
        if (IsInstalled) { progress?.Report(1); return; }

        Directory.CreateDirectory(DataDir);
        var zip = Path.Combine(DataDir, "platform-tools.zip");
        var tmp = Path.Combine(DataDir, "platform-tools.tmp");

        using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) })
        using (var resp = await http.GetAsync(DownloadUrl, HttpCompletionOption.ResponseHeadersRead, ct))
        {
            resp.EnsureSuccessStatusCode();
            var total = resp.Content.Headers.ContentLength ?? -1;
            await using var src = await resp.Content.ReadAsStreamAsync(ct);
            await using var dst = File.Create(zip);
            var buffer = new byte[81920];
            long read = 0;
            int n;
            while ((n = await src.ReadAsync(buffer, ct)) > 0)
            {
                await dst.WriteAsync(buffer.AsMemory(0, n), ct);
                read += n;
                if (total > 0) progress?.Report(Math.Min(0.99, (double)read / total));
            }
        }

        if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
        ZipFile.ExtractToDirectory(zip, tmp);
        if (Directory.Exists(ToolsDir)) Directory.Delete(ToolsDir, true);
        Directory.Move(Path.Combine(tmp, "platform-tools"), ToolsDir);
        Directory.Delete(tmp, true);
        File.Delete(zip);

        if (!OperatingSystem.IsWindows())
            File.SetUnixFileMode(AdbPath, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);

        progress?.Report(1);
    }

    /// <summary>
    /// Start the adb server without redirecting its output: the server outlives the call and
    /// would otherwise hold our pipes open forever.
    /// </summary>
    private async Task StartServerAsync()
    {
        if (_serverStarted) return;
        var psi = new ProcessStartInfo(AdbPath) { UseShellExecute = false, CreateNoWindow = true };
        psi.ArgumentList.Add("start-server");
        using var p = Process.Start(psi)!;
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        try { await p.WaitForExitAsync(cts.Token); } catch (OperationCanceledException) { }
        _serverStarted = true;
    }

    public async Task<AdbResult> RunAsync(IEnumerable<string> args, int timeoutMs = 20000, CancellationToken ct = default)
    {
        await StartServerAsync();
        var psi = new ProcessStartInfo(AdbPath)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            // adb speaks UTF-8; Windows would otherwise read it in the console's code page.
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);

        using var p = Process.Start(psi)!;
        var stdout = p.StandardOutput.ReadToEndAsync(ct);
        var stderr = p.StandardError.ReadToEndAsync(ct);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeoutMs);
        try
        {
            await p.WaitForExitAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            try { p.Kill(true); } catch { }
            return new AdbResult(-1, "", "timeout");
        }
        return new AdbResult(p.ExitCode, (await stdout).Replace("\r", ""), (await stderr).Replace("\r", ""));
    }

    public Task<AdbResult> ShellAsync(string serial, string command, int timeoutMs = 20000) =>
        RunAsync(["-s", serial, "shell", command], timeoutMs);

    /// <summary>State of one device in "adb devices": device, unauthorized, offline, or null if absent.</summary>
    public async Task<string?> GetStateAsync(string serial)
    {
        var r = await RunAsync(["devices"], 10000);
        foreach (var line in r.Output.Split('\n'))
        {
            var parts = line.Split(['\t', ' '], StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length >= 2 && parts[0] == serial) return parts[1];
        }
        return null;
    }

    /// <summary>"192.168.1.20:41234", or "adb-SERIAL-xyz._adb-tls-connect._tcp" when adb found the phone on its own.</summary>
    public static bool IsWirelessSerial(string serial) => serial.Contains(':') || serial.Contains("._adb-tls-connect.");

    /// <summary>Every phone adb sees, from "adb devices -l".</summary>
    public async Task<List<AdbDevice>> ListDevicesAsync()
    {
        var r = await RunAsync(["devices", "-l"], 10000);
        var list = new List<AdbDevice>();
        foreach (var line in r.Output.Split('\n').Skip(1))
        {
            var parts = line.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2) continue;
            var model = parts.FirstOrDefault(x => x.StartsWith("model:"))?["model:".Length..].Replace('_', ' ') ?? "";
            list.Add(new AdbDevice(parts[0], parts[1], model));
        }
        return list;
    }

    /// <summary>What wireless debugging announces on the network ("adb mdns services").</summary>
    public async Task<List<MdnsService>> MdnsServicesAsync()
    {
        var r = await RunAsync(["mdns", "services"], 10000);
        var list = new List<MdnsService>();
        foreach (var line in r.Output.Split('\n'))
        {
            // adb-SERIAL-xyz	_adb-tls-pairing._tcp	192.168.1.20:37099
            var parts = line.Split(['\t', ' '], StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 3 || !parts[2].Contains(':')) continue;
            if (parts[1].StartsWith("_adb-tls-pairing")) list.Add(new MdnsService(parts[0], parts[2], Pairing: true));
            else if (parts[1].StartsWith("_adb-tls-connect")) list.Add(new MdnsService(parts[0], parts[2], Pairing: false));
        }
        return list;
    }

    /// <summary>
    /// The serial a phone answers on now. Over Wi-Fi the port changes when the phone restarts,
    /// so look for it again by its hardware serial number and reconnect.
    /// </summary>
    public async Task<string?> FindAgainAsync(string serial, string serialNo)
    {
        var devices = await ListDevicesAsync();
        if (devices.Any(d => d.Serial == serial && d.State == "device")) return serial;
        if (serialNo.Length == 0) return null;
        if (devices.FirstOrDefault(d => d.State == "device" && (d.Serial == serialNo || d.Serial.StartsWith($"adb-{serialNo}-"))) is { } same)
            return same.Serial;
        if ((await MdnsServicesAsync()).FirstOrDefault(s => !s.Pairing && s.Name.StartsWith($"adb-{serialNo}-")) is { } svc)
        {
            await RunAsync(["connect", svc.Address], 10000);
            if (await GetStateAsync(svc.Address) == "device") return svc.Address;
        }
        return null;
    }

    public void KillServer()
    {
        if (!IsInstalled || !_serverStarted) return;
        try
        {
            var psi = new ProcessStartInfo(AdbPath) { UseShellExecute = false, CreateNoWindow = true };
            psi.ArgumentList.Add("kill-server");
            using var p = Process.Start(psi);
            p?.WaitForExit(3000);
        }
        catch { }
    }
}
