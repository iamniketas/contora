namespace AudioRecorder.Services.Transcription;

/// <summary>
/// Пути к моделям диаризации (sherpa-onnx: pyannote-segmentation-3.0 + CAM++).
/// Не зависят от выбора Whisper-модели — скачиваются один раз и используются для любого размера.
/// Хранятся в общей с Dictator папке AudioModels, т.к. движок-агностичны.
/// </summary>
public static class DiarizationModelPaths
{
    private const string SegmentationFileName = "sherpa-onnx-pyannote-segmentation-3-0.onnx";
    private const string EmbeddingFileName = "campplus-3dspeaker-zh-en.onnx";

    public static string GetDiarizationModelsRoot()
        => Path.Combine(WhisperPaths.GetSharedModelsRootOrDefault(), "diarization");

    public static string GetSegmentationModelPath(string root) => Path.Combine(root, SegmentationFileName);

    public static string GetEmbeddingModelPath(string root) => Path.Combine(root, EmbeddingFileName);

    public static bool IsInstalled(string root)
        => File.Exists(GetSegmentationModelPath(root)) && File.Exists(GetEmbeddingModelPath(root));
}
