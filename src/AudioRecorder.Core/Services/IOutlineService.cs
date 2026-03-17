using AudioRecorder.Core.Models;

namespace AudioRecorder.Core.Services;

public interface IOutlineService
{
    bool IsConfigured { get; }

    /// <summary>
    /// Creates a new document in Outline and returns its ID and URL.
    /// </summary>
    Task<OutlineDocumentResult> CreateDocumentAsync(
        string title,
        string text,
        string? collectionId = null,
        CancellationToken ct = default);

    /// <summary>
    /// Appends text to an existing Outline document.
    /// </summary>
    Task<OutlineDocumentResult> AppendToDocumentAsync(
        string documentId,
        string appendText,
        CancellationToken ct = default);

    /// <summary>
    /// Returns all collections the authenticated user can publish to.
    /// </summary>
    Task<OutlineCollectionsResult> GetCollectionsAsync(CancellationToken ct = default);
}
