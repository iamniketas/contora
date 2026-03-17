namespace AudioRecorder.Core.Services;

/// <summary>
/// Generates dense vector embeddings for text.
/// Implementations are expected to return unit-length (L2-normalized) vectors
/// so that cosine similarity reduces to a simple dot product.
/// </summary>
public interface IEmbeddingService
{
    bool IsAvailable { get; }
    string ModelName { get; }

    /// <summary>
    /// Generates a normalized embedding vector for the given text.
    /// Returns null when the service is unavailable or the text is empty.
    /// </summary>
    Task<float[]?> EmbedAsync(string text, CancellationToken ct = default);
}
