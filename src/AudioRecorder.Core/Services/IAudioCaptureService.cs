using AudioRecorder.Core.Models;

namespace AudioRecorder.Core.Services;

/// <summary>
/// Сервис для записи аудио из разных источников
/// </summary>
public interface IAudioCaptureService
{
    /// <summary>
    /// Получить список доступных источников аудио
    /// </summary>
    Task<IReadOnlyList<AudioSource>> GetAvailableSourcesAsync();

    /// <summary>
    /// Начать запись из одного или нескольких источников
    /// </summary>
    /// <param name="sources">Список источников аудио для записи</param>
    /// <param name="outputPath">Путь для сохранения файла</param>
    Task StartRecordingAsync(IReadOnlyList<AudioSource> sources, string outputPath);

    /// <summary>
    /// Остановить запись
    /// </summary>
    Task StopRecordingAsync();

    /// <summary>
    /// Приостановить запись
    /// </summary>
    Task PauseRecordingAsync();

    /// <summary>
    /// Возобновить запись
    /// </summary>
    Task ResumeRecordingAsync();

    /// <summary>
    /// Получить текущее состояние записи
    /// </summary>
    RecordingInfo GetCurrentRecordingInfo();

    /// <summary>
    /// Событие изменения состояния записи
    /// </summary>
    event EventHandler<RecordingInfo>? RecordingStateChanged;

    /// <summary>
    /// Fires when the OS audio device list changes (device added, removed, or default changed).
    /// </summary>
    event EventHandler? DeviceListChanged;
}
