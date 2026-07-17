namespace AudioRecorder.Core.Models;

public enum SpeakerCountConstraint
{
    Auto,
    Exact,
    Minimum,
    Maximum
}

/// <summary>Per-session diarization settings. Null Count means fully automatic detection.</summary>
public sealed record DiarizationOptions(
    SpeakerCountConstraint Constraint = SpeakerCountConstraint.Auto,
    int? Count = null)
{
    public static readonly DiarizationOptions Automatic = new();

    public DiarizationOptions Normalize()
    {
        var count = Count is >= 1 and <= 50 ? Count : null;
        return Constraint == SpeakerCountConstraint.Auto || count is null
            ? Automatic
            : this with { Count = count };
    }
}
