using System.Text.Json;

namespace AudioRecorder.Services.Settings;

public sealed class SharedModelConfigService
{
    private static readonly string ConfigDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "SharedWhisperModels");

    private static readonly string ConfigPath = Path.Combine(ConfigDir, "config.json");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private readonly SemaphoreSlim _lock = new(1, 1);
    private SharedModelConfig? _cached;

    public async Task<SharedModelConfig> LoadAsync()
    {
        await _lock.WaitAsync();
        try
        {
            if (_cached != null)
                return _cached;

            if (File.Exists(ConfigPath))
            {
                var json = await File.ReadAllTextAsync(ConfigPath);
                _cached = JsonSerializer.Deserialize<SharedModelConfig>(json, JsonOptions) ?? new SharedModelConfig();
            }
            else
            {
                _cached = AutoDetect();
            }

            return _cached;
        }
        finally
        {
            _lock.Release();
        }
    }

    public async Task SaveAsync(SharedModelConfig config)
    {
        await _lock.WaitAsync();
        try
        {
            Directory.CreateDirectory(ConfigDir);

            var tempPath = ConfigPath + ".tmp";
            var json = JsonSerializer.Serialize(config, JsonOptions);
            await File.WriteAllTextAsync(tempPath, json);

            if (File.Exists(ConfigPath))
                File.Delete(ConfigPath);
            File.Move(tempPath, ConfigPath);

            _cached = config;
        }
        finally
        {
            _lock.Release();
        }
    }

    public async Task RegisterRuntimeAsync(string id, string displayName, string exePath, string? version = null)
    {
        var config = await LoadAsync();

        var existing = config.InstalledRuntimes.FirstOrDefault(r => r.Id == id);
        if (existing != null)
        {
            existing.ExePath = exePath;
            existing.DisplayName = displayName;
            existing.Version = version;
            existing.DiskUsageBytes = CalculateDirectorySize(Path.GetDirectoryName(exePath));
        }
        else
        {
            config.InstalledRuntimes.Add(new InstalledRuntime
            {
                Id = id,
                DisplayName = displayName,
                ExePath = exePath,
                Version = version,
                DiskUsageBytes = CalculateDirectorySize(Path.GetDirectoryName(exePath))
            });
        }

        config.ActiveRuntimeId ??= id;

        await SaveAsync(config);
    }

    public async Task RegisterModelAsync(string name, string runtimeId, string directoryPath, bool isDefault = false)
    {
        var config = await LoadAsync();

        var existing = config.InstalledModels.FirstOrDefault(m => m.Name == name && m.RuntimeId == runtimeId);
        if (existing != null)
        {
            existing.DirectoryPath = directoryPath;
            existing.SizeBytes = CalculateDirectorySize(directoryPath);
            existing.IsDefault = isDefault;
        }
        else
        {
            config.InstalledModels.Add(new InstalledModel
            {
                Name = name,
                RuntimeId = runtimeId,
                DirectoryPath = directoryPath,
                SizeBytes = CalculateDirectorySize(directoryPath),
                IsDefault = isDefault
            });
        }

        if (isDefault || config.ActiveModelName == null)
            config.ActiveModelName = name;

        await SaveAsync(config);
    }

    public async Task UnregisterRuntimeAsync(string id)
    {
        var config = await LoadAsync();
        config.InstalledRuntimes.RemoveAll(r => r.Id == id);
        config.InstalledModels.RemoveAll(m => m.RuntimeId == id);

        if (config.ActiveRuntimeId == id)
            config.ActiveRuntimeId = config.InstalledRuntimes.FirstOrDefault()?.Id;

        await SaveAsync(config);
    }

    public async Task UnregisterModelAsync(string name, string runtimeId)
    {
        var config = await LoadAsync();
        config.InstalledModels.RemoveAll(m => m.Name == name && m.RuntimeId == runtimeId);

        if (config.ActiveModelName == name)
            config.ActiveModelName = config.InstalledModels.FirstOrDefault()?.Name;

        await SaveAsync(config);
    }

    public void InvalidateCache() => _cached = null;

    /// <summary>
    /// Re-scans filesystem for runtimes and models, merging newly found entries into existing config.
    /// </summary>
    public async Task RefreshFromDiskAsync()
    {
        var config = await LoadAsync();
        var detected = AutoDetect();

        bool changed = false;

        // Merge runtimes
        foreach (var runtime in detected.InstalledRuntimes)
        {
            if (!config.InstalledRuntimes.Any(r => r.Id == runtime.Id))
            {
                config.InstalledRuntimes.Add(runtime);
                changed = true;
            }
        }

        // Merge models
        foreach (var model in detected.InstalledModels)
        {
            if (!config.InstalledModels.Any(m => m.Name == model.Name && m.RuntimeId == model.RuntimeId))
            {
                config.InstalledModels.Add(model);
                changed = true;
            }
        }

        // Remove models whose directories no longer exist
        var removed = config.InstalledModels.RemoveAll(m => !Directory.Exists(m.DirectoryPath));
        if (removed > 0) changed = true;

        if (changed)
        {
            config.ActiveRuntimeId ??= config.InstalledRuntimes.FirstOrDefault()?.Id;
            config.ActiveModelName ??= config.InstalledModels.FirstOrDefault()?.Name;
            await SaveAsync(config);
        }
    }

    private static SharedModelConfig AutoDetect()
    {
        var config = new SharedModelConfig();

        // Scan canonical Contora runtime location
        var runtimeRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Contora", "runtime", "faster-whisper-xxl");

        var exePath = Path.Combine(runtimeRoot, "faster-whisper-xxl.exe");
        if (File.Exists(exePath))
        {
            config.InstalledRuntimes.Add(new InstalledRuntime
            {
                Id = "faster-whisper-xxl",
                DisplayName = "Faster Whisper XXL",
                ExePath = exePath,
                DiskUsageBytes = CalculateDirectorySize(runtimeRoot)
            });
            config.ActiveRuntimeId = "faster-whisper-xxl";

            // Scan models
            var modelsRoot = Path.Combine(runtimeRoot, "_models");
            if (Directory.Exists(modelsRoot))
            {
                foreach (var dir in Directory.EnumerateDirectories(modelsRoot, "faster-whisper-*"))
                {
                    var modelName = Path.GetFileName(dir).Replace("faster-whisper-", "");
                    if (HasRequiredModelFiles(dir))
                    {
                        config.InstalledModels.Add(new InstalledModel
                        {
                            Name = modelName,
                            RuntimeId = "faster-whisper-xxl",
                            DirectoryPath = dir,
                            SizeBytes = CalculateDirectorySize(dir)
                        });
                    }
                }
            }

            // Scan shared models location
            var sharedModels = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "SharedWhisperModels");
            if (Directory.Exists(sharedModels))
            {
                foreach (var dir in Directory.EnumerateDirectories(sharedModels, "faster-whisper-*"))
                {
                    var modelName = Path.GetFileName(dir).Replace("faster-whisper-", "");
                    if (HasRequiredModelFiles(dir) && !config.InstalledModels.Any(m => m.Name == modelName))
                    {
                        config.InstalledModels.Add(new InstalledModel
                        {
                            Name = modelName,
                            RuntimeId = "faster-whisper-xxl",
                            DirectoryPath = dir,
                            SizeBytes = CalculateDirectorySize(dir)
                        });
                    }
                }
            }

            if (config.InstalledModels.Count > 0)
                config.ActiveModelName = config.InstalledModels[0].Name;
        }

        return config;
    }

    private static bool HasRequiredModelFiles(string dir)
    {
        return File.Exists(Path.Combine(dir, "config.json"))
            && File.Exists(Path.Combine(dir, "model.bin"))
            && File.Exists(Path.Combine(dir, "tokenizer.json"))
            && File.Exists(Path.Combine(dir, "vocabulary.txt"));
    }

    private static long CalculateDirectorySize(string? path)
    {
        if (string.IsNullOrEmpty(path) || !Directory.Exists(path))
            return 0;

        try
        {
            return new DirectoryInfo(path)
                .EnumerateFiles("*", SearchOption.AllDirectories)
                .Sum(f => f.Length);
        }
        catch
        {
            return 0;
        }
    }
}
