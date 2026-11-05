import SwiftUI
import Observation
import MinuteerCore

public enum DetailTab: String, CaseIterable, Identifiable {
    case summary = "Summary"
    case transcript = "Transcript"
    case fileInfo = "File Info"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .summary: return "doc.text.fill"
        case .transcript: return "quote.bubble.fill"
        case .fileInfo: return "info.circle.fill"
        }
    }
}

@Observable
@MainActor
public final class AppModel {
    public let coordinator: IngestionCoordinator
    public let player: AudioPlayerController
    public let configStorage: AppConfigStorage

    public var config: AppConfig

    public var recordings: [AudioRecordingFile] = []
    public var selectedRecordingID: UUID? {
        didSet {
            if oldValue != selectedRecordingID {
                if let file = selectedRecording,
                   let typeName = file.sessionType,
                   let matched = config.sessionTypes.first(where: { $0.name.caseInsensitiveCompare(typeName) == .orderedSame || $0.slug.caseInsensitiveCompare(typeName) == .orderedSame }) {
                    selectedSessionTypeID = matched.id
                }
                loadAudioForSelectedFile()
            }
        }
    }
    public var pipelineStatus: PipelineStatus = .idle
    public var sdCardStatus: SDCardStatus = .notInserted
    public var selectedTab: DetailTab = .summary

    // Dynamic Session Types & Settings
    public var sessionTypes: [SessionTypeConfig] {
        get { config.sessionTypes }
        set {
            config.sessionTypes = newValue
            coordinator.updateAvailableSessionConfigs(newValue)
            saveConfig()
        }
    }

    public var selectedSessionTypeID: UUID {
        get { config.selectedSessionTypeID }
        set {
            config.selectedSessionTypeID = newValue
            if let matched = config.sessionTypes.first(where: { $0.id == newValue }) {
                coordinator.activeSessionConfig = matched
                coordinator.sessionType = SessionType(rawValue: matched.slug) ?? .custom
            }
            saveConfig()
        }
    }

    public var activeSessionType: SessionTypeConfig {
        config.sessionTypes.first(where: { $0.id == config.selectedSessionTypeID })
            ?? config.sessionTypes.first
            ?? SessionTypeConfig.defaultMeeting
    }

    public var autoProcessOnInsert: Bool {
        get { config.autoProcessOnInsert }
        set {
            config.autoProcessOnInsert = newValue
            coordinator.autoProcessOnInsert = newValue
            saveConfig()
        }
    }

    public var targetVolumeName: String {
        get { config.targetVolumeName }
        set {
            config.targetVolumeName = newValue
            coordinator.sdCardMonitor.targetVolumeName = newValue
            saveConfig()
        }
    }

    public var exportDirectoryPath: String {
        get { config.exportDirectoryPath }
        set {
            config.exportDirectoryPath = newValue
            coordinator.markdownExporter.destinationDirectory = URL(fileURLWithPath: newValue)
            saveConfig()
        }
    }

    public var audioLibraryDirectoryPath: String {
        get { config.audioLibraryDirectoryPath }
        set {
            config.audioLibraryDirectoryPath = newValue
            coordinator.audioLibraryDirectory = URL(fileURLWithPath: newValue)
            saveConfig()
        }
    }

    public var watchDirectoryPath: String {
        get { config.watchDirectoryPath }
        set {
            config.watchDirectoryPath = newValue
            coordinator.watchFolderMonitor.watchDirectoryURL = newValue.isEmpty ? nil : URL(fileURLWithPath: newValue)
            saveConfig()
        }
    }

    public var watchDirectoryEnabled: Bool {
        get { config.watchDirectoryEnabled }
        set {
            config.watchDirectoryEnabled = newValue
            coordinator.watchFolderMonitor.isEnabled = newValue
            saveConfig()
        }
    }

    public var deleteFromSourceAfterCopy: Bool {
        get { config.deleteFromSourceAfterCopy }
        set {
            config.deleteFromSourceAfterCopy = newValue
            coordinator.deleteFromSourceAfterCopy = newValue
            saveConfig()
        }
    }

    public var whisperModelName: String {
        get { config.whisperModelName }
        set {
            config.whisperModelName = newValue
            coordinator.setTranscriptionModel(newValue)
            saveConfig()
        }
    }

    public var activeModelDisplayName: String {
        TranscriptionModelOption.availableModels.first(where: { $0.id == whisperModelName })?.displayName ?? whisperModelName
    }

    public var downloadingModelID: String? = nil
    public var modelDownloadProgress: Double = 0.0
    public var modelDownloadError: String? = nil

    public var isTestingLLM: Bool = false
    public var llmTestResult: String? = nil
    public var llmTestSuccess: Bool? = nil

    public var availableFetchedModels: [String] = []
    public var isFetchingModels: Bool = false

    public static let standardOpenAIModels: [String] = [
        "gpt-4o-mini",
        "gpt-4o",
        "o3-mini",
        "o1",
        "o1-mini",
        "gpt-4-turbo",
        "llama3.2",
        "llama3.3",
        "mistral",
        "qwen2.5",
        "llama-3.3-70b-versatile",
        "meta-llama/llama-3.2-3b-instruct"
    ]

    public var allSelectableModels: [String] {
        var set = Set(Self.standardOpenAIModels)
        for m in availableFetchedModels {
            set.insert(m)
        }
        if !config.openAIModelName.isEmpty {
            set.insert(config.openAIModelName)
        }
        return Array(set).sorted()
    }

    public func fetchEndpointModels() {
        isFetchingModels = true
        let engine = OpenAICompatibleSummarizer(
            endpoint: config.openAIEndpoint,
            modelName: config.openAIModelName,
            apiKey: config.openAIApiKey
        )
        Task { [weak self] in
            do {
                let models = try await engine.fetchAvailableModels()
                await MainActor.run {
                    self?.isFetchingModels = false
                    if !models.isEmpty {
                        self?.availableFetchedModels = models
                    }
                }
            } catch {
                await MainActor.run {
                    self?.isFetchingModels = false
                }
            }
        }
    }

    public var summarizerEngineDisplayName: String {
        if config.summarizerProvider == .openAICompatible {
            let model = config.openAIModelName.isEmpty ? "LLM" : config.openAIModelName
            return "OpenAI-Compatible (\(model))"
        } else {
            return "Apple Intelligence"
        }
    }

    public func updateSummarizerEngine() {
        let engine: any SummarizerEngine = config.summarizerProvider == .openAICompatible
            ? OpenAICompatibleSummarizer(
                endpoint: config.openAIEndpoint,
                modelName: config.openAIModelName,
                apiKey: config.openAIApiKey
            )
            : AppleIntelligenceSummarizer()
        coordinator.setSummarizerEngine(engine)
        saveConfig()
    }

    public func testLLMConnection() {
        isTestingLLM = true
        llmTestResult = nil
        llmTestSuccess = nil
        let engine = OpenAICompatibleSummarizer(
            endpoint: config.openAIEndpoint,
            modelName: config.openAIModelName,
            apiKey: config.openAIApiKey
        )
        Task { [weak self] in
            do {
                let (latency, model) = try await engine.testConnection()
                await MainActor.run {
                    self?.isTestingLLM = false
                    self?.llmTestSuccess = true
                    self?.llmTestResult = "Connected to '\(model)' (Latency: \(latency) ms)"
                }
            } catch {
                await MainActor.run {
                    self?.isTestingLLM = false
                    self?.llmTestSuccess = false
                    self?.llmTestResult = error.localizedDescription
                }
            }
        }
    }

    public func downloadAndSelectModel(_ modelOption: TranscriptionModelOption) {
        let variant = modelOption.id
        downloadingModelID = variant
        modelDownloadProgress = 0.0
        modelDownloadError = nil

        Task { [weak self] in
            guard let self = self else { return }
            do {
                _ = try await WhisperKitEngine.downloadModel(variant: variant) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.modelDownloadProgress = progress
                    }
                }
                await MainActor.run {
                    self.downloadingModelID = nil
                    self.whisperModelName = variant
                }
            } catch {
                await MainActor.run {
                    self.downloadingModelID = nil
                    self.modelDownloadError = error.localizedDescription
                }
            }
        }
    }

    // Backward-compatible properties
    public var sessionType: SessionType {
        get {
            switch activeSessionType.slug.lowercased() {
            case "meeting": return .meeting
            case "therapy": return .therapy
            default: return .custom
            }
        }
        set {
            if let matched = config.sessionTypes.first(where: { $0.slug.caseInsensitiveCompare(newValue.rawValue) == .orderedSame }) {
                selectedSessionTypeID = matched.id
            }
        }
    }

    public var meetingInstructions: String {
        get {
            config.sessionTypes.first(where: { $0.slug == "meeting" })?.systemInstructions
                ?? SummaryPromptTemplate.defaultMeeting.systemInstructions
        }
        set {
            if let idx = config.sessionTypes.firstIndex(where: { $0.slug == "meeting" }) {
                config.sessionTypes[idx].systemInstructions = newValue
                saveConfig()
            }
        }
    }

    public var therapyInstructions: String {
        get {
            config.sessionTypes.first(where: { $0.slug == "therapy" })?.systemInstructions
                ?? SummaryPromptTemplate.defaultTherapy.systemInstructions
        }
        set {
            if let idx = config.sessionTypes.firstIndex(where: { $0.slug == "therapy" }) {
                config.sessionTypes[idx].systemInstructions = newValue
                saveConfig()
            }
        }
    }

    public var customInstructions: String {
        get {
            config.sessionTypes.first(where: { $0.slug == "custom" })?.systemInstructions
                ?? "Generate a concise 3-5 bullet summary with key highlights and next steps."
        }
        set {
            if let idx = config.sessionTypes.firstIndex(where: { $0.slug == "custom" }) {
                config.sessionTypes[idx].systemInstructions = newValue
                saveConfig()
            }
        }
    }

    // UI Dialog State
    public var isSettingsOpen: Bool = false

    public func openSettingsWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Calendar Integration
    public var candidateCalendarEvents: [CalendarEventInfo] = []
    public var isLoadingCalendarEvents: Bool = false
    public var isCalendarAuthorized: Bool {
        coordinator.calendarService.authorizationStatus() == .authorized
    }

    public var calendarAutoMatch: Bool {
        get { config.autoMatchCalendarEvents }
        set {
            config.autoMatchCalendarEvents = newValue
            saveConfig()
        }
    }

    public func requestCalendarAccess() async -> Bool {
        return await coordinator.calendarService.requestAccess()
    }

    public func loadCalendarEvents(for file: AudioRecordingFile, date: Date? = nil) {
        isLoadingCalendarEvents = true
        let queryDate = date ?? file.creationDate
        Task { [weak self] in
            guard let self = self else { return }
            do {
                var events = try await self.coordinator.calendarService.fetchEvents(around: queryDate, duration: file.duration)
                if events.isEmpty && date == nil && !Calendar.current.isDateInToday(queryDate) {
                    let todayEvents = try await self.coordinator.calendarService.fetchEvents(around: Date(), duration: file.duration)
                    if !todayEvents.isEmpty {
                        events = todayEvents
                    }
                }
                await MainActor.run {
                    self.candidateCalendarEvents = events
                    self.isLoadingCalendarEvents = false
                }
            } catch {
                await MainActor.run {
                    self.isLoadingCalendarEvents = false
                }
            }
        }
    }

    public func associateCalendarEvent(file: AudioRecordingFile, event: CalendarEventInfo?) {
        do {
            let updated = try coordinator.associateCalendarEvent(for: file, event: event)
            if selectedRecordingID == file.id {
                selectedRecordingID = updated.id
            }
            if event != nil, updated.transcript != nil {
                resummarizeFile(updated, sessionConfig: sessionConfig(for: updated))
            }
        } catch {
            alertErrorMessage = error.localizedDescription
            showAlertError = true
        }
    }

    public func searchCalendarEvents(query: String, start: Date, end: Date) async -> [CalendarEventInfo] {
        return (try? await coordinator.calendarService.searchEvents(query: query, start: start, end: end)) ?? []
    }

    public func loadCalendarEventsForLiveMeeting(date: Date = Date()) {
        isLoadingCalendarEvents = true
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let events = try await self.coordinator.calendarService.fetchEvents(around: date, duration: 1800.0)
                await MainActor.run {
                    self.candidateCalendarEvents = events
                    self.isLoadingCalendarEvents = false
                }
            } catch {
                await MainActor.run {
                    self.isLoadingCalendarEvents = false
                }
            }
        }
    }

    public func openMeetingRecorder() {
        if mixerEngine.channels.isEmpty {
            if let defaultMic = AudioCaptureDeviceManager.availableMicrophones().first {
                mixerEngine.addChannel(for: defaultMic)
            }
            mixerEngine.addChannel(for: AudioCaptureDeviceManager.systemAudio())
        }
        showMeetingRecorder = true
    }

    public func updateNoteTitle(in file: AudioRecordingFile, newTitle: String) {
        do {
            let updated = try coordinator.updateNoteTitle(for: file, newTitle: newTitle)
            if selectedRecordingID == file.id {
                selectedRecordingID = updated.id
            }
        } catch {
            alertErrorMessage = error.localizedDescription
            showAlertError = true
        }
    }

    public var showDeleteAlert: Bool = false
    public var filePendingDelete: AudioRecordingFile?
    public var showEjectAlert: Bool = false
    public var alertErrorMessage: String?
    public var showAlertError: Bool = false
    public var showMeetingRecorder: Bool = false
    public var mixerEngine: AudioMixerEngine = AudioMixerEngine()
    public var speakerPropagationToast: String? = nil

    public func showSpeakerToast(_ message: String) {
        speakerPropagationToast = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self?.speakerPropagationToast == message {
                self?.speakerPropagationToast = nil
            }
        }
    }

    // Playback state mirrors
    public var isAudioPlaying: Bool = false
    public var audioCurrentTime: TimeInterval = 0
    public var audioDuration: TimeInterval = 0
    public var playbackRate: Float = 1.0

    public var isSDCardConnected: Bool {
        if case .inserted = sdCardStatus { return true }
        return false
    }

    public var menuBarIconName: String {
        if pipelineStatus.isRunning {
            return "waveform.badge.mic"
        }
        if isSDCardConnected {
            return "sdcard.fill"
        }
        return "waveform"
    }

    public var menuBarStatusText: String {
        if pipelineStatus.isRunning {
            return pipelineStatus.statusDescription
        }
        if case .inserted(let url, let free, _) = sdCardStatus {
            let freeFormatted = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            return "\(url.lastPathComponent) connected (\(freeFormatted) free)"
        }
        return "No SD card inserted"
    }

    public var recentRecordings: [AudioRecordingFile] {
        Array(recordings.prefix(5))
    }

    public init(
        coordinator: IngestionCoordinator? = nil,
        player: AudioPlayerController = AudioPlayerController(),
        configStorage: AppConfigStorage = .shared,
        autoStartMonitoring: Bool = true
    ) {
        self.configStorage = configStorage
        let loadedConfig = configStorage.load()
        self.config = loadedConfig

        let initialActiveSession = loadedConfig.sessionTypes.first(where: { $0.id == loadedConfig.selectedSessionTypeID })
            ?? loadedConfig.sessionTypes.first
            ?? SessionTypeConfig.defaultMeeting

        let coord: IngestionCoordinator
        if let provided = coordinator {
            coord = provided
            coord.activeSessionConfig = initialActiveSession
        } else {
            let monitor = SDCardMonitor(targetVolumeName: loadedConfig.targetVolumeName)
            let transcriber = WhisperKitEngine(modelName: loadedConfig.whisperModelName)
            let summarizer: any SummarizerEngine = loadedConfig.summarizerProvider == .openAICompatible
                ? OpenAICompatibleSummarizer(
                    endpoint: loadedConfig.openAIEndpoint,
                    modelName: loadedConfig.openAIModelName,
                    apiKey: loadedConfig.openAIApiKey
                )
                : AppleIntelligenceSummarizer()
            let exporter = MarkdownExporter(destinationDirectory: URL(fileURLWithPath: loadedConfig.exportDirectoryPath))
            let ledger = HistoryLedger()
            let notif = SystemNotificationService.shared

            coord = IngestionCoordinator(
                sdCardMonitor: monitor,
                audioScanner: AudioScanner(),
                transcriptionEngine: transcriber,
                summarizerEngine: summarizer,
                markdownExporter: exporter,
                historyLedger: ledger,
                notificationService: notif,
                audioLibraryDirectory: URL(fileURLWithPath: loadedConfig.audioLibraryDirectoryPath),
                watchFolderMonitor: WatchFolderMonitor(
                    watchDirectoryURL: loadedConfig.watchDirectoryPath.isEmpty ? nil : URL(fileURLWithPath: loadedConfig.watchDirectoryPath),
                    isEnabled: loadedConfig.watchDirectoryEnabled
                ),
                deleteFromSourceAfterCopy: loadedConfig.deleteFromSourceAfterCopy,
                sessionType: SessionType(rawValue: initialActiveSession.slug) ?? .custom,
                activeSessionConfig: initialActiveSession,
                summaryPromptTemplate: SummaryPromptTemplate(sessionType: .custom, systemInstructions: initialActiveSession.systemInstructions),
                autoProcessOnInsert: loadedConfig.autoProcessOnInsert,
                allowOverwrite: false
            )
        }

        self.coordinator = coord
        self.player = player

        setupBindings()

        if autoStartMonitoring {
            self.start()
        }
    }

    private func setupBindings() {
        coordinator.onDiscoveredFilesChanged = { [weak self] files in
            guard let self = self else { return }
            // Deduplicate files by displayName to protect UI against any duplicate entries
            var seen = Set<String>()
            var unique: [AudioRecordingFile] = []
            for file in files {
                if !seen.contains(file.displayName) {
                    seen.insert(file.displayName)
                    unique.append(file)
                }
            }
            self.recordings = unique
            if let currentID = self.selectedRecordingID, unique.contains(where: { $0.id == currentID }) {
                // Preserve current selection
            } else if let first = unique.first {
                self.selectedRecordingID = first.id
                self.loadAudioForSelectedFile()
            }
        }

        coordinator.onPipelineStatusChanged = { [weak self] status in
            guard let self = self else { return }
            self.pipelineStatus = status
            if case .completed = status {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if case .completed = self?.pipelineStatus {
                        self?.pipelineStatus = .idle
                    }
                }
            }
        }

        coordinator.onSDCardStatusChanged = { [weak self] status in
            self?.sdCardStatus = status
        }

        player.onPlaybackStateChanged = { [weak self] playing in
            self?.isAudioPlaying = playing
        }

        player.onProgressUpdated = { [weak self] current, duration in
            guard let self = self else { return }
            self.audioCurrentTime = current
            self.audioDuration = duration
        }
    }

    private var isStarted = false

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        coordinator.startMonitoring()
        sdCardStatus = coordinator.sdCardMonitor.currentStatus
        Task {
            await coordinator.scanLocalLibrary()
            if case .inserted(let volumeURL, _, _) = coordinator.sdCardMonitor.currentStatus {
                await coordinator.scanAudioFiles(volumeURL: volumeURL)
            }
        }
    }

    public func stop() {
        isStarted = false
        coordinator.stopMonitoring()
        player.stop()
    }

    public var selectedRecording: AudioRecordingFile? {
        if let id = selectedRecordingID, let file = recordings.first(where: { $0.id == id }) {
            return file
        }
        return recordings.first
    }

    public func selectFile(_ file: AudioRecordingFile) {
        let isDifferentFile = (selectedRecordingID != file.id)
        selectedRecordingID = file.id
        if let typeName = file.sessionType,
           let matched = config.sessionTypes.first(where: { $0.name.caseInsensitiveCompare(typeName) == .orderedSame || $0.slug.caseInsensitiveCompare(typeName) == .orderedSame }) {
            selectedSessionTypeID = matched.id
        }
        if isDifferentFile || player.currentURL != file.url {
            loadAudioForSelectedFile()
        }
    }

    public func loadAudioForSelectedFile() {
        guard let file = selectedRecording else {
            player.stop()
            return
        }
        if player.currentURL == file.url && player.duration > 0 {
            return
        }
        player.stop()
        do {
            try player.load(url: file.url)
            player.setPlaybackRate(playbackRate)
        } catch {
            // Audio loading error or unplayable file: ensure player is stopped and duration cleared
            player.stop()
        }
    }

    private var parsedTurnsCache: [UUID: (transcript: String, turns: [TranscriptTurn])] = [:]

    public func turns(for file: AudioRecordingFile) -> [TranscriptTurn] {
        let transcript = activeTranscript(for: file)
        if let cached = parsedTurnsCache[file.id], cached.transcript == transcript {
            return cached.turns
        }
        let parsed = TranscriptTurn.parseTurns(from: transcript)
        parsedTurnsCache[file.id] = (transcript, parsed)
        return parsed
    }

    public func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        player.setPlaybackRate(rate)
    }

    public func cyclePlaybackRate() {
        let rates: [Float] = [1.0, 1.25, 1.5, 2.0]
        if let idx = rates.firstIndex(where: { abs($0 - playbackRate) < 0.05 }) {
            let nextIdx = (idx + 1) % rates.count
            setPlaybackRate(rates[nextIdx])
        } else {
            setPlaybackRate(1.0)
        }
    }

    public func rescanCard() {
        coordinator.sdCardMonitor.checkCurrentVolumes()
        sdCardStatus = coordinator.sdCardMonitor.currentStatus
        if case .inserted(let volumeURL, _, _) = sdCardStatus {
            Task {
                await coordinator.scanAudioFiles(volumeURL: volumeURL)
            }
        }
    }

    public func selectSessionType(_ session: SessionTypeConfig) {
        selectedSessionTypeID = session.id
        if let current = selectedRecording {
            if let idx = recordings.firstIndex(where: { $0.id == current.id }) {
                recordings[idx].sessionType = session.name
                coordinator.updateDiscoveredFile(recordings[idx])
            }
        }
    }

    public func sessionConfig(for file: AudioRecordingFile) -> SessionTypeConfig {
        if let typeName = file.sessionType {
            if let matched = config.sessionTypes.first(where: {
                $0.name.caseInsensitiveCompare(typeName) == .orderedSame ||
                $0.slug.caseInsensitiveCompare(typeName) == .orderedSame
            }) {
                return matched
            }
        }
        return activeSessionType
    }

    public func setSessionType(for file: AudioRecordingFile, to sessionConfig: SessionTypeConfig) {
        if let idx = recordings.firstIndex(where: { $0.id == file.id }) {
            recordings[idx].sessionType = sessionConfig.name
            coordinator.updateDiscoveredFile(recordings[idx])
        }
        selectedSessionTypeID = sessionConfig.id
    }

    public func autoClassifyFile(_ file: AudioRecordingFile) {
        Task {
            do {
                let classified = try await coordinator.autoClassify(file: file)
                setSessionType(for: file, to: classified)
            } catch {
                alertErrorMessage = error.localizedDescription
                showAlertError = true
            }
        }
    }

    public func resummarizeFile(_ file: AudioRecordingFile, sessionConfig: SessionTypeConfig) {
        setSessionType(for: file, to: sessionConfig)
        processFile(file, sessionConfig: sessionConfig)
    }

    public var speakers: [SpeakerProfile] {
        coordinator.speakerDirectory.allSpeakers
    }

    public func addSpeaker(name: String, aliases: [String] = [], contextNotes: String = "") {
        let profile = SpeakerProfile(name: name, aliases: aliases, contextNotes: contextNotes)
        coordinator.speakerDirectory.addSpeaker(profile)
    }

    public func updateSpeaker(_ profile: SpeakerProfile) {
        coordinator.speakerDirectory.updateSpeaker(profile)
    }

    public func deleteSpeaker(id: UUID) {
        coordinator.speakerDirectory.deleteSpeaker(id: id)
    }

    public func diarizeFile(_ file: AudioRecordingFile) {
        guard let transcript = file.transcript, !transcript.isEmpty else { return }
        Task {
            do {
                let diarized = try await coordinator.summarizerEngine.diarizeTranscript(
                    transcript: transcript,
                    knownSpeakers: coordinator.speakerDirectory.allSpeakers
                )
                if let idx = recordings.firstIndex(where: { $0.id == file.id }) {
                    recordings[idx].transcript = diarized
                    coordinator.updateDiscoveredFile(recordings[idx])
                }
            } catch {
                alertErrorMessage = error.localizedDescription
                showAlertError = true
            }
        }
    }

    public func activeTranscript(for file: AudioRecordingFile) -> String {
        if let memory = file.transcript, !memory.isEmpty {
            return TranscriptTurn.stripSpecialTokens(memory)
        }
        if let idx = recordings.firstIndex(where: { $0.id == file.id }),
           let mem = recordings[idx].transcript, !mem.isEmpty {
            return TranscriptTurn.stripSpecialTokens(mem)
        }
        if let path = file.markdownPath, FileManager.default.fileExists(atPath: path.path),
           let content = try? String(contentsOf: path, encoding: .utf8) {
            let parsed = MarkdownExporter.parseMarkdownNote(content)
            if let t = parsed.transcript, !t.isEmpty {
                return TranscriptTurn.stripSpecialTokens(t)
            }
        }
        return ""
    }

    public func updateTranscript(for file: AudioRecordingFile, newTranscript: String) {
        if let idx = recordings.firstIndex(where: { $0.id == file.id }) {
            recordings[idx].transcript = newTranscript
            coordinator.updateDiscoveredFile(recordings[idx])
            coordinator.updateExportedTranscript(for: recordings[idx], newTranscript: newTranscript)
        }
    }

    public func saveTurns(for file: AudioRecordingFile, turns: [TranscriptTurn]) {
        let formatted = TranscriptTurn.formatTranscript(turns: turns)
        updateTranscript(for: file, newTranscript: formatted)
    }

    public func renameSpeaker(in file: AudioRecordingFile, from oldName: String, to newName: String, saveToDirectory: Bool = true) {
        let cleanNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanNew.isEmpty else { return }

        let currentTranscript = activeTranscript(for: file)
        let turns = TranscriptTurn.parseTurns(from: currentTranscript)
        let updatedTurns = TranscriptTurn.renameSpeaker(in: turns, from: oldName, to: cleanNew)
        saveTurns(for: file, turns: updatedTurns)

        if saveToDirectory && coordinator.speakerDirectory.getSpeaker(named: cleanNew) == nil {
            coordinator.speakerDirectory.addSpeaker(SpeakerProfile(name: cleanNew))
        }

        // Train speaker's acoustic profile in the background and propagate to any remaining generic turns
        let spkDir = coordinator.speakerDirectory
        let fileURL = file.url
        Task.detached(priority: .userInitiated) { [weak self] in
            let (propagatedTurns, matchedCount) = await AudioFingerprintEngine.trainAndPropagateSpeaker(
                audioURL: fileURL,
                speakerName: cleanNew,
                turns: updatedTurns,
                directory: spkDir
            )
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                if matchedCount > 0 {
                    self.saveTurns(for: file, turns: propagatedTurns)
                    self.showSpeakerToast("Trained \(cleanNew)'s voiceprint & auto-matched \(matchedCount) additional turn\(matchedCount == 1 ? "" : "s")!")
                } else {
                    self.showSpeakerToast("Learned & refined voiceprint for \(cleanNew).")
                }
            }
        }
    }

    public func updateTurnSpeaker(in file: AudioRecordingFile, turnIndex: Int, newSpeaker: String) {
        let cleanNew = newSpeaker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanNew.isEmpty else { return }

        let currentTranscript = activeTranscript(for: file)
        var turns = TranscriptTurn.parseTurns(from: currentTranscript)
        guard turnIndex >= 0 && turnIndex < turns.count else { return }
        turns[turnIndex].speaker = cleanNew
        saveTurns(for: file, turns: turns)

        if coordinator.speakerDirectory.getSpeaker(named: cleanNew) == nil {
            coordinator.speakerDirectory.addSpeaker(SpeakerProfile(name: cleanNew))
        }

        // Train speaker's acoustic profile from the assigned turn and propagate across generic turns
        let spkDir = coordinator.speakerDirectory
        let fileURL = file.url
        Task.detached(priority: .userInitiated) { [weak self] in
            let (propagatedTurns, matchedCount) = await AudioFingerprintEngine.trainAndPropagateSpeaker(
                audioURL: fileURL,
                speakerName: cleanNew,
                turns: turns,
                directory: spkDir
            )
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                if matchedCount > 0 {
                    self.saveTurns(for: file, turns: propagatedTurns)
                    self.showSpeakerToast("Trained \(cleanNew)'s voiceprint & auto-matched \(matchedCount) additional turn\(matchedCount == 1 ? "" : "s")!")
                } else {
                    self.showSpeakerToast("Learned & refined voiceprint for \(cleanNew).")
                }
            }
        }
    }

    public func updateTurnText(in file: AudioRecordingFile, turnIndex: Int, newText: String) {
        let currentTranscript = activeTranscript(for: file)
        var turns = TranscriptTurn.parseTurns(from: currentTranscript)
        guard turnIndex >= 0 && turnIndex < turns.count else { return }
        turns[turnIndex].text = newText
        saveTurns(for: file, turns: turns)
    }

    public func mergeTurnWithPrevious(in file: AudioRecordingFile, turnIndex: Int) {
        let currentTranscript = activeTranscript(for: file)
        let turns = TranscriptTurn.parseTurns(from: currentTranscript)
        let merged = TranscriptTurn.mergeTurnWithPrevious(in: turns, turnIndex: turnIndex)
        saveTurns(for: file, turns: merged)
    }

    public func splitTurn(
        in file: AudioRecordingFile,
        turnIndex: Int,
        splitCharacterOffset: Int,
        newSpeaker: String? = nil
    ) {
        let currentTranscript = activeTranscript(for: file)
        let turns = TranscriptTurn.parseTurns(from: currentTranscript)
        let updated = TranscriptTurn.splitTurn(
            in: turns,
            turnIndex: turnIndex,
            splitCharacterOffset: splitCharacterOffset,
            newSpeaker: newSpeaker
        )
        saveTurns(for: file, turns: updated)

        if let spk = newSpeaker, !spk.isEmpty {
            AudioFingerprintEngine.fingerprintSpeakerInBackground(
                audioURL: file.url,
                speakerName: spk,
                turns: updated,
                directory: coordinator.speakerDirectory
            )
        }
    }

    public func splitTurn(
        in file: AudioRecordingFile,
        turnIndex: Int,
        part1Text: String,
        part2Text: String,
        newSpeaker: String? = nil,
        splitTimestamp: String? = nil
    ) {
        let currentTranscript = activeTranscript(for: file)
        let turns = TranscriptTurn.parseTurns(from: currentTranscript)
        let updated = TranscriptTurn.splitTurn(
            in: turns,
            turnIndex: turnIndex,
            part1Text: part1Text,
            part2Text: part2Text,
            newSpeaker: newSpeaker,
            splitTimestamp: splitTimestamp
        )
        saveTurns(for: file, turns: updated)

        let targetSpeaker = newSpeaker ?? (turnIndex + 1 < updated.count ? updated[turnIndex + 1].speaker : nil)
        if let spk = targetSpeaker, !spk.isEmpty {
            AudioFingerprintEngine.fingerprintSpeakerInBackground(
                audioURL: file.url,
                speakerName: spk,
                turns: updated,
                directory: coordinator.speakerDirectory
            )
        }
    }

    public func addSessionType(name: String, slug: String, systemInstructions: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let newSession = SessionTypeConfig(
            name: cleanName.isEmpty ? "New Session" : cleanName,
            slug: cleanSlug.isEmpty ? "session" : cleanSlug,
            systemInstructions: systemInstructions
        )
        config.sessionTypes.append(newSession)
        selectedSessionTypeID = newSession.id
        saveConfig()
    }

    public func updateSessionType(_ session: SessionTypeConfig) {
        if let idx = config.sessionTypes.firstIndex(where: { $0.id == session.id }) {
            config.sessionTypes[idx] = session
            if config.selectedSessionTypeID == session.id {
                coordinator.activeSessionConfig = session
            }
            saveConfig()
        }
    }

    public func deleteSessionType(id: UUID) {
        guard config.sessionTypes.count > 1 else { return }
        config.sessionTypes.removeAll { $0.id == id }
        if config.selectedSessionTypeID == id {
            if let first = config.sessionTypes.first {
                selectedSessionTypeID = first.id
            }
        }
        saveConfig()
    }

    public func resetSessionTypesToDefaults() {
        config.sessionTypes = SessionTypeConfig.defaultList
        selectedSessionTypeID = SessionTypeConfig.defaultMeeting.id
        coordinator.activeSessionConfig = SessionTypeConfig.defaultMeeting
        saveConfig()
    }

    public func saveConfig() {
        updateActiveTemplate()
        do {
            try configStorage.save(config)
        } catch {
            print("Failed to save config: \(error)")
        }
    }

    private var activeProcessingTask: Task<Void, Never>?

    public func processFile(_ file: AudioRecordingFile, sessionConfig: SessionTypeConfig? = nil) {
        let coordinator = self.coordinator
        let configToUse = sessionConfig ?? self.sessionConfig(for: file)
        activeProcessingTask?.cancel()
        activeProcessingTask = Task {
            do {
                _ = try await coordinator.processRecording(file, sessionConfig: configToUse)
            } catch {
                if !Task.isCancelled {
                    await MainActor.run { [weak self] in
                        self?.alertErrorMessage = error.localizedDescription
                        self?.showAlertError = true
                    }
                }
            }
        }
    }

    public func retranscribeFile(_ file: AudioRecordingFile) {
        let coordinator = self.coordinator
        let configToUse = self.sessionConfig(for: file)
        activeProcessingTask?.cancel()
        activeProcessingTask = Task {
            do {
                _ = try await coordinator.processRecording(file, sessionConfig: configToUse, forceRetranscribe: true)
            } catch {
                if !Task.isCancelled {
                    await MainActor.run { [weak self] in
                        self?.alertErrorMessage = error.localizedDescription
                        self?.showAlertError = true
                    }
                }
            }
        }
    }

    /// Run instant acoustic speaker identification without re-running WhisperKit
    public func autoIdentifySpeakers(in file: AudioRecordingFile) {
        let currentTranscript = activeTranscript(for: file)
        let fileURL = file.url
        let spkDir = coordinator.speakerDirectory
        let configToUse = sessionConfig(for: file)

        Task.detached(priority: .userInitiated) { [weak self] in
            let turns = TranscriptTurn.parseTurns(from: currentTranscript)
            let identifiedTurns = await AudioFingerprintEngine.identifySpeakers(
                in: fileURL,
                turns: turns,
                directory: spkDir,
                forceReidentify: true
            )
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.saveTurns(for: file, turns: identifiedTurns)
                self.resummarizeFile(file, sessionConfig: configToUse)
            }
        }
    }

    public func processAllUnprocessed() {
        activeProcessingTask?.cancel()
        activeProcessingTask = Task {
            _ = await coordinator.processAllUnprocessed()
        }
    }

    public func cancelProcessing() {
        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        coordinator.cancelProcessing()
    }

    public func promptDeleteFile(_ file: AudioRecordingFile) {
        filePendingDelete = file
        showDeleteAlert = true
    }

    public func confirmDeleteFile() {
        guard let file = filePendingDelete else { return }
        do {
            if player.currentURL == file.url {
                player.stop()
            }
            try coordinator.deleteRecording(file)
            recordings.removeAll { $0.id == file.id }
            if selectedRecordingID == file.id {
                selectedRecordingID = recordings.first?.id
                loadAudioForSelectedFile()
            }
            filePendingDelete = nil
        } catch {
            alertErrorMessage = error.localizedDescription
            showAlertError = true
        }
    }

    public func promptEjectCard() {
        showEjectAlert = true
    }

    public func confirmEjectCard() {
        Task {
            do {
                if let currentURL = player.currentURL, currentURL.path.hasPrefix("/Volumes/") {
                    player.stop()
                }
                try await coordinator.ejectCard()
                sdCardStatus = coordinator.sdCardMonitor.currentStatus
                await coordinator.scanLocalLibrary()
                if let selectedID = selectedRecordingID, !recordings.contains(where: { $0.id == selectedID }) {
                    selectedRecordingID = recordings.first?.id
                    loadAudioForSelectedFile()
                }
            } catch {
                alertErrorMessage = error.localizedDescription
                showAlertError = true
            }
        }
    }

    public func updateActiveTemplate() {
        coordinator.activeSessionConfig = activeSessionType
        coordinator.summaryPromptTemplate = SummaryPromptTemplate(
            sessionType: .custom,
            systemInstructions: activeSessionType.systemInstructions
        )
    }

    public func resetInstructionsToDefaults() {
        resetSessionTypesToDefaults()
    }
}
