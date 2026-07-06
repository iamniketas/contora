using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text.Json;

namespace AudioRecorder.Services.Transcription;

/// <summary>
/// Manages the lifecycle of sortformer_server.py (Flask HTTP server) and submits
/// audio for diarization via POST /diarize. Mirrors WhisperServerBackend's pattern
/// (persistent process, model loaded once) but on a separate port (5002 vs 5001)
/// since it's a distinct model/concern (diarization, not ASR).
/// </summary>
public sealed class DiarizationServerBackend : IDisposable
{
    private const int Port = 5002;
    private static readonly string BaseUrl = $"http://127.0.0.1:{Port}";

    private readonly string _pythonExe;
    private readonly string _scriptPath;
    private readonly HttpClient _http;

    private Process? _serverProcess;
    private bool _isLoaded;

    public DiarizationServerBackend(string pythonExe, string scriptPath)
    {
        _pythonExe = pythonExe;
        _scriptPath = scriptPath;
        _http = new HttpClient { Timeout = TimeSpan.FromSeconds(600) };
    }

    public bool IsLoaded => _isLoaded && _serverProcess is { HasExited: false };

    /// <summary>Starts the Python diarization server if it's not already running.</summary>
    public async Task<bool> StartAsync(CancellationToken ct)
    {
        if (IsLoaded) return true;

        if (_serverProcess is not null)
            await StopAsync();

        var psi = new ProcessStartInfo
        {
            FileName = _pythonExe,
            Arguments = $"\"{_scriptPath}\"",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8,
        };
        psi.EnvironmentVariables["SORTFORMER_PORT"] = Port.ToString();
        // Belt-and-suspenders against the tqdm-over-redirected-pipe crash (OSError [Errno 22]):
        // disable all progress bars and force UTF-8 so nothing writes ANSI/CR noise to the drained pipe.
        psi.EnvironmentVariables["TQDM_DISABLE"] = "1";
        psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8";
        psi.EnvironmentVariables["PYTHONUNBUFFERED"] = "1";

        _serverProcess = Process.Start(psi);
        if (_serverProcess is null) return false;

        _ = Task.Run(() => DrainStream(_serverProcess.StandardOutput), CancellationToken.None);
        _ = Task.Run(() => DrainStream(_serverProcess.StandardError), CancellationToken.None);

        // Model download (first run) + load can take a while; be generous.
        var deadline = DateTime.UtcNow.AddSeconds(180);
        while (DateTime.UtcNow < deadline && !ct.IsCancellationRequested)
        {
            if (_serverProcess.HasExited) return false;
            try
            {
                var resp = await _http.GetAsync($"{BaseUrl}/health", ct);
                if (resp.IsSuccessStatusCode)
                {
                    _isLoaded = true;
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
            _isLoaded = false;
        }
    }

    /// <summary>Sends a WAV file to the running server and returns raw (start, end, speaker) tuples.</summary>
    public async Task<(bool Success, List<(double Start, double End, string Speaker)> Segments, string? Error)> DiarizeAsync(
        string wavPath, CancellationToken ct = default)
    {
        try
        {
            var audioBytes = await File.ReadAllBytesAsync(wavPath, ct);
            using var form = new MultipartFormDataContent();

            var audioContent = new ByteArrayContent(audioBytes);
            audioContent.Headers.ContentType = MediaTypeHeaderValue.Parse("audio/wav");
            form.Add(audioContent, "file", Path.GetFileName(wavPath));

            var response = await _http.PostAsync($"{BaseUrl}/diarize", form, ct);
            var json = await response.Content.ReadAsStringAsync(ct);

            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            if (root.TryGetProperty("error", out var errProp))
                return (false, [], errProp.GetString() ?? "Unknown server error");

            var segments = new List<(double, double, string)>();
            if (root.TryGetProperty("segments", out var segmentsProp))
            {
                foreach (var seg in segmentsProp.EnumerateArray())
                {
                    var start = seg.GetProperty("start").GetDouble();
                    var end = seg.GetProperty("end").GetDouble();
                    var speaker = seg.GetProperty("speaker").GetString() ?? "speaker_0";
                    segments.Add((start, end, speaker));
                }
            }

            return (true, segments, null);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            return (false, [], $"HTTP diarization error: {ex.Message}");
        }
    }

    /// <summary>Searches known locations for sortformer_server.py.</summary>
    public static string? FindScript()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        var candidates = new[]
        {
            // 1. Alongside Contora's executable (bundled at publish time)
            Path.Combine(AppContext.BaseDirectory, "sortformer_server.py"),
            // 2. Contora's own runtime directory
            Path.Combine(localAppData, "Contora", "runtime", "sortformer_server.py"),
            // 3. Dev-time: Contora project tools folder
            FindDevToolsPath(),
        };

        return candidates.FirstOrDefault(c => c is not null && File.Exists(c));
    }

    private static string? FindDevToolsPath()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null)
        {
            var candidate = Path.Combine(dir.FullName, "tools", "sortformer-server", "sortformer_server.py");
            if (File.Exists(candidate))
                return candidate;
            dir = dir.Parent;
        }
        return null;
    }

    public void Dispose()
    {
        _ = StopAsync();
        _http.Dispose();
    }
}
