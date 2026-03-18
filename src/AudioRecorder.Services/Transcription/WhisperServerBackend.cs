using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text.Json;

namespace AudioRecorder.Services.Transcription;

/// <summary>
/// Manages the lifecycle of whisper_server.py (Flask HTTP server) and submits
/// audio files for transcription via POST /transcribe.
///
/// Supports three runtimes inside whisper_server.py:
///   - faster_whisper  (CTranslate2 Whisper models)
///   - transformers_asr (Canary, Granite via HuggingFace pipeline)
///   - nemo_asr         (Parakeet via NVIDIA NeMo)
///
/// Uses port 5001 (Dictator uses 5000) to avoid conflicts.
/// </summary>
public sealed class WhisperServerBackend : IDisposable
{
    private const int Port = 5001;
    private static readonly string BaseUrl = $"http://127.0.0.1:{Port}";

    private readonly string _pythonExe;
    private readonly string _scriptPath;
    private readonly HttpClient _http;

    private Process? _serverProcess;
    private string? _loadedModelId;

    public WhisperServerBackend(string pythonExe, string scriptPath)
    {
        _pythonExe = pythonExe;
        _scriptPath = scriptPath;
        _http = new HttpClient { Timeout = TimeSpan.FromSeconds(600) };
    }

    public bool IsLoaded(string modelId)
        => _loadedModelId == modelId
           && _serverProcess is { HasExited: false };

    /// <summary>
    /// Starts the Python server for the given model if it's not already running.
    /// Returns true when the server is healthy and ready.
    /// </summary>
    public async Task<bool> StartAsync(string modelPath, string modelId, CancellationToken ct)
    {
        if (IsLoaded(modelId)) return true;

        // If a different model is loaded, stop it first
        if (_serverProcess is not null)
            await StopAsync();

        var psi = new ProcessStartInfo
        {
            FileName = _pythonExe,
            Arguments = $"\"{_scriptPath}\" \"{modelPath}\"",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8,
        };

        // Runtime hint so whisper_server.py picks the right backend
        psi.EnvironmentVariables["WHISPER_PORT"] = Port.ToString();
        psi.EnvironmentVariables["WHISPER_DEVICE"] = "auto";

        var lowerModelId = modelId.ToLowerInvariant();
        if (lowerModelId.Contains("parakeet"))
            psi.EnvironmentVariables["WHISPER_RUNTIME"] = "nemo";
        else if (lowerModelId.Contains("canary") || lowerModelId.Contains("granite"))
            psi.EnvironmentVariables["WHISPER_RUNTIME"] = "transformers";

        _serverProcess = Process.Start(psi);
        if (_serverProcess is null) return false;

        // Drain output asynchronously to avoid buffer deadlocks
        _ = Task.Run(() => DrainStream(_serverProcess.StandardOutput), CancellationToken.None);
        _ = Task.Run(() => DrainStream(_serverProcess.StandardError),  CancellationToken.None);

        // Wait for health check (up to 120 seconds — NeMo model loading is slow)
        var deadline = DateTime.UtcNow.AddSeconds(120);
        while (DateTime.UtcNow < deadline && !ct.IsCancellationRequested)
        {
            if (_serverProcess.HasExited) return false;
            try
            {
                var resp = await _http.GetAsync($"{BaseUrl}/health", ct);
                if (resp.IsSuccessStatusCode)
                {
                    _loadedModelId = modelId;
                    return true;
                }
            }
            catch (HttpRequestException) { }
            catch (TaskCanceledException) { break; }

            await Task.Delay(750, ct);
        }

        return false;
    }

    private static async Task DrainStream(StreamReader reader)
    {
        try
        {
            while (await reader.ReadLineAsync() is not null) { }
        }
        catch { }
    }

    /// <summary>Stops the server process.</summary>
    public async Task StopAsync()
    {
        if (_serverProcess is null) return;
        try
        {
            if (!_serverProcess.HasExited)
                _serverProcess.Kill(entireProcessTree: true);
            await _serverProcess.WaitForExitAsync();
        }
        catch { }
        finally
        {
            _serverProcess?.Dispose();
            _serverProcess = null;
            _loadedModelId = null;
        }
    }

    /// <summary>
    /// Sends an audio file to the running server and returns the transcribed text.
    /// </summary>
    public async Task<(bool Success, string Text, string? Error)> TranscribeAsync(
        string audioPath, string language = "ru", CancellationToken ct = default)
    {
        try
        {
            var audioBytes = await File.ReadAllBytesAsync(audioPath, ct);
            using var form = new MultipartFormDataContent();

            var audioContent = new ByteArrayContent(audioBytes);
            audioContent.Headers.ContentType = MediaTypeHeaderValue.Parse("audio/mpeg");
            form.Add(audioContent, "file", Path.GetFileName(audioPath));
            form.Add(new StringContent(language), "language");

            var response = await _http.PostAsync($"{BaseUrl}/transcribe", form, ct);
            var json = await response.Content.ReadAsStringAsync(ct);

            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            if (root.TryGetProperty("error", out var errProp))
                return (false, "", errProp.GetString() ?? "Unknown server error");

            var text = root.TryGetProperty("text", out var textProp)
                ? textProp.GetString() ?? ""
                : "";

            return (true, text, null);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            return (false, "", $"HTTP transcription error: {ex.Message}");
        }
    }

    /// <summary>
    /// Searches known locations for whisper_server.py.
    /// </summary>
    public static string? FindScript()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

        var candidates = new[]
        {
            // 1. Alongside Contora's executable (bundled)
            Path.Combine(AppContext.BaseDirectory, "whisper_server.py"),
            // 2. Shared AudioModels runtime directory
            Path.Combine(localAppData, "AudioModels", "runtimes", "whisper_server.py"),
            // 3. Contora's own runtime directory
            Path.Combine(localAppData, "Contora", "runtime", "whisper_server.py"),
            // 4. Dev-time: Dictator project location
            Path.Combine(userProfile, "projects", "dictator", "shared", "whisper-server", "whisper_server.py"),
            Path.Combine(userProfile, "source", "repos", "dictator", "shared", "whisper-server", "whisper_server.py"),
        };

        return candidates.FirstOrDefault(File.Exists);
    }

    public void Dispose()
    {
        _ = StopAsync();
        _http.Dispose();
    }
}
