using AudioRecorder.Core.Models;

namespace AudioRecorder.Core.Services;

/// <summary>
/// Сервис диаризации: определяет спикеров по аудиобуферу, без распознавания текста.
/// </summary>
public interface IDiarizationService
{
    /// <summary>
    /// Определить сегменты речи по спикерам.
    /// </summary>
    /// <param name="pcm16kMono">Аудио как 16kHz mono float32 PCM (диапазон [-1, 1])</param>
    /// <param name="ct">Токен отмены</param>
    Task<List<DiarizationSegment>> DiarizeAsync(float[] pcm16kMono, CancellationToken ct = default);

    /// <summary>
    /// Доступны ли модели диаризации на диске.
    /// </summary>
    bool IsAvailable { get; }
}
