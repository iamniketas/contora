namespace AudioRecorder.Services.Transcription;

public static class WhisperPaths
{
    public const string EnvWhisperExe = "CONTORA_WHISPER_EXE";
    public const string EnvWhisperRoot = "CONTORA_WHISPER_ROOT";
    public const string EnvWhisperModelsRoot = "CONTORA_WHISPER_MODELS_DIR";
    public const string EnvWhisperModelLargeV2 = "CONTORA_WHISPER_MODEL_LARGE_V2_DIR";
    public const string EnvSharedModelsRoot = "CONTORA_SHARED_MODELS_DIR";

    private const string LegacyEnvWhisperExe = "AUDIORECORDER_WHISPER_EXE";
    private const string LegacyEnvWhisperRoot = "AUDIORECORDER_WHISPER_ROOT";
    private const string LegacyEnvWhisperModelsRoot = "AUDIORECORDER_WHISPER_MODELS_DIR";
    private const string LegacyEnvWhisperModelLargeV2 = "AUDIORECORDER_WHISPER_MODEL_LARGE_V2_DIR";

    private const string RuntimeFolderName = "faster-whisper-xxl";
    private const string ModelDirPrefix = "faster-whisper-";
    private static readonly string[] RequiredModelFiles =
    [
        "config.json",
        "model.bin",
        "tokenizer.json",
        "vocabulary.txt"
    ];

    public static string GetDefaultWhisperPath()
    {
        var envPath = GetEnvironmentVariableWithLegacy(EnvWhisperExe, LegacyEnvWhisperExe);
        if (!string.IsNullOrWhiteSpace(envPath))
            return envPath;

        var canonicalPath = GetCanonicalWhisperPath();
        if (File.Exists(canonicalPath))
            return canonicalPath;

        var legacyCanonicalPath = GetLegacyCanonicalWhisperPath();
        if (File.Exists(legacyCanonicalPath))
            return legacyCanonicalPath;

        var exeDir = AppContext.BaseDirectory;
        var toolsPath = Path.Combine(exeDir, "tools", "faster-whisper-xxl", "faster-whisper-xxl.exe");
        if (File.Exists(toolsPath))
            return toolsPath;

        var projectRoot = FindProjectRoot(exeDir);
        if (projectRoot != null)
        {
            toolsPath = Path.Combine(projectRoot, "tools", "faster-whisper-xxl", "faster-whisper-xxl.exe");
            if (File.Exists(toolsPath))
                return toolsPath;
        }

        // 3) Fallback: canonical runtime path in LocalAppData.
        return canonicalPath;
    }

    public static string GetCanonicalRuntimeRoot()
    {
        var appDataPath = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(appDataPath, "Contora", "runtime", RuntimeFolderName);
    }

    public static string GetCanonicalWhisperPath()
    {
        return Path.Combine(GetCanonicalRuntimeRoot(), "faster-whisper-xxl.exe");
    }

    public static string GetModelsRoot(string whisperPath)
    {
        var explicitModelsRoot = GetEnvironmentVariableWithLegacy(EnvWhisperModelsRoot, LegacyEnvWhisperModelsRoot);
        if (!string.IsNullOrWhiteSpace(explicitModelsRoot))
            return explicitModelsRoot;

        var sharedRoot = GetSharedModelsRoot();
        if (!string.IsNullOrWhiteSpace(sharedRoot))
            return sharedRoot;

        var rootDir = Path.GetDirectoryName(whisperPath) ?? AppContext.BaseDirectory;
        return Path.Combine(rootDir, "_models");
    }

    public static string GetModelDirectory(string whisperPath, string modelName)
    {
        return Path.Combine(GetModelsRoot(whisperPath), $"{ModelDirPrefix}{modelName}");
    }

    public static bool IsModelInstalled(string whisperPath, string modelName)
    {
        var modelDir = GetModelDirectory(whisperPath, modelName);
        if (!Directory.Exists(modelDir))
        {
            var fallbackInRuntime = Path.Combine(Path.GetDirectoryName(whisperPath) ?? AppContext.BaseDirectory, "_models", $"{ModelDirPrefix}{modelName}");
            if (!Directory.Exists(fallbackInRuntime))
                return false;
            modelDir = fallbackInRuntime;
        }

        foreach (var file in RequiredModelFiles)
        {
            if (!File.Exists(Path.Combine(modelDir, file)))
                return false;
        }

        return true;
    }

    public static void RegisterEnvironmentVariables(string whisperPath, string modelName = "large-v2")
    {
        var rootDir = Path.GetDirectoryName(whisperPath) ?? string.Empty;
        var modelsDir = GetModelsRoot(whisperPath);
        var modelDir = GetModelDirectory(whisperPath, modelName);

        SetEnvBothScopes(EnvWhisperExe, whisperPath);
        SetEnvBothScopes(EnvWhisperRoot, rootDir);
        SetEnvBothScopes(EnvWhisperModelsRoot, modelsDir);
        SetEnvBothScopes(EnvWhisperModelLargeV2, modelDir);
        SetEnvBothScopes(LegacyEnvWhisperExe, whisperPath);
        SetEnvBothScopes(LegacyEnvWhisperRoot, rootDir);
        SetEnvBothScopes(LegacyEnvWhisperModelsRoot, modelsDir);
        SetEnvBothScopes(LegacyEnvWhisperModelLargeV2, modelDir);
    }

    private static void SetEnvBothScopes(string key, string value)
    {
        try
        {
            Environment.SetEnvironmentVariable(key, value, EnvironmentVariableTarget.Process);
            Environment.SetEnvironmentVariable(key, value, EnvironmentVariableTarget.User);
        }
        catch
        {
            // Ignore when user-level env vars are not writable.
        }
    }

    private static string? FindProjectRoot(string startDir)
    {
        var dir = new DirectoryInfo(startDir);
        while (dir != null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "Contora.sln")) ||
                File.Exists(Path.Combine(dir.FullName, "AudioRecorder.sln")))
                return dir.FullName;
            dir = dir.Parent;
        }

        return null;
    }

    private static string GetLegacyCanonicalWhisperPath()
    {
        var appDataPath = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(appDataPath, "AudioRecorder", "runtime", RuntimeFolderName, "faster-whisper-xxl.exe");
    }

    private static string? GetEnvironmentVariableWithLegacy(string key, string legacyKey)
    {
        var current = Environment.GetEnvironmentVariable(key);
        if (!string.IsNullOrWhiteSpace(current))
            return current;

        return Environment.GetEnvironmentVariable(legacyKey);
    }

    private static string GetSharedModelsRoot()
    {
        var explicitShared = Environment.GetEnvironmentVariable(EnvSharedModelsRoot);
        if (!string.IsNullOrWhiteSpace(explicitShared))
            return explicitShared;

        // Read from shared config if available
        var configPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "SharedWhisperModels", "config.json");
        if (File.Exists(configPath))
        {
            try
            {
                var json = File.ReadAllText(configPath);
                using var doc = System.Text.Json.JsonDocument.Parse(json);
                if (doc.RootElement.TryGetProperty("modelsRootPath", out var modelsRootEl))
                {
                    var modelsRoot = modelsRootEl.GetString();
                    if (!string.IsNullOrWhiteSpace(modelsRoot) && Directory.Exists(modelsRoot))
                        return modelsRoot;
                }
            }
            catch
            {
                // Ignore config read errors
            }
        }

        var dictatorModelPath = Environment.GetEnvironmentVariable("DICTATOR_WHISPER_MODEL_PATH");
        if (!string.IsNullOrWhiteSpace(dictatorModelPath))
        {
            var modelPath = dictatorModelPath.Trim();
            if (Directory.Exists(modelPath))
            {
                return Path.GetDirectoryName(modelPath) ?? modelPath;
            }
        }

        var probes = new[]
        {
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "dictator", "models")),
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "project-dictator", "models"))
        };

        foreach (var probe in probes)
        {
            if (Directory.Exists(probe))
                return probe;
        }

        var appDataPath = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(appDataPath, "SharedWhisperModels");
    }
}
