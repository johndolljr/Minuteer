import Testing
import Foundation
@testable import MinuteerCore

@Suite("Summarizer & Safe Markdown Exporter Tests")
struct SummarizerAndExporterTests {

    @Test("Prompt templates generate appropriate instructions")
    func testPromptTemplates() {
        let meetingTemplate = SummaryPromptTemplate.defaultMeeting
        #expect(meetingTemplate.sessionType == .meeting)
        #expect(meetingTemplate.systemInstructions.localizedCaseInsensitiveContains("key decisions"))
        #expect(meetingTemplate.systemInstructions.localizedCaseInsensitiveContains("action items"))

        let therapyTemplate = SummaryPromptTemplate.defaultTherapy
        #expect(therapyTemplate.sessionType == .therapy)
        #expect(therapyTemplate.systemInstructions.localizedCaseInsensitiveContains("breakthrough moments"))
        #expect(therapyTemplate.systemInstructions.localizedCaseInsensitiveContains("core themes"))

        let customTemplate = SummaryPromptTemplate(sessionType: .custom, systemInstructions: "Provide a 3-bullet executive summary.")
        #expect(customTemplate.systemInstructions == "Provide a 3-bullet executive summary.")

        #expect(SessionType.meeting.title == "Meeting")
        #expect(SessionType.therapy.title == "Therapy Session")
        #expect(SessionType.custom.title == "Custom")
        #expect(SessionType.allCases.count == 3)

        let prompt = meetingTemplate.renderPrompt(transcript: "Alice: We agreed to launch next week.")
        #expect(prompt.contains("Alice: We agreed to launch next week."))
        #expect(prompt.contains(meetingTemplate.systemInstructions))
    }

    @Test("AppleIntelligenceSummarizer with mock runner")
    func testAppleIntelligenceSummarizer() async throws {
        let summarizer = AppleIntelligenceSummarizer { prompt in
            return "## Executive Summary\n- Decision reached."
        }
        #expect(summarizer.name.contains("Apple Intelligence"))

        let result = try await summarizer.summarize(transcript: "Test audio text", template: .defaultMeeting)
        #expect(result.contains("Executive Summary"))
        #expect(result.contains("Decision reached."))
    }

    @Test("AppleIntelligenceSummarizer chunking logic splits long transcripts")
    func testChunkTranscript() {
        let summarizer = AppleIntelligenceSummarizer()
        let emptyChunk = summarizer.chunkTranscript("")
        #expect(emptyChunk.isEmpty)

        let shortText = "First line.\nSecond line."
        let singleChunk = summarizer.chunkTranscript(shortText, maxChunkSize: 100)
        #expect(singleChunk.count == 1)

        let longText = (1...20).map { "Paragraph \($0): This is a substantial block of text discussing important points." }.joined(separator: "\n")
        let chunks = summarizer.chunkTranscript(longText, maxChunkSize: 200)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(!chunk.isEmpty)
        }

        // Test single continuous paragraph exceeding maxChunkSize (word-splitting path)
        let giantSingleLine = (1...30).map { "Word\($0) discusses various engineering and architecture trade-offs." }.joined(separator: " ")
        let wordSplitChunks = summarizer.chunkTranscript(giantSingleLine, maxChunkSize: 120)
        #expect(wordSplitChunks.count > 1)
        for sub in wordSplitChunks {
            #expect(sub.count <= 120)
        }
    }

    @Test("AppleIntelligenceSummarizer chunked execution via session runner")
    func testChunkedSummarizerExecution() async throws {
        let summarizer = AppleIntelligenceSummarizer(sessionRunner: { prompt in
            return "Summary snippet for: \(prompt.prefix(20))"
        })
        let longTranscript = (1...150).map { "Speaker \($0): Discussed quarterly metrics and architectural designs in detail." }.joined(separator: "\n")
        let summary = try await summarizer.summarize(transcript: longTranscript, template: .defaultMeeting)
        #expect(!summary.isEmpty)
        #expect(summary.contains("Summary snippet"))
    }

    @Test("MarkdownExporter exports note with frontmatter and transcript")
    func testMarkdownExporterSuccess() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let exporter = MarkdownExporter(destinationDirectory: tempDir)
        let recording = AudioRecordingFile(
            url: URL(fileURLWithPath: "/Volumes/P2_SD/250102_184844/MIX.WAV"),
            fileSize: 10_000_000,
            creationDate: Date(timeIntervalSince1970: 1735843724),
            duration: 180,
            transcript: "John: Meeting started.\nAlice: Status looks great.",
            markdownSummary: "## Summary\nStatus is great."
        )

        let writtenURL = try exporter.exportMarkdown(
            for: recording,
            sessionType: .meeting,
            allowOverwrite: false
        )

        #expect(FileManager.default.fileExists(atPath: writtenURL.path))
        let content = try String(contentsOf: writtenURL, encoding: .utf8)
        #expect(content.contains("type: meeting"))
        #expect(content.contains("source_file: \"250102_184844/MIX.WAV\""))
        #expect(content.contains("## Summary"))
        #expect(content.contains("John: Meeting started."))
    }

    @Test("MarkdownExporter refuses to overwrite without user permission")
    func testMarkdownExporterRefusesOverwrite() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let exporter = MarkdownExporter(destinationDirectory: tempDir)
        let recording = AudioRecordingFile(
            url: URL(fileURLWithPath: "/Volumes/P2_SD/250102_184844/MIX.WAV"),
            creationDate: Date(timeIntervalSince1970: 1735843724),
            transcript: "Transcript",
            markdownSummary: "Summary v1"
        )

        // First export succeeds
        let firstURL = try exporter.exportMarkdown(for: recording, sessionType: .meeting, allowOverwrite: false)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))

        // Second export without permission must throw OverwritePermissionRequired
        #expect(throws: MarkdownExportError.self) {
            _ = try exporter.exportMarkdown(for: recording, sessionType: .meeting, allowOverwrite: false)
        }

        // Export with explicit overwrite permission succeeds
        let updatedRecording = AudioRecordingFile(
            url: recording.url,
            creationDate: recording.creationDate,
            transcript: "Transcript",
            markdownSummary: "Summary v2 (Updated)"
        )
        let overwrittenURL = try exporter.exportMarkdown(for: updatedRecording, sessionType: .meeting, allowOverwrite: true)
        let newContent = try String(contentsOf: overwrittenURL, encoding: .utf8)
        #expect(newContent.contains("Summary v2 (Updated)"))

        let defaultFn = exporter.defaultFilename(for: recording, sessionType: .meeting)
        #expect(!defaultFn.isEmpty)
        let firstNonColliding = exporter.generateNonCollidingURL(for: recording, sessionType: .meeting)
        #expect(!firstNonColliding.path.isEmpty)

        // Test non-colliding URL generation
        let nonColliding = exporter.generateNonCollidingURL(for: updatedRecording, sessionType: .meeting)
        #expect(nonColliding.path != overwrittenURL.path)
        #expect(nonColliding.lastPathComponent.contains("(1)"))
    }

    @Test("AppleIntelligenceSummarizer live availability and execution check")
    func testLiveSummarizerAvailability() async throws {
        let liveSummarizer = AppleIntelligenceSummarizer()
        let available = liveSummarizer.isAvailable
        #expect(liveSummarizer.name.contains("Apple Intelligence"))
        if available {
            do {
                let res = try await liveSummarizer.summarize(
                    transcript: "Test meeting. Today we agreed on the architecture.",
                    template: .defaultMeeting
                )
                #expect(!res.isEmpty)
            } catch {
                // If the model is not downloaded or active, it throws an error which is acceptable
                #expect(error.localizedDescription.count > 0)
            }
        }
    }

    @Test("MarkdownExportError descriptions")
    func testMarkdownExportErrorDescriptions() {
        let err1 = MarkdownExportError.fileExists(URL(fileURLWithPath: "/tmp/test.md"))
        let err2 = MarkdownExportError.missingContent
        let err3 = MarkdownExportError.destinationNotWritable(URL(fileURLWithPath: "/tmp/inaccessible"))

        #expect(err1.errorDescription?.contains("File already exists") == true)
        #expect(err2.errorDescription?.contains("Cannot export empty") == true)
        #expect(err3.errorDescription?.contains("not writable") == true)
    }

    @Test("MarkdownExporter default init and fallback values")
    func testMarkdownExporterDefaults() {
        let exporter = MarkdownExporter()
        #expect(exporter.destinationDirectory == MarkdownExporter.defaultInboxDirectory)

        let recordingWithoutSummary = AudioRecordingFile(
            url: URL(fileURLWithPath: "/Volumes/P2_SD/test.wav"),
            creationDate: Date(timeIntervalSince1970: 1735843724),
            transcript: nil,
            markdownSummary: nil
        )
        let md = exporter.buildMarkdownContent(for: recordingWithoutSummary, sessionType: .therapy)
        #expect(md.contains("No summary generated."))
        #expect(md.contains("No transcript available."))
    }

    @Test("MarkdownExporter parseMarkdownNote extraction")
    func testParseMarkdownNote() {
        let sampleNote = """
        ---
        title: "Meeting - 2026-10-30"
        date: 2026-10-30T10:00:00Z
        type: meeting
        ---

        # Meeting - 2026-10-30

        ## Executive Summary
        Discussed project roadmap and release goals.

        ---

        <details>
        <summary>Raw Transcript</summary>

        Hello everyone, let's start the meeting.

        </details>
        """

        let parsed = MarkdownExporter.parseMarkdownNote(sampleNote)
        #expect(parsed.summary?.contains("Discussed project roadmap") == true)
        #expect(parsed.transcript?.contains("Hello everyone") == true)

        let simpleNote = "Just simple text without headers"
        let parsedSimple = MarkdownExporter.parseMarkdownNote(simpleNote)
        #expect(parsedSimple.summary == "Just simple text without headers")
        #expect(parsedSimple.transcript == nil)

        let noteWithMeetingCallout = """
        ---
        title: "Sprint Scrum"
        date: 2026-10-30T10:00:00Z
        type: meeting
        ---

        # Sprint Scrum

        > **Meeting:** Sprint Scrum (9:00 AM – 9:30 AM)
        > **Location:** Zoom Meeting
        > **Attendees:** Alice, Bob

        ## Real Summary
        Discussed velocity and blockers.
        """
        let parsedCallout = MarkdownExporter.parseMarkdownNote(noteWithMeetingCallout)
        #expect(parsedCallout.summary?.contains("Discussed velocity and blockers.") == true)
        #expect(parsedCallout.summary?.contains("> **Meeting:**") == false)
    }

    @Test("AppleIntelligenceSummarizer chunking error recovery and fallback")
    func testSummarizerChunkingRecovery() async throws {
        final class CounterBox: @unchecked Sendable {
            var callCount = 0
        }
        let box = CounterBox()
        let summarizer = AppleIntelligenceSummarizer(sessionRunner: { prompt in
            box.callCount += 1
            if box.callCount == 1 && prompt.contains("Part 1") {
                throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Context window exceeded"])
            }
            return "Recovered summary snippet"
        })

        let longTranscript = (1...120).map { "Section \($0): Discussed roadmap milestones and release schedules in depth." }.joined(separator: "\n")
        let summary = try await summarizer.summarize(transcript: longTranscript, template: .defaultMeeting)
        #expect(!summary.isEmpty)
        #expect(summary.contains("Recovered summary snippet"))

        // Test diarizeTranscript with known speakers
        let known = [SpeakerProfile(name: "Alice", aliases: ["Ali"], contextNotes: "Lead")]
        let diarized = try await summarizer.diarizeTranscript(transcript: "Hello team.", knownSpeakers: known)
        #expect(!diarized.isEmpty)
    }

    @Test("MarkdownExporter updates transcript in existing note")
    func testUpdateTranscriptInNote() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let exporter = MarkdownExporter(destinationDirectory: tempDir)
        let noteURL = tempDir.appendingPathComponent("note.md")
        let initialContent = """
        ---
        title: "Test Note"
        ---
        # Test Note
        Summary content.

        ---

        <details>
        <summary>Raw Transcript</summary>

        Original transcript text.

        </details>
        """
        try initialContent.write(to: noteURL, atomically: true, encoding: .utf8)

        try exporter.updateTranscriptInNote(at: noteURL, newTranscript: "Edited transcript text with corrections.")
        let updated = try String(contentsOf: noteURL, encoding: .utf8)
        #expect(updated.contains("Edited transcript text with corrections."))
        #expect(updated.contains("Summary content."))
        #expect(!updated.contains("Original transcript text."))

        // Test updating header-style note
        let headerNoteURL = tempDir.appendingPathComponent("header_note.md")
        try "# Title\n\nSummary\n\n## Full Audio Transcript\nOld transcript".write(to: headerNoteURL, atomically: true, encoding: .utf8)
        try exporter.updateTranscriptInNote(at: headerNoteURL, newTranscript: "New header transcript")
        let updatedHeader = try String(contentsOf: headerNoteURL, encoding: .utf8)
        #expect(updatedHeader.contains("New header transcript"))

        // Test updating note without transcript section (append path)
        let plainNoteURL = tempDir.appendingPathComponent("plain_note.md")
        try "# Title\n\nPlain summary only".write(to: plainNoteURL, atomically: true, encoding: .utf8)
        try exporter.updateTranscriptInNote(at: plainNoteURL, newTranscript: "Appended transcript")
        let updatedPlain = try String(contentsOf: plainNoteURL, encoding: .utf8)
        #expect(updatedPlain.contains("Appended transcript"))

        // Nonexistent note does not crash
        let missingURL = tempDir.appendingPathComponent("missing.md")
        try exporter.updateTranscriptInNote(at: missingURL, newTranscript: "No op")
    }

    @Test("TranscriptTurn parsing, wall-of-text splitting, and speaker renaming")
    func testTranscriptTurn() {
        let wallOfText = "Hello everyone, how are you doing today? We are reviewing the architecture requirements for the new release. Are there any objections? No, everything looks great to proceed."
        let turns = TranscriptTurn.splitWallOfText(wallOfText)
        #expect(turns.count >= 2)
        #expect(turns[0].speaker == "Speaker 1")
        #expect(turns[1].speaker == "Speaker 2")

        let markdownTranscript = """
        **Speaker 1**: Good morning.
        **Speaker 2**: Good morning, let's start.
        """
        let parsed = TranscriptTurn.parseTurns(from: markdownTranscript)
        #expect(parsed.count == 2)
        #expect(parsed[0].speaker == "Speaker 1")
        #expect(parsed[1].speaker == "Speaker 2")

        let renamed = TranscriptTurn.renameSpeaker(in: parsed, from: "Speaker 1", to: "John")
        #expect(renamed[0].speaker == "John")
        #expect(renamed[1].speaker == "Speaker 2")

        let formatted = TranscriptTurn.formatTranscript(turns: renamed)
        #expect(formatted.contains("**John**: Good morning."))
        #expect(formatted.contains("**Speaker 2**: Good morning, let's start."))

        // Edge cases
        #expect(TranscriptTurn.parseTurns(from: "").isEmpty)
        #expect(TranscriptTurn.splitWallOfText("").isEmpty)

        let multiline = "**Speaker 1**: First line\nSecond continuation line\n**Speaker 2**: Reply"
        let parsedMulti = TranscriptTurn.parseTurns(from: multiline)
        #expect(parsedMulti.count == 2)
        #expect(parsedMulti[0].text.contains("Second continuation line"))

        let timestampedTranscript = """
        [00:15] **Speaker 1**: Hello from fifteen seconds.
        [01:02:05] **Speaker 2**: Hello from over an hour.
        """
        let parsedTimestamped = TranscriptTurn.parseTurns(from: timestampedTranscript)
        #expect(parsedTimestamped.count == 2)
        #expect(parsedTimestamped[0].timestamp == "00:15")
        #expect(parsedTimestamped[0].timestampSeconds == 15.0)
        #expect(parsedTimestamped[1].timestamp == "01:02:05")
        #expect(parsedTimestamped[1].timestampSeconds == 3725.0)

        #expect(TranscriptTurn.formatSeconds(15.2) == "00:15")
        #expect(TranscriptTurn.formatSeconds(3725.0) == "01:02:05")

        // Test merging turn with previous preserves timestamp and concatenates text
        let preMergeTurns = [
            TranscriptTurn(id: 0, speaker: "Ravi", timestamp: "00:05", text: "First thought."),
            TranscriptTurn(id: 1, speaker: "Ravi", timestamp: "00:12", text: "Continuation thought."),
            TranscriptTurn(id: 2, speaker: "John", timestamp: "00:25", text: "Reply.")
        ]
        let postMerge = TranscriptTurn.mergeTurnWithPrevious(in: preMergeTurns, turnIndex: 1)
        #expect(postMerge.count == 2)
        #expect(postMerge[0].id == 0)
        #expect(postMerge[0].speaker == "Ravi")
        #expect(postMerge[0].timestamp == "00:05")
        #expect(postMerge[0].text == "First thought. Continuation thought.")
        #expect(postMerge[1].id == 1)
        #expect(postMerge[1].speaker == "John")
        #expect(postMerge[1].timestamp == "00:25")

        // Edge case: invalid turnIndex doesn't mutate
        #expect(TranscriptTurn.mergeTurnWithPrevious(in: preMergeTurns, turnIndex: 0).count == 3)
        #expect(TranscriptTurn.mergeTurnWithPrevious(in: preMergeTurns, turnIndex: 99).count == 3)

        // Test stripping special tokens
        let rawWithTokens = "<|startoftranscript|><|en|><|transcribe|><|0.00|> Hello world.<|7.00|>"
        #expect(TranscriptTurn.stripSpecialTokens(rawWithTokens) == "Hello world.")

        // Test parsing raw transcript containing tokens and timestamps into dialogue turns
        let tokenizedTranscript = """
        [00:00] <|startoftranscript|><|en|><|transcribe|><|0.00|> Hello.<|7.00|>
        [00:07] Can you tell all the transmit?<|2.00|>
        [00:10] Thank you.
        """
        let parsedTokens = TranscriptTurn.parseTurns(from: tokenizedTranscript)
        #expect(parsedTokens.count >= 2)
        #expect(parsedTokens[0].speaker == "Speaker 1")
        #expect(parsedTokens[0].text.contains("Hello."))
        #expect(!parsedTokens[0].text.contains("<|"))
        #expect(parsedTokens[1].speaker == "Speaker 2")
        #expect(parsedTokens[1].text.contains("Thank you"))
        #expect(!parsedTokens[1].text.contains("<|"))

        // Test timed segments formatting
        let segments: [(start: Float, text: String)] = [
            (0.0, "Segment zero."),
            (15.5, ""), // Should be ignored
            (32.0, "Segment thirty two.")
        ]
        let formattedSegments = TranscriptTurn.formatTimedSegments(segments)
        #expect(formattedSegments.contains("[00:00] Segment zero."))
        #expect(formattedSegments.contains("[00:32] Segment thirty two."))
        #expect(TranscriptTurn.formatTimedSegments([]).isEmpty)

        // Non-bold speaker format e.g. "Alice: Hello" and preamble lines
        let colonTranscript = """
        Preamble line before speakers
        Alice: Hello there.
        Bob: Hi Alice.
        """
        let parsedColon = TranscriptTurn.parseTurns(from: colonTranscript)
        #expect(parsedColon.count == 3)
        #expect(parsedColon[0].speaker == "Speaker 1")
        #expect(parsedColon[0].text.contains("Preamble line"))
        #expect(parsedColon[1].speaker == "Alice")
        #expect(parsedColon[1].text.contains("Hello there"))
        #expect(parsedColon[2].speaker == "Bob")
        #expect(parsedColon[2].text.contains("Hi Alice"))

        // splitWallOfText with timestamp prefixes
        let timestampedWall = "[00:05] What time is it? [00:12] It is noon now."
        let splitWithTS = TranscriptTurn.splitWallOfText(timestampedWall)
        #expect(splitWithTS.count == 2)
        #expect(splitWithTS[0].timestamp == "00:05")

        // Format transcript with mixed timestamps
        let mixedTurns = [
            TranscriptTurn(id: 0, speaker: "Alice", timestamp: "00:05", text: "First"),
            TranscriptTurn(id: 1, speaker: "Bob", timestamp: nil, text: "Second")
        ]
        let mixedFormatted = TranscriptTurn.formatTranscript(turns: mixedTurns)
        #expect(mixedFormatted.contains("[00:05] **Alice**: First"))
        #expect(mixedFormatted.contains("**Bob**: Second"))

        let customTurn = TranscriptTurn(id: 42, speaker: "Custom", timestamp: "02:30", text: "Text")
        #expect(customTurn.id == 42)
        #expect(customTurn.speaker == "Custom")
        #expect(customTurn.timestamp == "02:30")
        #expect(customTurn.timestampSeconds == 150.0)

        let invalidTurn = TranscriptTurn(id: 43, speaker: "Custom", timestamp: "invalid", text: "Text")
        #expect(invalidTurn.timestampSeconds == nil)
    }

    @Test("TranscriptTurn sentenceSplitPoints extracts sentence boundaries")
    func testSentenceSplitPoints() {
        let text = "Actually, it's in Kth was going to work on that. But you know, no, no, asking to not work on that. Next item."
        let points = TranscriptTurn.sentenceSplitPoints(in: text)
        #expect(points.count >= 2)
        #expect(points[0].sentence.contains("Actually, it's in Kth"))
        #expect(points[0].endOffset > 0)
        #expect(points[1].sentence.contains("But you know"))

        let emptyPoints = TranscriptTurn.sentenceSplitPoints(in: "")
        #expect(emptyPoints.isEmpty)
    }

    @Test("TranscriptTurn splitTurn splits turn at character offset and re-indexes")
    func testSplitTurnByOffset() {
        let text = "Actually, it's in Kth was going to work on that. But you know, no, asking to not work on that."
        let turns = [
            TranscriptTurn(id: 0, speaker: "Speaker 1", timestamp: "00:00", text: "Intro."),
            TranscriptTurn(id: 1, speaker: "Ravi", timestamp: "01:11", text: text),
            TranscriptTurn(id: 2, speaker: "Speaker 1", timestamp: "02:00", text: "Conclusion.")
        ]

        let points = TranscriptTurn.sentenceSplitPoints(in: text)
        #expect(!points.isEmpty)
        let splitOffset = points[0].endOffset

        let updated = TranscriptTurn.splitTurn(
            in: turns,
            turnIndex: 1,
            splitCharacterOffset: splitOffset,
            newSpeaker: "Sanket"
        )

        #expect(updated.count == 4)
        #expect(updated[0].id == 0)
        #expect(updated[0].speaker == "Speaker 1")
        #expect(updated[1].id == 1)
        #expect(updated[1].speaker == "Ravi")
        #expect(updated[1].timestamp == "01:11")
        #expect(updated[1].text == "Actually, it's in Kth was going to work on that.")

        #expect(updated[2].id == 2)
        #expect(updated[2].speaker == "Sanket")
        #expect(updated[2].timestamp != nil)
        #expect(updated[2].text == "But you know, no, asking to not work on that.")

        #expect(updated[3].id == 3)
        #expect(updated[3].speaker == "Speaker 1")
        #expect(updated[3].timestamp == "02:00")
        #expect(updated[3].text == "Conclusion.")
    }

    @Test("TranscriptTurn splitTurn with explicit parts and edge cases")
    func testSplitTurnExplicitParts() {
        let turns = [
            TranscriptTurn(id: 0, speaker: "Ravi", timestamp: "01:11", text: "First part. Second part.")
        ]

        let updated = TranscriptTurn.splitTurn(
            in: turns,
            turnIndex: 0,
            part1Text: "First part.",
            part2Text: "Second part.",
            newSpeaker: "Alice",
            splitTimestamp: "01:25"
        )

        #expect(updated.count == 2)
        #expect(updated[0].id == 0)
        #expect(updated[0].speaker == "Ravi")
        #expect(updated[0].text == "First part.")
        #expect(updated[1].id == 1)
        #expect(updated[1].speaker == "Alice")
        #expect(updated[1].timestamp == "01:25")
        #expect(updated[1].text == "Second part.")

        // Edge case: invalid turnIndex
        let invalidIndex = TranscriptTurn.splitTurn(in: turns, turnIndex: 99, splitCharacterOffset: 5)
        #expect(invalidIndex.count == turns.count)

        // Edge case: invalid offsets
        let negOffset = TranscriptTurn.splitTurn(in: turns, turnIndex: 0, splitCharacterOffset: -1)
        #expect(negOffset.count == turns.count)

        let outOfBounds = TranscriptTurn.splitTurn(in: turns, turnIndex: 0, splitCharacterOffset: 9999)
        #expect(outOfBounds.count == turns.count)

        // Edge case: empty parts
        let emptyPart = TranscriptTurn.splitTurn(in: turns, turnIndex: 0, part1Text: "", part2Text: "Second")
        #expect(emptyPart.count == turns.count)

        // Default fallback speaker when newSpeaker is nil
        let fallbackSplit = TranscriptTurn.splitTurn(in: turns, turnIndex: 0, part1Text: "Part 1", part2Text: "Part 2")
        #expect(fallbackSplit.count == 2)
        #expect(fallbackSplit[1].speaker == "Speaker 1" || fallbackSplit[1].speaker == "Speaker 2")
    }

    @Test("AppleIntelligenceSummarizer generateTitle creates descriptive title")
    func testGenerateTitle() async throws {
        let summarizer = AppleIntelligenceSummarizer(sessionRunner: { prompt in
            return "Quarterly Architecture & Release Review"
        })
        let title = try await summarizer.generateTitle(
            transcript: "Discussion about architecture roadmap",
            summary: "Discussed release planning and system architecture."
        )
        #expect(title == "Quarterly Architecture & Release Review")

        // Test prefix stripping
        let prefixSummarizer = AppleIntelligenceSummarizer(sessionRunner: { _ in
            return "Title: # Engineering Roadmap 2026"
        })
        let strippedTitle = try await prefixSummarizer.generateTitle(transcript: "text", summary: "text")
        #expect(strippedTitle == "Engineering Roadmap 2026")

        // Test fallback on empty content
        let defaultSummarizer = AppleIntelligenceSummarizer()
        let emptyTitle = try await defaultSummarizer.generateTitle(transcript: "", summary: nil)
        #expect(emptyTitle == "Audio Recording Note")
    }

    @Test("Autonomous classification and confidence scoring in AppleIntelligenceSummarizer")
    func testAutonomousClassification() async throws {
        // High confidence therapy match (>80%)
        let therapySummarizer = AppleIntelligenceSummarizer(sessionRunner: { prompt in
            return """
            {
              "sessionType": "Therapy",
              "confidence": 94,
              "reasoning": "Contains emotional processing, coping mechanisms, and breakthrough moments."
            }
            """
        })
        let therapyResult = try await therapySummarizer.classifySessionTypeWithConfidence(
            transcript: "I've been feeling anxious lately and worked through breathing exercises.",
            availableTypes: SessionTypeConfig.defaultList
        )
        #expect(therapyResult.config.slug == "therapy")
        #expect(therapyResult.confidence == 0.94)
        #expect(therapyResult.explanation?.contains("emotional") == true)

        // Low confidence (<80%) fallback regex match
        let lowConfSummarizer = AppleIntelligenceSummarizer(sessionRunner: { _ in
            return "Maybe this is a meeting with \"confidence\": 60"
        })
        let lowResult = try await lowConfSummarizer.classifySessionTypeWithConfidence(
            transcript: "Brief status check.",
            availableTypes: SessionTypeConfig.defaultList
        )
        #expect(lowResult.config.slug == "meeting")
        #expect(lowResult.confidence == 0.60)

        // Edge case: single type available returns 1.0 confidence
        let singleResult = try await therapySummarizer.classifySessionTypeWithConfidence(
            transcript: "Any text",
            availableTypes: [SessionTypeConfig.defaultMeeting]
        )
        #expect(singleResult.config.slug == "meeting")
        #expect(singleResult.confidence == 1.0)

        // Edge case: empty types list returns fallback
        let emptyResult = try await therapySummarizer.classifySessionTypeWithConfidence(
            transcript: "Any text",
            availableTypes: []
        )
        #expect(emptyResult.config.slug == "meeting")

        // Unparseable string fallback
        let unparseable = therapySummarizer.parseClassificationResponse("random gibberish", availableTypes: SessionTypeConfig.defaultList)
        #expect(unparseable.confidence == 0.50)
    }

    @Test("Autonomous calendar matching with confidence in AppleIntelligenceSummarizer")
    func testAutonomousCalendarMatching() async throws {
        let testEvent = CalendarEventInfo(
            id: "EVENT-UUID-1234",
            title: "Sprint Planning Q4",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            notes: "Review sprint goals.",
            attendees: ["Alice", "Bob"]
        )

        // Matched event with >80% confidence
        let matchSummarizer = AppleIntelligenceSummarizer(sessionRunner: { _ in
            return """
            {
              "matchedEventID": "EVENT-UUID-1234",
              "confidence": 92,
              "reasoning": "Discussed sprint goals with Alice and Bob."
            }
            """
        })
        let result = try await matchSummarizer.matchCalendarEvent(
            transcript: "Alice and Bob let's start sprint planning.",
            candidateEvents: [testEvent],
            fileDate: Date()
        )
        #expect(result.matchedEvent?.id == "EVENT-UUID-1234")
        #expect(result.confidence == 0.92)

        // Matched with regex fallback
        let regexSummarizer = AppleIntelligenceSummarizer(sessionRunner: { _ in
            return "matchedEventID: \"EVENT-UUID-1234\" with confidence: 88"
        })
        let regexResult = try await regexSummarizer.matchCalendarEvent(
            transcript: "Sprint planning transcript",
            candidateEvents: [testEvent],
            fileDate: Date()
        )
        #expect(regexResult.matchedEvent?.id == "EVENT-UUID-1234")
        #expect(regexResult.confidence == 0.88)

        // Event title keyword fallback
        let titleFallback = matchSummarizer.parseCalendarMatchResponse(
            "The transcript mentions Sprint Planning Q4 explicitly.",
            candidateEvents: [testEvent]
        )
        #expect(titleFallback.matchedEvent?.id == "EVENT-UUID-1234")

        // NONE or empty candidates
        let noneResult = try await matchSummarizer.matchCalendarEvent(
            transcript: "Some unrelated monologue",
            candidateEvents: [],
            fileDate: Date()
        )
        #expect(noneResult.matchedEvent == nil)
        #expect(noneResult.confidence == 0.0)
    }

    @Test("OpenAICompatibleSummarizer classification and calendar matching parsers")
    func testOpenAICompatibleParsers() {
        let summarizer = OpenAICompatibleSummarizer(
            endpoint: "http://localhost:11434/v1",
            modelName: "test-model"
        )

        // Test classification parser
        let classJson = """
        {
          "sessionType": "Therapy",
          "confidence": 91,
          "reasoning": "Reflective tone"
        }
        """
        let classRes = summarizer.parseClassificationResponse(classJson, availableTypes: SessionTypeConfig.defaultList)
        #expect(classRes.config.slug == "therapy")
        #expect(classRes.confidence == 0.91)

        // Test calendar match parser
        let event = CalendarEventInfo(id: "EV-1", title: "1-on-1 Sync", startDate: Date(), endDate: Date())
        let calJson = """
        {
          "matchedEventID": "EV-1",
          "confidence": 89,
          "reasoning": "Direct 1-on-1 conversation"
        }
        """
        let calRes = summarizer.parseCalendarMatchResponse(calJson, candidateEvents: [event])
        #expect(calRes.matchedEvent?.id == "EV-1")
        #expect(calRes.confidence == 0.89)
    }

    @Test("OpenAICompatibleSummarizer full execution suite with custom runner")
    func testOpenAICompatibleSummarizerFullSuite() async throws {
        let summarizer = OpenAICompatibleSummarizer(
            endpoint: "http://localhost:11434/v1",
            modelName: "mock-model",
            customRunner: { prompt in
                if prompt.contains("Available session types") {
                    return """
                    {
                      "sessionType": "Therapy",
                      "confidence": 93,
                      "reasoning": "Empathetic analysis"
                    }
                    """
                } else if prompt.contains("Candidate Calendar Events") {
                    return """
                    {
                      "matchedEventID": "EVT-MOCK-1",
                      "confidence": 88,
                      "reasoning": "Mock match"
                    }
                    """
                } else if prompt.contains("naming assistant") || prompt.contains("descriptive title") {
                    return "Executive Standup Sync"
                } else {
                    return "## Summary\\n- High level outcome."
                }
            }
        )

        #expect(summarizer.name.contains("mock-model"))

        // Session classification
        let classRes = try await summarizer.classifySessionTypeWithConfidence(
            transcript: "I felt deep emotions today.",
            availableTypes: SessionTypeConfig.defaultList
        )
        #expect(classRes.config.slug == "therapy")
        #expect(classRes.confidence == 0.93)

        let simpleClass = try await summarizer.classifySessionType(
            transcript: "Deep emotions",
            availableTypes: SessionTypeConfig.defaultList
        )
        #expect(simpleClass.slug == "therapy")

        // Single type and empty type edge cases
        let singleType = try await summarizer.classifySessionTypeWithConfidence(
            transcript: "Single",
            availableTypes: [SessionTypeConfig.defaultMeeting]
        )
        #expect(singleType.confidence == 1.0)
        let emptyType = try await summarizer.classifySessionTypeWithConfidence(
            transcript: "Empty",
            availableTypes: []
        )
        #expect(emptyType.config.slug == "meeting")

        // Calendar match
        let evt = CalendarEventInfo(id: "EVT-MOCK-1", title: "Sync", startDate: Date(), endDate: Date())
        let calMatch = try await summarizer.matchCalendarEvent(
            transcript: "Let's review our roadmap sync",
            candidateEvents: [evt],
            fileDate: Date()
        )
        #expect(calMatch.matchedEvent?.id == "EVT-MOCK-1")
        #expect(calMatch.confidence == 0.88)

        // Empty candidates
        let emptyCal = try await summarizer.matchCalendarEvent(
            transcript: "",
            candidateEvents: [],
            fileDate: Date()
        )
        #expect(emptyCal.matchedEvent == nil)

        // Title generation
        let title = try await summarizer.generateTitle(transcript: "Standup transcript", summary: "Summary text")
        #expect(title == "Executive Standup Sync")

        // Empty title fallback
        let emptyTitle = try await summarizer.generateTitle(transcript: "", summary: nil)
        #expect(emptyTitle == "Audio Recording Note")

        // Summarization
        let summary = try await summarizer.summarize(transcript: "Alice: Ready to launch.", template: .defaultMeeting)
        #expect(summary.contains("High level outcome"))

        // Chunking logic
        let emptyChunks = summarizer.chunkTranscript("")
        #expect(emptyChunks.isEmpty)
        let chunks = summarizer.chunkTranscript("Line 1\\nLine 2\\nLine 3", maxChunkSize: 10)
        #expect(chunks.count > 1)

        // Diarize transcript with empty knownSpeakers
        let diarized = try await summarizer.diarizeTranscript(transcript: "John: Hello\\nAlice: Hi", knownSpeakers: [])
        #expect(!diarized.isEmpty)
        let emptyDiarized = try await summarizer.diarizeTranscript(transcript: "")
        #expect(emptyDiarized.isEmpty)

        // Diarize with known speakers
        let profile = SpeakerProfile(name: "Alice", voiceprint: [0.1, 0.2])
        let diarizedKnown = try await summarizer.diarizeTranscript(transcript: "Speaker 1: Hi", knownSpeakers: [profile])
        #expect(!diarizedKnown.isEmpty)

        // summarizeWithChunking
        let longTranscript = (1...20).map { "Line \($0): Discussed quarterly objectives." }.joined(separator: "\n")
        let chunkSummary = try await summarizer.summarizeWithChunking(transcript: longTranscript, template: .defaultMeeting, maxChunkSize: 40)
        #expect(!chunkSummary.isEmpty)

        // testConnection and invalid endpoint fetchAvailableModels
        let conn = try await summarizer.testConnection()
        #expect(conn.latencyMs >= 1)
        #expect(conn.model == "mock-model")

        let badSummarizer = OpenAICompatibleSummarizer(endpoint: "bad url endpoint", modelName: "test")
        do {
            _ = try await badSummarizer.fetchAvailableModels()
        } catch {
            // Expected invalid URL error
        }
    }
}
