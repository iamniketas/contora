import Foundation

struct ZoomSpeakerTrack: Identifiable, Hashable, Sendable {
    let id: String
    let participantName: String
    let audioURL: URL
}
struct ZoomRecording: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let startedAt: Date
    let folderURL: URL
    let mixedAudioURL: URL?
    let tracks: [ZoomSpeakerTrack]
    let zoomRecordingID: String?

    var primaryAudioURL: URL? {
        mixedAudioURL ?? tracks.first?.audioURL
    }
}

struct ZoomSessionSource: Hashable, Sendable {
    let recordingID: String
    let folderURL: URL
    let tracks: [ZoomSpeakerTrack]
}

enum ZoomRecordingDetector {
    private struct RecordingConfiguration: Decodable {
        let magicNumber: String?

        private enum CodingKeys: String, CodingKey {
            case magicNumber = "magic_number"
        }
    }

    static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            return documents.appendingPathComponent("Zoom", isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Zoom", isDirectory: true)
    }

    static func scan(
        rootURL: URL,
        now: Date = Date(),
        stableFor seconds: TimeInterval = 20,
        fileManager: FileManager = .default
    ) throws -> [ZoomRecording] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let meetingDirectories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        return try meetingDirectories.compactMap { meetingURL in
            let values = try meetingURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { return nil }
            return try detectMeeting(
                at: meetingURL,
                now: now,
                stableFor: seconds,
                fileManager: fileManager
            )
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    private static func detectMeeting(
        at meetingURL: URL,
        now: Date,
        stableFor seconds: TimeInterval,
        fileManager: FileManager
    ) throws -> ZoomRecording? {
        let audioRecordURL = meetingURL.appendingPathComponent("Audio Record", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: audioRecordURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        let trackURLs = try fileManager.contentsOfDirectory(
            at: audioRecordURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "m4a" }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard trackURLs.count >= 2,
              try trackURLs.allSatisfy({ try isStableFile($0, now: now, stableFor: seconds) }) else {
            return nil
        }

        let configurationURL = meetingURL.appendingPathComponent("recording.conf")
        let zoomRecordingID = loadRecordingID(from: configurationURL)
        let rootAudioFiles = (try? fileManager.contentsOfDirectory(
            at: meetingURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let mixedAudioURL = rootAudioFiles
            .filter { $0.pathExtension.lowercased() == "m4a" && $0.lastPathComponent.lowercased().hasPrefix("audio") }
            .filter { (try? isStableFile($0, now: now, stableFor: seconds)) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .first
        let trackFilenameRecordingID = mixedAudioURL.flatMap(numericAudioID) ?? zoomRecordingID
        let parsedTracks = trackURLs.enumerated().map { offset, url in
            let parsed = parseTrackStem(
                url.deletingPathExtension().lastPathComponent,
                recordingID: trackFilenameRecordingID
            )
            return ZoomSpeakerTrack(
                id: "ZOOM_\(parsed.index ?? offset + 1)",
                participantName: parsed.name,
                audioURL: url
            )
        }
        let tracks = uniquingParticipantNames(parsedTracks).sorted {
            $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }

        let startedAt = parseStartDate(from: meetingURL.lastPathComponent)
            ?? ((try? meetingURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
            ?? .distantPast
        let title = meetingTitle(from: meetingURL.lastPathComponent)
        let identity = meetingURL.standardizedFileURL.path

        return ZoomRecording(
            id: identity,
            title: title,
            startedAt: startedAt,
            folderURL: meetingURL,
            mixedAudioURL: mixedAudioURL,
            tracks: tracks,
            zoomRecordingID: zoomRecordingID
        )
    }

    private static func isStableFile(_ url: URL, now: Date, stableFor seconds: TimeInterval) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile != false,
              (values.fileSize ?? 0) > 0,
              let modifiedAt = values.contentModificationDate else {
            return false
        }
        return now.timeIntervalSince(modifiedAt) >= seconds
    }

    private static func loadRecordingID(from configurationURL: URL) -> String? {
        guard let data = try? Data(contentsOf: configurationURL),
              let configuration = try? JSONDecoder().decode(RecordingConfiguration.self, from: data) else {
            return nil
        }
        return configuration.magicNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func numericAudioID(from audioURL: URL) -> String? {
        let stem = audioURL.deletingPathExtension().lastPathComponent
        guard stem.lowercased().hasPrefix("audio") else { return nil }
        let suffix = stem.dropFirst(5)
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
        return String(suffix)
    }

    private static func parseTrackStem(_ stem: String, recordingID: String?) -> (name: String, index: Int?) {
        var value = stem
        if value.lowercased().hasPrefix("audio") {
            value.removeFirst(5)
        }

        if let recordingID, !recordingID.isEmpty, value.hasSuffix(recordingID) {
            value.removeLast(recordingID.count)
        } else {
            value = value.replacingOccurrences(
                of: #"\d{8,}$"#,
                with: "",
                options: .regularExpression
            )
        }

        let indexText = value.reversed().prefix { $0.isNumber }.reversed()
        let index = Int(String(indexText))
        if !indexText.isEmpty {
            value.removeLast(indexText.count)
        }

        value = value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(
                of: #"(?<=[\p{Ll}])(?=[\p{Lu}])"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?<=[A-Za-z])(?=[А-Яа-яЁё])|(?<=[А-Яа-яЁё])(?=[A-Za-z])"#,
                with: " ",
                options: .regularExpression
            )
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        return (value.isEmpty ? "Participant \(index ?? 1)" : value, index)
    }

    private static func uniquingParticipantNames(_ tracks: [ZoomSpeakerTrack]) -> [ZoomSpeakerTrack] {
        var counts: [String: Int] = [:]
        return tracks.map { track in
            let nextCount = (counts[track.participantName] ?? 0) + 1
            counts[track.participantName] = nextCount
            guard nextCount > 1 else { return track }
            return ZoomSpeakerTrack(
                id: track.id,
                participantName: "\(track.participantName) \(nextCount)",
                audioURL: track.audioURL
            )
        }
    }

    private static func parseStartDate(from directoryName: String) -> Date? {
        guard directoryName.count >= 19 else { return nil }
        let prefix = String(directoryName.prefix(19))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.date(from: prefix)
    }

    private static func meetingTitle(from directoryName: String) -> String {
        let value = directoryName.replacingOccurrences(
            of: #"^\d{4}-\d{2}-\d{2}\s+\d{2}\.\d{2}\.\d{2}\s*"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? directoryName : value
    }
}

struct ZoomTrackTranscription: Sendable {
    let track: ZoomSpeakerTrack
    let output: TranscriptionBackendOutput
}

struct ZoomMergedTranscript: Sendable {
    let text: String
    let speakers: [ContoraSessionManifest.Transcription.Speaker]
    let segments: [ContoraSessionManifest.Transcription.Segment]
    let words: [ContoraSessionManifest.Transcription.Word]
    let speakerTurns: [ContoraSessionManifest.Transcription.SpeakerTurn]
    let structuredResultData: Data?
}

enum ZoomTranscriptMerger {
    static func merge(_ trackResults: [ZoomTrackTranscription]) -> ZoomMergedTranscript {
        var speakers: [ContoraSessionManifest.Transcription.Speaker] = []
        var segments: [ContoraSessionManifest.Transcription.Segment] = []
        var words: [ContoraSessionManifest.Transcription.Word] = []

        for trackResult in trackResults {
            let track = trackResult.track
            speakers.append(.init(id: track.id, displayName: track.participantName))

            if let result = trackResult.output.mlxResultV2, !result.utterances.isEmpty {
                for (index, utterance) in result.utterances.enumerated() {
                    let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    segments.append(.init(
                        id: "\(track.id)-\(index)",
                        startSeconds: utterance.start,
                        endSeconds: utterance.end,
                        speakerID: track.id,
                        text: text
                    ))
                }
                words.append(contentsOf: result.words.map {
                    .init(
                        text: $0.text,
                        startSeconds: $0.start,
                        endSeconds: $0.end,
                        confidence: $0.confidence,
                        speakerID: track.id,
                        speakerScore: 1,
                        overlap: false,
                        overlapSpeakers: []
                    )
                })
            } else {
                let parsed = TranscriptSegmentParser().parseSpeakersAndSegments(from: trackResult.output.text)
                let fallbackSegments: [ContoraSession.Segment]
                if parsed.segments.isEmpty {
                    let text = trackResult.output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    fallbackSegments = text.isEmpty ? [] : [
                        .init(
                            id: "fallback",
                            startSeconds: 0,
                            endSeconds: 0,
                            speakerID: track.id,
                            text: text
                        )
                    ]
                } else {
                    fallbackSegments = parsed.segments
                }
                for (index, segment) in fallbackSegments.enumerated() {
                    segments.append(.init(
                        id: "\(track.id)-\(index)",
                        startSeconds: segment.startSeconds,
                        endSeconds: segment.endSeconds,
                        speakerID: track.id,
                        text: segment.text
                    ))
                }
            }
        }

        segments.sort {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            if $0.endSeconds != $1.endSeconds { return $0.endSeconds < $1.endSeconds }
            return $0.speakerID < $1.speakerID
        }
        words.sort {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.endSeconds < $1.endSeconds
        }

        let speakerNames = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.displayName) })
        let text = segments.map { segment in
            let speaker = speakerNames[segment.speakerID] ?? segment.speakerID
            return "[\(formatTimestamp(segment.startSeconds)) --> \(formatTimestamp(segment.endSeconds))] [\(speaker)]: \(segment.text)"
        }.joined(separator: "\n")
        let speakerTurns = segments.map {
            ContoraSessionManifest.Transcription.SpeakerTurn(
                startSeconds: $0.startSeconds,
                endSeconds: $0.endSeconds,
                speakerID: $0.speakerID,
                confidence: 1
            )
        }
        let structuredResultData = makeStructuredResultData(
            text: text,
            speakers: speakers,
            segments: segments,
            words: words
        )

        return ZoomMergedTranscript(
            text: text,
            speakers: speakers,
            segments: segments,
            words: words,
            speakerTurns: speakerTurns,
            structuredResultData: structuredResultData
        )
    }

    private static func formatTimestamp(_ seconds: Double) -> String {
        let nonnegative = max(0, seconds)
        let hours = Int(nonnegative) / 3600
        let minutes = (Int(nonnegative) % 3600) / 60
        let wholeSeconds = Int(nonnegative) % 60
        let milliseconds = Int((nonnegative - floor(nonnegative)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, wholeSeconds, milliseconds)
    }

    private static func makeStructuredResultData(
        text: String,
        speakers: [ContoraSessionManifest.Transcription.Speaker],
        segments: [ContoraSessionManifest.Transcription.Segment],
        words: [ContoraSessionManifest.Transcription.Word]
    ) -> Data? {
        let payload: [String: Any] = [
            "schema_version": "2.0",
            "kind": "zoom_multitrack",
            "diarization": false,
            "text": text,
            "speakers": speakers.map { ["id": $0.id, "display_name": $0.displayName] },
            "segments": segments.map {
                [
                    "id": $0.id,
                    "start": $0.startSeconds,
                    "end": $0.endSeconds,
                    "speaker": $0.speakerID,
                    "text": $0.text,
                ] as [String: Any]
            },
            "words": words.map {
                [
                    "text": $0.text,
                    "start": $0.startSeconds,
                    "end": $0.endSeconds,
                    "confidence": $0.confidence.map { $0 as Any } ?? NSNull(),
                    "speaker": $0.speakerID,
                ] as [String: Any]
            },
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

enum ZoomRecordingSelfCheck {
    static func run(rootURL: URL) throws -> [ZoomRecording] {
        let recordings = try ZoomRecordingDetector.scan(rootURL: rootURL, stableFor: 0)
        for recording in recordings {
            guard recording.tracks.count >= 2 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard Set(recording.tracks.map(\.id)).count == recording.tracks.count,
                  Set(recording.tracks.map(\.participantName)).count == recording.tracks.count else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let first = ZoomTrackTranscription(
                track: recording.tracks[0],
                output: .init(text: "[00:00:02.000 --> 00:00:03.000] [SPEAKER_00]: second")
            )
            let second = ZoomTrackTranscription(
                track: recording.tracks[1],
                output: .init(text: "[00:00:01.000 --> 00:00:01.500] [SPEAKER_00]: first")
            )
            let merged = ZoomTranscriptMerger.merge([first, second])
            guard merged.segments.map(\.text) == ["first", "second"],
                  merged.speakers.map(\.displayName) == [recording.tracks[0].participantName, recording.tracks[1].participantName],
                  merged.text.contains(recording.tracks[0].participantName),
                  merged.text.contains(recording.tracks[1].participantName) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return recordings
    }
}
