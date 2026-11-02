import Foundation

/// Represents a selectable audio source for meeting and audio recording.
public struct AudioSourceDescriptor: Identifiable, Hashable, Equatable, Sendable, Codable {
    public enum Kind: String, Hashable, Equatable, Sendable, Codable {
        case microphone
        case runningApplication
        case systemAudio
    }

    public let id: String
    public let kind: Kind
    public let displayName: String
    public let bundleIdentifier: String?
    public let processIdentifier: Int32?

    public init(
        id: String,
        kind: Kind,
        displayName: String,
        bundleIdentifier: String? = nil,
        processIdentifier: Int32? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }

    public static var systemAudio: AudioSourceDescriptor {
        AudioSourceDescriptor(
            id: "system_audio",
            kind: .systemAudio,
            displayName: "System Audio (All Sounds)"
        )
    }

    public static func microphone(id: String, name: String) -> AudioSourceDescriptor {
        AudioSourceDescriptor(
            id: "mic_\(id)",
            kind: .microphone,
            displayName: name
        )
    }

    public static func application(bundleID: String, pid: pid_t, name: String) -> AudioSourceDescriptor {
        AudioSourceDescriptor(
            id: "app_\(bundleID)_\(pid)",
            kind: .runningApplication,
            displayName: name,
            bundleIdentifier: bundleID,
            processIdentifier: pid
        )
    }

    public var iconSystemName: String {
        switch kind {
        case .microphone:
            return "mic.fill"
        case .runningApplication:
            return "app.badge"
        case .systemAudio:
            return "speaker.wave.3.fill"
        }
    }
}
