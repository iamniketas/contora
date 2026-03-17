namespace AudioRecorder.Core.Models;

public enum SessionState
{
    Recorded,
    Transcribing,
    Transcribed,
    Exported
}

public sealed class Session
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = string.Empty;
    public DateTime RecordedAt { get; set; } = DateTime.Now;
    public double DurationSeconds { get; set; }
    public string? AudioPath { get; set; }
    public string? TranscriptPath { get; set; }
    public SessionState State { get; set; } = SessionState.Recorded;

    /// <summary>JSON-encoded dictionary of speaker id → display name.</summary>
    public string? SpeakerNamesJson { get; set; }

    /// <summary>Outline document id set after export.</summary>
    public string? OutlineDocumentId { get; set; }

    /// <summary>Full URL of the published Outline document.</summary>
    public string? OutlineDocumentUrl { get; set; }

    /// <summary>First ~300 chars of the transcript for list preview.</summary>
    public string? PreviewText { get; set; }

    public DateTime CreatedAt { get; set; } = DateTime.Now;
}
