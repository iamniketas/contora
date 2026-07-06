using NAudio.Lame;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using AudioRecorder.Services.Transcription;
using System.Diagnostics;

namespace AudioRecorder.Services.Audio;

/// <summary>
/// Конвертер аудиофайлов
/// </summary>
public static class AudioConverter
{
    private static readonly HashSet<string> VideoExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".mp4", ".m4v", ".mov", ".avi", ".mkv", ".webm", ".wmv"
    };

    /// <summary>
    /// Конвертировать WAV в MP3
    /// </summary>
    /// <param name="wavPath">Путь к WAV файлу</param>
    /// <param name="bitrate">Битрейт MP3 (по умолчанию 192 kbps)</param>
    /// <param name="deleteOriginal">Удалить исходный WAV после конвертации</param>
    /// <returns>Путь к MP3 файлу</returns>
    public static async Task<string> ConvertToMp3Async(
        string wavPath,
        int bitrate = 192,
        bool deleteOriginal = true)
    {
        if (!File.Exists(wavPath))
            throw new FileNotFoundException("WAV файл не найден", wavPath);

        var mp3Path = Path.ChangeExtension(wavPath, ".mp3");

        await Task.Run(() =>
        {
            using var reader = new WaveFileReader(wavPath);
            using var writer = new LameMP3FileWriter(mp3Path, reader.WaveFormat, bitrate);
            reader.CopyTo(writer);
        });

        if (deleteOriginal && File.Exists(mp3Path))
        {
            File.Delete(wavPath);
        }

        return mp3Path;
    }

    /// <summary>
    /// Декодирует любой поддерживаемый аудиофайл (wav/mp3/...) в 16kHz mono float32 PCM
    /// для скармливания Whisper.net (whisper.cpp ожидает ровно такой формат).
    /// Не влияет на хранение записей (WAV→MP3 конвертация для диска) — это отдельный шаг только для ASR.
    /// </summary>
    public static async Task<float[]> ToWhisperPcmAsync(string audioPath, CancellationToken ct = default)
    {
        if (!File.Exists(audioPath))
            throw new FileNotFoundException("Аудиофайл не найден", audioPath);

        return await Task.Run(() =>
        {
            using var reader = new AudioFileReader(audioPath);
            var channels = reader.WaveFormat.Channels;

            ISampleProvider sampleProvider = reader;
            if (reader.WaveFormat.SampleRate != 16000)
                sampleProvider = new WdlResamplingSampleProvider(sampleProvider, 16000);

            var interleaved = ReadAllSamples(sampleProvider, ct);
            return channels <= 1 ? interleaved : DownmixToMono(interleaved, channels);
        }, ct);
    }

    private static float[] ReadAllSamples(ISampleProvider sampleProvider, CancellationToken ct)
    {
        var chunks = new List<float[]>();
        var totalRead = 0;
        var buffer = new float[16000 * sampleProvider.WaveFormat.Channels];

        int samplesRead;
        while ((samplesRead = sampleProvider.Read(buffer, 0, buffer.Length)) > 0)
        {
            ct.ThrowIfCancellationRequested();
            var chunk = new float[samplesRead];
            Array.Copy(buffer, chunk, samplesRead);
            chunks.Add(chunk);
            totalRead += samplesRead;
        }

        var result = new float[totalRead];
        var offset = 0;
        foreach (var chunk in chunks)
        {
            Array.Copy(chunk, 0, result, offset, chunk.Length);
            offset += chunk.Length;
        }
        return result;
    }

    private static float[] DownmixToMono(float[] interleaved, int channels)
    {
        var mono = new float[interleaved.Length / channels];
        for (var i = 0; i < mono.Length; i++)
        {
            float sum = 0f;
            for (var c = 0; c < channels; c++)
                sum += interleaved[(i * channels) + c];
            mono[i] = sum / channels;
        }
        return mono;
    }

    /// <summary>
    /// Проверить, является ли файл WAV
    /// </summary>
    public static bool IsWavFile(string path)
    {
        return Path.GetExtension(path).Equals(".wav", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Проверить, является ли файл MP3
    /// </summary>
    public static bool IsMp3File(string path)
    {
        return Path.GetExtension(path).Equals(".mp3", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Проверить, является ли файл видео
    /// </summary>
    public static bool IsVideoFile(string path)
    {
        var ext = Path.GetExtension(path);
        return !string.IsNullOrWhiteSpace(ext) && VideoExtensions.Contains(ext);
    }

    /// <summary>
    /// Извлечь аудио-дорожку из медиафайла в MP3 через ffmpeg.
    /// </summary>
    public static async Task<string> ExtractAudioToMp3Async(
        string inputPath,
        int bitrateKbps = 192,
        CancellationToken ct = default)
    {
        if (!File.Exists(inputPath))
            throw new FileNotFoundException("Файл не найден", inputPath);

        var outputPath = BuildUniqueOutputPath(inputPath, ".mp3");
        var ffmpegExe = ResolveFfmpegExecutablePath();

        var args = $"-y -i \"{inputPath}\" -vn -acodec libmp3lame -b:a {bitrateKbps}k \"{outputPath}\"";
        var psi = new ProcessStartInfo
        {
            FileName = ffmpegExe,
            Arguments = args,
            UseShellExecute = false,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            CreateNoWindow = true
        };

        using var process = new Process { StartInfo = psi };
        process.Start();

        var stdOutTask = process.StandardOutput.ReadToEndAsync();
        var stdErrTask = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync(ct);

        var stdOut = await stdOutTask;
        var stdErr = await stdErrTask;

        if (process.ExitCode != 0 || !File.Exists(outputPath))
        {
            var details = string.IsNullOrWhiteSpace(stdErr) ? stdOut : stdErr;
            throw new InvalidOperationException(
                $"Не удалось извлечь аудио из видео через ffmpeg (код {process.ExitCode}). {details}".Trim());
        }

        return outputPath;
    }

    private static string ResolveFfmpegExecutablePath()
    {
        var envPath = Environment.GetEnvironmentVariable("CONTORA_FFMPEG_EXE");
        if (!string.IsNullOrWhiteSpace(envPath) && File.Exists(envPath))
            return envPath;

        // Canonical Contora runtime path (%LOCALAPPDATA%\Contora\runtime\ffmpeg\ffmpeg.exe).
        var canonicalPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Contora", "runtime", "ffmpeg", "ffmpeg.exe");
        if (File.Exists(canonicalPath))
            return canonicalPath;

        // Runtime from Faster-Whisper-XXL commonly keeps ffmpeg.exe next to faster-whisper-xxl.exe.
        var whisperPath = WhisperPaths.GetDefaultWhisperPath();
        var whisperDir = Path.GetDirectoryName(whisperPath);
        if (!string.IsNullOrWhiteSpace(whisperDir))
        {
            var bundled = Path.Combine(whisperDir, "ffmpeg.exe");
            if (File.Exists(bundled))
                return bundled;
        }

        var appBundled = Path.Combine(AppContext.BaseDirectory, "ffmpeg.exe");
        if (File.Exists(appBundled))
            return appBundled;

        // Fallback to PATH.
        return "ffmpeg";
    }

    private static string BuildUniqueOutputPath(string sourcePath, string newExtension)
    {
        var directory = Path.GetDirectoryName(sourcePath) ?? Environment.CurrentDirectory;
        var fileName = Path.GetFileNameWithoutExtension(sourcePath);
        var candidate = Path.Combine(directory, fileName + newExtension);

        if (!File.Exists(candidate))
            return candidate;

        var suffix = DateTime.Now.ToString("yyyyMMdd_HHmmss");
        return Path.Combine(directory, $"{fileName}_{suffix}{newExtension}");
    }
}
