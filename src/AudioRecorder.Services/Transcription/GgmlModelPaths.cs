namespace AudioRecorder.Services.Transcription;

/// <summary>
/// Path resolution for GGML (whisper.cpp) models used by Whisper.net.
/// Unlike faster-whisper's CTranslate2 layout (4 files per model directory),
/// GGML models are a single flat file: ggml-{name}.bin.
/// </summary>
public static class GgmlModelPaths
{
    private const string FilePrefix = "ggml-";
    private const string FileSuffix = ".bin";

    /// <summary>
    /// Root folder to look for/store ggml-*.bin files. Reuses the same shared-root discovery
    /// as faster-whisper (own SharedWhisperModels config -> Dictator's AudioModels config/folder -> fallback),
    /// so Contora and Dictator can share one copy of a model instead of downloading twice.
    /// </summary>
    public static string GetGgmlModelsRoot() => WhisperPaths.GetSharedModelsRootOrDefault();

    public static string GetFileName(string modelName) => $"{FilePrefix}{modelName}{FileSuffix}";

    public static string GetGgmlModelPath(string modelsRoot, string modelName)
        => Path.Combine(modelsRoot, GetFileName(modelName));

    public static bool IsGgmlModelInstalled(string modelsRoot, string modelName)
        => File.Exists(GetGgmlModelPath(modelsRoot, modelName));

    /// <summary>
    /// Resolves the path to a GGML model file, preferring an existing Dictator installation
    /// (matched by file name, not by Dictator's internal model id, since that naming scheme
    /// isn't guaranteed to match Contora's model name) over Contora's own shared-root copy.
    /// Returns null if the model isn't installed anywhere.
    /// </summary>
    public static string? ResolveInstalledModelPath(string modelName, DictatorSharedStoreService? dictatorStore)
    {
        var fileName = GetFileName(modelName);

        var dictatorModels = dictatorStore?.GetCached()?.InstalledModels;
        if (dictatorModels is not null)
        {
            var dictatorMatch = dictatorModels.FirstOrDefault(m =>
                DictatorSharedStoreService.IsGgmlModel(m) &&
                m.Health == "ok" &&
                string.Equals(Path.GetFileName(m.DirectoryPath), fileName, StringComparison.OrdinalIgnoreCase));

            if (dictatorMatch is not null && File.Exists(dictatorMatch.DirectoryPath))
                return dictatorMatch.DirectoryPath;
        }

        var ownRoot = GetGgmlModelsRoot();
        var ownPath = GetGgmlModelPath(ownRoot, modelName);
        return File.Exists(ownPath) ? ownPath : null;
    }
}
