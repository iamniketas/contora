namespace AudioRecorder.Core.Models;

/// <summary>
/// Движок транскрипции, выбираемый пользователем в настройках.
/// </summary>
public enum TranscriptionEngineKind
{
    /// <summary>Whisper.net (in-process whisper.cpp, CUDA/greedy/no-context).</summary>
    WhisperNet,

    /// <summary>faster-whisper-xxl.exe как отдельный процесс (прежний движок).</summary>
    LegacyFasterWhisperXxl
}
