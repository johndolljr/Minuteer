import Foundation

public struct MinuteerVersion: Sendable {
    public static let version = "1.0.0"

    public static func formattedVersion() -> String {
        return "Minuteer v\(version)"
    }
}

// Backward compatibility typealias
public typealias InjestAudioVersion = MinuteerVersion
