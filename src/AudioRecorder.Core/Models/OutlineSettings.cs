namespace AudioRecorder.Core.Models;

public sealed class OutlineSettings
{
    public string? BaseUrl { get; set; }
    public string? ApiToken { get; set; }
    public string? DefaultCollectionId { get; set; }
    public bool AutoPublish { get; set; } = true;
}

public sealed class OutlineDocumentResult
{
    public bool Success { get; init; }
    public string? DocumentId { get; init; }
    public string? DocumentUrl { get; init; }
    public string? ErrorMessage { get; init; }
}

public sealed class OutlineCollection
{
    public string Id { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;
    public string? Description { get; init; }
}

public sealed class OutlineCollectionsResult
{
    public bool Success { get; init; }
    public IReadOnlyList<OutlineCollection> Collections { get; init; } = [];
    public string? ErrorMessage { get; init; }
}
