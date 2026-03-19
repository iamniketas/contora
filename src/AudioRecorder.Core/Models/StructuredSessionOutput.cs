using System.Text.Json.Serialization;

namespace AudioRecorder.Core.Models;

/// <summary>
/// Structured output produced by LLM post-processing of a transcript.
/// Serialized as JSON and stored in the sessions table.
/// </summary>
public sealed class StructuredSessionOutput
{
    [JsonPropertyName("title")]
    public string? Title { get; set; }

    [JsonPropertyName("summary")]
    public string? Summary { get; set; }

    [JsonPropertyName("action_items")]
    public List<string> ActionItems { get; set; } = new();

    [JsonPropertyName("decisions")]
    public List<string> Decisions { get; set; } = new();

    [JsonPropertyName("risks")]
    public List<string> Risks { get; set; } = new();
}
