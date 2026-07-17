namespace AudioRecorder.Core.Models;

/// <summary>Reusable local meeting participant; Outline identity can be linked later.</summary>
public sealed record SpeakerProfile(string Name, string? OutlineProfileId = null);
