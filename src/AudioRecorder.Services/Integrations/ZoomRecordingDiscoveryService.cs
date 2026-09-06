using System.Text.RegularExpressions;

namespace AudioRecorder.Services.Integrations;

public sealed record ZoomSpeakerTrack(string SpeakerName, string AudioPath);

public sealed record ZoomMeetingRecording(
    string FolderPath,
    string Title,
    DateTime RecordedAt,
    string MasterAudioPath,
    IReadOnlyList<ZoomSpeakerTrack> SpeakerTracks);

/// <summary>
/// Discovers completed Zoom computer recordings without requiring Zoom or Contora to stay open.
/// A valid package contains the mixed master plus Zoom's "Audio Record" participant tracks.
/// </summary>
public sealed partial class ZoomRecordingDiscoveryService
{
    private static readonly HashSet<string> AudioExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".m4a", ".wav", ".mp3", ".flac", ".ogg", ".opus"
    };

    public static string GetDefaultRecordingsFolder()
        => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Zoom");

    public IReadOnlyList<ZoomMeetingRecording> Discover(
        string rootFolder,
        IEnumerable<string>? alreadyImportedMasterPaths = null,
        IReadOnlyList<string>? knownSpeakerNames = null)
    {
        if (string.IsNullOrWhiteSpace(rootFolder) || !Directory.Exists(rootFolder))
            return [];

        var imported = new HashSet<string>(
            (alreadyImportedMasterPaths ?? []).Select(NormalizePath),
            StringComparer.OrdinalIgnoreCase);
        var result = new List<ZoomMeetingRecording>();

        foreach (var folder in EnumerateCandidateFolders(rootFolder))
        {
            var recording = TryOpenMeetingFolder(folder, knownSpeakerNames);
            if (recording is null || imported.Contains(NormalizePath(recording.MasterAudioPath)))
                continue;

            result.Add(recording);
        }

        return result
            .OrderByDescending(r => r.RecordedAt)
            .ToList();
    }

    public ZoomMeetingRecording? TryOpenMeetingFolder(
        string folderPath,
        IReadOnlyList<string>? knownSpeakerNames = null)
    {
        if (string.IsNullOrWhiteSpace(folderPath) || !Directory.Exists(folderPath))
            return null;

        var audioRecordFolder = FindAudioRecordFolder(folderPath);
        if (audioRecordFolder is null)
            return null;

        // A .zoom file means Zoom has not finished converting the recording yet.
        if (Directory.EnumerateFiles(folderPath, "*.zoom", SearchOption.TopDirectoryOnly).Any())
            return null;

        var tracks = Directory.EnumerateFiles(audioRecordFolder, "*", SearchOption.TopDirectoryOnly)
            .Where(path => AudioExtensions.Contains(Path.GetExtension(path)))
            .Where(path => !Path.GetFileNameWithoutExtension(path)
                .Contains("shared content", StringComparison.OrdinalIgnoreCase))
            .Select(path => new ZoomSpeakerTrack(
                ResolveKnownSpeakerName(ParseSpeakerName(path), knownSpeakerNames),
                Path.GetFullPath(path)))
            .Where(track => !string.IsNullOrWhiteSpace(track.SpeakerName))
            .OrderBy(track => track.SpeakerName, StringComparer.CurrentCultureIgnoreCase)
            .ToList();

        if (tracks.Count == 0)
            return null;

        var topLevelFiles = Directory.EnumerateFiles(folderPath, "*", SearchOption.TopDirectoryOnly).ToList();
        var master = topLevelFiles
            .Where(path => AudioExtensions.Contains(Path.GetExtension(path)))
            .OrderBy(MasterFileRank)
            .ThenByDescending(path => new FileInfo(path).Length)
            .FirstOrDefault();

        // audio_only.m4a is normally present, but zoom_0.mp4 is still a usable mixed master.
        master ??= topLevelFiles.FirstOrDefault(path =>
            string.Equals(Path.GetFileNameWithoutExtension(path), "zoom_0", StringComparison.OrdinalIgnoreCase)
            && string.Equals(Path.GetExtension(path), ".mp4", StringComparison.OrdinalIgnoreCase));

        if (master is null)
            return null;

        var newestWrite = tracks
            .Select(t => File.GetLastWriteTime(t.AudioPath))
            .Append(File.GetLastWriteTime(master))
            .Max();

        // Avoid offering a folder while Zoom is still writing its converted media.
        if (DateTime.Now - newestWrite < TimeSpan.FromSeconds(15))
            return null;

        var directory = new DirectoryInfo(folderPath);
        return new ZoomMeetingRecording(
            directory.FullName,
            BuildMeetingTitle(directory.Name),
            directory.CreationTime,
            Path.GetFullPath(master),
            tracks);
    }

    private static IEnumerable<string> EnumerateCandidateFolders(string rootFolder)
    {
        // Also accept a meeting folder selected directly by the user.
        yield return rootFolder;

        IEnumerable<string> firstLevel;
        try { firstLevel = Directory.EnumerateDirectories(rootFolder).ToList(); }
        catch { yield break; }

        foreach (var folder in firstLevel)
        {
            yield return folder;

            // Some users organize Zoom recordings into year/month folders. Two levels keeps the
            // launch scan bounded and avoids walking unrelated trees when a broad folder is chosen.
            IEnumerable<string> secondLevel;
            try { secondLevel = Directory.EnumerateDirectories(folder).ToList(); }
            catch { continue; }
            foreach (var nested in secondLevel)
                yield return nested;
        }
    }

    private static string? FindAudioRecordFolder(string meetingFolder)
    {
        try
        {
            return Directory.EnumerateDirectories(meetingFolder, "*", SearchOption.TopDirectoryOnly)
                .FirstOrDefault(path => CanonicalToken(Path.GetFileName(path)) == "audiorecord");
        }
        catch
        {
            return null;
        }
    }

    private static int MasterFileRank(string path)
    {
        var stem = Path.GetFileNameWithoutExtension(path);
        if (string.Equals(stem, "audio_only", StringComparison.OrdinalIgnoreCase)) return 0;
        if (stem.StartsWith("audio_only", StringComparison.OrdinalIgnoreCase)) return 1;
        if (stem.Contains("audio only", StringComparison.OrdinalIgnoreCase)) return 2;
        return 10;
    }

    internal static string ParseSpeakerName(string audioPath)
    {
        var stem = Path.GetFileNameWithoutExtension(audioPath).Trim();
        stem = AudioOnlyPrefixRegex().Replace(stem, string.Empty);
        stem = AudioPrefixRegex().Replace(stem, string.Empty);
        stem = ZoomRandomSuffixRegex().Replace(stem, string.Empty);
        stem = stem.Trim(' ', '_', '-', '[', ']', '(', ')');
        stem = MultiSeparatorRegex().Replace(stem, " ").Trim();
        return stem.Length == 0 ? "Zoom participant" : stem;
    }

    private static string ResolveKnownSpeakerName(string parsed, IReadOnlyList<string>? knownNames)
    {
        if (knownNames is null || knownNames.Count == 0)
            return parsed;

        var token = CanonicalToken(parsed);
        return knownNames.FirstOrDefault(name => CanonicalToken(name) == token) ?? parsed;
    }

    private static string BuildMeetingTitle(string folderName)
    {
        var title = MeetingDatePrefixRegex().Replace(folderName, string.Empty).Trim(' ', '-', '_');
        return string.IsNullOrWhiteSpace(title) ? folderName : title;
    }

    private static string CanonicalToken(string value)
        => new(value.Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());

    private static string NormalizePath(string path)
    {
        try { return Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar); }
        catch { return path; }
    }

    [GeneratedRegex(@"^audio[ _-]*only(?:[ _-]+)?", RegexOptions.IgnoreCase)]
    private static partial Regex AudioOnlyPrefixRegex();

    [GeneratedRegex(@"^audio(?:[ _-]+)?", RegexOptions.IgnoreCase)]
    private static partial Regex AudioPrefixRegex();

    [GeneratedRegex(@"[ _-]?\d{7,}$", RegexOptions.IgnoreCase)]
    private static partial Regex ZoomRandomSuffixRegex();

    [GeneratedRegex(@"[_-]+")]
    private static partial Regex MultiSeparatorRegex();

    [GeneratedRegex(@"^\d{4}[-_.]\d{2}[-_.]\d{2}(?:[ _-]+\d{1,2}[.:-]\d{2}(?:[.:-]\d{2})?)?")]
    private static partial Regex MeetingDatePrefixRegex();
}
