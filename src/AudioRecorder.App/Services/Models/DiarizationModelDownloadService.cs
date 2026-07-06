using System.Diagnostics;
using AudioRecorder.Services.Transcription;

namespace AudioRecorder.Services.Models;

/// <summary>
/// Скачивает модели диаризации sherpa-onnx (pyannote-segmentation-3.0 + CAM++).
/// Не зависит от выбора Whisper-модели — один комплект на все размеры.
/// Сегментационная модель распространяется как .tar.bz2 (k2-fsa GitHub Releases) —
/// распаковывается через встроенный в Windows tar.exe (bsdtar, есть с Windows 10 1803+),
/// без добавления NuGet-пакета только ради bzip2.
/// </summary>
public sealed class DiarizationModelDownloadService
{
    private const string SegmentationArchiveUrl =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2";
    private const string EmbeddingModelUrl =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx";

    private readonly string _modelsRoot;

    public DiarizationModelDownloadService(string? modelsRoot = null)
    {
        _modelsRoot = modelsRoot ?? DiarizationModelPaths.GetDiarizationModelsRoot();
    }

    public string GetModelsRoot() => _modelsRoot;

    public bool IsInstalled() => DiarizationModelPaths.IsInstalled(_modelsRoot);

    public async Task<ModelDownloadResult> DownloadModelsAsync(
        Action<ModelDownloadProgress> onProgress,
        CancellationToken ct)
    {
        try
        {
            Directory.CreateDirectory(_modelsRoot);

            var embeddingTarget = DiarizationModelPaths.GetEmbeddingModelPath(_modelsRoot);
            if (!File.Exists(embeddingTarget))
            {
                await DownloadFileAsync(EmbeddingModelUrl, embeddingTarget, "campplus.onnx", onProgress, ct);
            }

            var segmentationTarget = DiarizationModelPaths.GetSegmentationModelPath(_modelsRoot);
            if (!File.Exists(segmentationTarget))
            {
                var archivePath = Path.Combine(_modelsRoot, "segmentation.tar.bz2.download");
                await DownloadFileAsync(SegmentationArchiveUrl, archivePath, "sherpa-onnx-pyannote-segmentation-3-0.tar.bz2", onProgress, ct);

                var extractDir = Path.Combine(_modelsRoot, "_segmentation_extract");
                if (Directory.Exists(extractDir))
                    Directory.Delete(extractDir, recursive: true);
                Directory.CreateDirectory(extractDir);

                await ExtractTarBz2Async(archivePath, extractDir, ct);

                var extractedOnnx = Directory.EnumerateFiles(extractDir, "model.onnx", SearchOption.AllDirectories).FirstOrDefault();
                if (extractedOnnx is null)
                {
                    return new ModelDownloadResult(false,
                        "Не удалось найти model.onnx внутри архива сегментации.");
                }

                File.Move(extractedOnnx, segmentationTarget, overwrite: true);

                File.Delete(archivePath);
                Directory.Delete(extractDir, recursive: true);
            }

            return new ModelDownloadResult(true, "Модели диаризации скачаны и готовы к использованию.");
        }
        catch (OperationCanceledException)
        {
            return new ModelDownloadResult(false, "Скачивание отменено.");
        }
        catch (Exception ex)
        {
            return new ModelDownloadResult(false, $"Не удалось скачать модели диаризации: {ex.Message}");
        }
    }

    private static async Task DownloadFileAsync(
        string url, string targetPath, string displayName,
        Action<ModelDownloadProgress> onProgress, CancellationToken ct)
    {
        var tempPath = targetPath + ".download";

        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };

        long totalBytes = 0;
        using (var headRequest = new HttpRequestMessage(HttpMethod.Head, url))
        using (var headResponse = await http.SendAsync(headRequest, HttpCompletionOption.ResponseHeadersRead, ct))
        {
            if (headResponse.IsSuccessStatusCode && headResponse.Content.Headers.ContentLength.HasValue)
                totalBytes = headResponse.Content.Headers.ContentLength.Value;
        }

        using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();

        var downloadStart = DateTime.UtcNow;
        long downloadedBytes = 0;

        await using (var source = await response.Content.ReadAsStreamAsync(ct))
        await using (var destination = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None, 81920, useAsync: true))
        {
            var buffer = new byte[1024 * 64];
            while (true)
            {
                var read = await source.ReadAsync(buffer.AsMemory(0, buffer.Length), ct);
                if (read == 0) break;

                await destination.WriteAsync(buffer.AsMemory(0, read), ct);
                downloadedBytes += read;

                var elapsed = (DateTime.UtcNow - downloadStart).TotalSeconds;
                var speed = elapsed > 0.5 ? downloadedBytes / elapsed : 0;
                var remaining = speed > 0 && totalBytes > downloadedBytes
                    ? TimeSpan.FromSeconds((totalBytes - downloadedBytes) / speed)
                    : (TimeSpan?)null;

                var percent = totalBytes > 0 ? (int)(downloadedBytes * 100 / totalBytes) : 0;
                onProgress(new ModelDownloadProgress(percent, downloadedBytes, totalBytes, displayName, speed, remaining));
            }
        }

        if (File.Exists(targetPath))
            File.Delete(targetPath);
        File.Move(tempPath, targetPath);
    }

    private static async Task ExtractTarBz2Async(string archivePath, string destinationDir, CancellationToken ct)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "tar.exe",
            Arguments = $"-xjf \"{archivePath}\" -C \"{destinationDir}\"",
            UseShellExecute = false,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            CreateNoWindow = true
        };

        using var process = new Process { StartInfo = psi };
        process.Start();

        var stdErrTask = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync(ct);
        var stdErr = await stdErrTask;

        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"tar.exe завершился с кодом {process.ExitCode}: {stdErr}");
        }
    }
}
