import Foundation

public enum PipelineStatus: Equatable, Sendable {
    case idle
    case scanning
    case transcribing(fileName: String, progress: Double)
    case summarizing(fileName: String)
    case exporting(fileName: String)
    case completed(fileName: String, exportURL: URL)
    case error(fileName: String?, message: String)

    public var isRunning: Bool {
        switch self {
        case .scanning, .transcribing, .summarizing, .exporting:
            return true
        case .idle, .completed, .error:
            return false
        }
    }

    public var statusDescription: String {
        switch self {
        case .idle:
            return "Idle"
        case .scanning:
            return "Scanning SD card for audio recordings..."
        case .transcribing(let name, let progress):
            let percent = Int(progress * 100)
            return "Transcribing \(name) (\(percent)%)..."
        case .summarizing(let name):
            return "Generating summary with Apple Intelligence for \(name)..."
        case .exporting(let name):
            return "Exporting Markdown note for \(name)..."
        case .completed(let name, _):
            return "Completed processing \(name)"
        case .error(let name, let msg):
            if let name = name {
                return "Error processing \(name): \(msg)"
            }
            return "Error: \(msg)"
        }
    }
}

@MainActor
public final class IngestionCoordinator {
    public let sdCardMonitor: SDCardMonitor
    public let audioScanner: AudioScanner
    public let transcriptionEngine: any TranscriptionEngine
    public private(set) var summarizerEngine: any SummarizerEngine
    public let markdownExporter: MarkdownExporter
    public let historyLedger: HistoryLedger
    public let notificationService: any NotificationService
    public let speakerDirectory: SpeakerDirectory
    public let noteCacheStore: NoteCacheStore
    public let calendarService: any CalendarService
    public var audioLibraryDirectory: URL
    public let watchFolderMonitor: WatchFolderMonitor
    public var deleteFromSourceAfterCopy: Bool
    public let audioFileCopyService: AudioFileCopyService

    public var activeSessionConfig: SessionTypeConfig
    public var availableSessionConfigs: [SessionTypeConfig]
    public var sessionType: SessionType
    public var summaryPromptTemplate: SummaryPromptTemplate
    public var autoProcessOnInsert: Bool
    public var allowOverwrite: Bool

    private(set) public var discoveredFiles: [AudioRecordingFile] = []
    private(set) public var pipelineStatus: PipelineStatus = .idle
    private var isBatchProcessing = false
    private var activeProcessingDisplayNames: Set<String> = []

    public var onDiscoveredFilesChanged: ((@MainActor ([AudioRecordingFile]) -> Void))?
    public var onPipelineStatusChanged: ((@MainActor (PipelineStatus) -> Void))?
    public var onSDCardStatusChanged: ((@MainActor (SDCardStatus) -> Void))?

    public init(
        sdCardMonitor: SDCardMonitor,
        audioScanner: AudioScanner = AudioScanner(),
        transcriptionEngine: any TranscriptionEngine,
        summarizerEngine: any SummarizerEngine,
        markdownExporter: MarkdownExporter = MarkdownExporter(),
        historyLedger: HistoryLedger = HistoryLedger(),
        notificationService: any NotificationService = SystemNotificationService.shared,
        speakerDirectory: SpeakerDirectory = .shared,
        noteCacheStore: NoteCacheStore = NoteCacheStore(),
        calendarService: any CalendarService = SystemCalendarService.shared,
        audioLibraryDirectory: URL = URL(fileURLWithPath: AppConfig.defaultAudioLibraryDirectory),
        watchFolderMonitor: WatchFolderMonitor = WatchFolderMonitor(),
        deleteFromSourceAfterCopy: Bool = false,
        audioFileCopyService: AudioFileCopyService = AudioFileCopyService(),
        sessionType: SessionType = .meeting,
        activeSessionConfig: SessionTypeConfig = SessionTypeConfig.defaultMeeting,
        availableSessionConfigs: [SessionTypeConfig] = SessionTypeConfig.defaultList,
        summaryPromptTemplate: SummaryPromptTemplate = .defaultMeeting,
        autoProcessOnInsert: Bool = true,
        allowOverwrite: Bool = false
    ) {
        self.sdCardMonitor = sdCardMonitor
        self.audioScanner = audioScanner
        self.transcriptionEngine = transcriptionEngine
        self.summarizerEngine = summarizerEngine
        self.markdownExporter = markdownExporter
        self.historyLedger = historyLedger
        self.notificationService = notificationService
        self.speakerDirectory = speakerDirectory
        self.noteCacheStore = noteCacheStore
        self.calendarService = calendarService
        self.audioLibraryDirectory = audioLibraryDirectory
        self.watchFolderMonitor = watchFolderMonitor
        self.deleteFromSourceAfterCopy = deleteFromSourceAfterCopy
        self.audioFileCopyService = audioFileCopyService
        self.sessionType = sessionType
        self.activeSessionConfig = activeSessionConfig
        self.availableSessionConfigs = availableSessionConfigs
        self.summaryPromptTemplate = summaryPromptTemplate
        self.autoProcessOnInsert = autoProcessOnInsert
        self.allowOverwrite = allowOverwrite
    }

    public func startMonitoring() {
        sdCardMonitor.onStatusChanged = { [weak self] status in
            Task { @MainActor [weak self] in
                await self?.handleSDCardStatusChanged(status)
            }
        }
        sdCardMonitor.startMonitoring()

        watchFolderMonitor.onFilesDiscovered = { [weak self] urls in
            Task { @MainActor [weak self] in
                await self?.handleWatchDirectoryFiles(urls)
            }
        }
        watchFolderMonitor.startMonitoring()
    }

    public func stopMonitoring() {
        sdCardMonitor.stopMonitoring()
        watchFolderMonitor.stopMonitoring()
    }

    public func handleSDCardStatusChanged(_ status: SDCardStatus) async {
        onSDCardStatusChanged?(status)
        switch status {
        case .inserted(let volumeURL, _, _):
            _ = await scanAudioFiles(volumeURL: volumeURL)
            if autoProcessOnInsert {
                _ = await processAllUnprocessed()
            }
        case .notInserted:
            setPipelineStatus(.idle)
        }
    }

    @discardableResult
    public func scanLocalLibrary() async -> [AudioRecordingFile] {
        if !FileManager.default.fileExists(atPath: audioLibraryDirectory.path) {
            try? FileManager.default.createDirectory(at: audioLibraryDirectory, withIntermediateDirectories: true)
        }
        let rawFiles = await audioScanner.scanDirectoryAsync(at: audioLibraryDirectory)
        let enriched = enrichDiscoveredFiles(rawFiles)
        mergeDiscoveredFiles(enriched)
        return enriched
    }

    @discardableResult
    public func scanAudioFiles(volumeURL: URL) async -> [AudioRecordingFile] {
        setPipelineStatus(.scanning)
        let rawFiles = await audioScanner.scanDirectoryAsync(at: volumeURL)
        let enriched = enrichDiscoveredFiles(rawFiles)
        mergeDiscoveredFiles(enriched)
        setPipelineStatus(.idle)
        return enriched
    }

    public func enrichDiscoveredFiles(_ rawFiles: [AudioRecordingFile]) -> [AudioRecordingFile] {
        var files = rawFiles
        for i in 0..<files.count {
            let relativePath = files[i].displayName
            let cached = noteCacheStore.load(audioRelativePath: relativePath)

            if let record = historyLedger.getRecord(for: files[i]) {
                files[i].status = .completed
                if let path = record.exportPath {
                    let exportURL = URL(fileURLWithPath: path)
                    files[i].markdownPath = exportURL
                    if FileManager.default.fileExists(atPath: path),
                       let content = try? String(contentsOf: exportURL, encoding: .utf8) {
                        let parsed = MarkdownExporter.parseMarkdownNote(content)
                        files[i].markdownSummary = parsed.summary
                        files[i].transcript = parsed.transcript
                        files[i].noteTitle = parsed.title
                    }
                }

                // Restore cached metadata (including calendarEvent and title)
                if let cached = cached {
                    files[i].calendarEvent = cached.calendarEvent
                    if files[i].noteTitle == nil || cached.calendarEvent != nil {
                        files[i].noteTitle = cached.calendarEvent?.title ?? cached.title
                    }
                    if files[i].markdownSummary == nil {
                        files[i].markdownSummary = cached.markdownSummary
                    }
                    if files[i].transcript == nil {
                        files[i].transcript = cached.transcript
                    }
                    if files[i].sessionType == nil {
                        files[i].sessionType = cached.sessionType
                    }
                    files[i].classificationConfidence = cached.classificationConfidence
                    files[i].calendarMatchConfidence = cached.calendarMatchConfidence
                }
                if files[i].sessionType == nil {
                    files[i].sessionType = record.sessionType
                }
            } else if let cached = cached {
                // Recovered from local note cache
                files[i].status = .completed
                files[i].markdownSummary = cached.markdownSummary
                files[i].transcript = cached.transcript
                files[i].noteTitle = cached.calendarEvent?.title ?? cached.title
                files[i].calendarEvent = cached.calendarEvent
                files[i].sessionType = cached.sessionType
                files[i].markdownPath = cached.inboxExportURL
                files[i].classificationConfidence = cached.classificationConfidence
                files[i].calendarMatchConfidence = cached.calendarMatchConfidence
            }
        }
        return files
    }

    public func mergeDiscoveredFiles(_ newFiles: [AudioRecordingFile]) {
        for file in newFiles {
            if let idx = discoveredFiles.firstIndex(where: { $0.displayName == file.displayName || $0.url.path == file.url.path }) {
                if discoveredFiles[idx].status == .completed || discoveredFiles[idx].status == .transcribing || discoveredFiles[idx].status == .summarizing {
                    if discoveredFiles[idx].noteTitle == nil {
                        discoveredFiles[idx].noteTitle = file.noteTitle
                    }
                    if discoveredFiles[idx].calendarEvent == nil {
                        discoveredFiles[idx].calendarEvent = file.calendarEvent
                    }
                } else {
                    discoveredFiles[idx] = file
                }
            } else {
                discoveredFiles.append(file)
            }
        }
        discoveredFiles.sort(by: { $0.creationDate > $1.creationDate })
        onDiscoveredFilesChanged?(discoveredFiles)
    }

    public func handleWatchDirectoryFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        var newFiles: [AudioRecordingFile] = []
        for url in urls {
            if discoveredFiles.contains(where: { $0.url.path == url.path }) {
                continue
            }
            let size = AudioFileCopyService.fileSize(at: url)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let creationDate = (attrs?[.creationDate] as? Date) ?? Date()
            let rec = AudioRecordingFile(url: url, fileSize: size, creationDate: creationDate)
            newFiles.append(rec)
        }

        guard !newFiles.isEmpty else { return }
        let enriched = enrichDiscoveredFiles(newFiles)
        mergeDiscoveredFiles(enriched)

        if autoProcessOnInsert {
            for file in enriched {
                _ = try? await processRecording(file)
            }
        }
    }

    @discardableResult
    public func processRecording(
        _ file: AudioRecordingFile,
        sessionConfig: SessionTypeConfig? = nil,
        forceRetranscribe: Bool = false
    ) async throws -> URL {
        let fileDisplayName = file.displayName
        guard !activeProcessingDisplayNames.contains(fileDisplayName) else {
            if let existing = file.markdownPath, FileManager.default.fileExists(atPath: existing.path) {
                return existing
            }
            throw NSError(domain: "IngestionCoordinator", code: 409, userInfo: [NSLocalizedDescriptionKey: "\(fileDisplayName) is already being processed."])
        }

        activeProcessingDisplayNames.insert(fileDisplayName)
        defer {
            activeProcessingDisplayNames.remove(fileDisplayName)
        }

        var activeFile = file
        activeFile.errorMessage = nil

        // If file.url does not exist on disk, check if it was already copied to audioLibraryDirectory or in discoveredFiles
        if !FileManager.default.fileExists(atPath: activeFile.url.path),
           let existing = discoveredFiles.first(where: { $0.id == file.id || $0.displayName == file.displayName }),
           FileManager.default.fileExists(atPath: existing.url.path) {
            activeFile.url = existing.url
        }

        guard FileManager.default.fileExists(atPath: activeFile.url.path) else {
            let errorMsg = "Audio file does not exist at \(activeFile.url.path)"
            setPipelineStatus(.error(fileName: activeFile.displayName, message: errorMsg))
            throw NSError(domain: "IngestionCoordinator", code: 404, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        let fileID = activeFile.id

        // Copy audio to local machine and delete from source once verified
        if !activeFile.url.path.hasPrefix(audioLibraryDirectory.path) {
            do {
                let copyService = self.audioFileCopyService
                let sourceURL = activeFile.url
                let destDir = self.audioLibraryDirectory
                let deleteSource = self.deleteFromSourceAfterCopy
                let relPath = activeFile.displayName

                let localURL = try await Task.detached(priority: .userInitiated) {
                    try copyService.copyAndVerify(
                        sourceURL: sourceURL,
                        destinationDirectory: destDir,
                        deleteSourceAfterVerification: deleteSource,
                        relativePath: relPath
                    )
                }.value

                activeFile.url = localURL
                updateDiscoveredFile(activeFile)
            } catch {
                let errorMsg = "Failed to copy audio to local storage: \(error.localizedDescription)"
                activeFile.status = .failed
                activeFile.errorMessage = errorMsg
                updateDiscoveredFile(activeFile)
                setPipelineStatus(.error(fileName: fileDisplayName, message: errorMsg))
                throw error
            }
        }

        let audioURL = activeFile.url

        do {
            // 1. Transcription (reuse existing transcript unless forceRetranscribe is true)
            let transcript: String
            if !forceRetranscribe, let existing = activeFile.transcript, !existing.isEmpty {
                transcript = existing
                activeFile.status = .transcribed
                activeFile.transcriptionProgress = 1.0
                updateDiscoveredFile(activeFile)
            } else {
                activeFile.transcript = nil
                activeFile.markdownSummary = nil
                activeFile.status = .transcribing
                activeFile.transcriptionProgress = 0.05
                updateDiscoveredFile(activeFile)
                setPipelineStatus(.transcribing(fileName: fileDisplayName, progress: 0.05))

                let transcribed = try await transcriptionEngine.transcribe(audioFileURL: audioURL) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.updateFileProgress(id: fileID, progress: progress, displayName: fileDisplayName)
                    }
                }
                transcript = transcribed
                activeFile.transcript = transcript
                activeFile.status = .transcribed
                activeFile.transcriptionProgress = 1.0
                updateDiscoveredFile(activeFile)
            }

            // 2. Speaker Diarization, Acoustic Fingerprinting & Tracking
            var turns = TranscriptTurn.parseTurns(from: transcript)
            if turns.isEmpty {
                turns = TranscriptTurn.splitWallOfText(transcript)
            }

            // Automatically recognize speakers using stored acoustic voiceprints
            let spkDir = self.speakerDirectory
            let currentTurns = turns
            turns = await Task.detached(priority: .userInitiated) {
                await AudioFingerprintEngine.identifySpeakers(
                    in: audioURL,
                    turns: currentTurns,
                    directory: spkDir
                )
            }.value

            let finalTranscript = TranscriptTurn.formatTranscript(turns: turns)
            activeFile.transcript = finalTranscript
            updateDiscoveredFile(activeFile)

            // 3. LLM Autonomous Calendar Event Matching (> 80% confidence)
            if activeFile.calendarEvent == nil {
                var candidateEvents = (try? await calendarService.fetchEvents(around: activeFile.creationDate, duration: activeFile.duration)) ?? []
                if candidateEvents.isEmpty && !Calendar.current.isDateInToday(activeFile.creationDate) {
                    let todayEvents = (try? await calendarService.fetchEvents(around: Date(), duration: activeFile.duration)) ?? []
                    candidateEvents.append(contentsOf: todayEvents)
                }

                if !candidateEvents.isEmpty {
                    if let matchResult = try? await summarizerEngine.matchCalendarEvent(
                        transcript: finalTranscript,
                        candidateEvents: candidateEvents,
                        fileDate: activeFile.creationDate
                    ), matchResult.confidence > 0.80, let matched = matchResult.matchedEvent {
                        activeFile.calendarEvent = matched
                        activeFile.noteTitle = matched.title
                        activeFile.calendarMatchConfidence = matchResult.confidence
                        updateDiscoveredFile(activeFile)
                    }
                }
            }

            // 4. LLM Autonomous Session Type Classification (> 80% confidence)
            let resolvedConfig: SessionTypeConfig
            if let explicit = sessionConfig {
                resolvedConfig = explicit
            } else {
                setPipelineStatus(.summarizing(fileName: fileDisplayName))
                if let classResult = try? await summarizerEngine.classifySessionTypeWithConfidence(
                    transcript: finalTranscript,
                    availableTypes: availableSessionConfigs
                ) {
                    activeFile.classificationConfidence = classResult.confidence
                    if classResult.confidence > 0.80 {
                        resolvedConfig = classResult.config
                    } else if let assigned = activeFile.sessionType,
                              let matched = availableSessionConfigs.first(where: {
                                  $0.name.caseInsensitiveCompare(assigned) == .orderedSame ||
                                  $0.slug.caseInsensitiveCompare(assigned) == .orderedSame
                              }) {
                        resolvedConfig = matched
                    } else {
                        resolvedConfig = activeSessionConfig
                    }
                } else if let assigned = activeFile.sessionType,
                          let matched = availableSessionConfigs.first(where: {
                              $0.name.caseInsensitiveCompare(assigned) == .orderedSame ||
                              $0.slug.caseInsensitiveCompare(assigned) == .orderedSame
                          }) {
                    resolvedConfig = matched
                } else {
                    resolvedConfig = activeSessionConfig
                }
            }

            activeFile.sessionType = resolvedConfig.name
            updateDiscoveredFile(activeFile)

            // 5. Summarization
            activeFile.status = .summarizing
            updateDiscoveredFile(activeFile)
            setPipelineStatus(.summarizing(fileName: fileDisplayName))

            var systemInstructions = resolvedConfig.systemInstructions
            if let event = activeFile.calendarEvent {
                var calendarContext = """
                \n\n### Calendar Meeting Information & Context
                - Meeting Title: \(event.title)
                - Scheduled Time: \(event.formattedTimeRange)
                - Calendar: \(event.calendarTitle)
                """
                if let (locText, _) = event.cleanLocation {
                    calendarContext += "\n- Location: \(locText)"
                }
                if !event.attendees.isEmpty {
                    let attendeeList = event.attendees.prefix(8).joined(separator: ", ")
                    calendarContext += "\n- Key Invitees: \(attendeeList)"
                }
                if let agenda = event.cleanNotes {
                    calendarContext += "\n- Stated Agenda & Goals:\n\(agenda)"
                }
                calendarContext += """
                \n\nInstructions for meeting integration:
                - Synthesize the summary using the meeting context above.
                - Cross-reference whether scheduled agenda items were discussed or resolved.
                - DO NOT reproduce raw email headers, join links, or recipient lists in your summary. Only include actionable and meaningful points.
                """
                systemInstructions += calendarContext
            }

            let promptTemplate = SummaryPromptTemplate(sessionType: .custom, systemInstructions: systemInstructions)
            let summary = try await summarizerEngine.summarize(transcript: finalTranscript, template: promptTemplate)
            activeFile.markdownSummary = summary

            // Determine content-based title (calendar event title takes priority if linked)
            let determinedTitle: String
            if let calTitle = activeFile.calendarEvent?.title {
                determinedTitle = calTitle
            } else if let gen = try? await summarizerEngine.generateTitle(transcript: finalTranscript, summary: summary) {
                determinedTitle = gen
            } else {
                determinedTitle = "\(resolvedConfig.name) - \(activeFile.formattedDate)"
            }
            activeFile.noteTitle = determinedTitle
            updateDiscoveredFile(activeFile)

            // 5. Markdown Export
            setPipelineStatus(.exporting(fileName: fileDisplayName))
            var targetExportURL: URL
            do {
                targetExportURL = try markdownExporter.exportMarkdown(
                    for: activeFile,
                    typeSlug: resolvedConfig.slug,
                    typeTitle: resolvedConfig.name,
                    allowOverwrite: allowOverwrite
                )
            } catch MarkdownExportError.fileExists {
                // If overwrite not allowed, fallback to non-colliding URL
                let nonCollidingURL = markdownExporter.generateNonCollidingURL(for: activeFile, typeSlug: resolvedConfig.slug)
                let customName = nonCollidingURL.lastPathComponent
                targetExportURL = try markdownExporter.exportMarkdown(
                    for: activeFile,
                    typeSlug: resolvedConfig.slug,
                    typeTitle: resolvedConfig.name,
                    allowOverwrite: true,
                    customFilename: customName
                )
            }

            activeFile.markdownPath = targetExportURL
            activeFile.status = .completed
            updateDiscoveredFile(activeFile)

            // Cache durable note
            let cachedNote = CachedRecordingNote(
                id: activeFile.id,
                audioRelativePath: activeFile.displayName,
                creationDate: activeFile.creationDate,
                duration: activeFile.duration,
                title: activeFile.noteTitle ?? resolvedConfig.name,
                sessionType: resolvedConfig.slug,
                calendarEvent: activeFile.calendarEvent,
                transcript: activeFile.transcript ?? "",
                markdownSummary: activeFile.markdownSummary ?? "",
                inboxExportURL: targetExportURL,
                lastExportedAt: Date(),
                classificationConfidence: activeFile.classificationConfidence,
                calendarMatchConfidence: activeFile.calendarMatchConfidence
            )
            try? noteCacheStore.save(cachedNote)

            // 4. Update History Ledger
            try historyLedger.markProcessed(file: activeFile, exportURL: targetExportURL)

            // 5. User Notification
            let noteName = targetExportURL.lastPathComponent
            await notificationService.postNotification(
                title: "Audio Ingestion Complete",
                subtitle: fileDisplayName,
                body: "[\(resolvedConfig.name)] Saved summary note: \(noteName)"
            )

            setPipelineStatus(.completed(fileName: fileDisplayName, exportURL: targetExportURL))
            return targetExportURL
        } catch {
            activeFile.status = .failed
            activeFile.errorMessage = error.localizedDescription
            updateDiscoveredFile(activeFile)
            setPipelineStatus(.error(fileName: fileDisplayName, message: error.localizedDescription))
            throw error
        }
    }

    @discardableResult
    public func processAllUnprocessed() async -> [URL] {
        guard !isBatchProcessing else { return [] }
        isBatchProcessing = true
        defer {
            isBatchProcessing = false
            setPipelineStatus(.idle)
        }

        let filesToProcess = discoveredFiles.filter { !historyLedger.isProcessed(file: $0) }

        var results: [URL] = []
        for file in filesToProcess {
            if Task.isCancelled { break }
            do {
                let url = try await processRecording(file)
                results.append(url)
            } catch {
                if Task.isCancelled { break }
                // Continue to next file if one fails
            }
        }

        return results
    }

    public func cancelProcessing() {
        isBatchProcessing = false
        activeProcessingDisplayNames.removeAll()
        for idx in discoveredFiles.indices {
            if discoveredFiles[idx].status == .transcribing || discoveredFiles[idx].status == .summarizing {
                discoveredFiles[idx].status = .discovered
                discoveredFiles[idx].transcriptionProgress = 0.0
            }
        }
        onDiscoveredFilesChanged?(discoveredFiles)
        setPipelineStatus(.idle)
    }

    public func deleteRecording(_ file: AudioRecordingFile) throws {
        // 1. Delete local cached audio copy if it exists on disk
        if FileManager.default.fileExists(atPath: file.url.path) {
            try? FileManager.default.removeItem(at: file.url)
            let parentDir = file.url.deletingLastPathComponent()
            if parentDir.path.hasPrefix(audioLibraryDirectory.path) && parentDir.path != audioLibraryDirectory.path {
                if let contents = try? FileManager.default.contentsOfDirectory(atPath: parentDir.path), contents.isEmpty {
                    try? FileManager.default.removeItem(at: parentDir)
                }
            }
        } else if case .inserted(let volumeURL, _, _) = sdCardMonitor.currentStatus, file.url.path.hasPrefix(volumeURL.path) {
            // Or if still on SD card, delete from SD card
            try? sdCardMonitor.deleteAudioFile(file)
        }

        // 2. Remove cached note from note cache store
        noteCacheStore.delete(audioRelativePath: file.displayName)
        noteCacheStore.delete(audioRelativePath: file.filename)

        // 3. Remove history ledger record
        try? historyLedger.removeRecord(for: file)

        // 4. Update discovered files
        discoveredFiles.removeAll { $0.displayName == file.displayName || $0.id == file.id }
        onDiscoveredFilesChanged?(discoveredFiles)
    }

    public func ejectCard() async throws {
        try await sdCardMonitor.ejectCard()
        discoveredFiles = []
        onDiscoveredFilesChanged?([])
        setPipelineStatus(.idle)
    }

    public func updateActiveSessionConfig(_ config: SessionTypeConfig) {
        self.activeSessionConfig = config
        self.summaryPromptTemplate = SummaryPromptTemplate(sessionType: .custom, systemInstructions: config.systemInstructions)
    }

    public func updateAvailableSessionConfigs(_ configs: [SessionTypeConfig]) {
        self.availableSessionConfigs = configs
    }

    @discardableResult
    public func retranscribe(file: AudioRecordingFile, sessionConfig: SessionTypeConfig? = nil) async throws -> URL {
        return try await processRecording(file, sessionConfig: sessionConfig, forceRetranscribe: true)
    }

    @discardableResult
    public func resummarize(file: AudioRecordingFile, sessionConfig: SessionTypeConfig) async throws -> URL {
        return try await processRecording(file, sessionConfig: sessionConfig)
    }

    public func updateExportedTranscript(for file: AudioRecordingFile, newTranscript: String) {
        if let path = file.markdownPath {
            try? markdownExporter.updateTranscriptInNote(at: path, newTranscript: newTranscript)
        }
    }

    public func fetchCandidateCalendarEvents(for file: AudioRecordingFile) async throws -> [CalendarEventInfo] {
        return try await calendarService.fetchEvents(around: file.creationDate, duration: file.duration)
    }

    @discardableResult
    public func associateCalendarEvent(for file: AudioRecordingFile, event: CalendarEventInfo?) throws -> AudioRecordingFile {
        var updated = file
        updated.calendarEvent = event
        if let event = event {
            updated.noteTitle = event.title
        }

        let configToUse = availableSessionConfigs.first { $0.slug == file.sessionType } ?? activeSessionConfig

        // 1. Update in cache store
        let cachedNote = CachedRecordingNote(
            id: updated.id,
            audioRelativePath: updated.displayName,
            creationDate: updated.creationDate,
            duration: updated.duration,
            title: updated.noteTitle ?? configToUse.name,
            sessionType: configToUse.slug,
            calendarEvent: updated.calendarEvent,
            transcript: updated.transcript ?? "",
            markdownSummary: updated.markdownSummary ?? "",
            inboxExportURL: updated.markdownPath,
            lastExportedAt: Date(),
            classificationConfidence: updated.classificationConfidence,
            calendarMatchConfidence: updated.calendarMatchConfidence
        )
        try? noteCacheStore.save(cachedNote)

        // 2. Dynamic renaming in inbox if export exists
        if let oldExportURL = updated.markdownPath {
            let newFilename = markdownExporter.defaultFilename(for: updated, typeSlug: configToUse.slug, title: updated.noteTitle)
            let newContent = markdownExporter.buildMarkdownContent(
                for: updated,
                typeSlug: configToUse.slug,
                typeTitle: configToUse.name,
                customTitle: updated.noteTitle
            )
            let newExportURL = try markdownExporter.renameExportedNote(
                for: updated,
                oldURL: oldExportURL,
                newFilename: newFilename,
                newContent: newContent
            )
            updated.markdownPath = newExportURL
            try? historyLedger.markProcessed(file: updated, exportURL: newExportURL)

            var refreshed = cachedNote
            refreshed.inboxExportURL = newExportURL
            try? noteCacheStore.save(refreshed)
        }

        updateDiscoveredFile(updated)
        return updated
    }

    @discardableResult
    public func updateNoteTitle(for file: AudioRecordingFile, newTitle: String) throws -> AudioRecordingFile {
        var updated = file
        let clean = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.noteTitle = clean.isEmpty ? nil : clean

        let configToUse = availableSessionConfigs.first { $0.slug == file.sessionType } ?? activeSessionConfig

        let cachedNote = CachedRecordingNote(
            id: updated.id,
            audioRelativePath: updated.displayName,
            creationDate: updated.creationDate,
            duration: updated.duration,
            title: updated.noteTitle ?? configToUse.name,
            sessionType: configToUse.slug,
            calendarEvent: updated.calendarEvent,
            transcript: updated.transcript ?? "",
            markdownSummary: updated.markdownSummary ?? "",
            inboxExportURL: updated.markdownPath,
            lastExportedAt: Date(),
            classificationConfidence: updated.classificationConfidence,
            calendarMatchConfidence: updated.calendarMatchConfidence
        )
        try? noteCacheStore.save(cachedNote)

        if let oldExportURL = updated.markdownPath {
            let newFilename = markdownExporter.defaultFilename(for: updated, typeSlug: configToUse.slug, title: updated.noteTitle)
            let newContent = markdownExporter.buildMarkdownContent(
                for: updated,
                typeSlug: configToUse.slug,
                typeTitle: configToUse.name,
                customTitle: updated.noteTitle
            )
            let newExportURL = try markdownExporter.renameExportedNote(
                for: updated,
                oldURL: oldExportURL,
                newFilename: newFilename,
                newContent: newContent
            )
            updated.markdownPath = newExportURL
            try? historyLedger.markProcessed(file: updated, exportURL: newExportURL)

            var refreshed = cachedNote
            refreshed.inboxExportURL = newExportURL
            try? noteCacheStore.save(refreshed)
        }

        updateDiscoveredFile(updated)
        return updated
    }

    public func autoClassify(file: AudioRecordingFile) async throws -> SessionTypeConfig {
        guard let transcript = file.transcript, !transcript.isEmpty else {
            return activeSessionConfig
        }
        let classified = try await summarizerEngine.classifySessionType(transcript: transcript, availableTypes: availableSessionConfigs)
        var updated = file
        updated.sessionType = classified.name
        updateDiscoveredFile(updated)
        return classified
    }

    public func updatePromptTemplate(_ template: SummaryPromptTemplate) {
        self.summaryPromptTemplate = template
    }

    public func updateSessionType(_ type: SessionType) {
        self.sessionType = type
    }

    public func setTranscriptionModel(_ modelName: String) {
        if let wk = transcriptionEngine as? WhisperKitEngine {
            Task {
                await wk.setModelName(modelName)
            }
        }
    }

    public func setSummarizerEngine(_ engine: any SummarizerEngine) {
        self.summarizerEngine = engine
    }

    private func updateFileProgress(id: UUID, progress: Double, displayName: String) {
        if let idx = discoveredFiles.firstIndex(where: { $0.displayName == displayName || $0.id == id }) {
            discoveredFiles[idx].transcriptionProgress = progress
            onDiscoveredFilesChanged?(discoveredFiles)
        }
        setPipelineStatus(.transcribing(fileName: displayName, progress: progress))
    }

    public func updateDiscoveredFile(_ updated: AudioRecordingFile) {
        if let idx = discoveredFiles.firstIndex(where: { $0.displayName == updated.displayName || $0.id == updated.id || $0.url.path == updated.url.path }) {
            discoveredFiles[idx] = updated
        } else {
            discoveredFiles.append(updated)
        }
        onDiscoveredFilesChanged?(discoveredFiles)
    }

    private func setPipelineStatus(_ status: PipelineStatus) {
        pipelineStatus = status
        onPipelineStatusChanged?(status)
    }
}
