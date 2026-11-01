import Foundation

public struct HistoryRecord: Codable, Equatable, Sendable {
    public let fileName: String
    public let fileSize: Int64
    public let creationDate: Date
    public let exportPath: String?
    public let processedAt: Date
    public var sessionType: String?

    public init(
        fileName: String,
        fileSize: Int64,
        creationDate: Date,
        exportPath: String?,
        processedAt: Date = Date(),
        sessionType: String? = nil
    ) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.creationDate = creationDate
        self.exportPath = exportPath
        self.processedAt = processedAt
        self.sessionType = sessionType
    }
}

public final class HistoryLedger: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    private var records: [String: HistoryRecord] = [:]

    public init(fileURL: URL? = nil, appSupportDirectory: URL? = nil) {
        if let fileURL = fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = appSupportDirectory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "/tmp"))
            let appDir = appSupport.appendingPathComponent("Minuteer", isDirectory: true)
            self.fileURL = appDir.appendingPathComponent("history.json")
            if !FileManager.default.fileExists(atPath: self.fileURL.path) {
                let legacy = appSupport.appendingPathComponent("InjestAudio/history.json")
                if FileManager.default.fileExists(atPath: legacy.path) {
                    try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
                    try? FileManager.default.copyItem(at: legacy, to: self.fileURL)
                }
            }
        }
        load()
    }

    public func recordKey(for file: AudioRecordingFile) -> String {
        return "\(file.url.lastPathComponent)-\(file.fileSize)-\(Int(file.creationDate.timeIntervalSince1970))"
    }

    public func isProcessed(file: AudioRecordingFile) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return records[recordKey(for: file)] != nil
    }

    public func getRecord(for file: AudioRecordingFile) -> HistoryRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records[recordKey(for: file)]
    }

    public func markProcessed(file: AudioRecordingFile, exportURL: URL?) throws {
        lock.lock()
        defer { lock.unlock() }
        let record = HistoryRecord(
            fileName: file.url.lastPathComponent,
            fileSize: file.fileSize,
            creationDate: file.creationDate,
            exportPath: exportURL?.path,
            processedAt: Date(),
            sessionType: file.sessionType
        )
        records[recordKey(for: file)] = record
        try saveUnlocked()
    }

    public func removeRecord(for file: AudioRecordingFile) throws {
        lock.lock()
        defer { lock.unlock() }
        records.removeValue(forKey: recordKey(for: file))
        try saveUnlocked()
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll()
        try saveUnlocked()
    }

    public var allRecords: [HistoryRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(records.values)
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([String: HistoryRecord].self, from: data)
            lock.lock()
            self.records = decoded
            lock.unlock()
        } catch {
            lock.lock()
            self.records = [:]
            lock.unlock()
        }
    }

    private func saveUnlocked() throws {
        let parentDir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder().encode(records)
        try data.write(to: fileURL, options: .atomic)
    }
}
