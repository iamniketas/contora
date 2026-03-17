using System.Net.Http.Json;
using System.Text.Json.Serialization;
using AudioRecorder.Core.Services;
using AudioRecorder.Services.Logging;

namespace AudioRecorder.Services.Embeddings;

/// <summary>
/// Generates text embeddings via the Ollama /api/embed endpoint.
/// Compatible with any Ollama embedding model; default model is bge-m3.
///
/// BGE-M3 is a multilingual embedding model that supports 100+ languages including
/// Russian and English. Install via: ollama pull bge-m3
///
/// Returned vectors are L2-normalized to unit length so cosine similarity
/// equals the dot product — no extra normalization needed at query time.
/// </summary>
public sealed class OllamaEmbeddingService : IEmbeddingService
{
    private static readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(60) };

    private readonly string _embedUrl;

    public string ModelName { get; }

    /// <summary>
    /// True until a request fails; reset to true on next successful response.
    /// Used by callers to skip the service cheaply without waiting for timeouts.
    /// </summary>
    public bool IsAvailable { get; private set; } = true;

    public OllamaEmbeddingService(
        string modelName = "bge-m3",
        string ollamaBaseUrl = "http://localhost:11434")
    {
        ModelName = modelName;
        _embedUrl = $"{ollamaBaseUrl.TrimEnd('/')}/api/embed";
    }

    public async Task<float[]?> EmbedAsync(string text, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;

        try
        {
            var request = new { model = ModelName, input = text };
            using var response = await _http.PostAsJsonAsync(_embedUrl, request, ct);

            if (!response.IsSuccessStatusCode)
            {
                AppLogger.LogWarning($"OllamaEmbeddingService: HTTP {(int)response.StatusCode} from {_embedUrl}");
                IsAvailable = false;
                return null;
            }

            var payload = await response.Content.ReadFromJsonAsync<OllamaEmbedResponse>(cancellationToken: ct);
            if (payload?.Embeddings is { Length: > 0 } embeddings && embeddings[0].Length > 0)
            {
                IsAvailable = true;
                return Normalize(embeddings[0]);
            }

            AppLogger.LogWarning("OllamaEmbeddingService: empty embeddings in response");
            return null;
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or InvalidOperationException)
        {
            AppLogger.LogWarning($"OllamaEmbeddingService unavailable: {ex.Message}");
            IsAvailable = false;
            return null;
        }
    }

    private static float[] Normalize(float[] v)
    {
        double sumSq = 0;
        for (int i = 0; i < v.Length; i++)
            sumSq += (double)v[i] * v[i];

        if (sumSq < 1e-12) return v;

        var scale = (float)(1.0 / Math.Sqrt(sumSq));
        var result = new float[v.Length];
        for (int i = 0; i < v.Length; i++)
            result[i] = v[i] * scale;
        return result;
    }
}

internal sealed class OllamaEmbedResponse
{
    [JsonPropertyName("embeddings")]
    public float[][]? Embeddings { get; init; }
}
