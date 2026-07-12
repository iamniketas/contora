using System.Text;
using AudioRecorder.Core.Models;
using AudioRecorder.Core.Services;
using AudioRecorder.Services.Audio;
using AudioRecorder.Services.Logging;
using Whisper.net;

namespace AudioRecorder.Services.Transcription;

/// <summary>
/// In-process ASR через Whisper.net (whisper.cpp binding) — CUDA + Flash Attention + greedy
/// decoding + no-context, тот же профиль скорости, что у whisper-rs в Dictator.
/// Модель грузится один раз на инстанс сервиса и держится в памяти между вызовами.
/// </summary>
public sealed class WhisperNetTranscriptionService : ITranscriptionService, IDisposable
{
    private readonly string _modelPath;
    private readonly bool _enableDiarization;
    private readonly string _deviceMode; // "auto" | "cuda" | "cpu"
    private readonly IDiarizationService? _diarizationService;
    private readonly string _language;
    private readonly bool _useVad;

    private WhisperFactory? _factory;
    private WhisperVadFactory? _vadFactory;
    private TimeSpan _audioDuration;
    private DateTime _transcriptionStartTime;

    public event EventHandler<TranscriptionProgress>? ProgressChanged;

    public bool IsWhisperAvailable => File.Exists(_modelPath);

    public WhisperNetTranscriptionService(
        string modelPath,
        bool enableDiarization = true,
        string deviceMode = "auto",
        IDiarizationService? diarizationService = null,
        string language = "ru",
        bool useVad = true)
    {
        _modelPath = modelPath;
        _enableDiarization = enableDiarization;
        _deviceMode = deviceMode;
        _diarizationService = diarizationService;
        _language = language;
        _useVad = useVad;
    }

    public async Task<TranscriptionResult> TranscribeAsync(string audioPath, CancellationToken ct = default)
    {
        if (!File.Exists(audioPath))
            return new TranscriptionResult(false, null, [], $"File not found: {audioPath}");

        if (!IsWhisperAvailable)
        {
            return new TranscriptionResult(false, null, [],
                $"Модель «{Path.GetFileName(_modelPath)}» не найдена.\nСкачайте модель в Настройки → Models.");
        }

        try
        {
            RaiseProgress(TranscriptionState.Converting, 0, "Preparing audio...");

            var pcm = await AudioConverter.ToWhisperPcmAsync(audioPath, ct);
            _audioDuration = TimeSpan.FromSeconds(pcm.Length / 16000.0);
            _transcriptionStartTime = DateTime.Now;

            RaiseProgress(TranscriptionState.Transcribing, 0, "Starting Whisper.net...");

            var factory = GetOrCreateFactory();

            // VAD-driven transcription: feed only detected speech regions to Whisper so it never
            // decodes pure silence/music (which produces "Продолжение следует…"-style hallucinations).
            // This mirrors the legacy faster-whisper-xxl engine's default --vad_filter behaviour.
            // Falls back to whole-buffer transcription if the VAD model isn't available.
            var speechRegions = _useVad ? await TryGetSpeechRegionsAsync(pcm, ct) : null;

            List<(TimeSpan Start, TimeSpan End, string Text)> rawSegments;
            if (speechRegions is { Count: > 0 })
            {
                // A fresh WhisperProcessor per region, rather than one processor reused across the
                // whole file: on long recordings (hundreds of VAD regions) reusing a single native
                // decoding session degraded and eventually threw "invalid argument" from the CUDA
                // backend near the end of the file. Building processors is cheap — it opens a new
                // decoding session against the already-loaded model, it does not reload weights.
                rawSegments = await TranscribeRegionsAsync(factory, pcm, speechRegions, ct);
            }
            else
            {
                using var processor = BuildProcessor(factory);
                rawSegments = await TranscribeWholeAsync(processor, pcm, ct);
            }

            List<DiarizationSegment>? diarizationSegments = null;
            if (_enableDiarization && _diarizationService is { IsAvailable: true })
            {
                RaiseProgress(TranscriptionState.Transcribing, 97, "Detecting speakers...",
                    processed: _audioDuration, total: _audioDuration);
                diarizationSegments = await _diarizationService.DiarizeAsync(pcm, ct);
            }

            var segments = TranscriptionDiarizationMerger.Merge(rawSegments, diarizationSegments);

            var outputPath = await WriteTranscriptFileAsync(audioPath, segments, ct);

            RaiseProgress(TranscriptionState.Completed, 100, "Transcription completed");
            return new TranscriptionResult(true, outputPath, segments, null);
        }
        catch (OperationCanceledException)
        {
            RaiseProgress(TranscriptionState.Failed, 0, "Transcription cancelled");
            throw;
        }
        catch (Exception ex)
        {
            AppLogger.LogError(
                $"WhisperNetTranscriptionService failed (model={Path.GetFileName(_modelPath)}, " +
                $"device={_deviceMode}, audio={Path.GetFileName(audioPath)}, duration={_audioDuration}): {ex}");
            RaiseProgress(TranscriptionState.Failed, 0, ex.Message);
            return new TranscriptionResult(false, null, [], ex.Message);
        }
    }

    private WhisperFactory GetOrCreateFactory()
    {
        if (_factory is not null)
            return _factory;

        _factory = WhisperFactory.FromPath(_modelPath, new WhisperFactoryOptions
        {
            UseGpu = _deviceMode != "cpu",
            UseFlashAttention = _deviceMode != "cpu",
        });
        return _factory;
    }

    /// <summary>
    /// Runs Silero VAD over the audio and returns merged speech regions, or null when VAD is
    /// unavailable (model missing and not downloadable) — the caller then transcribes the whole buffer.
    /// </summary>
    private async Task<IReadOnlyList<(TimeSpan Start, TimeSpan End)>?> TryGetSpeechRegionsAsync(
        float[] pcm, CancellationToken ct)
    {
        try
        {
            var vadModelPath = await EnsureVadModelAsync(ct);
            if (vadModelPath is null) return null;

            _vadFactory ??= WhisperVadFactory.FromPath(vadModelPath);
            using var vad = _vadFactory.CreateBuilder()
                .WithThreshold(0.5f)
                .WithMinSpeechDuration(TimeSpan.FromMilliseconds(250))
                .WithMinSilenceDuration(TimeSpan.FromMilliseconds(1000))
                .WithSpeechPadding(TimeSpan.FromMilliseconds(250))
                .WithMaxSpeechDuration(TimeSpan.FromSeconds(28))
                .Build();

            var regions = await vad.DetectSpeechAsync(pcm, ct);
            return regions.Select(r => (r.Start, r.End)).ToList();
        }
        catch
        {
            // VAD is best-effort; on any failure fall back to whole-buffer transcription.
            return null;
        }
    }

    private static async Task<string?> EnsureVadModelAsync(CancellationToken ct)
    {
        var path = GgmlModelPaths.GetVadModelPath();
        if (File.Exists(path)) return path;

        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var tempPath = path + ".download";
            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
            await using (var src = await http.GetStreamAsync(GgmlModelPaths.VadModelUrl, ct))
            await using (var dst = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                await src.CopyToAsync(dst, ct);
            }
            if (File.Exists(path)) File.Delete(path);
            File.Move(tempPath, path);
            return path;
        }
        catch
        {
            return null;
        }
    }

    private async Task<List<(TimeSpan Start, TimeSpan End, string Text)>> TranscribeRegionsAsync(
        WhisperFactory factory, float[] pcm, IReadOnlyList<(TimeSpan Start, TimeSpan End)> regions,
        CancellationToken ct)
    {
        var rawSegments = new List<(TimeSpan Start, TimeSpan End, string Text)>();

        foreach (var region in regions)
        {
            ct.ThrowIfCancellationRequested();

            var startSample = Math.Clamp((int)(region.Start.TotalSeconds * 16000), 0, pcm.Length);
            var endSample = Math.Clamp((int)(region.End.TotalSeconds * 16000), startSample, pcm.Length);
            if (endSample <= startSample) continue;

            var chunk = pcm[startSample..endSample];

            try
            {
                using var processor = BuildProcessor(factory);
                await foreach (var segment in processor.ProcessAsync(chunk, ct))
                {
                    var text = segment.Text.Trim();
                    if (text.Length == 0) continue;
                    // Offset chunk-local timestamps back to absolute positions in the full audio.
                    rawSegments.Add((region.Start + segment.Start, region.Start + segment.End, text));
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // A single bad region shouldn't sink the whole transcription — log and continue
                // so the rest of the file (and everything decoded so far) is still saved.
                AppLogger.LogWarning(
                    $"WhisperNetTranscriptionService: region {region.Start}-{region.End} failed, skipping: {ex.Message}");
            }

            ReportSegmentProgress(region.End);
        }

        return rawSegments;
    }

    private WhisperProcessor BuildProcessor(WhisperFactory factory) => factory.CreateBuilder()
        .WithLanguage(_language)
        .WithGreedySamplingStrategy(s => s.WithBestOf(1))
        .WithNoContext()
        .Build();

    private async Task<List<(TimeSpan Start, TimeSpan End, string Text)>> TranscribeWholeAsync(
        WhisperProcessor processor, float[] pcm, CancellationToken ct)
    {
        var rawSegments = new List<(TimeSpan Start, TimeSpan End, string Text)>();

        await foreach (var segment in processor.ProcessAsync(pcm, ct))
        {
            var text = segment.Text.Trim();
            if (text.Length == 0) continue;
            rawSegments.Add((segment.Start, segment.End, text));
            ReportSegmentProgress(segment.End);
        }

        return rawSegments;
    }

    private void ReportSegmentProgress(TimeSpan processed)
    {
        var elapsed = DateTime.Now - _transcriptionStartTime;
        var totalSeconds = _audioDuration.TotalSeconds;
        var percent = totalSeconds > 0
            ? Math.Clamp((int)(processed.TotalSeconds / totalSeconds * 100), 0, 99)
            : 0;

        double? speed = elapsed.TotalSeconds > 0 ? processed.TotalSeconds / elapsed.TotalSeconds : null;
        TimeSpan? remaining = speed is > 0
            ? TimeSpan.FromSeconds((_audioDuration - processed).TotalSeconds / speed.Value)
            : null;

        var message = $"Transcribing {percent}% - {FormatTimeSpan(processed)} / {FormatTimeSpan(_audioDuration)}";
        RaiseProgress(TranscriptionState.Transcribing, percent, message, elapsed, remaining, processed, _audioDuration, speed);
    }

    private static string FormatTimeSpan(TimeSpan ts)
        => ts.TotalHours >= 1 ? ts.ToString(@"h\:mm\:ss") : ts.ToString(@"m\:ss");

    private static async Task<string> WriteTranscriptFileAsync(
        string audioPath, List<TranscriptionSegment> segments, CancellationToken ct)
    {
        var outputPath = Path.ChangeExtension(audioPath, ".txt");
        var sb = new StringBuilder();

        foreach (var segment in segments)
        {
            sb.AppendLine($"[{FormatTimestamp(segment.Start)} --> {FormatTimestamp(segment.End)}] [{segment.Speaker}]: {segment.Text}");
        }

        await File.WriteAllTextAsync(outputPath, sb.ToString(), Encoding.UTF8, ct);
        return outputPath;
    }

    private static string FormatTimestamp(TimeSpan ts)
        => $"{(int)ts.TotalHours:D2}:{ts.Minutes:D2}:{ts.Seconds:D2}.{ts.Milliseconds:D3}";

    private void RaiseProgress(TranscriptionState state, int percent, string? message,
        TimeSpan? elapsed = null, TimeSpan? remaining = null,
        TimeSpan? processed = null, TimeSpan? total = null, double? speed = null)
    {
        ProgressChanged?.Invoke(this, new TranscriptionProgress(
            state, percent, message, elapsed, remaining, processed, total, speed));
    }

    public void Dispose()
    {
        _factory?.Dispose();
        _factory = null;
        _vadFactory?.Dispose();
        _vadFactory = null;
        (_diarizationService as IDisposable)?.Dispose();
    }
}
