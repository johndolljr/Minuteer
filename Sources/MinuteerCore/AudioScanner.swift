import Foundation
import AVFoundation

public final class AudioScanner: Sendable {
    public static let supportedExtensions: Set<String> = [
        "wav", "wave", "mp3", "m4a", "aac", "flac", "aif", "aiff"
    ]

    public static let ignoredDirectories: Set<String> = [
        ".spotlight-v100", ".trashes", ".fseventsd", ".temporaryitems", ".documentrevisions-v100"
    ]

    public init() {}

    public func isAudioFile(url: URL) -> Bool {
        let filename = url.lastPathComponent
        // Skip hidden files or AppleDouble files (._*)
        if filename.hasPrefix(".") {
            return false
        }
        let ext = url.pathExtension.lowercased()
        return Self.supportedExtensions.contains(ext)
    }

    public func scanDirectory(at rootURL: URL, readDurations: Bool = false) -> [AudioRecordingFile] {
        var results: [AudioRecordingFile] = []
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            let lastComponent = fileURL.lastPathComponent.lowercased()

            // Skip ignored directories
            if Self.ignoredDirectories.contains(lastComponent) {
                enumerator.skipDescendants()
                continue
            }

            // Skip hidden directories and hidden files
            if fileURL.lastPathComponent.hasPrefix(".") {
                continue
            }

            // Check if it's a directory
            var isDirectory: AnyObject?
            try? (fileURL as NSURL).getResourceValue(&isDirectory, forKey: .isDirectoryKey)
            if let isDir = isDirectory as? Bool, isDir {
                continue
            }

            if isAudioFile(url: fileURL) {
                var size: Int64 = 0
                var creationDate = Date()
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]) {
                    if let s = resourceValues.fileSize {
                        size = Int64(s)
                    }
                    if let d = resourceValues.creationDate {
                        creationDate = d
                    }
                }

                var duration: TimeInterval = 0
                if readDurations {
                    if let player = try? AVAudioPlayer(contentsOf: fileURL) {
                        duration = player.duration
                    }
                }

                let recording = AudioRecordingFile(
                    url: fileURL,
                    fileSize: size,
                    creationDate: creationDate,
                    duration: duration,
                    status: .discovered
                )
                results.append(recording)
            }
        }

        // Sort descending by creation date (newest first)
        results.sort { $0.creationDate > $1.creationDate }
        return results
    }

    public func scanDirectoryAsync(at rootURL: URL) async -> [AudioRecordingFile] {
        var files = scanDirectory(at: rootURL, readDurations: false)
        for i in 0..<files.count {
            let url = files[i].url
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(duration)
                if seconds > 0 && !seconds.isNaN && !seconds.isInfinite {
                    files[i].duration = seconds
                } else {
                    files[i].duration = 0
                }
            }
        }
        return files
    }

    public static func loadDuration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds > 0 && !seconds.isNaN && !seconds.isInfinite {
                return seconds
            }
        }
        return 0
    }
}
