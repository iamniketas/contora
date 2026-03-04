using AudioRecorder.Core.Models;
using AudioRecorder.Core.Services;
using AudioRecorder.Services.Audio;
using AudioRecorder.Services.Notifications;
using AudioRecorder.Services.Pipeline;
using AudioRecorder.Services.Models;
using AudioRecorder.Services.Settings;
using AudioRecorder.Services.Transcription;
using AudioRecorder.Services.Updates;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text;
using Velopack;

namespace AudioRecorder.Views;

public class AudioSourceViewModel : INotifyPropertyChanged
{
    private bool _isSelected;

    public AudioSource Source { get; }

    public bool IsSelected
    {
        get => _isSelected;
        set
        {
            if (_isSelected != value)
            {
                _isSelected = value;
                OnPropertyChanged();
            }
        }
    }

    public AudioSourceViewModel(AudioSource source, bool isSelected = false)
    {
        Source = source;
        _isSelected = isSelected;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    protected void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}

public class SpeakerViewModel : INotifyPropertyChanged
{
    private string _name;

    public string Id { get; }

    public string Name
    {
        get => _name;
        set
        {
            if (_name != value)
            {
                _name = value;
                OnPropertyChanged();
            }
        }
    }

    public SpeakerViewModel(string id, string name)
    {
        Id = id;
        _name = name;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    protected void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}

public class TranscriptionSegmentViewModel : INotifyPropertyChanged
{
    private string _speakerName;
    private string _text;

    public TimeSpan Start { get; }
    public TimeSpan End { get; }
    public string SpeakerId { get; }

    public string SpeakerName
    {
        get => _speakerName;
        set
        {
            if (_speakerName != value)
            {
                _speakerName = value;
                OnPropertyChanged();
            }
        }
    }

    public string Text
    {
        get => _text;
        set
        {
            if (_text != value)
            {
                _text = value;
                OnPropertyChanged();
            }
        }
    }

    public string TimestampDisplay => Start.ToString(@"mm\:ss");

    public TranscriptionSegmentViewModel(TranscriptionSegment segment, string speakerName)
    {
        Start = segment.Start;
        End = segment.End;
        SpeakerId = segment.Speaker;
        _speakerName = speakerName;
        _text = segment.Text;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    protected void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}

public sealed partial class MainPage : Page
{
    private readonly IAudioCaptureService _audioCaptureService;
    private ITranscriptionService _transcriptionService;
    private readonly ISettingsService _settingsService;
    private readonly IAudioPlaybackService _playbackService;
    private readonly ISessionPipelineService _sessionPipelineService;
    private readonly AppUpdateService _appUpdateService;
    private readonly WhisperRuntimeInstallerService _runtimeInstallerService;
    private WhisperModelDownloadService _modelDownloadService;
    private readonly FfmpegInstallerService _ffmpegInstallerService;
    private readonly SharedModelConfigService _sharedConfigService;
    private readonly DispatcherQueue _dispatcherQueue;
    private readonly DispatcherQueueTimer _updateTimer;
    private string? _lastRecordingPath;
    private string? _lastTranscriptionPath;
    private CancellationTokenSource? _transcriptionCts;
    private bool _isSettingsPanelVisible = true;
    private TranscriptionSegmentViewModel? _playingSegment;
    private bool _hasUnsavedChanges;
    private bool _isRuntimeDownloadInProgress;
    private CancellationTokenSource? _runtimeDownloadCts;
    private bool _isModelDownloadInProgress;
    private CancellationTokenSource? _modelDownloadCts;
    private bool _isFfmpegDownloadInProgress;
    private CancellationTokenSource? _ffmpegDownloadCts;
    private bool _isUpdateFlowRunning;
    private UpdateInfo? _availableUpdateInfo;
    private VelopackAsset? _readyToApplyRelease;
    private string _transcriptionMode = "quality";
    private string _whisperModel = "large-v2";
    private readonly Dictionary<string, string> _speakerNameMap = new();

    public ObservableCollection<AudioSourceViewModel> OutputSources { get; } = new();
    public ObservableCollection<AudioSourceViewModel> InputSources { get; } = new();
    public ObservableCollection<SpeakerViewModel> Speakers { get; } = new();
    public ObservableCollection<TranscriptionSegmentViewModel> TranscriptionSegments { get; } = new();

    public MainPage()
    {
        InitializeComponent();

        _audioCaptureService = new WasapiAudioCaptureService();
        _audioCaptureService.RecordingStateChanged += OnRecordingStateChanged;

        _settingsService = new LocalSettingsService();
        _transcriptionMode = _settingsService.LoadTranscriptionMode();
        _whisperModel = _settingsService.LoadWhisperModel();
        _transcriptionService = CreateTranscriptionService(_transcriptionMode);
        _transcriptionService.ProgressChanged += OnTranscriptionProgressChanged;

        _playbackService = new AudioPlaybackService();
        _sessionPipelineService = new SessionPipelineService();
        _playbackService.StateChanged += OnPlaybackStateChanged;
        _appUpdateService = new AppUpdateService();
        _runtimeInstallerService = new WhisperRuntimeInstallerService();
        _modelDownloadService = new WhisperModelDownloadService(_whisperModel);
        _ffmpegInstallerService = new FfmpegInstallerService();
        _sharedConfigService = new SharedModelConfigService();

        NotificationService.Initialize();

        _dispatcherQueue = DispatcherQueue.GetForCurrentThread();

        _updateTimer = _dispatcherQueue.CreateTimer();
        _updateTimer.Interval = TimeSpan.FromMilliseconds(500);
        _updateTimer.Tick += (s, e) => UpdateRecordingInfo();

        Loaded += OnPageLoaded;
        Unloaded += (s, e) =>
        {
            _runtimeDownloadCts?.Cancel();
            _runtimeDownloadCts?.Dispose();
            _runtimeDownloadCts = null;
            _modelDownloadCts?.Cancel();
            _modelDownloadCts?.Dispose();
            _modelDownloadCts = null;
            _ffmpegDownloadCts?.Cancel();
            _ffmpegDownloadCts?.Dispose();
            _ffmpegDownloadCts = null;
            _appUpdateService.Dispose();
        };
    }

    private async void OnPageLoaded(object sender, RoutedEventArgs e)
    {
        await LoadAudioSourcesAsync();
        LoadOutputFolderSetting();
        LoadTranscriptionModeSetting();
        LoadWhisperModelSetting();

        if (_runtimeInstallerService.IsRuntimeInstalled())
        {
            WhisperPaths.RegisterEnvironmentVariables(_runtimeInstallerService.GetRuntimeExePath(), _whisperModel);
        }

        _ = CheckForUpdatesAsync(userInitiated: false);
        UpdateTranscriptionAvailabilityUi();
        _ = TryAutoSetupWhisperAsync();
    }

    private ITranscriptionService CreateTranscriptionService(string mode)
    {
        bool enableDiarization = !string.Equals(mode, "light", StringComparison.OrdinalIgnoreCase);
        return new WhisperTranscriptionService(modelName: _whisperModel, enableDiarization: enableDiarization);
    }

    private void ApplyTranscriptionMode(string mode, bool save)
    {
        var normalized = string.Equals(mode, "light", StringComparison.OrdinalIgnoreCase) ? "light" : "quality";
        if (string.Equals(_transcriptionMode, normalized, StringComparison.OrdinalIgnoreCase))
            return;

        _transcriptionService.ProgressChanged -= OnTranscriptionProgressChanged;
        _transcriptionService = CreateTranscriptionService(normalized);
        _transcriptionService.ProgressChanged += OnTranscriptionProgressChanged;
        _transcriptionMode = normalized;

        if (save)
        {
            _settingsService.SaveTranscriptionMode(_transcriptionMode);
        }

        UpdateTranscriptionAvailabilityUi();
    }

    private void LoadTranscriptionModeSetting()
    {
        var savedMode = _settingsService.LoadTranscriptionMode();
        _transcriptionMode = string.Equals(savedMode, "light", StringComparison.OrdinalIgnoreCase) ? "light" : "quality";

        if (TranscriptionModeComboBox.Items.Count >= 2)
        {
            TranscriptionModeComboBox.SelectedIndex = _transcriptionMode == "light" ? 1 : 0;
        }
    }

    private void LoadWhisperModelSetting()
    {
        var savedModel = _settingsService.LoadWhisperModel();
        _whisperModel = WhisperModelDownloadService.NormalizeModelName(savedModel);

        if (WhisperModelComboBox.Items.Count >= 3)
        {
            WhisperModelComboBox.SelectedIndex = _whisperModel switch
            {
                "small" => 0,
                "medium" => 1,
                _ => 2
            };
        }
    }

    private void ApplyWhisperModel(string modelName, bool save)
    {
        var normalized = WhisperModelDownloadService.NormalizeModelName(modelName);
        if (string.Equals(_whisperModel, normalized, StringComparison.OrdinalIgnoreCase))
            return;

        _whisperModel = normalized;

        _transcriptionService.ProgressChanged -= OnTranscriptionProgressChanged;
        _transcriptionService = CreateTranscriptionService(_transcriptionMode);
        _transcriptionService.ProgressChanged += OnTranscriptionProgressChanged;

        if (save)
        {
            _settingsService.SaveWhisperModel(_whisperModel);
        }

        _modelDownloadService = new WhisperModelDownloadService(_whisperModel);

        if (_runtimeInstallerService.IsRuntimeInstalled())
        {
            WhisperPaths.RegisterEnvironmentVariables(_runtimeInstallerService.GetRuntimeExePath(), _whisperModel);
        }

        UpdateTranscriptionAvailabilityUi();
    }

    private Task TryAutoSetupWhisperAsync()
    {
        // Only update the UI to show what needs to be downloaded.
        // The user must initiate downloads manually.
        UpdateTranscriptionAvailabilityUi();
        return Task.CompletedTask;
    }

    private void UpdateTranscriptionAvailabilityUi()
    {
        var whisperAvailable = _transcriptionService.IsWhisperAvailable;
        var modelInstalled = _modelDownloadService.IsModelInstalled();
        var ffmpegInstalled = _ffmpegInstallerService.IsInstalled();

        DownloadRuntimeButton.Visibility = Visibility.Collapsed;
        CancelRuntimeDownloadButton.Visibility = Visibility.Collapsed;
        RuntimeDownloadProgressBar.Visibility = Visibility.Collapsed;
        RuntimeDownloadStatusText.Visibility = Visibility.Collapsed;
        DownloadModelButton.Visibility = Visibility.Collapsed;
        CancelModelDownloadButton.Visibility = Visibility.Collapsed;
        ModelDownloadProgressBar.Visibility = Visibility.Collapsed;
        ModelDownloadStatusText.Visibility = Visibility.Collapsed;
        DownloadFfmpegButton.Visibility = Visibility.Collapsed;
        CancelFfmpegDownloadButton.Visibility = Visibility.Collapsed;
        FfmpegDownloadProgressBar.Visibility = Visibility.Collapsed;
        FfmpegDownloadStatusText.Visibility = Visibility.Collapsed;

        if (!whisperAvailable)
        {
            WhisperWarningBar.Title = "Whisper runtime is missing";
            WhisperWarningBar.Message = "Download faster-whisper-xxl (~1.5 GB). It will be installed in LocalAppData.";
            WhisperWarningBar.IsOpen = true;

            TranscribeButton.IsEnabled = false;

            DownloadRuntimeButton.Visibility = _isRuntimeDownloadInProgress ? Visibility.Collapsed : Visibility.Visible;
            CancelRuntimeDownloadButton.Visibility = _isRuntimeDownloadInProgress ? Visibility.Visible : Visibility.Collapsed;
            RuntimeDownloadProgressBar.Visibility = _isRuntimeDownloadInProgress ? Visibility.Visible : Visibility.Collapsed;
            RuntimeDownloadStatusText.Visibility = Visibility.Visible;

            UpdateFfmpegUi(ffmpegInstalled);
            return;
        }

        if (!modelInstalled)
        {
            var modelSize = _whisperModel switch
            {
                "small" => "~500 MB, good accuracy",
                "medium" => "~1.5 GB, better accuracy",
                _ => "~3 GB, best accuracy"
            };
            WhisperWarningBar.Title = "Whisper model is missing";
            WhisperWarningBar.Message = $"Download model '{_whisperModel}' ({modelSize}). Stored in LocalAppData.";
            WhisperWarningBar.IsOpen = true;
            TranscribeButton.IsEnabled = false;

            DownloadModelButton.Visibility = _isModelDownloadInProgress ? Visibility.Collapsed : Visibility.Visible;
            CancelModelDownloadButton.Visibility = _isModelDownloadInProgress ? Visibility.Visible : Visibility.Collapsed;
            ModelDownloadProgressBar.Visibility = _isModelDownloadInProgress ? Visibility.Visible : Visibility.Collapsed;
            ModelDownloadStatusText.Visibility = Visibility.Visible;

            UpdateFfmpegUi(ffmpegInstalled);
            return;
        }

        WhisperWarningBar.IsOpen = false;
        TranscribeButton.IsEnabled = true;

        UpdateFfmpegUi(ffmpegInstalled);
    }

    private void UpdateFfmpegUi(bool ffmpegInstalled)
    {
        if (ffmpegInstalled)
        {
            FfmpegWarningBar.IsOpen = false;
            return;
        }

        FfmpegWarningBar.IsOpen = true;

        if (_isFfmpegDownloadInProgress)
        {
            DownloadFfmpegButton.Visibility = Visibility.Collapsed;
            CancelFfmpegDownloadButton.Visibility = Visibility.Visible;
            FfmpegDownloadProgressBar.Visibility = Visibility.Visible;
            FfmpegDownloadStatusText.Visibility = Visibility.Visible;
        }
        else
        {
            DownloadFfmpegButton.Visibility = Visibility.Visible;
            FfmpegDownloadStatusText.Visibility = Visibility.Visible;
        }
    }

    private async Task StartModelDownloadAsync()
    {
        if (_isModelDownloadInProgress)
            return;

        _modelDownloadService = new WhisperModelDownloadService(_whisperModel);

        _isModelDownloadInProgress = true;
        _modelDownloadCts = new CancellationTokenSource();

        DownloadModelButton.Visibility = Visibility.Collapsed;
        CancelModelDownloadButton.Visibility = Visibility.Visible;
        ModelDownloadProgressBar.Visibility = Visibility.Visible;
        ModelDownloadProgressBar.Value = 0;
        ModelDownloadStatusText.Visibility = Visibility.Visible;
        ModelDownloadStatusText.Text = $"Downloading model '{_whisperModel}'...";

        try
        {
            var result = await _modelDownloadService.DownloadModelAsync(
                progress =>
                {
                    _dispatcherQueue.TryEnqueue(() =>
                    {
                        ModelDownloadProgressBar.Value = progress.Percent;
                        var downloadedMb = progress.DownloadedBytes / (1024.0 * 1024.0);
                        var totalMb = progress.TotalBytes > 0 ? progress.TotalBytes / (1024.0 * 1024.0) : 0;

                        ModelDownloadStatusText.Text = progress.TotalBytes > 0
                            ? $"Model download: {progress.Percent}% ({downloadedMb:F1}/{totalMb:F1} MB), file: {progress.CurrentFile}"
                            : $"Model download: file {progress.CurrentFile}";
                    });
                },
                _modelDownloadCts.Token);

            ModelDownloadStatusText.Text = result.StatusMessage;
            if (result.Success)
            {
                WhisperPaths.RegisterEnvironmentVariables(_modelDownloadService.GetWhisperPath(), _whisperModel);
            }
        }
        finally
        {
            _modelDownloadCts?.Dispose();
            _modelDownloadCts = null;
            _isModelDownloadInProgress = false;
            UpdateTranscriptionAvailabilityUi();
        }
    }

    private async void OnDownloadModelClicked(object sender, RoutedEventArgs e)
    {
        await StartModelDownloadAsync();
    }

    private void OnCancelModelDownloadClicked(object sender, RoutedEventArgs e)
    {
        _modelDownloadCts?.Cancel();
    }

    private async Task StartRuntimeDownloadAsync()
    {
        if (_isRuntimeDownloadInProgress)
            return;

        _isRuntimeDownloadInProgress = true;
        _runtimeDownloadCts = new CancellationTokenSource();

        DownloadRuntimeButton.Visibility = Visibility.Collapsed;
        CancelRuntimeDownloadButton.Visibility = Visibility.Visible;
        RuntimeDownloadProgressBar.Visibility = Visibility.Visible;
        RuntimeDownloadProgressBar.Value = 0;
        RuntimeDownloadStatusText.Visibility = Visibility.Visible;
        RuntimeDownloadStatusText.Text = "Downloading Whisper XXL runtime...";

        try
        {
            var result = await _runtimeInstallerService.InstallAsync(
                progress =>
                {
                    _dispatcherQueue.TryEnqueue(() =>
                    {
                        RuntimeDownloadProgressBar.Value = progress.Percent;
                        RuntimeDownloadStatusText.Text = progress.StatusMessage;
                    });
                },
                _runtimeDownloadCts.Token);

            RuntimeDownloadStatusText.Text = result.StatusMessage;

            if (result.Success && !string.IsNullOrWhiteSpace(result.WhisperExePath))
            {
                WhisperPaths.RegisterEnvironmentVariables(result.WhisperExePath, _whisperModel);
            }
        }
        finally
        {
            _runtimeDownloadCts?.Dispose();
            _runtimeDownloadCts = null;
            _isRuntimeDownloadInProgress = false;
            UpdateTranscriptionAvailabilityUi();
        }

    }

    private async void OnDownloadRuntimeClicked(object sender, RoutedEventArgs e)
    {
        await StartRuntimeDownloadAsync();
    }

    private void OnCancelRuntimeDownloadClicked(object sender, RoutedEventArgs e)
    {
        _runtimeDownloadCts?.Cancel();
    }

    private async Task StartFfmpegDownloadAsync()
    {
        if (_isFfmpegDownloadInProgress)
            return;

        _isFfmpegDownloadInProgress = true;
        _ffmpegDownloadCts = new CancellationTokenSource();

        DownloadFfmpegButton.Visibility = Visibility.Collapsed;
        CancelFfmpegDownloadButton.Visibility = Visibility.Visible;
        FfmpegDownloadProgressBar.Visibility = Visibility.Visible;
        FfmpegDownloadProgressBar.Value = 0;
        FfmpegDownloadStatusText.Visibility = Visibility.Visible;
        FfmpegDownloadStatusText.Text = "Downloading FFmpeg...";

        try
        {
            var result = await _ffmpegInstallerService.InstallAsync(
                progress =>
                {
                    _dispatcherQueue.TryEnqueue(() =>
                    {
                        FfmpegDownloadProgressBar.Value = progress.Percent;
                        FfmpegDownloadStatusText.Text = progress.StatusMessage;
                    });
                },
                _ffmpegDownloadCts.Token);

            FfmpegDownloadStatusText.Text = result.StatusMessage;
        }
        finally
        {
            _ffmpegDownloadCts?.Dispose();
            _ffmpegDownloadCts = null;
            _isFfmpegDownloadInProgress = false;
            UpdateTranscriptionAvailabilityUi();
        }
    }

    private async void OnDownloadFfmpegClicked(object sender, RoutedEventArgs e)
    {
        await StartFfmpegDownloadAsync();
    }

    private void OnCancelFfmpegDownloadClicked(object sender, RoutedEventArgs e)
    {
        _ffmpegDownloadCts?.Cancel();
    }

    private void OnOpenSettingsWindowClicked(object sender, RoutedEventArgs e)
    {
        if (App.SettingsWindowInstance != null)
        {
            App.SettingsWindowInstance.Activate();
            return;
        }

        var settingsWindow = new SettingsWindow(
            _runtimeInstallerService,
            _ffmpegInstallerService,
            _sharedConfigService,
            _settingsService,
            onSettingsChanged: () =>
            {
                _dispatcherQueue.TryEnqueue(() =>
                {
                    // Reload transcription mode
                    LoadTranscriptionModeSetting();
                    LoadWhisperModelSetting();
                    LoadOutputFolderSetting();
                    UpdateTranscriptionAvailabilityUi();
                });
            });

        App.SettingsWindowInstance = settingsWindow;
        settingsWindow.Activate();
    }

    private async Task CheckForUpdatesAsync(bool userInitiated)
    {
        if (_isUpdateFlowRunning)
            return;

        _isUpdateFlowRunning = true;
        SetUpdateUiBusy(true);
        _availableUpdateInfo = null;
        _readyToApplyRelease = null;
        ApplyUpdateButton.Visibility = Visibility.Collapsed;
        UpdateProgressBar.Visibility = Visibility.Collapsed;
        UpdateProgressBar.Value = 0;

        try
        {
            UpdateStatusText.Text = "Checking for updates...";
            var checkResult = await _appUpdateService.CheckForUpdatesAsync();

            if (!checkResult.Success)
            {
                UpdateStatusText.Text = checkResult.StatusMessage;
                return;
            }

            if (!checkResult.UpdateAvailable || checkResult.UpdateInfo == null)
            {
                UpdateStatusText.Text = userInitiated
                    ? "No updates available. You already have the latest version."
                    : "Auto-check: no updates available.";
                return;
            }

            _availableUpdateInfo = checkResult.UpdateInfo;
            UpdateStatusText.Text = $"{checkResult.StatusMessage} Downloading...";
            UpdateProgressBar.Visibility = Visibility.Visible;
            UpdateProgressBar.Value = 0;

            var downloadResult = await _appUpdateService.DownloadUpdateAsync(
                _availableUpdateInfo,
                progress =>
                {
                    _dispatcherQueue.TryEnqueue(() =>
                    {
                        UpdateProgressBar.Visibility = Visibility.Visible;
                        UpdateProgressBar.Value = Math.Max(0, Math.Min(100, progress));
                        UpdateStatusText.Text = $"Downloading update: {progress}%";
                    });
                });

            if (!downloadResult.Success || downloadResult.ReadyToApplyRelease == null)
            {
                UpdateStatusText.Text = downloadResult.StatusMessage;
                return;
            }

            _readyToApplyRelease = downloadResult.ReadyToApplyRelease;
            UpdateStatusText.Text = downloadResult.StatusMessage;
            ApplyUpdateButton.Visibility = Visibility.Visible;
        }
        finally
        {
            SetUpdateUiBusy(false);
            _isUpdateFlowRunning = false;
        }
    }

    private void SetUpdateUiBusy(bool isBusy)
    {
        CheckUpdatesButton.IsEnabled = !isBusy;
    }

    private async void OnCheckUpdatesClicked(object sender, RoutedEventArgs e)
    {
        await CheckForUpdatesAsync(userInitiated: true);
    }

    private async void OnApplyUpdateClicked(object sender, RoutedEventArgs e)
    {
        if (_readyToApplyRelease == null)
            return;

        var dialog = new ContentDialog
        {
            Title = "Apply update",
            Content = "The app will restart to complete installation.",
            PrimaryButtonText = "Apply and restart",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = Content.XamlRoot
        };

        var result = await dialog.ShowAsync();
        if (result != ContentDialogResult.Primary)
            return;

        var started = _appUpdateService.ApplyUpdateAndRestart(_readyToApplyRelease);
        if (!started)
        {
            await ShowErrorDialogAsync("Failed to apply update.");
        }
    }

    private void LoadOutputFolderSetting()
    {
        var savedFolder = _settingsService.LoadOutputFolder();
        if (!string.IsNullOrEmpty(savedFolder))
        {
            OutputFolderTextBox.Text = FormatFolderPath(savedFolder);
            ToolTipService.SetToolTip(OutputFolderTextBox, savedFolder);
        }
        else
        {
            var defaultFolder = GetDefaultOutputFolder();
            OutputFolderTextBox.Text = FormatFolderPath(defaultFolder);
            ToolTipService.SetToolTip(OutputFolderTextBox, defaultFolder);
        }
    }

    private static string FormatFolderPath(string fullPath)
    {
        var parts = fullPath.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (parts.Length > 3)
        {
            return $"...{Path.DirectorySeparatorChar}{string.Join(Path.DirectorySeparatorChar, parts.TakeLast(2))}";
        }
        return fullPath;
    }

    private async Task LoadAudioSourcesAsync()
    {
        try
        {
            var sources = await _audioCaptureService.GetAvailableSourcesAsync();
            var savedSourceIds = _settingsService.LoadSelectedSourceIds();

            OutputSources.Clear();
            InputSources.Clear();

            foreach (var source in sources)
            {
                var isSelected = savedSourceIds.Contains(source.Id) ||
                               (savedSourceIds.Count == 0 && source.IsDefault);

                var viewModel = new AudioSourceViewModel(source, isSelected);

                if (source.Type == AudioSourceType.SystemOutput)
                {
                    OutputSources.Add(viewModel);
                }
                else if (source.Type == AudioSourceType.Microphone)
                {
                    InputSources.Add(viewModel);
                }
            }

            UpdateStartButtonState();
        }
        catch (Exception ex)
        {
            await ShowErrorDialogAsync($"Failed to load devices: {ex.Message}");
        }
    }

    private void OnSourceSelectionChanged(object sender, RoutedEventArgs e)
    {
        UpdateStartButtonState();
    }

    private void UpdateStartButtonState()
    {
        var hasSelection = OutputSources.Any(s => s.IsSelected) || InputSources.Any(s => s.IsSelected);
        StartStopButton.IsEnabled = hasSelection;
    }

    private async void OnSelectFolderClicked(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FolderPicker
        {
            SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.DocumentsLibrary
        };
        picker.FileTypeFilter.Add("*");

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);

        var folder = await picker.PickSingleFolderAsync();
        if (folder != null)
        {
            OutputFolderTextBox.Text = FormatFolderPath(folder.Path);
            ToolTipService.SetToolTip(OutputFolderTextBox, folder.Path);
            _settingsService.SaveOutputFolder(folder.Path);
        }
    }

    private void OnToggleSettingsClicked(object sender, RoutedEventArgs e)
    {
        _isSettingsPanelVisible = !_isSettingsPanelVisible;

        if (_isSettingsPanelVisible)
        {
            SettingsColumn.Width = new GridLength(280);
            SettingsPanel.Visibility = Visibility.Visible;
            ToggleSettingsButton.Content = "<<";
        }
        else
        {
            SettingsColumn.Width = new GridLength(0);
            SettingsPanel.Visibility = Visibility.Collapsed;
            ToggleSettingsButton.Content = ">>";
        }
    }

    private async void OnStartStopClicked(object sender, RoutedEventArgs e)
    {
        try
        {
            var info = _audioCaptureService.GetCurrentRecordingInfo();

            if (info.State == RecordingState.Stopped)
            {
                var selectedSources = OutputSources.Concat(InputSources)
                    .Where(vm => vm.IsSelected)
                    .Select(vm => vm.Source)
                    .ToList();

                if (selectedSources.Count == 0)
                {
                    await ShowErrorDialogAsync("Select at least one audio source");
                    return;
                }

                _settingsService.SaveSelectedSourceIds(selectedSources.Select(s => s.Id));

                _lastRecordingPath = GetOutputPath();
                await _audioCaptureService.StartRecordingAsync(selectedSources, _lastRecordingPath);

                StartStopButton.Content = "Stop";
                PauseResumeButton.IsEnabled = true;
                OutputSourcesListView.IsEnabled = false;
                InputSourcesListView.IsEnabled = false;

                CurrentFileTextBlock.Text = Path.GetFileName(_lastRecordingPath);

                _updateTimer.Start();
            }
            else
            {
                await _audioCaptureService.StopRecordingAsync();

                StartStopButton.Content = "Start recording";
                PauseResumeButton.IsEnabled = false;
                PauseResumeButton.Content = "Pause";
                OutputSourcesListView.IsEnabled = true;
                InputSourcesListView.IsEnabled = true;

                _updateTimer.Stop();

                if (_lastRecordingPath != null && File.Exists(_lastRecordingPath))
                {
                    if (AudioConverter.IsWavFile(_lastRecordingPath))
                    {
                        StateTextBlock.Text = "Converting to MP3...";
                        try
                        {
                            _lastRecordingPath = await AudioConverter.ConvertToMp3Async(
                                _lastRecordingPath, bitrate: 192, deleteOriginal: true);
                            CurrentFileTextBlock.Text = Path.GetFileName(_lastRecordingPath);
                        }
                        catch (Exception ex)
                        {
                            System.Diagnostics.Debug.WriteLine($"Conversion error: {ex.Message}");
                        }
                        StateTextBlock.Text = "Stopped";
                    }

                    ShowTranscriptionSection();
                    await ShowRecordingSavedDialogAsync(_lastRecordingPath);
                }
            }
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Error in OnStartStopClicked: {ex.Message}");
            await ShowErrorDialogAsync($"Error: {ex.Message}");
        }
    }

    private async void OnPauseResumeClicked(object sender, RoutedEventArgs e)
    {
        try
        {
            var info = _audioCaptureService.GetCurrentRecordingInfo();

            if (info.State == RecordingState.Recording)
            {
                await _audioCaptureService.PauseRecordingAsync();
                PauseResumeButton.Content = "Resume";
            }
            else if (info.State == RecordingState.Paused)
            {
                await _audioCaptureService.ResumeRecordingAsync();
                PauseResumeButton.Content = "Pause";
            }
        }
        catch (Exception ex)
        {
            await ShowErrorDialogAsync($"Error: {ex.Message}");
        }
    }

    private async void OnImportClicked(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker
        {
            SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.MusicLibrary
        };

        picker.FileTypeFilter.Add(".wav");
        picker.FileTypeFilter.Add(".mp3");
        picker.FileTypeFilter.Add(".flac");
        picker.FileTypeFilter.Add(".m4a");
        picker.FileTypeFilter.Add(".ogg");
        picker.FileTypeFilter.Add(".mp4");
        picker.FileTypeFilter.Add(".m4v");
        picker.FileTypeFilter.Add(".mov");
        picker.FileTypeFilter.Add(".avi");
        picker.FileTypeFilter.Add(".mkv");
        picker.FileTypeFilter.Add(".webm");
        picker.FileTypeFilter.Add(".wmv");

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);

        var file = await picker.PickSingleFileAsync();
        if (file != null)
        {
            try
            {
                if (AudioConverter.IsVideoFile(file.Path))
                {
                    TranscriptionControlSection.Visibility = Visibility.Visible;
                    TranscriptionProgressPanel.Visibility = Visibility.Visible;
                    TranscriptionProgressBar.IsIndeterminate = true;
                    TranscriptionStatusText.Text = "Extracting audio from video...";
                    TranscribeButton.IsEnabled = false;
                    ImportButton.IsEnabled = false;

                    var mp3Path = await AudioConverter.ExtractAudioToMp3Async(file.Path);
                    _lastRecordingPath = mp3Path;
                    CurrentFileTextBlock.Text = Path.GetFileName(mp3Path);
                }
                else
                {
                    _lastRecordingPath = file.Path;
                    CurrentFileTextBlock.Text = file.Name;
                }

                ShowTranscriptionSection();
            }
            catch (Exception ex)
            {
                await ShowErrorDialogAsync($"Failed to import file: {ex.Message}");
            }
            finally
            {
                ImportButton.IsEnabled = true;
                TranscriptionProgressPanel.Visibility = Visibility.Collapsed;
                TranscriptionProgressBar.IsIndeterminate = false;
            }
        }
    }

    private void OnTranscriptionModeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is not ComboBox comboBox || comboBox.SelectedItem is not ComboBoxItem item)
            return;

        var mode = item.Tag?.ToString() ?? "quality";
        ApplyTranscriptionMode(mode, save: true);
    }

    private void OnWhisperModelChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is not ComboBox comboBox || comboBox.SelectedItem is not ComboBoxItem item)
            return;

        var modelName = item.Tag?.ToString() ?? "large-v2";
        ApplyWhisperModel(modelName, save: true);
    }

    private void ShowTranscriptionSection()
    {
        TranscriptionControlSection.Visibility = Visibility.Visible;
        TranscribeButton.IsEnabled = true;
        TranscriptionProgressPanel.Visibility = Visibility.Collapsed;
        _lastTranscriptionPath = null;

        TranscriptionSegments.Clear();
        Speakers.Clear();
        SpeakersPanel.Visibility = Visibility.Collapsed;
        SaveTranscriptionButton.Visibility = Visibility.Collapsed;

        UpdateTranscriptionAvailabilityUi();
    }

    private async void OnTranscribeClicked(object sender, RoutedEventArgs e)
    {
        if (_lastRecordingPath == null || !File.Exists(_lastRecordingPath))
        {
            await ShowErrorDialogAsync("Recording file not found");
            return;
        }

        TranscribeButton.IsEnabled = false;
        TranscriptionProgressPanel.Visibility = Visibility.Visible;
        TranscriptionProgressBar.IsIndeterminate = true;
        TranscriptionStatusText.Text = "Preparing...";
        TranscriptionStatsPanel.Visibility = Visibility.Collapsed; //  

        _transcriptionCts = new CancellationTokenSource();

        try
        {
            var result = await _transcriptionService.TranscribeAsync(_lastRecordingPath, _transcriptionCts.Token);

            if (result.Success)
            {
                _lastTranscriptionPath = result.OutputPath;
                TranscriptionStatusText.Text = $"Done! {result.Segments.Count} segments";
                TranscriptionProgressBar.IsIndeterminate = false;
                TranscriptionProgressBar.Value = 100;

                if (result.OutputPath != null && File.Exists(result.OutputPath))
                {
                    try
                    {
                        var fileInfo = new FileInfo(result.OutputPath);
                        var text = await File.ReadAllTextAsync(result.OutputPath);

                        var charCount = text.Length;
                        var wordCount = text.Split(new[] { ' ', '\n', '\r', '\t' }, StringSplitOptions.RemoveEmptyEntries).Length;
                        var fileSizeKB = fileInfo.Length / 1024.0;

                        var statsText = $"Characters: {charCount:N0}  Words: {wordCount:N0}  File size: {fileSizeKB:F1} KB";
                        TranscriptionStatsText.Text = statsText;
                        TranscriptionStatsPanel.Visibility = Visibility.Visible;
                    }
                    catch
                    {
                    }
                }

                var mp3Path = Path.ChangeExtension(_lastRecordingPath, ".mp3");
                if (File.Exists(mp3Path))
                {
                    _lastRecordingPath = mp3Path;
                    CurrentFileTextBlock.Text = Path.GetFileName(mp3Path);
                }

                await LoadTranscriptionToUI(result.Segments);

                // Post-processing pipeline: clean -> Ollama -> append to markdown.
                TranscriptionStatusText.Text = "Post-processing with Ollama...";
                var pipelineCt = _transcriptionCts?.Token ?? CancellationToken.None;
                var rawWhisperText = await LoadRawWhisperTextAsync(result, pipelineCt);
                var pipelineResult = await _sessionPipelineService.ProcessSessionAsync(
                    rawWhisperText,
                    result.OutputPath,
                    pipelineCt);

                if (pipelineResult.Success)
                {
                    TranscriptionStatusText.Text = pipelineResult.UsedBackup
                        ? $"Transcription saved in backup: {Path.GetFileName(pipelineResult.TargetPath)}"
                        : $"Transcription and summary saved: {Path.GetFileName(pipelineResult.TargetPath)}";
                }
                else
                {
                    TranscriptionStatusText.Text = "Transcription is ready, but post-processing failed";
                    AudioRecorder.Services.Logging.AppLogger.LogWarning(
                        $"Session pipeline failed after transcription: {pipelineResult.ErrorMessage}");
                }

                if (_lastRecordingPath != null && File.Exists(_lastRecordingPath))
                {
                    await _playbackService.LoadAsync(_lastRecordingPath);
                }

                var fileName = Path.GetFileName(_lastRecordingPath ?? "recording");
                NotificationService.ShowTranscriptionCompleted(fileName, result.Segments.Count, result.OutputPath);
            }
            else
            {
                await ShowErrorDialogAsync($"Transcription error:\n{result.ErrorMessage}");
                TranscriptionProgressPanel.Visibility = Visibility.Collapsed;
                TranscribeButton.IsEnabled = true;
            }
        }
        catch (Exception ex)
        {
            await ShowErrorDialogAsync($"Error: {ex.Message}");
            TranscriptionProgressPanel.Visibility = Visibility.Collapsed;
            TranscribeButton.IsEnabled = true;
        }
        finally
        {
            _transcriptionCts?.Dispose();
            _transcriptionCts = null;
        }
    }

    private Task LoadTranscriptionToUI(IReadOnlyList<TranscriptionSegment> segments)
    {
        TranscriptionSegments.Clear();
        Speakers.Clear();
        _speakerNameMap.Clear();

        var speakerIds = segments.Select(s => s.Speaker).Distinct().ToList();
        var speakerMap = new Dictionary<string, SpeakerViewModel>();

        foreach (var id in speakerIds)
        {
            var speaker = new SpeakerViewModel(id, id);
            Speakers.Add(speaker);
            speakerMap[id] = speaker;
            _speakerNameMap[id] = id;
        }

        foreach (var segment in segments)
        {
            var speakerName = speakerMap.TryGetValue(segment.Speaker, out var speaker) ? speaker.Name : segment.Speaker;
            TranscriptionSegments.Add(new TranscriptionSegmentViewModel(segment, speakerName));
        }

        SpeakersPanel.Visibility = Speakers.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        SaveTranscriptionButton.Visibility = Visibility.Visible;
        SetUnsavedChanges(false);

        return Task.CompletedTask;
    }

    private static async Task<string> LoadRawWhisperTextAsync(TranscriptionResult result, CancellationToken ct)
    {
        if (!string.IsNullOrWhiteSpace(result.OutputPath) && File.Exists(result.OutputPath))
        {
            return await File.ReadAllTextAsync(result.OutputPath, ct);
        }

        // Fallback if txt file is unavailable: build raw text from parsed segments.
        var sb = new StringBuilder();
        foreach (var segment in result.Segments)
        {
            sb.Append('[')
              .Append(segment.Start.ToString(@"hh\:mm\:ss"))
              .Append("] ")
              .Append(segment.Speaker)
              .Append(' ')
              .AppendLine(segment.Text);
        }

        return sb.ToString();
    }

    private void OnSpeakerNameChanged(object sender, TextChangedEventArgs e)
    {
        if (sender is TextBox textBox && textBox.DataContext is SpeakerViewModel speaker)
        {
            foreach (var segment in TranscriptionSegments.Where(s => s.SpeakerId == speaker.Id))
            {
                segment.SpeakerName = speaker.Name;
            }
            _speakerNameMap[speaker.Id] = speaker.Name;
            SetUnsavedChanges(true);
        }
    }

    private void OnSegmentTextChanged(object sender, TextChangedEventArgs e)
    {
        SetUnsavedChanges(true);
    }

    private void SetUnsavedChanges(bool hasChanges)
    {
        _hasUnsavedChanges = hasChanges;
        if (SaveIndicator != null)
        {
            SaveIndicator.Fill = hasChanges
                ? new Microsoft.UI.Xaml.Media.SolidColorBrush(Windows.UI.Color.FromArgb(255, 255, 193, 7)) // 
                : new Microsoft.UI.Xaml.Media.SolidColorBrush(Windows.UI.Color.FromArgb(255, 76, 175, 80)); // 
        }
    }

    private void OnSpeakerRightTapped(object sender, Microsoft.UI.Xaml.Input.RightTappedRoutedEventArgs e)
    {
    }

    private async void OnRenameSpeakerClicked(object sender, RoutedEventArgs e)
    {
        TranscriptionSegmentViewModel? segment = null;

        if (sender is MenuFlyoutItem menuItem)
        {
            segment = menuItem.Tag as TranscriptionSegmentViewModel;
        }

        if (segment == null) return;

        var speakerId = segment.SpeakerId;
        var currentName = segment.SpeakerName;

        var inputBox = new TextBox
        {
            Text = currentName,
            PlaceholderText = "Enter speaker name",
            SelectionStart = 0,
            SelectionLength = currentName.Length
        };

        var dialog = new ContentDialog
        {
            Title = "Rename speaker",
            Content = new StackPanel
            {
                Spacing = 8,
                Children =
                {
                    new TextBlock { Text = $"Original ID: {speakerId}" },
                    inputBox
                }
            },
            PrimaryButtonText = "Rename",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = Content.XamlRoot
        };

        var result = await dialog.ShowAsync();

        if (result == ContentDialogResult.Primary && !string.IsNullOrWhiteSpace(inputBox.Text))
        {
            var newName = inputBox.Text.Trim();

            foreach (var seg in TranscriptionSegments.Where(s => s.SpeakerId == speakerId))
            {
                seg.SpeakerName = newName;
            }

            var speakerVm = Speakers.FirstOrDefault(s => s.Id == speakerId);
            if (speakerVm != null)
            {
                speakerVm.Name = newName;
            }

            _speakerNameMap[speakerId] = newName;
            SetUnsavedChanges(true);
        }
    }

    private async void OnTimestampClicked(object sender, RoutedEventArgs e)
    {
        if (sender is Button button && button.Tag is TranscriptionSegmentViewModel segment)
        {
            if (_playingSegment == segment && _playbackService.State == PlaybackState.Playing)
            {
                _playbackService.Stop();
                _playingSegment = null;
                return;
            }

            if (_lastRecordingPath != null && _playbackService.LoadedFilePath != _lastRecordingPath)
            {
                try
                {
                    await _playbackService.LoadAsync(_lastRecordingPath);
                }
                catch (Exception ex)
                {
                    System.Diagnostics.Debug.WriteLine($"Audio loading error: {ex.Message}");
                    await ShowErrorDialogAsync($"Failed to load audio: {ex.Message}");
                    return;
                }
            }

            _playbackService.PlaySegment(segment.Start, segment.End, loop: true);
            _playingSegment = segment;
        }
    }

    private void OnPlaybackStateChanged(object? sender, PlaybackState state)
    {
        _dispatcherQueue.TryEnqueue(() =>
        {
            if (state == PlaybackState.Stopped)
            {
                _playingSegment = null;
            }
        });
    }

    private async void OnSaveTranscriptionClicked(object sender, RoutedEventArgs e)
    {
        if (_lastTranscriptionPath == null)
            return;

        try
        {
            var sb = new StringBuilder();

            foreach (var segment in TranscriptionSegments)
            {
                var speakerName = _speakerNameMap.TryGetValue(segment.SpeakerId, out var name)
                    ? name
                    : segment.SpeakerName;

                if (segment.Start != TimeSpan.Zero || segment.End != TimeSpan.Zero)
                {
                    var startStr = $"{(int)segment.Start.TotalHours:00}:{segment.Start.Minutes:00}:{segment.Start.Seconds:00}.{segment.Start.Milliseconds:000}";
                    var endStr = $"{(int)segment.End.TotalHours:00}:{segment.End.Minutes:00}:{segment.End.Seconds:00}.{segment.End.Milliseconds:000}";
                    sb.AppendLine($"[{startStr} --> {endStr}] [{speakerName}]: {segment.Text}");
                }
                else
                {
                    sb.AppendLine(segment.Text);
                }
            }

            await File.WriteAllTextAsync(_lastTranscriptionPath, sb.ToString());
            SetUnsavedChanges(false);
        }
        catch (Exception ex)
        {
            await ShowErrorDialogAsync($"Save error: {ex.Message}");
        }
    }

    private void OnTranscriptionProgressChanged(object? sender, TranscriptionProgress progress)
    {
        _dispatcherQueue.TryEnqueue(() =>
        {
            TranscriptionStatusText.Text = progress.StatusMessage ?? progress.State.ToString();

            if (progress.ProgressPercent >= 0)
            {
                TranscriptionProgressBar.IsIndeterminate = false;
                TranscriptionProgressBar.Value = progress.ProgressPercent;
            }
            else
            {
                TranscriptionProgressBar.IsIndeterminate = true;
            }

            if (progress.State == TranscriptionState.Transcribing && progress.ProgressPercent > 0)
            {
                TranscriptionDetailsGrid.Visibility = Visibility.Visible;

                if (progress.ElapsedTime.HasValue)
                {
                    ElapsedTimeText.Text = FormatTimeSpan(progress.ElapsedTime.Value);
                }

                if (progress.Speed.HasValue && progress.Speed.Value > 0)
                {
                    SpeedText.Text = $"{progress.Speed.Value:F1}x";
                }

                if (progress.RemainingTime.HasValue && progress.RemainingTime.Value.TotalSeconds > 5)
                {
                    RemainingTimeText.Text = $"~{FormatTimeSpan(progress.RemainingTime.Value)}";
                }
                else
                {
                    RemainingTimeText.Text = "soon...";
                }
            }
            else
            {
                TranscriptionDetailsGrid.Visibility = Visibility.Collapsed;
            }
        });
    }

    private static string FormatTimeSpan(TimeSpan ts)
    {
        if (ts.TotalHours >= 1)
            return ts.ToString(@"h\:mm\:ss");
        return ts.ToString(@"m\:ss");
    }

    private void OnRecordingStateChanged(object? sender, RecordingInfo info)
    {
        _dispatcherQueue.TryEnqueue(() =>
        {
            UpdateRecordingInfo(info);
        });
    }

    private void UpdateRecordingInfo()
    {
        var info = _audioCaptureService.GetCurrentRecordingInfo();
        UpdateRecordingInfo(info);
    }

    private void UpdateRecordingInfo(RecordingInfo info)
    {
        StateTextBlock.Text = info.State switch
        {
            RecordingState.Stopped => "Stopped",
            RecordingState.Recording => "Recording",
            RecordingState.Paused => "Pause",
            _ => "Unknown"
        };

        DurationTextBlock.Text = info.Duration.ToString(@"hh\:mm\:ss");
        FileSizeTextBlock.Text = FormatFileSize(info.FileSizeBytes);
    }

    private static string FormatFileSize(long bytes)
    {
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

    public (RecordingState State, bool HasSourceSelection) GetTrayStateSnapshot()
    {
        var info = _audioCaptureService.GetCurrentRecordingInfo();
        bool hasSelection = OutputSources.Any(s => s.IsSelected) || InputSources.Any(s => s.IsSelected);
        return (info.State, hasSelection);
    }

    public void ToggleRecordingFromTray()
    {
        OnStartStopClicked(this, new RoutedEventArgs());
    }

    public void TogglePauseFromTray()
    {
        OnPauseResumeClicked(this, new RoutedEventArgs());
    }

    private string GetOutputPath()
    {
        var savedFolder = _settingsService.LoadOutputFolder();
        var outputFolder = !string.IsNullOrEmpty(savedFolder)
            ? savedFolder
            : GetDefaultOutputFolder();

        Directory.CreateDirectory(outputFolder);

        var timestamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
        return Path.Combine(outputFolder, $"recording_{timestamp}.wav");
    }

    private static string GetDefaultOutputFolder()
    {
        var documents = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        var contoraFolder = Path.Combine(documents, "Contora");
        var legacyFolder = Path.Combine(documents, "AudioRecorder");

        if (Directory.Exists(contoraFolder))
            return contoraFolder;
        if (Directory.Exists(legacyFolder))
            return legacyFolder;
        return contoraFolder;
    }

    private async Task ShowRecordingSavedDialogAsync(string filePath)
    {
        var fileName = Path.GetFileName(filePath);
        var fileSize = FormatFileSize(new FileInfo(filePath).Length);

        var dialog = new ContentDialog
        {
            Title = "Recording saved",
            Content = new StackPanel
            {
                Spacing = 12,
                Children =
                {
                    new TextBlock
                    {
                        Text = $"File: {fileName}\nSize: {fileSize}",
                        TextWrapping = TextWrapping.Wrap
                    },
                    new HyperlinkButton
                    {
                        Content = "Open folder",
                        Tag = filePath
                    }
                }
            },
            CloseButtonText = "OK",
            XamlRoot = Content.XamlRoot
        };

        var stackPanel = (StackPanel)dialog.Content;
        var button = (HyperlinkButton)stackPanel.Children[1];
        button.Click += (s, e) =>
        {
            try
            {
                var folderPath = Path.GetDirectoryName(filePath);
                if (folderPath != null)
                {
                    System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{filePath}\"");
                }
            }
            catch { }
        };

        await dialog.ShowAsync();
    }

    private async Task ShowErrorDialogAsync(string message)
    {
        var dialog = new ContentDialog
        {
            Title = "Error",
            Content = message,
            CloseButtonText = "OK",
            XamlRoot = Content.XamlRoot
        };

        await dialog.ShowAsync();
    }
}







