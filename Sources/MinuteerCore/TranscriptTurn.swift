import Foundation

public struct TranscriptTurn: Identifiable, Equatable, Hashable, Sendable {
    public var id: Int
    public var speaker: String
    public var timestamp: String?
    public var text: String

    public init(id: Int, speaker: String, timestamp: String? = nil, text: String) {
        self.id = id
        self.speaker = speaker
        self.timestamp = timestamp
        self.text = text
    }

    public var timestampSeconds: TimeInterval? {
        guard let ts = timestamp else { return nil }
        let parts = ts.components(separatedBy: ":")
        if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) {
            return m * 60 + s
        } else if parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) {
            return h * 3600 + m * 60 + s
        }
        return nil
    }

    public static func formatSeconds(_ seconds: Float) -> String {
        let total = max(0, Int(seconds))
        let mins = total / 60
        let secs = total % 60
        if mins >= 60 {
            let hours = mins / 60
            let remMins = mins % 60
            return String(format: "%02d:%02d:%02d", hours, remMins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }

    /// Strip any special tokens such as <|startoftranscript|>, <|en|>, <|0.00|>, etc.
    public static func stripSpecialTokens(_ text: String) -> String {
        let regex = try? NSRegularExpression(pattern: "<\\|[\\s\\S]*?\\|>", options: [])
        let ns = text as NSString
        let cleaned = regex?.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        ) ?? text
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse markdown or plain transcript into structured speaker turns with stable indices
    public static func parseTurns(from rawTranscript: String) -> [TranscriptTurn] {
        let sanitized = stripSpecialTokens(rawTranscript)
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var rawTurns: [(speaker: String, timestamp: String?, text: String)] = []
        let lines = trimmed.components(separatedBy: "\n")

        let timestampRegex = try? NSRegularExpression(pattern: "\\[(\\d{1,2}:\\d{2}(?::\\d{2})?)\\]", options: [])
        let speakerRegex = try? NSRegularExpression(
            pattern: "^(?:\\*\\*(.*?)\\*\\*|([A-Za-z0-9 _]{2,30}))\\s*:\\s*([\\s\\S]*)",
            options: []
        )

        var explicitSpeakerMatches = 0

        for line in lines {
            let lTrimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lTrimmed.isEmpty else { continue }

            var workingLine = lTrimmed
            var extractedTimestamp: String?

            let nsWorking = workingLine as NSString
            if let tsMatch = timestampRegex?.firstMatch(in: workingLine, options: [], range: NSRange(location: 0, length: nsWorking.length)) {
                if tsMatch.range(at: 1).location != NSNotFound {
                    extractedTimestamp = nsWorking.substring(with: tsMatch.range(at: 1))
                }
                workingLine = timestampRegex?.stringByReplacingMatches(
                    in: workingLine,
                    options: [],
                    range: NSRange(location: 0, length: nsWorking.length),
                    withTemplate: ""
                ).trimmingCharacters(in: .whitespacesAndNewlines) ?? workingLine
            }

            let nsStr = workingLine as NSString
            let match = speakerRegex?.firstMatch(in: workingLine, options: [], range: NSRange(location: 0, length: nsStr.length))

            if let match = match {
                explicitSpeakerMatches += 1
                var speakerName = "Speaker 1"
                if match.range(at: 1).location != NSNotFound {
                    speakerName = nsStr.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if match.range(at: 2).location != NSNotFound {
                    speakerName = nsStr.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                }

                var text = workingLine
                if match.range(at: 3).location != NSNotFound {
                    text = nsStr.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
                }

                rawTurns.append((speaker: speakerName, timestamp: extractedTimestamp, text: text))
            } else {
                if !rawTurns.isEmpty {
                    rawTurns[rawTurns.count - 1].text += " " + workingLine
                } else {
                    rawTurns.append((speaker: "Speaker 1", timestamp: extractedTimestamp, text: workingLine))
                }
            }
        }

        let allSpeaker1 = rawTurns.allSatisfy { $0.speaker == "Speaker 1" }
        let hasBoldSpeakerHeader = trimmed.contains("**")
        if rawTurns.isEmpty || explicitSpeakerMatches == 0 || (allSpeaker1 && !hasBoldSpeakerHeader) {
            return splitWallOfText(trimmed)
        }

        return rawTurns.enumerated().map { index, item in
            let ts = (item.timestamp != nil && !item.timestamp!.isEmpty) ? item.timestamp! : formatSeconds(Float(index * 15))
            return TranscriptTurn(id: index, speaker: item.speaker, timestamp: ts, text: item.text)
        }
    }

    /// Split a plain raw transcript into alternating speaker turns using sentence and conversational flow heuristics
    public static func splitWallOfText(_ text: String) -> [TranscriptTurn] {
        let sanitized = stripSpecialTokens(text)
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tsRegex = try? NSRegularExpression(pattern: "^\\[(\\d{1,2}:\\d{2}(?::\\d{2})?)\\]\\s*", options: [])

        var sentences: [(timestamp: String?, text: String)] = []
        let rawLines = trimmed.components(separatedBy: "\n")

        for line in rawLines {
            let lTrimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lTrimmed.isEmpty else { continue }

            var ts: String?
            var cleanText = lTrimmed
            let nsLine = lTrimmed as NSString
            if let match = tsRegex?.firstMatch(in: lTrimmed, options: [], range: NSRange(location: 0, length: nsLine.length)) {
                if match.range(at: 1).location != NSNotFound {
                    ts = nsLine.substring(with: match.range(at: 1))
                }
                cleanText = tsRegex?.stringByReplacingMatches(
                    in: lTrimmed,
                    options: [],
                    range: NSRange(location: 0, length: nsLine.length),
                    withTemplate: ""
                ).trimmingCharacters(in: .whitespacesAndNewlines) ?? cleanText
            }

            cleanText.enumerateSubstrings(in: cleanText.startIndex..., options: [.bySentences, .localized]) { substring, _, _, _ in
                if let s = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                    sentences.append((timestamp: ts, text: s))
                }
            }
        }

        if sentences.isEmpty {
            sentences = [(timestamp: nil, text: trimmed)]
        }

        var rawTurns: [(speaker: String, timestamp: String?, text: String)] = []
        var currentSpeakerIndex = 1
        var currentChunk: [String] = []
        var currentTimestamp: String?

        for (ts, sentence) in sentences {
            if currentTimestamp == nil && ts != nil {
                currentTimestamp = ts
            }
            currentChunk.append(sentence)

            let isQuestion = sentence.hasSuffix("?")
            let totalWords = currentChunk.joined(separator: " ").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
            let reachedLength = totalWords >= 28 || currentChunk.count >= 3

            if isQuestion || reachedLength {
                let turnText = currentChunk.joined(separator: " ")
                let assignedTS = currentTimestamp ?? formatSeconds(Float(rawTurns.count * 15))
                rawTurns.append((speaker: "Speaker \(currentSpeakerIndex)", timestamp: assignedTS, text: turnText))
                currentChunk = []
                currentTimestamp = nil
                currentSpeakerIndex = (currentSpeakerIndex == 1) ? 2 : 1
            }
        }

        if !currentChunk.isEmpty {
            let turnText = currentChunk.joined(separator: " ")
            let assignedTS = currentTimestamp ?? formatSeconds(Float(rawTurns.count * 15))
            rawTurns.append((speaker: "Speaker \(currentSpeakerIndex)", timestamp: assignedTS, text: turnText))
        }

        return rawTurns.enumerated().map { index, item in
            TranscriptTurn(id: index, speaker: item.speaker, timestamp: item.timestamp, text: item.text)
        }
    }

    /// Format timed transcription segments with [mm:ss] timestamp headers
    public static func formatTimedSegments(_ segments: [(start: Float, text: String)]) -> String {
        var formattedLines: [String] = []
        for segment in segments {
            let clean = stripSpecialTokens(segment.text)
            guard !clean.isEmpty else { continue }
            let timeStr = formatSeconds(segment.start)
            formattedLines.append("[\(timeStr)] \(clean)")
        }
        return formattedLines.joined(separator: "\n")
    }

    /// Format turns back into standard markdown transcript
    public static func formatTranscript(turns: [TranscriptTurn]) -> String {
        return turns.map { turn in
            if let ts = turn.timestamp, !ts.isEmpty {
                return "[\(ts)] **\(turn.speaker)**: \(turn.text)"
            } else {
                return "**\(turn.speaker)**: \(turn.text)"
            }
        }.joined(separator: "\n\n")
    }

    /// Replace all occurrences of a speaker name with a new speaker name
    public static func renameSpeaker(in turns: [TranscriptTurn], from oldName: String, to newName: String) -> [TranscriptTurn] {
        turns.enumerated().map { index, turn in
            if turn.speaker.caseInsensitiveCompare(oldName) == .orderedSame {
                return TranscriptTurn(id: index, speaker: newName, timestamp: turn.timestamp, text: turn.text)
            }
            return TranscriptTurn(id: index, speaker: turn.speaker, timestamp: turn.timestamp, text: turn.text)
        }
    }

    /// Merge a turn into the preceding turn, preserving timestamps and re-indexing turns
    public static func mergeTurnWithPrevious(in turns: [TranscriptTurn], turnIndex: Int) -> [TranscriptTurn] {
        guard turnIndex > 0 && turnIndex < turns.count else { return turns }
        var updated = turns
        updated[turnIndex - 1].text += " " + updated[turnIndex].text
        updated.remove(at: turnIndex)
        return updated.enumerated().map { idx, t in
            TranscriptTurn(id: idx, speaker: t.speaker, timestamp: t.timestamp, text: t.text)
        }
    }

    /// Extract sentence split points (sentence text and end character offset) from turn text
    public static func sentenceSplitPoints(in text: String) -> [(sentence: String, endOffset: Int)] {
        var points: [(sentence: String, endOffset: Int)] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { substring, substringRange, _, _ in
            if let s = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                let endOffset = text.distance(from: text.startIndex, to: substringRange.upperBound)
                points.append((sentence: s, endOffset: endOffset))
            }
        }
        return points
    }

    /// Splits a turn into two turns at a given character offset in its text.
    /// Re-indexes all subsequent turns and computes an appropriate timestamp for the second turn.
    public static func splitTurn(
        in turns: [TranscriptTurn],
        turnIndex: Int,
        splitCharacterOffset: Int,
        newSpeaker: String? = nil
    ) -> [TranscriptTurn] {
        guard turnIndex >= 0 && turnIndex < turns.count else { return turns }
        let turn = turns[turnIndex]
        let text = turn.text
        guard splitCharacterOffset > 0 && splitCharacterOffset < text.count else { return turns }

        let splitIdx = text.index(text.startIndex, offsetBy: splitCharacterOffset)
        let part1 = String(text[..<splitIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        let part2 = String(text[splitIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)

        return splitTurn(
            in: turns,
            turnIndex: turnIndex,
            part1Text: part1,
            part2Text: part2,
            newSpeaker: newSpeaker
        )
    }

    /// Splits a turn into two turns with explicit text parts and an optional custom timestamp or speaker.
    public static func splitTurn(
        in turns: [TranscriptTurn],
        turnIndex: Int,
        part1Text: String,
        part2Text: String,
        newSpeaker: String? = nil,
        splitTimestamp: String? = nil
    ) -> [TranscriptTurn] {
        guard turnIndex >= 0 && turnIndex < turns.count else { return turns }
        let turn = turns[turnIndex]
        let p1 = part1Text.trimmingCharacters(in: .whitespacesAndNewlines)
        let p2 = part2Text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p1.isEmpty && !p2.isEmpty else { return turns }

        let calculatedTimestamp: String
        if let ts = splitTimestamp, !ts.isEmpty {
            calculatedTimestamp = ts
        } else {
            let startSec = turn.timestampSeconds ?? (Double(turnIndex) * 15.0)
            let totalLen = max(1, p1.count + p2.count)
            let ratio = max(0.1, min(0.9, Double(p1.count) / Double(totalLen)))
            let nextStartSec: Double
            if turnIndex + 1 < turns.count, let nSec = turns[turnIndex + 1].timestampSeconds, nSec > startSec {
                nextStartSec = nSec
            } else {
                nextStartSec = startSec + max(10.0, Double(totalLen) * 0.08)
            }
            let splitSec = startSec + (ratio * (nextStartSec - startSec))
            calculatedTimestamp = formatSeconds(Float(splitSec))
        }

        let fallbackSpeaker: String
        if let explicit = newSpeaker, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fallbackSpeaker = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let other = turns.first(where: { $0.speaker.caseInsensitiveCompare(turn.speaker) != .orderedSame })?.speaker
            fallbackSpeaker = other ?? (turn.speaker == "Speaker 1" ? "Speaker 2" : "Speaker 1")
        }

        let firstTurn = TranscriptTurn(id: turnIndex, speaker: turn.speaker, timestamp: turn.timestamp, text: p1)
        let secondTurn = TranscriptTurn(id: turnIndex + 1, speaker: fallbackSpeaker, timestamp: calculatedTimestamp, text: p2)

        var newTurns: [TranscriptTurn] = []
        for (i, t) in turns.enumerated() {
            if i < turnIndex {
                newTurns.append(t)
            } else if i == turnIndex {
                newTurns.append(firstTurn)
                newTurns.append(secondTurn)
            } else {
                newTurns.append(t)
            }
        }

        return newTurns.enumerated().map { idx, t in
            TranscriptTurn(id: idx, speaker: t.speaker, timestamp: t.timestamp, text: t.text)
        }
    }
}
