using System.Text.Json.Serialization;

namespace AudioRecorder.Services.Settings;

public sealed class SharedModelConfig
{
    [JsonPropertyName("installedRuntimes")]
    public List<InstalledRuntime> InstalledRuntimes { get; set; } = [];

    [JsonPropertyName("installedModels")]
    public List<InstalledModel> InstalledModels { get; set; } = [];

    [JsonPropertyName("activeRuntimeId")]
    public string? ActiveRuntimeId { get; set; }

    [JsonPropertyName("activeModelName")]
    public string? ActiveModelName { get; set; }

    [JsonPropertyName("modelsRootPath")]
    public string? ModelsRootPath { get; set; }
}

public sealed class InstalledRuntime
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = string.Empty;

    [JsonPropertyName("displayName")]
    public string DisplayName { get; set; } = string.Empty;

    [JsonPropertyName("exePath")]
    public string ExePath { get; set; } = string.Empty;

    [JsonPropertyName("version")]
    public string? Version { get; set; }

    [JsonPropertyName("diskUsageBytes")]
    public long DiskUsageBytes { get; set; }
}

public sealed class InstalledModel
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("runtimeId")]
    public string RuntimeId { get; set; } = string.Empty;

    [JsonPropertyName("directoryPath")]
    public string DirectoryPath { get; set; } = string.Empty;

    [JsonPropertyName("sizeBytes")]
    public long SizeBytes { get; set; }

    [JsonPropertyName("isDefault")]
    public bool IsDefault { get; set; }
}
