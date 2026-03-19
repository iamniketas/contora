namespace AudioRecorder.Core.Services;

public interface ISettingsService
{
    void SaveSelectedSourceIds(IEnumerable<string> sourceIds);

    IReadOnlyList<string> LoadSelectedSourceIds();

    void SaveOutputFolder(string folderPath);

    string? LoadOutputFolder();

    void SaveTranscriptionMode(string mode);

    string LoadTranscriptionMode();

    void SaveWhisperModel(string modelName);

    string LoadWhisperModel();

    /// <summary>Device mode for transcription: "auto", "cuda", or "cpu".</summary>
    void SaveDeviceMode(string mode);

    string LoadDeviceMode();

    /// <summary>Custom root directory where faster-whisper-xxl is installed. Null = default canonical path.</summary>
    void SaveInstallRootPath(string path);

    string? LoadInstallRootPath();

    // ── Outline integration ──────────────────────────────────────────────────

    void SaveOutlineBaseUrl(string url);
    string? LoadOutlineBaseUrl();

    void SaveOutlineApiToken(string token);
    string? LoadOutlineApiToken();

    void SaveOutlineDefaultCollectionId(string collectionId);
    string? LoadOutlineDefaultCollectionId();

    // ── Global Hotkey ────────────────────────────────────────────────────────

    /// <summary>Human-readable hotkey string, e.g. "Win+Shift+R".</summary>
    void SaveGlobalHotkey(string hotkeyString);
    string LoadGlobalHotkey();
}
