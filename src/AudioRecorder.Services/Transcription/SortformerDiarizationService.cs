using AudioRecorder.Core.Models;
using AudioRecorder.Core.Services;
using NAudio.Wave;

namespace AudioRecorder.Services.Transcription;

/// <summary>
/// Диаризация через NVIDIA NeMo Sortformer (streaming, до 4 спикеров) — заметно точнее
/// автоматического определения числа спикеров у sherpa-onnx (эмпирически: 4 против 3 реальных
/// на тестовой записи, вместо 14 у sherpa-onnx с порогом по умолчанию), но требует Python
/// (переиспользует общий python-asr venv Dictator, уже используемый для Parakeet ASR).
/// Используется как основной бэкенд, когда Python venv доступен; иначе — фолбэк на sherpa-onnx.
/// </summary>
public sealed class SortformerDiarizationService : IDiarizationService, IDisposable
{
    private readonly string _pythonExe;
    private readonly string _scriptPath;
    private DiarizationServerBackend? _serverBackend;

    public SortformerDiarizationService(string pythonExe, string scriptPath)
    {
        _pythonExe = pythonExe;
        _scriptPath = scriptPath;
    }

    public bool IsAvailable => File.Exists(_pythonExe) && File.Exists(_scriptPath);

    public async Task<List<DiarizationSegment>> DiarizeAsync(float[] pcm16kMono, CancellationToken ct = default)
    {
        _serverBackend ??= new DiarizationServerBackend(_pythonExe, _scriptPath);

        if (!await _serverBackend.StartAsync(ct))
            throw new InvalidOperationException("Не удалось запустить Sortformer diarization server.");

        var tempWavPath = Path.Combine(Path.GetTempPath(), $"Contora_diar_{Guid.NewGuid():N}.wav");
        try
        {
            WritePcmToWav(pcm16kMono, tempWavPath);

            var (success, segments, error) = await _serverBackend.DiarizeAsync(tempWavPath, ct);
            if (!success)
                throw new InvalidOperationException(error ?? "Sortformer diarization failed");

            return segments
                .OrderBy(s => s.Start)
                .Select(s => new DiarizationSegment(
                    TimeSpan.FromSeconds(s.Start),
                    TimeSpan.FromSeconds(s.End),
                    NormalizeSpeakerLabel(s.Speaker)))
                .ToList();
        }
        finally
        {
            try { File.Delete(tempWavPath); } catch { }
        }
    }

    // "speaker_0" -> "SPEAKER_00" — совпадает с конвенцией отображения, общей со старым движком.
    private static string NormalizeSpeakerLabel(string sortformerLabel)
    {
        var digits = new string(sortformerLabel.Where(char.IsDigit).ToArray());
        return int.TryParse(digits, out var index) ? $"SPEAKER_{index:D2}" : sortformerLabel;
    }

    private static void WritePcmToWav(float[] pcm, string path)
    {
        var format = WaveFormat.CreateIeeeFloatWaveFormat(16000, 1);
        using var writer = new WaveFileWriter(path, format);
        writer.WriteSamples(pcm, 0, pcm.Length);
    }

    public void Dispose()
    {
        _serverBackend?.Dispose();
        _serverBackend = null;
    }
}
