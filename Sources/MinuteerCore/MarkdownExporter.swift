import Foundation

public enum MarkdownExportError: LocalizedError, Equatable {
    case fileExists(URL)
    case missingContent
    case destinationNotWritable(URL)

    public var errorDescription: String? {
        switch self {
        case .fileExists(let url):
            return "File already exists at '\(url.path)'. Overwrite requires explicit user permission."
        case .missingContent:
            return "Cannot export empty summary or recording."
        case .destinationNotWritable(let url):
            return "Destination directory '\(url.path)' is not writable."
        }
    }
}

public final class MarkdownExporter: @unchecked Sendable {
    public static var defaultInboxDirectory: URL {
        URL(fileURLWithPath: AppConfig.defaultExportDirectory)
    }
    private let lock = NSLock()
    private var _destinationDirectory: URL

    public var destinationDirectory: URL {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _destinationDirectory
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _destinationDirectory = newValue
        }
    }

    public init(destinationDirectory: URL = MarkdownExporter.defaultInboxDirectory) {
        self._destinationDirectory = destinationDirectory
    }

    public func defaultFilename(for recording: AudioRecordingFile, typeSlug: String, title: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let datePrefix = formatter.string(from: recording.creationDate)

        let chosenTitle = recording.calendarEvent?.title ?? title ?? recording.noteTitle
        if let chosen = chosenTitle, !chosen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let slug = chosen.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .prefix(8)
                .joined(separator: "-")
            if !slug.isEmpty {
                return "\(datePrefix)-\(slug).md"
            }
        }
        return "\(datePrefix)-\(typeSlug).md"
    }

    public func defaultFilename(for recording: AudioRecordingFile, sessionType: SessionType) -> String {
        defaultFilename(for: recording, typeSlug: sessionType.rawValue, title: recording.noteTitle)
    }

    public func buildMarkdownContent(
        for recording: AudioRecordingFile,
        typeSlug: String,
        typeTitle: String,
        customTitle: String? = nil
    ) -> String {
        let isoFormatter = ISO8601DateFormatter()
        let timestamp = isoFormatter.string(from: recording.creationDate)

        let title: String
        if let custom = customTitle ?? recording.noteTitle, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let titleDateFormatter = DateFormatter()
            titleDateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            let titleDate = titleDateFormatter.string(from: recording.creationDate)
            title = "\(typeTitle) - \(titleDate)"
        }

        let summary = recording.markdownSummary ?? "No summary generated."
        let transcript = recording.transcript ?? "No transcript available."

        var calendarYaml = ""
        var meetingContextMarkdown = ""
        if let event = recording.calendarEvent {
            let safeTitle = event.title.replacingOccurrences(of: "\"", with: "\\\"")
            calendarYaml += "\ncalendar_event: \"\(safeTitle)\""
            calendarYaml += "\ncalendar_name: \"\(event.calendarTitle)\""
            if let (locText, _) = event.cleanLocation {
                calendarYaml += "\ncalendar_location: \"\(locText.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            if !event.attendees.isEmpty {
                calendarYaml += "\nattendees:"
                for att in event.attendees {
                    calendarYaml += "\n  - \"\(att.replacingOccurrences(of: "\"", with: "\\\""))\""
                }
            }
            if let agenda = event.cleanNotes {
                let cleanAgenda = agenda.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ")
                calendarYaml += "\ncalendar_agenda: \"\(cleanAgenda)\""
            }

            meetingContextMarkdown = """
            \n> **Meeting:** \(event.title) (\(event.formattedTimeRange))
            """
            if let (displayText, _) = event.cleanLocation {
                meetingContextMarkdown += "\n> **Location:** \(displayText)"
            }
            if !event.attendees.isEmpty {
                let displayAttendees: String
                if event.attendees.count > 5 {
                    displayAttendees = "\(event.attendees.prefix(4).joined(separator: ", ")) (+ \(event.attendees.count - 4) others)"
                } else {
                    displayAttendees = event.attendees.joined(separator: ", ")
                }
                meetingContextMarkdown += "\n> **Attendees:** \(displayAttendees)"
            }
            if let agenda = event.cleanNotes {
                meetingContextMarkdown += "\n> **Agenda:** \(agenda.replacingOccurrences(of: "\n", with: " "))"
            }
            meetingContextMarkdown += "\n"
        }

        return """
        ---
        title: "\(title)"
        date: \(timestamp)
        type: \(typeSlug)
        source_file: "\(recording.displayName)"
        duration: "\(recording.formattedDuration)"
        file_size: "\(recording.formattedFileSize)"\(calendarYaml)
        tags:
          - inbox
          - audio-recording
          - \(typeSlug)
        ---

        # \(title)
        \(meetingContextMarkdown)
        \(summary)

        ---

        <details>
        <summary>Raw Transcript</summary>

        \(transcript)

        </details>
        """
    }

    public func buildMarkdownContent(
        for recording: AudioRecordingFile,
        sessionType: SessionType
    ) -> String {
        buildMarkdownContent(for: recording, typeSlug: sessionType.rawValue, typeTitle: sessionType.title, customTitle: recording.noteTitle)
    }

    public func exportMarkdown(
        for recording: AudioRecordingFile,
        typeSlug: String,
        typeTitle: String,
        allowOverwrite: Bool = false,
        customFilename: String? = nil,
        customTitle: String? = nil
    ) throws -> URL {
        let filename = customFilename ?? defaultFilename(for: recording, typeSlug: typeSlug, title: customTitle ?? recording.noteTitle)
        let targetURL = destinationDirectory.appendingPathComponent(filename)

        if !FileManager.default.fileExists(atPath: destinationDirectory.path) {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        }

        if FileManager.default.fileExists(atPath: targetURL.path) && !allowOverwrite {
            throw MarkdownExportError.fileExists(targetURL)
        }

        let content = buildMarkdownContent(for: recording, typeSlug: typeSlug, typeTitle: typeTitle, customTitle: customTitle)
        try content.write(to: targetURL, atomically: true, encoding: .utf8)
        return targetURL
    }

    public func renameExportedNote(
        for recording: AudioRecordingFile,
        oldURL: URL,
        newFilename: String,
        newContent: String
    ) throws -> URL {
        let newURL = destinationDirectory.appendingPathComponent(newFilename)
        let fm = FileManager.default

        if !fm.fileExists(atPath: destinationDirectory.path) {
            try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        }

        if fm.fileExists(atPath: oldURL.path) {
            if oldURL.standardizedFileURL.path != newURL.standardizedFileURL.path {
                if fm.fileExists(atPath: newURL.path) {
                    try fm.removeItem(at: newURL)
                }
                try fm.moveItem(at: oldURL, to: newURL)
            }
            try newContent.write(to: newURL, atomically: true, encoding: .utf8)
            return newURL
        } else {
            // If the note was already moved out of the inbox, create fresh export copy
            try newContent.write(to: newURL, atomically: true, encoding: .utf8)
            return newURL
        }
    }

    public func exportMarkdown(
        for recording: AudioRecordingFile,
        sessionType: SessionType,
        allowOverwrite: Bool = false,
        customFilename: String? = nil
    ) throws -> URL {
        try exportMarkdown(
            for: recording,
            typeSlug: sessionType.rawValue,
            typeTitle: sessionType.title,
            allowOverwrite: allowOverwrite,
            customFilename: customFilename,
            customTitle: recording.noteTitle
        )
    }

    public func generateNonCollidingURL(for recording: AudioRecordingFile, typeSlug: String) -> URL {
        let baseName = defaultFilename(for: recording, typeSlug: typeSlug, title: recording.noteTitle)
        let ext = (baseName as NSString).pathExtension
        let nameWithoutExt = (baseName as NSString).deletingPathExtension

        var targetURL = destinationDirectory.appendingPathComponent(baseName)
        var counter = 1

        while FileManager.default.fileExists(atPath: targetURL.path) {
            let nextName = "\(nameWithoutExt) (\(counter)).\(ext)"
            targetURL = destinationDirectory.appendingPathComponent(nextName)
            counter += 1
        }

        return targetURL
    }

    public func generateNonCollidingURL(for recording: AudioRecordingFile, sessionType: SessionType) -> URL {
        generateNonCollidingURL(for: recording, typeSlug: sessionType.rawValue)
    }

    public func updateTranscriptInNote(at url: URL, newTranscript: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let existing = try String(contentsOf: url, encoding: .utf8)
        let replacementDetails = """
        <details>
        <summary>Raw Transcript</summary>

        \(newTranscript)

        </details>
        """

        if let detailsRange = existing.range(of: "<details>[\\s\\S]*?<summary>Raw Transcript</summary>[\\s\\S]*?</details>", options: .regularExpression) {
            let updated = existing.replacingCharacters(in: detailsRange, with: replacementDetails)
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } else if let headerRange = existing.range(of: "## Full Audio Transcript[\\s\\S]*", options: .regularExpression) {
            let updated = existing.replacingCharacters(in: headerRange, with: "## Full Audio Transcript\n\n\(newTranscript)")
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } else {
            let updated = "\(existing)\n\n---\n\n\(replacementDetails)\n"
            try updated.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public static func parseMarkdownNote(_ content: String) -> (summary: String?, transcript: String?, title: String?) {
        var transcript: String?
        var summary: String?
        var extractedTitle: String?

        // Extract title from frontmatter
        let lines = content.components(separatedBy: "\n")
        var inFrontmatter = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" {
                if !inFrontmatter {
                    inFrontmatter = true
                } else {
                    break
                }
            } else if inFrontmatter && trimmed.lowercased().hasPrefix("title:") {
                let rawVal = trimmed.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
                extractedTitle = rawVal.trimmingCharacters(in: CharacterSet(charactersIn: "\"\'"))
            }
        }

        if let detailsRange = content.range(of: "<summary>Raw Transcript</summary>") {
            let afterDetails = content[detailsRange.upperBound...]
            if let closingRange = afterDetails.range(of: "</details>") {
                transcript = String(afterDetails[..<closingRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                transcript = String(afterDetails).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if let headerRange = content.range(of: "## Full Audio Transcript") {
            transcript = String(content[headerRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var body = content
        if body.hasPrefix("---") {
            let components = body.components(separatedBy: "---")
            if components.count >= 3 {
                body = components.dropFirst(2).joined(separator: "---")
            }
        }

        if let detailsIndex = body.range(of: "<details>")?.lowerBound {
            body = String(body[..<detailsIndex])
        } else if let headerIndex = body.range(of: "## Full Audio Transcript")?.lowerBound {
            body = String(body[..<headerIndex])
        }

        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleanSummary = cleanBody
        if cleanSummary.hasPrefix("# ") {
            if let lineEnd = cleanSummary.firstIndex(of: "\n") {
                let firstLine = cleanSummary[..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines)
                if extractedTitle == nil {
                    extractedTitle = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                cleanSummary = String(cleanSummary[lineEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                if extractedTitle == nil {
                    extractedTitle = String(cleanSummary.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // If the summary begins with a callout (> **Meeting:** ...), strip the callout block
        if cleanSummary.hasPrefix("> **Meeting:**") {
            let lines = cleanSummary.components(separatedBy: "\n")
            let remaining = lines.drop { $0.hasPrefix(">") || $0.trimmingCharacters(in: .whitespaces).isEmpty }
            cleanSummary = remaining.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else if cleanSummary.hasPrefix("## Meeting Information") {
            // Legacy format with ## Meeting Information ... ---
            if let divider = cleanSummary.range(of: "---") {
                cleanSummary = String(cleanSummary[divider.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        summary = cleanSummary.isEmpty ? nil : cleanSummary

        return (summary: summary, transcript: transcript, title: extractedTitle)
    }
}
