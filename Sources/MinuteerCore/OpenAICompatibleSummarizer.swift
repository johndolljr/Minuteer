import Foundation

public final class OpenAICompatibleSummarizer: SummarizerEngine, @unchecked Sendable {
    public var name: String {
        return "OpenAI-Compatible (\(modelName))"
    }

    public var endpoint: String
    public var modelName: String
    public var apiKey: String
    public var customRunner: (@Sendable (String) async throws -> String)?
    public var session: URLSession

    public init(
        endpoint: String = "https://api.openai.com/v1",
        modelName: String = "gpt-4o-mini",
        apiKey: String = "",
        customRunner: (@Sendable (String) async throws -> String)? = nil,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.modelName = modelName
        self.apiKey = apiKey
        self.customRunner = customRunner
        self.session = session
    }

    public func executePrompt(_ prompt: String) async throws -> String {
        if let runner = customRunner {
            return try await runner(prompt)
        }

        var cleanEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanEndpoint.hasSuffix("/") {
            cleanEndpoint.removeLast()
        }
        let completionsURLString = cleanEndpoint.hasSuffix("/chat/completions")
            ? cleanEndpoint
            : "\(cleanEndpoint)/chat/completions"

        guard let requestURL = URL(string: completionsURLString),
              requestURL.scheme != nil,
              requestURL.host != nil else {
            throw NSError(domain: "OpenAICompatibleSummarizer", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Invalid API endpoint URL: \(endpoint)"
            ])
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanKey.isEmpty {
            request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        }

        var payload: [String: Any] = [
            "model": modelName,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        let lowerModel = modelName.lowercased()
        let isReasoningModel = lowerModel.hasPrefix("o1") || lowerModel.hasPrefix("o3") || lowerModel.contains("reason") || lowerModel.contains("gpt-5")
        if !isReasoningModel {
            payload["temperature"] = 0.3
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        var (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAICompatibleSummarizer", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Invalid server response."
            ])
        }

        // Auto-recovery: if rejected due to unsupported temperature parameter, retry without temperature
        if httpResponse.statusCode == 400 && payload["temperature"] != nil {
            let initialError = String(decoding: data, as: UTF8.self).lowercased()
            if initialError.contains("temperature") {
                payload.removeValue(forKey: "temperature")
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                let retry = try await session.data(for: request)
                data = retry.0
                if let retryHttp = retry.1 as? HTTPURLResponse, (200...299).contains(retryHttp.statusCode) {
                    return try parseChoicesContent(from: data)
                }
            }
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorText = ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errObj = json["error"] as? [String: Any],
               let msg = errObj["message"] as? String, !msg.isEmpty {
                errorText = msg
            } else {
                errorText = String(decoding: data, as: UTF8.self)
            }
            throw NSError(domain: "OpenAICompatibleSummarizer", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "API error (\(httpResponse.statusCode)): \(errorText)"
            ])
        }

        return try parseChoicesContent(from: data)
    }

    private func parseChoicesContent(from data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "OpenAICompatibleSummarizer", code: 502, userInfo: [
                NSLocalizedDescriptionKey: "Response did not contain valid choices[0].message.content."
            ])
        }

        return content
    }

    public func testConnection() async throws -> (latencyMs: Int, model: String) {
        let start = Date()
        let prompt = "Respond with 'OK'."
        _ = try await executePrompt(prompt)
        let latency = max(1, Int(Date().timeIntervalSince(start) * 1000))
        return (latency, modelName)
    }

    public func fetchAvailableModels() async throws -> [String] {
        var cleanEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanEndpoint.hasSuffix("/") {
            cleanEndpoint.removeLast()
        }
        let base = cleanEndpoint.hasSuffix("/chat/completions")
            ? cleanEndpoint.replacingOccurrences(of: "/chat/completions", with: "")
            : cleanEndpoint
        let modelsURLString = base.hasSuffix("/models") ? base : "\(base)/models"
        guard let requestURL = URL(string: modelsURLString), requestURL.scheme != nil, requestURL.host != nil else {
            throw NSError(domain: "OpenAICompatibleSummarizer", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Invalid API endpoint URL: \(endpoint)"
            ])
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanKey.isEmpty {
            request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            var errorText = ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errObj = json["error"] as? [String: Any],
               let msg = errObj["message"] as? String, !msg.isEmpty {
                errorText = msg
            } else {
                errorText = String(decoding: data, as: UTF8.self)
            }
            throw NSError(domain: "OpenAICompatibleSummarizer", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [
                NSLocalizedDescriptionKey: "Failed to fetch models: \(errorText)"
            ])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let dataArray = json?["data"] as? [[String: Any]] else {
            return []
        }
        let ids = dataArray.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
        return ids.sorted()
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

        let response = try await executePrompt(prompt)
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

        let response = try await executePrompt(prompt)
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

        if knownSpeakers.isEmpty {
            let turns = TranscriptTurn.splitWallOfText(sanitized)
            return TranscriptTurn.formatTranscript(turns: turns)
        }

        let chunks = chunkTranscript(sanitized, maxChunkSize: 2_000)
        var formattedParts: [String] = []

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
        let speakerContext = "Known frequent speakers to recognize by name and context:\n\(descriptions)"

        for chunk in chunks {
            let prompt = """
            You are an audio dialogue editor and speaker attribution specialist.
            Rewrite the following audio transcript excerpt into alternating speaker dialogue turns while preserving any [mm:ss] timestamps.
            Prefix each turn with [mm:ss] **Speaker Name**: (or [mm:ss] **Speaker 1**: / [mm:ss] **Speaker 2**:).
            \(speakerContext)

            Respond with ONLY the formatted dialogue turns.

            [Transcript Excerpt]:
            \(chunk)
            """
            do {
                let response = try await executePrompt(prompt)
                formattedParts.append(response.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                formattedParts.append(chunk)
            }
        }

        let combined = formattedParts.joined(separator: "\n\n")
        return combined.isEmpty ? TranscriptTurn.formatTranscript(turns: TranscriptTurn.splitWallOfText(transcript)) : combined
    }

    public func generateTitle(transcript: String, summary: String?) async throws -> String {
        let contentForTitle: String
        if let summary = summary, !summary.isEmpty {
            contentForTitle = String(summary.prefix(1_500))
        } else {
            contentForTitle = String(transcript.prefix(1_500))
        }

        guard !contentForTitle.isEmpty else {
            return "Audio Recording Note"
        }

        let prompt = """
        You are a concise document naming assistant.
        Analyze the following audio recording summary and transcript to generate a clear, descriptive title (4 to 8 words) summarizing what was discussed.
        Do NOT wrap the title in quotes, backticks, or asterisks. Do NOT add trailing punctuation or dates.
        Respond with ONLY the title.

        [Content]:
        \(contentForTitle)
        """

        let rawResponse = try await executePrompt(prompt)
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

        // ChatGPT and modern OpenAI-compatible LLMs support 32k-128k+ tokens.
        // Direct single-pass summarization preserves full context and doesn't waste roundtrips.
        if transcript.count <= 100_000 {
            do {
                let prompt = template.renderPrompt(transcript: transcript)
                return try await executePrompt(prompt)
            } catch {
                let errorLower = error.localizedDescription.lowercased()
                if errorLower.contains("context") || errorLower.contains("token") || errorLower.contains("too large") || errorLower.contains("maximum context") {
                    return try await summarizeWithChunking(transcript: transcript, template: template)
                }
                throw error
            }
        } else {
            return try await summarizeWithChunking(transcript: transcript, template: template)
        }
    }

    public func summarizeWithChunking(transcript: String, template: SummaryPromptTemplate, maxChunkSize: Int = 40_000) async throws -> String {
        let chunks = chunkTranscript(transcript, maxChunkSize: maxChunkSize)
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

        for paragraph in rawParagraphs {
            let pTrimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if pTrimmed.isEmpty { continue }

            if currentChunk.count + pTrimmed.count + 1 > maxChunkSize {
                flushCurrent()
            }

            if pTrimmed.count > maxChunkSize {
                var remaining = pTrimmed
                while remaining.count > maxChunkSize {
                    let splitIndex = remaining.index(remaining.startIndex, offsetBy: maxChunkSize)
                    let subChunk = String(remaining[..<splitIndex])
                    chunks.append(subChunk)
                    remaining = String(remaining[splitIndex...])
                }
                currentChunk = remaining
            } else {
                if currentChunk.isEmpty {
                    currentChunk = pTrimmed
                } else {
                    currentChunk += "\n" + pTrimmed
                }
            }
        }
        flushCurrent()
        return chunks
    }
}
