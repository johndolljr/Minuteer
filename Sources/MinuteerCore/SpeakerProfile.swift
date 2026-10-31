import Foundation

public struct SpeakerProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var aliases: [String]
    public var contextNotes: String
    public var voiceprint: [Float]?
    public var sampleCount: Int

    public init(
        id: UUID = UUID(),
        name: String,
        aliases: [String] = [],
        contextNotes: String = "",
        voiceprint: [Float]? = nil,
        sampleCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.contextNotes = contextNotes
        self.voiceprint = voiceprint
        self.sampleCount = sampleCount
    }

    enum CodingKeys: String, CodingKey {
        case id, name, aliases, contextNotes, voiceprint, sampleCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        self.contextNotes = try container.decodeIfPresent(String.self, forKey: .contextNotes) ?? ""
        self.voiceprint = try container.decodeIfPresent([Float].self, forKey: .voiceprint)
        self.sampleCount = try container.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 0
    }
}

public final class SpeakerDirectory: @unchecked Sendable {
    public static let shared = SpeakerDirectory()
    public let fileURL: URL
    private let lock = NSLock()
    private var cachedSpeakers: [SpeakerProfile] = []

    public init(fileURL: URL? = nil) {
        if let file = fileURL {
            self.fileURL = file
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "/tmp")
            let appDir = appSupport.appendingPathComponent("Minuteer", isDirectory: true)
            self.fileURL = appDir.appendingPathComponent("speakers.json")
            if !FileManager.default.fileExists(atPath: self.fileURL.path) {
                let legacy = appSupport.appendingPathComponent("InjestAudio/speakers.json")
                if FileManager.default.fileExists(atPath: legacy.path) {
                    try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
                    try? FileManager.default.copyItem(at: legacy, to: self.fileURL)
                }
            }
        }
        load()
    }

    public var allSpeakers: [SpeakerProfile] {
        lock.lock()
        defer { lock.unlock() }
        return cachedSpeakers
    }

    public func addSpeaker(_ speaker: SpeakerProfile) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = cachedSpeakers.firstIndex(where: { $0.id == speaker.id }) {
            cachedSpeakers[idx] = speaker
        } else {
            cachedSpeakers.append(speaker)
        }
        saveUnlocked()
    }

    public func updateSpeaker(_ speaker: SpeakerProfile) {
        addSpeaker(speaker)
    }

    public func deleteSpeaker(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        cachedSpeakers.removeAll { $0.id == id }
        saveUnlocked()
    }

    public func getSpeaker(named name: String) -> SpeakerProfile? {
        lock.lock()
        defer { lock.unlock() }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cachedSpeakers.first { speaker in
            if speaker.name.lowercased() == clean { return true }
            return speaker.aliases.contains { $0.lowercased() == clean }
        }
    }

    /// Incrementally updates or sets the acoustic voiceprint for a speaker profile
    public func updateVoiceprint(forSpeakerNamed name: String, newVoiceprint: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let idx = cachedSpeakers.firstIndex(where: {
            $0.name.lowercased() == clean || $0.aliases.contains(where: { $0.lowercased() == clean })
        }) else { return }

        let current = cachedSpeakers[idx]
        let (updatedPrint, newCount) = AudioFingerprintEngine.updateVoiceprint(
            existing: current.voiceprint,
            sampleCount: current.sampleCount,
            newPrint: newVoiceprint
        )
        cachedSpeakers[idx].voiceprint = updatedPrint
        cachedSpeakers[idx].sampleCount = newCount
        saveUnlocked()
    }

    private func load() {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedSpeakers = []
            return
        }
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([SpeakerProfile].self, from: data) {
            cachedSpeakers = decoded
        } else {
            cachedSpeakers = []
        }
    }

    private func saveUnlocked() {
        let parentDir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        if let data = try? JSONEncoder().encode(cachedSpeakers) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
