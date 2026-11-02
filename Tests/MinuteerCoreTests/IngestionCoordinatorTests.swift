import Testing
import Foundation
@testable import MinuteerCore

@Suite("Ingestion Coordinator & Pipeline Tests")
struct IngestionCoordinatorTests {

    @Test("HistoryLedger marks, queries, removes, and recovers records")
    func testHistoryLedger() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ledgerFile = tempDir.appendingPathComponent("history.json")
        let ledger = HistoryLedger(fileURL: ledgerFile)

        let file = AudioRecordingFile(
            url: URL(fileURLWithPath: "/Volumes/P2_SD/250102_184844/MIX.WAV"),
            fileSize: 12345,
            creationDate: Date(timeIntervalSince1970: 1700000000)
        )

        #expect(!ledger.isProcessed(file: file))
        #expect(ledger.getRecord(for: file) == nil)
        #expect(ledger.allRecords.isEmpty)

        // Mark processed
        let exportURL = URL(fileURLWithPath: "/Volumes/Inbox/2026-10-30-meeting.md")
        try ledger.markProcessed(file: file, exportURL: exportURL)

        #expect(ledger.isProcessed(file: file))
        let record = ledger.getRecord(for: file)
        #expect(record != nil)
        #expect(record?.fileName == "MIX.WAV")
        #expect(record?.fileSize == 12345)
        #expect(record?.exportPath == exportURL.path)
        #expect(ledger.allRecords.count == 1)

        // Test reloading from disk
        let reloadedLedger = HistoryLedger(fileURL: ledgerFile)
        #expect(reloadedLedger.isProcessed(file: file))

        // Remove record
        try ledger.removeRecord(for: file)
        #expect(!ledger.isProcessed(file: file))

        // Clear ledger
        try ledger.markProcessed(file: file, exportURL: exportURL)
        #expect(ledger.allRecords.count == 1)
        try ledger.clear()
        #expect(ledger.allRecords.isEmpty)

        // Corrupted file recovery
        try "corrupted json content".data(using: .utf8)?.write(to: ledgerFile)
        let recoveredLedger = HistoryLedger(fileURL: ledgerFile)
        #expect(recoveredLedger.allRecords.isEmpty)

        // Default path initializer
        let defaultLedger = HistoryLedger()
        #expect(defaultLedger.fileURL.path.contains("history.json"))

        // Test parent dir creation during saveUnlocked
        let nestedDir = tempDir.appendingPathComponent("nested_subfolder_test")
        let nestedLedger = HistoryLedger(fileURL: nestedDir.appendingPathComponent("history.json"))
        try nestedLedger.markProcessed(file: file, exportURL: nil)
        #expect(nestedLedger.isProcessed(file: file))
    }

    @Test("NotificationService handles authorization and posting")
    func testNotificationService() async {
        final class NotificationBox: @unchecked Sendable {
            var postedTitle: String?
            var postedBody: String?
        }
        let box = NotificationBox()

        let service = SystemNotificationService(
            customPoster: { title, subtitle, body in
                box.postedTitle = title
                box.postedBody = body
            },
            customAuthorizer: {
                return true
            }
        )

        let authorized = await service.requestAuthorization()
        #expect(authorized)

        await service.postNotification(title: "Test Ingestion", subtitle: "Card Ready", body: "1 file processed")
        #expect(box.postedTitle == "Test Ingestion")
        #expect(box.postedBody == "1 file processed")

        let defaultService = SystemNotificationService.shared
        _ = await defaultService.requestAuthorization()
        await defaultService.postNotification(title: "Default", subtitle: nil, body: "Default Body")

        // Test native defaults
        let liveService = SystemNotificationService.shared
        _ = await liveService.requestAuthorization()
        await liveService.postNotification(title: "Native test", subtitle: "Native sub", body: "Native body")

        let handlerService = SystemNotificationService()
        handlerService.authorizationHandler = { true }
        let hAuth = await handlerService.requestAuthorization()
        #expect(hAuth)

        handlerService.authorizationHandler = { throw NSError(domain: "test", code: 1) }
        let hAuthFail = await handlerService.requestAuthorization()
        #expect(!hAuthFail)

        final class RequestBox: @unchecked Sendable { var reqTitle: String? }
        let reqBox = RequestBox()
        handlerService.notificationCenterAddHandler = { req in
            reqBox.reqTitle = req.content.title
        }
        await handlerService.postNotification(title: "Handler Title", subtitle: "Handler Sub", body: "Handler Body")
        #expect(reqBox.reqTitle == "Handler Title")

        handlerService.notificationCenterAddHandler = { _ in throw NSError(domain: "test", code: 2) }
        await handlerService.postNotification(title: "Handler Err", subtitle: nil, body: "Err Body")
    }

    @Test("PipelineStatus descriptions")
    func testPipelineStatusDescriptions() {
        let dummyURL = URL(fileURLWithPath: "/tmp/note.md")
        let idle = PipelineStatus.idle
        let scanning = PipelineStatus.scanning
        let transcribing = PipelineStatus.transcribing(fileName: "MIX.WAV", progress: 0.45)
        let summarizing = PipelineStatus.summarizing(fileName: "MIX.WAV")
        let exporting = PipelineStatus.exporting(fileName: "MIX.WAV")
        let completed = PipelineStatus.completed(fileName: "MIX.WAV", exportURL: dummyURL)
        let errorNamed = PipelineStatus.error(fileName: "MIX.WAV", message: "Failed")
        let errorGeneric = PipelineStatus.error(fileName: nil, message: "General error")

        #expect(idle.statusDescription == "Idle")
        #expect(!idle.isRunning)
        #expect(scanning.statusDescription.contains("Scanning"))
        #expect(scanning.isRunning)
        #expect(transcribing.statusDescription.contains("45%"))
        #expect(transcribing.isRunning)
        #expect(summarizing.statusDescription.contains("Apple Intelligence"))
        #expect(summarizing.isRunning)
        #expect(exporting.statusDescription.contains("Exporting"))
        #expect(exporting.isRunning)
        #expect(completed.statusDescription.contains("Completed"))
        #expect(!completed.isRunning)
        #expect(errorNamed.statusDescription.contains("MIX.WAV: Failed"))
        #expect(!errorNamed.isRunning)
        #expect(errorGeneric.statusDescription == "Error: General error")
        #expect(!errorGeneric.isRunning)
    }

    @Test("IngestionCoordinator full automated pipeline")
    @MainActor
    func testIngestionPipeline() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cardDir = tempDir.appendingPathComponent("P2_SD")
        let sessionDir = cardDir.appendingPathComponent("250102_184844")
        let inboxDir = tempDir.appendingPathComponent("Inbox")
        let ledgerDir = tempDir.appendingPathComponent("Ledger")

        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create sample audio WAV file on fake SD card
        let wavURL = sessionDir.appendingPathComponent("MIX.WAV")
        try makeValidWAVData(durationSeconds: 1.0).write(to: wavURL)

        let monitor = SDCardMonitor(targetVolumeName: "P2_SD")
        let mockTranscription = MockTranscriptionEngine(mockTranscript: "Speaker 1: Action items decided.")
        let mockSummarizer = AppleIntelligenceSummarizer { prompt in
            return "## Action Items Summary\n- Decided next steps."
        }
        let exporter = MarkdownExporter(destinationDirectory: inboxDir)
        let ledger = HistoryLedger(fileURL: ledgerDir.appendingPathComponent("history.json"))

        final class TestNotificationBox: @unchecked Sendable {
            var sent = false
        }
        let notifBox = TestNotificationBox()
        let notifService = SystemNotificationService(
            customPoster: { _, _, _ in notifBox.sent = true },
            customAuthorizer: { true }
        )

        let coordinator = IngestionCoordinator(
            sdCardMonitor: monitor,
            audioScanner: AudioScanner(),
            transcriptionEngine: mockTranscription,
            summarizerEngine: mockSummarizer,
            markdownExporter: exporter,
            historyLedger: ledger,
            notificationService: notifService,
            noteCacheStore: NoteCacheStore(cacheDirectory: tempDir.appendingPathComponent("NoteCache")),
            audioLibraryDirectory: tempDir.appendingPathComponent("Library"),
            sessionType: .meeting,
            summaryPromptTemplate: .defaultMeeting,
            autoProcessOnInsert: false,
            allowOverwrite: false
        )

        #expect(coordinator.pipelineStatus == .idle)
        #expect(coordinator.discoveredFiles.isEmpty)

        // 1. Scan
        let scanned = await coordinator.scanAudioFiles(volumeURL: cardDir)
        #expect(scanned.count == 1)
        #expect(coordinator.discoveredFiles.count == 1)
        let targetFile = scanned[0]
        #expect(targetFile.displayName.contains("MIX.WAV"))

        // 2. Process
        let exportURL = try await coordinator.processRecording(targetFile)
        #expect(FileManager.default.fileExists(atPath: exportURL.path))
        #expect(coordinator.discoveredFiles.first?.status == .completed)
        #expect(coordinator.discoveredFiles.first?.transcript?.contains("Action items decided.") == true)
        #expect(coordinator.discoveredFiles.first?.markdownSummary?.contains("Action Items Summary") == true)
        #expect(ledger.isProcessed(file: targetFile))
        #expect(notifBox.sent)

        let content = try String(contentsOf: exportURL, encoding: .utf8)
        #expect(content.contains("Action items decided."))
        #expect(content.contains("Action Items Summary"))

        // 3. Second process handles collision safely
        let secondExportURL = try await coordinator.processRecording(targetFile)
        #expect(secondExportURL.path != exportURL.path)
        #expect(FileManager.default.fileExists(atPath: secondExportURL.path))

        // 4. Test re-scan retains processed status
        let rescanned = await coordinator.scanAudioFiles(volumeURL: cardDir)
        #expect(rescanned.first?.status == .completed)

        // 4b. Test retranscribe forces fresh transcription pass
        let retranscribedURL = try await coordinator.retranscribe(file: targetFile)
        #expect(FileManager.default.fileExists(atPath: retranscribedURL.path))
        #expect(coordinator.discoveredFiles.first?.status == .completed)

        // 4c. Test updateExportedTranscript updates note on disk
        if let current = coordinator.discoveredFiles.first {
            coordinator.updateExportedTranscript(for: current, newTranscript: "Manually edited dialogue here.")
            if let exportPath = current.markdownPath {
                let noteContent = try String(contentsOf: exportPath, encoding: .utf8)
                #expect(noteContent.contains("Manually edited dialogue here."))
            }

            _ = try? await coordinator.retranscribe(file: current)
            _ = try? await coordinator.resummarize(file: current, sessionConfig: coordinator.activeSessionConfig)
        }

        // 5. Test processAllUnprocessed (already processed, so returns empty)
        let unprocessed = await coordinator.processAllUnprocessed()
        #expect(unprocessed.isEmpty)

        // 6. Template updates
        coordinator.updatePromptTemplate(.defaultTherapy)
        #expect(coordinator.summaryPromptTemplate.sessionType == .therapy)
        coordinator.updateSessionType(.therapy)
        #expect(coordinator.sessionType == .therapy)
        coordinator.setTranscriptionModel("openai_whisper-large-v3_turbo")

        // 7. Error handling when file is missing
        let missingFile = AudioRecordingFile(
            url: URL(fileURLWithPath: "/tmp/nonexistent.wav"),
            creationDate: Date()
        )
        await #expect(throws: Error.self) {
            _ = try await coordinator.processRecording(missingFile)
        }

        // 8. Delete audio file (Explicit user confirmation required)
        // Ensure card status is inserted so SDCardMonitor allows deletion
        monitor.checkCurrentVolumes()
        // Fake the monitor's internal status for testing if needed
        // Since SDCardMonitor validates file prefix matches volumeURL when inserted,
        // let's create a file on a fake mounted volume or test delete:
        do {
            try coordinator.deleteRecording(targetFile)
        } catch {
            // SD card not inserted error in test environment is expected if not in mountedVolumeURLs
            #expect(error.localizedDescription.contains("SD Card") || error.localizedDescription.contains("Security"))
        }

        // 9. Eject card
        final class EjectBox: @unchecked Sendable { var ejected = false }
        let ejectBox = EjectBox()
        monitor.ejectHandler = { _ in ejectBox.ejected = true }

        try await coordinator.ejectCard()
        #expect(coordinator.discoveredFiles.isEmpty)

        // 10. Start and stop monitoring
        coordinator.startMonitoring()
        coordinator.stopMonitoring()
    }

    @Test("IngestionCoordinator auto-process on mount trigger")
    @MainActor
    func testAutoProcessTrigger() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cardDir = tempDir.appendingPathComponent("P2_SD")
        let sessionDir = cardDir.appendingPathComponent("250102_184844")
        let inboxDir = tempDir.appendingPathComponent("Inbox")
        let ledgerDir = tempDir.appendingPathComponent("Ledger")

        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wavURL = sessionDir.appendingPathComponent("MIX.WAV")
        try makeValidWAVData(durationSeconds: 0.5).write(to: wavURL)

        let monitor = SDCardMonitor(targetVolumeName: "P2_SD")
        let coordinator = IngestionCoordinator(
            sdCardMonitor: monitor,
            transcriptionEngine: MockTranscriptionEngine(mockTranscript: "Auto transcribed"),
            summarizerEngine: AppleIntelligenceSummarizer { _ in "Auto summary" },
            markdownExporter: MarkdownExporter(destinationDirectory: inboxDir),
            historyLedger: HistoryLedger(fileURL: ledgerDir.appendingPathComponent("history.json")),
            notificationService: SystemNotificationService(customPoster: { _, _, _ in }, customAuthorizer: { true }),
            noteCacheStore: NoteCacheStore(cacheDirectory: tempDir.appendingPathComponent("NoteCache")),
            audioLibraryDirectory: tempDir.appendingPathComponent("Library"),
            autoProcessOnInsert: true
        )

        // Simulate SD Card mount
        await coordinator.handleSDCardStatusChanged(.inserted(volumeURL: cardDir, freeBytes: 1000, totalBytes: 5000))
        #expect(coordinator.discoveredFiles.count == 1)
        #expect(coordinator.discoveredFiles.first?.status == .completed)

        // Simulate unmount
        await coordinator.handleSDCardStatusChanged(.notInserted)
        #expect(coordinator.pipelineStatus == .idle)
    }

    @Test("Autonomous classification and calendar match during ingestion pipeline")
    @MainActor
    func testAutonomousIngestionClassificationAndCalendarMatching() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cardDir = tempDir.appendingPathComponent("P2_SD")
        let sessionDir = cardDir.appendingPathComponent("250102_184844")
        let inboxDir = tempDir.appendingPathComponent("Inbox")
        let ledgerDir = tempDir.appendingPathComponent("Ledger")

        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wavURL = sessionDir.appendingPathComponent("MIX.WAV")
        try makeValidWAVData(durationSeconds: 0.5).write(to: wavURL)

        let targetEvent = CalendarEventInfo(
            id: "CAL-AI-MATCH-999",
            title: "Product Roadmap Sync",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            attendees: ["John", "Sarah"]
        )

        let mockSummarizer = AppleIntelligenceSummarizer(sessionRunner: { prompt in
            if prompt.contains("Candidate Calendar Events") {
                return """
                {
                  "matchedEventID": "CAL-AI-MATCH-999",
                  "confidence": 95,
                  "reasoning": "Product roadmap discussion matches event"
                }
                """
            } else if prompt.contains("Available session types") {
                return """
                {
                  "sessionType": "Therapy",
                  "confidence": 92,
                  "reasoning": "Discussed deep emotional challenges and coping"
                }
                """
            } else {
                return "## Summary\\nReflective session summary."
            }
        })

        let coordinator = IngestionCoordinator(
            sdCardMonitor: SDCardMonitor(targetVolumeName: "P2_SD"),
            transcriptionEngine: MockTranscriptionEngine(mockTranscript: "Deep emotional challenges discussed with Sarah."),
            summarizerEngine: mockSummarizer,
            markdownExporter: MarkdownExporter(destinationDirectory: inboxDir),
            historyLedger: HistoryLedger(fileURL: ledgerDir.appendingPathComponent("history.json")),
            notificationService: SystemNotificationService(customPoster: { _, _, _ in }, customAuthorizer: { true }),
            noteCacheStore: NoteCacheStore(cacheDirectory: tempDir.appendingPathComponent("NoteCache")),
            calendarService: MockCalendarService(mockEvents: [targetEvent]),
            audioLibraryDirectory: tempDir.appendingPathComponent("Library"),
            autoProcessOnInsert: false
        )

        let file = AudioRecordingFile(url: wavURL, creationDate: Date())
        let exported = try await coordinator.processRecording(file)

        #expect(FileManager.default.fileExists(atPath: exported.path))
        let processedFile = coordinator.discoveredFiles.first { $0.id == file.id }
        #expect(processedFile?.sessionType == "Therapy")
        #expect(processedFile?.classificationConfidence ?? 0.0 > 0.80)
        #expect(processedFile?.calendarEvent?.id == "CAL-AI-MATCH-999")
        #expect(processedFile?.calendarMatchConfidence ?? 0.0 > 0.80)
        #expect(processedFile?.noteTitle == "Product Roadmap Sync")

        // Test additional coordinator methods for full function coverage
        coordinator.updateAvailableSessionConfigs([SessionTypeConfig.defaultMeeting, SessionTypeConfig.defaultTherapy])
        let candidateEvts = try await coordinator.fetchCandidateCalendarEvents(for: file)
        #expect(candidateEvts.count == 1)

        coordinator.setSummarizerEngine(mockSummarizer)

        if let processed = processedFile {
            // Unlink calendar event
            let unlinked = try coordinator.associateCalendarEvent(for: processed, event: nil)
            #expect(unlinked.calendarEvent == nil)

            // Auto classify file with transcript
            let classifiedConfig = try await coordinator.autoClassify(file: processed)
            #expect(classifiedConfig.slug == "therapy")

            // Empty transcript returns activeSessionConfig
            var emptyFile = processed
            emptyFile.transcript = ""
            let fallbackClass = try await coordinator.autoClassify(file: emptyFile)
            #expect(fallbackClass.slug == "meeting")
        }
    }

    @Test("Low confidence classification respects assigned session type or fallback")
    @MainActor
    func testLowConfidenceIngestionPaths() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cardDir = tempDir.appendingPathComponent("P2_SD")
        let sessionDir = cardDir.appendingPathComponent("250102_184844")
        let inboxDir = tempDir.appendingPathComponent("Inbox")
        let ledgerDir = tempDir.appendingPathComponent("Ledger")

        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wavURL = sessionDir.appendingPathComponent("MIX.WAV")
        try makeValidWAVData(durationSeconds: 0.5).write(to: wavURL)

        // Summarizer returns confidence 0.40 (< 0.80)
        let lowConfSummarizer = AppleIntelligenceSummarizer(sessionRunner: { prompt in
            if prompt.contains("Available session types") {
                return """
                {
                  "sessionType": "Meeting",
                  "confidence": 40,
                  "reasoning": "Unclear discussion"
                }
                """
            } else {
                return "## Summary\\nGeneral summary."
            }
        })

        final class ThrowingCalendarService: CalendarService, @unchecked Sendable {
            func authorizationStatus() -> CalendarAuthorizationStatus { .denied }
            func requestAccess() async -> Bool { false }
            func fetchEvents(around date: Date, duration: TimeInterval) async throws -> [CalendarEventInfo] {
                throw NSError(domain: "CalErr", code: 500)
            }
            func searchEvents(query: String, start: Date, end: Date) async throws -> [CalendarEventInfo] {
                throw NSError(domain: "CalErr", code: 500)
            }
            func listCalendars() -> [DiscoveredCalendarInfo] { [] }
        }

        let wkEngine = WhisperKitEngine()
        let coordinator = IngestionCoordinator(
            sdCardMonitor: SDCardMonitor(targetVolumeName: "P2_SD"),
            transcriptionEngine: wkEngine,
            summarizerEngine: lowConfSummarizer,
            markdownExporter: MarkdownExporter(destinationDirectory: inboxDir),
            historyLedger: HistoryLedger(fileURL: ledgerDir.appendingPathComponent("history.json")),
            notificationService: SystemNotificationService(customPoster: { _, _, _ in }, customAuthorizer: { true }),
            noteCacheStore: NoteCacheStore(cacheDirectory: tempDir.appendingPathComponent("NoteCache")),
            calendarService: ThrowingCalendarService(),
            audioLibraryDirectory: tempDir.appendingPathComponent("Library"),
            autoProcessOnInsert: false
        )

        // Test setTranscriptionModel with WhisperKitEngine
        coordinator.setTranscriptionModel("openai_whisper-base")
        try await Task.sleep(nanoseconds: 30_000_000)

        // Audio recording file with pre-assigned sessionType "Therapy" and old creationDate
        var file = AudioRecordingFile(
            url: wavURL,
            creationDate: Date(timeIntervalSince1970: 1600000000)
        )
        file.sessionType = "Therapy"
        file.transcript = "Pre-existing transcript for testing"

        let exported = try await coordinator.processRecording(file)
        #expect(FileManager.default.fileExists(atPath: exported.path))

        let processed = coordinator.discoveredFiles.first { $0.id == file.id }
        #expect(processed?.sessionType == "Therapy") // Retained because confidence < 80%

        // Also test fallback to activeSessionConfig when sessionType is nil or unknown
        file.sessionType = "UnknownType"
        let fallbackExport = try await coordinator.processRecording(file)
        #expect(FileManager.default.fileExists(atPath: fallbackExport.path))
    }

    @Test("IngestionCoordinator deduplication and concurrent processing prevention")
    @MainActor
    func testDeduplicationAndConcurrentProcessingGuard() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let audioDir = tempDir.appendingPathComponent("Recordings")
        let exportDir = tempDir.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let monitor = SDCardMonitor(targetVolumeName: "TEST_VOL")
        let transcriber = MockTranscriptionEngine(mockTranscript: "Deduplication test transcription")
        let summarizer = AppleIntelligenceSummarizer { _ in "Deduplication test summary" }

        let coordinator = IngestionCoordinator(
            sdCardMonitor: monitor,
            transcriptionEngine: transcriber,
            summarizerEngine: summarizer,
            markdownExporter: MarkdownExporter(destinationDirectory: exportDir),
            historyLedger: HistoryLedger(fileURL: tempDir.appendingPathComponent("history.json")),
            audioLibraryDirectory: audioDir,
            autoProcessOnInsert: false
        )

        let file1 = AudioRecordingFile(
            id: UUID(),
            url: audioDir.appendingPathComponent("250105_195443/MIX.WAV"),
            fileSize: 1024,
            creationDate: Date()
        )
        let file2Duplicate = AudioRecordingFile(
            id: UUID(),
            url: tempDir.appendingPathComponent("other_path/250105_195443/MIX.WAV"),
            fileSize: 1024,
            creationDate: Date()
        )

        // Merging duplicates by displayName preserves single entry
        coordinator.mergeDiscoveredFiles([file1, file2Duplicate])
        #expect(coordinator.discoveredFiles.count == 1)

        // Updating with a file that has matching displayName updates in-place
        var updated = file2Duplicate
        updated.transcriptionProgress = 0.5
        coordinator.updateDiscoveredFile(updated)
        #expect(coordinator.discoveredFiles.count == 1)
        #expect(coordinator.discoveredFiles.first?.transcriptionProgress == 0.5)

        // Test concurrent processRecording guard
        try FileManager.default.createDirectory(at: file1.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeValidWAVData(durationSeconds: 0.2).write(to: file1.url)
        async let run1 = coordinator.processRecording(file1)
        async let run2 = coordinator.processRecording(file1)

        let results = await (try? run1, try? run2)
        // At least one succeeds and the other either succeeds (reuses output) or raises the concurrency guard
        #expect(results.0 != nil || results.1 != nil)
    }

    @Test("IngestionCoordinator cancelProcessing resets in-flight state and clears queue")
    @MainActor
    func testCancelProcessing() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let audioDir = tempDir.appendingPathComponent("Recordings")
        let exportDir = tempDir.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let monitor = SDCardMonitor(targetVolumeName: "TEST_VOL")
        let transcriber = MockTranscriptionEngine(mockTranscript: "Test")
        let summarizer = AppleIntelligenceSummarizer { _ in "Test Summary" }

        let coordinator = IngestionCoordinator(
            sdCardMonitor: monitor,
            transcriptionEngine: transcriber,
            summarizerEngine: summarizer,
            markdownExporter: MarkdownExporter(destinationDirectory: exportDir),
            historyLedger: HistoryLedger(fileURL: tempDir.appendingPathComponent("history.json")),
            audioLibraryDirectory: audioDir,
            autoProcessOnInsert: false
        )

        let file = AudioRecordingFile(
            id: UUID(),
            url: audioDir.appendingPathComponent("REC001.WAV"),
            fileSize: 1024,
            creationDate: Date(),
            status: .transcribing,
            transcriptionProgress: 0.45
        )
        let file2 = AudioRecordingFile(
            id: UUID(),
            url: audioDir.appendingPathComponent("REC002.WAV"),
            fileSize: 2048,
            creationDate: Date(),
            status: .summarizing,
            transcriptionProgress: 0.80
        )
        coordinator.mergeDiscoveredFiles([file, file2])
        #expect(coordinator.discoveredFiles.first(where: { $0.id == file.id })?.status == .transcribing)
        #expect(coordinator.discoveredFiles.first(where: { $0.id == file2.id })?.status == .summarizing)

        coordinator.cancelProcessing()
        #expect(coordinator.discoveredFiles.allSatisfy { $0.status == .discovered && $0.transcriptionProgress == 0.0 })
        #expect(coordinator.pipelineStatus == .idle)
    }
}
