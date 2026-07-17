using System.Diagnostics;

namespace AudioRecorder.Services.Models;

/// <summary>
/// Keeps pyannote.audio 4 isolated from Dictator's Python dependencies. The existing Dictator
/// Python is only used once as a bootstrap interpreter, so upgrading Community-1 never changes
/// Dictator's NeMo/ASR environment.
/// </summary>
public sealed class PyannoteCommunityRuntimeInstallerService
{
    // CUDA wheels are published separately from the CPU packages on PyPI. Keep this explicit:
    // otherwise pip resolves torch to the CPU build and Community-1 silently runs on the CPU.
    private const string CudaTorchVersion = "2.11.0+cu128";
    private const string CudaTorchIndexUrl = "https://download.pytorch.org/whl/cu128";
    private readonly string _runtimeRoot = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Contora", "runtimes", "pyannote-community");

    public string GetPythonPath() => Path.Combine(_runtimeRoot, "Scripts", "python.exe");

    public bool IsInstalled() => File.Exists(GetPythonPath());

    public async Task<(bool Success, string? Error)> EnsureInstalledAsync(
        string? bootstrapPython, Action<string>? onStatus, CancellationToken ct)
    {
        // Importing pyannote alone is not sufficient: Community-1 is fetched
        // lazily and can still be absent or inaccessible on first diarization.
        if (IsInstalled()
            && await IsCudaTorchAvailableAsync(ct)
            && await CanLoadCommunityModelAsync(ct))
            return (true, null);
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

            if (!await IsCudaTorchAvailableAsync(ct))
            {
                onStatus?.Invoke("Installing CUDA PyTorch for Community-1 (first run only)...");
                var cudaInstall = await RunAsync(GetPythonPath(),
                    ["-m", "pip", "install", "--upgrade", "--force-reinstall", "--no-cache-dir",
                        $"torch=={CudaTorchVersion}", "--index-url", CudaTorchIndexUrl],
                    ct, TimeSpan.FromMinutes(30));
                if (!cudaInstall.Success) return (false, cudaInstall.Error);

                if (!await IsCudaTorchAvailableAsync(ct))
                    return (false, "CUDA PyTorch was installed, but Contora cannot access an NVIDIA GPU. Update the NVIDIA driver and restart Contora.");
            }

            // Download the complete gated snapshot now. Pipeline.from_pretrained
            // only fetches its manifest eagerly, leaving model weights to be
            // downloaded during the "Detecting speakers" phase otherwise.
            onStatus?.Invoke("Downloading the Community-1 diarization model...");
            var preload = await RunAsync(GetPythonPath(),
                ["-c", "import os; from huggingface_hub import snapshot_download; from pyannote.audio import Pipeline; token=os.getenv('HF_TOKEN') or os.getenv('HUGGINGFACE_HUB_TOKEN'); path=snapshot_download('pyannote/speaker-diarization-community-1', token=token); Pipeline.from_pretrained(path, token=token)"],
                ct, TimeSpan.FromMinutes(20));
            return preload.Success ? (true, null) : (false, preload.Error);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex) { return (false, ex.Message); }
    }

    private async Task<bool> CanLoadCommunityModelAsync(CancellationToken ct)
        => (await RunAsync(GetPythonPath(),
            ["-c", "import os; from huggingface_hub import snapshot_download; from pyannote.audio import Pipeline; token=os.getenv('HF_TOKEN') or os.getenv('HUGGINGFACE_HUB_TOKEN'); path=snapshot_download('pyannote/speaker-diarization-community-1', local_files_only=True); Pipeline.from_pretrained(path, token=token)"],
            ct, TimeSpan.FromMinutes(5))).Success;

    private async Task<bool> IsCudaTorchAvailableAsync(CancellationToken ct)
        => (await RunAsync(GetPythonPath(),
            ["-c", "import sys, torch; sys.exit(0 if torch.version.cuda and torch.cuda.is_available() else 1)"],
            ct, TimeSpan.FromMinutes(1))).Success;

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
        ConfigureHuggingFaceToken(psi);
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

    private static void ConfigureHuggingFaceToken(ProcessStartInfo psi)
    {
        // Read the persistent user variable as well as the current process.
        // Explorer-launched applications can otherwise miss a token added with
        // setx until the next sign-in.
        var token = Environment.GetEnvironmentVariable("HF_TOKEN")
            ?? Environment.GetEnvironmentVariable("HF_TOKEN", EnvironmentVariableTarget.User);
        if (string.IsNullOrWhiteSpace(token)) return;

        psi.Environment["HF_TOKEN"] = token;
        psi.Environment["HUGGINGFACE_HUB_TOKEN"] = token;
    }
}
