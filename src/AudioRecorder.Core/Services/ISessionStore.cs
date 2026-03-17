using AudioRecorder.Core.Models;

namespace AudioRecorder.Core.Services;

public interface ISessionStore
{
    /// <summary>Initialize database schema (idempotent).</summary>
    Task InitializeAsync();

    Task<Session> CreateAsync(Session session);
    Task UpdateAsync(Session session);
    Task<Session?> GetAsync(Guid id);

    /// <summary>Returns sessions ordered by RecordedAt descending.</summary>
    Task<IReadOnlyList<Session>> GetAllAsync(int limit = 200, int offset = 0);

    /// <summary>Full-text search across transcript text and titles.</summary>
    Task<IReadOnlyList<Session>> SearchAsync(string query, int limit = 50);

    /// <summary>Stores a pre-computed embedding vector for a session (upsert).</summary>
    Task StoreEmbeddingAsync(Guid sessionId, float[] embedding);

    /// <summary>Returns all sessions that have a stored embedding vector.</summary>
    Task<IReadOnlyList<(Guid Id, float[] Embedding)>> GetAllEmbeddingsAsync();

    Task DeleteAsync(Guid id);
}
