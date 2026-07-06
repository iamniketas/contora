namespace AudioRecorder.Core.Models;

/// <summary>
/// Сегмент диаризации: временной отрезок с меткой спикера, без текста.
/// </summary>
public record DiarizationSegment(
    TimeSpan Start,
    TimeSpan End,
    string Speaker
);
