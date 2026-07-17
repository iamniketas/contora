using AudioRecorder.Core.Services;
using System.Text.Json;

namespace AudioRecorder.Services.Settings;

public class LocalSettingsService : ISettingsService
{
    private readonly string _settingsFilePath;

    public LocalSettingsService()
    {
        var appDataPath = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var appFolder = Path.Combine(appDataPath, "Contora");
        var legacyAppFolder = Path.Combine(appDataPath, "AudioRecorder");
        Directory.CreateDirectory(appFolder);
        _settingsFilePath = Path.Combine(appFolder, "settings.json");

        var legacySettingsPath = Path.Combine(legacyAppFolder, "settings.json");
        if (!File.Exists(_settingsFilePath) && File.Exists(legacySettingsPath))
        {
            File.Copy(legacySettingsPath, _settingsFilePath);
        }
    }

    public void SaveSelectedSourceIds(IEnumerable<string> sourceIds)
    {
        try
        {
            var settings = LoadSettings();
            settings.SelectedSourceIds = sourceIds.ToList();
            SaveSettings(settings);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to save settings: {ex.Message}");
        }
    }

    public IReadOnlyList<string> LoadSelectedSourceIds()
    {
        try
        {
            var settings = LoadSettings();
            return settings.SelectedSourceIds;
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to load settings: {ex.Message}");
            return new List<string>();
        }
    }

    public void SaveOutputFolder(string folderPath)
    {
        try
        {
            var settings = LoadSettings();
            settings.OutputFolder = folderPath;
            SaveSettings(settings);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to save output folder: {ex.Message}");
        }
    }

    public string? LoadOutputFolder()
    {
        try
        {
            var settings = LoadSettings();
            return settings.OutputFolder;
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to load output folder: {ex.Message}");
            return null;
        }
    }

    public void SaveTranscriptionMode(string mode)
    {
        try
        {
            var normalized = string.Equals(mode, "light", StringComparison.OrdinalIgnoreCase)
                ? "light"
                : "quality";

            var settings = LoadSettings();
            settings.TranscriptionMode = normalized;
            SaveSettings(settings);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to save transcription mode: {ex.Message}");
        }
    }

    public string LoadTranscriptionMode()
    {
        try
        {
            var settings = LoadSettings();
            return string.Equals(settings.TranscriptionMode, "light", StringComparison.OrdinalIgnoreCase)
                ? "light"
                : "quality";
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to load transcription mode: {ex.Message}");
            return "quality";
        }
    }

    public void SaveWhisperModel(string modelName)
    {
        try
        {
            var settings = LoadSettings();
            settings.WhisperModel = NormalizeWhisperModel(modelName);
            SaveSettings(settings);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to save whisper model: {ex.Message}");
        }
    }

    public string LoadWhisperModel()
    {
        try
        {
            var settings = LoadSettings();
            return NormalizeWhisperModel(settings.WhisperModel);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to load whisper model: {ex.Message}");
            return "large-v2";
        }
    }

    private AppSettings LoadSettings()
    {
        if (!File.Exists(_settingsFilePath))
            return new AppSettings();

        var json = File.ReadAllText(_settingsFilePath);
        return JsonSerializer.Deserialize<AppSettings>(json) ?? new AppSettings();
    }

    private void SaveSettings(AppSettings settings)
    {
        var json = JsonSerializer.Serialize(settings, new JsonSerializerOptions
        {
            WriteIndented = true
        });
        File.WriteAllText(_settingsFilePath, json);
    }

    public void SaveDeviceMode(string mode)
    {
        try
        {
            var normalized = mode?.Trim().ToLowerInvariant() switch
            {
                "cpu" => "cpu",
                "cuda" => "cuda",
                _ => "auto"
            };
            var settings = LoadSettings();
            settings.DeviceMode = normalized;
            SaveSettings(settings);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to save device mode: {ex.Message}");
        }
    }

    public string LoadDeviceMode()
    {
        try
        {
            var settings = LoadSettings();
            return settings.DeviceMode?.Trim().ToLowerInvariant() switch
            {
                "cpu" => "cpu",
                "cuda" => "cuda",
                _ => "auto"
            };
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to load device mode: {ex.Message}");
            return "auto";
        }
    }

    public void SaveInstallRootPath(string path)
    {
        try
        {
            var settings = LoadSettings();
            settings.InstallRootPath = path;
            SaveSettings(settings);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to save install root path: {ex.Message}");
        }
    }

    public string? LoadInstallRootPath()
    {
        try
        {
            var settings = LoadSettings();
            return string.IsNullOrWhiteSpace(settings.InstallRootPath) ? null : settings.InstallRootPath;
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to load install root path: {ex.Message}");
            return null;
        }
    }

    public void SaveTranscriptionEngine(string engine)
    {
        try
        {
            var normalized = string.Equals(engine, "whisper-net", StringComparison.OrdinalIgnoreCase)
                ? "whisper-net"
                : "legacy-fwx";
            var settings = LoadSettings();
            settings.TranscriptionEngine = normalized;
            SaveSettings(settings);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to save transcription engine: {ex.Message}");
        }
    }

    public string LoadTranscriptionEngine()
    {
        try
        {
            var settings = LoadSettings();
            return string.Equals(settings.TranscriptionEngine, "whisper-net", StringComparison.OrdinalIgnoreCase)
                ? "whisper-net"
                : "legacy-fwx";
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to load transcription engine: {ex.Message}");
            return "legacy-fwx";
        }
    }

    public IReadOnlyList<AudioRecorder.Core.Models.SpeakerProfile> LoadSpeakerProfiles()
    {
        try
        {
            return LoadSettings().SpeakerProfiles
                .Where(p => !string.IsNullOrWhiteSpace(p.Name))
                .GroupBy(p => p.Name.Trim(), StringComparer.OrdinalIgnoreCase)
                .Select(g => g.First() with { Name = g.Key })
                .OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase)
                .ToList();
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to load speaker profiles: {ex.Message}");
            return [];
        }
    }

    public void SaveSpeakerProfiles(IEnumerable<AudioRecorder.Core.Models.SpeakerProfile> profiles)
    {
        try
        {
            var settings = LoadSettings();
            settings.SpeakerProfiles = profiles
                .Where(p => !string.IsNullOrWhiteSpace(p.Name))
                .Select(p => p with { Name = p.Name.Trim() })
                .GroupBy(p => p.Name, StringComparer.OrdinalIgnoreCase)
                .Select(g => g.First())
                .OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase)
                .ToList();
            SaveSettings(settings);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Failed to save speaker profiles: {ex.Message}");
        }
    }

    public void SaveOutlineBaseUrl(string url)
    {
        var settings = LoadSettings();
        settings.OutlineBaseUrl = url?.Trim();
        SaveSettings(settings);
    }

    public string? LoadOutlineBaseUrl()
    {
        var settings = LoadSettings();
        return string.IsNullOrWhiteSpace(settings.OutlineBaseUrl) ? null : settings.OutlineBaseUrl;
    }

    public void SaveOutlineApiToken(string token)
    {
        var settings = LoadSettings();
        settings.OutlineApiToken = token?.Trim();
        SaveSettings(settings);
    }

    public string? LoadOutlineApiToken()
    {
        var settings = LoadSettings();
        return string.IsNullOrWhiteSpace(settings.OutlineApiToken) ? null : settings.OutlineApiToken;
    }

    public void SaveOutlineDefaultCollectionId(string collectionId)
    {
        var settings = LoadSettings();
        settings.OutlineDefaultCollectionId = collectionId?.Trim();
        SaveSettings(settings);
    }

    public string? LoadOutlineDefaultCollectionId()
    {
        var settings = LoadSettings();
        return string.IsNullOrWhiteSpace(settings.OutlineDefaultCollectionId) ? null : settings.OutlineDefaultCollectionId;
    }

    public void SaveGlobalHotkey(string hotkeyString)
    {
        var settings = LoadSettings();
        settings.GlobalHotkey = string.IsNullOrWhiteSpace(hotkeyString) ? "Win+Shift+R" : hotkeyString.Trim();
        SaveSettings(settings);
    }

    public string LoadGlobalHotkey()
    {
        var settings = LoadSettings();
        return string.IsNullOrWhiteSpace(settings.GlobalHotkey) ? "Win+Shift+R" : settings.GlobalHotkey;
    }

    private class AppSettings
    {
        public List<string> SelectedSourceIds { get; set; } = new();
        public string? OutputFolder { get; set; }
        public string TranscriptionMode { get; set; } = "quality";
        public string WhisperModel { get; set; } = "large-v2";
        public string DeviceMode { get; set; } = "auto";
        public string? InstallRootPath { get; set; }
        public string TranscriptionEngine { get; set; } = "whisper-net";
        public List<AudioRecorder.Core.Models.SpeakerProfile> SpeakerProfiles { get; set; } = [];
        public string? OutlineBaseUrl { get; set; }
        public string? OutlineApiToken { get; set; }
        public string? OutlineDefaultCollectionId { get; set; }
        public string GlobalHotkey { get; set; } = "Win+Shift+R";
    }

    private static string NormalizeWhisperModel(string? modelName)
    {
        // Accept any non-empty model name. A hard-coded whitelist here previously collapsed every
        // unlisted name (large-v3, large-v3-turbo, base, and all GGML models) to "large-v2",
        // which silently broke model selection for the Whisper.net engine.
        var name = modelName?.Trim().ToLowerInvariant();
        return string.IsNullOrWhiteSpace(name) ? "large-v2" : name;
    }
}
