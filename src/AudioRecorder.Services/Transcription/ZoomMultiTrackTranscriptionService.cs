using System.Text;
using AudioRecorder.Core.Models;
using AudioRecorder.Core.Services;
using AudioRecorder.Services.Audio;
using AudioRecorder.Services.Integrations;
using AudioRecorder.Services.Logging;
using NAudio.Wave;

namespace AudioRecorder.Services.Transcription;

/// <summary>
/// Transcribes Zoom's isolated participant tracks without diarization and merges the timestamped
/// results. The mixed master is used only as the playback source and as an alignment reference.
/// </summary>
public sealed class ZoomMultiTrackTranscriptionService : ITranscriptionService, IDisposable
{
    private readonly ZoomMeetingRecording _recording;
    private readonly Func<ITranscriptionService> _transcriptionFactory;
    private readonly bool _isWhisperAvailable;
    private ITranscriptionService? _activeService;

    public ZoomMultiTrackTranscriptionService(
        ZoomMeetingRecording recording,
        Func<ITranscriptionService> transcriptionFactory,
        bool isWhisperAvailable)
    {
        _recording = recording;
        _transcriptionFactory = transcriptionFactory;
        _isWhisperAvailable = isWhisperAvailable;
    }

    public event EventHandler<TranscriptionProgress>? ProgressChanged;

    public bool IsWhisperAvailable => _isWhisperAvailable;

    public async Task<TranscriptionResult> TranscribeAsync(string audioPath, CancellationToken ct = default)
    {
        if (!File.Exists(_recording.MasterAudioPath))
            return new TranscriptionResult(false, null, [], "Zoom mixed audio file was not found.");
        if (_recording.SpeakerTracks.Count == 0)
            return new TranscriptionResult(false, null, [], "Zoom participant audio files were not found.");

        var offsets = await ResolveTrackOffsetsAsync(ct);
        var merged = new List<TranscriptionSegment>();
        var failures = new List<string>();
        var trackCount = _recording.SpeakerTracks.Count;

        for (var index = 0; index < trackCount; index++)
        {
            ct.ThrowIfCancellationRequested();
            var track = _recording.SpeakerTracks[index];
            var service = _transcriptionFactory();
            _activeService = service;

            void ForwardProgress(object? _, TranscriptionProgress progress)
            {
                var overall = Math.Clamp((index * 100 + progress.ProgressPercent) / trackCount, 0, 99);
                var processed = progress.TotalDuration is { TotalSeconds: > 0 }
                    ? TimeSpan.FromTicks((long)(progress.TotalDuration.Value.Ticks * overall / 100d))
                    : progress.ProcessedDuration;
                ProgressChanged?.Invoke(this, progress with
                {
                    ProgressPercent = overall,
                    StatusMessage = $"{track.SpeakerName}: {progress.StatusMessage}",
                    ProcessedDuration = processed,
                    TotalDuration = progress.TotalDuration
                });
            }

            service.ProgressChanged += ForwardProgress;
            try
            {
                var result = await service.TranscribeAsync(track.AudioPath, ct);
                if (!result.Success)
                {
                    failures.Add($"{track.SpeakerName}: {result.ErrorMessage}");
                    continue;
                }

                var offset = offsets.GetValueOrDefault(track.AudioPath, TimeSpan.Zero);
                merged.AddRange(result.Segments.Select(segment => new TranscriptionSegment(
                    ClampToZero(segment.Start + offset),
                    ClampToZero(segment.End + offset),
                    track.SpeakerName,
                    segment.Text)));
            }
            finally
            {
                service.ProgressChanged -= ForwardProgress;
                (service as IDisposable)?.Dispose();
                _activeService = null;
            }
        }

        merged = merged
            .Where(segment => !string.IsNullOrWhiteSpace(segment.Text))
            .OrderBy(segment => segment.Start)
            .ThenBy(segment => segment.End)
            .ToList();

        if (merged.Count == 0)
        {
            var details = failures.Count == 0 ? "No speech was detected." : string.Join(Environment.NewLine, failures);
            return new TranscriptionResult(false, null, [], details);
        }

        var outputPath = Path.Combine(_recording.FolderPath, "contora_transcript.txt");
        await WriteMergedTranscriptAsync(outputPath, merged, ct);

        var status = failures.Count == 0
            ? "Zoom transcription completed"
            : $"Zoom transcription completed; {failures.Count} track(s) failed";
        ProgressChanged?.Invoke(this, new TranscriptionProgress(
            TranscriptionState.Completed, 100, status));

        if (failures.Count > 0)
            AppLogger.LogWarning("Zoom multi-track partial failures: " + string.Join(" | ", failures));

        return new TranscriptionResult(true, outputPath, merged,
            failures.Count == 0 ? null : string.Join(Environment.NewLine, failures));
    }

    private async Task<Dictionary<string, TimeSpan>> ResolveTrackOffsetsAsync(CancellationToken ct)
    {
        var offsets = _recording.SpeakerTracks.ToDictionary(
            track => track.AudioPath,
            _ => TimeSpan.Zero,
            StringComparer.OrdinalIgnoreCase);

        var masterDuration = await TryGetDurationAsync(_recording.MasterAudioPath, ct);
        if (masterDuration is null)
            return offsets;

        float[]? masterEnvelope = null;
        foreach (var track in _recording.SpeakerTracks)
        {
            ct.ThrowIfCancellationRequested();
            var trackDuration = await TryGetDurationAsync(track.AudioPath, ct);
            if (trackDuration is null)
                continue;

            var difference = masterDuration.Value - trackDuration.Value;
            if (Math.Abs(difference.TotalSeconds) <= 2)
                continue; // Normal Zoom output: every file shares the recording's zero point.

            ProgressChanged?.Invoke(this, new TranscriptionProgress(
                TranscriptionState.Converting, 0,
                $"Checking timeline for {track.SpeakerName}..."));

            try
            {
                masterEnvelope ??= BuildEnergyEnvelope(
                    await AudioConverter.ToWhisperPcmAsync(_recording.MasterAudioPath, ct));
                var trackEnvelope = BuildEnergyEnvelope(
                    await AudioConverter.ToWhisperPcmAsync(track.AudioPath, ct));
                var estimated = EstimatePositiveOffset(masterEnvelope, trackEnvelope);
                if (estimated is not null)
                {
                    offsets[track.AudioPath] = estimated.Value;
                    AppLogger.LogInfo(
                        $"Zoom track aligned: {track.SpeakerName}, offset {estimated.Value:c}, " +
                        $"master {masterDuration.Value:c}, track {trackDuration.Value:c}");
                }
                else
                {
                    throw new InvalidDataException(
                        $"The Zoom track for {track.SpeakerName} has a different timeline and " +
                        "could not be aligned with the mixed recording safely.");
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                AppLogger.LogError($"Zoom track alignment failed for {track.SpeakerName}: {ex}");
                throw;
            }
        }

        return offsets;
    }

    private static async Task<TimeSpan?> TryGetDurationAsync(string path, CancellationToken ct)
    {
        try
        {
            return await Task.Run(() =>
            {
                ct.ThrowIfCancellationRequested();
                using var reader = new AudioFileReader(path);
                return reader.TotalTime;
            }, ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            AppLogger.LogWarning($"Could not read media duration for Zoom alignment: {path}: {ex.Message}");
            return null;
        }
    }

    // 250 ms RMS windows are enough to align speaking/silence patterns while keeping an hour-long
    // meeting below 15,000 values. This path runs only when container durations disagree.
    private static float[] BuildEnergyEnvelope(float[] pcm)
    {
        const int windowSamples = 4000;
        var envelope = new float[(pcm.Length + windowSamples - 1) / windowSamples];
        for (var window = 0; window < envelope.Length; window++)
        {
            var start = window * windowSamples;
            var end = Math.Min(start + windowSamples, pcm.Length);
            double sum = 0;
            for (var i = start; i < end; i++)
                sum += pcm[i] * pcm[i];
            envelope[window] = (float)Math.Log(1 + Math.Sqrt(sum / Math.Max(1, end - start)) * 1000);
        }
        return envelope;
    }

    private static TimeSpan? EstimatePositiveOffset(float[] master, float[] track)
    {
        if (track.Length < 8 || master.Length < track.Length)
            return null;

        var activeIndexes = Enumerable.Range(0, track.Length)
            .Where(index => track[index] > 0.05f)
            .OrderByDescending(index => track[index])
            .Take(240)
            .ToArray();
        if (activeIndexes.Length < 8)
            return null;

        var maxLag = master.Length - track.Length;
        var coarseStep = maxLag > 240 ? 2 : 1;
        var bestLag = 0;
        var bestScore = double.NegativeInfinity;

        for (var lag = 0; lag <= maxLag; lag += coarseStep)
        {
            var score = CosineScore(master, track, activeIndexes, lag);
            if (score > bestScore)
            {
                bestScore = score;
                bestLag = lag;
            }
        }

        var start = Math.Max(0, bestLag - coarseStep * 2);
        var end = Math.Min(maxLag, bestLag + coarseStep * 2);
        for (var lag = start; lag <= end; lag++)
        {
            var score = CosineScore(master, track, activeIndexes, lag);
            if (score > bestScore)
            {
                bestScore = score;
                bestLag = lag;
            }
        }

        return bestScore >= 0.45
            ? TimeSpan.FromMilliseconds(bestLag * 250d)
            : null;
    }

    private static double CosineScore(float[] master, float[] track, int[] indexes, int lag)
    {
        double dot = 0, masterNorm = 0, trackNorm = 0;
        foreach (var index in indexes)
        {
            var a = master[index + lag];
            var b = track[index];
            dot += a * b;
            masterNorm += a * a;
            trackNorm += b * b;
        }
        return masterNorm <= 0 || trackNorm <= 0
            ? 0
            : dot / Math.Sqrt(masterNorm * trackNorm);
    }

    private static async Task WriteMergedTranscriptAsync(
        string outputPath,
        IReadOnlyList<TranscriptionSegment> segments,
        CancellationToken ct)
    {
        var text = new StringBuilder();
        foreach (var segment in segments)
        {
            text.Append('[')
                .Append(FormatTimestamp(segment.Start))
                .Append(" --> ")
                .Append(FormatTimestamp(segment.End))
                .Append("] [")
                .Append(segment.Speaker)
                .Append("]: ")
                .AppendLine(segment.Text);
        }
        await File.WriteAllTextAsync(outputPath, text.ToString(), Encoding.UTF8, ct);
    }

    private static TimeSpan ClampToZero(TimeSpan value) => value < TimeSpan.Zero ? TimeSpan.Zero : value;

    private static string FormatTimestamp(TimeSpan value)
        => $"{(int)value.TotalHours:D2}:{value.Minutes:D2}:{value.Seconds:D2}.{value.Milliseconds:D3}";

    public void Dispose()
    {
        (_activeService as IDisposable)?.Dispose();
        _activeService = null;
    }
}
