using AudioRecorder.Core.Models;
using AudioRecorder.Core.Services;
using SherpaOnnx;

namespace AudioRecorder.Services.Transcription;

/// <summary>
/// Диаризация через sherpa-onnx: сегментация pyannote-3.0 + эмбеддинги CAM++ (3D-Speaker),
/// оба в ONNX — полностью in-process, без Python. Модели небольшие, кластеризация быстрая
/// даже на CPU (Provider="cpu" по умолчанию), GPU не требуется.
/// </summary>
public sealed class SherpaOnnxDiarizationService : IDiarizationService, IDisposable
{
    private readonly string _segmentationModelPath;
    private readonly string _embeddingModelPath;
    private OfflineSpeakerDiarization? _diarization;

    public SherpaOnnxDiarizationService(string segmentationModelPath, string embeddingModelPath)
    {
        _segmentationModelPath = segmentationModelPath;
        _embeddingModelPath = embeddingModelPath;
    }

    public bool IsAvailable => File.Exists(_segmentationModelPath) && File.Exists(_embeddingModelPath);

    public Task<List<DiarizationSegment>> DiarizeAsync(float[] pcm16kMono, CancellationToken ct = default)
    {
        return Task.Run(() =>
        {
            var diarization = GetOrCreateDiarization();
            var segments = diarization.Process(pcm16kMono);

            return segments
                .OrderBy(s => s.Start)
                .Select(s => new DiarizationSegment(
                    TimeSpan.FromSeconds(s.Start),
                    TimeSpan.FromSeconds(s.End),
                    $"SPEAKER_{s.Speaker:D2}"))
                .ToList();
        }, ct);
    }

    private OfflineSpeakerDiarization GetOrCreateDiarization()
    {
        if (_diarization is not null)
            return _diarization;

        var config = new OfflineSpeakerDiarizationConfig();
        config.Segmentation.Pyannote.Model = _segmentationModelPath;
        config.Embedding.Model = _embeddingModelPath;
        config.Clustering.NumClusters = -1; // число спикеров определяется автоматически.

        // Дефолтный Threshold=0.5 у sherpa-onnx сильно переоценивает число спикеров на записях
        // с короткими репликами/перебиванием (эмпирически: 3 реальных спикера -> 14 кластеров).
        // 0.95 — лучшее найденное эмпирически значение (даёт 5 вместо 14), но всё ещё не идеально:
        // это ограничение простой agglomerative-кластеризации по порогу, а не баг интеграции —
        // NumClusters=N (явно заданное) на тех же данных даёт корректный результат.
        // См. заметку про NeMo Sortformer как более точную альтернативу в будущем.
        config.Clustering.Threshold = 0.95f;

        _diarization = new OfflineSpeakerDiarization(config);
        return _diarization;
    }

    public void Dispose()
    {
        _diarization?.Dispose();
        _diarization = null;
    }
}
