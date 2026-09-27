import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContoraWorkspaceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            if let session = model.selectedSession {
                CleanSessionDetailView(model: model, session: session)
            } else {
                ContentUnavailableView(
                    "Your transcript archive is empty",
                    systemImage: "text.page.badge.magnifyingglass",
                    description: Text("Record a conversation or import an audio or video file to begin.")
                )
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            model.reloadSessions()
        }
    }
}

private struct WorkspaceSidebar: View {
    @ObservedObject var model: AppModel
    @State private var showsRecentlyDeleted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Contora", systemImage: "waveform.circle.fill")
                    .font(.headline)
                Spacer()
                Button {
                    openContoraSettingsWindow()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            CompactCaptureControls(model: model)
                .padding(12)

            Divider()

            VStack(spacing: 10) {
                HStack {
                    Text(showsRecentlyDeleted ? "Recently Deleted" : "History")
                        .font(.headline)
                    Text("\(showsRecentlyDeleted ? model.deletedSessions.count : model.visibleSessions.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showsRecentlyDeleted.toggle()
                        if showsRecentlyDeleted {
                            model.reloadRecentlyDeleted()
                        }
                    } label: {
                        Image(systemName: showsRecentlyDeleted ? "clock.arrow.circlepath" : "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(showsRecentlyDeleted ? "Back to history" : "Recently Deleted")

                    Button {
                        if showsRecentlyDeleted {
                            model.reloadRecentlyDeleted()
                        } else {
                            model.reloadSessions()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reload")
                }

                if !showsRecentlyDeleted {
                    TextField("Search all transcript text", text: $model.sessionSearchText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.sessionSearchText) { _, _ in
                            model.selectFirstVisibleSessionIfNeeded()
                        }

                    HStack(spacing: 8) {
                        Picker("Status", selection: $model.sessionStatusFilter) {
                            ForEach(SessionStatusFilter.allCases) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: model.sessionStatusFilter) { _, _ in
                            model.selectFirstVisibleSessionIfNeeded()
                        }

                        Picker("Sort", selection: $model.sessionSortMode) {
                            ForEach(SessionSortMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: model.sessionSortMode) { _, _ in
                            model.selectFirstVisibleSessionIfNeeded()
                        }
                        Spacer()
                    }
                }
            }
            .padding(12)

            if showsRecentlyDeleted {
                List(model.deletedSessions) { deletedSession in
                    DeletedSessionRow(model: model, deletedSession: deletedSession)
                }
                .listStyle(.sidebar)
                .overlay {
                    if model.deletedSessions.isEmpty {
                        ContentUnavailableView(
                            "Recently Deleted is empty",
                            systemImage: "trash",
                            description: Text("Deleted sessions can be restored from here.")
                        )
                    }
                }
            } else {
                List(selection: $model.selectedSessionID) {
                    ForEach(model.visibleSessions) { session in
                        CleanSessionRow(model: model, session: session)
                            .tag(session.id)
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: model.selectedSessionID) { _, newValue in
                    model.selectSession(newValue)
                }
            }
        }
    }
}

private struct DeletedSessionRow: View {
    @ObservedObject var model: AppModel
    let deletedSession: DeletedSessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(deletedSession.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text("Deleted \(deletedSession.deletedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Restore") {
                model.restoreSession(deletedSession)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 5)
    }
}

private struct CompactCaptureControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    model.toggleRecording()
                } label: {
                    Label(
                        model.isRecording ? "Stop" : "Record",
                        systemImage: model.isRecording ? "stop.fill" : "record.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isRecording ? .red : .accentColor)
                .controlSize(.large)
                .disabled(model.isRecording ? model.isFinalizingStop : !model.canStartRecording)

                Menu {
                    Button("Import Audio…", systemImage: "waveform") { presentAudioImportPanel() }
                    Button("Import Video…", systemImage: "film") { presentVideoImportPanel() }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.isRecording || model.isFinalizingStop)
                .help("Import audio or video")
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if model.isRecording {
                    Text(formatDuration(model.recordingSeconds))
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
            }

            if let job = model.activeTranscriptionJob {
                VStack(spacing: 6) {
                    if let progress = job.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                    }
                    HStack {
                        Text(job.sessionTitle)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            model.cancelActiveTranscription()
                        } label: {
                            Image(systemName: "stop.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop transcription")
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var statusText: String {
        if model.isRecording { return "Recording" }
        if model.isFinalizingStop { return "Saving recording…" }
        if model.isTranscriptionBusy { return "Transcribing…" }
        return model.pendingTranscriptionJobsCount > 0 ? "\(model.pendingTranscriptionJobsCount) queued" : "Ready"
    }

    private var statusColor: Color {
        if model.isRecording { return .red }
        if model.isFinalizingStop || model.isTranscriptionBusy { return .orange }
        return .green
    }

    private func formatDuration(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private func presentAudioImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, UTType(filenameExtension: "opus") ?? .audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importAudioFile(from: url)
    }

    private func presentVideoImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .movie,
            UTType(filenameExtension: "mkv") ?? .movie,
            UTType(filenameExtension: "webm") ?? .movie,
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importVideoFile(from: url)
    }
}

private struct CleanSessionRow: View {
    @ObservedObject var model: AppModel
    let session: ContoraSession

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(session.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if model.isSessionPinned(session.id) {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.secondary)
                        .help("Pinned")
                }
                if model.outlineLink(for: session.id) != nil {
                    Image(systemName: "arrow.up.right.square.fill")
                        .foregroundStyle(.secondary)
                        .help("Published to Outline")
                }
            }

            HStack(spacing: 6) {
                Text(SessionRowView.dateFormatter.string(from: session.createdAt))
                Text("·")
                Text(sessionStatus)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if !previewText.isEmpty {
                Text(previewText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button(model.isSessionPinned(session.id) ? "Unpin" : "Pin") {
                model.toggleSessionPinned(session.id)
            }
        }
    }

    private var sessionStatus: String {
        if session.metadata.success == false { return "Failed" }
        return session.transcriptURL == nil ? "Audio" : "Transcribed"
    }

    private var previewText: String {
        let segmentPreview = session.segments.prefix(3)
            .map(\.text)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return segmentPreview.isEmpty ? session.transcriptPreview : segmentPreview
    }
}

private struct CleanSessionDetailView: View {
    @ObservedObject var model: AppModel
    let session: ContoraSession
    @State private var showsInspector = false
    @State private var showsRenameSheet = false
    @State private var renameDraft = ""
    @State private var confirmsDelete = false

    var body: some View {
        VStack(spacing: 0) {
            sessionHeader

            if model.activeTranscriptionJob?.sessionID == session.id {
                ActiveSessionProgress(model: model)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }

            if !model.sessionEditorSegments.isEmpty {
                SpeakerEditorStrip(model: model, session: session)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }

            Divider()

            transcriptContent
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .inspector(isPresented: $showsInspector) {
            SessionInspectorView(model: model, session: session)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .onAppear {
            model.selectSession(session.id)
        }
        .sheet(isPresented: $showsRenameSheet) {
            RenameSessionSheet(
                title: $renameDraft,
                onCancel: { showsRenameSheet = false },
                onRename: {
                    model.renameSession(session, to: renameDraft)
                    showsRenameSheet = false
                }
            )
        }
        .confirmationDialog(
            "Move “\(session.title)” to Recently Deleted?",
            isPresented: $confirmsDelete
        ) {
            Button("Move to Recently Deleted", role: .destructive) {
                model.moveSessionToRecentlyDeleted(session)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The session can be restored later. Imported source media outside Contora will not be moved or deleted.")
        }
    }

    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    Text(SessionRowView.dateFormatter.string(from: session.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.sessionEditorHasUnsavedChanges {
                    Text("Unsaved")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                } else if model.sessionEditorStatus != "Loaded" {
                    Text(model.sessionEditorStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 8) {
                if session.transcriptURL == nil {
                    Button {
                        model.retranscribeSession(session)
                    } label: {
                        Label("Transcribe", systemImage: "text.bubble")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRecording)
                } else {
                    Button {
                        model.openURL(session.recordingURL)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }

                    Button {
                        model.saveSelectedSessionEdits()
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.sessionEditorHasUnsavedChanges)

                    Button {
                        model.publishSelectedSessionToOutline()
                    } label: {
                        if model.isPublishingToOutline {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(
                                model.outlineLink(for: session.id) == nil ? "Publish" : "Update",
                                systemImage: "arrow.up.right.square"
                            )
                        }
                    }
                    .disabled(model.isPublishingToOutline)

                    if model.outlineLink(for: session.id)?.url != nil {
                        Button {
                            model.openOutlineDocument(for: session.id)
                        } label: {
                            Image(systemName: "safari")
                        }
                        .help("Open in Outline")
                    }
                }

                Spacer()

                Button {
                    showsInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help("Session details")

                Menu {
                    Button(model.isSessionPinned(session.id) ? "Unpin" : "Pin", systemImage: model.isSessionPinned(session.id) ? "pin.slash" : "pin") {
                        model.toggleSessionPinned(session.id)
                    }
                    Button("Rename…", systemImage: "pencil") {
                        renameDraft = session.title
                        showsRenameSheet = true
                    }
                    Divider()
                    Button("Reveal Recording in Finder") { model.revealSession(session) }
                    Button("Reveal Transcript in Finder") { model.revealTranscript(session) }
                        .disabled(session.transcriptURL == nil)
                    Divider()
                    Button("Re-transcribe") { model.retranscribeSession(session) }
                        .disabled(model.isRecording)
                    Button("Export Markdown") { model.exportSelectedSessionOutlineMarkdown() }
                        .disabled(session.transcriptURL == nil)
                    Divider()
                    Button("Move to Recently Deleted…", systemImage: "trash", role: .destructive) {
                        confirmsDelete = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if !model.sessionEditorSegments.isEmpty {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.sessionEditorSegments) { segment in
                        CompactTranscriptRow(model: model, session: session, segment: segment)
                        Divider().padding(.leading, 86)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        } else if let error = session.metadata.errorMessage {
            ContentUnavailableView(
                "Transcription failed",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if !model.sessionEditorTranscriptDraft.isEmpty {
            ScrollView {
                Text(model.sessionEditorTranscriptDraft)
                    .textSelection(.enabled)
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(28)
            }
        } else {
            ContentUnavailableView(
                "No transcript yet",
                systemImage: "waveform",
                description: Text("The audio is saved. Start transcription when you are ready.")
            )
        }
    }
}

private struct RenameSessionSheet: View {
    @Binding var title: String
    let onCancel: () -> Void
    let onRename: () -> Void
    @FocusState private var titleIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Session")
                .font(.title3.weight(.semibold))
            TextField("Session title", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleIsFocused)
                .onSubmit {
                    if canRename { onRename() }
                }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: onRename)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRename)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { titleIsFocused = true }
    }

    private var canRename: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct ActiveSessionProgress: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if let progress = model.activeTranscriptionJob?.progress {
                ProgressView(value: progress)
                    .frame(maxWidth: 180)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(model.activeTranscriptionJob?.statusText ?? "Transcribing…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Stop") { model.cancelActiveTranscription() }
                .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SpeakerEditorStrip: View {
    @ObservedObject var model: AppModel
    let session: ContoraSession

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Speakers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(speakers, id: \.id) { speaker in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(speakerColor(speaker.id))
                                .frame(width: 8, height: 8)
                            TextField("Speaker name", text: Binding(
                                get: { model.displayName(forSpeakerID: speaker.id, fallback: speaker.name) },
                                set: { model.updateSpeakerName(speakerID: speaker.id, newName: $0) }
                            ))
                            .textFieldStyle(.plain)
                            .frame(width: 112)

                            if let sample = firstSegment(for: speaker.id) {
                                Button {
                                    model.playSegment(sample, in: session)
                                } label: {
                                    Image(systemName: model.playingSegmentID == sample.id ? "stop.fill" : "play.fill")
                                }
                                .buttonStyle(.borderless)
                                .help("Play a sample from \(speaker.name)")
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.quaternary.opacity(0.75), in: Capsule())
                        .help(speaker.id)
                    }
                }
            }
        }
    }

    private var speakers: [(id: String, name: String)] {
        var seen = Set<String>()
        return model.sessionEditorSegments.compactMap { segment in
            guard seen.insert(segment.speakerID).inserted else { return nil }
            return (segment.speakerID, segment.speakerName)
        }
    }

    private func firstSegment(for speakerID: String) -> EditableSessionSegment? {
        model.sessionEditorSegments.first(where: { $0.speakerID == speakerID })
    }
}

private struct CompactTranscriptRow: View {
    @ObservedObject var model: AppModel
    let session: ContoraSession
    let segment: EditableSessionSegment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Button {
                model.playSegment(segment, in: session)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.playingSegmentID == segment.id ? "stop.fill" : "play.fill")
                        .font(.caption2)
                    Text(segment.timestampDisplay)
                        .monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 70, alignment: .leading)
            .help("Play \(segment.timestampRangeDisplay)")

            HStack(spacing: 6) {
                Circle()
                    .fill(speakerColor(segment.speakerID))
                    .frame(width: 7, height: 7)
                Text(model.displayName(forSpeakerID: segment.speakerID, fallback: segment.speakerName))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(width: 118, alignment: .leading)

            TextField("Transcript text", text: Binding(
                get: { segment.text },
                set: { model.updateSegmentText(segmentID: segment.id, newText: $0) }
            ), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

private struct SessionInspectorView: View {
    @ObservedObject var model: AppModel
    let session: ContoraSession

    var body: some View {
        Form {
            Section("Session") {
                LabeledContent("Created", value: SessionRowView.dateFormatter.string(from: session.createdAt))
                LabeledContent("Duration", value: duration)
                LabeledContent("Status", value: status)
                if let language = session.metadata.language {
                    LabeledContent("Language", value: language)
                }
            }

            Section("Files") {
                Button("Recording in Finder") { model.revealSession(session) }
                Button("Transcript in Finder") { model.revealTranscript(session) }
                    .disabled(session.transcriptURL == nil)
            }

            if let endpoint = session.metadata.endpoint {
                Section("Technical") {
                    LabeledContent("Source", value: session.metadata.mode ?? "Unknown")
                    LabeledContent("Backend") {
                        Text(endpoint)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var duration: String {
        guard let seconds = session.metadata.audioSeconds else { return "Unknown" }
        let value = Int(seconds)
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }

    private var status: String {
        if session.metadata.success == false { return "Failed" }
        return session.transcriptURL == nil ? "Audio only" : "Transcribed"
    }
}

private func speakerColor(_ speakerID: String) -> Color {
    let palette: [Color] = [.blue, .purple, .green, .orange, .pink, .teal, .indigo, .mint]
    let seed = speakerID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
    return palette[seed % palette.count]
}
