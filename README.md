<p align="center"><img src="docs/icon.png" width="96" alt=""></p>

<h1 align="center">UnbloatMyPhone</h1>

<p align="center">
  Turn off the preinstalled apps, tracking and extras you don't use on an Android phone.<br>
  For Windows, macOS and Linux. Plain-language choices, a backup of everything, one-click undo.
</p>

<p align="center">
  <a href="../../releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/matguitarist/UnbloatMyPhone?label=download"></a>
  <img alt="Android phones" src="https://img.shields.io/badge/Android%20phones%20%C2%B7%20Google%20Pixel-green">
  <img alt="Windows, macOS, Linux" src="https://img.shields.io/badge/Windows%20%C2%B7%20macOS%20%C2%B7%20Linux-blue">
  <a href="LICENSE"><img alt="MIT licence" src="https://img.shields.io/github/license/matguitarist/UnbloatMyPhone"></a>
  <br><sub>The phone sibling of <a href="https://github.com/matguitarist/UnbloatMyTV">UnbloatMyTV</a>.</sub>
  <br><a href="README.fr.md">Version française</a>
</p>

> **Early version.** The list of apps is tuned for Google Pixel phones first. Other brands get the
> Android and Google parts, and the app helps you suggest the rest.

## Download

Get the file for your computer from the **[latest release](../../releases/latest)**. Nothing else to
install: the first time, the app downloads Google's official ADB tools (about 7 MB, from
`dl.google.com`) into its own folder.

| | File | First launch |
|---|---|---|
| **Windows** 10/11 | `UnbloatMyPhone.exe` | SmartScreen may say the publisher is unknown (the exe isn't code-signed yet): **More info → Run anyway**. A Pixel may need [Google's USB driver](https://developer.android.com/studio/run/win-usb). |
| **macOS** 14+ | `UnbloatMyPhone-mac.zip` | Native Mac app for Apple silicon and Intel, signed and notarized by Apple. Unzip, move it to Applications and open it. |
| **Linux** x64 | `UnbloatMyPhone-x86_64.AppImage` | Make it executable (`chmod +x`) and open it. For USB, your user may need access to the phone (the `android-udev-rules` package on most distributions). |

Every version updates itself: it shows what's new and installs the update in a few seconds.

## What it does

**Clean up**
- **Finds your phone on its own**, plugged in by USB or over Wi-Fi with wireless debugging: type the
  6-digit pairing code and it connects. No root.
- **Lists only what is on your phone**, explained in plain words: diagnostics, unused system parts,
  Google features, preinstalled apps, and speed and privacy settings.
- **Ticks the safe choices for you.** Anything you might use (Photos, Maps, the Google app, Personal
  Safety…) is left unticked, with a warning that says what stops working.
- **Never touches what the phone needs**: the Phone and Messages apps you use, the keyboard, the home
  screen, Settings, Google Play services, emergency alerts and the core of Android.
- **Blocks ads and trackers for the whole phone** with a filtering DNS, tested on the spot and undone
  if it breaks anything.
- **Backs up, applies, restarts the phone and checks it**: home screen, internet, name lookups.

**Keep it clean**
- **Notices when an update undoes your cleanup** and ticks what came back in one click.
- **Same choices on the next phone**, and choices can be saved to a file to reuse anywhere.
- **Undo any run exactly** from Restore, or turn every app back on in one click.
- **Turns debugging off for you** when you are done.

**Tools**
- **Privacy check-up**: which apps can use your location (and "all the time"), microphone, camera,
  contacts, text messages, call log and calendar. Remove an access in one click; Restore gives it back.
- **Phone info**: Android version, how old the security update is, the beta and how to leave it
  without losing anything, bootloader and verified boot. Opens System update or the reset screen
  on the phone, and restarts it normally, into recovery or into bootloader mode (after asking).
- **Health check**: memory, storage, processor, the apps using the most memory, and apps stuck in a
  crash loop, with plain advice. Read-only.
- **My apps**: the apps you installed, with their size, version, install date and where they came
  from (Google Play, a file, another store). Open, force stop, turn off (undo from Restore),
  archive (Android 15+, keeps the data) or uninstall each one.
- **Install an app**: drop an `.apk` on the window.

Nothing is uninstalled: apps are switched off with Android's own `pm disable-user`, and a factory
reset brings everything back too. English and French; light and dark themes follow your system.

## Before you start, on the phone

1. **Settings → About phone**: tap **Build number** 7 times, until it says you are a developer.
2. **Settings → System → Developer options → USB debugging** on.
3. Plug the phone in. No cable? Turn on **Wireless debugging** in the same menu, open **Pair device
   with pairing code**, and type the code in the app.
4. Accept **Allow USB debugging?** on the phone and tick *Always allow from this computer*.

When you are done, the last screen turns debugging off again.

## How it stays safe

- Only apps in a reviewed list ([`shared/catalog.json`](shared/catalog.json)) are offered.
- Never offered, whatever the list says: the default Phone and SMS apps, any app that can be the home
  screen, the keyboard, the app that manages a work profile or company phone, Settings, the Play Store, Google Play services, WebView, telephony, Bluetooth,
  NFC, emergency alerts and the core of Android (the list's `keep` section and a built-in list).
- Every change is written to a backup with its original value *before* it is made, so even an
  interrupted run can be undone.
- Backups live in `%LOCALAPPDATA%\UnbloatMyPhone\backups` (Mac:
  `~/Library/Application Support/UnbloatMyPhone/backups`, Linux: `~/.local/share/UnbloatMyPhone/backups`),
  with a raw snapshot of all packages and settings. Same format on every system.

## Privacy

The app has no account, no analytics and no server of its own. Besides your phone, it only contacts:
- `dl.google.com`, once, to download Google's ADB tools;
- `github.com` to check for a new version (this can be turned off in the update window) and to fetch
  the latest list of apps;
- GitHub's "new issue" page in your browser, only if you click **Suggest them on GitHub**, with the
  phone model and app names filled in for you to review.

## For developers

**Windows and Linux app** (`src/`, C# with Avalonia): [.NET 10 SDK](https://dotnet.microsoft.com/download).
```sh
dotnet run --project src/UnbloatMyPhone                               # run it (any system)
dotnet publish src/UnbloatMyPhone -c Release -r win-x64 -o publish    # single Windows exe
linux/build-appimage.sh                                               # AppImage (on Linux)
```

**Mac app** (`mac/`, Swift and SwiftUI, updates with [Sparkle](https://sparkle-project.org)): Xcode,
then `mac/build-app.sh`. Its text comes from the Windows app's `Strings.cs`: after changing it, run
`python3 tools/gen-mac-strings.py`.

**The list of apps** is [`shared/catalog.json`](shared/catalog.json), used by both apps. Each entry
has a package `id` (or a `prefix`), a `group`, `recommended`, and `name` / `description` (plus an
optional `warning`) in English and French; settings and the `keep` list live there too. Only mark
something `recommended` if switching it off changes nothing anyone would notice, test it on a real
phone, and **increase `version`**: every installed copy picks up the new list from `main`.

**Releases**: bump `<Version>` in the csproj and push an annotated tag such as `v0.2.0`. GitHub
Actions builds all three, signs and notarizes the Mac app, and publishes the release; the tag
message becomes the notes shown in the update window.

## Licence

MIT. Use at your own risk: the app only switches things off and back on, but it is your phone.
