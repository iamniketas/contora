using AudioRecorder.Core.Models;

namespace AudioRecorder.Services.Transcription;

/// <summary>
/// Совмещает ASR-сегменты (текст+тайминги от Whisper.net) с сегментами диаризации
/// (спикер+тайминги от sherpa-onnx) по принципу majority-overlap — как в WhisperX:
/// границы сегментов задаёт ASR, диаризация только навешивает метку спикера.
/// </summary>
public static class TranscriptionDiarizationMerger
{
    private const string DefaultSpeaker = "SPEAKER_00";

    public static List<TranscriptionSegment> Merge(
        IReadOnlyList<(TimeSpan Start, TimeSpan End, string Text)> asrSegments,
        IReadOnlyList<DiarizationSegment>? diarizationSegments)
    {
        var result = new List<TranscriptionSegment>(asrSegments.Count);

        if (diarizationSegments is null || diarizationSegments.Count == 0)
        {
            foreach (var asr in asrSegments)
                result.Add(new TranscriptionSegment(asr.Start, asr.End, DefaultSpeaker, asr.Text));
            return result;
        }

        string? previousSpeaker = null;

        foreach (var asr in asrSegments)
        {
            var speaker = AssignSpeaker(asr.Start, asr.End, diarizationSegments, previousSpeaker);
            result.Add(new TranscriptionSegment(asr.Start, asr.End, speaker, asr.Text));
            previousSpeaker = speaker;
        }

        return result;
    }

    private static string AssignSpeaker(
        TimeSpan asrStart, TimeSpan asrEnd,
        IReadOnlyList<DiarizationSegment> diarizationSegments,
        string? previousSpeaker)
    {
        string? bestSpeaker = null;
        var bestOverlap = TimeSpan.Zero;

        foreach (var d in diarizationSegments)
        {
            var overlapStart = asrStart > d.Start ? asrStart : d.Start;
            var overlapEnd = asrEnd < d.End ? asrEnd : d.End;
            var overlap = overlapEnd - overlapStart;

            if (overlap > bestOverlap)
            {
                bestOverlap = overlap;
                bestSpeaker = d.Speaker;
            }
        }

        if (bestSpeaker is not null)
            return bestSpeaker;

        // Нет пересечения (пауза/edge case) — ближайший по midpoint, иначе продолжаем спикера предыдущего сегмента.
        var asrMidpoint = asrStart + TimeSpan.FromTicks((asrEnd - asrStart).Ticks / 2);
        var nearest = diarizationSegments
            .OrderBy(d => Distance(asrMidpoint, d))
            .FirstOrDefault();

        return nearest?.Speaker ?? previousSpeaker ?? DefaultSpeaker;
    }

    private static TimeSpan Distance(TimeSpan point, DiarizationSegment segment)
    {
        if (point < segment.Start) return segment.Start - point;
        if (point > segment.End) return point - segment.End;
        return TimeSpan.Zero;
    }
}
