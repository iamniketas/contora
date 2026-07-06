using AudioRecorder.Services.Transcription;

namespace AudioRecorder.Services.Models;

/// <summary>
/// Скачивает GGML (whisper.cpp) модели для Whisper.net — одиночный файл ggml-{name}.bin,
/// в отличие от 4-файлового CTranslate2-формата у WhisperModelDownloadService.
/// Модели официально публикуются ggerganov/whisper.cpp, включая large-v3-turbo
/// (у CTranslate2/Systran репозитория для turbo не существует — см. WhisperModelDownloadService).
/// </summary>
public sealed class GgmlModelDownloadService
{
    private const string RepoResolveUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main";

    private readonly string _modelName;
    private readonly string _modelsRoot;
    private readonly string _fileName;

    public GgmlModelDownloadService(string modelName, string? modelsRoot = null)
    {
        _modelName = WhisperModelDownloadService.NormalizeModelName(modelName);
        _modelsRoot = modelsRoot ?? GgmlModelPaths.GetGgmlModelsRoot();
        _fileName = GgmlModelPaths.GetFileName(_modelName);
    }

    public string GetModelsRoot() => _modelsRoot;

    public string GetModelPath() => GgmlModelPaths.GetGgmlModelPath(_modelsRoot, _modelName);

    public bool IsModelInstalled() => GgmlModelPaths.IsGgmlModelInstalled(_modelsRoot, _modelName);

    public async Task<ModelDownloadResult> DownloadModelAsync(
        Action<ModelDownloadProgress> onProgress,
        CancellationToken ct)
    {
        try
        {
            Directory.CreateDirectory(_modelsRoot);

            var targetPath = GetModelPath();
            var tempPath = targetPath + ".download";
            var fileUrl = $"{RepoResolveUrl}/{_fileName}";

            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };

            long totalBytes = 0;
            using (var headRequest = new HttpRequestMessage(HttpMethod.Head, fileUrl))
            using (var headResponse = await http.SendAsync(headRequest, HttpCompletionOption.ResponseHeadersRead, ct))
            {
                if (headResponse.IsSuccessStatusCode && headResponse.Content.Headers.ContentLength.HasValue)
                    totalBytes = headResponse.Content.Headers.ContentLength.Value;
            }

            using var response = await http.GetAsync(fileUrl, HttpCompletionOption.ResponseHeadersRead, ct);
            if (!response.IsSuccessStatusCode)
            {
                return new ModelDownloadResult(false,
                    $"Модель «{_modelName}» недоступна по адресу {fileUrl} (HTTP {(int)response.StatusCode}).");
            }

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
                    onProgress(new ModelDownloadProgress(percent, downloadedBytes, totalBytes, _fileName, speed, remaining));
                }

                await destination.FlushAsync(ct);
            }

            if (File.Exists(targetPath))
                File.Delete(targetPath);
            File.Move(tempPath, targetPath);

            return new ModelDownloadResult(true, $"Модель «{_modelName}» (GGML) скачана и готова к использованию.");
        }
        catch (OperationCanceledException)
        {
            return new ModelDownloadResult(false, "Скачивание модели отменено.");
        }
        catch (Exception ex)
        {
            return new ModelDownloadResult(false, $"Не удалось скачать модель: {ex.Message}");
        }
    }
}
