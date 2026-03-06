using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AudioRecorder.Services.Hardware;

public sealed record GpuInfo(
    string Name,
    long VramMb,
    bool IsNvidia,
    bool IsCudaCompatible);

public sealed record CpuInfo(
    string Name,
    int Cores,
    int MaxMhz);

public sealed record HardwareDiagnostics(
    GpuInfo? PrimaryGpu,
    CpuInfo? Cpu,
    long TotalRamMb,
    string RecommendedDevice,   // "cuda" or "cpu"
    string RecommendedModel,    // "large-v2", "medium", "small", "tiny"
    string? PerformanceWarning);

public static class HardwareDiagnosticsService
{
    /// <summary>
    /// Cached result of the last RunAsync call.
    /// MainPage reads this in CreateTranscriptionService so "auto" mode
    /// resolves to the hardware-recommended device without asking the user.
    /// </summary>
    public static HardwareDiagnostics? LastResult { get; private set; }

    public static async Task<HardwareDiagnostics> RunAsync(CancellationToken ct = default)
    {
        var (gpus, cpu, totalRamMb) = await QueryAllHardwareAsync(ct);

        var cudaGpu    = gpus.FirstOrDefault(g => g.IsNvidia && g.IsCudaCompatible);
        var anyNvidia  = gpus.FirstOrDefault(g => g.IsNvidia);
        var primaryGpu = cudaGpu ?? anyNvidia ?? gpus.FirstOrDefault();

        // nvidia-smi: most precise VRAM for NVIDIA (runs as its own 64-bit process).
        if (primaryGpu?.IsNvidia == true)
        {
            var smiVram = await QueryNvidiaSmiVramAsync(ct);
            if (smiVram > 0)
                primaryGpu = primaryGpu with { VramMb = smiVram };
        }

        string device, model;
        string? warning = null;

        if (cudaGpu != null)
        {
            device = "cuda";
            var vram = primaryGpu!.VramMb;
            model = vram >= 4096 ? "large-v2"
                  : vram >= 2048 ? "medium"
                  : "small";
        }
        else
        {
            device = "cpu";
            model  = totalRamMb >= 8192 ? "small" : "tiny";

            var anyAmd = gpus.FirstOrDefault(g => ContainsAny(g.Name, "AMD", "Radeon"));

            if (anyNvidia != null)
                warning = $"GPU {anyNvidia.Name} does not support CUDA " +
                          "(requires GTX 600 or newer). Transcription will run on CPU.";
            else if (anyAmd != null)
                warning = $"GPU {anyAmd.Name} (AMD) does not support CUDA. " +
                          "faster-whisper on Windows requires NVIDIA. Transcription will run on CPU.";
            else if (totalRamMb < 4096)
                warning = $"Low RAM ({totalRamMb / 1024.0:F1} GB). Consider using model 'tiny'.";
        }

        var result = new HardwareDiagnostics(primaryGpu, cpu, totalRamMb, device, model, warning);
        LastResult = result;
        return result;
    }

    // ─── Single PowerShell script: GPU names, VRAM (64-bit registry), CPU, RAM ───
    // KEY FIX: we spawn 64-bit PowerShell via Sysnative when the app runs as 32-bit.
    // A 32-bit process reads the registry via WOW64 and gets 32-bit-truncated values;
    // the 64-bit powershell.exe reads the real QWORD (e.g. 24 GB = 0x600000000 bytes).

    private static async Task<(List<GpuInfo> Gpus, CpuInfo? Cpu, long TotalRamMb)>
        QueryAllHardwareAsync(CancellationToken ct)
    {
        const string script = """
            $out = @{}
            # GPU names
            try {
                $out.gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name })
            } catch {}
            # VRAM: HardwareInformation.MemorySize is REG_QWORD (64-bit) — correct for >4 GB cards
            try {
                $base    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
                $maxVram = [long]0
                Get-ChildItem $base -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -match '^\d{4}$' } |
                    ForEach-Object {
                        $val = (Get-ItemProperty $_.PSPath 'HardwareInformation.MemorySize' -EA SilentlyContinue).'HardwareInformation.MemorySize'
                        if ($val -ne $null) {
                            $v = [long]$val
                            if ($v -gt $maxVram) { $maxVram = $v }
                        }
                    }
                $out.vramBytes = $maxVram
            } catch {}
            # RAM
            try { $out.ramBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory } catch {}
            # CPU
            try {
                $c = Get-CimInstance Win32_Processor | Select-Object -First 1
                $out.cpuName  = $c.Name
                $out.cpuCores = $c.NumberOfCores
                $out.cpuMhz   = $c.MaxClockSpeed
            } catch {}
            $out | ConvertTo-Json -Compress
            """;

        var json = await RunPowerShellAsync(script, ct);
        if (string.IsNullOrWhiteSpace(json))
            return ([], null, 0);

        try
        {
            using var doc  = JsonDocument.Parse(json);
            var root = doc.RootElement;

            // GPUs
            var gpus = new List<GpuInfo>();
            long vramMbFromRegistry = 0;
            if (root.TryGetProperty("vramBytes", out var vramEl) && vramEl.TryGetInt64(out var vramBytes) && vramBytes > 0)
                vramMbFromRegistry = vramBytes / (1024 * 1024);

            if (root.TryGetProperty("gpus", out var gpusEl))
            {
                foreach (var nameEl in gpusEl.EnumerateArray())
                {
                    var name = nameEl.GetString() ?? "";
                    var isNvidia       = ContainsAny(name, "NVIDIA", "GeForce", "Quadro", "RTX", "GTX", "Tesla");
                    var isCudaCompatible = isNvidia && IsModernNvidiaGpu(name);
                    gpus.Add(new GpuInfo(name, vramMbFromRegistry, isNvidia, isCudaCompatible));
                }
            }

            // RAM
            long totalRamMb = 0;
            if (root.TryGetProperty("ramBytes", out var ramEl) && ramEl.TryGetInt64(out var ramBytes))
                totalRamMb = ramBytes / (1024 * 1024);

            // CPU
            CpuInfo? cpu = null;
            if (root.TryGetProperty("cpuName", out var cpuNameEl))
            {
                var cores = root.TryGetProperty("cpuCores", out var cEl) ? cEl.GetInt32() : 0;
                var mhz   = root.TryGetProperty("cpuMhz",   out var mEl) ? mEl.GetInt32() : 0;
                cpu = new CpuInfo((cpuNameEl.GetString() ?? "Unknown").Trim(), cores, mhz);
            }

            return (gpus, cpu, totalRamMb);
        }
        catch { return ([], null, 0); }
    }

    // ─── VRAM via nvidia-smi (independent 64-bit process, most accurate for NVIDIA) ───

    private static async Task<long> QueryNvidiaSmiVramAsync(CancellationToken ct)
    {
        var smiPath = FindNvidiaSmi();
        if (smiPath == null) return 0;

        try
        {
            var psi = new ProcessStartInfo(smiPath)
            {
                Arguments = "--query-gpu=memory.total --format=csv,noheader,nounits",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(5));
            using var proc = new Process { StartInfo = psi };
            proc.Start();
            var output = await proc.StandardOutput.ReadToEndAsync(cts.Token);
            await proc.WaitForExitAsync(cts.Token);
            var line = output.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim();
            if (long.TryParse(line, out var mib) && mib > 0)
                return mib;
        }
        catch { }
        return 0;
    }

    private static string? FindNvidiaSmi()
    {
        // Check well-known paths first (not dependent on PATH env var)
        string[] candidates =
        [
            // From a 32-bit process, System32 is redirected to SysWOW64.
            // Sysnative is a virtual alias that always points to the real 64-bit System32.
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Sysnative", "nvidia-smi.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),  "nvidia-smi.exe"),
            @"C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
        ];
        foreach (var p in candidates)
        {
            try { if (File.Exists(p)) return p; } catch { }
        }
        return null;
    }

    // ─── Helpers ───

    /// <summary>
    /// Returns the path to 64-bit powershell.exe.
    /// When the app runs as a 32-bit (x86) process on a 64-bit OS, the normal "System32"
    /// folder is transparently redirected to "SysWOW64" by WOW64, giving us 32-bit PowerShell
    /// which reads 32-bit-truncated registry values. Using the "Sysnative" virtual path
    /// bypasses that redirection and gives us true 64-bit PowerShell.
    /// </summary>
    private static string GetPowerShellExe()
    {
        if (Environment.Is64BitOperatingSystem && !Environment.Is64BitProcess)
        {
            var sysnativePsh = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "Sysnative", "WindowsPowerShell", "v1.0", "powershell.exe");
            try { if (File.Exists(sysnativePsh)) return sysnativePsh; } catch { }
        }
        return "powershell.exe";
    }

    private static async Task<string> RunPowerShellAsync(string script, CancellationToken ct)
    {
        var encoded = Convert.ToBase64String(System.Text.Encoding.Unicode.GetBytes(script));
        var psi = new ProcessStartInfo(GetPowerShellExe())
        {
            Arguments = $"-NoProfile -NonInteractive -EncodedCommand {encoded}",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(15));
            using var process = new Process { StartInfo = psi };
            process.Start();
            var output = await process.StandardOutput.ReadToEndAsync(cts.Token);
            await process.WaitForExitAsync(cts.Token);
            return output;
        }
        catch { return string.Empty; }
    }

    private static bool ContainsAny(string text, params string[] terms)
        => terms.Any(t => text.Contains(t, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// Kepler+ (GTX 6xx+, RTX) support CUDA 3.5+ required by modern PyTorch/faster-whisper.
    /// Fermi (GTX 4xx, 5xx) and older are NOT supported.
    /// </summary>
    private static bool IsModernNvidiaGpu(string name)
    {
        if (Regex.IsMatch(name, @"\bRTX\b",         RegexOptions.IgnoreCase)) return true;
        if (Regex.IsMatch(name, @"GTX\s*16\d{2}",   RegexOptions.IgnoreCase)) return true;
        if (Regex.IsMatch(name, @"GTX\s*10\d{2}",   RegexOptions.IgnoreCase)) return true;
        if (Regex.IsMatch(name, @"GTX\s*9\d{2}",    RegexOptions.IgnoreCase)) return true;
        if (Regex.IsMatch(name, @"GTX\s*750",       RegexOptions.IgnoreCase)) return true;
        if (Regex.IsMatch(name, @"GTX\s*7[0-9]{2}", RegexOptions.IgnoreCase)) return true;
        if (Regex.IsMatch(name, @"GTX\s*6[0-9]{2}", RegexOptions.IgnoreCase)) return true;
        if (Regex.IsMatch(name, @"\b[AVH]\d{2,4}\b", RegexOptions.IgnoreCase)) return true;
        return false;
    }
}
