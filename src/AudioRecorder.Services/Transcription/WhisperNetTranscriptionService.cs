using System.Text;
using AudioRecorder.Core.Models;
using AudioRecorder.Core.Services;
using AudioRecorder.Services.Audio;
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

    private WhisperFactory? _factory;
    private TimeSpan _audioDuration;
    private DateTime _transcriptionStartTime;

    public event EventHandler<TranscriptionProgress>? ProgressChanged;

    public bool IsWhisperAvailable => File.Exists(_modelPath);

    public WhisperNetTranscriptionService(
        string modelPath,
        bool enableDiarization = true,
        string deviceMode = "auto",
        IDiarizationService? diarizationService = null,
        string language = "ru")
    {
        _modelPath = modelPath;
        _enableDiarization = enableDiarization;
        _deviceMode = deviceMode;
        _diarizationService = diarizationService;
        _language = language;
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
            using var processor = factory.CreateBuilder()
                .WithLanguage(_language)
                .WithGreedySamplingStrategy(s => s.WithBestOf(1))
                .WithNoContext()
                .Build();

            var rawSegments = new List<(TimeSpan Start, TimeSpan End, string Text)>();

            await foreach (var segment in processor.ProcessAsync(pcm, ct))
            {
                rawSegments.Add((segment.Start, segment.End, segment.Text.Trim()));
                ReportSegmentProgress(segment.End);
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
    }
}
