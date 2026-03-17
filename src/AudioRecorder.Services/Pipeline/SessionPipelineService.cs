using AudioRecorder.Core.Models;
using AudioRecorder.Core.Services;
using AudioRecorder.Services.Logging;
using System.Net.Sockets;
using System.Text;

namespace AudioRecorder.Services.Pipeline;

public sealed class SessionPipelineService : ISessionPipelineService
{
    private const string DefaultSystemPrompt =
        "Сделай структурированную выжимку беседы: ключевые темы, эмоции, инсайты, договоренности и next steps. " +
        "Пиши кратко, без воды, только факты из текста.";

    private readonly SessionPipelineOptions _options;
    private readonly OllamaClient _ollamaClient;

    public SessionPipelineService()
    {
        _options = SessionPipelineOptions.LoadOrDefault();
        _ollamaClient = new OllamaClient(_options);
    }

    public async Task<SessionPipelineResult> ProcessSessionAsync(
        string rawWhisperText,
        string? transcriptionPath,
        CancellationToken ct = default)
    {
        var cleanedText = TextProcessor.Clean(rawWhisperText);
        if (string.IsNullOrWhiteSpace(cleanedText))
        {
            return new SessionPipelineResult(
                Success: false,
                CleanedText: string.Empty,
                SummaryText: null,
                GeneratedTitle: null,
                TargetPath: string.Empty,
                UsedBackup: false,
                ErrorMessage: "Cleaned transcript is empty.");
        }

        var outputDir = ResolveOutputDirectory(transcriptionPath);
        var masterPath = Path.Combine(outputDir, _options.MasterFileName);
        var backupPath = Path.Combine(outputDir, _options.BackupFileName);
        var systemPrompt = await LoadSystemPromptAsync(ct);

        // Title generation runs in parallel (best-effort, never throws)
        var titleTask = _ollamaClient.GenerateTitleAsync(cleanedText, ct);

        try
        {
            var summary = await _ollamaClient.GenerateSummaryAsync(systemPrompt, cleanedText, ct);
            var generatedTitle = await titleTask;
            await AppendSessionAsync(masterPath, summary, ct);
            AppLogger.LogInfo($"Session pipeline: summary appended to {masterPath}");

            return new SessionPipelineResult(
                Success: true,
                CleanedText: cleanedText,
                SummaryText: summary,
                GeneratedTitle: generatedTitle,
                TargetPath: masterPath,
                UsedBackup: false,
                ErrorMessage: null);
        }
        catch (Exception ex) when (IsOllamaUnavailable(ex))
        {
            var generatedTitle = titleTask.IsCompletedSuccessfully ? titleTask.Result : null;
            AppLogger.LogWarning($"Session pipeline: Ollama unavailable. Fallback to backup. {ex.Message}");
            try
            {
                await AppendBackupAsync(backupPath, cleanedText, ct);
                return new SessionPipelineResult(
                    Success: true,
                    CleanedText: cleanedText,
                    SummaryText: null,
                    GeneratedTitle: generatedTitle,
                    TargetPath: backupPath,
                    UsedBackup: true,
                    ErrorMessage: ex.Message);
            }
            catch (Exception backupEx)
            {
                AppLogger.LogError($"Session pipeline backup write failed: {backupEx.Message}");
                return new SessionPipelineResult(
                    Success: false,
                    CleanedText: cleanedText,
                    SummaryText: null,
                    GeneratedTitle: null,
                    TargetPath: backupPath,
                    UsedBackup: true,
                    ErrorMessage: $"Ollama error: {ex.Message}. Backup error: {backupEx.Message}");
            }
        }
        catch (Exception ex)
        {
            AppLogger.LogError($"Session pipeline failed: {ex.Message}");
            return new SessionPipelineResult(
                Success: false,
                CleanedText: cleanedText,
                SummaryText: null,
                GeneratedTitle: null,
                TargetPath: masterPath,
                UsedBackup: false,
                ErrorMessage: ex.Message);
        }
    }

    private static string ResolveOutputDirectory(string? transcriptionPath)
    {
        if (!string.IsNullOrWhiteSpace(transcriptionPath))
        {
            var dir = Path.GetDirectoryName(transcriptionPath);
            if (!string.IsNullOrWhiteSpace(dir))
            {
                Directory.CreateDirectory(dir);
                return dir;
            }
        }

        var documents = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        var fallback = Path.Combine(documents, "Contora");
        Directory.CreateDirectory(fallback);
        return fallback;
    }

    private async Task<string> LoadSystemPromptAsync(CancellationToken ct)
    {
        try
        {
            if (!File.Exists(_options.SystemPromptPath))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_options.SystemPromptPath)!);
                await File.WriteAllTextAsync(_options.SystemPromptPath, DefaultSystemPrompt, Encoding.UTF8, ct);
                return DefaultSystemPrompt;
            }

            var prompt = await File.ReadAllTextAsync(_options.SystemPromptPath, ct);
            return string.IsNullOrWhiteSpace(prompt) ? DefaultSystemPrompt : prompt.Trim();
        }
        catch
        {
            return DefaultSystemPrompt;
        }
    }

    private static async Task AppendSessionAsync(string path, string text, CancellationToken ct)
    {
        var header = $"## Сессия от {DateTime.Now:yyyy-MM-dd}{Environment.NewLine}{Environment.NewLine}";
        var payload = $"{header}{text}{Environment.NewLine}{Environment.NewLine}";
        await AppendOnlyWriteAsync(path, payload, ct);
    }

    private static async Task AppendBackupAsync(string path, string cleanedText, CancellationToken ct)
    {
        var header = $"## Сессия от {DateTime.Now:yyyy-MM-dd} (backup: Ollama unavailable){Environment.NewLine}{Environment.NewLine}";
        var payload = $"{header}{cleanedText}{Environment.NewLine}{Environment.NewLine}";
        await AppendOnlyWriteAsync(path, payload, ct);
    }

    private static async Task AppendOnlyWriteAsync(string path, string payload, CancellationToken ct)
    {
        await using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read);
        await using var writer = new StreamWriter(stream, Encoding.UTF8);
        await writer.WriteAsync(payload.AsMemory(), ct);
        await writer.FlushAsync();
    }

    private static bool IsOllamaUnavailable(Exception ex)
    {
        if (ex is TaskCanceledException)
        {
            return true;
        }

        if (ex is HttpRequestException httpEx)
        {
            if (httpEx.InnerException is SocketException)
            {
                return true;
            }

            var msg = httpEx.Message.ToLowerInvariant();
            if (msg.Contains("refused") || msg.Contains("connection"))
            {
                return true;
            }
        }

        return false;
    }
}
