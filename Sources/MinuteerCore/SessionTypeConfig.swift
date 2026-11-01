import Foundation

public struct SessionTypeConfig: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var slug: String
    public var systemInstructions: String

    public init(
        id: UUID = UUID(),
        name: String,
        slug: String,
        systemInstructions: String
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.systemInstructions = systemInstructions
    }

    public static let defaultMeeting = SessionTypeConfig(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        name: "Meeting",
        slug: "meeting",
        systemInstructions: """
        You are an expert meeting recorder and executive summarizer.
        Analyze the audio transcript and generate a structured markdown document with:
        1. Executive Summary: High-level overview of the meeting purpose and outcomes.
        2. Key Decisions: Explicit decisions agreed upon by participants.
        3. Action Items: Clear tasks formatted as '- [ ] Task (Owner, Deadline if mentioned)'.
        4. Important Discussion Points: Key debates, technical or business rationale, and context.
        5. Open Questions & Next Steps: Unresolved items that need follow-up.

        Keep formatting clean, concise, and professional.
        """
    )

    public static let defaultTherapy = SessionTypeConfig(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        name: "Therapy",
        slug: "therapy",
        systemInstructions: """
        You are a compassionate, thoughtful, and private therapeutic reflection assistant.
        Analyze the session audio transcript and generate a structured reflective summary with:
        1. Core Themes: Main emotional topics, relational patterns, and concerns explored.
        2. Emotional State & Tone: Affect, mood, shifts in energy, and felt sense during the session.
        3. Breakthrough Moments & Insights: Key realizations, reframes, or moments of clarity.
        4. Coping Strategies & Tools Discussed: Techniques, mindfulness exercises, or homework mentioned.
        5. Reflections & Forward Intentions: Long-term growth themes and areas to reflect on before the next session.

        Maintain an empathetic, non-judgmental, and constructive tone. Protect confidentiality and focus on insight.
        """
    )

    public var glyph: String {
        Self.glyph(for: slug)
    }

    public static func glyph(for slug: String) -> String {
        let clean = slug.lowercased()
        if clean.contains("therapy") || clean.contains("counseling") {
            return "🌿"
        } else if clean.contains("meeting") || clean.contains("sync") {
            return "👥"
        } else if clean.contains("memo") || clean.contains("note") {
            return "🎙️"
        } else if clean.contains("brief") || clean.contains("exec") {
            return "📊"
        } else if clean.contains("spec") || clean.contains("tech") {
            return "⚙️"
        } else {
            return "💡"
        }
    }

    public static let defaultCustom = SessionTypeConfig(
        id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        name: "Custom",
        slug: "custom",
        systemInstructions: """
        You are an intelligent note assistant.
        Analyze the audio transcript and provide a clear, concise summary with:
        1. Summary Highlights: 3 to 5 key takeaway points.
        2. Key Context & Details: Main facts, topics discussed, and notable statements.
        3. Outcomes & Next Steps: Any actions or conclusions reached.
        """
    )

    public static var defaultList: [SessionTypeConfig] {
        [defaultMeeting, defaultTherapy]
    }
}

public enum SummarizerProvider: String, Codable, Sendable, CaseIterable {
    case appleIntelligence = "appleIntelligence"
    case openAICompatible = "openAICompatible"

    public var displayName: String {
        switch self {
        case .appleIntelligence:
            return "Apple Intelligence (On-Device)"
        case .openAICompatible:
            return "OpenAI-Compatible LLM (BYO Endpoint)"
        }
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var targetVolumeName: String
    public var exportDirectoryPath: String
    public var audioLibraryDirectoryPath: String
    public var watchDirectoryPath: String
    public var watchDirectoryEnabled: Bool
    public var deleteFromSourceAfterCopy: Bool
    public var autoProcessOnInsert: Bool
    public var selectedSessionTypeID: UUID
    public var sessionTypes: [SessionTypeConfig]
    public var whisperModelName: String
    public var summarizerProvider: SummarizerProvider
    public var openAIEndpoint: String
    public var openAIModelName: String
    public var openAIApiKey: String
    public var autoMatchCalendarEvents: Bool

    public static var defaultAudioLibraryDirectory: String {
        (FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Music"))
            .appendingPathComponent("Minuteer").path
    }

    public static var defaultExportDirectory: String {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Documents"))
            .appendingPathComponent("Minuteer/Inbox").path
    }

    public init(
        targetVolumeName: String = "P2_SD",
        exportDirectoryPath: String = AppConfig.defaultExportDirectory,
        audioLibraryDirectoryPath: String = AppConfig.defaultAudioLibraryDirectory,
        watchDirectoryPath: String = "",
        watchDirectoryEnabled: Bool = false,
        deleteFromSourceAfterCopy: Bool = true,
        autoProcessOnInsert: Bool = true,
        selectedSessionTypeID: UUID = SessionTypeConfig.defaultMeeting.id,
        sessionTypes: [SessionTypeConfig] = SessionTypeConfig.defaultList,
        whisperModelName: String = "openai_whisper-base",
        summarizerProvider: SummarizerProvider = .appleIntelligence,
        openAIEndpoint: String = "https://api.openai.com/v1",
        openAIModelName: String = "gpt-4o-mini",
        openAIApiKey: String = "",
        autoMatchCalendarEvents: Bool = true
    ) {
        self.targetVolumeName = targetVolumeName
        self.exportDirectoryPath = exportDirectoryPath
        self.audioLibraryDirectoryPath = audioLibraryDirectoryPath
        self.watchDirectoryPath = watchDirectoryPath
        self.watchDirectoryEnabled = watchDirectoryEnabled
        self.deleteFromSourceAfterCopy = deleteFromSourceAfterCopy
        self.autoProcessOnInsert = autoProcessOnInsert
        self.selectedSessionTypeID = selectedSessionTypeID
        self.sessionTypes = sessionTypes
        self.whisperModelName = whisperModelName
        self.summarizerProvider = summarizerProvider
        self.openAIEndpoint = openAIEndpoint
        self.openAIModelName = openAIModelName
        self.openAIApiKey = openAIApiKey
        self.autoMatchCalendarEvents = autoMatchCalendarEvents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.targetVolumeName = try container.decode(String.self, forKey: .targetVolumeName)
        if let exportPath = try container.decodeIfPresent(String.self, forKey: .exportDirectoryPath) {
            self.exportDirectoryPath = exportPath
        } else {
            self.exportDirectoryPath = AppConfig.defaultExportDirectory
        }
        if let audioLib = try container.decodeIfPresent(String.self, forKey: .audioLibraryDirectoryPath) {
            self.audioLibraryDirectoryPath = audioLib
        } else {
            self.audioLibraryDirectoryPath = AppConfig.defaultAudioLibraryDirectory
        }
        if let watchDir = try container.decodeIfPresent(String.self, forKey: .watchDirectoryPath) {
            self.watchDirectoryPath = watchDir
        } else {
            self.watchDirectoryPath = ""
        }
        if let watchEnabled = try container.decodeIfPresent(Bool.self, forKey: .watchDirectoryEnabled) {
            self.watchDirectoryEnabled = watchEnabled
        } else {
            self.watchDirectoryEnabled = false
        }
        if let deleteSource = try container.decodeIfPresent(Bool.self, forKey: .deleteFromSourceAfterCopy) {
            self.deleteFromSourceAfterCopy = deleteSource
        } else {
            self.deleteFromSourceAfterCopy = true
        }
        self.autoProcessOnInsert = try container.decode(Bool.self, forKey: .autoProcessOnInsert)
        self.selectedSessionTypeID = try container.decode(UUID.self, forKey: .selectedSessionTypeID)
        self.sessionTypes = try container.decode([SessionTypeConfig].self, forKey: .sessionTypes)
        if let model = try container.decodeIfPresent(String.self, forKey: .whisperModelName) {
            self.whisperModelName = model
        } else {
            self.whisperModelName = "openai_whisper-base"
        }
        if let providerStr = try container.decodeIfPresent(String.self, forKey: .summarizerProvider),
           let provider = SummarizerProvider(rawValue: providerStr) {
            self.summarizerProvider = provider
        } else {
            self.summarizerProvider = .appleIntelligence
        }
        if let endpoint = try container.decodeIfPresent(String.self, forKey: .openAIEndpoint) {
            self.openAIEndpoint = endpoint
        } else {
            self.openAIEndpoint = "https://api.openai.com/v1"
        }
        if let modelName = try container.decodeIfPresent(String.self, forKey: .openAIModelName) {
            self.openAIModelName = modelName
        } else {
            self.openAIModelName = "gpt-4o-mini"
        }
        if let apiKey = try container.decodeIfPresent(String.self, forKey: .openAIApiKey) {
            self.openAIApiKey = apiKey
        } else {
            self.openAIApiKey = ""
        }
        if let autoMatch = try container.decodeIfPresent(Bool.self, forKey: .autoMatchCalendarEvents) {
            self.autoMatchCalendarEvents = autoMatch
        } else {
            self.autoMatchCalendarEvents = true
        }
    }
}

public final class AppConfigStorage: @unchecked Sendable {
    public static let shared = AppConfigStorage()
    public let configFileURL: URL
    private let lock = NSLock()
    private var cachedConfig: AppConfig

    public init(configFileURL: URL? = nil, appSupportDirectory: URL? = nil) {
        if let file = configFileURL {
            self.configFileURL = file
        } else {
            let appSupport = appSupportDirectory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "/tmp"))
            let appDir = appSupport.appendingPathComponent("Minuteer", isDirectory: true)
            self.configFileURL = appDir.appendingPathComponent("config.json")
            if !FileManager.default.fileExists(atPath: self.configFileURL.path) {
                let legacyFile = appSupport.appendingPathComponent("InjestAudio/config.json")
                if FileManager.default.fileExists(atPath: legacyFile.path) {
                    try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
                    try? FileManager.default.copyItem(at: legacyFile, to: self.configFileURL)
                }
            }
        }

        var loaded: AppConfig?
        if FileManager.default.fileExists(atPath: self.configFileURL.path) {
            if let data = try? Data(contentsOf: self.configFileURL),
               let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
                loaded = decoded
            }
        }
        self.cachedConfig = loaded ?? AppConfig()
    }

    public func load() -> AppConfig {
        lock.lock()
        defer { lock.unlock() }
        return cachedConfig
    }

    public func save(_ config: AppConfig) throws {
        lock.lock()
        defer { lock.unlock() }
        self.cachedConfig = config

        let parentDir = configFileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder().encode(config)
        try data.write(to: configFileURL, options: .atomic)
    }
}
