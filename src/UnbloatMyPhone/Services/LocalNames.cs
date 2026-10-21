using System.Text.Json;
using UnbloatMyPhone.Models;

namespace UnbloatMyPhone.Services;

/// <summary>
/// Names the user gave to apps the catalog doesn't know, in app-names.json next to the backups.
/// Shown everywhere an app name is, and offered for sharing so the catalog can learn them.
/// </summary>
public static class LocalNames
{
    private static string FilePath => Path.Combine(AdbService.DataDir, "app-names.json");
    private static readonly Dictionary<string, string> Names = Load();

    private static Dictionary<string, string> Load()
    {
        try
        {
            return File.Exists(FilePath)
                ? JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(FilePath)) ?? []
                : [];
        }
        catch { return []; }
    }

    public static string? Get(string pkg) => Names.GetValueOrDefault(pkg);

    /// <summary>An empty name forgets it.</summary>
    public static void Set(string pkg, string name)
    {
        name = name.Trim();
        if (name.Length == 0) Names.Remove(pkg);
        else Names[pkg] = name.Length > 60 ? name[..60] : name;
        try
        {
            Directory.CreateDirectory(AdbService.DataDir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(Names, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { /* the name still shows until the app closes */ }
    }

    /// <summary>The names the catalog doesn't have yet: what is worth sharing.</summary>
    public static List<KeyValuePair<string, string>> NotInCatalog() =>
        Names.Where(n => Catalog.CatalogNameOf(n.Key) is null).OrderBy(n => n.Key).ToList();
}
