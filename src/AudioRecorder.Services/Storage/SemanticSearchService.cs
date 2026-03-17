using AudioRecorder.Core.Models;
using AudioRecorder.Core.Services;
using AudioRecorder.Services.Logging;

namespace AudioRecorder.Services.Storage;

/// <summary>
/// Hybrid search combining FTS5 full-text search with semantic (vector) search.
///
/// Vector similarity is computed in-memory using dot product of unit-length vectors
/// (cosine similarity). Embeddings are stored as float32 BLOBs in the sessions table —
/// an architecture that is directly compatible with sqlite-vec for future migration when
/// the session count grows beyond the in-memory threshold.
///
/// Search strategy:
///   1. Embed the query via IEmbeddingService (if available)
///   2. Load all stored embeddings, score by dot product, take top-k
///   3. Run FTS5 for keyword fallback / additional coverage
///   4. Merge: semantic results first, then FTS5 additions up to limit
///
/// Falls back to pure FTS5 when the embedding service is unavailable.
/// </summary>
public sealed class SemanticSearchService
{
    private readonly ISessionStore _store;
    private readonly IEmbeddingService _embedding;

    // Minimum cosine similarity to include a result from semantic search.
    // BGE-M3 typically returns >0.6 for relevant matches; 0.3 avoids noise.
    private const float SimilarityThreshold = 0.3f;

    public SemanticSearchService(ISessionStore store, IEmbeddingService embedding)
    {
        _store = store;
        _embedding = embedding;
    }

    /// <summary>
    /// Hybrid search. Returns sessions ordered by relevance
    /// (semantic match first, then FTS5 keyword matches).
    /// Falls back to GetAllAsync when query is empty.
    /// </summary>
    public async Task<IReadOnlyList<Session>> SearchAsync(
        string? query,
        int limit = 50,
        CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(query))
            return await _store.GetAllAsync(limit);

        // Always run FTS5 — fast and reliable regardless of embedding availability
        var ftsTask = _store.SearchAsync(query, limit);

        // Semantic search — only when embedding service responded successfully before
        List<Guid>? semanticIds = null;
        if (_embedding.IsAvailable)
        {
            try
            {
                var queryEmbedding = await _embedding.EmbedAsync(query, ct);
                if (queryEmbedding != null)
                {
                    var allEmbeddings = await _store.GetAllEmbeddingsAsync();
                    if (allEmbeddings.Count > 0)
                    {
                        semanticIds = allEmbeddings
                            .Select(e => (e.Id, Score: DotProduct(queryEmbedding, e.Embedding)))
                            .Where(x => x.Score >= SimilarityThreshold)
                            .OrderByDescending(x => x.Score)
                            .Take(limit)
                            .Select(x => x.Id)
                            .ToList();

                        AppLogger.LogInfo(
                            $"SemanticSearch: {semanticIds.Count} semantic hit(s) for \"{query}\"");
                    }
                }
            }
            catch (Exception ex)
            {
                AppLogger.LogWarning($"SemanticSearchService: embedding query failed: {ex.Message}");
            }
        }

        var ftsResults = await ftsTask;

        if (semanticIds == null || semanticIds.Count == 0)
            return ftsResults;

        // Merge: semantic hits first (best semantic match), then FTS5 additions
        var seen = new HashSet<Guid>();
        var merged = new List<Session>(limit);

        foreach (var id in semanticIds)
        {
            if (merged.Count >= limit) break;
            if (!seen.Add(id)) continue;
            var session = await _store.GetAsync(id);
            if (session != null) merged.Add(session);
        }

        foreach (var session in ftsResults)
        {
            if (merged.Count >= limit) break;
            if (seen.Add(session.Id)) merged.Add(session);
        }

        return merged;
    }

    private static float DotProduct(float[] a, float[] b)
    {
        var len = Math.Min(a.Length, b.Length);
        float sum = 0;
        for (int i = 0; i < len; i++)
            sum += a[i] * b[i];
        return sum;
    }
}
