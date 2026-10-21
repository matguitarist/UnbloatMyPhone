using System.Text;
using UnbloatMyPhone.Models;

namespace UnbloatMyPhone.Services;

/// <summary>A pre-filled "new issue" link listing apps the catalog doesn't know. Only model and package names.</summary>
public static class IssueReport
{
    private const string NewIssue = "https://github.com/matguitarist/UnbloatMyPhone/issues/new";
    /// <summary>Browsers and GitHub cope with links up to about 8000 characters.</summary>
    private const int MaxUrl = 7000;

    /// <returns>The link, and whether every package fit in it.</returns>
    public static (string Url, bool Complete) Build(PhoneDevice dev, IReadOnlyList<string> packages, int catalogVersion)
    {
        var title = $"Unknown apps on {dev.DisplayName} (Android {dev.AndroidVersion})";
        string Body(int count, int left)
        {
            var b = new StringBuilder();
            b.AppendLine($"**Device:** {dev.DisplayName}, Android {dev.AndroidVersion} (SDK {dev.Sdk})");
            b.AppendLine($"**Catalog version:** {catalogVersion}");
            b.AppendLine();
            b.AppendLine("Preinstalled apps that are not in the catalog yet:");
            b.AppendLine("```");
            foreach (var p in packages.Take(count)) b.AppendLine(p);
            b.AppendLine("```");
            if (left > 0) b.AppendLine($"…and {left} more: the full list is on the clipboard, paste it here.");
            b.AppendLine();
            b.AppendLine("If you know what some of them do, add a line about it.");
            return b.ToString();
        }
        string Url(string body) => $"{NewIssue}?title={Uri.EscapeDataString(title)}&body={Uri.EscapeDataString(body)}";

        var url = Url(Body(packages.Count, 0));
        if (url.Length <= MaxUrl) return (url, true);
        var n = packages.Count;
        while (n > 0 && (url = Url(Body(n, packages.Count - n))).Length > MaxUrl) n--;
        return (url, false);
    }

    /// <summary>
    /// A pre-filled "App names" issue: only package names and the names the user typed. Named lines
    /// ("package = Name") are ready for tools/add-names.py; bare packages still need a name.
    /// </summary>
    /// <returns>The link, and whether every line fit in it.</returns>
    public static (string Url, bool Complete) BuildNames(IReadOnlyList<string> lines)
    {
        var named = lines.Count(l => l.Contains(" = "));
        var unnamed = lines.Count - named;
        var title = unnamed == 0 ? $"App names ({named})"
            : named == 0 ? $"Apps without a name ({unnamed})"
            : $"App names ({named} named, {unnamed} without a name)";
        string Body(int count, int left)
        {
            var b = new StringBuilder();
            b.AppendLine($"Apps the catalog has no name for, sent from UnbloatMyPhone {UpdateService.Current.ToString(3)}.");
            if (named > 0) b.AppendLine("Lines with \"= Name\" were named by the user.");
            if (unnamed > 0) b.AppendLine("The others still need a name: if you know one, add \" = Name\" after it.");
            b.AppendLine("```");
            foreach (var l in lines.Take(count)) b.AppendLine(l);
            b.AppendLine("```");
            if (left > 0) b.AppendLine($"…and {left} more: the full list is on the clipboard, paste it here.");
            return b.ToString();
        }
        string Url(string body) => $"{NewIssue}?title={Uri.EscapeDataString(title)}&body={Uri.EscapeDataString(body)}";

        var url = Url(Body(lines.Count, 0));
        if (url.Length <= MaxUrl) return (url, true);
        var n = lines.Count;
        while (n > 0 && (url = Url(Body(n, lines.Count - n))).Length > MaxUrl) n--;
        return (url, false);
    }
}
