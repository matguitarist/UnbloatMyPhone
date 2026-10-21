using System.Security.Cryptography;
using System.Text.RegularExpressions;
using UnbloatMyPhone.Models;

namespace UnbloatMyPhone.Services;

/// <summary>One of Google's official images for a Pixel: a full factory image or an OTA update.</summary>
/// <param name="Build">"CP3A.261005.002.A1"</param>
/// <param name="Label">"17.0.0 (CP3A.261005.002.A1, Oct 2026)" or "Android 17 QPR3 Beta"</param>
public sealed record PixelImage(bool IsOta, bool IsBeta, string Build, string Label, string Url, string Sha256)
{
    public string FileName => Url[(Url.LastIndexOf('/') + 1)..];
    /// <summary>"261005" from "CP3A.261005.002.A1": the build date, to sort by.</summary>
    public string Date => Build.Split('.').ElementAtOrDefault(1) ?? "";
}

/// <summary>
/// Finds Google's factory and OTA images for a Pixel on Google's own pages (listed in the catalog,
/// so a moved page can be fixed without an update), and downloads them with their checksum checked.
/// </summary>
public static partial class PixelImages
{
    public static string Folder => Path.Combine(AdbService.DataDir, "images");

    /// <summary>
    /// Google shows its terms before the lists; this cookie is what the page sets when you accept them.
    /// The app asks the user to accept the same terms first.
    /// </summary>
    private const string AcceptedTerms = "devsite_wall_acks=nexus-image-tos,nexus-ota-tos";

    [GeneratedRegex(@"https://dl\.google\.com/[^""'\s<>]+\.zip")]
    private static partial Regex ZipUrl();
    [GeneratedRegex(@"\b[0-9a-f]{64}\b")]
    private static partial Regex Sha();
    [GeneratedRegex(@"<td>\s*([^<]*\([A-Z0-9.]+[^<]*\))\s*</td>")]
    private static partial Regex RowLabel();

    /// <summary>Every image for this codename, newest first. Pages that can't be read are skipped.</summary>
    public static async Task<List<PixelImage>> ListAsync(string codename, CancellationToken ct = default)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(40) };
        http.DefaultRequestHeaders.Add("Cookie", AcceptedTerms);
        var found = new List<PixelImage>();
        foreach (var page in Catalog.ImagePages)
        {
            try { found.AddRange(Parse(await http.GetStringAsync(page.Url, ct), codename, page.IsOta, page.IsBeta, page.Name)); }
            catch (Exception) when (!ct.IsCancellationRequested) { }
        }
        return found.DistinctBy(i => i.Url).OrderByDescending(i => i.Date).ThenBy(i => i.IsBeta).ToList();
    }

    /// <summary>
    /// The images on one page for this codename. A file's checksum is the first one after its name
    /// with no other file in between; beta pages put the link elsewhere and the name on a button.
    /// </summary>
    public static List<PixelImage> Parse(string html, string codename, bool isOta, bool isBeta, string betaName)
    {
        var list = new List<PixelImage>();
        foreach (var url in ZipUrl().Matches(html).Select(m => m.Value).Distinct())
        {
            var file = url[(url.LastIndexOf('/') + 1)..];
            // cheetah-cp3a.261005.002.a1-factory-5b5b06ad.zip, cheetah-ota-…, cheetah_beta-cp41.…-factory-…
            if (!file.StartsWith(codename + "-") && !file.StartsWith(codename + "_beta-")) continue;
            if (file.Contains("-ota-") != isOta) continue;
            var parts = file.Split('-');
            var build = (isOta ? parts.ElementAtOrDefault(2) : parts.ElementAtOrDefault(1))?.ToUpperInvariant() ?? "";
            if (build.Length == 0) continue;

            string? sha = null, label = null;
            for (var at = html.IndexOf(file, StringComparison.Ordinal); at >= 0 && sha is null; at = html.IndexOf(file, at + file.Length, StringComparison.Ordinal))
            {
                var after = html[(at + file.Length)..Math.Min(html.Length, at + file.Length + 600)];
                var m = Sha().Match(after);
                if (m.Success && !after[..m.Index].Contains(".zip")) sha = m.Value;
                // Stable pages: "17.0.0 (CP3A.261005.002.A1, Oct 2026)" a little before the link.
                var before = html[Math.Max(0, at - 700)..at];
                if (RowLabel().Matches(before).LastOrDefault() is { } l && l.Value.Contains(build, StringComparison.OrdinalIgnoreCase))
                    label = System.Net.WebUtility.HtmlDecode(l.Groups[1].Value.Trim());
            }
            if (sha is null) continue;
            list.Add(new PixelImage(isOta, isBeta, build, isBeta ? $"{betaName} ({build})" : label ?? build, url, sha));
        }
        return list;
    }

    /// <summary>Where a download goes, kept for next time.</summary>
    public static string LocalPath(PixelImage image) => Path.Combine(Folder, image.FileName);

    public static bool IsDownloaded(PixelImage image) => File.Exists(LocalPath(image));

    /// <summary>Free space where downloads go, in bytes.</summary>
    public static long FreeSpace()
    {
        Directory.CreateDirectory(Folder);
        return new DriveInfo(Path.GetPathRoot(Path.GetFullPath(Folder))!).AvailableFreeSpace;
    }

    public static async Task<long> SizeAsync(PixelImage image, CancellationToken ct = default)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        using var resp = await http.SendAsync(new HttpRequestMessage(HttpMethod.Head, image.Url), ct);
        return resp.Content.Headers.ContentLength ?? 0;
    }

    /// <summary>
    /// Download the image, resuming a partial download, and check its SHA-256 against Google's.
    /// A file that doesn't match is deleted. Progress is 0 to 1.
    /// </summary>
    public static async Task<string> DownloadAsync(PixelImage image, IProgress<double> progress, CancellationToken ct)
    {
        Directory.CreateDirectory(Folder);
        var path = LocalPath(image);
        if (File.Exists(path)) return path;
        var part = path + ".part";
        using (var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan })
        {
            var have = File.Exists(part) ? new FileInfo(part).Length : 0;
            var req = new HttpRequestMessage(HttpMethod.Get, image.Url);
            if (have > 0) req.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(have, null);
            using var resp = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
            resp.EnsureSuccessStatusCode();
            if (resp.StatusCode != System.Net.HttpStatusCode.PartialContent) have = 0;
            var total = have + (resp.Content.Headers.ContentLength ?? 0);
            await using var src = await resp.Content.ReadAsStreamAsync(ct);
            await using var dst = new FileStream(part, have > 0 ? FileMode.Append : FileMode.Create);
            var buffer = new byte[1 << 20];
            var read = have;
            int n;
            while ((n = await src.ReadAsync(buffer, ct)) > 0)
            {
                await dst.WriteAsync(buffer.AsMemory(0, n), ct);
                read += n;
                if (total > 0) progress.Report(0.95 * read / total);
            }
        }
        if (!await MatchesAsync(part, image.Sha256, ct))
        {
            File.Delete(part);
            throw new InvalidDataException("checksum");
        }
        File.Move(part, path, true);
        progress.Report(1);
        return path;
    }

    public static async Task<bool> MatchesAsync(string path, string sha256, CancellationToken ct)
    {
        await using var f = File.OpenRead(path);
        var hash = await SHA256.HashDataAsync(f, ct);
        return Convert.ToHexStringLower(hash) == sha256.ToLowerInvariant();
    }
}
