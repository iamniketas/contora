using System.Text.Json;
using System.Text.Json.Serialization;

namespace AudioRecorder.Services.Transcription;

// ─── JSON models (mirrors shared_model_store.v1.json schema) ───

public record DictatorInstalledRuntime(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("display_name")] string DisplayName,
    [property: JsonPropertyName("kind")] string Kind,
    [property: JsonPropertyName("entry_path")] string EntryPath,
    [property: JsonPropertyName("disk_usage_bytes")] long DiskUsageBytes);

public record DictatorInstalledModel(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("runtime_id")] string RuntimeId,
    [property: JsonPropertyName("directory_path")] string DirectoryPath,
    [property: JsonPropertyName("size_bytes")] long? SizeBytes,
    [property: JsonPropertyName("is_default")] bool? IsDefault,
    [property: JsonPropertyName("health")] string Health,
    [property: JsonPropertyName("required_files")] List<string>? RequiredFiles = null);

public record DictatorModelStore(
    [property: JsonPropertyName("schema_version")] string SchemaVersion,
    [property: JsonPropertyName("active_model_id")] string? ActiveModelId,
    [property: JsonPropertyName("active_runtime_id")] string? ActiveRuntimeId,
    [property: JsonPropertyName("models_root_path")] string ModelsRootPath,
    [property: JsonPropertyName("installed_runtimes")] List<DictatorInstalledRuntime>? InstalledRuntimes,
    [property: JsonPropertyName("installed_models")] List<DictatorInstalledModel>? InstalledModels);

// ─── Service ───

public sealed class DictatorSharedStoreService
{
    private static readonly string StorePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "AudioModels", "shared_model_store.v1.json");

    private static readonly string AudioModelsRoot = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "AudioModels");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        AllowTrailingCommas = true,
    };

    private DictatorModelStore? _cached;

    public async Task<DictatorModelStore?> LoadStoreAsync()
    {
        if (!File.Exists(StorePath)) return null;
        try
        {
            var json = await File.ReadAllTextAsync(StorePath);
            _cached = JsonSerializer.Deserialize<DictatorModelStore>(json, JsonOptions);
            return _cached;
        }
        catch
        {
            return null;
        }
    }

    public DictatorModelStore? GetCached() => _cached;

    /// <summary>Returns the model entry if it's installed and healthy.</summary>
    public DictatorInstalledModel? GetInstalledModel(string modelId)
    {
        return _cached?.InstalledModels?
            .FirstOrDefault(m => string.Equals(m.Id, modelId, StringComparison.OrdinalIgnoreCase)
                                 && m.Health == "ok");
    }

    /// <summary>Returns all models that use the shared Python ASR server (NeMo / transformers).</summary>
    public IReadOnlyList<DictatorInstalledModel> GetServerModels()
    {
        return _cached?.InstalledModels?
            .Where(m => m.RuntimeId == "server_python_asr" && m.Health == "ok")
            .ToList()
            ?? (IReadOnlyList<DictatorInstalledModel>)[];
    }

    /// <summary>Returns true if the model should be routed to the Python ASR server.</summary>
    public bool IsServerModel(string modelId)
    {
        var model = GetInstalledModel(modelId);
        return model?.RuntimeId == "server_python_asr";
    }

    /// <summary>Returns path to python.exe inside Dictator's shared Python venv, or null if not installed.</summary>
    public string? GetPythonVenvPath()
    {
        var venvPython = Path.Combine(AudioModelsRoot, "runtimes", "python-asr", "venv", "Scripts", "python.exe");
        return File.Exists(venvPython) ? venvPython : null;
    }

    public bool IsPythonVenvAvailable() => GetPythonVenvPath() != null;

    /// <summary>
    /// Returns the runtime entry for 'server_python_asr', or null.
    /// entry_path points to the python-asr directory.
    /// </summary>
    public DictatorInstalledRuntime? GetPythonAsrRuntime()
    {
        return _cached?.InstalledRuntimes?
            .FirstOrDefault(r => r.Id == "server_python_asr");
    }

    /// <summary>Returns human-readable runtime kind label for display.</summary>
    public static string GetModelRuntimeLabel(DictatorInstalledModel model)
    {
        return model.RuntimeId switch
        {
            "embedded_whisper_rs" => "Dictator (GGML)",
            "server_python_asr"   => "Dictator (Python)",
            _                     => "Dictator"
        };
    }

    /// <summary>Returns true if the model is a GGML embedded model (requires whisper-rs, not usable in Contora).</summary>
    public static bool IsGgmlModel(DictatorInstalledModel model)
        => model.RuntimeId == "embedded_whisper_rs";
}
