using AudioRecorder.Core.Services;
using AudioRecorder.Services.Models;
using AudioRecorder.Services.Settings;
using AudioRecorder.Services.Transcription;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AudioRecorder.Views;

public sealed partial class SettingsWindow : Window
{
    private readonly WhisperRuntimeInstallerService _runtimeInstaller;
    private readonly FfmpegInstallerService _ffmpegInstaller;
    private readonly SharedModelConfigService _sharedConfigService;
    private readonly ISettingsService _settingsService;
    private readonly DispatcherQueue _dispatcherQueue;

    private CancellationTokenSource? _runtimeDownloadCts;
    private CancellationTokenSource? _modelDownloadCts;
    private CancellationTokenSource? _ffmpegDownloadCts;
    private bool _isRuntimeDownloading;
    private bool _isModelDownloading;
    private bool _isFfmpegDownloading;

    private Action? _onSettingsChanged;

    public SettingsWindow(
        WhisperRuntimeInstallerService runtimeInstaller,
        FfmpegInstallerService ffmpegInstaller,
        SharedModelConfigService sharedConfigService,
        ISettingsService settingsService,
        Action? onSettingsChanged = null)
    {
        InitializeComponent();

        _runtimeInstaller = runtimeInstaller;
        _ffmpegInstaller = ffmpegInstaller;
        _sharedConfigService = sharedConfigService;
        _settingsService = settingsService;
        _onSettingsChanged = onSettingsChanged;
        _dispatcherQueue = DispatcherQueue.GetForCurrentThread();

        Title = "Settings — Contora";

        // Set initial size
        var hWnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var windowId = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(hWnd);
        var appWindow = Microsoft.UI.Windowing.AppWindow.GetFromWindowId(windowId);
        appWindow.Resize(new Windows.Graphics.SizeInt32(800, 650));

        // Select first nav item
        SettingsNavView.SelectedItem = SettingsNavView.MenuItems[0];

        Closed += OnWindowClosed;
        _ = LoadAllDataAsync();
    }

    private void OnWindowClosed(object sender, WindowEventArgs args)
    {
        _runtimeDownloadCts?.Cancel();
        _modelDownloadCts?.Cancel();
        _ffmpegDownloadCts?.Cancel();
        App.SettingsWindowInstance = null;
    }

    private void OnNavSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem item && item.Tag is string tag)
        {
            EnginesSection.Visibility = tag == "engines" ? Visibility.Visible : Visibility.Collapsed;
            ModelsSection.Visibility = tag == "models" ? Visibility.Visible : Visibility.Collapsed;
            StorageSection.Visibility = tag == "storage" ? Visibility.Visible : Visibility.Collapsed;
            GeneralSection.Visibility = tag == "general" ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    private async Task LoadAllDataAsync()
    {
        await LoadEnginesDataAsync();
        await LoadModelsDataAsync();
        LoadStorageData();
        LoadGeneralData();
    }

    // ─── Engines ───

    private async Task LoadEnginesDataAsync()
    {
        var installed = _runtimeInstaller.IsRuntimeInstalled();
        RuntimeStatusText.Text = installed ? "Installed" : "Not installed";
        RuntimePathText.Text = installed ? _runtimeInstaller.GetRuntimeExePath() : "—";

        if (installed)
        {
            DownloadRuntimeBtn.Visibility = Visibility.Collapsed;
            DeleteRuntimeBtn.Visibility = Visibility.Visible;

            var config = await _sharedConfigService.LoadAsync();
            var runtime = config.InstalledRuntimes.FirstOrDefault(r => r.Id == "faster-whisper-xxl");
            RuntimeSizeText.Text = runtime != null ? FormatFileSize(runtime.DiskUsageBytes) : "calculating...";

            if (runtime == null)
            {
                // Auto-register on first settings open
                await _sharedConfigService.RegisterRuntimeAsync(
                    "faster-whisper-xxl",
                    "Faster Whisper XXL",
                    _runtimeInstaller.GetRuntimeExePath());
                var updatedConfig = await _sharedConfigService.LoadAsync();
                var updatedRuntime = updatedConfig.InstalledRuntimes.FirstOrDefault(r => r.Id == "faster-whisper-xxl");
                if (updatedRuntime != null)
                    RuntimeSizeText.Text = FormatFileSize(updatedRuntime.DiskUsageBytes);
            }
        }
        else
        {
            DownloadRuntimeBtn.Visibility = Visibility.Visible;
            DeleteRuntimeBtn.Visibility = Visibility.Collapsed;
            RuntimeSizeText.Text = "—";
        }
    }

    private async void OnDownloadRuntimeClicked(object sender, RoutedEventArgs e)
    {
        if (_isRuntimeDownloading) return;
        _isRuntimeDownloading = true;
        _runtimeDownloadCts = new CancellationTokenSource();

        DownloadRuntimeBtn.Visibility = Visibility.Collapsed;
        CancelRuntimeBtn.Visibility = Visibility.Visible;
        RuntimeProgressBar.Visibility = Visibility.Visible;
        RuntimeProgressBar.Value = 0;
        RuntimeProgressText.Visibility = Visibility.Visible;
        RuntimeProgressText.Text = "Starting...";

        try
        {
            var result = await _runtimeInstaller.InstallAsync(
                progress =>
                {
                    _dispatcherQueue.TryEnqueue(() =>
                    {
                        RuntimeProgressBar.Value = progress.Percent;
                        RuntimeProgressText.Text = progress.StatusMessage;
                    });
                },
                _runtimeDownloadCts.Token);

            RuntimeProgressText.Text = result.StatusMessage;

            if (result.Success)
            {
                await _sharedConfigService.RegisterRuntimeAsync(
                    "faster-whisper-xxl",
                    "Faster Whisper XXL",
                    result.WhisperExePath!);
                _onSettingsChanged?.Invoke();
            }
        }
        finally
        {
            _runtimeDownloadCts?.Dispose();
            _runtimeDownloadCts = null;
            _isRuntimeDownloading = false;
            CancelRuntimeBtn.Visibility = Visibility.Collapsed;
            await LoadEnginesDataAsync();
            LoadStorageData();
        }
    }

    private void OnCancelRuntimeClicked(object sender, RoutedEventArgs e)
    {
        _runtimeDownloadCts?.Cancel();
    }

    private async void OnDeleteRuntimeClicked(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            Title = "Delete runtime?",
            Content = "This will remove the Faster Whisper XXL runtime from disk. You can re-download it later.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Content.XamlRoot
        };

        var result = await dialog.ShowAsync();
        if (result != ContentDialogResult.Primary) return;

        try
        {
            var runtimeRoot = WhisperPaths.GetCanonicalRuntimeRoot();
            if (Directory.Exists(runtimeRoot))
                Directory.Delete(runtimeRoot, recursive: true);

            await _sharedConfigService.UnregisterRuntimeAsync("faster-whisper-xxl");
            _onSettingsChanged?.Invoke();
        }
        catch (Exception ex)
        {
            RuntimeProgressText.Visibility = Visibility.Visible;
            RuntimeProgressText.Text = $"Delete failed: {ex.Message}";
        }

        await LoadEnginesDataAsync();
        LoadStorageData();
    }

    // ─── Models ───

    private async Task LoadModelsDataAsync()
    {
        await _sharedConfigService.RefreshFromDiskAsync();
        var config = await _sharedConfigService.LoadAsync();
        InstalledModelsPanel.Children.Clear();

        if (config.InstalledModels.Count == 0)
        {
            InstalledModelsPanel.Children.Add(new TextBlock
            {
                Text = "No models installed yet.",
                FontSize = 12,
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"]
            });
            return;
        }

        foreach (var model in config.InstalledModels)
        {
            var card = new Border
            {
                Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardBackgroundFillColorSecondaryBrush"],
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(12, 8, 12, 8)
            };

            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var info = new StackPanel { Spacing = 2 };
            var nameText = new TextBlock
            {
                Text = model.Name,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold
            };
            var sizeText = new TextBlock
            {
                Text = FormatFileSize(model.SizeBytes),
                FontSize = 11,
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"]
            };
            info.Children.Add(nameText);
            info.Children.Add(sizeText);
            Grid.SetColumn(info, 0);
            grid.Children.Add(info);

            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
            var deleteBtn = new Button { Content = "Delete", Padding = new Thickness(8, 4, 8, 4) };
            var modelName = model.Name;
            var modelRuntimeId = model.RuntimeId;
            var modelDir = model.DirectoryPath;
            deleteBtn.Click += async (_, _) =>
            {
                try
                {
                    if (Directory.Exists(modelDir))
                        Directory.Delete(modelDir, recursive: true);
                    await _sharedConfigService.UnregisterModelAsync(modelName, modelRuntimeId);
                    _onSettingsChanged?.Invoke();
                    await LoadModelsDataAsync();
                    LoadStorageData();
                }
                catch (Exception ex)
                {
                    ModelProgressText.Visibility = Visibility.Visible;
                    ModelProgressText.Text = $"Delete failed: {ex.Message}";
                }
            };
            buttons.Children.Add(deleteBtn);
            Grid.SetColumn(buttons, 1);
            grid.Children.Add(buttons);

            card.Child = grid;
            InstalledModelsPanel.Children.Add(card);
        }
    }

    private async void OnDownloadModelClicked(object sender, RoutedEventArgs e)
    {
        if (_isModelDownloading) return;

        if (ModelSelectorCombo.SelectedItem is not ComboBoxItem item) return;
        var modelName = item.Tag?.ToString() ?? "large-v2";

        if (!_runtimeInstaller.IsRuntimeInstalled())
        {
            ModelProgressText.Visibility = Visibility.Visible;
            ModelProgressText.Text = "Install runtime first before downloading models.";
            return;
        }

        _isModelDownloading = true;
        _modelDownloadCts = new CancellationTokenSource();

        DownloadModelBtn.IsEnabled = false;
        CancelModelBtn.Visibility = Visibility.Visible;
        ModelProgressBar.Visibility = Visibility.Visible;
        ModelProgressBar.Value = 0;
        ModelProgressText.Visibility = Visibility.Visible;
        ModelProgressText.Text = $"Downloading model '{modelName}'...";

        var svc = new WhisperModelDownloadService(modelName);

        try
        {
            var result = await svc.DownloadModelAsync(
                progress =>
                {
                    _dispatcherQueue.TryEnqueue(() =>
                    {
                        ModelProgressBar.Value = progress.Percent;
                        var dlMb = progress.DownloadedBytes / (1024.0 * 1024.0);
                        var totMb = progress.TotalBytes > 0 ? progress.TotalBytes / (1024.0 * 1024.0) : 0;
                        ModelProgressText.Text = progress.TotalBytes > 0
                            ? $"{progress.Percent}% ({dlMb:F1}/{totMb:F1} MB) — {progress.CurrentFile}"
                            : $"Downloading {progress.CurrentFile}...";
                    });
                },
                _modelDownloadCts.Token);

            ModelProgressText.Text = result.StatusMessage;

            if (result.Success)
            {
                await _sharedConfigService.RegisterModelAsync(
                    modelName, "faster-whisper-xxl", svc.GetModelDirectory());
                WhisperPaths.RegisterEnvironmentVariables(svc.GetWhisperPath(), modelName);
                _onSettingsChanged?.Invoke();
            }
        }
        finally
        {
            _modelDownloadCts?.Dispose();
            _modelDownloadCts = null;
            _isModelDownloading = false;
            DownloadModelBtn.IsEnabled = true;
            CancelModelBtn.Visibility = Visibility.Collapsed;
            ModelProgressBar.Visibility = Visibility.Collapsed;
            await LoadModelsDataAsync();
            LoadStorageData();
        }
    }

    private void OnCancelModelClicked(object sender, RoutedEventArgs e)
    {
        _modelDownloadCts?.Cancel();
    }

    // ─── Storage ───

    private void LoadStorageData()
    {
        var whisperPath = WhisperPaths.GetDefaultWhisperPath();
        ModelsFolderText.Text = WhisperPaths.GetModelsRoot(whisperPath);

        var savedFolder = _settingsService.LoadOutputFolder();
        RecordingsFolderText.Text = string.IsNullOrEmpty(savedFolder)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Contora")
            : savedFolder;

        _ = LoadDiskUsageAsync();
    }

    private async Task LoadDiskUsageAsync()
    {
        var config = await _sharedConfigService.LoadAsync();
        long runtimeBytes = config.InstalledRuntimes.Sum(r => r.DiskUsageBytes);
        long modelsBytes = config.InstalledModels.Sum(m => m.SizeBytes);

        DiskRuntimeText.Text = FormatFileSize(runtimeBytes);
        DiskModelsText.Text = FormatFileSize(modelsBytes);
        DiskTotalText.Text = FormatFileSize(runtimeBytes + modelsBytes);
    }

    private async void OnChangeModelsFolderClicked(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FolderPicker
        {
            SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.ComputerFolder
        };
        picker.FileTypeFilter.Add("*");

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);

        var folder = await picker.PickSingleFolderAsync();
        if (folder != null)
        {
            ModelsFolderText.Text = folder.Path;

            var config = await _sharedConfigService.LoadAsync();
            config.ModelsRootPath = folder.Path;
            await _sharedConfigService.SaveAsync(config);

            _onSettingsChanged?.Invoke();
        }
    }

    private async void OnChangeRecordingsFolderClicked(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FolderPicker
        {
            SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.DocumentsLibrary
        };
        picker.FileTypeFilter.Add("*");

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);

        var folder = await picker.PickSingleFolderAsync();
        if (folder != null)
        {
            RecordingsFolderText.Text = folder.Path;
            _settingsService.SaveOutputFolder(folder.Path);
            _onSettingsChanged?.Invoke();
        }
    }

    // ─── General ───

    private void LoadGeneralData()
    {
        var mode = _settingsService.LoadTranscriptionMode();
        TranscriptionModeCombo.SelectedIndex = string.Equals(mode, "light", StringComparison.OrdinalIgnoreCase) ? 1 : 0;

        var ffmpegInstalled = _ffmpegInstaller.IsInstalled();
        FfmpegStatusText.Text = ffmpegInstalled
            ? $"Installed: {_ffmpegInstaller.GetInstalledPath()}"
            : "Not installed. FFmpeg is needed for video import (~140 MB).";
        DownloadFfmpegBtn.Visibility = ffmpegInstalled ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OnTranscriptionModeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is not ComboBox combo || combo.SelectedItem is not ComboBoxItem item) return;
        var mode = item.Tag?.ToString() ?? "quality";
        _settingsService.SaveTranscriptionMode(mode);
        _onSettingsChanged?.Invoke();
    }

    private async void OnDownloadFfmpegClicked(object sender, RoutedEventArgs e)
    {
        if (_isFfmpegDownloading) return;
        _isFfmpegDownloading = true;
        _ffmpegDownloadCts = new CancellationTokenSource();

        DownloadFfmpegBtn.Visibility = Visibility.Collapsed;
        CancelFfmpegBtn.Visibility = Visibility.Visible;
        FfmpegProgressBar.Visibility = Visibility.Visible;
        FfmpegProgressBar.Value = 0;
        FfmpegProgressText.Visibility = Visibility.Visible;

        try
        {
            var result = await _ffmpegInstaller.InstallAsync(
                progress =>
                {
                    _dispatcherQueue.TryEnqueue(() =>
                    {
                        FfmpegProgressBar.Value = progress.Percent;
                        FfmpegProgressText.Text = progress.StatusMessage;
                    });
                },
                _ffmpegDownloadCts.Token);

            FfmpegProgressText.Text = result.StatusMessage;
            _onSettingsChanged?.Invoke();
        }
        finally
        {
            _ffmpegDownloadCts?.Dispose();
            _ffmpegDownloadCts = null;
            _isFfmpegDownloading = false;
            CancelFfmpegBtn.Visibility = Visibility.Collapsed;
            LoadGeneralData();
        }
    }

    private void OnCancelFfmpegClicked(object sender, RoutedEventArgs e)
    {
        _ffmpegDownloadCts?.Cancel();
    }

    // ─── Helpers ───

    private static string FormatFileSize(long bytes)
    {
        if (bytes <= 0) return "—";
        string[] sizes = ["B", "KB", "MB", "GB"];
        double len = bytes;
        int order = 0;
        while (len >= 1024 && order < sizes.Length - 1)
        {
            order++;
            len /= 1024;
        }
        return $"{len:0.##} {sizes[order]}";
    }
}
