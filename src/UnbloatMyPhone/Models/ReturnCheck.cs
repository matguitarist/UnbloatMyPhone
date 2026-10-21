using UnbloatMyPhone.Services;

namespace UnbloatMyPhone.Models;

/// <summary>What earlier runs turned off or changed that is back the way it was, usually after a system update.</summary>
public sealed record ReturnedItems(DateTime Since, List<string> Packages, List<SettingChange> Settings)
{
    public int Count => Packages.Count + Settings.Count;
}

public static class ReturnCheck
{
    /// <summary>Compare the phone with the backups of runs that weren't undone. Read-only.</summary>
    public static async Task<ReturnedItems?> FindAsync(AdbService adb, PhoneDevice dev)
    {
        var runs = Backup.ListFor(dev); // newest first, undone runs excluded
        if (runs.Count == 0) return null;

        var packages = runs.SelectMany(r => r.DisabledPackages).Distinct()
            .Where(dev.Enabled.Contains)
            .Where(p => !runs.Any(r => r.EnabledPackages.Contains(p))) // turned back on on purpose
            .OrderBy(p => p).ToList();

        // The latest value we set for each setting.
        var wanted = new Dictionary<(string, string), SettingChange>();
        foreach (var run in runs)
            foreach (var s in run.Settings)
                wanted.TryAdd((s.Namespace, s.Key), s);

        // One shell call reads them all: "@@<n>" before each value.
        var list = wanted.Values.ToList();
        var settings = new List<SettingChange>();
        if (list.Count > 0)
        {
            var script = string.Join("; ", list.Select((s, i) =>
            {
                var (cmd, ns) = s.Namespace.StartsWith("device_config:")
                    ? ("device_config", s.Namespace["device_config:".Length..]) : ("settings", s.Namespace);
                return $"echo @@{i}; {cmd} get {ns} {s.Key}";
            }));
            var r = await adb.ShellAsync(dev.Serial, script, 30000);
            var values = new Dictionary<int, string>();
            var current = -1;
            foreach (var line in r.Output.Split('\n'))
            {
                if (line.StartsWith("@@") && int.TryParse(line[2..].Trim(), out var n)) current = n;
                else if (current >= 0 && !values.ContainsKey(current)) values[current] = line.Trim();
            }
            for (var i = 0; i < list.Count; i++)
            {
                var now = values.GetValueOrDefault(i, "");
                if (now != list[i].NewValue && now.Length > 0) settings.Add(list[i]);
            }
        }

        var result = new ReturnedItems(runs[0].Created, packages, settings);
        return result.Count > 0 ? result : null;
    }
}
