import Foundation

public struct CachedRecordingNote: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var audioRelativePath: String
    public var creationDate: Date
    public var duration: TimeInterval
    public var title: String
    public var sessionType: String
    public var calendarEvent: CalendarEventInfo?
    public var transcript: String
    public var markdownSummary: String
    public var inboxExportURL: URL?
    public var lastExportedAt: Date?
    public var classificationConfidence: Double?
    public var calendarMatchConfidence: Double?

    public init(
        id: UUID = UUID(),
        audioRelativePath: String,
        creationDate: Date,
        duration: TimeInterval = 0,
        title: String,
        sessionType: String,
        calendarEvent: CalendarEventInfo? = nil,
        transcript: String,
        markdownSummary: String,
        inboxExportURL: URL? = nil,
        lastExportedAt: Date? = nil,
        classificationConfidence: Double? = nil,
        calendarMatchConfidence: Double? = nil
    ) {
        self.id = id
        self.audioRelativePath = audioRelativePath
        self.creationDate = creationDate
        self.duration = duration
        self.title = title
        self.sessionType = sessionType
        self.calendarEvent = calendarEvent
        self.transcript = transcript
        self.markdownSummary = markdownSummary
        self.inboxExportURL = inboxExportURL
        self.lastExportedAt = lastExportedAt
        self.classificationConfidence = classificationConfidence
        self.calendarMatchConfidence = calendarMatchConfidence
    }
}

public final class NoteCacheStore: @unchecked Sendable {
    public let cacheDirectory: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.ragingcoders.NoteCacheStore", qos: .utility)

    public init(cacheDirectory: URL? = nil, fileManager: FileManager = .default, appSupportDirectory: URL? = nil) {
        self.fileManager = fileManager
        if let dir = cacheDirectory {
            self.cacheDirectory = dir
        } else {
            let appSupport = appSupportDirectory ?? (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            self.cacheDirectory = appSupport
                .appendingPathComponent("Minuteer", isDirectory: true)
                .appendingPathComponent("Cache", isDirectory: true)
                .appendingPathComponent("Notes", isDirectory: true)
            if !fileManager.fileExists(atPath: self.cacheDirectory.path) {
                let legacyCache = appSupport.appendingPathComponent("InjestAudio/Cache/Notes", isDirectory: true)
                if fileManager.fileExists(atPath: legacyCache.path) {
                    try? fileManager.createDirectory(at: self.cacheDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fileManager.copyItem(at: legacyCache, to: self.cacheDirectory)
                }
            }
        }

        try? fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    private func cacheFileURL(for key: String) -> URL {
        let safeName = key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return cacheDirectory.appendingPathComponent("\(safeName).json")
    }

    public func save(_ note: CachedRecordingNote) throws {
        try queue.sync {
            let fileURL = cacheFileURL(for: note.audioRelativePath)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(note)
            try data.write(to: fileURL, options: .atomic)
        }
    }

    public func load(audioRelativePath: String) -> CachedRecordingNote? {
        queue.sync {
            let fileURL = cacheFileURL(for: audioRelativePath)
            guard fileManager.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL) else {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(CachedRecordingNote.self, from: data)
        }
    }

    public func allNotes() -> [CachedRecordingNote] {
        queue.sync {
            guard let files = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
                return []
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var notes: [CachedRecordingNote] = []
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let note = try? decoder.decode(CachedRecordingNote.self, from: data) {
                    notes.append(note)
                }
            }
            return notes
        }
    }

    public func delete(audioRelativePath: String) {
        queue.sync {
            let fileURL = cacheFileURL(for: audioRelativePath)
            try? fileManager.removeItem(at: fileURL)
        }
    }

    public func clearAll() {
        queue.sync {
            guard let files = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
                return
            }
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
