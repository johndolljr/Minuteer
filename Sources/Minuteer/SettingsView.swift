import SwiftUI
import AppKit
import MinuteerCore

public enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case transcription = "Transcription"
    case summarization = "Summarization & LLM"
    case sessionTypes = "Session Types"
    case speakers = "Speakers"
    case calendars = "Calendars"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .transcription: return "waveform"
        case .summarization: return "sparkles"
        case .sessionTypes: return "doc.text"
        case .speakers: return "person.2"
        case .calendars: return "calendar"
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    @State private var selectedTab: SettingsTab = .general
    @State private var isCustomModelSelected: Bool = false

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem {
                    Label(SettingsTab.general.rawValue, systemImage: SettingsTab.general.systemImage)
                }
                .tag(SettingsTab.general)

            transcriptionTab
                .tabItem {
                    Label(SettingsTab.transcription.rawValue, systemImage: SettingsTab.transcription.systemImage)
                }
                .tag(SettingsTab.transcription)

            summarizationTab
                .tabItem {
                    Label(SettingsTab.summarization.rawValue, systemImage: SettingsTab.summarization.systemImage)
                }
                .tag(SettingsTab.summarization)

            sessionTypesTab
                .tabItem {
                    Label(SettingsTab.sessionTypes.rawValue, systemImage: SettingsTab.sessionTypes.systemImage)
                }
                .tag(SettingsTab.sessionTypes)

            speakersTab
                .tabItem {
                    Label(SettingsTab.speakers.rawValue, systemImage: SettingsTab.speakers.systemImage)
                }
                .tag(SettingsTab.speakers)

            calendarsTab
                .tabItem {
                    Label(SettingsTab.calendars.rawValue, systemImage: SettingsTab.calendars.systemImage)
                }
                .tag(SettingsTab.calendars)
        }
        .frame(width: 640, height: 490)
    }

    // MARK: - Tab 1: General
    private var generalTab: some View {
        Form {
            Section("SD Card Volume") {
                LabeledContent("Volume Name") {
                    HStack {
                        TextField("Target Volume Name", text: $model.targetVolumeName)
                            .textFieldStyle(.roundedBorder)
                        Button("Rescan Now") {
                            model.rescanCard()
                        }
                    }
                }
                Text("Monitors for inserted SD card volumes matching this name (case-insensitive). Default: P2_SD.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Auto-process recordings when SD card is inserted", isOn: $model.autoProcessOnInsert)
                    .font(.subheadline)
            }

            Section("Watched Folder Ingestion") {
                Toggle("Enable Watched Folder", isOn: $model.watchDirectoryEnabled)
                    .font(.subheadline)

                if model.watchDirectoryEnabled {
                    LabeledContent("Watch Path") {
                        HStack {
                            Text(model.watchDirectoryPath.isEmpty ? "No folder selected" : model.watchDirectoryPath)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                            Button("Choose...") {
                                chooseWatchDirectory()
                            }

                            if !model.watchDirectoryPath.isEmpty {
                                Button("Reveal") {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.watchDirectoryPath)
                                }
                            }
                        }
                    }
                }
                Text("Continuously monitors this folder for incoming audio files, automatically copying them to your local Mac library and processing them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local Audio Storage & Library") {
                LabeledContent("Storage Path") {
                    HStack {
                        Text(model.audioLibraryDirectoryPath)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        Button("Choose...") {
                            chooseAudioLibraryDirectory()
                        }

                        Button("Reveal") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.audioLibraryDirectoryPath)
                        }
                    }
                }
                Text("Recordings from SD cards and watched folders are copied and safely archived here for offline playback and persistent note access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Delete audio from source after verified copy", isOn: $model.deleteFromSourceAfterCopy)
                    .font(.subheadline)
                Text("Guaranteed safety: Deletes original audio from SD card or watched folder only after file existence, byte size, and SHA256 checksums are strictly verified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Markdown Note Destination") {
                LabeledContent("Export Path") {
                    HStack {
                        Text(model.exportDirectoryPath)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        Button("Choose...") {
                            chooseExportDirectory()
                        }

                        Button("Reveal") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.exportDirectoryPath)
                        }
                    }
                }
                Text("Processed summaries and meeting action items are saved as Markdown notes to your journal or inbox folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Tab 2: Transcription (Whisper CoreML Models)
    private var transcriptionTab: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(Color.accentColor)
                    Text("Your Mac: \(DeviceHardware.chipName) (\(DeviceHardware.physicalMemoryGB) GB)")
                        .font(.caption)
                        .fontWeight(.semibold)

                    Spacer()

                    Text("Tuned for \(DeviceHardware.currentTier.rawValue)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                }

                Text("CoreML models run 100% on-device on Apple Silicon Neural Engine & GPU. Performance ratings are calculated specifically for your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Available CoreML Models") {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(TranscriptionModelOption.availableModels) { option in
                            modelRow(for: option)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 250)
            }
        }
        .formStyle(.grouped)
    }

    private func modelRow(for option: TranscriptionModelOption) -> some View {
        let isDownloaded = TranscriptionModelOption.isModelDownloaded(option.id)
        let isActive = model.whisperModelName == option.id
        let isDownloading = model.downloadingModelID == option.id
        let perfInfo = option.performance(for: DeviceHardware.currentTier)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(option.displayName)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        if perfInfo.isRecommendedForDevice {
                            Text(perfInfo.badgeText)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.18))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        } else if perfInfo.level == .heavy || perfInfo.level == .veryHeavy {
                            Text(perfInfo.badgeText)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.18))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        } else {
                            Text(perfInfo.badgeText)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.15))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }

                        if isActive {
                            HStack(spacing: 2) {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Active")
                            }
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                        }
                    }

                    Text(perfInfo.recommendationNote)
                        .font(.caption2)
                        .foregroundStyle(perfInfo.level == .heavy || perfInfo.level == .veryHeavy ? .orange : .secondary)

                    HStack(spacing: 10) {
                        Label(perfInfo.estimatedSpeedDescription, systemImage: "speedometer")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Label(option.accuracy, systemImage: "target")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Label(option.sizeDescription, systemImage: "internaldrive")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    if isDownloading {
                        HStack(spacing: 4) {
                            ProgressView(value: model.modelDownloadProgress)
                                .progressViewStyle(.linear)
                                .frame(width: 60)
                            Text("\(Int(model.modelDownloadProgress * 100))%")
                                .font(.caption2)
                                .monospacedDigit()
                        }
                    } else if isActive {
                        Text("In Use")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    } else if isDownloaded {
                        Button("Use") {
                            model.whisperModelName = option.id
                        }
                        .controlSize(.mini)
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            model.downloadAndSelectModel(option)
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                        .controlSize(.mini)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(isActive ? 0.7 : 0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Tab 3: Summarization & LLM
    private var summarizationTab: some View {
        Form {
            Section {
                Picker("Engine Provider", selection: $model.config.summarizerProvider) {
                    Text("Apple Intelligence (On-Device)").tag(SummarizerProvider.appleIntelligence)
                    Text("OpenAI-Compatible LLM (BYO Endpoint)").tag(SummarizerProvider.openAICompatible)
                }
                .pickerStyle(.segmented)
                .onChange(of: model.config.summarizerProvider) { _, _ in
                    model.updateSummarizerEngine()
                }
            }

            if model.config.summarizerProvider == .appleIntelligence {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "apple.intelligence")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apple Intelligence FoundationModels")
                                    .font(.headline)
                                Text("SystemLanguageModel • 100% Private & Local")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("Runs natively on your Mac's Neural Engine. No transcripts, notes, or recording data ever leave your computer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section("Endpoint Presets") {
                    HStack(spacing: 6) {
                        Button("OpenAI (Official)") {
                            model.config.openAIEndpoint = "https://api.openai.com/v1"
                            model.config.openAIModelName = "gpt-4o-mini"
                            isCustomModelSelected = false
                            model.updateSummarizerEngine()
                        }
                        .controlSize(.small)

                        Button("Ollama (Local)") {
                            model.config.openAIEndpoint = "http://localhost:11434/v1"
                            model.config.openAIModelName = "llama3.2"
                            isCustomModelSelected = false
                            model.updateSummarizerEngine()
                        }
                        .controlSize(.small)

                        Button("LM Studio") {
                            model.config.openAIEndpoint = "http://localhost:1234/v1"
                            model.config.openAIModelName = "local-model"
                            isCustomModelSelected = false
                            model.updateSummarizerEngine()
                        }
                        .controlSize(.small)

                        Button("Groq") {
                            model.config.openAIEndpoint = "https://api.groq.com/openai/v1"
                            model.config.openAIModelName = "llama-3.3-70b-versatile"
                            isCustomModelSelected = false
                            model.updateSummarizerEngine()
                        }
                        .controlSize(.small)

                        Button("OpenRouter") {
                            model.config.openAIEndpoint = "https://openrouter.ai/api/v1"
                            model.config.openAIModelName = "meta-llama/llama-3.2-3b-instruct"
                            isCustomModelSelected = false
                            model.updateSummarizerEngine()
                        }
                        .controlSize(.small)
                    }
                }

                Section("API Configuration") {
                    LabeledContent("Base URL") {
                        TextField("https://api.openai.com/v1", text: $model.config.openAIEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: model.config.openAIEndpoint) { _, _ in
                                model.updateSummarizerEngine()
                            }
                    }

                    LabeledContent("Model") {
                        HStack(spacing: 6) {
                            Picker("", selection: Binding(
                                get: {
                                    if isCustomModelSelected {
                                        return "custom"
                                    }
                                    return model.allSelectableModels.contains(model.config.openAIModelName)
                                        ? model.config.openAIModelName
                                        : "custom"
                                },
                                set: { newValue in
                                    if newValue == "custom" {
                                        isCustomModelSelected = true
                                    } else {
                                        isCustomModelSelected = false
                                        model.config.openAIModelName = newValue
                                        model.updateSummarizerEngine()
                                    }
                                }
                            )) {
                                Section("Populated Models") {
                                    ForEach(model.allSelectableModels, id: \.self) { m in
                                        Text(m).tag(m)
                                    }
                                }
                                Section {
                                    Text("Custom Model ID...").tag("custom")
                                }
                            }
                            .labelsHidden()

                            Button {
                                model.fetchEndpointModels()
                            } label: {
                                if model.isFetchingModels {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .help("Fetch available models from your server (/v1/models)")
                            .disabled(model.isFetchingModels)
                        }
                    }

                    if isCustomModelSelected {
                        LabeledContent("Custom Model ID") {
                            TextField("model-id", text: $model.config.openAIModelName)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: model.config.openAIModelName) { _, _ in
                                    model.updateSummarizerEngine()
                                }
                        }
                    }

                    LabeledContent("API Key") {
                        SecureField("sk-... (optional for local servers)", text: $model.config.openAIApiKey)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: model.config.openAIApiKey) { _, _ in
                                model.updateSummarizerEngine()
                            }
                    }

                    LabeledContent("Connection") {
                        HStack(spacing: 8) {
                            Button {
                                model.testLLMConnection()
                            } label: {
                                if model.isTestingLLM {
                                    HStack(spacing: 4) {
                                        ProgressView().controlSize(.small)
                                        Text("Pinging...")
                                    }
                                } else {
                                    Label("Test Connection", systemImage: "network")
                                }
                            }
                            .controlSize(.small)
                            .disabled(model.isTestingLLM)

                            if let success = model.llmTestSuccess, let result = model.llmTestResult {
                                HStack(spacing: 4) {
                                    Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(success ? .green : .red)
                                    Text(result)
                                        .font(.caption)
                                        .foregroundStyle(success ? .green : .red)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Tab 4: Session Types
    private var sessionTypesTab: some View {
        Form {
            Section {
                ForEach($model.config.sessionTypes) { $session in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Display Name")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    TextField("Name", text: $session.name)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: session.name) { _, _ in model.saveConfig() }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Slug")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    TextField("Slug", text: $session.slug)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: session.slug) { _, _ in model.saveConfig() }
                                }
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("System Prompt Instructions")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                TextEditor(text: $session.systemInstructions)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(height: 90)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
                                    .onChange(of: session.systemInstructions) { _, _ in model.saveConfig() }
                            }

                            if model.config.sessionTypes.count > 1 {
                                Button(role: .destructive) {
                                    model.deleteSessionType(id: session.id)
                                } label: {
                                    Label("Delete Type", systemImage: "trash")
                                        .foregroundStyle(.red)
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        HStack {
                            Image(systemName: "doc.text.fill")
                                .foregroundStyle(Color.accentColor)
                            Text(session.name)
                                .fontWeight(.medium)
                            Text("(\(session.slug))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if model.selectedSessionTypeID == session.id {
                                Text("Active Default")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        model.addSessionType(
                            name: "New Session",
                            slug: "session",
                            systemInstructions: "Analyze the audio transcript and provide a structured summary with executive overview, key decisions, and next steps."
                        )
                    } label: {
                        Label("Add Session Type", systemImage: "plus")
                    }

                    Button("Reset to Defaults") {
                        model.resetSessionTypesToDefaults()
                    }
                    .controlSize(.small)
                }
                .padding(.top, 2)
            } header: {
                Text("Session Types & Prompts (\(model.config.sessionTypes.count))")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Tab 5: Speakers
    private var speakersTab: some View {
        Form {
            Section {
                if model.speakers.isEmpty {
                    Text("No recurring speakers defined yet. Add known participants to help recognition.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(model.speakers) { speaker in
                                HStack {
                                    Image(systemName: "person.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(speaker.name)
                                            .fontWeight(.medium)
                                        if !speaker.aliases.isEmpty {
                                            Text(speaker.aliases.joined(separator: ", "))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Button(role: .destructive) {
                                        model.deleteSpeaker(id: speaker.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(6)
                                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }

                Button {
                    model.addSpeaker(
                        name: "New Speaker",
                        aliases: [],
                        contextNotes: "Key participant, discussed topics..."
                    )
                } label: {
                    Label("Add Known Speaker", systemImage: "person.badge.plus")
                }
                .controlSize(.small)
            } header: {
                Text("Known Recurring Speakers (\(model.speakers.count))")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseExportDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Folder"
        panel.directoryURL = URL(fileURLWithPath: model.exportDirectoryPath)

        if panel.runModal() == .OK, let selectedURL = panel.url {
            model.exportDirectoryPath = selectedURL.path
        }
    }

    private func chooseAudioLibraryDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Audio Library Folder"
        panel.directoryURL = URL(fileURLWithPath: model.audioLibraryDirectoryPath)

        if panel.runModal() == .OK, let selectedURL = panel.url {
            model.audioLibraryDirectoryPath = selectedURL.path
        }
    }

    private func chooseWatchDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Watched Folder"
        if !model.watchDirectoryPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: model.watchDirectoryPath)
        }

        if panel.runModal() == .OK, let selectedURL = panel.url {
            model.watchDirectoryPath = selectedURL.path
        }
    }

    // MARK: - Tab 6: Calendars
    private var calendarsTab: some View {
        Form {
            Section("macOS Calendar Integration") {
                HStack(spacing: 12) {
                    Circle()
                        .fill(model.isCalendarAuthorized ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.isCalendarAuthorized ? "Connected to macOS EventKit" : "Access Not Authorized")
                            .font(.subheadline.weight(.semibold))
                        Text(model.isCalendarAuthorized
                            ? "Minuteer can search and automatically associate recordings with your calendar events."
                            : "Grant calendar permission to auto-match recordings to your scheduled meetings."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !model.isCalendarAuthorized {
                        Button("Request Access") {
                            Task {
                                _ = await model.requestCalendarAccess()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Discovered Calendars") {
                if !model.isCalendarAuthorized {
                    Text("Authorize calendar access above to view configured macOS calendars.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    let calendars = model.coordinator.calendarService.listCalendars()
                    if calendars.isEmpty {
                        Text("No active calendars found on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        List(calendars, id: \.id) { cal in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color(hex: cal.colorHex))
                                    .frame(width: 8, height: 8)
                                Text(cal.title)
                                    .font(.subheadline)
                                Spacer()
                                Text(cal.sourceTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: 120, maxHeight: 180)
                    }
                }
            }

            Section("Auto-Matching") {
                Toggle("Auto-match recordings within 30 minutes of scheduled meetings", isOn: $model.calendarAutoMatch)
                Text("When enabled, recordings matching calendar event start and end times will automatically adopt the meeting's agenda, attendees, and title.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
