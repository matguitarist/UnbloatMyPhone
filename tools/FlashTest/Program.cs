using System.IO.Compression;
using UnbloatMyPhone.Localization;
using UnbloatMyPhone.Services;

// Usage: dotnet run --project tools/FlashTest -- <command> [args]
//   images <codename>                  list Google's images (reads web pages only)
//   state <serialNo>                   what adb and fastboot see (read-only)
//   script <factory.zip>               the steps the app would run (read-only)
//   otainfo <ota.zip>                  which phone and build an OTA is for (read-only)
//   download <codename> <build> [ota]  download and check an image
//   bootloader|android <serialNo>      restart into that mode
//   unlock|lock <serialNo>             bootloader lock (erases the phone)
//   factory <serialNo> <zip> [keep] [lock]   flash a factory image (erases unless "keep")
//   flashimg <serialNo> <partition> <img>   flash one image to the current slot
//   bootonce <serialNo> <img>          start once from an image
//   ota <serialNo> <zip>               sideload an official OTA
var adb = new AdbService();
var log = new ConsoleLog();
var ct = CancellationToken.None;
try
{
    switch (args)
    {
        case ["images", var code]:
            await UnbloatMyPhone.Models.Catalog.RefreshFromGitHubAsync();
            foreach (var i in await PixelImages.ListAsync(code))
                Console.WriteLine($"{(i.IsOta ? "ota    " : "factory")} {(i.IsBeta ? "beta" : "    ")} {i.Build,-22} {i.Label,-45} {i.Sha256[..12]} {i.FileName}");
            break;
        case ["state", var sn]:
            Console.WriteLine($"adb: {await adb.GetStateAsync(sn) ?? "absent"}");
            Console.WriteLine($"fastboot: {string.Join(", ", await Fastboot.ListAsync(adb))}");
            if (await Fastboot.ReadAsync(adb, sn) is { } b)
            {
                Console.WriteLine($"product={b.Product} unlocked={b.Unlocked} slot={b.Slot} battery={b.BatteryOk} bl={b.BootloaderVersion} radio={b.BasebandVersion} userspace={b.IsUserspace}");
                Console.WriteLine($"can unlock: {await Fastboot.CanUnlockAsync(adb, sn)}");
            }
            Console.WriteLine($"flash state: stock={FlashState.Get(sn)?.Stock} {FlashState.Get(sn)?.Image}");
            break;
        case ["otainfo", var zip]:
            Console.WriteLine(Flasher.ReadOtaMetadata(zip) is { } o ? $"{string.Join(",", o.Devices)} -> {o.Build}" : "not an OTA");
            break;
        case ["script", var zip]:
            using (var z = ZipFile.OpenRead(zip))
                foreach (var s in Flasher.ReadScript(z)) Console.WriteLine($"{s.Command} {s.Partition} {s.File}");
            Console.WriteLine($"for: {Flasher.CodenameOf(zip)}");
            break;
        case ["download", var code, var build, .. var rest]:
            await UnbloatMyPhone.Models.Catalog.RefreshFromGitHubAsync();
            var img = (await PixelImages.ListAsync(code)).First(i => i.Build == build.ToUpperInvariant() && i.IsOta == (rest is ["ota"]));
            var last = -1;
            Console.WriteLine(await PixelImages.DownloadAsync(img, new Progress<double>(p => { var pc = (int)(p * 100); if (pc / 5 != last / 5) Console.WriteLine($"{pc}%"); last = pc; }), ct));
            break;
        case ["bootloader", var sn]: await Flasher.ToBootloaderAsync(adb, sn, log, ct); break;
        case ["android", var sn]: Console.WriteLine((await Flasher.RebootFromBootloaderAsync(adb, sn, "", ct)).All); break;
        case ["unlock", var sn]: await Flasher.UnlockAsync(adb, sn, log, ct); break;
        case ["lock", var sn]: await Flasher.LockAsync(adb, sn, log, ct); break;
        case ["factory", var sn, var zip, .. var opts]:
            await Flasher.FactoryAsync(adb, sn, zip, wipe: !opts.Contains("keep"), lockAfter: opts.Contains("lock"), log, ct); break;
        case ["flashimg", var sn, var part, var file]: await Flasher.FlashImageAsync(adb, sn, part, file, false, false, log, ct); break;
        case ["bootonce", var sn, var file]: await Flasher.BootOnceAsync(adb, sn, file, log, ct); break;
        case ["ota", var sn, var zip]: await Flasher.SideloadAsync(adb, sn, zip, official: true, log, ct); break;
        default: Console.WriteLine("unknown command"); return 1;
    }
}
catch (FlashException e)
{
    Console.WriteLine("STOPPED: " + Loc.Format(e.Message, e.Args));
    return 2;
}
return 0;

sealed class ConsoleLog : IFlashLog
{
    private int _last = -1;
    public void Step(string key, params object[] args) => Console.WriteLine("== " + Loc.Format(key, args));
    public void Line(string text) => Console.WriteLine("   " + text);
    public void Progress(double? value)
    {
        var pc = value is { } v ? (int)(v * 100) : -1;
        if (pc / 10 != _last / 10) Console.WriteLine($"   [{(pc < 0 ? "…" : pc + "%")}]");
        _last = pc;
    }
}
