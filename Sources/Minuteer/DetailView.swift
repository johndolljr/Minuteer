import SwiftUI
import AppKit
import MinuteerCore

struct DetailView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    enum ActiveDetailSheet: Identifiable {
        case speakerMapping
        case splitTurn(TranscriptTurn)
        case calendarPicker(AudioRecordingFile)

        var id: String {
            switch self {
            case .speakerMapping:
                return "speakerMapping"
            case .splitTurn(let turn):
                return "splitTurn-\(turn.id)"
            case .calendarPicker(let file):
                return "calendarPicker-\(file.id)"
            }
        }
    }

    @State private var showRawMarkdown: Bool = false
    @State private var isEditingTranscript: Bool = false
    @State private var editedTranscript: String = ""
    @State private var activeSheet: ActiveDetailSheet? = nil
    @State private var showRawTranscript: Bool = false
    @State private var editingTurnIndex: Int? = nil
    @State private var editingTurnText: String = ""
    @State private var isEditingTitle: Bool = false
    @State private var editingTitleText: String = ""

    // Speaker Creation & Renaming Alerts
    @State private var showNewTurnSpeakerAlert: Bool = false
    @State private var speakerPromptTargetTurn: TranscriptTurn? = nil
    @State private var showRenameAllSpeakerAlert: Bool = false
    @State private var speakerToRename: String = ""
    @State private var showAddSpeakerToDirectoryAlert: Bool = false
    @State private var newSpeakerInput: String = ""

    var body: some View {
        Group {
            if let file = model.selectedRecording {
                selectedFileDetailView(for: file)
            } else {
                emptyStateView
            }
        }
        .onChange(of: model.selectedRecordingID) { _, _ in
            isEditingTranscript = false
            editingTurnIndex = nil
            isEditingTitle = false
            editingTitleText = ""
            activeSheet = nil
        }
        .sheet(item: $activeSheet) { sheet in
            if let file = model.selectedRecording {
                switch sheet {
                case .speakerMapping:
                    SpeakerMappingSheet(model: model, file: file)
                case .splitTurn(let turn):
                    SplitTurnSheet(
                        model: model,
                        file: file,
                        turn: turn,
                        detectedSpeakers: Array(Set(TranscriptTurn.parseTurns(from: model.activeTranscript(for: file)).map { $0.speaker })).sorted()
                    )
                case .calendarPicker(let targetFile):
                    CalendarEventPickerSheet(model: model, file: targetFile)
                }
            }
        }
        .alert("New Speaker for this Turn", isPresented: $showNewTurnSpeakerAlert) {
            TextField("Speaker Name (e.g. Dennis)", text: $newSpeakerInput)
            Button("Assign") {
                let clean = newSpeakerInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty, let targetTurn = speakerPromptTargetTurn, let file = model.selectedRecording {
                    model.addSpeaker(name: clean)
                    model.updateTurnSpeaker(in: file, turnIndex: targetTurn.id, newSpeaker: clean)
                }
                newSpeakerInput = ""
                speakerPromptTargetTurn = nil
            }
            Button("Cancel", role: .cancel) {
                newSpeakerInput = ""
                speakerPromptTargetTurn = nil
            }
        } message: {
            Text("Enter the name of the speaker for this dialogue turn.")
        }
        .alert("Rename All '\(speakerToRename)' Turns", isPresented: $showRenameAllSpeakerAlert) {
            TextField("New Speaker Name (e.g. Baron)", text: $newSpeakerInput)
            Button("Rename All") {
                let clean = newSpeakerInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty && !speakerToRename.isEmpty, let file = model.selectedRecording {
                    model.addSpeaker(name: clean)
                    model.renameSpeaker(in: file, from: speakerToRename, to: clean)
                }
                newSpeakerInput = ""
                speakerToRename = ""
            }
            Button("Cancel", role: .cancel) {
                newSpeakerInput = ""
                speakerToRename = ""
            }
        } message: {
            Text("Enter the new speaker name to replace all occurrences of '\(speakerToRename)' across this recording.")
        }
        .alert("Add New Speaker", isPresented: $showAddSpeakerToDirectoryAlert) {
            TextField("Speaker Full Name", text: $newSpeakerInput)
            Button("Add") {
                let clean = newSpeakerInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    model.addSpeaker(name: clean)
                }
                newSpeakerInput = ""
            }
            Button("Cancel", role: .cancel) {
                newSpeakerInput = ""
            }
        } message: {
            Text("Enter the name of the new speaker to add to your speaker directory.")
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.18), Color.purple.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 96, height: 96)

                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor, Color.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 6) {
                Text("Ready for Your Audio")
                    .font(.title2.weight(.bold))

                Text("Pick a recording from the sidebar to review transcripts, listen with the studio deck, or let AI synthesize your notes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            HStack(spacing: 12) {
                Label("Intelligent Session Types", systemImage: "sparkles")
                Text("•")
                Label("Auto Calendar Sync", systemImage: "calendar")
                Text("•")
                Label("100% Local AI", systemImage: "lock.shield")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func selectedFileDetailView(for file: AudioRecordingFile) -> some View {
        VStack(spacing: 0) {
            // Meeting & Session Hero Banner (Unified, no stacked bars)
            meetingHeroBanner(for: file)
                .background(Color(NSColor.windowBackgroundColor))

            // Error Banner
            if let errorMsg = file.errorMessage, file.status == .failed {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(errorMsg)
                        .font(.callout)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Retry Processing") {
                        model.processFile(file)
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.red.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 18)
                .padding(.top, 4)
            }

            // Real-time Transcription Progress Banner
            if file.status == .transcribing {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Transcribing with \(model.activeModelDisplayName) (CoreML)...", systemImage: "waveform.badge.magnifyingglass")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.blue)
                        Spacer()
                        Text("\(Int(file.transcriptionProgress * 100))%")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .monospacedDigit()
                            .foregroundStyle(.blue)

                        Button("Stop", systemImage: "stop.fill") {
                            model.cancelProcessing()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                    }
                    ProgressView(value: max(file.transcriptionProgress, 0.03))
                        .progressViewStyle(.linear)
                    Text("Processing on-device Neural Engine. No cloud upload.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 18)
                .padding(.top, 4)
            }

            // Real-time Summarization Progress Banner
            if file.status == .summarizing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Synthesizing Summary with \(model.summarizerEngineDisplayName)...")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.purple)
                        Text("Processing with '\(file.sessionType ?? model.activeSessionType.name)' prompt instructions...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Stop", systemImage: "stop.fill") {
                        model.cancelProcessing()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }
                .padding(10)
                .background(Color.purple.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 18)
                .padding(.top, 4)
            }

            // Studio Waveform Deck & Scrubber
            AudioPlayerView(model: model)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)

            // In-Context Detail View Mode Switcher
            HStack {
                Picker("View Mode", selection: $model.selectedTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.regular)
                .labelsHidden()
                .frame(maxWidth: 320)

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)

            Divider()

            // Tab Content
            switch model.selectedTab {
            case .summary:
                summaryTabView(for: file)
            case .transcript:
                transcriptTabView(for: file)
            case .fileInfo:
                fileInfoTabView(for: file)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func meetingHeroBanner(for file: AudioRecordingFile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1: Title & Actions Toolbar
            HStack(alignment: .center, spacing: 12) {
                if isEditingTitle {
                    HStack(spacing: 6) {
                        TextField("Note Title", text: $editingTitleText)
                            .textFieldStyle(.roundedBorder)
                            .font(.title2.weight(.bold))
                            .frame(maxWidth: 420)
                            .onSubmit {
                                saveTitle(for: file)
                            }

                        Button("Save") {
                            saveTitle(for: file)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)

                        Button("Cancel") {
                            isEditingTitle = false
                        }
                        .controlSize(.small)
                    }
                } else {
                    HStack(spacing: 8) {
                        Text(file.noteTitle ?? file.displayName)
                            .font(.title2)
                            .fontWeight(.bold)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(file.noteTitle ?? file.displayName)

                        Button {
                            editingTitleText = file.noteTitle ?? file.displayName
                            isEditingTitle = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Rename note & file (Enter)")
                    }
                }

                Spacer()

                // Actions Toolbar
                HStack(spacing: 8) {
                    if let mdPath = file.markdownPath, FileManager.default.fileExists(atPath: mdPath.path) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([mdPath])
                        } label: {
                            Label("Reveal Note", systemImage: "arrow.up.forward.app")
                        }
                        .controlSize(.small)
                        .lineLimit(1)
                        .fixedSize()
                        .help("Reveal markdown note in Finder")
                    }

                    if file.status == .completed || file.transcript != nil {
                        Menu {
                            Button {
                                model.autoIdentifySpeakers(in: file)
                            } label: {
                                Label("Auto-Identify Speakers with Voiceprints", systemImage: "person.crop.circle.badge.checkmark")
                            }

                            Button {
                                model.retranscribeFile(file)
                            } label: {
                                Label("Re-transcribe Audio & Summarize", systemImage: "arrow.clockwise")
                            }

                            Button {
                                model.resummarizeFile(file, sessionConfig: model.sessionConfig(for: file))
                            } label: {
                                Label("Update Summary Only", systemImage: "sparkles")
                            }
                        } label: {
                            Label("Re-process", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .menuStyle(.borderedButton)
                        .controlSize(.small)
                        .lineLimit(1)
                        .fixedSize()
                        .help("Update summary or re-transcribe audio")
                    } else {
                        Button {
                            model.processFile(file)
                        } label: {
                            Label(file.status == .failed ? "Retry" : "Process Now", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .lineLimit(1)
                        .fixedSize()
                        .keyboardShortcut("r", modifiers: .command)
                    }

                    Button(role: .destructive) {
                        model.promptDeleteFile(file)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete recording from library")
                }
            }

            // Row 2: Clean Metadata Row
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                    Text(file.displayName)
                        .font(.caption.weight(.medium))
                }
                Text("•")
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text(file.formattedDate)
                        .font(.caption)
                }
                Text("•")
                Text(file.formattedDuration)
                    .font(.caption)
                Text("•")
                Text(file.formattedFileSize)
                    .font(.caption)

                if file.url.path.hasPrefix(model.audioLibraryDirectoryPath) {
                    Text("•")
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                        Text("Saved to Mac")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .foregroundStyle(.secondary)

            // Row 3: Classifiers & Calendar Context Badges
            HStack(alignment: .center, spacing: 8) {
                // Session Type Menu Tag
                let sessionConfig = model.sessionConfig(for: file)
                let sessionSlug = file.sessionType ?? sessionConfig.slug
                let sessionName = file.sessionType ?? sessionConfig.name

                Menu {
                    ForEach(model.sessionTypes) { session in
                        Button {
                            model.setSessionType(for: file, to: session)
                        } label: {
                            if session.id == sessionConfig.id {
                                Label("\(session.glyph)  \(session.name)", systemImage: "checkmark")
                            } else {
                                Text("\(session.glyph)  \(session.name)")
                            }
                        }
                    }

                    Divider()

                    Button {
                        model.autoClassifyFile(file)
                    } label: {
                        Label("Auto-Detect with \(model.summarizerEngineDisplayName)", systemImage: "sparkles")
                    }
                    .disabled(file.transcript == nil)
                } label: {
                    HStack(spacing: 5) {
                        Text("\(SessionTypeConfig.glyph(for: sessionSlug))  \(sessionName)")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .lineLimit(1)
                .fixedSize()
                .help("Session Type & Prompt Template")

                if let conf = file.classificationConfidence, conf > 0.80 {
                    HStack(spacing: 3) {
                        Text("✨")
                            .font(.system(size: 9))
                        Text("\(Int(conf * 100))% match")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.purple.opacity(0.12))
                    .foregroundStyle(.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .lineLimit(1)
                    .fixedSize()
                    .help("Autonomous classification confidence: \(Int(conf * 100))%")
                }

                // Calendar Event Tag
                if let event = file.calendarEvent {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(hex: event.calendarColorHex ?? "#007AFF"))
                            .frame(width: 7, height: 7)

                        Text(event.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 180, alignment: .leading)

                        Text("•  \(event.formattedTimeRange)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Button {
                            model.associateCalendarEvent(file: file, event: nil)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Unlink calendar event")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .onTapGesture {
                        activeSheet = .calendarPicker(file)
                    }
                    .help("Calendar Event: \(event.title)\nTime: \(event.formattedTimeRange)\nCalendar: \(event.calendarTitle)\nClick to change")
                } else {
                    Button {
                        activeSheet = .calendarPicker(file)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar.badge.plus")
                                .font(.system(size: 10))
                            Text("Link Meeting")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .lineLimit(1)
                    .fixedSize()
                    .help("Link a meeting from macOS Calendar")
                }

                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private func saveTitle(for file: AudioRecordingFile) {
        let trimmed = editingTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            model.updateNoteTitle(in: file, newTitle: trimmed)
        }
        isEditingTitle = false
    }

    private func summaryTabView(for file: AudioRecordingFile) -> some View {
        let activeSummary = file.markdownSummary ?? resolvedSummaryFromDisk(for: file)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let summary = activeSummary, !summary.isEmpty {
                    HStack(spacing: 8) {
                        Text("\(model.summarizerEngineDisplayName) Summary")
                            .font(.headline)
                            .lineLimit(1)

                        Spacer()

                        Picker("View Mode", selection: $showRawMarkdown) {
                            Text("Rendered").tag(false)
                            Text("Raw").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .labelsHidden()
                        .frame(width: 140)

                        Button {
                            model.resummarizeFile(file, sessionConfig: model.sessionConfig(for: file))
                        } label: {
                            Label("Update", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .controlSize(.small)
                        .lineLimit(1)
                        .fixedSize()
                        .help("Re-summarize existing transcript using the active session type")

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(summary, forType: .string)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .controlSize(.small)
                        .lineLimit(1)
                        .fixedSize()
                        .help("Copy Markdown note to clipboard")
                    }

                    if let event = file.calendarEvent {
                        meetingInfoCard(event)
                    }

                    if showRawMarkdown {
                        Text(summary)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineSpacing(4)
                    } else {
                        RenderedMarkdownView(markdown: summary)
                    }
                } else if file.status == .transcribing {
                    VStack(spacing: 12) {
                        ProgressView(value: max(file.transcriptionProgress, 0.03))
                            .frame(maxWidth: 240)
                        Text("Transcribing audio (\(Int(file.transcriptionProgress * 100))%)...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if file.status == .summarizing {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("Synthesizing summary with \(model.summarizerEngineDisplayName)...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if file.status == .failed {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.red)
                        Text("Processing Failed")
                            .font(.headline)
                        Text(file.errorMessage ?? "An error occurred during transcription or summarization.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                        Button("Retry Processing") {
                            model.processFile(file)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("No summary generated yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Process Recording") {
                            model.processFile(file)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func meetingInfoCard(_ event: CalendarEventInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: event.calendarColorHex ?? "#007AFF"))
                    .frame(width: 8, height: 8)
                Text(event.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("•")
                    .foregroundStyle(.secondary)
                Text(event.formattedTimeRange)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("•")
                    .foregroundStyle(.secondary)
                Text(event.calendarTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let (displayText, url) = event.cleanLocation {
                HStack(spacing: 4) {
                    Image(systemName: url != nil ? "video.fill" : "location.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let targetURL = url {
                        Link(displayText, destination: targetURL)
                            .font(.caption)
                    } else {
                        Text(displayText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !event.attendees.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    let text = event.attendees.count > 4
                        ? "\(event.attendees.prefix(4).joined(separator: ", ")) (+\(event.attendees.count - 4) more)"
                        : event.attendees.joined(separator: ", ")
                    Text("Invitees: \(text)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let agenda = event.cleanNotes {
                DisclosureGroup("Meeting Agenda & Topics") {
                    Text(agenda)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
                .font(.caption)
                .foregroundStyle(.primary)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }

    private func transcriptTabView(for file: AudioRecordingFile) -> some View {
        let activeTranscript = file.transcript ?? resolvedTranscriptFromDisk(for: file)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isEditingTranscript {
                    rawTranscriptEditorView(for: file)
                } else if let transcript = activeTranscript, !transcript.isEmpty {
                    // Header Toolbar
                    HStack(spacing: 8) {
                        Text("Audio Transcript & Speaker Tracking")
                            .font(.headline)
                            .lineLimit(1)

                        Spacer()

                        Picker("View Mode", selection: $showRawTranscript) {
                            Text("Speakers").tag(false)
                            Text("Raw").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .labelsHidden()
                        .frame(width: 140)

                        Button {
                            activeSheet = .speakerMapping
                        } label: {
                            Label("Identify", systemImage: "person.2.badge.gearshape.fill")
                        }
                        .controlSize(.small)
                        .lineLimit(1)
                        .fixedSize()
                        .help("Map detected speakers (Speaker 1, 2, ...) to known people or create new speaker profiles")

                        Button {
                            newSpeakerInput = ""
                            showAddSpeakerToDirectoryAlert = true
                        } label: {
                            Label("Add Speaker", systemImage: "person.badge.plus")
                        }
                        .controlSize(.small)
                        .lineLimit(1)
                        .fixedSize()
                        .help("Add a new speaker profile to the directory")

                        if showRawTranscript {
                            Button {
                                editedTranscript = transcript
                                isEditingTranscript = true
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .controlSize(.small)
                            .lineLimit(1)
                            .fixedSize()
                        }

                        Menu {
                            Button("Re-transcribe with \(model.activeModelDisplayName)") {
                                model.retranscribeFile(file)
                            }
                            Divider()
                            ForEach(TranscriptionModelOption.availableModels) { option in
                                let perf = option.performance(for: DeviceHardware.currentTier)
                                Button {
                                    if TranscriptionModelOption.isModelDownloaded(option.id) {
                                        model.whisperModelName = option.id
                                        model.retranscribeFile(file)
                                    } else {
                                        model.downloadAndSelectModel(option)
                                    }
                                } label: {
                                    if option.id == model.whisperModelName {
                                        Label("\(option.displayName) (Active • \(perf.badgeText))", systemImage: "checkmark")
                                    } else if TranscriptionModelOption.isModelDownloaded(option.id) {
                                        Text("\(option.displayName) (Ready • \(perf.badgeText))")
                                    } else {
                                        Text("\(option.displayName) (\(option.sizeDescription) • \(perf.badgeText)) - Download")
                                    }
                                }
                            }
                            Divider()
                            Button("Manage & Download Models in Settings...") {
                                openSettings()
                            }
                        } label: {
                            Label("Re-transcribe", systemImage: "arrow.clockwise")
                        } primaryAction: {
                            model.retranscribeFile(file)
                        }
                        .menuStyle(.borderedButton)
                        .controlSize(.small)
                        .lineLimit(1)
                        .fixedSize()
                        .help("Re-transcribe with \(model.activeModelDisplayName). Click arrow to select or download other models.")

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(transcript, forType: .string)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .controlSize(.small)
                        .lineLimit(1)
                        .fixedSize()
                        .help("Copy transcript to clipboard")
                    }

                    if let downloading = model.downloadingModelID {
                        HStack(spacing: 8) {
                            ProgressView(value: model.modelDownloadProgress)
                                .progressViewStyle(.linear)
                                .frame(width: 120)
                            Text("Downloading \(TranscriptionModelOption.availableModels.first(where: { $0.id == downloading })?.displayName ?? downloading) (\(Int(model.modelDownloadProgress * 100))%)...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    if let toast = model.speakerPropagationToast {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(Color.accentColor)
                            Text(toast)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                            Spacer()
                            Button {
                                withAnimation {
                                    model.speakerPropagationToast = nil
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .transition(.opacity)
                    }

                    if showRawTranscript {
                        Text(transcript)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineSpacing(4)
                    } else {
                        interactiveTurnsView(for: file, transcript: transcript)
                    }
                } else if file.status == .transcribing {
                    VStack(spacing: 12) {
                        ProgressView(value: max(file.transcriptionProgress, 0.03))
                            .frame(maxWidth: 240)
                        Text("Transcribing audio (\(Int(file.transcriptionProgress * 100))%)...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("No transcript available.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button {
                            model.retranscribeFile(file)
                        } label: {
                            Label("Transcribe Audio", systemImage: "waveform.badge.magnifyingglass")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rawTranscriptEditorView(for file: AudioRecordingFile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("Editing Audio Transcript", systemImage: "pencil.line")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)

                Spacer()

                Button("Cancel") {
                    isEditingTranscript = false
                }
                .controlSize(.small)

                Button {
                    model.updateTranscript(for: file, newTranscript: editedTranscript)
                    isEditingTranscript = false
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .controlSize(.small)

                Button {
                    model.updateTranscript(for: file, newTranscript: editedTranscript)
                    isEditingTranscript = false
                    model.resummarizeFile(file, sessionConfig: model.sessionConfig(for: file))
                } label: {
                    Label("Save & Reprocess Summary", systemImage: "sparkles")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }

            TextEditor(text: $editedTranscript)
                .font(.system(.body, design: .monospaced))
                .lineSpacing(4)
                .frame(minHeight: 340)
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.35), lineWidth: 1))

            Text("Edit recognition mistakes, adjust speaker labels (e.g. `**Name**: ...`), or add notes. Click **Save & Reprocess Summary** to synthesize updated notes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func interactiveTurnsView(for file: AudioRecordingFile, transcript: String) -> some View {
        let turns = model.turns(for: file)
        let uniqueSpeakers = Array(Set(turns.map { $0.speaker })).sorted()

        var speakerOrder: [String] = []
        for t in turns {
            if !speakerOrder.contains(t.speaker) {
                speakerOrder.append(t.speaker)
            }
        }

        var allCandidates: [String] = []
        for s in uniqueSpeakers {
            let tr = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tr.isEmpty && !allCandidates.contains(tr) {
                allCandidates.append(tr)
            }
        }
        for s in model.speakers.map(\.name) {
            let tr = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tr.isEmpty && !allCandidates.contains(tr) {
                allCandidates.append(tr)
            }
        }
        allCandidates.sort()

        let turnSides = computeTurnSides(for: turns)

        return LazyVStack(spacing: 16) {
            ForEach(turns) { turn in
                let isTrailing = turnSides[turn.id] ?? false
                turnCardView(
                    for: turn,
                    file: file,
                    allCandidates: allCandidates,
                    isTrailing: isTrailing
                )
            }
        }
        .padding(.vertical, 6)
    }

    private func computeTurnSides(for turns: [TranscriptTurn]) -> [Int: Bool] {
        guard Set(turns.map(\.speaker)).count > 1 else {
            return [:]
        }
        var sides: [Int: Bool] = [:]
        var currentSide = false
        var lastSpeaker: String? = nil

        for turn in turns {
            if let last = lastSpeaker, turn.speaker != last {
                currentSide.toggle()
            }
            sides[turn.id] = currentSide
            lastSpeaker = turn.speaker
        }
        return sides
    }

    private func speakerAvatarColor(for name: String) -> Color {
        let colors: [Color] = [.blue, .purple, .teal, .indigo, .orange, .pink, .cyan, .mint]
        let hash = abs(name.hashValue)
        return colors[hash % colors.count]
    }

    private func speakerInitials(for name: String) -> String {
        let parts = name.split(separator: " ").filter { !$0.isEmpty }
        if parts.count >= 2 {
            let first = parts[0].prefix(1)
            let second = parts[1].prefix(1)
            return "\(first)\(second)".uppercased()
        } else if let first = parts.first {
            return String(first.prefix(2)).uppercased()
        }
        return "?"
    }

    @ViewBuilder
    private func turnCardView(
        for turn: TranscriptTurn,
        file: AudioRecordingFile,
        allCandidates: [String],
        isTrailing: Bool
    ) -> some View {
        let speakerColor = speakerAvatarColor(for: turn.speaker)
        let isEditing = editingTurnIndex == turn.id

        if isTrailing {
            // Trailing / Right-aligned conversation turn
            HStack(alignment: .top, spacing: 10) {
                Spacer(minLength: 40)

                VStack(alignment: .trailing, spacing: 5) {
                    // Controls and speaker name grouped together on the right
                    HStack(alignment: .center, spacing: 6) {
                        turnActionButtons(for: turn, file: file, isEditing: isEditing)
                        timestampJumpButton(for: turn)
                        speakerMenu(for: turn, file: file, allCandidates: allCandidates, color: speakerColor)
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    messageBubble(for: turn, file: file, isEditing: isEditing, isTrailing: true)
                }
                .frame(maxWidth: 580, alignment: .trailing)

                avatarView(speaker: turn.speaker, color: speakerColor)
            }
            .padding(.vertical, 2)
        } else {
            // Leading / Left-aligned conversation turn
            HStack(alignment: .top, spacing: 10) {
                avatarView(speaker: turn.speaker, color: speakerColor)

                VStack(alignment: .leading, spacing: 5) {
                    // Speaker name and controls grouped together on the left
                    HStack(alignment: .center, spacing: 6) {
                        speakerMenu(for: turn, file: file, allCandidates: allCandidates, color: speakerColor)
                        timestampJumpButton(for: turn)
                        turnActionButtons(for: turn, file: file, isEditing: isEditing)
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    messageBubble(for: turn, file: file, isEditing: isEditing, isTrailing: false)
                }
                .frame(maxWidth: 580, alignment: .leading)

                Spacer(minLength: 40)
            }
            .padding(.vertical, 2)
        }
    }

    private func avatarView(speaker: String, color: Color) -> some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.85), color],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 32, height: 32)
                .shadow(color: color.opacity(0.25), radius: 3, y: 1)

            Text(speakerInitials(for: speaker))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.top, 2)
    }

    private func speakerMenu(
        for turn: TranscriptTurn,
        file: AudioRecordingFile,
        allCandidates: [String],
        color: Color
    ) -> some View {
        Menu {
            Section("Change Speaker for this Turn Only") {
                ForEach(allCandidates, id: \.self) { spk in
                    Button {
                        model.updateTurnSpeaker(in: file, turnIndex: turn.id, newSpeaker: spk)
                    } label: {
                        if spk == turn.speaker {
                            Label(spk, systemImage: "checkmark")
                        } else {
                            Text(spk)
                        }
                    }
                }

                Divider()

                Button {
                    speakerPromptTargetTurn = turn
                    newSpeakerInput = ""
                    showNewTurnSpeakerAlert = true
                } label: {
                    Label("New Speaker for this Turn...", systemImage: "person.badge.plus")
                }
            }

            Section("Rename ALL '\(turn.speaker)' Turns in Recording") {
                ForEach(allCandidates.filter { $0 != turn.speaker }, id: \.self) { spk in
                    Button("Rename all to '\(spk)'") {
                        model.renameSpeaker(in: file, from: turn.speaker, to: spk)
                    }
                }

                Divider()

                Button {
                    speakerToRename = turn.speaker
                    newSpeakerInput = ""
                    showRenameAllSpeakerAlert = true
                } label: {
                    Label("Rename all to New Speaker...", systemImage: "person.badge.plus")
                }
            }

            Section {
                Button("Open Speaker Mapping Sheet...") {
                    activeSheet = .speakerMapping
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(turn.speaker)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(color.opacity(0.8))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Reassign or rename speaker")
    }

    @ViewBuilder
    private func timestampJumpButton(for turn: TranscriptTurn) -> some View {
        if let timeStr = turn.timestamp, !timeStr.isEmpty {
            Button {
                if let seconds = turn.timestampSeconds {
                    model.player.seek(to: seconds)
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.accentColor)
                    Text(timeStr)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.75))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help("Play audio at \(timeStr)")
        }
    }

    @ViewBuilder
    private func turnActionButtons(for turn: TranscriptTurn, file: AudioRecordingFile, isEditing: Bool) -> some View {
        HStack(spacing: 5) {
            if turn.id > 0 {
                Button {
                    model.mergeTurnWithPrevious(in: file, turnIndex: turn.id)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.turn.left.up")
                            .font(.system(size: 9, weight: .medium))
                        Text("Merge")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
                    .foregroundStyle(.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .help("Merge with turn above")
            }

            Button {
                activeSheet = .splitTurn(turn)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "scissors")
                        .font(.system(size: 9, weight: .medium))
                    Text("Split")
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
                .foregroundStyle(.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help("Split this turn")

            if isEditing {
                Button("Cancel") {
                    editingTurnIndex = nil
                }
                .controlSize(.mini)

                Button("Done") {
                    model.updateTurnText(in: file, turnIndex: turn.id, newText: editingTurnText)
                    editingTurnIndex = nil
                }
                .controlSize(.mini)
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    editingTurnIndex = turn.id
                    editingTurnText = turn.text
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help("Edit text for this turn")
            }
        }
    }

    @ViewBuilder
    private func messageBubble(
        for turn: TranscriptTurn,
        file: AudioRecordingFile,
        isEditing: Bool,
        isTrailing: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditing {
                TextField("Dialogue text", text: $editingTurnText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .lineLimit(2...8)
            } else {
                Text(turn.text)
                    .font(.system(size: 13, weight: .regular))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: isTrailing ? 14 : 4,
                bottomLeadingRadius: 14,
                bottomTrailingRadius: isTrailing ? 4 : 14,
                topTrailingRadius: 14
            )
            .fill(
                isTrailing
                    ? Color.accentColor.opacity(0.18)
                    : Color(NSColor.controlBackgroundColor).opacity(0.85)
            )
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: isTrailing ? 14 : 4,
                bottomLeadingRadius: 14,
                bottomTrailingRadius: isTrailing ? 4 : 14,
                topTrailingRadius: 14
            )
            .stroke(
                isEditing
                    ? Color.accentColor
                    : (isTrailing ? Color.accentColor.opacity(0.32) : Color.secondary.opacity(0.15)),
                lineWidth: 1
            )
        )
    }

    private func fileInfoTabView(for file: AudioRecordingFile) -> some View {
        Form {
            Section("File Information") {
                LabeledContent("Audio File Path", value: file.url.path)
                LabeledContent("File Name", value: file.filename)
                LabeledContent("Display Name", value: file.displayName)
                LabeledContent("File Size", value: file.formattedFileSize)
                LabeledContent("Duration", value: file.formattedDuration)
                LabeledContent("Date Created", value: file.formattedDate)
                LabeledContent("Status", value: file.status.rawValue)
                LabeledContent("Session Type", value: file.sessionType ?? model.activeSessionType.name)
                if let err = file.errorMessage {
                    LabeledContent("Error Message", value: err)
                }
                if let path = file.markdownPath {
                    LabeledContent("Exported Markdown Note", value: path.path)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func resolvedSummaryFromDisk(for file: AudioRecordingFile) -> String? {
        if file.status == .transcribing || file.status == .summarizing {
            return nil
        }
        guard let mdPath = file.markdownPath, FileManager.default.fileExists(atPath: mdPath.path),
              let content = try? String(contentsOf: mdPath, encoding: .utf8) else {
            return nil
        }
        return MarkdownExporter.parseMarkdownNote(content).summary
    }

    private func resolvedTranscriptFromDisk(for file: AudioRecordingFile) -> String? {
        if file.status == .transcribing {
            return nil
        }
        guard let mdPath = file.markdownPath, FileManager.default.fileExists(atPath: mdPath.path),
              let content = try? String(contentsOf: mdPath, encoding: .utf8) else {
            return nil
        }
        return MarkdownExporter.parseMarkdownNote(content).transcript
    }
}
