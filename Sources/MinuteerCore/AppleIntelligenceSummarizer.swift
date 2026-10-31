import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public struct SessionClassificationResult: Equatable, Sendable {
    public var config: SessionTypeConfig
    public var confidence: Double // 0.0 to 1.0 (e.g. 0.85 = 85%)
    public var explanation: String?

    public init(config: SessionTypeConfig, confidence: Double, explanation: String? = nil) {
        self.config = config
        self.confidence = confidence
        self.explanation = explanation
    }
}

public struct CalendarMatchResult: Equatable, Sendable {
    public var matchedEvent: CalendarEventInfo?
    public var confidence: Double // 0.0 to 1.0
    public var reasoning: String?

    public init(matchedEvent: CalendarEventInfo?, confidence: Double, reasoning: String? = nil) {
        self.matchedEvent = matchedEvent
        self.confidence = confidence
        self.reasoning = reasoning
    }
}

public protocol SummarizerEngine: Sendable {
    var name: String { get }
    func summarize(transcript: String, template: SummaryPromptTemplate) async throws -> String
    func classifySessionType(transcript: String, availableTypes: [SessionTypeConfig]) async throws -> SessionTypeConfig
    func classifySessionTypeWithConfidence(transcript: String, availableTypes: [SessionTypeConfig]) async throws -> SessionClassificationResult
    func matchCalendarEvent(transcript: String, candidateEvents: [CalendarEventInfo], fileDate: Date) async throws -> CalendarMatchResult
    func diarizeTranscript(transcript: String, knownSpeakers: [SpeakerProfile]) async throws -> String
    func generateTitle(transcript: String, summary: String?) async throws -> String
}

public extension SummarizerEngine {
    func classifySessionTypeWithConfidence(
        transcript: String,
        availableTypes: [SessionTypeConfig]
    ) async throws -> SessionClassificationResult {
        let type = try await classifySessionType(transcript: transcript, availableTypes: availableTypes)
        return SessionClassificationResult(config: type, confidence: 0.85, explanation: "Matched by content classification")
    }

    func matchCalendarEvent(
        transcript: String,
        candidateEvents: [CalendarEventInfo],
        fileDate: Date
    ) async throws -> CalendarMatchResult {
        return CalendarMatchResult(matchedEvent: nil, confidence: 0.0, reasoning: "No candidate match")
    }
}

public final class AppleIntelligenceSummarizer: SummarizerEngine, @unchecked Sendable {
    public let name = "Apple Intelligence (FoundationModels)"
    var customRunner: (@Sendable (String) async throws -> String)?
    var sessionRunner: (@Sendable (String) async throws -> String)?

    public init(
        customRunner: (@Sendable (String) async throws -> String)? = nil,
        sessionRunner: (@Sendable (String) async throws -> String)? = nil
    ) {
        self.customRunner = customRunner
        self.sessionRunner = sessionRunner
    }

    public var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        } else {
            return false
        }
        #else
        return false
        #endif
    }

    func executePrompt(_ prompt: String) async throws -> String {
        if let runner = sessionRunner {
            return try await runner(prompt)
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else {
                throw NSError(
                    domain: "AppleIntelligenceSummarizer",
                    code: 503,
                    userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is currently unavailable on this system."]
                )
            }

            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            return response.content
        } else {
            throw NSError(
                domain: "AppleIntelligenceSummarizer",
                code: 501,
                userInfo: [NSLocalizedDescriptionKey: "FoundationModels requires macOS 26.0 or newer."]
            )
        }
        #else
        throw NSError(
            domain: "AppleIntelligenceSummarizer",
            code: 501,
            userInfo: [NSLocalizedDescriptionKey: "FoundationModels framework not available on this macOS version."]
        )
        #endif
    }

    public func classifySessionType(transcript: String, availableTypes: [SessionTypeConfig]) async throws -> SessionTypeConfig {
        let result = try await classifySessionTypeWithConfidence(transcript: transcript, availableTypes: availableTypes)
        return result.config
    }

    public func classifySessionTypeWithConfidence(
        transcript: String,
        availableTypes: [SessionTypeConfig]
    ) async throws -> SessionClassificationResult {
        guard !availableTypes.isEmpty else {
            return SessionClassificationResult(config: SessionTypeConfig.defaultMeeting, confidence: 1.0)
        }
        guard availableTypes.count > 1 else {
            return SessionClassificationResult(config: availableTypes[0], confidence: 1.0)
        }

        let excerpt = String(transcript.prefix(2_500))
        let typeList = availableTypes.map { "- \($0.name) (slug: \($0.slug)): \($0.systemInstructions.prefix(120))..." }.joined(separator: "\n")
        let prompt = """
        You are an intelligent audio classifier.
        Analyze the audio transcript excerpt and classify it into one of the available session types with a confidence score from 0 to 100 percent.

        Available session types:
        \(typeList)

        Respond in valid JSON format:
        {
          "sessionType": "<exact name or slug of matching session type>",
          "confidence": <integer from 0 to 100>,
          "reasoning": "<short explanation>"
        }

        [Transcript Excerpt]:
        \(excerpt)
        """

        let response: String
        if let runner = customRunner ?? sessionRunner {
            response = try await runner(prompt)
        } else {
            response = try await executePrompt(prompt)
        }

        return parseClassificationResponse(response, availableTypes: availableTypes)
    }

    func parseClassificationResponse(_ text: String, availableTypes: [SessionTypeConfig]) -> SessionClassificationResult {
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let typeName = obj["sessionType"] as? String {
            let confInt = (obj["confidence"] as? NSNumber)?.doubleValue ?? 85.0
            let conf = max(0.0, min(1.0, confInt > 1.0 ? confInt / 100.0 : confInt))
            let reasoning = obj["reasoning"] as? String
            if let matched = availableTypes.first(where: {
                $0.name.caseInsensitiveCompare(typeName) == .orderedSame ||
                $0.slug.caseInsensitiveCompare(typeName) == .orderedSame
            }) {
                return SessionClassificationResult(config: matched, confidence: conf, explanation: reasoning)
            }
        }

        // Regex / keyword fallback
        var detectedConf = 0.85
        if let regex = try? NSRegularExpression(pattern: #""confidence"\s*:\s*(\d+)"#),
           let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
           match.numberOfRanges > 1 {
            let range = match.range(at: 1)
            if let num = Double((text as NSString).substring(with: range)) {
                detectedConf = max(0.0, min(1.0, num > 1.0 ? num / 100.0 : num))
            }
        }

        let cleanResponse = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for type in availableTypes {
            if cleanResponse.contains(type.name.lowercased()) || cleanResponse.contains(type.slug.lowercased()) {
                return SessionClassificationResult(config: type, confidence: detectedConf, explanation: "Matched keywords")
            }
        }

        return SessionClassificationResult(config: availableTypes.first ?? SessionTypeConfig.defaultMeeting, confidence: 0.50, explanation: "Default fallback")
    }

    public func matchCalendarEvent(
        transcript: String,
        candidateEvents: [CalendarEventInfo],
        fileDate: Date
    ) async throws -> CalendarMatchResult {
        guard !candidateEvents.isEmpty, !transcript.isEmpty else {
            return CalendarMatchResult(matchedEvent: nil, confidence: 0.0)
        }

        let excerpt = String(transcript.prefix(2_500))
        var eventList = ""
        for (i, e) in candidateEvents.enumerated() {
            var details = "[\(i + 1)] ID: \(e.id) | Title: \"\(e.title)\" | Time: \(e.formattedTimeRange)"
            if !e.attendees.isEmpty {
                details += " | Attendees: \(e.attendees.joined(separator: ", "))"
            }
            if let notes = e.notes, !notes.isEmpty {
                details += " | Notes: \(notes.prefix(120))"
            }
            eventList += details + "\n"
        }

        let prompt = """
        You are an intelligent executive assistant.
        Analyze the audio transcript excerpt and determine if this recording corresponds to any of the candidate calendar events.
        File timestamp: \(fileDate) (use this only as a general hint; conversations may start early or late).

        Candidate Calendar Events:
        \(eventList)

        Respond in valid JSON format:
        {
          "matchedEventID": "<exact ID of the matching event, or NONE>",
          "confidence": <integer from 0 to 100>,
          "reasoning": "<short explanation why this transcript matches the event, including speakers or agenda mentioned>"
        }

        Transcript Excerpt:
        \(excerpt)
        """

        let response: String
        if let runner = customRunner ?? sessionRunner {
            response = try await runner(prompt)
        } else {
            response = try await executePrompt(prompt)
        }

        return parseCalendarMatchResponse(response, candidateEvents: candidateEvents)
    }

    func parseCalendarMatchResponse(_ text: String, candidateEvents: [CalendarEventInfo]) -> CalendarMatchResult {
        var matchedID: String?
        var conf: Double = 0.0
        var reasoning: String?

        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            matchedID = obj["matchedEventID"] as? String
            let confVal = (obj["confidence"] as? NSNumber)?.doubleValue ?? 0.0
            conf = max(0.0, min(1.0, confVal > 1.0 ? confVal / 100.0 : confVal))
            reasoning = obj["reasoning"] as? String
        } else {
            if let idRegex = try? NSRegularExpression(pattern: #""?matchedEventID"?\s*:\s*"?([A-Za-z0-9\-_]+)"?"#),
               let match = idRegex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
               match.numberOfRanges > 1 {
                matchedID = (text as NSString).substring(with: match.range(at: 1))
            }
            if let confRegex = try? NSRegularExpression(pattern: #""?confidence"?\s*:\s*(\d+)"#),
               let match = confRegex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
               match.numberOfRanges > 1 {
                if let num = Double((text as NSString).substring(with: match.range(at: 1))) {
                    conf = max(0.0, min(1.0, num > 1.0 ? num / 100.0 : num))
                }
            }
        }

        if let id = matchedID, id.uppercased() != "NONE" {
            if let matched = candidateEvents.first(where: { $0.id == id || id.contains($0.id) }) {
                return CalendarMatchResult(matchedEvent: matched, confidence: conf > 0 ? conf : 0.85, reasoning: reasoning)
            }
        }

        for e in candidateEvents {
            if text.localizedCaseInsensitiveContains(e.title) {
                return CalendarMatchResult(matchedEvent: e, confidence: conf > 0 ? conf : 0.85, reasoning: reasoning ?? "Matched title keywords")
            }
        }

        return CalendarMatchResult(matchedEvent: nil, confidence: conf, reasoning: reasoning)
    }

    public func diarizeTranscript(transcript: String, knownSpeakers: [SpeakerProfile] = []) async throws -> String {
        guard !transcript.isEmpty else { return transcript }
        let sanitized = TranscriptTurn.stripSpecialTokens(transcript)

        // When no known speaker profiles are registered, splitWallOfText instantly and accurately
        // segments dialogue turns and attaches exact audio timestamps without costly repetitive LLM passes.
        if knownSpeakers.isEmpty {
            let turns = TranscriptTurn.splitWallOfText(sanitized)
            return TranscriptTurn.formatTranscript(turns: turns)
        }

        let chunks = chunkTranscript(sanitized, maxChunkSize: 2_000)
        var formattedParts: [String] = []

        let speakerContext: String
        let descriptions = knownSpeakers.map { s in
            var line = "- \(s.name)"
            if !s.aliases.isEmpty {
                line += " (aliases: \(s.aliases.joined(separator: ", ")))"
            }
            if !s.contextNotes.isEmpty {
                line += ": \(s.contextNotes)"
            }
            return line
        }.joined(separator: "\n")
        speakerContext = "Known frequent speakers to recognize by name and context:\n\(descriptions)"

        for chunk in chunks {
            if customRunner != nil && sessionRunner == nil {
                formattedParts.append(chunk)
                continue
            }

            let prompt = """
            You are an audio dialogue editor and speaker attribution specialist.
            Rewrite the following audio transcript excerpt into alternating speaker dialogue turns while preserving any [mm:ss] timestamps.
            Prefix each turn with [mm:ss] **Speaker Name**: (or [mm:ss] **Speaker 1**: / [mm:ss] **Speaker 2**:).
            \(speakerContext)

            Example output format:
            [00:00] **Speaker 1**: Hello everyone, thank you for joining.
            [00:15] **Speaker 2**: Glad to be here. Did you see the latest updates?
            [00:42] **Speaker 1**: Yes, they look solid.

            Rules:
            - Every statement MUST start with [mm:ss] **Speaker Name**: (keep existing timestamp brackets).
            - Do not provide commentary, introductions, or preambles. Output ONLY the attributed conversation turns.

            [Transcript Excerpt]:
            \(chunk)
            """

            do {
                let result: String
                if let runner = sessionRunner {
                    result = try await runner(prompt)
                } else {
                    result = try await executePrompt(prompt)
                }
                let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.contains("**") && clean.contains(":") {
                    formattedParts.append(clean)
                } else {
                    let turns = TranscriptTurn.splitWallOfText(chunk)
                    formattedParts.append(TranscriptTurn.formatTranscript(turns: turns))
                }
            } catch {
                let turns = TranscriptTurn.splitWallOfText(chunk)
                formattedParts.append(TranscriptTurn.formatTranscript(turns: turns))
            }
        }

        let combined = formattedParts.joined(separator: "\n\n")
        return combined.isEmpty ? TranscriptTurn.formatTranscript(turns: TranscriptTurn.splitWallOfText(transcript)) : combined
    }

    public func generateTitle(transcript: String, summary: String? = nil) async throws -> String {
        let contentForTitle: String
        if let sum = summary, !sum.isEmpty {
            contentForTitle = String(sum.prefix(2_000))
        } else {
            contentForTitle = String(transcript.prefix(2_000))
        }
        guard !contentForTitle.isEmpty else { return "Audio Recording Note" }

        let prompt = """
        You are a concise document title generator.
        Analyze the following audio recording summary and transcript to generate a clear, descriptive title (4 to 8 words) summarizing what was discussed.
        Do NOT wrap the title in quotes, backticks, or asterisks. Do NOT add trailing punctuation or dates.
        Respond with ONLY the title.

        [Content]:
        \(contentForTitle)
        """

        let rawResponse: String
        if let runner = customRunner ?? sessionRunner {
            rawResponse = try await runner(prompt)
        } else {
            rawResponse = try await executePrompt(prompt)
        }

        var clean = rawResponse
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"\'#*`"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if clean.lowercased().hasPrefix("title:") {
            clean = String(clean.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if clean.hasPrefix("#") {
            clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return clean.isEmpty ? "Audio Recording Note" : clean
    }

    public func summarize(transcript: String, template: SummaryPromptTemplate) async throws -> String {
        if let runner = customRunner {
            let prompt = template.renderPrompt(transcript: transcript)
            return try await runner(prompt)
        }

        // If transcript is <= 2,500 chars (~500 tokens), single pass is safe
        if transcript.count <= 2_500 {
            do {
                let prompt = template.renderPrompt(transcript: transcript)
                return try await executePrompt(prompt)
            } catch {
                // If single-pass fails, fall through to chunked summarization
                return try await summarizeWithChunking(transcript: transcript, template: template)
            }
        } else {
            return try await summarizeWithChunking(transcript: transcript, template: template)
        }
    }

    public func summarizeWithChunking(transcript: String, template: SummaryPromptTemplate) async throws -> String {
        let chunks = chunkTranscript(transcript, maxChunkSize: 2_500)
        var runningSummary = ""

        for (index, chunk) in chunks.enumerated() {
            let partNumber = index + 1
            let safeRunning = runningSummary.count > 2_000 ? String(runningSummary.suffix(2_000)) : runningSummary
            let prompt = """
            You are summarizing an audio recording.
            Update and refine the running summary with key discussion points, decisions, facts, and context from Part \(partNumber) of \(chunks.count).
            Keep your updated summary concise and structured (under 350 words):

            [Current Running Summary]:
            \(safeRunning.isEmpty ? "None yet (start of recording)." : safeRunning)

            [New Transcript Section]:
            \(chunk)
            """
            do {
                runningSummary = try await executePrompt(prompt)
            } catch {
                // If a chunk still encounters context limits, truncate and attempt a recovery prompt
                let trimmed = String(chunk.prefix(1_200))
                let retryPrompt = """
                Briefly add key points from this segment to the summary:
                \(trimmed)
                """
                if let recovered = try? await executePrompt(retryPrompt) {
                    runningSummary = (runningSummary.isEmpty ? "" : "\(runningSummary)\n") + recovered
                }
            }
        }

        let finalPrompt = template.renderPrompt(transcript: runningSummary)
        do {
            return try await executePrompt(finalPrompt)
        } catch {
            return runningSummary.isEmpty ? "Summary generated from transcript." : runningSummary
        }
    }

    public func chunkTranscript(_ text: String, maxChunkSize: Int = 2_500) -> [String] {
        guard !text.isEmpty else { return [] }
        var chunks: [String] = []
        let rawParagraphs = text.components(separatedBy: "\n")
        var currentChunk = ""

        func flushCurrent() {
            let trimmed = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chunks.append(trimmed)
            }
            currentChunk = ""
        }

        for rawPara in rawParagraphs {
            let para = rawPara.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !para.isEmpty else { continue }

            if para.count > maxChunkSize {
                flushCurrent()
                let words = para.components(separatedBy: " ")
                var subChunk = ""
                for word in words {
                    if subChunk.count + word.count + 1 > maxChunkSize && !subChunk.isEmpty {
                        chunks.append(subChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                        subChunk = word
                    } else {
                        subChunk = subChunk.isEmpty ? word : "\(subChunk) \(word)"
                    }
                }
                if !subChunk.isEmpty {
                    chunks.append(subChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } else {
                let candidate = currentChunk.isEmpty ? para : "\(currentChunk)\n\(para)"
                if candidate.count > maxChunkSize {
                    flushCurrent()
                    currentChunk = para
                } else {
                    currentChunk = candidate
                }
            }
        }

        flushCurrent()
        return chunks.isEmpty ? [text] : chunks
    }
}
