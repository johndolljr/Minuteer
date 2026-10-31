import Testing
import Foundation
#if canImport(EventKit)
@preconcurrency import EventKit
#endif
#if canImport(AppKit)
import AppKit
#endif
@testable import MinuteerCore

@Suite("Calendar Service & Note Cache Tests")
struct CalendarAndCacheTests {

    @Test("CalendarEventInfo formatting and initialization")
    func testCalendarEventInfo() {
        let start = Date(timeIntervalSince1970: 1700000000)
        let end = Date(timeIntervalSince1970: 1700003600)
        let event = CalendarEventInfo(
            id: "evt-123",
            title: "Sprint Planning",
            startDate: start,
            endDate: end,
            calendarTitle: "Work",
            calendarColorHex: "#FF5733",
            location: "Room 101",
            notes: "Bring your laptop",
            attendees: ["alice@example.com", "bob@example.com"],
            isAllDay: false
        )

        #expect(event.id == "evt-123")
        #expect(event.title == "Sprint Planning")
        #expect(event.calendarTitle == "Work")
        #expect(event.calendarColorHex == "#FF5733")
        #expect(event.location == "Room 101")
        #expect(event.notes == "Bring your laptop")
        #expect(event.attendees.count == 2)
        #expect(!event.isAllDay)
        #expect(!event.formattedTimeRange.isEmpty)

        let recording = AudioRecordingFile(
            url: URL(fileURLWithPath: "/Volumes/P2_SD/250102_TEST/MIX.WAV"),
            fileSize: 1024,
            creationDate: start,
            duration: 120,
            calendarEvent: event
        )
        #expect(recording.formattedDate.count > 0)
        #expect(recording.calendarEvent?.title == "Sprint Planning")
    }

    @Test("MockCalendarService lifecycle, authorization, and event matching")
    func testMockCalendarService() async throws {
        let baseDate = Date(timeIntervalSince1970: 1700000000)
        let event1 = CalendarEventInfo(
            id: "1",
            title: "Team Standup",
            startDate: baseDate.addingTimeInterval(-1800),
            endDate: baseDate.addingTimeInterval(1800),
            calendarTitle: "Work"
        )
        let event1b = CalendarEventInfo(
            id: "1b",
            title: "Team Retrospective",
            startDate: baseDate.addingTimeInterval(1000),
            endDate: baseDate.addingTimeInterval(2000),
            calendarTitle: "Work"
        )
        let event2 = CalendarEventInfo(
            id: "2",
            title: "Dentist Appointment",
            startDate: baseDate.addingTimeInterval(86400),
            endDate: baseDate.addingTimeInterval(90000),
            calendarTitle: "Personal"
        )

        let mock = MockCalendarService(mockEvents: [event1, event1b, event2], mockStatus: .notDetermined, requestAccessResult: true)
        #expect(mock.authorizationStatus() == .notDetermined)

        let granted = await mock.requestAccess()
        #expect(granted)
        #expect(mock.authorizationStatus() == .authorized)

        // Fetch events around baseDate
        let nearby = try await mock.fetchEvents(around: baseDate, duration: 1800)
        #expect(nearby.count == 2)
        #expect(nearby.first?.title == "Team Standup")

        // Search events
        let searchResults = try await mock.searchEvents(
            query: "dentist",
            start: baseDate,
            end: baseDate.addingTimeInterval(100000)
        )
        #expect(searchResults.count == 1)
        #expect(searchResults.first?.title == "Dentist Appointment")

        let eventWithNotes = CalendarEventInfo(
            id: "notes-evt",
            title: "Offsite",
            startDate: baseDate,
            endDate: baseDate.addingTimeInterval(3600),
            location: "Tahoe Lodge",
            notes: "Bring warm clothes"
        )
        let mockWithNotes = MockCalendarService(mockEvents: [eventWithNotes], mockStatus: .authorized)
        let searchLoc = try await mockWithNotes.searchEvents(query: "Tahoe", start: baseDate.addingTimeInterval(-100), end: baseDate.addingTimeInterval(5000))
        #expect(searchLoc.count == 1)
        let searchNotes = try await mockWithNotes.searchEvents(query: "clothes", start: baseDate.addingTimeInterval(-100), end: baseDate.addingTimeInterval(5000))
        #expect(searchNotes.count == 1)

        let emptySearch = try await mock.searchEvents(
            query: "",
            start: baseDate,
            end: baseDate.addingTimeInterval(100000)
        )
        #expect(emptySearch.count == 3)

        // Denied case
        let deniedMock = MockCalendarService(mockEvents: [event1], mockStatus: .denied, requestAccessResult: false)
        let deniedGranted = await deniedMock.requestAccess()
        #expect(!deniedGranted)
        let deniedNearby = try await deniedMock.fetchEvents(around: baseDate, duration: 1800)
        #expect(deniedNearby.isEmpty)
        let deniedSearch = try await deniedMock.searchEvents(query: "Team", start: baseDate, end: baseDate.addingTimeInterval(5000))
        #expect(deniedSearch.isEmpty)
        #expect(deniedMock.listCalendars().isEmpty)
        #expect(mock.listCalendars().count == 2)

        let allDayEvt = CalendarEventInfo(
            id: "allday",
            title: "All Day Holiday",
            startDate: baseDate,
            endDate: baseDate.addingTimeInterval(86400),
            calendarTitle: "Holidays",
            calendarColorHex: "#FF9500",
            location: nil,
            notes: nil,
            attendees: ["alice@example.com"],
            isAllDay: true
        )
        #expect(allDayEvt.isAllDay)
        #expect(allDayEvt.attendees.contains("alice@example.com"))
        #expect(!allDayEvt.formattedTimeRange.isEmpty)
    }

    @Test("CalendarEventInfo cleanLocation and cleanNotes sanitization")
    func testCalendarEventSanitization() {
        let rawHtmlInvite = """
        --Original Appointment-----
        From: Alex Taylor <alex.taylor@example.com>
        Sent: Monday, August 1, 2022 6:58 AM
        To: Team Members <team@example.com>
        Subject: Team Standup
        When: Occurs every day
        Where: https://zoom.us/j/123456789?pwd=mockPassword123

        Minutes of our daily call is here &lt;onenote://example.com/daily&gt;.
        <div>Hi there, Alex is inviting you to a scheduled Zoom meeting.</div>
        Join Zoom Meeting
        Meeting ID: 123 456 789
        Passcode: 123456
        One tap mobile
        +16468769923,,123456789#
        Dial by your location
        Find your local number: https://zoom.us/u/acde
        """

        let event = CalendarEventInfo(
            id: "zoom-1",
            title: "Team Standup",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            location: "https://zoom.us/j/123456789?pwd=mockPassword123",
            notes: rawHtmlInvite,
            attendees: ["mailto:alice@example.com", "Bob Smith", "Bob Smith"]
        )

        let cleanLoc = event.cleanLocation
        #expect(cleanLoc?.displayText == "Zoom Meeting")
        #expect(cleanLoc?.url != nil)

        let cleanAgenda = event.cleanNotes
        #expect(cleanAgenda != nil)
        #expect(cleanAgenda?.contains("Minutes of our daily call is here <onenote://example.com/daily>.") == true)
        #expect(cleanAgenda?.contains("--Original Appointment-----") == false)
        #expect(cleanAgenda?.contains("Join Zoom Meeting") == false)
        #expect(cleanAgenda?.contains("Meeting ID:") == false)

        let boilerplateOnly = """
        Join Zoom Meeting
        https://zoom.us/j/123456
        Meeting ID: 123456
        Passcode: 9999
        """
        #expect(CalendarEventInfo.sanitizeCalendarNotes(boilerplateOnly) == nil)
        #expect(CalendarEventInfo.sanitizeCalendarNotes("") == nil)
        #expect(CalendarEventInfo.sanitizeCalendarNotes("   ") == nil)

        let roomEvent = CalendarEventInfo(
            id: "room-1",
            title: "1:1",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            location: "Conference Room B"
        )
        #expect(roomEvent.cleanLocation?.displayText == "Conference Room B")
        #expect(roomEvent.cleanLocation?.url == nil)

        let teamsEvent = CalendarEventInfo(
            id: "teams-1",
            title: "Sync",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            location: "https://teams.microsoft.com/l/meetup-join/123"
        )
        #expect(teamsEvent.cleanLocation?.displayText == "Microsoft Teams Meeting")

        let meetEvent = CalendarEventInfo(
            id: "meet-1",
            title: "Sync",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            location: "https://meet.google.com/abc-defg-hij"
        )
        #expect(meetEvent.cleanLocation?.displayText == "Google Meet")

        let webexEvent = CalendarEventInfo(
            id: "webex-1",
            title: "Sync",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            location: "https://company.webex.com/meet/user"
        )
        #expect(webexEvent.cleanLocation?.displayText == "Webex Meeting")

        let genericEvent = CalendarEventInfo(
            id: "gen-1",
            title: "Sync",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            location: "https://conference.internal.company.com/room"
        )
        #expect(genericEvent.cleanLocation?.displayText == "conference.internal.company.com")

        let noLocEvent = CalendarEventInfo(
            id: "noloc",
            title: "Sync",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            location: "   ",
            notes: nil
        )
        #expect(noLocEvent.cleanLocation == nil)
        #expect(noLocEvent.cleanNotes == nil)

        let complexNotes = "Intro<br>Line 1</p>Line 2</div>&quot;Quotes&#39; and &nbsp;spaces"
        let sanitized = CalendarEventInfo.sanitizeCalendarNotes(complexNotes)
        #expect(sanitized?.contains("Intro") == true)
        #expect(sanitized?.contains("\"Quotes' and  spaces") == true)

        let forwardedNote = """
        --Forwarded Message-----
        Cc: copy@example.com
        Microsoft Teams meeting
        Join Microsoft Teams
        Join with a video conferencing device
        Find your local number: tel:123
        https://meet.google.com/test-room
        Real Action Item: Deploy new backend
        """
        let sanitizedFwd = CalendarEventInfo.sanitizeCalendarNotes(forwardedNote)
        #expect(sanitizedFwd == "Real Action Item: Deploy new backend")
    }

    @Test("SystemCalendarService instance and fallback checks")
    func testSystemCalendarService() async throws {
        let service = SystemCalendarService.shared
        let status = service.authorizationStatus()
        #expect(status == .authorized || status == .notDetermined || status == .denied || status == .restricted)

        _ = await service.requestAccess()
        _ = try await service.fetchEvents(around: Date(), duration: 60)
        _ = try await service.searchEvents(query: "Exec", start: Date(), end: Date())
        _ = try await service.searchEvents(query: "", start: Date(), end: Date())
        _ = service.listCalendars()

        #if canImport(EventKit)
        let store = EKEventStore()
        let ek = EKEvent(eventStore: store)
        ek.title = "Direct EKEvent"
        ek.startDate = Date()
        ek.endDate = Date().addingTimeInterval(3600)
        ek.location = "Building 4"
        ek.notes = "Quarterly alignment"
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = "Executive Calendar"
        #if canImport(AppKit)
        cal.cgColor = NSColor.red.cgColor
        #endif
        ek.calendar = cal
        let converted = service.convertEvent(ek)
        #expect(converted.title == "Direct EKEvent")
        #expect(converted.calendarTitle == "Executive Calendar")
        #expect(converted.location == "Building 4")
        #expect(converted.notes == "Quarterly alignment")

        let ek2 = EKEvent(eventStore: store)
        ek2.title = "Direct EKEvent Prior"
        ek2.startDate = Date().addingTimeInterval(-1800)
        ek2.endDate = Date().addingTimeInterval(-600)

        let runnerService = SystemCalendarService(customStatus: { .authorized })
        runnerService.eventStoreRunner = { _ in [ek, ek2] }
        let runnerFetched = try await runnerService.fetchEvents(around: Date(), duration: 60)
        #expect(runnerFetched.count == 2)
        #expect(runnerFetched.first?.title == "Direct EKEvent Prior")
        let runnerSearched = try await runnerService.searchEvents(query: "Direct", start: Date().addingTimeInterval(-3600), end: Date().addingTimeInterval(7200))
        #expect(runnerSearched.count == 2)
        let runnerSearchedLoc = try await runnerService.searchEvents(query: "Building", start: Date(), end: Date().addingTimeInterval(7200))
        #expect(runnerSearchedLoc.count == 1)
        let runnerSearchedNotes = try await runnerService.searchEvents(query: "Quarterly", start: Date(), end: Date().addingTimeInterval(7200))
        #expect(runnerSearchedNotes.count == 1)
        let runnerEmptyQuery = try await runnerService.searchEvents(query: "", start: Date().addingTimeInterval(-3600), end: Date().addingTimeInterval(7200))
        #expect(runnerEmptyQuery.count == 2)

        let liveAuthorizedService = SystemCalendarService(customStatus: { .authorized })
        _ = try? await liveAuthorizedService.fetchEvents(around: Date(), duration: 60)
        _ = try? await liveAuthorizedService.searchEvents(query: "Test", start: Date(), end: Date().addingTimeInterval(3600))
        _ = try? await liveAuthorizedService.searchEvents(query: "", start: Date(), end: Date().addingTimeInterval(3600))
        #endif

        let mockEvent = CalendarEventInfo(
            id: "sys-1",
            title: "Executive Review",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600)
        )

        let customService = SystemCalendarService(
            customStatus: { .authorized },
            customRequestAccess: { true },
            customFetcher: { _, _ in [mockEvent] },
            customSearcher: { _, _, _ in [mockEvent] }
        )

        #expect(customService.authorizationStatus() == .authorized)
        let access = await customService.requestAccess()
        #expect(access)
        let fetched = try await customService.fetchEvents(around: Date(), duration: 60)
        #expect(fetched.count == 1)
        let searched = try await customService.searchEvents(query: "Exec", start: Date(), end: Date())
        #expect(searched.count == 1)

        let deniedService = SystemCalendarService(customStatus: { .denied })
        #expect(deniedService.authorizationStatus() == .denied)
        let deniedFetch = try await deniedService.fetchEvents(around: Date(), duration: 60)
        #expect(deniedFetch.isEmpty)
        let deniedSearch = try await deniedService.searchEvents(query: "Test", start: Date(), end: Date())
        #expect(deniedSearch.isEmpty)
        #expect(deniedService.listCalendars().isEmpty)

        let restrictedService = SystemCalendarService(customStatus: { .restricted })
        #expect(restrictedService.authorizationStatus() == .restricted)
        let notDeterminedService = SystemCalendarService(customStatus: { .notDetermined })
        #expect(notDeterminedService.authorizationStatus() == .notDetermined)
    }

    @Test("NoteCacheStore save, load, allNotes, delete, and clearAll")
    func testNoteCacheStore() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TestNoteCache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = NoteCacheStore(cacheDirectory: tempDir)

        let testNote = CachedRecordingNote(
            audioRelativePath: "250102_TEST/MIX.WAV",
            creationDate: Date(),
            duration: 120,
            title: "Roadmap Review",
            sessionType: "meeting",
            calendarEvent: CalendarEventInfo(
                id: "e1",
                title: "Roadmap Sync",
                startDate: Date(),
                endDate: Date().addingTimeInterval(3600)
            ),
            transcript: "Transcript content",
            markdownSummary: "Summary content",
            inboxExportURL: URL(fileURLWithPath: "/tmp/inbox/2026-10-30-roadmap-sync.md")
        )

        try store.save(testNote)

        let loaded = store.load(audioRelativePath: "250102_TEST/MIX.WAV")
        #expect(loaded != nil)
        #expect(loaded?.title == "Roadmap Review")
        #expect(loaded?.calendarEvent?.title == "Roadmap Sync")
        #expect(loaded?.transcript == "Transcript content")
        #expect(loaded?.markdownSummary == "Summary content")

        let all = store.allNotes()
        #expect(all.count == 1)

        store.delete(audioRelativePath: "250102_TEST/MIX.WAV")
        #expect(store.load(audioRelativePath: "250102_TEST/MIX.WAV") == nil)

        try store.save(testNote)
        store.clearAll()
        #expect(store.allNotes().isEmpty)

        // Test allNotes with non-existent cache directory
        let missingCache = NoteCacheStore(cacheDirectory: URL(fileURLWithPath: "/dev/null/notes"))
        #expect(missingCache.allNotes().isEmpty)
    }

    @Test("MarkdownExporter defaultFilename and frontmatter with calendar event")
    func testMarkdownExporterWithCalendar() throws {
        let tempInbox = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TestInbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempInbox) }

        let exporter = MarkdownExporter(destinationDirectory: tempInbox)
        let calEvent = CalendarEventInfo(
            id: "c1",
            title: "Q4 Strategy Kickoff",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            calendarTitle: "Executive",
            location: "Boardroom A",
            notes: "Discuss revenue goals and hiring plan.",
            attendees: ["Jane Doe"]
        )

        var recording = AudioRecordingFile(
            url: URL(fileURLWithPath: "/tmp/test.wav"),
            fileSize: 1024,
            creationDate: Date(),
            duration: 60,
            transcript: "We will focus on our key pillars.",
            markdownSummary: "Summary of Q4 goals."
        )

        // Without calendar event: uses typeSlug or noteTitle
        let defaultName = exporter.defaultFilename(for: recording, typeSlug: "meeting")
        #expect(defaultName.contains("meeting.md"))

        // With calendar event: event title dictates filename
        recording.calendarEvent = calEvent
        let calFilename = exporter.defaultFilename(for: recording, typeSlug: "meeting")
        #expect(calFilename.contains("q4-strategy-kickoff.md"))

        // Content includes calendar frontmatter
        let content = exporter.buildMarkdownContent(for: recording, typeSlug: "meeting", typeTitle: "Meeting")
        #expect(content.contains("calendar_event: \"Q4 Strategy Kickoff\""))
        #expect(content.contains("calendar_name: \"Executive\""))
        #expect(content.contains("calendar_location: \"Boardroom A\""))
        #expect(content.contains("Jane Doe"))
        #expect(content.contains("> **Meeting:** Q4 Strategy Kickoff"))
        #expect(content.contains("Discuss revenue goals"))

        // Export and rename in inbox
        let exportedURL = try exporter.exportMarkdown(for: recording, typeSlug: "meeting", typeTitle: "Meeting")
        #expect(FileManager.default.fileExists(atPath: exportedURL.path))

        let newCal = CalendarEventInfo(
            id: "c2",
            title: "Board of Directors Review",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600)
        )
        recording.calendarEvent = newCal
        let newFilename = exporter.defaultFilename(for: recording, typeSlug: "meeting")
        let newContent = exporter.buildMarkdownContent(for: recording, typeSlug: "meeting", typeTitle: "Meeting")

        let renamedURL = try exporter.renameExportedNote(
            for: recording,
            oldURL: exportedURL,
            newFilename: newFilename,
            newContent: newContent
        )
        #expect(FileManager.default.fileExists(atPath: renamedURL.path))
        #expect(!FileManager.default.fileExists(atPath: exportedURL.path))
        #expect(renamedURL.lastPathComponent.contains("board-of-directors-review.md"))

        // If file was moved out of inbox, renaming creates a fresh copy in inbox
        try FileManager.default.removeItem(at: renamedURL)
        let recreatedURL = try exporter.renameExportedNote(
            for: recording,
            oldURL: renamedURL,
            newFilename: "recreated.md",
            newContent: newContent
        )
        #expect(FileManager.default.fileExists(atPath: recreatedURL.path))
    }

    @Test("IngestionCoordinator calendar association and cache recovery")
    @MainActor
    func testCoordinatorCalendarAndCache() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("CoordTest-\(UUID().uuidString)")
        let cacheDir = tempDir.appendingPathComponent("Cache")
        let inboxDir = tempDir.appendingPathComponent("Inbox")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let monitor = SDCardMonitor(targetVolumeName: "P2_SD")
        let cacheStore = NoteCacheStore(cacheDirectory: cacheDir)
        let exporter = MarkdownExporter(destinationDirectory: inboxDir)
        let calEvent = CalendarEventInfo(
            id: "cal-sync",
            title: "Product Design Sync",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            calendarTitle: "Work"
        )
        let mockCal = MockCalendarService(mockEvents: [calEvent], mockStatus: .authorized)

        let coord = IngestionCoordinator(
            sdCardMonitor: monitor,
            audioScanner: AudioScanner(),
            transcriptionEngine: MockTranscriptionEngine(),
            summarizerEngine: AppleIntelligenceSummarizer(),
            markdownExporter: exporter,
            historyLedger: HistoryLedger(fileURL: tempDir.appendingPathComponent("history.json")),
            notificationService: SystemNotificationService.shared,
            noteCacheStore: cacheStore,
            calendarService: mockCal,
            audioLibraryDirectory: tempDir.appendingPathComponent("lib")
        )

        var sampleFile = AudioRecordingFile(
            url: URL(fileURLWithPath: "/tmp/sample.wav"),
            fileSize: 2048,
            creationDate: Date(),
            duration: 90,
            status: .completed,
            transcript: "Design meeting notes",
            markdownSummary: "Summary of design ideas"
        )

        // 1. Candidate calendar events lookup
        let candidates = try await coord.fetchCandidateCalendarEvents(for: sampleFile)
        #expect(candidates.count == 1)
        #expect(candidates.first?.title == "Product Design Sync")

        // Export sample note to inbox
        let exportURL = try exporter.exportMarkdown(for: sampleFile, typeSlug: "meeting", typeTitle: "Meeting")
        sampleFile.markdownPath = exportURL

        // 2. Associate calendar event: renames file in inbox and caches note
        let associated = try coord.associateCalendarEvent(for: sampleFile, event: calEvent)
        #expect(associated.calendarEvent?.title == "Product Design Sync")
        #expect(associated.noteTitle == "Product Design Sync")
        #expect(associated.markdownPath?.lastPathComponent.contains("product-design-sync.md") == true)
        #expect(FileManager.default.fileExists(atPath: associated.markdownPath!.path))

        // 3. User moves file out of inbox
        try FileManager.default.removeItem(at: associated.markdownPath!)
        #expect(!FileManager.default.fileExists(atPath: associated.markdownPath!.path))

        // 4. Verify cache still preserves the note
        let cached = cacheStore.load(audioRelativePath: sampleFile.displayName)
        #expect(cached != nil)
        #expect(cached?.title == "Product Design Sync")
        #expect(cached?.transcript == "Design meeting notes")
        #expect(cached?.markdownSummary == "Summary of design ideas")

        // 5. Unlink calendar event
        let unlinked = try coord.associateCalendarEvent(for: associated, event: nil)
        #expect(unlinked.calendarEvent == nil)

        // 6. Associate without prior markdownPath (unprocessed file)
        let unexported = AudioRecordingFile(
            url: URL(fileURLWithPath: "/tmp/fresh.wav"),
            fileSize: 100,
            creationDate: Date(),
            duration: 10
        )
        let freshAssociated = try coord.associateCalendarEvent(for: unexported, event: calEvent)
        #expect(freshAssociated.calendarEvent?.title == "Product Design Sync")

        // 7. Auto-classify with empty transcript falls back to activeSessionConfig
        let unclassified = AudioRecordingFile(
            url: URL(fileURLWithPath: "/tmp/notranscript.wav"),
            transcript: ""
        )
        let emptyClassified = try await coord.autoClassify(file: unclassified)
        #expect(emptyClassified.slug == coord.activeSessionConfig.slug)

        // 8. Coordinator setTranscriptionModel call
        coord.setTranscriptionModel("openai_whisper-tiny")

        // 9. Scan audio files recovers cached items even when inbox note is gone or not in ledger
        let mockVolume = tempDir.appendingPathComponent("MockVolume")
        let subFolder = mockVolume.appendingPathComponent("250102_TEST")
        try FileManager.default.createDirectory(at: subFolder, withIntermediateDirectories: true)
        let testAudio = subFolder.appendingPathComponent("MIX.WAV")
        try "fake audio data".write(to: testAudio, atomically: true, encoding: .utf8)

        // Case A: present in NoteCacheStore directly
        let archEvent = CalendarEventInfo(
            id: "arch-1",
            title: "Cached Architecture Review",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            calendarTitle: "Engineering"
        )
        let cachedA = CachedRecordingNote(
            audioRelativePath: "250102_TEST/MIX.WAV",
            creationDate: Date(),
            duration: 180,
            title: "Cached Architecture Review",
            sessionType: "technical",
            calendarEvent: archEvent,
            transcript: "Cached review transcript",
            markdownSummary: "Cached review summary"
        )
        try cacheStore.save(cachedA)

        let scannedFiles = await coord.scanAudioFiles(volumeURL: mockVolume)
        #expect(scannedFiles.count == 1)
        #expect(scannedFiles.first?.status == .completed)
        #expect(scannedFiles.first?.noteTitle == "Cached Architecture Review")
        #expect(scannedFiles.first?.transcript == "Cached review transcript")

        // Case B: present in HistoryLedger but note was removed from inbox -> recovers from cache
        let testAudio2 = subFolder.appendingPathComponent("MIX2.WAV")
        try "fake audio 2".write(to: testAudio2, atomically: true, encoding: .utf8)
        let ghostInboxPath = inboxDir.appendingPathComponent("ghost.md")
        let rec2 = AudioRecordingFile(url: testAudio2, status: .completed)
        try coord.historyLedger.markProcessed(file: rec2, exportURL: ghostInboxPath)

        let cachedB = CachedRecordingNote(
            audioRelativePath: "250102_TEST/MIX2.WAV",
            creationDate: Date(),
            duration: 240,
            title: "Recovered Strategy Session",
            sessionType: "strategy",
            transcript: "Recovered transcript content",
            markdownSummary: "Recovered summary content"
        )
        try cacheStore.save(cachedB)

        let scannedAgain = await coord.scanAudioFiles(volumeURL: mockVolume)
        let matched2 = scannedAgain.first(where: { $0.url.lastPathComponent == "MIX2.WAV" })
        #expect(matched2?.status == .completed)
        #expect(matched2?.noteTitle == "Recovered Strategy Session")
        #expect(matched2?.transcript == "Recovered transcript content")

        // Case C: Note present in ledger AND in inbox with cached calendar event -> preserves calendarEvent on scan
        let testAudio3 = subFolder.appendingPathComponent("MIX3.WAV")
        try "fake audio 3".write(to: testAudio3, atomically: true, encoding: .utf8)
        let retroEvent = CalendarEventInfo(
            id: "retro-3",
            title: "Sprint Retrospective",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            calendarTitle: "Agile"
        )
        var rec3 = AudioRecordingFile(
            url: testAudio3,
            fileSize: 1024,
            creationDate: Date(),
            duration: 300,
            status: .completed,
            calendarEvent: retroEvent,
            transcript: "Existing transcript",
            markdownSummary: "Existing summary"
        )
        let note3URL = try exporter.exportMarkdown(for: rec3, typeSlug: "meeting", typeTitle: "Meeting")
        rec3.markdownPath = note3URL
        try coord.historyLedger.markProcessed(file: rec3, exportURL: note3URL)
        let cachedC = CachedRecordingNote(
            audioRelativePath: "250102_TEST/MIX3.WAV",
            creationDate: Date(),
            duration: 300,
            title: "Sprint Retrospective",
            sessionType: "meeting",
            calendarEvent: retroEvent,
            transcript: "Existing transcript",
            markdownSummary: "Existing summary",
            inboxExportURL: note3URL
        )
        try cacheStore.save(cachedC)

        let scannedAgain3 = await coord.scanAudioFiles(volumeURL: mockVolume)
        let matched3 = scannedAgain3.first(where: { $0.url.lastPathComponent == "MIX3.WAV" })
        #expect(matched3?.status == .completed)
        #expect(matched3?.calendarEvent?.title == "Sprint Retrospective")
        #expect(matched3?.noteTitle == "Sprint Retrospective")
    }

    @Test("Discovered calendars listing and updateNoteTitle workflow")
    @MainActor
    func testListCalendarsAndNoteTitleUpdate() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mockService = MockCalendarService(mockStatus: .authorized)
        let cals = mockService.listCalendars()
        #expect(cals.count == 2)
        #expect(cals.first?.title == "Work")

        let deniedService = MockCalendarService(mockStatus: .denied)
        #expect(deniedService.listCalendars().isEmpty)

        let info = DiscoveredCalendarInfo(id: "test", title: "Planning", colorHex: "#123456", sourceTitle: "Exchange")
        #expect(info.id == "test")
        #expect(info.title == "Planning")
        #expect(info.colorHex == "#123456")
        #expect(info.sourceTitle == "Exchange")

        let sysService = SystemCalendarService.shared
        _ = sysService.listCalendars()
        _ = sysService.authorizationStatus()
        _ = await sysService.requestAccess()

        let authSysService = SystemCalendarService(customStatus: { .authorized })
        _ = authSysService.listCalendars()

        #if canImport(EventKit)
        let store = EKEventStore()
        let ek = EKEvent(eventStore: store)
        ek.title = "Direct EK Test"
        ek.startDate = Date()
        ek.endDate = Date().addingTimeInterval(1800)
        let converted = SystemCalendarService.shared.convertEvent(ek)
        #expect(converted.title == "Direct EK Test")
        #endif

        let deniedSys = SystemCalendarService(customStatus: { .denied })
        #expect(deniedSys.listCalendars().isEmpty)
        let deniedFetcher = try await deniedSys.fetchEvents(around: Date(), duration: 60)
        #expect(deniedFetcher.isEmpty)
        let deniedSearcher = try await deniedSys.searchEvents(query: "Test", start: Date(), end: Date())
        #expect(deniedSearcher.isEmpty)
        let restrSys = SystemCalendarService(customStatus: { .restricted })
        #expect(restrSys.authorizationStatus() == .restricted)
        let notDetSys = SystemCalendarService(customStatus: { .notDetermined })
        #expect(notDetSys.authorizationStatus() == .notDetermined)

        // Coordinator note title updates
        let inboxDir = tempDir.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        let cacheStore = NoteCacheStore(cacheDirectory: tempDir.appendingPathComponent("Cache"))
        let exporter = MarkdownExporter(destinationDirectory: inboxDir)
        let ledger = HistoryLedger(fileURL: tempDir.appendingPathComponent("history.json"))
        let monitor = SDCardMonitor(targetVolumeName: "P2_SD")

        let coord = IngestionCoordinator(
            sdCardMonitor: monitor,
            audioScanner: AudioScanner(),
            transcriptionEngine: MockTranscriptionEngine(),
            summarizerEngine: AppleIntelligenceSummarizer(),
            markdownExporter: exporter,
            historyLedger: ledger,
            notificationService: SystemNotificationService.shared,
            noteCacheStore: cacheStore,
            calendarService: mockService,
            audioLibraryDirectory: tempDir.appendingPathComponent("lib")
        )

        let sampleAudioURL = tempDir.appendingPathComponent("sample.wav")
        try "audio bytes".write(to: sampleAudioURL, atomically: true, encoding: .utf8)

        var file = AudioRecordingFile(
            url: sampleAudioURL,
            fileSize: 1024,
            creationDate: Date(),
            duration: 120,
            status: .completed,
            transcript: "Transcript sample",
            markdownSummary: "Summary sample"
        )
        let initialExport = try exporter.exportMarkdown(for: file, typeSlug: "meeting", typeTitle: "Meeting")
        file.markdownPath = initialExport
        try ledger.markProcessed(file: file, exportURL: initialExport)

        // Rename via coordinator
        let updated = try coord.updateNoteTitle(for: file, newTitle: "Keynote Architecture Discussion")
        #expect(updated.noteTitle == "Keynote Architecture Discussion")
        #expect(updated.markdownPath != nil)
        #expect(FileManager.default.fileExists(atPath: updated.markdownPath!.path))

        // Check cache store
        let cached = cacheStore.load(audioRelativePath: file.displayName)
        #expect(cached?.title == "Keynote Architecture Discussion")

        // Clear title with empty string
        let cleared = try coord.updateNoteTitle(for: updated, newTitle: "   ")
        #expect(cleared.noteTitle == nil)

        // Delete recording through coordinator
        monitor.updateStatus(.inserted(volumeURL: tempDir, freeBytes: 10000, totalBytes: 20000))
        try coord.deleteRecording(cleared)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test("SystemCalendarService custom hooks execution")
    func testSystemCalendarServiceCustomHooks() async throws {
        let testFetchEv = CalendarEventInfo(id: "ev-fetch", title: "Fetch Test", startDate: Date(), endDate: Date())
        let fetchSys = SystemCalendarService(
            customStatus: { .authorized },
            customRequestAccess: { true },
            customFetcher: { _, _ in [testFetchEv] },
            customSearcher: { query, _, _ in query == "FindMe" ? [testFetchEv] : [] }
        )
        let fetched = try await fetchSys.fetchEvents(around: Date(), duration: 100)
        #expect(fetched.count == 1)
        let searched = try await fetchSys.searchEvents(query: "FindMe", start: Date(), end: Date())
        #expect(searched.count == 1)
        let emptySearch = try await fetchSys.searchEvents(query: "NotFound", start: Date(), end: Date())
        #expect(emptySearch.isEmpty)
        let req = await fetchSys.requestAccess()
        #expect(req)

        // Denied access check
        let deniedService = SystemCalendarService(
            customStatus: { .denied },
            customRequestAccess: { false }
        )
        let dReq = await deniedService.requestAccess()
        #expect(!dReq)
        #expect(deniedService.authorizationStatus() == .denied)
    }
}
