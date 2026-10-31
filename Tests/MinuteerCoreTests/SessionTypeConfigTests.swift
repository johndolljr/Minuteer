import Testing
import Foundation
@testable import MinuteerCore

@Suite("Session Type & App Configuration Tests")
struct SessionTypeConfigTests {
    @Test("SessionTypeConfig defaults and custom initialization")
    func testSessionTypeConfig() {
        let defaults = SessionTypeConfig.defaultList
        #expect(defaults.count == 2)
        #expect(SessionTypeConfig.defaultMeeting.name == "Meeting")
        #expect(SessionTypeConfig.defaultMeeting.slug == "meeting")
        #expect(SessionTypeConfig.defaultMeeting.glyph == "👥")
        #expect(SessionTypeConfig.defaultTherapy.name == "Therapy")
        #expect(SessionTypeConfig.defaultTherapy.slug == "therapy")
        #expect(SessionTypeConfig.defaultTherapy.glyph == "🌿")
        #expect(SessionTypeConfig.defaultCustom.name == "Custom")
        #expect(SessionTypeConfig.defaultCustom.slug == "custom")
        #expect(SessionTypeConfig.defaultCustom.glyph == "💡")

        // Glyphs for other categories
        #expect(SessionTypeConfig.glyph(for: "voice_memo") == "🎙️")
        #expect(SessionTypeConfig.glyph(for: "executive_brief") == "📊")
        #expect(SessionTypeConfig.glyph(for: "tech_spec") == "⚙️")
        #expect(SessionTypeConfig.glyph(for: "general") == "💡")

        let customID = UUID()
        let custom = SessionTypeConfig(
            id: customID,
            name: "Interview",
            slug: "interview",
            systemInstructions: "Extract questions and answers."
        )
        #expect(custom.id == customID)
        #expect(custom.name == "Interview")
        #expect(custom.slug == "interview")
        #expect(custom.systemInstructions == "Extract questions and answers.")
    }

    @Test("AppConfig initialization, encoding and decoding")
    func testAppConfigSerialization() throws {
        let defaultConf = AppConfig()
        #expect(defaultConf.targetVolumeName == "P2_SD")
        #expect(defaultConf.autoProcessOnInsert == true)
        #expect(defaultConf.sessionTypes.count == 2)
        #expect(defaultConf.whisperModelName == "openai_whisper-base")
        #expect(defaultConf.autoMatchCalendarEvents == true)
        #expect(!defaultConf.audioLibraryDirectoryPath.isEmpty)
        #expect(defaultConf.watchDirectoryEnabled == false)
        #expect(defaultConf.deleteFromSourceAfterCopy == true)

        let customConf = AppConfig(
            targetVolumeName: "ZOOM_REC",
            exportDirectoryPath: "/tmp/custom_inbox",
            audioLibraryDirectoryPath: "/tmp/custom_audio",
            watchDirectoryPath: "/tmp/custom_watch",
            watchDirectoryEnabled: true,
            deleteFromSourceAfterCopy: false,
            autoProcessOnInsert: false,
            selectedSessionTypeID: SessionTypeConfig.defaultTherapy.id,
            sessionTypes: [SessionTypeConfig.defaultTherapy],
            whisperModelName: "openai_whisper-large-v3_turbo",
            summarizerProvider: .openAICompatible,
            openAIEndpoint: "http://localhost:11434/v1",
            openAIModelName: "llama3.2",
            openAIApiKey: "sk-mykey",
            autoMatchCalendarEvents: false
        )
        #expect(customConf.audioLibraryDirectoryPath == "/tmp/custom_audio")
        #expect(customConf.watchDirectoryPath == "/tmp/custom_watch")
        #expect(customConf.watchDirectoryEnabled == true)
        #expect(customConf.deleteFromSourceAfterCopy == false)
        #expect(customConf.autoMatchCalendarEvents == false)
        #expect(customConf.summarizerProvider == .openAICompatible)
        #expect(customConf.openAIModelName == "llama3.2")
        #expect(customConf.openAIApiKey == "sk-mykey")
        #expect(customConf.targetVolumeName == "ZOOM_REC")
        #expect(customConf.autoProcessOnInsert == false)
        #expect(customConf.sessionTypes.count == 1)
        #expect(customConf.whisperModelName == "openai_whisper-large-v3_turbo")

        let data = try JSONEncoder().encode(customConf)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded == customConf)

        // Test backward compatibility: JSON missing whisperModelName and exportDirectoryPath
        let legacyJSON = """
        {
            "targetVolumeName": "P2_SD",
            "autoProcessOnInsert": true,
            "selectedSessionTypeID": "11111111-1111-1111-1111-111111111111",
            "sessionTypes": []
        }
        """.data(using: .utf8)!
        let legacyDecoded = try JSONDecoder().decode(AppConfig.self, from: legacyJSON)
        #expect(legacyDecoded.whisperModelName == "openai_whisper-base")
        #expect(legacyDecoded.exportDirectoryPath == AppConfig.defaultExportDirectory)
    }

    @Test("AppConfigStorage load, save, and persistence")
    func testAppConfigStorage() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = tempDir.appendingPathComponent("test_config.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = AppConfigStorage(configFileURL: fileURL)
        let loaded = storage.load()
        #expect(loaded.targetVolumeName == "P2_SD")

        // Test default nil init and shared instance
        let defaultStorage = AppConfigStorage(configFileURL: nil)
        #expect(!defaultStorage.configFileURL.path.isEmpty)
        _ = AppConfigStorage.shared.load()

        var newConfig = loaded
        newConfig.targetVolumeName = "CUSTOM_CARD"
        newConfig.exportDirectoryPath = "/tmp/new_export"
        try storage.save(newConfig)

        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let reloadedStorage = AppConfigStorage(configFileURL: fileURL)
        let reloaded = reloadedStorage.load()
        #expect(reloaded.targetVolumeName == "CUSTOM_CARD")
        #expect(reloaded.exportDirectoryPath == "/tmp/new_export")
    }

    @Test("Dynamic target volume name and destination directory mutability")
    func testDynamicMonitorAndExporterProperties() {
        let monitor = SDCardMonitor(targetVolumeName: "INITIAL_CARD")
        #expect(monitor.targetVolumeName == "INITIAL_CARD")
        monitor.targetVolumeName = "UPDATED_CARD"
        #expect(monitor.targetVolumeName == "UPDATED_CARD")

        let exporter = MarkdownExporter(destinationDirectory: URL(fileURLWithPath: "/tmp/dirA"))
        #expect(exporter.destinationDirectory.path == "/tmp/dirA")
        exporter.destinationDirectory = URL(fileURLWithPath: "/tmp/dirB")
        #expect(exporter.destinationDirectory.path == "/tmp/dirB")
    }

    @Test("IngestionCoordinator active session config update")
    @MainActor
    func testCoordinatorActiveSessionConfig() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let monitor = SDCardMonitor(targetVolumeName: "P2_SD")
        let transcriber = MockTranscriptionEngine()
        let summarizer = AppleIntelligenceSummarizer { _ in "Mock Summary" }
        let exporter = MarkdownExporter(destinationDirectory: tempDir)
        let coordinator = IngestionCoordinator(
            sdCardMonitor: monitor,
            transcriptionEngine: transcriber,
            summarizerEngine: summarizer,
            markdownExporter: exporter,
            historyLedger: HistoryLedger(fileURL: tempDir.appendingPathComponent("history.json")),
            noteCacheStore: NoteCacheStore(cacheDirectory: tempDir.appendingPathComponent("cache")),
            audioLibraryDirectory: tempDir.appendingPathComponent("lib")
        )

        #expect(coordinator.activeSessionConfig.name == "Meeting")
        let newConfig = SessionTypeConfig(name: "Standup", slug: "standup", systemInstructions: "Quick bullet points.")
        coordinator.updateActiveSessionConfig(newConfig)
        #expect(coordinator.activeSessionConfig.name == "Standup")
        #expect(coordinator.activeSessionConfig.slug == "standup")

        coordinator.updateAvailableSessionConfigs([newConfig, SessionTypeConfig.defaultMeeting])
        #expect(coordinator.availableSessionConfigs.count == 2)
    }

    @Test("AppleIntelligenceSummarizer classifySessionType logic")
    func testSummarizerClassification() async throws {
        let summarizer = AppleIntelligenceSummarizer(sessionRunner: { prompt in
            if prompt.contains("Therapy") {
                return "Therapy"
            }
            return "Meeting"
        })

        let types = SessionTypeConfig.defaultList
        let classified = try await summarizer.classifySessionType(
            transcript: "Doctor, I've been feeling anxious and reflecting on emotional patterns.",
            availableTypes: types
        )
        #expect(classified.slug == "therapy")

        // Edge cases: single type or empty types
        let single = try await summarizer.classifySessionType(transcript: "test", availableTypes: [SessionTypeConfig.defaultMeeting])
        #expect(single.slug == "meeting")

        let empty = try await summarizer.classifySessionType(transcript: "test", availableTypes: [])
        #expect(empty.slug == "meeting")

        // Fallback on unrecognized response
        let unknownSummarizer = AppleIntelligenceSummarizer(sessionRunner: { _ in "unrelated text" })
        let fallback = try await unknownSummarizer.classifySessionType(transcript: "test", availableTypes: types)
        #expect(fallback.slug == "meeting")
    }

    @Test("Coordinator auto-classification and re-summarize")
    @MainActor
    func testCoordinatorAutoClassify() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let monitor = SDCardMonitor(targetVolumeName: "P2_SD")
        let transcriber = MockTranscriptionEngine()
        let summarizer = AppleIntelligenceSummarizer(sessionRunner: { prompt in
            if prompt.contains("classifier") {
                return "Therapy"
            }
            return "Generated summary note content"
        })
        let exporter = MarkdownExporter(destinationDirectory: tempDir)
        let coordinator = IngestionCoordinator(
            sdCardMonitor: monitor,
            transcriptionEngine: transcriber,
            summarizerEngine: summarizer,
            markdownExporter: exporter,
            historyLedger: HistoryLedger(fileURL: tempDir.appendingPathComponent("history.json")),
            noteCacheStore: NoteCacheStore(cacheDirectory: tempDir.appendingPathComponent("cache")),
            audioLibraryDirectory: tempDir.appendingPathComponent("lib")
        )

        var file = AudioRecordingFile(
            url: tempDir.appendingPathComponent("test.wav"),
            fileSize: 100,
            creationDate: Date()
        )
        try Data("dummy audio".utf8).write(to: file.url)
        file.transcript = "I talked about personal emotions and feeling overwhelmed."

        let detected = try await coordinator.autoClassify(file: file)
        #expect(detected.slug == "therapy")

        // Resummarize
        let exportURL = try await coordinator.resummarize(file: file, sessionConfig: detected)
        #expect(FileManager.default.fileExists(atPath: exportURL.path))
    }

    @Test("SpeakerDirectory persistence, lookup, and diarization pass")
    func testSpeakerDirectoryAndDiarization() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("speakers.json")
        let directory = SpeakerDirectory(fileURL: fileURL)
        #expect(directory.allSpeakers.isEmpty)
        _ = SpeakerDirectory.shared.allSpeakers

        let john = SpeakerProfile(name: "John", aliases: ["JD"], contextNotes: "Lead Developer")
        directory.addSpeaker(john)
        #expect(directory.allSpeakers.count == 1)
        #expect(directory.getSpeaker(named: "John")?.name == "John")
        #expect(directory.getSpeaker(named: "JD")?.name == "John")
        #expect(directory.getSpeaker(named: "Unknown") == nil)

        var updatedJohn = john
        updatedJohn.contextNotes = "Senior Lead Developer"
        directory.updateSpeaker(updatedJohn)
        #expect(directory.getSpeaker(named: "John")?.contextNotes == "Senior Lead Developer")

        // Reload
        let reloaded = SpeakerDirectory(fileURL: fileURL)
        #expect(reloaded.allSpeakers.count == 1)

        // Delete
        reloaded.deleteSpeaker(id: john.id)
        #expect(reloaded.allSpeakers.isEmpty)

        // Diarization test
        let summarizer = AppleIntelligenceSummarizer(sessionRunner: { prompt in
            return "**John**: We need to ship the release.\n\n**Speaker 2**: Agreed, all tests are passing."
        })

        let raw = "We need to ship the release. Agreed, all tests are passing."
        let diarized = try await summarizer.diarizeTranscript(transcript: raw, knownSpeakers: [john])
        #expect(diarized.contains("**John**:"))
        #expect(diarized.contains("**Speaker 2**:"))

        let noSpeakersDiarized = try await summarizer.diarizeTranscript(transcript: raw, knownSpeakers: [])
        #expect(!noSpeakersDiarized.isEmpty)

        let emptyDiarized = try await summarizer.diarizeTranscript(transcript: "", knownSpeakers: [])
        #expect(emptyDiarized.isEmpty)
    }

    @Test("OpenAICompatibleSummarizer full lifecycle, network execution and testConnection")
    func testOpenAICompatibleSummarizer() async throws {
        // Mock URLSession configuration
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockOpenAIURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        let summarizer = OpenAICompatibleSummarizer(
            endpoint: "http://localhost:11434/v1",
            modelName: "llama3.2",
            apiKey: "sk-test",
            session: mockSession
        )

        #expect(summarizer.name.contains("llama3.2"))

        // 1. Success response
        MockOpenAIURLProtocol.requestHandler = { req in
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
            #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {
                "choices": [
                    {
                        "message": {
                            "content": "This is a great executive summary of the meeting."
                        }
                    }
                ]
            }
            """.data(using: .utf8)!
            return (response, json)
        }

        let result = try await summarizer.executePrompt("Summarize")
        #expect(result.contains("executive summary"))

        let defaultSummarizer = OpenAICompatibleSummarizer()
        #expect(defaultSummarizer.modelName == "gpt-4o-mini")
        #expect(defaultSummarizer.endpoint == "https://api.openai.com/v1")
        #expect(defaultSummarizer.name.contains("gpt-4o-mini"))
        #expect(summarizer.name.contains("llama3.2"))

        let connectionTest = try await summarizer.testConnection()
        #expect(connectionTest.model == "llama3.2")
        #expect(connectionTest.latencyMs >= 1)

        // 2. Custom runner override
        summarizer.customRunner = { _ in return "Custom runner response" }
        let customRes = try await summarizer.executePrompt("Test")
        #expect(customRes == "Custom runner response")
        summarizer.customRunner = nil

        // 3. HTTP error response
        MockOpenAIURLProtocol.requestHandler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, "Unauthorized".data(using: .utf8)!)
        }
        await #expect(throws: Error.self) {
            _ = try await summarizer.executePrompt("Test error")
        }

        // 4. Malformed JSON response
        MockOpenAIURLProtocol.requestHandler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }
        await #expect(throws: Error.self) {
            _ = try await summarizer.executePrompt("Test malformed")
        }

        // 5. Invalid URL
        let invalidSummarizer = OpenAICompatibleSummarizer(endpoint: ":::not a url:::", session: mockSession)
        await #expect(throws: Error.self) {
            _ = try await invalidSummarizer.executePrompt("Invalid")
        }
        await #expect(throws: Error.self) {
            _ = try await invalidSummarizer.fetchAvailableModels()
        }

        // 5b. Fetch available models
        MockOpenAIURLProtocol.requestHandler = { req in
            #expect(req.url?.path.contains("/models") == true)
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {
                "data": [
                    { "id": "gpt-4o" },
                    { "id": "gpt-4o-mini" },
                    { "id": "o3-mini" }
                ]
            }
            """.data(using: .utf8)!
            return (response, json)
        }
        let fetchedModels = try await summarizer.fetchAvailableModels()
        #expect(fetchedModels.count == 3)
        #expect(fetchedModels.contains("gpt-4o-mini"))

        // Fetch models with error response
        MockOpenAIURLProtocol.requestHandler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, "Server error".data(using: .utf8)!)
        }
        await #expect(throws: Error.self) {
            _ = try await summarizer.fetchAvailableModels()
        }

        // 6. Classification & Title generation
        for provider in SummarizerProvider.allCases {
            #expect(!provider.displayName.isEmpty)
        }

        MockOpenAIURLProtocol.requestHandler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {
                "choices": [{ "message": { "content": "Therapy" } }]
            }
            """.data(using: .utf8)!
            return (response, json)
        }
        let classified = try await summarizer.classifySessionType(transcript: "I felt anxious today.", availableTypes: SessionTypeConfig.defaultList)
        #expect(classified.slug == "therapy")

        _ = try await summarizer.classifySessionType(transcript: "test", availableTypes: [])
        _ = try await summarizer.classifySessionType(transcript: "test", availableTypes: [SessionTypeConfig.defaultMeeting])

        MockOpenAIURLProtocol.requestHandler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {
                "choices": [{ "message": { "content": "Title: # Quarterly Roadmap Sync" } }]
            }
            """.data(using: .utf8)!
            return (response, json)
        }
        let title = try await summarizer.generateTitle(transcript: "Let's review the quarterly roadmap.", summary: nil)
        #expect(title == "Quarterly Roadmap Sync")

        let titleWithSummary = try await summarizer.generateTitle(transcript: "...", summary: "Detailed meeting summary.")
        #expect(!titleWithSummary.isEmpty)

        let emptyTitle = try await summarizer.generateTitle(transcript: "", summary: "")
        #expect(emptyTitle == "Audio Recording Note")

        // 7. Diarization
        MockOpenAIURLProtocol.requestHandler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {
                "choices": [{ "message": { "content": "[00:00] **Alice**: Hello team." } }]
            }
            """.data(using: .utf8)!
            return (response, json)
        }
        let alice = SpeakerProfile(name: "Alice", aliases: ["Ally"], contextNotes: "Engineer")
        let diarized = try await summarizer.diarizeTranscript(transcript: "Hello team.", knownSpeakers: [alice])
        #expect(diarized.contains("Alice"))

        let diarizedNoSpeakers = try await summarizer.diarizeTranscript(transcript: "Hello team. How are you?", knownSpeakers: [])
        #expect(!diarizedNoSpeakers.isEmpty)

        let emptyDiarized = try await summarizer.diarizeTranscript(transcript: "", knownSpeakers: [alice])
        #expect(emptyDiarized.isEmpty)

        // 8. Summarization and chunking
        let shortSummary = try await summarizer.summarize(transcript: "Short text", template: .defaultMeeting)
        #expect(!shortSummary.isEmpty)

        let longText = String(repeating: "Discussion about engineering architecture and roadmap.\n", count: 80)
        let longSummary = try await summarizer.summarize(transcript: longText, template: .defaultMeeting)
        #expect(!longSummary.isEmpty)

        let chunkedDirect = try await summarizer.summarizeWithChunking(transcript: longText, template: .defaultMeeting, maxChunkSize: 500)
        #expect(!chunkedDirect.isEmpty)

        // Test reasoning model without temperature
        summarizer.modelName = "o3-mini"
        MockOpenAIURLProtocol.requestHandler = { req in
            if let bodyData = req.httpBody, let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                #expect(body["temperature"] == nil)
            }
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            { "choices": [{ "message": { "content": "Reasoning response" } }] }
            """.data(using: .utf8)!
            return (response, json)
        }
        let o3Res = try await summarizer.executePrompt("Reasoning test")
        #expect(o3Res == "Reasoning response")

        // Test temperature recovery: 400 with temperature error
        summarizer.modelName = "custom-model"
        var attempt = 0
        MockOpenAIURLProtocol.requestHandler = { req in
            attempt += 1
            if attempt == 1 {
                let response = HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
                let json = """
                { "error": { "message": "unsupported parameter: temperature" } }
                """.data(using: .utf8)!
                return (response, json)
            } else {
                let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                { "choices": [{ "message": { "content": "Recovered response" } }] }
                """.data(using: .utf8)!
                return (response, json)
            }
        }
        let recoveredRes = try await summarizer.executePrompt("Retry test")
        #expect(recoveredRes == "Recovered response")
        summarizer.modelName = "llama3.2"

        // Chunking test with regular and oversized single paragraph
        let chunks = summarizer.chunkTranscript(longText, maxChunkSize: 500)
        #expect(chunks.count > 1)
        #expect(summarizer.chunkTranscript("").isEmpty)

        let hugeParagraph = String(repeating: "abcdefghij", count: 100)
        let hugeChunks = summarizer.chunkTranscript(hugeParagraph, maxChunkSize: 200)
        #expect(hugeChunks.count >= 5)

        // Endpoint normalization tests
        summarizer.endpoint = "http://localhost:11434/v1/"
        _ = try await summarizer.executePrompt("Endpoint test 1")
        summarizer.endpoint = "http://localhost:11434/v1/chat/completions"
        _ = try await summarizer.executePrompt("Endpoint test 2")
        summarizer.endpoint = "http://localhost:11434/v1"

        // Test classifySessionTypeWithConfidence via network
        MockOpenAIURLProtocol.requestHandler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {
                "choices": [{
                    "message": {
                        "content": "{\\"sessionType\\": \\"Therapy\\", \\"confidence\\": 95, \\"reasoning\\": \\"Clear clinical reflection\\"}"
                    }
                }]
            }
            """.data(using: .utf8)!
            return (response, json)
        }
        let netClass = try await summarizer.classifySessionTypeWithConfidence(
            transcript: "I felt deep emotions today.",
            availableTypes: SessionTypeConfig.defaultList
        )
        #expect(netClass.config.slug == "therapy")
        #expect(netClass.confidence == 0.95)

        // Test matchCalendarEvent via network
        let testEv = CalendarEventInfo(id: "NET-EV-1", title: "Strategy Sync", startDate: Date(), endDate: Date())
        MockOpenAIURLProtocol.requestHandler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {
                "choices": [{
                    "message": {
                        "content": "{\\"matchedEventID\\": \\"NET-EV-1\\", \\"confidence\\": 90, \\"reasoning\\": \\"Matches strategy sync\\"}"
                    }
                }]
            }
            """.data(using: .utf8)!
            return (response, json)
        }
        let netCal = try await summarizer.matchCalendarEvent(
            transcript: "Discussed strategy sync.",
            candidateEvents: [testEv],
            fileDate: Date()
        )
        #expect(netCal.matchedEvent?.id == "NET-EV-1")
        #expect(netCal.confidence == 0.90)

        // IngestionCoordinator integration
        await MainActor.run {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let monitor = SDCardMonitor(targetVolumeName: "P2_SD")
            let coord = IngestionCoordinator(
                sdCardMonitor: monitor,
                audioScanner: AudioScanner(),
                transcriptionEngine: MockTranscriptionEngine(),
                summarizerEngine: summarizer,
                markdownExporter: MarkdownExporter(destinationDirectory: tempDir),
                historyLedger: HistoryLedger(fileURL: tempDir.appendingPathComponent("history.json")),
                notificationService: SystemNotificationService.shared,
                noteCacheStore: NoteCacheStore(cacheDirectory: tempDir.appendingPathComponent("cache")),
                audioLibraryDirectory: tempDir.appendingPathComponent("lib")
            )
            coord.setSummarizerEngine(AppleIntelligenceSummarizer())
            #expect(coord.summarizerEngine.name.contains("Apple Intelligence"))

            let sampleFile = AudioRecordingFile(
                url: URL(fileURLWithPath: "/tmp/sample.wav"),
                fileSize: 1024,
                creationDate: Date(),
                duration: 10
            )
            coord.updateDiscoveredFile(sampleFile)
        }
    }
}

final class MockOpenAIURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = MockOpenAIURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
