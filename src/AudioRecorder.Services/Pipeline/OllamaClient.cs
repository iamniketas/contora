using AudioRecorder.Core.Models;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AudioRecorder.Services.Pipeline;

public sealed class OllamaClient
{
    private readonly HttpClient _httpClient;
    private readonly SessionPipelineOptions _options;

    public OllamaClient(SessionPipelineOptions options)
    {
        _options = options;
        _httpClient = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(Math.Max(30, options.RequestTimeoutSeconds))
        };
    }

    private const string TitleSystemPrompt =
        "Придумай короткое название (3–7 слов) для этой записи разговора. " +
        "Только название, без кавычек, без пунктуации в конце.";

    private const string StructuredSystemPrompt = """
        Analyze the following conversation transcript and respond ONLY with valid JSON.
        Use the SAME language as the transcript (Russian or English).
        Required JSON format — do not add any text outside the JSON:
        {
          "title": "3-7 word short title of the conversation",
          "summary": "2-3 sentence summary of key points discussed",
          "action_items": ["concrete action 1", "concrete action 2"],
          "decisions": ["decision made 1", "decision made 2"],
          "risks": ["risk or concern 1"]
        }
        Rules: be concise; use empty arrays [] when nothing found; no markdown formatting inside strings.
        """;

    /// <summary>
    /// Generates a short title for the session. Returns null on any error — best-effort only.
    /// </summary>
    public async Task<string?> GenerateTitleAsync(string cleanedText, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(cleanedText)) return null;
        var excerpt = cleanedText.Length > 1500 ? cleanedText[..1500] : cleanedText;
        try
        {
            var request = new OllamaGenerateRequest
            {
                Model = _options.Model,
                System = TitleSystemPrompt,
                Prompt = excerpt,
                Stream = false,
            };
            using var response = await _httpClient.PostAsJsonAsync(_options.OllamaUrl, request, ct);
            var payload = await response.Content.ReadFromJsonAsync<OllamaGenerateResponse>(cancellationToken: ct);
            if (!response.IsSuccessStatusCode || payload == null || string.IsNullOrWhiteSpace(payload.Response))
                return null;
            var title = payload.Response.Trim().TrimEnd('.', '!', '?').Trim();
            return title.Length > 80 ? title[..80] : title;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// Sends one structured request to Ollama and returns parsed <see cref="StructuredSessionOutput"/>.
    /// Returns null on any error — best-effort only.
    /// </summary>
    public async Task<StructuredSessionOutput?> GenerateStructuredAsync(string cleanedText, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(cleanedText)) return null;
        // Use up to 4000 chars — enough context without overloading small models
        var excerpt = cleanedText.Length > 4000 ? cleanedText[..4000] : cleanedText;
        try
        {
            var request = new OllamaGenerateRequest
            {
                Model = _options.Model,
                System = StructuredSystemPrompt,
                Prompt = excerpt,
                Stream = false,
                Format = "json",
            };
            using var response = await _httpClient.PostAsJsonAsync(_options.OllamaUrl, request, ct);
            var payload = await response.Content.ReadFromJsonAsync<OllamaGenerateResponse>(cancellationToken: ct);
            if (!response.IsSuccessStatusCode || payload == null || string.IsNullOrWhiteSpace(payload.Response))
                return null;

            var json = payload.Response.Trim();
            // Strip markdown code fences if model wrapped JSON anyway
            if (json.StartsWith("```")) json = json.Split('\n', 2)[1].TrimEnd('`').Trim();
            var output = JsonSerializer.Deserialize<StructuredSessionOutput>(json);
            return output;
        }
        catch
        {
            return null;
        }
    }

    public async Task<string> GenerateSummaryAsync(string systemPrompt, string cleanedText, CancellationToken ct)
    {
        var request = new OllamaGenerateRequest
        {
            Model = _options.Model,
            System = systemPrompt,
            Prompt = cleanedText,
            Stream = false
        };

        using var response = await _httpClient.PostAsJsonAsync(_options.OllamaUrl, request, ct);
        var payload = await response.Content.ReadFromJsonAsync<OllamaGenerateResponse>(cancellationToken: ct);

        if (!response.IsSuccessStatusCode)
        {
            var apiError = payload?.Error;
            throw new HttpRequestException(
                $"Ollama HTTP {(int)response.StatusCode}: {response.ReasonPhrase}. {apiError}".Trim());
        }

        if (payload == null || string.IsNullOrWhiteSpace(payload.Response))
        {
            throw new InvalidOperationException("Ollama response payload does not contain `response`.");
        }

        return payload.Response.Trim();
    }
}

public sealed class OllamaGenerateRequest
{
    [JsonPropertyName("model")]
    public string Model { get; init; } = string.Empty;

    [JsonPropertyName("system")]
    public string System { get; init; } = string.Empty;

    [JsonPropertyName("prompt")]
    public string Prompt { get; init; } = string.Empty;

    [JsonPropertyName("stream")]
    public bool Stream { get; init; }

    /// <summary>Set to "json" to force JSON output mode.</summary>
    [JsonPropertyName("format")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Format { get; init; }
}

public sealed class OllamaGenerateResponse
{
    [JsonPropertyName("response")]
    public string? Response { get; init; }

    [JsonPropertyName("error")]
    public string? Error { get; init; }
}
