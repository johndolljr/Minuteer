import Foundation

public enum IngestionStatus: String, Sendable, CaseIterable {
    case discovered = "Discovered"
    case transcribing = "Transcribing"
    case transcribed = "Transcribed"
    case summarizing = "Summarizing"
    case completed = "Completed"
    case failed = "Failed"
}

public struct AudioRecordingFile: Identifiable, Sendable, Hashable {
    public let id: UUID
    public var url: URL
    public let filename: String
    public let displayName: String
    public let fileSize: Int64
    public let creationDate: Date
    public var duration: TimeInterval
    public var status: IngestionStatus
    public var transcriptionProgress: Double
    public var sessionType: String?
    public var noteTitle: String?
    public var calendarEvent: CalendarEventInfo?
    public var transcript: String?
    public var markdownSummary: String?
    public var markdownPath: URL?
    public var errorMessage: String?
    public var classificationConfidence: Double?
    public var calendarMatchConfidence: Double?

    public init(
        id: UUID = UUID(),
        url: URL,
        fileSize: Int64 = 0,
        creationDate: Date = Date(),
        duration: TimeInterval = 0,
        status: IngestionStatus = .discovered,
        transcriptionProgress: Double = 0.0,
        sessionType: String? = nil,
        noteTitle: String? = nil,
        calendarEvent: CalendarEventInfo? = nil,
        transcript: String? = nil,
        markdownSummary: String? = nil,
        markdownPath: URL? = nil,
        errorMessage: String? = nil,
        classificationConfidence: Double? = nil,
        calendarMatchConfidence: Double? = nil
    ) {
        self.id = id
        self.url = url
        self.filename = url.lastPathComponent
        self.classificationConfidence = classificationConfidence
        self.calendarMatchConfidence = calendarMatchConfidence
        
        // Use "parentFolder/filename" if parent is not root /Volumes
        let parentName = url.deletingLastPathComponent().lastPathComponent
        if !parentName.isEmpty && parentName != "/" && parentName != "Volumes" && parentName != "P2_SD" {
            self.displayName = "\(parentName)/\(url.lastPathComponent)"
        } else {
            self.displayName = url.lastPathComponent
        }
        
        self.fileSize = fileSize
        self.creationDate = creationDate
        self.duration = duration
        self.status = status
        self.transcriptionProgress = transcriptionProgress
        self.sessionType = sessionType
        self.noteTitle = noteTitle
        self.calendarEvent = calendarEvent
        self.transcript = transcript
        self.markdownSummary = markdownSummary
        self.markdownPath = markdownPath
        self.errorMessage = errorMessage
    }

    public var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    public var formattedDuration: String {
        guard duration > 0 else { return "00:00" }
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: creationDate)
    }

    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: creationDate)
    }
}
