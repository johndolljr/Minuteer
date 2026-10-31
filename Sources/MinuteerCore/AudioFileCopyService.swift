import Foundation
import CryptoKit

public enum AudioFileCopyError: LocalizedError, Sendable {
    case sourceNotFound(URL)
    case sourceNotReadable(URL)
    case destinationDirectoryCreationFailed(URL)
    case copyFailed(String)
    case verificationFailed(String)
    case sourceDeletionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let url):
            return "Source audio file not found at \(url.path)"
        case .sourceNotReadable(let url):
            return "Unable to read source audio file at \(url.path)"
        case .destinationDirectoryCreationFailed(let url):
            return "Failed to create destination audio directory at \(url.path)"
        case .copyFailed(let reason):
            return "Failed to copy audio file: \(reason)"
        case .verificationFailed(let reason):
            return "Audio file verification failed: \(reason)"
        case .sourceDeletionFailed(let reason):
            return "Failed to delete source file after verified copy: \(reason)"
        }
    }
}

public struct AudioFileCopyService: Sendable {
    public init() {}

    public static func computeSHA256(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 1024 * 1024)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    public static func fileSize(at url: URL) -> Int64 {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber {
            return size.int64Value
        }
        return -1
    }

    public static func generateDestinationURL(
        sourceURL: URL,
        destinationDirectory: URL,
        relativePath: String? = nil
    ) -> URL {
        let rel = relativePath ?? sourceURL.lastPathComponent
        let targetURL = destinationDirectory.appendingPathComponent(rel)
        let parentDir = targetURL.deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: targetURL.path) {
            return targetURL
        }

        // Check if existing file has identical hash
        if let srcHash = try? computeSHA256(for: sourceURL),
           let dstHash = try? computeSHA256(for: targetURL),
           srcHash == dstHash {
            return targetURL
        }

        // Generate non-colliding timestamped name
        let ext = sourceURL.pathExtension
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let newName = ext.isEmpty ? "\(base)_\(timestamp)" : "\(base)_\(timestamp).\(ext)"
        return parentDir.appendingPathComponent(newName)
    }

    @discardableResult
    public func copyAndVerify(
        sourceURL: URL,
        destinationDirectory: URL,
        deleteSourceAfterVerification: Bool = true,
        relativePath: String? = nil
    ) throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw AudioFileCopyError.sourceNotFound(sourceURL)
        }

        let sourceSize = Self.fileSize(at: sourceURL)
        guard sourceSize >= 0 else {
            throw AudioFileCopyError.sourceNotReadable(sourceURL)
        }

        let sourceHash = try Self.computeSHA256(for: sourceURL)

        let targetURL = Self.generateDestinationURL(
            sourceURL: sourceURL,
            destinationDirectory: destinationDirectory,
            relativePath: relativePath
        )
        let targetParent = targetURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: targetParent.path) {
            do {
                try FileManager.default.createDirectory(at: targetParent, withIntermediateDirectories: true)
            } catch {
                throw AudioFileCopyError.destinationDirectoryCreationFailed(targetParent)
            }
        }

        // If target file already exists and matches hash, it's already verified
        var didCopy = false
        if FileManager.default.fileExists(atPath: targetURL.path) {
            let targetSize = Self.fileSize(at: targetURL)
            if let targetHash = try? Self.computeSHA256(for: targetURL),
               targetHash == sourceHash && targetSize == sourceSize {
                // Already copied and verified
                didCopy = false
            } else {
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: targetURL)
                    didCopy = true
                } catch {
                    throw AudioFileCopyError.copyFailed(error.localizedDescription)
                }
            }
        } else {
            do {
                try FileManager.default.copyItem(at: sourceURL, to: targetURL)
                didCopy = true
            } catch {
                throw AudioFileCopyError.copyFailed(error.localizedDescription)
            }
        }

        // Rigorous Verification
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            throw AudioFileCopyError.verificationFailed("Destination file missing after copy.")
        }

        let destSize = Self.fileSize(at: targetURL)
        guard destSize == sourceSize else {
            if didCopy {
                try? FileManager.default.removeItem(at: targetURL)
            }
            throw AudioFileCopyError.verificationFailed("File size mismatch: source=\(sourceSize), dest=\(destSize)")
        }

        let destHash = try Self.computeSHA256(for: targetURL)
        guard destHash == sourceHash else {
            if didCopy {
                try? FileManager.default.removeItem(at: targetURL)
            }
            throw AudioFileCopyError.verificationFailed("Checksum mismatch: source=\(sourceHash), dest=\(destHash)")
        }

        // Verification passed! Only now delete source file if requested
        if deleteSourceAfterVerification && sourceURL.path != targetURL.path {
            do {
                try FileManager.default.removeItem(at: sourceURL)
            } catch {
                throw AudioFileCopyError.sourceDeletionFailed(error.localizedDescription)
            }
        }

        return targetURL
    }
}
