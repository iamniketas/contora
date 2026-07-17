using System.Diagnostics;

namespace AudioRecorder.Services.Models;

/// <summary>
/// Keeps pyannote.audio 4 isolated from Dictator's Python dependencies. The existing Dictator
/// Python is only used once as a bootstrap interpreter, so upgrading Community-1 never changes
/// Dictator's NeMo/ASR environment.
/// </summary>
public sealed class PyannoteCommunityRuntimeInstallerService
{
    private readonly string _runtimeRoot = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Contora", "runtimes", "pyannote-community");

    public string GetPythonPath() => Path.Combine(_runtimeRoot, "Scripts", "python.exe");

    public bool IsInstalled() => File.Exists(GetPythonPath());

    public async Task<(bool Success, string? Error)> EnsureInstalledAsync(
        string? bootstrapPython, Action<string>? onStatus, CancellationToken ct)
    {
        if (IsInstalled() && await CanImportPyannoteAsync(ct)) return (true, null);
        if (string.IsNullOrWhiteSpace(bootstrapPython) || !File.Exists(bootstrapPython))
            return (false, "Community-1 requires the Dictator Python runtime. Install Dictator's Python/NeMo runtime first.");

        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_runtimeRoot)!);
            if (!IsInstalled())
            {
                onStatus?.Invoke("Preparing isolated Community-1 runtime...");
                var create = await RunAsync(bootstrapPython, ["-m", "venv", "--system-site-packages", _runtimeRoot], ct);
                if (!create.Success) return (false, create.Error);
            }

            onStatus?.Invoke("Installing pyannote Community-1 dependencies (first run only)...");
            var install = await RunAsync(GetPythonPath(),
                ["-m", "pip", "install", "--upgrade", "pyannote.audio>=4,<5", "flask>=3,<4"], ct, TimeSpan.FromMinutes(20));
            if (!install.Success) return (false, install.Error);

            // The model is cached by huggingface_hub. This also catches gated/offline access now,
            // before transcription begins and gives the UI a useful installation error.
            onStatus?.Invoke("Downloading the Community-1 diarization model...");
            var preload = await RunAsync(GetPythonPath(),
                ["-c", "from pyannote.audio import Pipeline; Pipeline.from_pretrained('pyannote/speaker-diarization-community-1')"],
                ct, TimeSpan.FromMinutes(20));
            return preload.Success ? (true, null) : (false, preload.Error);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex) { return (false, ex.Message); }
    }

    private async Task<bool> CanImportPyannoteAsync(CancellationToken ct)
        => (await RunAsync(GetPythonPath(), ["-c", "import pyannote.audio"], ct, TimeSpan.FromSeconds(30))).Success;

    private static async Task<(bool Success, string? Error)> RunAsync(
        string fileName, IReadOnlyList<string> arguments, CancellationToken ct, TimeSpan? timeout = null)
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in arguments) psi.ArgumentList.Add(argument);
        using var process = Process.Start(psi);
        if (process is null) return (false, "Could not start Python.");

        var stdout = process.StandardOutput.ReadToEndAsync(ct);
        var stderr = process.StandardError.ReadToEndAsync(ct);
        using var timeoutCts = new CancellationTokenSource(timeout ?? TimeSpan.FromMinutes(5));
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, timeoutCts.Token);
        try
        {
            await process.WaitForExitAsync(linked.Token);
            var output = (await stderr).Trim();
            if (process.ExitCode == 0) return (true, null);
            if (string.IsNullOrWhiteSpace(output)) output = (await stdout).Trim();
            return (false, string.IsNullOrWhiteSpace(output) ? "Python runtime installation failed." : output);
        }
        catch (OperationCanceledException)
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
            if (ct.IsCancellationRequested) throw;
            return (false, "Timed out while installing the pyannote runtime.");
        }
    }
}
