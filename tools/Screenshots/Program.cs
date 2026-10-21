using UnbloatMyPhone;
using UnbloatMyPhone.Localization;
using UnbloatMyPhone.Models;
using UnbloatMyPhone.Services;
using UnbloatMyPhone.ViewModels;
using UnbloatMyPhone.Views;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Styling;
using Avalonia.Threading;

// Usage: dotnet run --project tools/Screenshots -- <output folder>
// Everything shown is made up: no phone is read, and nothing saved on this computer is shown.
var outDir = Path.GetFullPath(args.Length > 0 ? args[0] : "docs/screenshots");
Directory.CreateDirectory(outDir);

AppBuilder.Configure<App>()
    .UseSkia()
    .UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false })
    .WithInterFont()
    .SetupWithoutStarting();

// A made-up Pixel with a typical mix of preinstalled extras. The serial isn't a real one, so nothing reaches a phone.
var phone = new PhoneDevice
{
    Serial = "DEMO0000000000",
    Manufacturer = "Google", Brand = "google", Model = "Pixel 9", SerialNo = "DEMO",
    AndroidVersion = "16", Sdk = 36, RamMb = 11800, SetupComplete = true,
    HomePackage = "com.google.android.apps.nexuslauncher", InputMethodPackage = "com.google.android.inputmethod.latin",
    RoleHolders = ["com.google.android.dialer", "com.google.android.apps.messaging"],
    StorageTotalMb = 122000, StorageFreeMb = 61500,
    Enabled =
    [
        "com.google.android.feedback", "com.android.traceur", "com.google.android.apps.tips", "com.android.egg",
        "com.google.android.partnersetup", "com.android.dreams.basic", "com.google.android.printservice.recommendation",
        "com.android.printspooler", "com.android.bips", "com.google.android.apps.dreamliner", "com.google.android.apps.pixelmigrate",
        "com.google.android.apps.bard", "com.google.ar.core", "com.google.android.apps.pixel.nowplaying",
        "com.google.android.apps.privacy.wildlife", "com.google.android.apps.youtube.music", "com.google.android.videos",
        "com.google.android.apps.subscriptions.red", "com.google.android.apps.magazines", "com.google.android.apps.tachyon",
        "com.google.android.apps.photos", "com.google.android.apps.maps", "com.google.android.youtube",
        "com.google.android.apps.nexuslauncher", "com.google.android.inputmethod.latin",
        "com.google.android.dialer", "com.google.android.apps.messaging", "com.android.vending", "com.google.android.gms",
    ],
    ThirdParty = [],
};

void Shot(string name, ThemeVariant theme, string lang, Func<MainViewModel, PageViewModel> page, int height = 900, bool connected = true)
{
    Application.Current!.RequestedThemeVariant = theme;
    Loc.Instance.Language = lang;
    var main = new MainViewModel(new AdbService()) { Device = connected ? phone : null };
    main.CurrentPage = page(main);
    var w = new MainWindow { DataContext = main, Width = 1140, Height = height };
    w.Show();
    Dispatcher.UIThread.RunJobs();
    w.CaptureRenderedFrame()?.Save(Path.Combine(outDir, name + ".png"));
    w.Close();
    Console.WriteLine(name);
}

Shot("welcome-dark-en", ThemeVariant.Dark, "en", m => new WelcomeViewModel(m), 1000, connected: false);

// Choose, with made-up "last choices", never the ones saved on this computer.
ChooseViewModel Choose(MainViewModel m)
{
    var c = new ChooseViewModel(m, phone) { LastChoices = null };
    return c;
}
Shot("choose-dark-en", ThemeVariant.Dark, "en", Choose, 1500);
Shot("choose-dark-fr", ThemeVariant.Dark, "fr", Choose, 1500);

Shot("apply-dark-en", ThemeVariant.Dark, "en", m =>
{
    var a = new ApplyViewModel(m, phone, [], true);
    foreach (var (text, detail) in new[]
             {
                 ("Saving a backup on this computer", ""),
                 ("Google Feedback", ""),
                 ("Pixel Tips", ""),
                 ("Google Partner Setup", ""),
                 ("Block ads and trackers (DNS)", "dns.adguard-dns.com"),
                 ("Restarting the phone", ""),
                 ("Checking home screen and internet", "Home screen opens, internet and name lookups work."),
             })
        a.Items.Add(new StepItem(text) { State = StepState.Done, Detail = detail });
    a.BackupPath = @"C:\Users\you\AppData\Local\UnbloatMyPhone\backups\Google_Pixel_9-DEMO";
    a.AppsOff = 9;
    a.SettingsChanged = 2;
    a.IsFinished = true;
    return a;
}, 900);

Shot("info-dark-en", ThemeVariant.Dark, "en", m => new PhoneInfoViewModel(m, phone, read: false)
{
    Info = new PhoneInfo
    {
        AndroidVersion = "16", Codename = "REL", BuildId = "BP3A.251005.004",
        SecurityPatch = DateOnly.FromDateTime(DateTime.Today.AddDays(1 - DateTime.Today.Day)),
        BootloaderLocked = true, VerifiedBoot = "green",
    },
}, 1350);

Shot("health-dark-en", ThemeVariant.Dark, "en", m => new HealthViewModel(m, phone, read: false)
{
    Report = new HealthReport
    {
        MemTotalMb = 11800, MemAvailableMb = 4300, StorageTotalMb = 122000, StorageFreeMb = 61500,
        Load = 3.1, Cores = 8, UptimeHours = 70,
        TopMemory =
        [
            new("com.google.android.gms.persistent", 412), new("com.google.android.apps.nexuslauncher", 301),
            new("system", 288), new("com.android.systemui", 260), new("com.google.android.inputmethod.latin", 151),
            new("com.google.android.as", 140),
        ],
        Crashing = [new("com.google.android.apps.pixelmigrate", 9)],
    },
}, 900);

Shot("privacy-dark-en", ThemeVariant.Dark, "en", m =>
{
    var p = new PrivacyViewModel(m, phone, read: false);
    AccessKind Kind(string key) => Privacy.Kinds.First(k => k.Key == key);
    AppAccess A(string pkg, string kind, bool yours) => new(pkg, Kind(kind), ["android.permission.X"], yours);
    p.Show(
    [
        A("com.whatsapp", "BgLocation", true),
        A("com.google.android.apps.maps", "BgLocation", false),
        A("com.whatsapp", "Location", true), A("com.spotify.music", "Location", true),
        A("com.google.android.apps.maps", "Location", false), A("com.google.android.apps.photos", "Location", false),
        A("com.whatsapp", "Microphone", true), A("com.shazam.android", "Microphone", true),
        A("com.google.android.apps.tachyon", "Microphone", false),
        A("com.whatsapp", "Camera", true), A("com.instagram.android", "Camera", true),
        A("com.whatsapp", "Contacts", true), A("com.google.android.gm", "Contacts", false),
    ]);
    return p;
}, 1400);

// My apps: made-up apps with drawn icons, so no real app or brand appears.
byte[] Icon(string color, string letter)
{
    var tile = new Border
    {
        Width = 96, Height = 96, CornerRadius = new CornerRadius(22),
        Background = new SolidColorBrush(Color.Parse(color)),
        Child = new TextBlock
        {
            Text = letter, FontSize = 46, FontWeight = FontWeight.Bold, Foreground = Brushes.White,
            HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center,
            VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
        },
    };
    tile.Measure(new Size(96, 96));
    tile.Arrange(new Rect(0, 0, 96, 96));
    using var bmp = new RenderTargetBitmap(new PixelSize(96, 96));
    bmp.Render(tile);
    using var ms = new MemoryStream();
    bmp.Save(ms);
    return ms.ToArray();
}
var demoApps = new (string Pkg, string Label, string Color, string Installer, int Mb, int DaysAgo)[]
{
    ("com.example.budget", "Budget Buddy", "#2DA36B", "com.android.vending", 48, 200),
    ("com.example.chess", "Chess Club", "#5B6B82", "com.android.vending", 92, 30),
    ("com.example.notes", "Pocket Notes", "#E2A33A", "com.android.vending", 23, 400),
    ("com.example.podcasts", "Podcast Player", "#8E5BD9", "org.fdroid.fdroid", 61, 12),
    ("com.example.recipes", "Recipe Box", "#E0533D", "", 35, 3),
    ("com.example.trails", "Trail Maps", "#3B72F0", "com.android.vending", 186, 90),
    ("com.example.weather", "Weather Now", "#1FA3C4", "com.android.vending", 31, 600),
};
Shot("apps-dark-en", ThemeVariant.Dark, "en", m =>
{
    var a = new AppsViewModel(m, phone, read: false);
    var today = DateTime.Today;
    a.Show(
        demoApps.Select(d => new InstalledApp(d.Pkg, "2.4.1", d.Installer, today.AddDays(-d.DaysAgo), today.AddDays(-1),
            d.Mb * 1024L * 1024, 6 * 1024L * 1024, 2 * 1024L * 1024, IsEnabled: d.Pkg != "com.example.chess", HasIcon: true)),
        demoApps.ToDictionary(d => d.Pkg, d => new PhoneIcons.Entry(d.Label, Icon(d.Color, d.Label[..1]))));
    return a;
}, 1000);
