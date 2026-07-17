using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text.Json;
using AudioRecorder.Core.Models;
using AudioRecorder.Core.Services;
using NAudio.Wave;

namespace AudioRecorder.Services.Transcription;

/// <summary>
/// Local pyannote Community-1 diarization. Whisper.net remains in-process; this small persistent
/// Python host is only for pyannote, whose official runtime is Python/PyTorch.
/// </summary>
public sealed class PyannoteCommunityDiarizationService : IDiarizationService, IDisposable
{
    private readonly string _pythonExe;
    private readonly string _scriptPath;
    private readonly DiarizationOptions _options;
    private readonly string _deviceMode;
    private PyannoteCommunityServerBackend? _server;

    public PyannoteCommunityDiarizationService(
        string pythonExe, string scriptPath, DiarizationOptions options, string deviceMode)
    {
        _pythonExe = pythonExe;
        _scriptPath = scriptPath;
        _options = options.Normalize();
        _deviceMode = deviceMode;
    }

    public bool IsAvailable => File.Exists(_pythonExe) && File.Exists(_scriptPath);

    public async Task<List<DiarizationSegment>> DiarizeAsync(float[] pcm16kMono, CancellationToken ct = default)
    {
        _server ??= new PyannoteCommunityServerBackend(_pythonExe, _scriptPath, _deviceMode);
        if (!await _server.StartAsync(ct))
            throw new InvalidOperationException(
                "Could not start the pyannote Community-1 diarization runtime. " +
                "Install the Contora Python runtime with pyannote.audio 4 and the Community-1 model.");

        var tempWavPath = Path.Combine(Path.GetTempPath(), $"Contora_pyannote_{Guid.NewGuid():N}.wav");
        try
        {
            var format = WaveFormat.CreateIeeeFloatWaveFormat(16000, 1);
            using (var writer = new WaveFileWriter(tempWavPath, format))
                writer.WriteSamples(pcm16kMono, 0, pcm16kMono.Length);

            var result = await _server.DiarizeAsync(tempWavPath, _options, ct);
            if (!result.Success)
                throw new InvalidOperationException(result.Error ?? "pyannote diarization failed.");

            return result.Segments
                .OrderBy(s => s.Start)
                .Select(s => new DiarizationSegment(
                    TimeSpan.FromSeconds(s.Start), TimeSpan.FromSeconds(s.End), NormalizeSpeakerLabel(s.Speaker)))
                .ToList();
        }
        finally
        {
            try { File.Delete(tempWavPath); } catch { }
        }
    }

    private static string NormalizeSpeakerLabel(string label)
    {
        var digits = new string(label.Where(char.IsDigit).ToArray());
        return int.TryParse(digits, out var index) ? $"SPEAKER_{index:D2}" : label;
    }

    public void Dispose()
    {
        _server?.Dispose();
        _server = null;
    }
}

public sealed class PyannoteCommunityServerBackend : IDisposable
{
    private const int Port = 5003;
    private static readonly string BaseUrl = $"http://127.0.0.1:{Port}";
    private static readonly string PidFilePath = Path.Combine(Path.GetTempPath(), "contora_pyannote_server.pid");
    private readonly string _pythonExe;
    private readonly string _scriptPath;
    private readonly string _deviceMode;
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromMinutes(20) };
    private Process? _serverProcess;

    public PyannoteCommunityServerBackend(string pythonExe, string scriptPath, string deviceMode)
    {
        _pythonExe = pythonExe;
        _scriptPath = scriptPath;
        _deviceMode = deviceMode;
    }

    public async Task<bool> StartAsync(CancellationToken ct)
    {
        if (_serverProcess is { HasExited: false }) return true;
        await StopAsync();
        KillOrphanedServer();

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
        psi.EnvironmentVariables["CONTORA_PYANNOTE_PORT"] = Port.ToString();
        psi.EnvironmentVariables["CONTORA_PYANNOTE_DEVICE"] = _deviceMode;
        psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8";
        psi.EnvironmentVariables["PYTHONUNBUFFERED"] = "1";
        psi.EnvironmentVariables["TQDM_DISABLE"] = "1";
        var hfToken = Environment.GetEnvironmentVariable("HF_TOKEN")
            ?? Environment.GetEnvironmentVariable("HF_TOKEN", EnvironmentVariableTarget.User);
        if (!string.IsNullOrWhiteSpace(hfToken))
        {
            psi.EnvironmentVariables["HF_TOKEN"] = hfToken;
            psi.EnvironmentVariables["HUGGINGFACE_HUB_TOKEN"] = hfToken;
        }

        _serverProcess = Process.Start(psi);
        if (_serverProcess is null) return false;
        try { File.WriteAllText(PidFilePath, _serverProcess.Id.ToString()); } catch { }
        _ = DrainStream(_serverProcess.StandardOutput);
        _ = DrainStream(_serverProcess.StandardError);

        var deadline = DateTime.UtcNow.AddMinutes(5);
        while (DateTime.UtcNow < deadline && !ct.IsCancellationRequested)
        {
            if (_serverProcess.HasExited) return false;
            try
            {
                if ((await _http.GetAsync($"{BaseUrl}/health", ct)).IsSuccessStatusCode) return true;
            }
            catch (HttpRequestException) { }
            catch (TaskCanceledException) { break; }
            await Task.Delay(750, ct);
        }
        return false;
    }

    public async Task<(bool Success, List<(double Start, double End, string Speaker)> Segments, string? Error)> DiarizeAsync(
        string wavPath, DiarizationOptions options, CancellationToken ct)
    {
        try
        {
            using var form = new MultipartFormDataContent();
            var bytes = await File.ReadAllBytesAsync(wavPath, ct);
            var audio = new ByteArrayContent(bytes);
            audio.Headers.ContentType = MediaTypeHeaderValue.Parse("audio/wav");
            form.Add(audio, "file", Path.GetFileName(wavPath));
            form.Add(new StringContent(options.Constraint.ToString().ToLowerInvariant()), "constraint");
            if (options.Count is { } count) form.Add(new StringContent(count.ToString()), "count");

            var response = await _http.PostAsync($"{BaseUrl}/diarize", form, ct);
            var json = await response.Content.ReadAsStringAsync(ct);
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.TryGetProperty("error", out var error))
                return (false, [], error.GetString());
            if (!response.IsSuccessStatusCode)
                return (false, [], $"pyannote server returned HTTP {(int)response.StatusCode}.");

            var segments = new List<(double, double, string)>();
            if (root.TryGetProperty("segments", out var items))
            {
                foreach (var item in items.EnumerateArray())
                    segments.Add((item.GetProperty("start").GetDouble(), item.GetProperty("end").GetDouble(),
                        item.GetProperty("speaker").GetString() ?? "speaker_0"));
            }
            return (true, segments, null);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex) { return (false, [], $"pyannote HTTP error: {ex.Message}"); }
    }

    private static async Task DrainStream(StreamReader reader)
    {
        try { while (await reader.ReadLineAsync() is not null) { } } catch { }
    }

    private static void KillOrphanedServer()
    {
        try
        {
            if (!File.Exists(PidFilePath) || !int.TryParse(File.ReadAllText(PidFilePath), out var pid)) return;
            using var process = Process.GetProcessById(pid);
            if (string.Equals(process.ProcessName, "python", StringComparison.OrdinalIgnoreCase))
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit(5000);
            }
        }
        catch { }
        finally { try { File.Delete(PidFilePath); } catch { } }
    }

    public async Task StopAsync()
    {
        if (_serverProcess is null) return;
        try
        {
            if (!_serverProcess.HasExited) _serverProcess.Kill(entireProcessTree: true);
            await _serverProcess.WaitForExitAsync();
        }
        catch { }
        finally
        {
            _serverProcess.Dispose();
            _serverProcess = null;
            try { File.Delete(PidFilePath); } catch { }
        }
    }

    public void Dispose()
    {
        _ = StopAsync();
        _http.Dispose();
    }

    public static string? FindScript()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var candidates = new[]
        {
            Path.Combine(AppContext.BaseDirectory, "pyannote_community_server.py"),
            Path.Combine(localAppData, "Contora", "runtime", "pyannote_community_server.py"),
            FindDevToolsPath(),
        };
        return candidates.FirstOrDefault(File.Exists);
    }

    private static string? FindDevToolsPath()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "tools", "pyannote-community-server", "pyannote_community_server.py");
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }
}
