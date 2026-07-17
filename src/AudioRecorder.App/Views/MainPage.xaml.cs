using AudioRecorder.Core.Models;
using AudioRecorder.Core.Services;
using AudioRecorder.Services.Audio;
using AudioRecorder.Services.Hardware;
using AudioRecorder.Services.Integrations;
using AudioRecorder.Services.Notifications;
using AudioRecorder.Services.Pipeline;
using AudioRecorder.Services.Models;
using AudioRecorder.Services.Settings;
using AudioRecorder.Services.Transcription;
using AudioRecorder.Services.Embeddings;
using AudioRecorder.Services.Storage;
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

public sealed class SessionViewModel
{
    public Guid Id { get; set; }
    public string Title { get; set; } = string.Empty;
    public string DateDurationDisplay { get; set; } = string.Empty;
    public string PreviewText { get; set; } = string.Empty;
    public string StateLabel { get; set; } = string.Empty;
    public Microsoft.UI.Xaml.Media.Brush StateBrush { get; set; } =
        new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Gray);
    public string? TranscriptPath { get; set; }
    public string? OutlineDocumentUrl { get; set; }
    public string? SummaryText { get; set; }
    public string? ActionItemsJson { get; set; }
    public string? DecisionsJson { get; set; }

    public Microsoft.UI.Xaml.Visibility OutlineUrlVisibility =>
        OutlineDocumentUrl != null
            ? Microsoft.UI.Xaml.Visibility.Visible
            : Microsoft.UI.Xaml.Visibility.Collapsed;

    /// <summary>Shown when transcript exists but not yet published to Outline.</summary>
    public Microsoft.UI.Xaml.Visibility PublishButtonVisibility =>
        TranscriptPath != null && OutlineDocumentUrl == null
            ? Microsoft.UI.Xaml.Visibility.Visible
            : Microsoft.UI.Xaml.Visibility.Collapsed;

    public static SessionViewModel FromSession(Session s)
    {
        var (label, color) = s.State switch
        {
            SessionState.Recorded => ("Recorded", Windows.UI.Color.FromArgb(255, 100, 130, 200)),
            SessionState.Transcribing => ("Transcribing…", Windows.UI.Color.FromArgb(255, 200, 150, 50)),
            SessionState.Transcribed => ("Transcribed", Windows.UI.Color.FromArgb(255, 60, 160, 80)),
            SessionState.Exported => ("Exported", Windows.UI.Color.FromArgb(255, 100, 100, 200)),
            _ => ("Unknown", Windows.UI.Color.FromArgb(255, 128, 128, 128)),
        };

        var duration = TimeSpan.FromSeconds(s.DurationSeconds);
        var durationStr = s.DurationSeconds >= 3600
            ? duration.ToString(@"h\:mm\:ss")
            : duration.ToString(@"m\:ss");

        return new SessionViewModel
        {
            Id = s.Id,
            Title = s.Title,
            DateDurationDisplay = $"{s.RecordedAt:dd MMM yyyy, HH:mm}  ·  {durationStr}",
            PreviewText = s.PreviewText ?? string.Empty,
            StateLabel = label,
            StateBrush = new Microsoft.UI.Xaml.Media.SolidColorBrush(color),
            TranscriptPath = s.TranscriptPath,
            OutlineDocumentUrl = s.OutlineDocumentUrl,
            SummaryText = s.SummaryText,
            ActionItemsJson = s.ActionItemsJson,
            DecisionsJson = s.DecisionsJson,
        };
    }
}

public sealed partial class MainPage : Page
{
    private readonly IAudioCaptureService _audioCaptureService;
    private ITranscriptionService _transcriptionService;
    private readonly ISettingsService _settingsService;
    private readonly IAudioPlaybackService _playbackService;
    private readonly ISessionPipelineService _sessionPipelineService;
    private readonly ISessionStore _sessionStore;
    private IOutlineService _outlineService;
    private readonly AppUpdateService _appUpdateService;
    private readonly WhisperRuntimeInstallerService _runtimeInstallerService;
    private WhisperModelDownloadService _modelDownloadService;
    private readonly FfmpegInstallerService _ffmpegInstallerService;
    private readonly SharedModelConfigService _sharedConfigService;
    private readonly DictatorSharedStoreService _dictatorStoreService;
    private readonly DispatcherQueue _dispatcherQueue;
    private readonly DispatcherQueueTimer _updateTimer;
    private string? _lastRecordingPath;
    private string? _lastTranscriptionPath;
    private Guid? _currentSessionId;
    private DispatcherQueueTimer? _searchDebounceTimer;
    private CancellationTokenSource? _transcriptionCts;
    private bool _isSettingsPanelVisible = true;
    private TranscriptionSegmentViewModel? _playingSegment;
    private bool _hasUnsavedChanges;
    private OllamaEmbeddingService _embeddingService = null!;
    private SemanticSearchService _semanticSearch = null!;
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
    private string _deviceMode = "auto";
    private bool _isTranscribing = false;
    private TimeSpan? _lastTranscriptionAudioDuration; // last known audio duration from progress events
    private string? _pendingAudioPath;
    private readonly Dictionary<string, string> _speakerNameMap = new();

    public ObservableCollection<AudioSourceViewModel> OutputSources { get; } = new();
    public ObservableCollection<AudioSourceViewModel> InputSources { get; } = new();
    public ObservableCollection<SpeakerViewModel> Speakers { get; } = new();
    public ObservableCollection<TranscriptionSegmentViewModel> TranscriptionSegments { get; } = new();
    public ObservableCollection<SessionViewModel> Sessions { get; } = new();

    // ── Analysis panel data ─────────────────────────────────────────────────
    public ObservableCollection<string> AnalysisActionItems { get; } = new();
    public ObservableCollection<string> AnalysisDecisions { get; } = new();
    public ObservableCollection<string> AnalysisRisks { get; } = new();

    // ── Sessions filter & pagination ────────────────────────────────────────
    private SessionState? _activeStateFilter = null;
    private const int SessionPageSize = 20;
    private int _sessionPageCount = 1; // how many pages loaded so far

    public MainPage()
    {
        InitializeComponent();

        _audioCaptureService = new WasapiAudioCaptureService();
        _audioCaptureService.RecordingStateChanged += OnRecordingStateChanged;
        _audioCaptureService.DeviceListChanged += OnAudioDeviceListChanged;

        _settingsService = new LocalSettingsService();
        _transcriptionMode = _settingsService.LoadTranscriptionMode();
        _whisperModel = _settingsService.LoadWhisperModel();
        _deviceMode = _settingsService.LoadDeviceMode();

        // Must exist before CreateTranscriptionService: the whisper-net branch resolves the
        // diarization backend via _dictatorStoreService, so it has to be constructed first.
        _sharedConfigService = new SharedModelConfigService();
        _dictatorStoreService = new DictatorSharedStoreService();
        _ = _dictatorStoreService.LoadStoreAsync(); // warm up async, non-blocking

        _transcriptionService = CreateTranscriptionService(_transcriptionMode);
        _transcriptionService.ProgressChanged += OnTranscriptionProgressChanged;

        _playbackService = new AudioPlaybackService();
        _sessionPipelineService = new SessionPipelineService();
        _sessionStore = new SqliteSessionStore();
        _outlineService = CreateOutlineService();
        _playbackService.StateChanged += OnPlaybackStateChanged;
        _appUpdateService = new AppUpdateService();
        var customInstallRoot = _settingsService.LoadInstallRootPath();
        _runtimeInstallerService = new WhisperRuntimeInstallerService(customInstallRoot);
        _modelDownloadService = new WhisperModelDownloadService(_whisperModel);
        _ffmpegInstallerService = new FfmpegInstallerService();
        _embeddingService = new OllamaEmbeddingService();
        _semanticSearch = new SemanticSearchService(_sessionStore, _embeddingService);

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
            _transcriptionService.ProgressChanged -= OnTranscriptionProgressChanged;
            (_transcriptionService as IDisposable)?.Dispose();
        };
    }

    private async void OnPageLoaded(object sender, RoutedEventArgs e)
    {
        await _sessionStore.InitializeAsync();
        _ = LoadSessionsAsync();
        await LoadAudioSourcesAsync();
        LoadOutputFolderSetting();
        LoadTranscriptionModeSetting();
        LoadWhisperModelSetting();
        UpdateDeviceInfoText();

        // Run hardware diagnostics in background so "auto" mode resolves correctly.
        // Once done, rebuild the transcription service with the right device.
        _ = InitializeDiagnosticsAsync();

        // Legacy-engine-only: these env vars point faster-whisper-xxl at its runtime/model dirs.
        // Skipped for Whisper.net to avoid the slow User-scoped env var write on the UI thread.
        if (_settingsService.LoadTranscriptionEngine() != "whisper-net"
            && _runtimeInstallerService.IsRuntimeInstalled())
        {
            WhisperPaths.RegisterEnvironmentVariables(_runtimeInstallerService.GetRuntimeExePath(), _whisperModel);
        }

        _ = CheckForUpdatesAsync(userInitiated: false);
        UpdateTranscriptionAvailabilityUi();
        _ = TryAutoSetupWhisperAsync();
        _ = CheckRuntimeVersionAsync();
    }

    /// <summary>
    /// Swaps in a freshly-built transcription service, disposing the outgoing one first.
    /// Without this, every model/mode switch orphaned the previous WhisperNet factory and — for
    /// whisper-net with diarization — its Sortformer python server process (fixed port 5002),
    /// leaking a GPU-resident process per switch for the lifetime of the app.
    /// </summary>
    private void ReplaceTranscriptionService(string mode)
    {
        _transcriptionService.ProgressChanged -= OnTranscriptionProgressChanged;
        (_transcriptionService as IDisposable)?.Dispose();
        _transcriptionService = CreateTranscriptionService(mode);
        _transcriptionService.ProgressChanged += OnTranscriptionProgressChanged;
    }

    private ITranscriptionService CreateTranscriptionService(string mode)
    {
        bool enableDiarization = !string.Equals(mode, "light", StringComparison.OrdinalIgnoreCase);
        var effectiveDevice = ResolveEffectiveDevice();

        if (_settingsService.LoadTranscriptionEngine() != "whisper-net")
        {
            return new WhisperTranscriptionService(
                modelName: _whisperModel,
                enableDiarization: enableDiarization,
                deviceMode: effectiveDevice,
                dictatorStore: _dictatorStoreService);
        }

        var ggmlModelPath = GgmlModelPaths.ResolveInstalledModelPath(_whisperModel, _dictatorStoreService);

        return new WhisperNetTranscriptionService(
            modelPath: ggmlModelPath ?? GgmlModelPaths.GetGgmlModelPath(GgmlModelPaths.GetGgmlModelsRoot(), _whisperModel),
            enableDiarization: enableDiarization,
            deviceMode: effectiveDevice,
            diarizationService: CreateDiarizationService());
    }

    /// <summary>
    /// Sortformer (NeMo, до 4 спикеров) точнее автоопределения числа спикеров у sherpa-onnx
    /// (эмпирически: 4 вместо 3 реальных на тестовой записи против 14 у sherpa-onnx с порогом
    /// по умолчанию), поэтому используется как основной бэкенд, когда доступен python-asr venv
    /// Dictator. Если venv не установлен — фолбэк на sherpa-onnx (полностью in-process, без Python).
    /// </summary>
    private IDiarizationService CreateDiarizationService()
    {
        var pythonExe = _dictatorStoreService?.GetPythonVenvPath();
        var sortformerScript = DiarizationServerBackend.FindScript();

        if (pythonExe is not null && sortformerScript is not null)
        {
            return new SortformerDiarizationService(pythonExe, sortformerScript);
        }

        var diarizationRoot = DiarizationModelPaths.GetDiarizationModelsRoot();
        return new SherpaOnnxDiarizationService(
            DiarizationModelPaths.GetSegmentationModelPath(diarizationRoot),
            DiarizationModelPaths.GetEmbeddingModelPath(diarizationRoot));
    }

    /// <summary>
    /// Resolves the actual device to pass to faster-whisper.
    /// If the user chose "auto", uses the hardware diagnostics recommendation
    /// (e.g. "cpu" for GT 220, "cuda" for RTX 3090) so faster-whisper never
    /// tries CUDA on incompatible hardware.
    /// If diagnostics haven't run yet, defaults to "cpu" (safe fallback).
    /// </summary>
    private string ResolveEffectiveDevice()
    {
        if (_deviceMode != "auto")
            return _deviceMode;

        return HardwareDiagnosticsService.LastResult?.RecommendedDevice ?? "cpu";
    }

    private void ApplyTranscriptionMode(string mode, bool save)
    {
        var normalized = string.Equals(mode, "light", StringComparison.OrdinalIgnoreCase) ? "light" : "quality";
        if (string.Equals(_transcriptionMode, normalized, StringComparison.OrdinalIgnoreCase))
            return;

        ReplaceTranscriptionService(normalized);
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

    private void LoadWhisperModelSetting() => _ = LoadWhisperModelSettingAsync();

    // One selectable model in the main dropdown. Each model carries the engine that can run it, so
    // picking a model transparently switches the engine — the user never has to think about engines.
    private sealed record ModelChoice(string Model, string Engine);

    private async Task LoadWhisperModelSettingAsync()
    {
        // Without this, models downloaded on disk but not yet merged into the shared config (e.g.
        // large-v3/large-v3-turbo under the legacy engine) are invisible here, and the engine/model
        // reconciliation below can't find them as a valid choice for the just-selected engine.
        await _sharedConfigService.RefreshFromDiskAsync();
        var config = await _sharedConfigService.LoadAsync();
        var currentEngine = _settingsService.LoadTranscriptionEngine();
        var activeModel = !string.IsNullOrWhiteSpace(config.ActiveModelName)
            ? config.ActiveModelName!
            : _settingsService.LoadWhisperModel();

        // Build a single list of everything Contora can actually run, across both engines:
        //  - GGML files  → Whisper.net (in-process)
        //  - CTranslate2 → legacy faster-whisper-xxl
        var choices = new List<(ModelChoice Choice, string Label)>();

        foreach (var name in GgmlModelPaths.EnumerateInstalledModelNames(_dictatorStoreService))
            choices.Add((new ModelChoice(name, "whisper-net"), $"{name}  ·  Whisper.net"));

        foreach (var m in config.InstalledModels.Where(m => m.RuntimeId != "whisper-net-ggml"))
        {
            // Skip a CTranslate2 entry if a GGML model of the same name is already listed to avoid
            // two confusingly-identical rows; the GGML/Whisper.net one is preferred.
            if (choices.Any(c => string.Equals(c.Choice.Model, m.Name, StringComparison.OrdinalIgnoreCase)))
                continue;
            choices.Add((new ModelChoice(m.Name, "legacy-fwx"), $"{m.Name}  ·  faster-whisper"));
        }

        WhisperModelComboBox.SelectionChanged -= OnWhisperModelChanged;
        WhisperModelComboBox.Items.Clear();
        foreach (var (choice, label) in choices)
            WhisperModelComboBox.Items.Add(new ComboBoxItem { Content = label, Tag = choice });

        // Prefer the persisted (engine, model) pair; else *some* model under the currently selected
        // engine; else the same model under a different engine; else first. Engine before model-name
        // match matters: currentEngine reflects whatever the user just picked in Settings (possibly
        // moments ago), and that choice must win even if the previously active model isn't registered
        // under the new engine (e.g. a GGML-only model with no faster-whisper counterpart listed) —
        // otherwise this "keep things coherent" pass silently reverts the engine switch.
        var selectedIndex = choices.FindIndex(c =>
            string.Equals(c.Choice.Model, activeModel, StringComparison.OrdinalIgnoreCase) &&
            string.Equals(c.Choice.Engine, currentEngine, StringComparison.OrdinalIgnoreCase));
        if (selectedIndex < 0)
            selectedIndex = choices.FindIndex(c => string.Equals(c.Choice.Engine, currentEngine, StringComparison.OrdinalIgnoreCase));
        if (selectedIndex < 0)
            selectedIndex = choices.FindIndex(c => string.Equals(c.Choice.Model, activeModel, StringComparison.OrdinalIgnoreCase));
        if (selectedIndex < 0 && choices.Count > 0)
            selectedIndex = 0;

        if (selectedIndex >= 0)
            WhisperModelComboBox.SelectedIndex = selectedIndex;

        WhisperModelComboBox.SelectionChanged += OnWhisperModelChanged;

        if (selectedIndex >= 0)
        {
            var chosen = choices[selectedIndex].Choice;
            // Apply if the resolved (engine, model) differs from the live state — keeps the engine,
            // settings.WhisperModel and shared active-model coherent after any drift.
            if (!string.Equals(_whisperModel, chosen.Model, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(currentEngine, chosen.Engine, StringComparison.OrdinalIgnoreCase))
            {
                ApplyModelChoice(chosen, save: true);
            }
        }
        else
        {
            // Nothing installed for either engine — show the "download a model" hint.
            UpdateTranscriptionAvailabilityUi();
        }
    }

    private async Task InitializeDiagnosticsAsync()
    {
        try
        {
            var diag = await HardwareDiagnosticsService.RunAsync();
            _dispatcherQueue.TryEnqueue(() =>
            {
                // Rebuild service: "auto" now resolves to the correct device
                ReplaceTranscriptionService(_transcriptionMode);
                UpdateDeviceInfoText();
            });
        }
        catch { }
    }

    private void UpdateDeviceInfoText()
    {
        var effective = ResolveEffectiveDevice();
        var deviceLabel = effective switch
        {
            "cuda" => "GPU (CUDA)",
            _      => "CPU"
        };

        var modeLabel = _deviceMode == "auto"
            ? $"Auto → {deviceLabel}"
            : deviceLabel;

        DeviceInfoText.Text = $"Device: {modeLabel} · Model: {_whisperModel}";
    }

    private void ApplyWhisperModel(string modelName, bool save)
    {
        var normalized = WhisperModelDownloadService.NormalizeModelName(modelName);
        if (string.Equals(_whisperModel, normalized, StringComparison.OrdinalIgnoreCase))
            return;

        _whisperModel = normalized;

        ReplaceTranscriptionService(_transcriptionMode);

        if (save)
        {
            _settingsService.SaveWhisperModel(_whisperModel);
            _ = UpdateSharedActiveModelAsync(_whisperModel);
        }

        _modelDownloadService = new WhisperModelDownloadService(_whisperModel);

        // RegisterEnvironmentVariables writes User-scoped env vars, which broadcasts a system
        // settings-change message and can stall the UI thread for seconds. These vars only matter
        // for the legacy faster-whisper-xxl engine, so skip the cost entirely for Whisper.net.
        if (_settingsService.LoadTranscriptionEngine() != "whisper-net"
            && _runtimeInstallerService.IsRuntimeInstalled())
        {
            WhisperPaths.RegisterEnvironmentVariables(_runtimeInstallerService.GetRuntimeExePath(), _whisperModel);
        }

        UpdateTranscriptionAvailabilityUi();
        UpdateDeviceInfoText();
    }

    private async Task UpdateSharedActiveModelAsync(string modelName)
    {
        try
        {
            var config = await _sharedConfigService.LoadAsync();
            config.ActiveModelName = modelName;
            await _sharedConfigService.SaveAsync(config);
        }
        catch { }
    }

    private Task TryAutoSetupWhisperAsync()
    {
        // Only update the UI to show what needs to be downloaded.
        // The user must initiate downloads manually.
        UpdateTranscriptionAvailabilityUi();
        return Task.CompletedTask;
    }

    private async Task CheckRuntimeVersionAsync()
    {
        if (!_runtimeInstallerService.IsRuntimeInstalled())
            return;

        try
        {
            var (version, versionStr) = await _runtimeInstallerService.GetInstalledVersionAsync();
            if (version == null)
                return;

            // Store version in shared config
            var config = await _sharedConfigService.LoadAsync();
            var runtime = config.InstalledRuntimes.FirstOrDefault(r => r.Id == "faster-whisper-xxl");
            if (runtime != null && runtime.Version != versionStr)
            {
                runtime.Version = versionStr;
                await _sharedConfigService.SaveAsync(config);
            }

            if (version < WhisperRuntimeInstallerService.MinimumRequiredVersion)
            {
                _dispatcherQueue.TryEnqueue(() =>
                {
                    RuntimeOutdatedBar.Title = $"Whisper runtime outdated ({versionStr})";
                    RuntimeOutdatedBar.Message = "Update required for diarization support. Current version does not support --diarize flag.";
                    RuntimeOutdatedBar.IsOpen = true;
                    UpdateRuntimeButton.Visibility = Visibility.Visible;
                });
            }
        }
        catch
        {
            // Version check is best-effort
        }
    }

    private async void OnUpdateRuntimeClicked(object sender, RoutedEventArgs e)
    {
        RuntimeOutdatedBar.IsOpen = false;
        UpdateRuntimeButton.Visibility = Visibility.Collapsed;

        // Delete old runtime
        var runtimeRoot = WhisperPaths.GetCanonicalRuntimeRoot();
        if (Directory.Exists(runtimeRoot))
        {
            try
            {
                Directory.Delete(runtimeRoot, recursive: true);
            }
            catch (Exception ex)
            {
                RuntimeDownloadStatusText.Visibility = Visibility.Visible;
                RuntimeDownloadStatusText.Text = $"Failed to delete old runtime: {ex.Message}";
                return;
            }
        }

        await _sharedConfigService.UnregisterRuntimeAsync("faster-whisper-xxl");

        // Download new runtime
        await StartRuntimeDownloadAsync();

        // Re-check version after install
        if (_runtimeInstallerService.IsRuntimeInstalled())
        {
            var (version, versionStr) = await _runtimeInstallerService.GetInstalledVersionAsync();
            if (version != null)
            {
                await _sharedConfigService.RegisterRuntimeAsync(
                    "faster-whisper-xxl",
                    "Faster Whisper XXL",
                    _runtimeInstallerService.GetRuntimeExePath(),
                    versionStr);
            }
        }
    }

    private void UpdateTranscriptionAvailabilityUi()
    {
        var ffmpegInstalled = _ffmpegInstallerService.IsInstalled();

        RuntimeOutdatedBar.IsOpen = false;
        UpdateRuntimeButton.Visibility = Visibility.Collapsed;
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

        // Whisper.net has no separate "runtime" to install and no CTranslate2-style model
        // directory check — _transcriptionService.IsWhisperAvailable already reflects GGML
        // file presence (including models shared from Dictator), so that single check is enough.
        if (_settingsService.LoadTranscriptionEngine() == "whisper-net")
        {
            if (!_transcriptionService.IsWhisperAvailable)
            {
                WhisperWarningBar.Title = "Whisper model is missing";
                WhisperWarningBar.Message = $"Download model '{_whisperModel}' (GGML) via Settings → Models, or select an existing model already shared with Dictator.";
                WhisperWarningBar.IsOpen = true;
                TranscribeButton.IsEnabled = false;
                UpdateFfmpegUi(ffmpegInstalled);
                return;
            }

            WhisperWarningBar.IsOpen = false;
            TranscribeButton.IsEnabled = true;
            UpdateFfmpegUi(ffmpegInstalled);
            return;
        }

        var whisperAvailable = _transcriptionService.IsWhisperAvailable;
        var modelInstalled = _modelDownloadService.IsModelInstalled();

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
            _dictatorStoreService,
            _settingsService,
            onSettingsChanged: () =>
            {
                _dispatcherQueue.TryEnqueue(() =>
                {
                    // Reload transcription mode
                    LoadTranscriptionModeSetting();
                    LoadWhisperModelSetting();
                    // Reload device mode and rebuild service
                    _deviceMode = _settingsService.LoadDeviceMode();
                    ReplaceTranscriptionService(_transcriptionMode);
                    LoadOutputFolderSetting();
                    UpdateTranscriptionAvailabilityUi();
                    UpdateDeviceInfoText();
                    _outlineService = CreateOutlineService();
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

            // Show top-of-page banner with the available version
            _availableUpdateInfo = checkResult.UpdateInfo;
            var newVersion = checkResult.UpdateInfo.TargetFullRelease.Version;
            UpdateAvailableBanner.Message = $"Версия {newVersion} — скачивается в фоне...";
            UpdateAvailableBanner.IsOpen = true;
            UpdateBannerInstallButton.IsEnabled = false;

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

            // Update banner: ready to install
            if (UpdateAvailableBanner.IsOpen)
            {
                var readyVersion = _readyToApplyRelease.Version;
                UpdateAvailableBanner.Message = $"Версия {readyVersion} загружена и готова к установке.";
                UpdateBannerInstallButton.IsEnabled = true;
            }
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

    /// <summary>
    /// "Обновить" button in the top InfoBar banner — same as OnApplyUpdateClicked.
    /// </summary>
    private async void OnUpdateBannerInstallClicked(object sender, RoutedEventArgs e)
    {
        await OnApplyUpdateClickedCore();
    }

    private async Task OnApplyUpdateClickedCore()
    {
        if (_readyToApplyRelease == null) return;

        var dialog = new ContentDialog
        {
            Title = "Применить обновление",
            Content = "Приложение перезапустится для завершения установки.",
            PrimaryButtonText = "Обновить и перезапустить",
            CloseButtonText = "Отмена",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = Content.XamlRoot
        };

        var result = await dialog.ShowAsync();
        if (result != ContentDialogResult.Primary) return;

        var started = _appUpdateService.ApplyUpdateAndRestart(_readyToApplyRelease);
        if (!started)
            await ShowErrorDialogAsync("Failed to apply update.");
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
            AudioRecorder.Services.Logging.AppLogger.LogError($"LoadAudioSourcesAsync failed: {ex.Message}");
            await ShowErrorDialogAsync($"Failed to load devices: {ex.Message}");
        }
    }

    private void OnSourceSelectionChanged(object sender, RoutedEventArgs e)
    {
        UpdateStartButtonState();
        var selected = OutputSources.Concat(InputSources).Where(s => s.IsSelected).Select(s => s.Source.Id);
        _settingsService.SaveSelectedSourceIds(selected);
    }

    private void OnAudioDeviceListChanged(object? sender, EventArgs e)
    {
        // Invoked on a background thread by IMMNotificationClient — marshal to UI thread
        _dispatcherQueue?.TryEnqueue(async () =>
        {
            // Don't disrupt an active recording
            if (_audioCaptureService.GetCurrentRecordingInfo().State != RecordingState.Stopped)
                return;
            await LoadAudioSourcesAsync();
        });
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
                var recordingInfo = _audioCaptureService.GetCurrentRecordingInfo();
                var recordedDuration = recordingInfo.Duration;
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

                    if (_isTranscribing)
                        _pendingAudioPath = _lastRecordingPath;
                    else
                        ShowTranscriptionSection();
                    _ = SaveNewSessionAsync(_lastRecordingPath, recordedDuration);
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
                // Importing a new file — detach from any previously recorded session
                _currentSessionId = null;

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

        if (item.Tag is ModelChoice choice)
            ApplyModelChoice(choice, save: true);
    }

    /// <summary>
    /// Applies a model together with the engine that runs it, then rebuilds the transcription
    /// service. This is the single entry point that keeps engine + model in sync when the user
    /// picks a model in the main dropdown.
    /// </summary>
    private void ApplyModelChoice(ModelChoice choice, bool save)
    {
        var engineChanged = !string.Equals(_settingsService.LoadTranscriptionEngine(), choice.Engine, StringComparison.OrdinalIgnoreCase);
        if (save && engineChanged)
            _settingsService.SaveTranscriptionEngine(choice.Engine);

        // Force a rebuild even if only the engine changed (ApplyWhisperModel early-returns when the
        // model name is unchanged, so handle the engine-only case explicitly).
        var modelChanged = !string.Equals(_whisperModel, choice.Model, StringComparison.OrdinalIgnoreCase);
        if (modelChanged)
        {
            ApplyWhisperModel(choice.Model, save);
        }
        else if (engineChanged)
        {
            ReplaceTranscriptionService(_transcriptionMode);
            if (save)
                _ = UpdateSharedActiveModelAsync(_whisperModel);
            UpdateTranscriptionAvailabilityUi();
            UpdateDeviceInfoText();
        }
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
        CopyTranscriptButton.Visibility = Visibility.Collapsed;
        ExportToOutlineButton.Visibility = Visibility.Collapsed;

        UpdateTranscriptionAvailabilityUi();
    }

    private async void OnTranscribeClicked(object sender, RoutedEventArgs e)
    {
        // If already transcribing — cancel
        if (_isTranscribing)
        {
            _transcriptionCts?.Cancel();
            TranscribeButton.Content = "Stopping...";
            TranscribeButton.IsEnabled = false;
            return;
        }

        if (_lastRecordingPath == null || !File.Exists(_lastRecordingPath))
        {
            await ShowErrorDialogAsync("Recording file not found");
            return;
        }

        // For imported files there is no prior session — create one now before transcription starts.
        // (Recordings create their session on stop, so _currentSessionId is already set in that case.)
        if (_currentSessionId == null)
            await CreateImportedFileSessionAsync(_lastRecordingPath);

        // Capture current values so a new recording started in parallel doesn't overwrite them
        var audioPath = _lastRecordingPath;
        var transcriptionSessionId = _currentSessionId;

        _isTranscribing = true;
        TranscribeButton.Content = "Stop transcription";
        TranscriptionProgressPanel.Visibility = Visibility.Visible;
        TranscriptionProgressBar.IsIndeterminate = true;
        TranscriptionStatusText.Text = "Preparing...";
        TranscriptionStatsPanel.Visibility = Visibility.Collapsed;

        _transcriptionCts = new CancellationTokenSource();
        _lastTranscriptionAudioDuration = null;
        var transcriptionStopwatch = System.Diagnostics.Stopwatch.StartNew();

        try
        {
            var result = await _transcriptionService.TranscribeAsync(audioPath, _transcriptionCts.Token);
            transcriptionStopwatch.Stop();

            if (result.Success)
            {
                var elapsed = transcriptionStopwatch.Elapsed;
                var audioDuration = _lastTranscriptionAudioDuration;
                var speedFactor = audioDuration is { TotalSeconds: > 0 } && elapsed.TotalSeconds > 0
                    ? audioDuration.Value.TotalSeconds / elapsed.TotalSeconds
                    : (double?)null;

                AudioRecorder.Services.Logging.AppLogger.LogInfo(
                    $"Transcription completed: {result.Segments.Count} segments, "
                    + $"audio {(audioDuration.HasValue ? FormatTimeSpan(audioDuration.Value) : "?")}, "
                    + $"elapsed {FormatTimeSpan(elapsed)}"
                    + (speedFactor.HasValue ? $", {speedFactor.Value:F1}x realtime" : "")
                    + $", model {_whisperModel}, engine {_settingsService.LoadTranscriptionEngine()}");

                _lastTranscriptionPath = result.OutputPath;
                TranscriptionStatusText.Text = $"Done! {result.Segments.Count} segments";
                TranscriptionProgressBar.IsIndeterminate = false;
                TranscriptionProgressBar.Value = 100;
                TranscriptionDetailsGrid.Visibility = Visibility.Collapsed;

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

                        var timeText = $"Time: {FormatTimeSpan(elapsed)}";
                        if (audioDuration.HasValue)
                            timeText += $" for {FormatTimeSpan(audioDuration.Value)} of audio";
                        if (speedFactor.HasValue)
                            timeText += $"  ·  {speedFactor.Value:F1}x realtime";
                        statsText += $"\n{timeText}";

                        TranscriptionStatsText.Text = statsText;
                        TranscriptionStatsPanel.Visibility = Visibility.Visible;
                    }
                    catch
                    {
                    }
                }

                var mp3Path = Path.ChangeExtension(audioPath, ".mp3");
                if (File.Exists(mp3Path))
                {
                    audioPath = mp3Path;
                    if (_pendingAudioPath == null) // only update UI file label if no new recording is pending
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
                        ? $"Saved (Ollama not available): {Path.GetFileName(pipelineResult.TargetPath)}"
                        : $"Saved with summary: {Path.GetFileName(pipelineResult.TargetPath)}";
                }
                else
                {
                    TranscriptionStatusText.Text = "Transcription is ready, but post-processing failed";
                    AudioRecorder.Services.Logging.AppLogger.LogWarning(
                        $"Session pipeline failed after transcription: {pipelineResult.ErrorMessage}");
                }

                if (File.Exists(audioPath))
                {
                    await _playbackService.LoadAsync(audioPath);
                }

                _ = UpdateSessionAfterTranscriptionAsync(transcriptionSessionId, result.OutputPath, result.Segments, pipelineResult.GeneratedTitle, pipelineResult.StructuredOutput);

                var fileName = Path.GetFileName(audioPath);
                NotificationService.ShowTranscriptionCompleted(fileName, result.Segments.Count, result.OutputPath);
            }
            else
            {
                await ShowErrorDialogAsync($"Transcription error:\n{result.ErrorMessage}");
                TranscriptionProgressPanel.Visibility = Visibility.Collapsed;
                TranscriptionDetailsGrid.Visibility = Visibility.Collapsed;
                TranscribeButton.Content = "Transcribe";
                TranscribeButton.IsEnabled = true;
            }
        }
        catch (OperationCanceledException)
        {
            TranscriptionStatusText.Text = "Transcription stopped";
            TranscriptionProgressBar.IsIndeterminate = false;
            TranscriptionProgressBar.Value = 0;
            TranscriptionDetailsGrid.Visibility = Visibility.Collapsed;
            TranscribeButton.Content = "Transcribe";
            TranscribeButton.IsEnabled = true;
        }
        catch (Exception ex)
        {
            await ShowErrorDialogAsync($"Error: {ex.Message}");
            TranscriptionProgressPanel.Visibility = Visibility.Collapsed;
            TranscriptionDetailsGrid.Visibility = Visibility.Collapsed;
            TranscribeButton.Content = "Transcribe";
            TranscribeButton.IsEnabled = true;
        }
        finally
        {
            _isTranscribing = false;
            TranscribeButton.Content = "Transcribe";
            TranscribeButton.IsEnabled = true;
            _transcriptionCts?.Dispose();
            _transcriptionCts = null;

            // If a new recording finished while we were transcribing, activate it now
            if (_pendingAudioPath != null)
            {
                _lastRecordingPath = _pendingAudioPath;
                _pendingAudioPath = null;
                ShowTranscriptionSection();
            }
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
        CopyTranscriptButton.Visibility = Visibility.Visible;
        ExportToOutlineButton.Visibility = _outlineService.IsConfigured ? Visibility.Visible : Visibility.Collapsed;
        SetUnsavedChanges(false);

        return Task.CompletedTask;
    }

    private Task LoadTranscriptionToUI(
        IReadOnlyList<TranscriptionSegment> segments,
        Dictionary<string, string> existingSpeakerNames)
    {
        TranscriptionSegments.Clear();
        Speakers.Clear();
        _speakerNameMap.Clear();

        var speakerIds = segments.Select(s => s.Speaker).Distinct().ToList();
        var speakerViewMap = new Dictionary<string, SpeakerViewModel>();

        foreach (var id in speakerIds)
        {
            var displayName = existingSpeakerNames.TryGetValue(id, out var saved) ? saved : id;
            var speaker = new SpeakerViewModel(id, displayName);
            Speakers.Add(speaker);
            speakerViewMap[id] = speaker;
            _speakerNameMap[id] = displayName;
        }

        foreach (var segment in segments)
        {
            var name = speakerViewMap.TryGetValue(segment.Speaker, out var sv) ? sv.Name : segment.Speaker;
            TranscriptionSegments.Add(new TranscriptionSegmentViewModel(segment, name));
        }

        SpeakersPanel.Visibility = Speakers.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        SaveTranscriptionButton.Visibility = Visibility.Visible;
        CopyTranscriptButton.Visibility = Visibility.Visible;
        ExportToOutlineButton.Visibility = _outlineService.IsConfigured ? Visibility.Visible : Visibility.Collapsed;
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

    // Shared rename path used by both the top speaker bar and the per-segment rename dialog,
    // so a rename from either UI updates the chip, every matching transcript segment, and the
    // name map (used on save/export) identically.
    private void RenameSpeaker(string speakerId, string newName)
    {
        newName = newName.Trim();
        if (string.IsNullOrEmpty(newName)) return;

        var speakerVm = Speakers.FirstOrDefault(s => s.Id == speakerId);
        if (speakerVm != null)
            speakerVm.Name = newName;

        foreach (var seg in TranscriptionSegments.Where(s => s.SpeakerId == speakerId))
            seg.SpeakerName = newName;

        _speakerNameMap[speakerId] = newName;
        SetUnsavedChanges(true);
    }

    private void OnSpeakerNameLostFocus(object sender, RoutedEventArgs e)
    {
        // Commit on LostFocus (not TextChanged): writing the source property on every keystroke
        // fed back into the bound TextBox.Text and reset the caret to position 0 on each key press,
        // making it impossible to type a name. Text is now OneWay, so nothing else writes it back
        // except this explicit commit.
        if (sender is TextBox textBox && textBox.Tag is SpeakerViewModel speaker)
        {
            var newName = textBox.Text.Trim();
            if (string.IsNullOrEmpty(newName))
            {
                textBox.Text = speaker.Name;
                return;
            }

            RenameSpeaker(speaker.Id, newName);
        }
    }

    private void OnSpeakerNameKeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter && sender is TextBox textBox)
        {
            // Move focus off the TextBox to trigger the LostFocus commit above.
            Microsoft.UI.Xaml.Input.FocusManager.TryMoveFocus(Microsoft.UI.Xaml.Input.FocusNavigationDirection.Next);
            e.Handled = true;
        }
    }

    private async void OnSpeakerSampleClicked(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement fe || fe.Tag is not SpeakerViewModel speaker) return;

        // Pick the longest segment for this speaker so the sample is long enough to identify
        // them by voice, instead of grabbing the first (possibly one-word) segment.
        var sample = TranscriptionSegments
            .Where(s => s.SpeakerId == speaker.Id)
            .OrderByDescending(s => (s.End - s.Start).TotalSeconds)
            .FirstOrDefault();

        if (sample != null)
            await PlaySegmentAsync(sample);
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
            RenameSpeaker(speakerId, inputBox.Text);
        }
    }

    private async void OnTimestampClicked(object sender, RoutedEventArgs e)
    {
        if (sender is Button button && button.Tag is TranscriptionSegmentViewModel segment)
        {
            await PlaySegmentAsync(segment);
        }
    }

    private async Task PlaySegmentAsync(TranscriptionSegmentViewModel segment)
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

        _playbackService.PlaySegment(segment.Start, segment.End, loop: false);
        _playingSegment = segment;
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

    private async void OnExportToOutlineClicked(object sender, RoutedEventArgs e)
    {
        if (!_outlineService.IsConfigured)
        {
            await ShowErrorDialogAsync("Outline is not configured. Set the URL and API token in Settings → Integrations.");
            return;
        }

        if (_currentSessionId == null)
        {
            await ShowErrorDialogAsync("No active session. Save the transcript first.");
            return;
        }

        ExportToOutlineButton.IsEnabled = false;
        var prevTooltip = ToolTipService.GetToolTip(ExportToOutlineButton)?.ToString() ?? "Export to Outline";
        ToolTipService.SetToolTip(ExportToOutlineButton, "Exporting…");

        try
        {
            var session = await _sessionStore.GetAsync(_currentSessionId.Value);
            if (session == null) return;

            var markdownText = BuildExportMarkdown();
            var title = session.Title;

            OutlineDocumentResult result;
            if (session.OutlineDocumentId is { } existingId)
            {
                result = await _outlineService.UpdateDocumentAsync(existingId, title, markdownText);
            }
            else
            {
                // Ask user which collection to publish to
                string? collectionId = await PickOutlineCollectionAsync();
                if (collectionId == null)
                {
                    ToolTipService.SetToolTip(ExportToOutlineButton, prevTooltip);
                    return; // user cancelled
                }
                result = await _outlineService.CreateDocumentAsync(title, markdownText, collectionId);
            }

            if (!result.Success)
            {
                await ShowErrorDialogAsync($"Outline export failed: {result.ErrorMessage}");
                ToolTipService.SetToolTip(ExportToOutlineButton, prevTooltip);
                return;
            }

            // Persist document ID/URL on the session
            if (result.DocumentId != null)
            {
                session.OutlineDocumentId = result.DocumentId;
                session.OutlineDocumentUrl = result.DocumentUrl;
                session.State = SessionState.Exported;
                await _sessionStore.UpdateAsync(session);
                _ = LoadSessionsAsync();
            }

            ToolTipService.SetToolTip(ExportToOutlineButton, "Update in Outline");
            TranscriptionStatusText.Text = prevTooltip == "Update in Outline"
                ? "Updated in Outline ✓"
                : "Exported to Outline ✓";

            AudioRecorder.Services.Logging.AppLogger.LogInfo(
                $"Outline export: {result.DocumentUrl ?? result.DocumentId}");
        }
        catch (Exception ex)
        {
            await ShowErrorDialogAsync($"Outline export error: {ex.Message}");
            ToolTipService.SetToolTip(ExportToOutlineButton, prevTooltip);
        }
        finally
        {
            ExportToOutlineButton.IsEnabled = true;
        }
    }

    /// <summary>
    /// Builds the full Markdown export: AI analysis (if present) followed by
    /// the transcript grouped by speaker (consecutive lines merged).
    /// </summary>
    /// <summary>
    /// Shows a collection picker dialog. Returns the selected collection ID, or null if cancelled.
    /// </summary>
    private async Task<string?> PickOutlineCollectionAsync()
    {
        var collectionsResult = await _outlineService.GetCollectionsAsync();
        if (!collectionsResult.Success || collectionsResult.Collections.Count == 0)
        {
            // Fall back to the default collection from settings
            var fallback = _settingsService.LoadOutlineDefaultCollectionId();
            if (fallback != null) return fallback;
            await ShowErrorDialogAsync("Could not load Outline collections. Check your connection and API token.");
            return null;
        }

        var listView = new ListView
        {
            ItemsSource = collectionsResult.Collections,
            DisplayMemberPath = "Name",
            SelectionMode = ListViewSelectionMode.Single,
            Height = 300,
        };

        // Pre-select the default collection if configured
        var defaultId = _settingsService.LoadOutlineDefaultCollectionId();
        if (defaultId != null)
        {
            var defaultItem = collectionsResult.Collections.FirstOrDefault(c => c.Id == defaultId);
            if (defaultItem != null) listView.SelectedItem = defaultItem;
        }
        if (listView.SelectedItem == null && collectionsResult.Collections.Count > 0)
            listView.SelectedItem = collectionsResult.Collections[0];

        var dialog = new ContentDialog
        {
            Title = "Choose Outline collection",
            Content = listView,
            PrimaryButtonText = "Export",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = Content.XamlRoot,
        };

        var result = await dialog.ShowAsync();
        if (result != ContentDialogResult.Primary) return null;

        return (listView.SelectedItem as AudioRecorder.Core.Models.OutlineCollection)?.Id;
    }

    private string BuildExportMarkdown()
    {
        var sb = new StringBuilder();

        // ── AI analysis ──────────────────────────────────────────────────────
        var summaryText = AnalysisSummaryText?.Text;
        if (!string.IsNullOrWhiteSpace(summaryText))
        {
            sb.AppendLine("## Summary");
            sb.AppendLine(summaryText);
            sb.AppendLine();
        }

        if (AnalysisActionItems.Count > 0)
        {
            sb.AppendLine("## Action Items");
            foreach (var item in AnalysisActionItems)
                sb.AppendLine($"- [ ] {item}");
            sb.AppendLine();
        }

        if (AnalysisDecisions.Count > 0)
        {
            sb.AppendLine("## Decisions");
            foreach (var d in AnalysisDecisions)
                sb.AppendLine($"- {d}");
            sb.AppendLine();
        }

        // ── Transcript grouped by speaker ────────────────────────────────────
        if (TranscriptionSegments.Count > 0)
        {
            sb.AppendLine("## Transcript");
            sb.AppendLine();

            string? lastSpeaker = null;
            var chunk = new StringBuilder();

            void FlushChunk()
            {
                if (lastSpeaker != null && chunk.Length > 0)
                {
                    sb.AppendLine($"**{lastSpeaker}:** {chunk.ToString().Trim()}");
                    sb.AppendLine();
                    chunk.Clear();
                }
            }

            foreach (var seg in TranscriptionSegments)
            {
                var speakerName = _speakerNameMap.TryGetValue(seg.SpeakerId, out var mapped)
                    ? mapped
                    : seg.SpeakerName;

                if (speakerName != lastSpeaker)
                {
                    FlushChunk();
                    lastSpeaker = speakerName;
                }

                if (chunk.Length > 0) chunk.Append(' ');
                chunk.Append(seg.Text.Trim());
            }

            FlushChunk();
        }

        return sb.ToString().TrimEnd();
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

    private void OnCopyTranscriptClicked(object sender, RoutedEventArgs e)
    {
        if (TranscriptionSegments.Count == 0) return;

        var sb = new StringBuilder();
        foreach (var segment in TranscriptionSegments)
        {
            var speakerName = _speakerNameMap.TryGetValue(segment.SpeakerId, out var name)
                ? name
                : segment.SpeakerName;

            if (segment.Start != TimeSpan.Zero || segment.End != TimeSpan.Zero)
            {
                var startStr = $"{(int)segment.Start.TotalHours:00}:{segment.Start.Minutes:00}:{segment.Start.Seconds:00}";
                sb.AppendLine($"[{startStr}] {speakerName}: {segment.Text}");
            }
            else
            {
                sb.AppendLine(segment.Text);
            }
        }

        var dp = new Windows.ApplicationModel.DataTransfer.DataPackage();
        dp.SetText(sb.ToString().TrimEnd());
        Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(dp);
    }

    private void OnCopyAnalysisClicked(object sender, RoutedEventArgs e)
    {
        var sb = new StringBuilder();

        var summaryText = AnalysisSummaryText?.Text;
        if (!string.IsNullOrWhiteSpace(summaryText))
        {
            sb.AppendLine("## Summary");
            sb.AppendLine(summaryText);
            sb.AppendLine();
        }

        if (AnalysisActionItems.Count > 0)
        {
            sb.AppendLine("## Action Items");
            foreach (var item in AnalysisActionItems)
                sb.AppendLine($"- [ ] {item}");
            sb.AppendLine();
        }

        if (AnalysisDecisions.Count > 0)
        {
            sb.AppendLine("## Decisions");
            foreach (var d in AnalysisDecisions)
                sb.AppendLine($"- {d}");
            sb.AppendLine();
        }

        if (AnalysisRisks.Count > 0)
        {
            sb.AppendLine("## Risks");
            foreach (var r in AnalysisRisks)
                sb.AppendLine($"- ⚠️ {r}");
            sb.AppendLine();
        }

        var text = sb.ToString().TrimEnd();
        if (string.IsNullOrWhiteSpace(text)) return;

        var dp = new Windows.ApplicationModel.DataTransfer.DataPackage();
        dp.SetText(text);
        Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(dp);
    }

    private void OnTranscriptionProgressChanged(object? sender, TranscriptionProgress progress)
    {
        // Both engines report the full audio duration in their progress events; capture it so the
        // final stats can show the realtime speed factor (audio duration / wall-clock elapsed).
        if (progress.TotalDuration is { TotalSeconds: > 0 })
            _lastTranscriptionAudioDuration = progress.TotalDuration;

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

    // ── Sessions UI ─────────────────────────────────────────────────────────

    /// <param name="query">Search query (null = show all).</param>
    /// <param name="resetPaging">True to reset to page 1; false to append next page.</param>
    private async Task LoadSessionsAsync(string? query = null, bool resetPaging = true)
    {
        try
        {
            if (resetPaging) _sessionPageCount = 1;

            // Get all matching sessions (semantic search already limits to 200)
            var all = await _semanticSearch.SearchAsync(query);

            // Apply state filter client-side
            IEnumerable<AudioRecorder.Core.Models.Session> filtered = _activeStateFilter.HasValue
                ? all.Where(s => s.State == _activeStateFilter.Value)
                : all;

            var filteredList = filtered.ToList();
            var pageLimit = SessionPageSize * _sessionPageCount;
            var page = filteredList.Take(pageLimit).ToList();
            var remaining = filteredList.Count - page.Count;

            _dispatcherQueue.TryEnqueue(() =>
            {
                Sessions.Clear();
                foreach (var s in page)
                    Sessions.Add(SessionViewModel.FromSession(s));

                if (LoadMoreButton != null)
                {
                    LoadMoreButton.Visibility = remaining > 0
                        ? Microsoft.UI.Xaml.Visibility.Visible
                        : Microsoft.UI.Xaml.Visibility.Collapsed;
                    if (LoadMoreText != null)
                        LoadMoreText.Text = $"Ещё {remaining} сессий";
                }
            });
        }
        catch (Exception ex)
        {
            AudioRecorder.Services.Logging.AppLogger.LogError($"LoadSessionsAsync failed: {ex.Message}");
        }
    }

    private void OnSessionSearchChanged(object sender, TextChangedEventArgs e)
    {
        // Debounce: wait 350ms after user stops typing
        _searchDebounceTimer?.Stop();
        _searchDebounceTimer = _dispatcherQueue.CreateTimer();
        _searchDebounceTimer.Interval = TimeSpan.FromMilliseconds(350);
        _searchDebounceTimer.IsRepeating = false;
        _searchDebounceTimer.Tick += (_, _) =>
        {
            var q = SessionSearchBox.Text;
            _ = LoadSessionsAsync(q);
        };
        _searchDebounceTimer.Start();
    }

    private void OnSessionFilterChanged(object sender, RoutedEventArgs e)
    {
        if (sender is not RadioButton rb) return;
        if (_semanticSearch == null) return; // fired during InitializeComponent before services are ready
        var tag = rb.Tag?.ToString() ?? string.Empty;
        _activeStateFilter = string.IsNullOrEmpty(tag)
            ? null
            : Enum.TryParse<SessionState>(tag, out var st) ? st : null;
        _ = LoadSessionsAsync(SessionSearchBox?.Text);
    }

    private void OnLoadMoreClicked(object sender, RoutedEventArgs e)
    {
        _sessionPageCount++;
        _ = LoadSessionsAsync(SessionSearchBox?.Text, resetPaging: false);
    }

    private async void OnSessionItemPointerPressed(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        if (sender is not Border { Tag: SessionViewModel vm }) return;

        try
        {
            var session = await _sessionStore.GetAsync(vm.Id);
            if (session is null)
            {
                AudioRecorder.Services.Logging.AppLogger.LogWarning($"Session {vm.Id} not found in DB");
                return;
            }

            // Switch to Transcript tab unconditionally so the user sees something
            RightPanelPivot.SelectedIndex = 0;

            if (session.TranscriptPath == null)
            {
                var msg = session.State == AudioRecorder.Core.Models.SessionState.Transcribed
                    ? "Путь к расшифровке не сохранён в базе данных. Возможно, сессия была создана до обновления."
                    : $"Расшифровка ещё не готова.\nСтатус: {session.State}";
                await new ContentDialog
                {
                    Title = "Нет расшифровки",
                    Content = msg,
                    CloseButtonText = "OK",
                    XamlRoot = XamlRoot
                }.ShowAsync();
                return;
            }

            if (!File.Exists(session.TranscriptPath))
            {
                AudioRecorder.Services.Logging.AppLogger.LogWarning($"Transcript file missing: {session.TranscriptPath}");
                await new ContentDialog
                {
                    Title = "Файл не найден",
                    Content = $"Файл расшифровки не найден:\n{session.TranscriptPath}",
                    CloseButtonText = "OK",
                    XamlRoot = XamlRoot
                }.ShowAsync();
                return;
            }

            _lastTranscriptionPath = session.TranscriptPath;
            await LoadTranscriptFromFileAsync(session);
            LoadAnalysisFromSession(session);
        }
        catch (Exception ex)
        {
            AudioRecorder.Services.Logging.AppLogger.LogError($"Failed to open session: {ex.Message}");
        }
    }

    private async void OnRenameButtonClicked(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: SessionViewModel vm }) return;

        var textBox = new TextBox { Text = vm.Title, MinWidth = 300, SelectionStart = vm.Title.Length };
        var dialog = new ContentDialog
        {
            Title = "Rename session",
            Content = textBox,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = XamlRoot,
        };

        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var newTitle = textBox.Text.Trim();
        if (string.IsNullOrWhiteSpace(newTitle) || newTitle == vm.Title) return;

        try
        {
            var session = await _sessionStore.GetAsync(vm.Id);
            if (session is null) return;
            session.Title = newTitle;
            await _sessionStore.UpdateAsync(session);
            _ = LoadSessionsAsync();
        }
        catch (Exception ex)
        {
            AudioRecorder.Services.Logging.AppLogger.LogError($"Rename session failed: {ex.Message}");
        }
    }

    private async void OnOutlineLinkClicked(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string url } && !string.IsNullOrEmpty(url))
        {
            try { await Windows.System.Launcher.LaunchUriAsync(new Uri(url)); }
            catch { }
        }
    }

    private async void OnPublishSessionToOutlineClicked(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: SessionViewModel vm }) return;
        await PublishSessionFromHistoryAsync(vm);
    }

    private async Task PublishSessionFromHistoryAsync(SessionViewModel vm)
    {
        if (!_outlineService.IsConfigured)
        {
            var dlg = new ContentDialog
            {
                Title = "Outline not configured",
                Content = "Open Settings → Integrations and enter your Outline URL and API key.",
                CloseButtonText = "OK",
                XamlRoot = XamlRoot
            };
            await dlg.ShowAsync();
            return;
        }

        var session = await _sessionStore.GetAsync(vm.Id);
        if (session is null) return;

        if (session.TranscriptPath is null || !File.Exists(session.TranscriptPath))
        {
            var dlg = new ContentDialog
            {
                Title = "No transcript",
                Content = "This session has no transcript file. Transcribe it first.",
                CloseButtonText = "OK",
                XamlRoot = XamlRoot
            };
            await dlg.ShowAsync();
            return;
        }

        // Show collection picker
        var collections = await _outlineService.GetCollectionsAsync();
        string? chosenCollectionId = null;

        if (collections.Success && collections.Collections.Count > 0)
        {
            var combo = new ComboBox { MinWidth = 300, Margin = new Thickness(0, 8, 0, 0) };
            foreach (var c in collections.Collections)
                combo.Items.Add(new ComboBoxItem { Content = c.Name, Tag = c.Id });
            combo.SelectedIndex = 0;

            var pickerContent = new StackPanel { Spacing = 4 };
            pickerContent.Children.Add(new TextBlock { Text = "Select collection:", FontSize = 12 });
            pickerContent.Children.Add(combo);

            var pickerDlg = new ContentDialog
            {
                Title = "Publish to Outline",
                Content = pickerContent,
                PrimaryButtonText = "Publish",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Primary,
                XamlRoot = XamlRoot
            };

            if (await pickerDlg.ShowAsync() != ContentDialogResult.Primary) return;
            chosenCollectionId = (combo.SelectedItem as ComboBoxItem)?.Tag?.ToString();
        }

        // Build markdown from transcript segments
        var segments = await ParseTranscriptFileAsync(session.TranscriptPath);
        var sb = new System.Text.StringBuilder();
        sb.AppendLine($"# {session.Title}");
        sb.AppendLine();
        sb.AppendLine($"*{session.RecordedAt:dd MMM yyyy, HH:mm}*");
        sb.AppendLine();

        string? lastSpeaker = null;
        foreach (var seg in segments)
        {
            if (seg.Speaker != lastSpeaker)
            {
                if (lastSpeaker != null) sb.AppendLine();
                sb.AppendLine($"**{seg.Speaker}**");
                lastSpeaker = seg.Speaker;
            }
            sb.AppendLine(seg.Text.Trim());
        }

        var markdown = sb.ToString();

        // Publish
        var progressDlg = new ContentDialog
        {
            Title = "Publishing…",
            Content = new ProgressRing { IsActive = true, Width = 40, Height = 40 },
            XamlRoot = XamlRoot
        };
        _ = progressDlg.ShowAsync();

        try
        {
            var result = await _outlineService.CreateDocumentAsync(
                session.Title, markdown, collectionId: chosenCollectionId);

            progressDlg.Hide();

            if (!result.Success)
            {
                var errDlg = new ContentDialog
                {
                    Title = "Publish failed",
                    Content = result.ErrorMessage ?? "Unknown error",
                    CloseButtonText = "OK",
                    XamlRoot = XamlRoot
                };
                await errDlg.ShowAsync();
                return;
            }

            session.OutlineDocumentId = result.DocumentId;
            session.OutlineDocumentUrl = result.DocumentUrl;
            session.State = SessionState.Exported;
            await _sessionStore.UpdateAsync(session);
            _ = LoadSessionsAsync();

            if (result.DocumentUrl != null)
            {
                var okDlg = new ContentDialog
                {
                    Title = "Published ✓",
                    Content = $"Document created in Outline.\n{result.DocumentUrl}",
                    PrimaryButtonText = "Open in Outline",
                    CloseButtonText = "Close",
                    DefaultButton = ContentDialogButton.Primary,
                    XamlRoot = XamlRoot
                };
                if (await okDlg.ShowAsync() == ContentDialogResult.Primary)
                    try { await Windows.System.Launcher.LaunchUriAsync(new Uri(result.DocumentUrl)); }
                    catch { }
            }
        }
        catch (Exception ex)
        {
            progressDlg.Hide();
            AudioRecorder.Services.Logging.AppLogger.LogError($"PublishSessionFromHistoryAsync: {ex.Message}");
        }
    }

    private async Task LoadTranscriptFromFileAsync(Core.Models.Session session)
    {
        try
        {
            if (session.TranscriptPath == null || !File.Exists(session.TranscriptPath))
                return;

            // Restore speaker names if available
            Dictionary<string, string> speakerMap = new();
            if (!string.IsNullOrEmpty(session.SpeakerNamesJson))
            {
                try
                {
                    speakerMap = System.Text.Json.JsonSerializer
                        .Deserialize<Dictionary<string, string>>(session.SpeakerNamesJson) ?? [];
                }
                catch { }
            }

            var segments = await ParseTranscriptFileAsync(session.TranscriptPath);
            await LoadTranscriptionToUI(segments, speakerMap);
        }
        catch (Exception ex)
        {
            AudioRecorder.Services.Logging.AppLogger.LogError($"LoadTranscriptFromFileAsync: {ex.Message}");
        }
    }

    /// <summary>
    /// Populates the Analysis pivot tab from session's LLM-structured data.
    /// </summary>
    private void LoadAnalysisFromSession(Core.Models.Session session)
    {
        AnalysisActionItems.Clear();
        AnalysisDecisions.Clear();
        AnalysisRisks.Clear();

        // Update summary TextBlock if it exists
        if (AnalysisSummaryText != null)
        {
            AnalysisSummaryText.Text = session.SummaryText ?? string.Empty;
            AnalysisSummarySection.Visibility = string.IsNullOrWhiteSpace(session.SummaryText)
                ? Microsoft.UI.Xaml.Visibility.Collapsed
                : Microsoft.UI.Xaml.Visibility.Visible;
        }

        if (!string.IsNullOrWhiteSpace(session.ActionItemsJson))
        {
            try
            {
                var items = System.Text.Json.JsonSerializer.Deserialize<List<string>>(session.ActionItemsJson) ?? [];
                foreach (var item in items) AnalysisActionItems.Add(item);
            }
            catch { }
        }

        if (!string.IsNullOrWhiteSpace(session.DecisionsJson))
        {
            try
            {
                var decisions = System.Text.Json.JsonSerializer.Deserialize<List<string>>(session.DecisionsJson) ?? [];
                foreach (var d in decisions) AnalysisDecisions.Add(d);
            }
            catch { }
        }

        // Show/hide Analysis tab sections
        if (AnalysisActionItemsSection != null)
            AnalysisActionItemsSection.Visibility = AnalysisActionItems.Count > 0
                ? Microsoft.UI.Xaml.Visibility.Visible
                : Microsoft.UI.Xaml.Visibility.Collapsed;
        if (AnalysisDecisionsSection != null)
            AnalysisDecisionsSection.Visibility = AnalysisDecisions.Count > 0
                ? Microsoft.UI.Xaml.Visibility.Visible
                : Microsoft.UI.Xaml.Visibility.Collapsed;
        if (AnalysisEmptyHint != null)
            AnalysisEmptyHint.Visibility =
                string.IsNullOrWhiteSpace(session.SummaryText)
                    && AnalysisActionItems.Count == 0
                    && AnalysisDecisions.Count == 0
                    ? Microsoft.UI.Xaml.Visibility.Visible
                    : Microsoft.UI.Xaml.Visibility.Collapsed;
    }

    /// <summary>
    /// Parses a transcript .txt file using the same segment format produced by
    /// WhisperTranscriptionService: [HH:MM:SS.mmm --> HH:MM:SS.mmm] [SPEAKER_XX] text
    /// </summary>
    private static async Task<List<TranscriptionSegment>> ParseTranscriptFileAsync(string txtPath)
    {
        var segments = new List<TranscriptionSegment>();
        var lines = await File.ReadAllLinesAsync(txtPath, System.Text.Encoding.UTF8);

        // Matches: [00:00:00.000 --> 00:01:23.456] [SPEAKER_00] : text
        var regex = new System.Text.RegularExpressions.Regex(
            @"^\s*\[(\d{2}:\d{2}(?::\d{2})?[.,]\d{3})\s*-->\s*(\d{2}:\d{2}(?::\d{2})?[.,]\d{3})\]\s*(?:\[([^\]]+)\])?\s*:?\s*(.*)$");

        TimeSpan curStart = TimeSpan.Zero, curEnd = TimeSpan.Zero;
        string curSpeaker = "SPEAKER_00";
        var curText = new System.Text.StringBuilder();
        bool hasSegment = false;

        void Flush()
        {
            var t = curText.ToString().Trim();
            if (hasSegment && !string.IsNullOrWhiteSpace(t))
                segments.Add(new TranscriptionSegment(curStart, curEnd, curSpeaker, t));
            curText.Clear();
            hasSegment = false;
        }

        foreach (var raw in lines)
        {
            var line = raw.Trim('\uFEFF', '\u200B');
            if (string.IsNullOrWhiteSpace(line)) continue;

            var m = regex.Match(line);
            if (m.Success)
            {
                Flush();
                curStart  = ParseTs(m.Groups[1].Value);
                curEnd    = ParseTs(m.Groups[2].Value);
                curSpeaker = m.Groups[3].Success ? m.Groups[3].Value : "SPEAKER_00";
                curText.Append(m.Groups[4].Value.Trim());
                hasSegment = true;
            }
            else if (hasSegment)
            {
                if (curText.Length > 0) curText.Append(' ');
                curText.Append(line.Trim());
            }
        }
        Flush();
        return segments;

        static TimeSpan ParseTs(string s)
        {
            s = s.Trim().Replace(',', '.');
            var parts = s.Split('.');
            if (parts.Length == 2 && parts[0].Count(c => c == ':') == 1)
                s = "00:" + s;
            return TimeSpan.TryParse(s, System.Globalization.CultureInfo.InvariantCulture, out var ts)
                ? ts : TimeSpan.Zero;
        }
    }

    // ── Outline integration ──────────────────────────────────────────────────

    private IOutlineService CreateOutlineService()
    {
        var settings = new OutlineSettings
        {
            BaseUrl = _settingsService.LoadOutlineBaseUrl(),
            ApiToken = _settingsService.LoadOutlineApiToken(),
            DefaultCollectionId = _settingsService.LoadOutlineDefaultCollectionId(),
        };
        return new OutlineService(settings);
    }

    private async Task PublishToOutlineAsync(
        Guid? sessionId,
        string audioPath,
        string markdownPath,
        CancellationToken ct)
    {
        try
        {
            var title = Path.GetFileNameWithoutExtension(audioPath);
            var markdownText = await File.ReadAllTextAsync(markdownPath, ct);

            var outlineResult = await _outlineService.CreateDocumentAsync(title, markdownText, ct: ct);
            if (!outlineResult.Success)
            {
                AudioRecorder.Services.Logging.AppLogger.LogWarning(
                    $"Outline publish failed: {outlineResult.ErrorMessage}");
                return;
            }

            AudioRecorder.Services.Logging.AppLogger.LogInfo(
                $"Published to Outline: {outlineResult.DocumentUrl ?? outlineResult.DocumentId}");

            // Persist the Outline document ID and URL on the session
            if (sessionId is { } sid && outlineResult.DocumentId != null)
            {
                var session = await _sessionStore.GetAsync(sid);
                if (session != null)
                {
                    session.OutlineDocumentId = outlineResult.DocumentId;
                    session.OutlineDocumentUrl = outlineResult.DocumentUrl;
                    session.State = SessionState.Exported;
                    await _sessionStore.UpdateAsync(session);
                    _ = LoadSessionsAsync();
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            AudioRecorder.Services.Logging.AppLogger.LogError(
                $"PublishToOutlineAsync exception: {ex.Message}");
        }
    }

    // ── Session persistence ─────────────────────────────────────────────────

    /// <summary>
    /// Creates a session record for a file that was imported (not recorded by Contora).
    /// Called at transcription start so the resulting transcript is linked to a real session.
    /// </summary>
    private async Task CreateImportedFileSessionAsync(string audioPath)
    {
        try
        {
            var session = new Session
            {
                Title = Path.GetFileNameWithoutExtension(audioPath),
                RecordedAt = DateTime.Now,
                DurationSeconds = 0, // unknown until transcription completes
                AudioPath = audioPath,
                State = SessionState.Recorded,
            };
            await _sessionStore.CreateAsync(session);
            _currentSessionId = session.Id;
            AudioRecorder.Services.Logging.AppLogger.LogInfo($"Import session created: {session.Id}");
            _ = LoadSessionsAsync();
        }
        catch (Exception ex)
        {
            AudioRecorder.Services.Logging.AppLogger.LogError($"Failed to create import session: {ex.Message}");
        }
    }

    private async Task SaveNewSessionAsync(string audioPath, TimeSpan duration)
    {
        try
        {
            var fileName = Path.GetFileNameWithoutExtension(audioPath);
            var session = new Session
            {
                Title = fileName,
                RecordedAt = DateTime.Now,
                DurationSeconds = duration.TotalSeconds,
                AudioPath = audioPath,
                State = SessionState.Recorded,
            };
            await _sessionStore.CreateAsync(session);
            _currentSessionId = session.Id;
            AudioRecorder.Services.Logging.AppLogger.LogInfo($"Session saved: {session.Id}");
            _ = LoadSessionsAsync();
        }
        catch (Exception ex)
        {
            AudioRecorder.Services.Logging.AppLogger.LogError($"Failed to save session: {ex.Message}");
        }
    }

    private async Task UpdateSessionAfterTranscriptionAsync(
        Guid? sessionId,
        string? transcriptPath,
        IReadOnlyList<TranscriptionSegment> segments,
        string? generatedTitle = null,
        AudioRecorder.Core.Models.StructuredSessionOutput? structuredOutput = null)
    {
        if (sessionId is not { } sid) return;
        try
        {
            var session = await _sessionStore.GetAsync(sid);
            if (session is null) return;

            var previewText = string.Join(" ", segments.Take(5).Select(s => s.Text)).Trim();
            if (previewText.Length > 300) previewText = previewText[..300];

            session.TranscriptPath = transcriptPath;
            session.State = SessionState.Transcribed;
            session.PreviewText = previewText;

            // Title: prefer structured output title, then generatedTitle
            var resolvedTitle = structuredOutput?.Title ?? generatedTitle;
            if (!string.IsNullOrWhiteSpace(resolvedTitle))
                session.Title = resolvedTitle;

            // Save structured LLM output
            if (structuredOutput != null)
            {
                session.SummaryText = structuredOutput.Summary;
                if (structuredOutput.ActionItems.Count > 0)
                    session.ActionItemsJson = System.Text.Json.JsonSerializer.Serialize(structuredOutput.ActionItems);
                if (structuredOutput.Decisions.Count > 0)
                    session.DecisionsJson = System.Text.Json.JsonSerializer.Serialize(structuredOutput.Decisions);
            }

            // Build speaker names JSON from current UI map
            if (_speakerNameMap.Count > 0)
            {
                session.SpeakerNamesJson = System.Text.Json.JsonSerializer.Serialize(_speakerNameMap);
            }

            await _sessionStore.UpdateAsync(session);
            _ = LoadSessionsAsync();

            // Fire-and-forget: generate and store embedding for semantic search
            _ = IndexSessionEmbeddingAsync(sid, segments);
        }
        catch (Exception ex)
        {
            AudioRecorder.Services.Logging.AppLogger.LogError($"Failed to update session after transcription: {ex.Message}");
        }
    }

    private async Task IndexSessionEmbeddingAsync(Guid sessionId, IReadOnlyList<TranscriptionSegment> segments)
    {
        try
        {
            // Use full transcript text for rich semantic representation
            var fullText = string.Join(" ", segments.Select(s => s.Text)).Trim();
            if (string.IsNullOrWhiteSpace(fullText)) return;

            var embedding = await _embeddingService.EmbedAsync(fullText);
            if (embedding != null)
            {
                await _sessionStore.StoreEmbeddingAsync(sessionId, embedding);
                AudioRecorder.Services.Logging.AppLogger.LogInfo(
                    $"Embedding stored for session {sessionId} ({embedding.Length}-dim)");
            }
        }
        catch (Exception ex)
        {
            AudioRecorder.Services.Logging.AppLogger.LogWarning($"IndexSessionEmbeddingAsync failed: {ex.Message}");
        }
    }

    // ── Formatting helpers ──────────────────────────────────────────────────

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







