using UnbloatMyPhone.Models;
using UnbloatMyPhone.Services;
using UnbloatMyPhone.ViewModels;
using UnbloatMyPhone.Views;
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;

namespace UnbloatMyPhone;

public partial class App : Application
{
    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            UpdateService.CleanUpAfterUpdate();
            var main = new MainViewModel(new AdbService());
            desktop.MainWindow = new MainWindow { DataContext = main };
            _ = main.Updater.CheckInBackgroundAsync();
            _ = Catalog.RefreshFromGitHubAsync();
            // Leave no adb server running in the background once the app is closed.
            desktop.Exit += (_, _) => main.Adb.KillServer();
        }
        base.OnFrameworkInitializationCompleted();
    }
}
