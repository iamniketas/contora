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

    // Silero VAD model for whisper.cpp — used to skip non-speech so the ASR doesn't hallucinate
    // ("Продолжение следует…", etc.) over silence/music. Tiny (~0.9 MB), auto-downloaded on demand.
    public const string VadModelFileName = "ggml-silero-v5.1.2.bin";
    public const string VadModelUrl =
        "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin";

    public static string GetVadModelPath() => Path.Combine(GetGgmlModelsRoot(), VadModelFileName);

    public static bool IsGgmlModelInstalled(string modelsRoot, string modelName)
        => File.Exists(GetGgmlModelPath(modelsRoot, modelName));

    /// <summary>
    /// Short model name from a ggml file path, e.g. "…/ggml-large-v3.bin" → "large-v3".
    /// Returns null if the file isn't a ggml-*.bin.
    /// </summary>
    public static string? ModelNameFromFile(string path)
    {
        var fileName = Path.GetFileName(path);
        if (!fileName.StartsWith(FilePrefix, StringComparison.OrdinalIgnoreCase) ||
            !fileName.EndsWith(FileSuffix, StringComparison.OrdinalIgnoreCase))
            return null;
        return fileName[FilePrefix.Length..^FileSuffix.Length];
    }

    /// <summary>
    /// Enumerates GGML models usable by the Whisper.net engine: every ggml-*.bin in the shared
    /// root plus any GGML model registered in Dictator's store. Returns distinct short names.
    /// </summary>
    public static IReadOnlyList<string> EnumerateInstalledModelNames(DictatorSharedStoreService? dictatorStore)
    {
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        var root = GetGgmlModelsRoot();
        if (Directory.Exists(root))
        {
            foreach (var file in Directory.EnumerateFiles(root, $"{FilePrefix}*{FileSuffix}"))
            {
                var name = ModelNameFromFile(file);
                if (name is not null) names.Add(name);
            }
        }

        var dictatorModels = dictatorStore?.GetCached()?.InstalledModels;
        if (dictatorModels is not null)
        {
            foreach (var m in dictatorModels)
            {
                if (!DictatorSharedStoreService.IsGgmlModel(m) || m.Health != "ok") continue;
                if (!File.Exists(m.DirectoryPath)) continue;
                var name = ModelNameFromFile(m.DirectoryPath);
                if (name is not null) names.Add(name);
            }
        }

        return names.OrderBy(n => n, StringComparer.OrdinalIgnoreCase).ToList();
    }

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
