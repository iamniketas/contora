using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using AudioRecorder.Core.Models;
using AudioRecorder.Core.Services;
using AudioRecorder.Services.Logging;

namespace AudioRecorder.Services.Integrations;

/// <summary>
/// Publishes transcriptions to an Outline wiki via the REST API.
/// Configure via Settings → Integrations (base URL + API token + default collection).
/// </summary>
public sealed class OutlineService : IOutlineService
{
    private readonly OutlineSettings _settings;
    private static readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(30) };

    public OutlineService(OutlineSettings settings)
    {
        _settings = settings;
    }

    public bool IsConfigured =>
        !string.IsNullOrWhiteSpace(_settings.BaseUrl) &&
        !string.IsNullOrWhiteSpace(_settings.ApiToken);

    public async Task<OutlineDocumentResult> CreateDocumentAsync(
        string title,
        string text,
        string? collectionId = null,
        CancellationToken ct = default)
    {
        if (!IsConfigured)
            return Fail("Outline not configured");

        var effectiveCollection = collectionId ?? _settings.DefaultCollectionId;

        var body = new
        {
            title,
            text,
            collectionId = effectiveCollection,
            publish = _settings.AutoPublish,
        };

        return await PostAsync("documents.create", body, ct);
    }

    public async Task<OutlineDocumentResult> AppendToDocumentAsync(
        string documentId,
        string appendText,
        CancellationToken ct = default)
    {
        if (!IsConfigured)
            return Fail("Outline not configured");

        var body = new
        {
            id = documentId,
            text = appendText,
            append = true,
            publish = _settings.AutoPublish,
        };

        return await PostAsync("documents.update", body, ct);
    }

    public async Task<OutlineDocumentResult> UpdateDocumentAsync(
        string documentId,
        string title,
        string text,
        CancellationToken ct = default)
    {
        if (!IsConfigured)
            return Fail("Outline not configured");

        var body = new
        {
            id = documentId,
            title,
            text,
            publish = _settings.AutoPublish,
        };

        return await PostAsync("documents.update", body, ct);
    }

    // ── Private ─────────────────────────────────────────────────────────────

    private async Task<OutlineDocumentResult> PostAsync(string endpoint, object body, CancellationToken ct)
    {
        try
        {
            var baseUrl = _settings.BaseUrl!.TrimEnd('/');
            var url = $"{baseUrl}/api/{endpoint}";

            var json = JsonSerializer.Serialize(body);
            using var request = new HttpRequestMessage(HttpMethod.Post, url);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _settings.ApiToken);
            request.Content = new StringContent(json, Encoding.UTF8, "application/json");

            using var response = await _http.SendAsync(request, ct);
            var responseBody = await response.Content.ReadAsStringAsync(ct);

            if (!response.IsSuccessStatusCode)
            {
                AppLogger.LogError($"OutlineService {endpoint} failed: HTTP {(int)response.StatusCode} — {responseBody}");
                return Fail($"HTTP {(int)response.StatusCode}");
            }

            using var doc = JsonDocument.Parse(responseBody);
            var root = doc.RootElement;

            if (!root.TryGetProperty("data", out var data))
                return Fail("Unexpected response: missing 'data'");

            var id = data.TryGetProperty("id", out var idEl) ? idEl.GetString() : null;
            var docUrl = data.TryGetProperty("url", out var urlEl) ? urlEl.GetString() : null;

            // Outline returns relative paths like /doc/... — make them absolute
            if (docUrl != null && docUrl.StartsWith('/'))
                docUrl = baseUrl + docUrl;

            AppLogger.LogInfo($"Outline {endpoint}: doc {id} — {docUrl}");
            return new OutlineDocumentResult { Success = true, DocumentId = id, DocumentUrl = docUrl };
        }
        catch (OperationCanceledException)
        {
            return Fail("Cancelled");
        }
        catch (Exception ex)
        {
            AppLogger.LogError($"OutlineService {endpoint} exception: {ex.Message}");
            return Fail(ex.Message);
        }
    }

    public async Task<OutlineCollectionsResult> GetCollectionsAsync(CancellationToken ct = default)
    {
        if (!IsConfigured)
            return new OutlineCollectionsResult { Success = false, ErrorMessage = "Outline not configured" };

        try
        {
            var baseUrl = _settings.BaseUrl!.TrimEnd('/');
            var url = $"{baseUrl}/api/collections.list";

            using var request = new HttpRequestMessage(HttpMethod.Post, url);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _settings.ApiToken);
            // Empty body — Outline collections.list accepts no required params
            request.Content = new StringContent("{}", Encoding.UTF8, "application/json");

            using var response = await _http.SendAsync(request, ct);
            var responseBody = await response.Content.ReadAsStringAsync(ct);

            if (!response.IsSuccessStatusCode)
            {
                AppLogger.LogError($"OutlineService collections.list failed: HTTP {(int)response.StatusCode}");
                return new OutlineCollectionsResult { Success = false, ErrorMessage = $"HTTP {(int)response.StatusCode}" };
            }

            using var doc = JsonDocument.Parse(responseBody);
            var root = doc.RootElement;

            if (!root.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array)
                return new OutlineCollectionsResult { Success = false, ErrorMessage = "Unexpected response format" };

            var collections = new List<OutlineCollection>();
            foreach (var item in data.EnumerateArray())
            {
                var id = item.TryGetProperty("id", out var idEl) ? idEl.GetString() : null;
                var name = item.TryGetProperty("name", out var nameEl) ? nameEl.GetString() : null;
                var description = item.TryGetProperty("description", out var descEl) ? descEl.GetString() : null;

                if (id != null && name != null)
                    collections.Add(new OutlineCollection { Id = id, Name = name, Description = description });
            }

            AppLogger.LogInfo($"OutlineService: loaded {collections.Count} collections");
            return new OutlineCollectionsResult { Success = true, Collections = collections };
        }
        catch (OperationCanceledException)
        {
            return new OutlineCollectionsResult { Success = false, ErrorMessage = "Cancelled" };
        }
        catch (Exception ex)
        {
            AppLogger.LogError($"OutlineService collections.list exception: {ex.Message}");
            return new OutlineCollectionsResult { Success = false, ErrorMessage = ex.Message };
        }
    }

    private static OutlineDocumentResult Fail(string msg) =>
        new() { Success = false, ErrorMessage = msg };
}
