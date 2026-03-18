using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using AudioRecorder.Core.Models;
using AudioRecorder.Core.Services;
using AudioRecorder.Services.Audio;

namespace AudioRecorder.Services.Transcription;

public partial class WhisperTranscriptionService : ITranscriptionService
{
    private readonly string _whisperPath;
    private readonly string _modelName;
    private readonly bool _enableDiarization;
    private readonly string _deviceMode; // "auto", "cuda", "cpu"
    private readonly DictatorSharedStoreService? _dictatorStore;
    private TimeSpan _audioDuration;
    private DateTime _transcriptionStartTime;
    private WhisperServerBackend? _serverBackend;

    public event EventHandler<TranscriptionProgress>? ProgressChanged;

    public bool IsWhisperAvailable => File.Exists(_whisperPath)
                                      || (_dictatorStore?.IsServerModel(_modelName) == true
                                          && _dictatorStore.IsPythonVenvAvailable());

    public WhisperTranscriptionService(
        string? whisperPath = null,
        string modelName = "large-v2",
        bool enableDiarization = true,
        string deviceMode = "auto",
        DictatorSharedStoreService? dictatorStore = null)
    {
        _whisperPath = whisperPath ?? WhisperPaths.GetDefaultWhisperPath();
        _modelName = modelName;
        _enableDiarization = enableDiarization;
        _deviceMode = deviceMode;
        _dictatorStore = dictatorStore;
    }
    public async Task<TranscriptionResult> TranscribeAsync(string audioPath, CancellationToken ct = default)
    {
        if (!File.Exists(audioPath))
        {
            return new TranscriptionResult(false, null, [], $"File not found: {audioPath}");
        }

        // ─── Route to Python ASR server (NeMo / transformers models from Dictator) ───
        if (_dictatorStore is not null)
        {
            var dictatorModel = _dictatorStore.GetInstalledModel(_modelName);
            if (dictatorModel is not null)
            {
                if (DictatorSharedStoreService.IsGgmlModel(dictatorModel))
                {
                    return new TranscriptionResult(false, null, [],
                        $"Модель «{_modelName}» — GGML-формат (только для Dictator).\n" +
                        "Для Contora скачайте Whisper-модель через Настройки → Models.");
                }

                // server_python_asr → NeMo / transformers
                return await TranscribeWithServerAsync(audioPath, dictatorModel, ct);
            }
            // Model not in Dictator store — fall through to faster-whisper-xxl below
        }

        if (!IsWhisperAvailable)
        {
            return new TranscriptionResult(false, null, [],
                $"Whisper runtime not found. Download faster-whisper-xxl and place it at:\n{_whisperPath}");
        }

        string? tempFilePath = null;
        string? tempOutputDir = null;

        var originalFileName = Path.GetFileNameWithoutExtension(audioPath);
        var originalDir = Path.GetDirectoryName(audioPath) ?? Path.GetTempPath();

        try
        {
            var processPath = audioPath;

            if (ContainsNonAscii(audioPath))
            {
                RaiseProgress(TranscriptionState.Converting, 0, "Copying file...");
                tempOutputDir = Path.Combine(Path.GetTempPath(), $"Contora_{Guid.NewGuid():N}");
                Directory.CreateDirectory(tempOutputDir);

                var safeFileName = $"audio_{DateTime.Now:yyyyMMdd_HHmmss}{Path.GetExtension(audioPath)}";
                tempFilePath = Path.Combine(tempOutputDir, safeFileName);
                File.Copy(audioPath, tempFilePath);
                processPath = tempFilePath;
            }

            if (AudioConverter.IsWavFile(processPath))
            {
                RaiseProgress(TranscriptionState.Converting, 0, "Converting to MP3...");
                var mp3Path = await AudioConverter.ConvertToMp3Async(processPath, deleteOriginal: tempFilePath != null);
                processPath = mp3Path;
                if (tempFilePath != null)
                    tempFilePath = mp3Path;
                RaiseProgress(TranscriptionState.Converting, 100, "Conversion completed");
            }

            _audioDuration = await GetAudioDurationAsync(processPath);
            _transcriptionStartTime = DateTime.Now;

            RaiseProgress(TranscriptionState.Transcribing, 0, "Starting Whisper...");

            var outputDir = tempOutputDir ?? originalDir;
            var result = await RunWhisperAsync(processPath, outputDir, originalFileName, originalDir, ct);

            if (result.Success && tempOutputDir != null && result.OutputPath != null)
            {
                var finalTxtPath = Path.Combine(originalDir, $"{originalFileName}.txt");
                File.Copy(result.OutputPath, finalTxtPath, overwrite: true);
                result = result with { OutputPath = finalTxtPath };
            }

            if (result.Success)
            {
                RaiseProgress(TranscriptionState.Completed, 100, "Transcription completed");
            }
            else
            {
                RaiseProgress(TranscriptionState.Failed, 0, result.ErrorMessage);
            }

            return result;
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
        finally
        {
            if (tempOutputDir != null)
            {
                try { Directory.Delete(tempOutputDir, recursive: true); } catch { }
            }
        }
    }

    // ─── Python ASR server backend (NeMo / transformers) ───

    private async Task<TranscriptionResult> TranscribeWithServerAsync(
        string audioPath, DictatorInstalledModel model, CancellationToken ct)
    {
        var pythonExe = _dictatorStore!.GetPythonVenvPath();
        if (pythonExe is null)
        {
            return new TranscriptionResult(false, null, [],
                $"Python venv не найден в AudioModels\\runtimes\\python-asr\\.\n" +
                "Установите Dictator и скачайте модель через его настройки.");
        }

        var scriptPath = WhisperServerBackend.FindScript();
        if (scriptPath is null)
        {
            return new TranscriptionResult(false, null, [],
                "whisper_server.py не найден. Переустановите Contora или Dictator.");
        }

        _serverBackend ??= new WhisperServerBackend(pythonExe, scriptPath);

        // Handle non-ASCII paths before sending to server
        string processPath = audioPath;
        string? tempDir = null;
        try
        {
            if (ContainsNonAscii(audioPath))
            {
                RaiseProgress(TranscriptionState.Converting, 0, "Copying file...");
                tempDir = Path.Combine(Path.GetTempPath(), $"Contora_{Guid.NewGuid():N}");
                Directory.CreateDirectory(tempDir);
                var safeName = $"audio_{DateTime.Now:yyyyMMdd_HHmmss}{Path.GetExtension(audioPath)}";
                processPath = Path.Combine(tempDir, safeName);
                File.Copy(audioPath, processPath);
            }

            // Server needs MP3/WAV — convert if WAV
            if (AudioConverter.IsWavFile(processPath))
            {
                RaiseProgress(TranscriptionState.Converting, 0, "Converting to MP3...");
                processPath = await AudioConverter.ConvertToMp3Async(processPath, deleteOriginal: tempDir != null);
            }

            _audioDuration = await GetAudioDurationAsync(processPath);

            var runtimeLabel = DictatorSharedStoreService.GetModelRuntimeLabel(model);
            RaiseProgress(TranscriptionState.Transcribing, 0, $"Запуск {model.Id} ({runtimeLabel})...");

            if (!await _serverBackend.StartAsync(model.DirectoryPath, model.Id, ct))
            {
                return new TranscriptionResult(false, null, [],
                    $"Не удалось запустить Python ASR сервер для модели «{model.Id}».\n" +
                    "Проверьте, что Python venv установлен корректно.");
            }

            RaiseProgress(TranscriptionState.Transcribing, 5, "Transcribing...");

            var language = "ru"; // TODO: from settings
            var (success, text, error) = await _serverBackend.TranscribeAsync(processPath, language, ct);

            if (!success)
                return new TranscriptionResult(false, null, [], error ?? "Server transcription failed");

            // Save result as .txt alongside original audio
            var originalFileName = Path.GetFileNameWithoutExtension(audioPath);
            var originalDir = Path.GetDirectoryName(audioPath) ?? Path.GetTempPath();
            var txtPath = Path.Combine(originalDir, $"{originalFileName}.txt");

            var durationStr = FormatTimeSpanForSegment(_audioDuration);
            var line = $"[00:00:00.000 --> {durationStr}] {text}";
            await File.WriteAllTextAsync(txtPath, line, System.Text.Encoding.UTF8, ct);

            var segments = new List<TranscriptionSegment>
            {
                new TranscriptionSegment(TimeSpan.Zero, _audioDuration, "SPEAKER_00", text)
            };

            RaiseProgress(TranscriptionState.Completed, 100, "Transcription completed");
            return new TranscriptionResult(true, txtPath, segments, null);
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
        finally
        {
            if (tempDir is not null)
                try { Directory.Delete(tempDir, recursive: true); } catch { }
        }
    }

    private static string FormatTimeSpanForSegment(TimeSpan ts)
        => $"{(int)ts.TotalHours:D2}:{ts.Minutes:D2}:{ts.Seconds:D2}.{ts.Milliseconds:D3}";

    private static bool ContainsNonAscii(string path)
    {
        return path.Any(c => c > 127);
    }

    private static async Task<TimeSpan> GetAudioDurationAsync(string audioPath)
    {
        try
        {
            return await Task.Run(() =>
            {
                using var reader = new NAudio.Wave.AudioFileReader(audioPath);
                return reader.TotalTime;
            });
        }
        catch
        {
            return TimeSpan.FromMinutes(5); // Fallback
        }
    }

    private async Task<TranscriptionResult> RunWhisperAsync(string audioPath, string outputDir, string outputFileName, string logDir, CancellationToken ct)
    {
        var arguments = BuildArguments(audioPath, outputDir);

        var logPath = Path.Combine(logDir, $"{outputFileName}_whisper.log");
        StreamWriter? logWriter = null;

        try
        {
            logWriter = new StreamWriter(logPath, append: false, Encoding.UTF8) { AutoFlush = true };
            logWriter.WriteLine($"=== Whisper Transcription Log ===");
            logWriter.WriteLine($"Time: {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
            logWriter.WriteLine($"Command: \"{_whisperPath}\" {arguments}");
            logWriter.WriteLine($"Audio: {audioPath}");
            logWriter.WriteLine($"Output: {outputDir}");
            logWriter.WriteLine($"=================================\n");
        }
        catch
        {
        }

        var psi = new ProcessStartInfo
        {
            FileName = _whisperPath,
            Arguments = arguments,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };

        using var process = new Process { StartInfo = psi };

        var errorLines = new System.Collections.Concurrent.ConcurrentQueue<string>();
        const int MaxErrorLines = 200; // Keep enough stderr lines for diagnostics.

        var outputComplete = new TaskCompletionSource<bool>();
        var errorComplete = new TaskCompletionSource<bool>();

        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data == null)
            {
                outputComplete.TrySetResult(true);
                return;
            }

            try { logWriter?.WriteLine($"[OUT] {e.Data}"); } catch { }

            ParseProgressFromOutput(e.Data);
        };

        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data == null)
            {
                errorComplete.TrySetResult(true);
                return;
            }

            try { logWriter?.WriteLine($"[ERR] {e.Data}"); } catch { }

            errorLines.Enqueue(e.Data);
            while (errorLines.Count > MaxErrorLines)
            {
                errorLines.TryDequeue(out string? _);
            }

            ParseProgressFromOutput(e.Data);
        };

        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        await process.WaitForExitAsync(ct);

        await Task.WhenAll(outputComplete.Task, errorComplete.Task).ConfigureAwait(false);

        try
        {
            logWriter?.WriteLine($"\n=================================");
            logWriter?.WriteLine($"Exit Code: {process.ExitCode}");
            logWriter?.WriteLine($"Completed: {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
            logWriter?.Dispose();
        }
        catch { }

        var whisperBaseName = Path.GetFileNameWithoutExtension(audioPath);
        var whisperTxtPath = Path.Combine(outputDir, $"{whisperBaseName}.txt");
        bool resultFileExists = File.Exists(whisperTxtPath);

        if (process.ExitCode != 0)
        {
            if (process.ExitCode == -1073740791 && resultFileExists)
            {
                System.Diagnostics.Debug.WriteLine($"[Whisper] Ignoring cleanup crash -1073740791, result file exists");
            }
            else
            {
                var rawError = string.Join(Environment.NewLine, errorLines);
                var friendlyError = TryGetFriendlyErrorMessage(rawError, _modelName)
                                    ?? (string.IsNullOrWhiteSpace(rawError)
                                        ? $"Whisper завершился с кодом {process.ExitCode}"
                                        : rawError);

                friendlyError += $"\n\nПолный лог сохранён:\n{logPath}";

                return new TranscriptionResult(false, null, [], friendlyError);
            }
        }

        if (!resultFileExists)
        {
            return new TranscriptionResult(false, null, [], "Transcription file was not created");
        }

        var finalTxtPath = Path.Combine(outputDir, $"{outputFileName}.txt");
        if (whisperTxtPath != finalTxtPath)
        {
            if (File.Exists(finalTxtPath))
                File.Delete(finalTxtPath);
            File.Move(whisperTxtPath, finalTxtPath);
        }

        var segments = await ParseTranscriptionFileAsync(finalTxtPath);

        return new TranscriptionResult(true, finalTxtPath, segments, null);
    }

    private string BuildArguments(string audioPath, string outputDir)
    {
        var sb = new StringBuilder();
        sb.Append("-pp ");                       // Explicit progress output.
        sb.Append($"-o \"{outputDir}\" ");
        sb.Append("--standard ");                // Standard output format.
        sb.Append("-f txt ");
        sb.Append($"-m {_modelName} ");

        // Device selection based on mode setting.
        if (_deviceMode == "cpu")
        {
            sb.Append("--device cpu --compute_type int8 ");
        }
        else if (_deviceMode == "cuda")
        {
            sb.Append("--device cuda ");
        }
        // "auto": let faster-whisper-xxl decide automatically.

        // Point faster-whisper-xxl to the directory containing model folders.
        var modelsRoot = WhisperPaths.GetModelsRoot(_whisperPath);
        if (Directory.Exists(modelsRoot))
        {
            sb.Append($"--model_dir \"{modelsRoot}\" ");
        }

        if (_enableDiarization)
        {
            sb.Append("--diarize pyannote_v3.1 ");
        }
        sb.Append($"\"{audioPath}\"");
        return sb.ToString();
    }

    private void ParseProgressFromOutput(string line)
    {
        // "  1% |   35/4423 | 00:01<<02:22 | 30.73 audio seconds/s"

        var elapsed = DateTime.Now - _transcriptionStartTime;

        var fullProgressMatch = FullProgressRegex().Match(line);
        if (fullProgressMatch.Success)
        {
            if (!int.TryParse(fullProgressMatch.Groups[1].Value, out var percent))
                return;

            var elapsedStr = fullProgressMatch.Groups[2].Value;
            var elapsedTime = ParseTimeSpanShort(elapsedStr);

            var remainingStr = fullProgressMatch.Groups[3].Value;
            var remainingTime = ParseTimeSpanShort(remainingStr);

            double? speed = null;
            if (double.TryParse(fullProgressMatch.Groups[4].Value.Replace(',', '.'),
                System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture,
                out var parsedSpeed))
            {
                speed = parsedSpeed;
            }

            var message = BuildProgressMessage(percent, elapsedTime, remainingTime, null, _audioDuration, speed);
            RaiseProgress(TranscriptionState.Transcribing, percent, message, elapsedTime, remainingTime, null, _audioDuration, speed);
            return;
        }

        double? fallbackSpeed = null;
        var speedMatch = SpeedRegex().Match(line);
        if (speedMatch.Success && double.TryParse(speedMatch.Groups[1].Value.Replace(',', '.'),
            System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture,
            out var parsedFallbackSpeed))
        {
            fallbackSpeed = parsedFallbackSpeed;
        }

        var percentMatch = PercentRegex().Match(line);
        if (percentMatch.Success && double.TryParse(percentMatch.Groups[1].Value.Replace(',', '.'),
            System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture,
            out var fallbackPercent))
        {
            var intPercent = (int)Math.Round(fallbackPercent);
            var remaining = intPercent > 0
                ? TimeSpan.FromSeconds(elapsed.TotalSeconds * (100 - intPercent) / intPercent)
                : TimeSpan.Zero;

            var message = BuildProgressMessage(intPercent, elapsed, remaining, null, _audioDuration, fallbackSpeed);

            RaiseProgress(TranscriptionState.Transcribing, intPercent, message, elapsed, remaining, null, _audioDuration, fallbackSpeed);
            return;
        }
    }

    private static TimeSpan ParseTimeSpanShort(string time)
    {
        var parts = time.Split(':');
        if (parts.Length == 2 && int.TryParse(parts[0], out var minutes) && int.TryParse(parts[1], out var seconds))
        {
            return TimeSpan.FromMinutes(minutes) + TimeSpan.FromSeconds(seconds);
        }
        return TimeSpan.Zero;
    }

    private static string BuildProgressMessage(int percent, TimeSpan elapsed, TimeSpan remaining, TimeSpan? processed, TimeSpan? total, double? speed)
    {
        if (processed.HasValue && total.HasValue)
        {
            return $"Transcribing {percent}% - {FormatTimeSpan(processed.Value)} / {FormatTimeSpan(total.Value)}";
        }

        return $"Transcribing {percent}%";
    }

    private static string FormatTimeSpan(TimeSpan ts)
    {
        if (ts.TotalHours >= 1)
            return ts.ToString(@"h\:mm\:ss");
        return ts.ToString(@"m\:ss");
    }

    private static async Task<List<TranscriptionSegment>> ParseTranscriptionFileAsync(string txtPath)
    {
        var segments = new List<TranscriptionSegment>();

        var lines = await File.ReadAllLinesAsync(txtPath, Encoding.UTF8);

        var regex = SegmentRegex();

        TimeSpan currentStart = TimeSpan.Zero;
        TimeSpan currentEnd = TimeSpan.Zero;
        string currentSpeaker = "SPEAKER_00";
        var currentText = new StringBuilder();
        bool hasValidSegment = false;

        void AddCurrentSegment()
        {
            var text = currentText.ToString().Trim();
            if (!string.IsNullOrWhiteSpace(text) && hasValidSegment)
            {
                segments.Add(new TranscriptionSegment(currentStart, currentEnd, currentSpeaker, text));
            }
            currentText.Clear();
            hasValidSegment = false;
        }

        int lineNum = 0;
        foreach (var rawLine in lines)
        {
            lineNum++;
            var line = rawLine.Trim('\uFEFF', '\u200B', '\u200C', '\u200D');

            if (string.IsNullOrWhiteSpace(line))
                continue;

            var match = regex.Match(line);
            if (match.Success)
            {
                AddCurrentSegment();

                var startStr = match.Groups[1].Value;
                var endStr = match.Groups[2].Value;
                currentStart = ParseTimeSpan(startStr);
                currentEnd = ParseTimeSpan(endStr);
                currentSpeaker = match.Groups[3].Success ? match.Groups[3].Value : "SPEAKER_00";
                currentText.Append(match.Groups[4].Value.Trim());
                hasValidSegment = true;

                if (currentStart == TimeSpan.Zero && currentEnd == TimeSpan.Zero)
                {
                    System.Diagnostics.Debug.WriteLine($"[ParseTranscription] Line {lineNum}: Failed to parse timestamps: '{startStr}' --> '{endStr}'");
                }
            }
            else
            {
                if (hasValidSegment)
                {
                    if (currentText.Length > 0)
                        currentText.Append(' '); // Insert a space between merged lines.
                    currentText.Append(line.Trim());
                }
                else
                {
                    System.Diagnostics.Debug.WriteLine($"[ParseTranscription] Line {lineNum}: Skipping orphan line: '{line.Substring(0, Math.Min(50, line.Length))}'");
                }
            }
        }

        AddCurrentSegment();

        System.Diagnostics.Debug.WriteLine($"[ParseTranscription] Total segments parsed: {segments.Count} from {lineNum} lines");

        return segments;
    }

    private static TimeSpan ParseTimeSpan(string time)
    {
        if (string.IsNullOrWhiteSpace(time))
        {
            System.Diagnostics.Debug.WriteLine($"[ParseTimeSpan] Empty time string");
            return TimeSpan.Zero;
        }

        var originalTime = time;
        time = time.Trim().Replace(',', '.');

        var parts = time.Split('.');
        if (parts.Length == 2)
        {
            var timePart = parts[0];
            var colonCount = timePart.Count(c => c == ':');
            if (colonCount == 1)
            {
                time = "00:" + time;
            }
        }

        if (TimeSpan.TryParse(time, System.Globalization.CultureInfo.InvariantCulture, out var result))
        {
            return result;
        }

        System.Diagnostics.Debug.WriteLine($"[ParseTimeSpan] Failed to parse: '{originalTime}' (normalized: '{time}')");
        return TimeSpan.Zero;
    }

    private void RaiseProgress(TranscriptionState state, int percent, string? message,
        TimeSpan? elapsed = null, TimeSpan? remaining = null,
        TimeSpan? processed = null, TimeSpan? total = null, double? speed = null)
    {
        ProgressChanged?.Invoke(this, new TranscriptionProgress(
            state, percent, message, elapsed, remaining, processed, total, speed));
    }

    private static string? TryGetFriendlyErrorMessage(string rawError, string modelName)
    {
        if (rawError.Contains("mkl_malloc: failed to allocate memory", StringComparison.OrdinalIgnoreCase) ||
            rawError.Contains("failed to allocate memory", StringComparison.OrdinalIgnoreCase))
        {
            return $"Недостаточно памяти для загрузки модели «{modelName}».\n\n" +
                   "Что делать:\n" +
                   "• Откройте Настройки → Models и выберите модель меньшего размера (например, «small» или «tiny»)\n" +
                   "• Или переключитесь на CPU-режим: Настройки → General → Device mode → CPU";
        }

        if (rawError.Contains("CUDA out of memory", StringComparison.OrdinalIgnoreCase) ||
            rawError.Contains("out of memory", StringComparison.OrdinalIgnoreCase) && rawError.Contains("CUDA"))
        {
            return $"Видеопамяти недостаточно для модели «{modelName}».\n\n" +
                   "Что делать:\n" +
                   "• Откройте Настройки → Models и выберите меньшую модель\n" +
                   "• Или переключитесь на CPU-режим: Настройки → General → Device mode → CPU";
        }

        if (rawError.Contains("No CUDA GPUs are available", StringComparison.OrdinalIgnoreCase) ||
            rawError.Contains("CUDA failed", StringComparison.OrdinalIgnoreCase) ||
            rawError.Contains("nvml", StringComparison.OrdinalIgnoreCase) && rawError.Contains("error", StringComparison.OrdinalIgnoreCase))
        {
            return "GPU не поддерживает CUDA или видеодрайвер устарел.\n\n" +
                   "Что делать:\n" +
                   "• Переключитесь на CPU-режим: Настройки → General → Device mode → CPU\n" +
                   "• Выберите модель small или tiny для приемлемой скорости на CPU";
        }

        if (rawError.Contains("model.bin", StringComparison.OrdinalIgnoreCase) &&
            rawError.Contains("No such file", StringComparison.OrdinalIgnoreCase))
        {
            return $"Модель «{modelName}» не установлена.\n\n" +
                   "Что делать:\n" +
                   "• Откройте Настройки → Models → Download model и скачайте нужную модель";
        }

        if (rawError.Contains("faster-whisper-xxl.exe", StringComparison.OrdinalIgnoreCase) &&
            rawError.Contains("not found", StringComparison.OrdinalIgnoreCase))
        {
            return "Faster Whisper XXL не установлен.\n\n" +
                   "Что делать:\n" +
                   "• Откройте Настройки → Engines → Download runtime";
        }

        return null;
    }

    // "  1% |   35/4423 | 00:01<<02:22 | 30.73 audio seconds/s"
    [GeneratedRegex(@"^\s*(\d+)%\s*\|.*?\|\s*(\d{2}:\d{2})<<(\d{2}:\d{2})\s*\|\s*([\d.,]+)\s+audio seconds")]
    private static partial Regex FullProgressRegex();

    [GeneratedRegex(@"(\d+(?:[.,]\d+)?)%")]
    private static partial Regex PercentRegex();

    [GeneratedRegex(@"\[(\d{2}:\d{2}:\d{2})")]
    private static partial Regex TimeRegex();

    [GeneratedRegex(@"(\d+(?:[.,]\d+)?)\s*x")]
    private static partial Regex SpeedRegex();

    [GeneratedRegex(@"^\s*\[(\d{2}:\d{2}(?::\d{2})?[.,]\d{3})\s*-->\s*(\d{2}:\d{2}(?::\d{2})?[.,]\d{3})\]\s*(?:\[([^\]]+)\])?\s*:?\s*(.*)$")]
    private static partial Regex SegmentRegex();
}


