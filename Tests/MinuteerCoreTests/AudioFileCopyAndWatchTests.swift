import Testing
import Foundation
@testable import MinuteerCore

@Suite("Audio File Copy & Watch Folder Tests")
struct AudioFileCopyAndWatchTests {

    @Test("AudioRecordingFile formattedTime formatting")
    func testFormattedTime() {
        var comp = DateComponents()
        comp.year = 2026
        comp.month = 10
        comp.day = 31
        comp.hour = 14
        comp.minute = 30
        let date = Calendar.current.date(from: comp) ?? Date()

        let file = AudioRecordingFile(
            url: URL(fileURLWithPath: "/tmp/sample.wav"),
            fileSize: 1024,
            creationDate: date
        )
        #expect(!file.formattedTime.isEmpty)
        #expect(file.formattedTime.contains(":") || file.formattedTime.contains("2"))
    }

    @Test("AudioFileCopyService SHA256 checksum and file size")
    func testChecksumAndFileSize() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test.wav")
        let content = "RIFF\u{24}\u{00}\u{00}\u{00}WAVEfmt \u{10}\u{00}\u{00}\u{00}\u{01}\u{00}\u{01}\u{00}\u{44}\u{ac}\u{00}\u{00}\u{88}\u{58}\u{01}\u{00}\u{02}\u{00}\u{10}\u{00}data\u{00}\u{00}\u{00}\u{00}"
        try content.write(to: testFile, atomically: true, encoding: .utf8)

        let size = AudioFileCopyService.fileSize(at: testFile)
        #expect(size > 0)

        let hash = try AudioFileCopyService.computeSHA256(for: testFile)
        #expect(!hash.isEmpty)
        #expect(hash.count == 64)

        // Non-existent file returns -1 size
        let missing = tempDir.appendingPathComponent("missing.wav")
        #expect(AudioFileCopyService.fileSize(at: missing) == -1)
    }

    @Test("AudioFileCopyService copy and verify with source deletion")
    func testCopyAndVerifySuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDir = root.appendingPathComponent("SourceSD")
        let destDir = root.appendingPathComponent("LocalLibrary")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceFile = sourceDir.appendingPathComponent("REC001.WAV")
        let testData = Data(repeating: 0x42, count: 4096)
        try testData.write(to: sourceFile)

        let service = AudioFileCopyService()
        let resultURL = try service.copyAndVerify(
            sourceURL: sourceFile,
            destinationDirectory: destDir,
            deleteSourceAfterVerification: true
        )

        // Destination exists and matches size
        #expect(FileManager.default.fileExists(atPath: resultURL.path))
        #expect(AudioFileCopyService.fileSize(at: resultURL) == 4096)

        // Source file was verified and removed
        #expect(!FileManager.default.fileExists(atPath: sourceFile.path))
    }

    @Test("AudioFileCopyService copy without source deletion")
    func testCopyWithoutSourceDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDir = root.appendingPathComponent("SourceSD")
        let destDir = root.appendingPathComponent("LocalLibrary")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceFile = sourceDir.appendingPathComponent("REC002.WAV")
        let testData = Data(repeating: 0x99, count: 2048)
        try testData.write(to: sourceFile)

        let service = AudioFileCopyService()
        let resultURL = try service.copyAndVerify(
            sourceURL: sourceFile,
            destinationDirectory: destDir,
            deleteSourceAfterVerification: false
        )

        #expect(FileManager.default.fileExists(atPath: resultURL.path))
        #expect(FileManager.default.fileExists(atPath: sourceFile.path))
    }

    @Test("AudioFileCopyService destination collision handling")
    func testCollisionHandling() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDir = root.appendingPathComponent("SourceSD")
        let destDir = root.appendingPathComponent("LocalLibrary")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Existing file at destination with different content
        let existingDest = destDir.appendingPathComponent("REC003.WAV")
        try Data(repeating: 0x11, count: 1024).write(to: existingDest)

        // Source file with same name but different content
        let sourceFile = sourceDir.appendingPathComponent("REC003.WAV")
        try Data(repeating: 0x22, count: 2048).write(to: sourceFile)

        let service = AudioFileCopyService()
        let resultURL = try service.copyAndVerify(
            sourceURL: sourceFile,
            destinationDirectory: destDir,
            deleteSourceAfterVerification: true
        )

        #expect(FileManager.default.fileExists(atPath: resultURL.path))
        #expect(resultURL.path != existingDest.path)
        #expect(AudioFileCopyService.fileSize(at: resultURL) == 2048)
        #expect(AudioFileCopyService.fileSize(at: existingDest) == 1024)
    }

    @Test("AudioFileCopyError errorDescription coverage")
    func testAudioFileCopyErrorDescriptions() {
        let dummyURL = URL(fileURLWithPath: "/tmp/sample.wav")
        let errs: [AudioFileCopyError] = [
            .sourceNotFound(dummyURL),
            .sourceNotReadable(dummyURL),
            .destinationDirectoryCreationFailed(dummyURL),
            .copyFailed("disk full"),
            .verificationFailed("hash mismatch"),
            .sourceDeletionFailed("permission denied")
        ]

        for err in errs {
            #expect(err.errorDescription != nil)
            #expect(!err.errorDescription!.isEmpty)
        }
    }

    @Test("AudioFileCopyService missing source error")
    func testMissingSourceError() {
        let service = AudioFileCopyService()
        let missing = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).wav")
        let dest = FileManager.default.temporaryDirectory

        #expect(throws: AudioFileCopyError.self) {
            try service.copyAndVerify(sourceURL: missing, destinationDirectory: dest)
        }
        #expect(AudioFileCopyService.fileSize(at: missing) == -1)
    }

    @Test("AudioFileCopyService already copied and verified path and directory creation failure")
    func testAlreadyCopiedAndVerified() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDir = root.appendingPathComponent("Source")
        let destDir = root.appendingPathComponent("Dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceFile = sourceDir.appendingPathComponent("already_done.wav")
        let data = Data(repeating: 0x55, count: 512)
        try data.write(to: sourceFile)

        let service = AudioFileCopyService()
        // First copy (without source deletion)
        let first = try service.copyAndVerify(sourceURL: sourceFile, destinationDirectory: destDir, deleteSourceAfterVerification: false)
        #expect(FileManager.default.fileExists(atPath: first.path))

        // Second copy with identical destination file already existing (exercises already verified path)
        let second = try service.copyAndVerify(sourceURL: sourceFile, destinationDirectory: destDir, deleteSourceAfterVerification: false)
        #expect(second.path == first.path)

        // Test destination generation with identical hash
        let destGenSame = AudioFileCopyService.generateDestinationURL(sourceURL: sourceFile, destinationDirectory: destDir)
        #expect(destGenSame.path == first.path)

        // Test destination generation for file without extension
        let noExtSource = sourceDir.appendingPathComponent("no_ext_file")
        try Data("no ext".utf8).write(to: noExtSource)
        let noExtDest = destDir.appendingPathComponent("no_ext_file")
        try Data("existing diff".utf8).write(to: noExtDest)
        let destGenNoExt = AudioFileCopyService.generateDestinationURL(sourceURL: noExtSource, destinationDirectory: destDir)
        #expect(destGenNoExt.path != noExtDest.path)

        // Test destination directory creation failure
        let impossibleDest = URL(fileURLWithPath: "/dev/null/impossible_dir")
        #expect(throws: AudioFileCopyError.self) {
            try service.copyAndVerify(sourceURL: sourceFile, destinationDirectory: impossibleDest, deleteSourceAfterVerification: false)
        }
    }

    final class DiscoveredBox: @unchecked Sendable {
        var urls: [URL] = []
    }

    @Test("WatchFolderMonitor lifecycle and file discovery")
    func testWatchFolderMonitor() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let monitor = WatchFolderMonitor(watchDirectoryURL: tempDir, isEnabled: false)
        #expect(monitor.watchDirectoryURL?.path == tempDir.path)
        #expect(!monitor.isEnabled)

        let box = DiscoveredBox()
        monitor.onFilesDiscovered = { urls in
            box.urls = urls
        }

        monitor.isEnabled = true
        #expect(monitor.isEnabled)

        // Add a valid audio file
        let audioFile = tempDir.appendingPathComponent("incoming.wav")
        try Data(repeating: 0x33, count: 1024).write(to: audioFile)

        // Add an incomplete / temporary file (should be ignored)
        let tempFile = tempDir.appendingPathComponent("incoming.wav.download")
        try Data(repeating: 0x00, count: 512).write(to: tempFile)
        let tmpFile = tempDir.appendingPathComponent("incoming.tmp")
        try Data("tmp".utf8).write(to: tmpFile)
        let crFile = tempDir.appendingPathComponent("incoming.crdownload")
        try Data("cr".utf8).write(to: crFile)
        let zeroByteFile = tempDir.appendingPathComponent("zero.wav")
        try Data().write(to: zeroByteFile)

        monitor.scanWatchedDirectory()

        #expect(box.urls.contains(where: { $0.lastPathComponent == "incoming.wav" }))
        #expect(!box.urls.contains(where: { $0.lastPathComponent.contains(".download") }))
        #expect(!box.urls.contains(where: { $0.lastPathComponent.contains(".tmp") }))
        #expect(!box.urls.contains(where: { $0.lastPathComponent.contains(".crdownload") }))
        #expect(!box.urls.contains(where: { $0.lastPathComponent == "zero.wav" }))

        monitor.stopMonitoring()
        #expect(!monitor.isEnabled)

        // Test init with enabled: true
        let monitor2 = WatchFolderMonitor(watchDirectoryURL: tempDir, isEnabled: true)
        #expect(monitor2.isEnabled)

        // Test updating watchDirectoryURL while running triggers restartMonitoring
        let tempDir2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir2, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir2) }

        monitor2.watchDirectoryURL = tempDir2
        #expect(monitor2.watchDirectoryURL?.path == tempDir2.path)

        // Test disabling via isEnabled property setter
        monitor2.isEnabled = false
        #expect(!monitor2.isEnabled)

        // Test scan with nil URL and non-existent URL
        let emptyMonitor = WatchFolderMonitor()
        emptyMonitor.scanWatchedDirectory()
        emptyMonitor.watchDirectoryURL = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString)")
        emptyMonitor.scanWatchedDirectory()
    }

    @Test("IngestionCoordinator scanLocalLibrary and watch directory integration")
    @MainActor
    func testCoordinatorLibraryAndWatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let localLib = root.appendingPathComponent("Library")
        let watchDir = root.appendingPathComponent("Watch")
        let sdDir = root.appendingPathComponent("SD")
        let inboxDir = root.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: localLib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: watchDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sdDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Place a file in local library
        let libFile = localLib.appendingPathComponent("meeting_archive.wav")
        try makeValidWAVData(durationSeconds: 0.5).write(to: libFile)

        // Place a file in watch folder
        let watchFile = watchDir.appendingPathComponent("incoming_audio.wav")
        try makeValidWAVData(durationSeconds: 0.5).write(to: watchFile)

        let mockTranscriber = MockTranscriptionEngine(mockTranscript: "Transcribed audio")
        let mockSummarizer = AppleIntelligenceSummarizer(sessionRunner: { _ in "## Executive Summary\nKey points" })
        let sdMonitor = SDCardMonitor(targetVolumeName: "TEST_SD")

        let coordinator = IngestionCoordinator(
            sdCardMonitor: sdMonitor,
            transcriptionEngine: mockTranscriber,
            summarizerEngine: mockSummarizer,
            markdownExporter: MarkdownExporter(destinationDirectory: inboxDir),
            audioLibraryDirectory: localLib,
            watchFolderMonitor: WatchFolderMonitor(watchDirectoryURL: watchDir, isEnabled: true),
            deleteFromSourceAfterCopy: true,
            autoProcessOnInsert: false
        )

        // 1. Scan local library
        let localFiles = await coordinator.scanLocalLibrary()
        #expect(localFiles.contains(where: { $0.displayName.contains("meeting_archive") }))

        // Test mergeDiscoveredFiles when an entry is already completed
        var completedEntry = localFiles[0]
        completedEntry.status = .completed
        completedEntry.noteTitle = nil
        coordinator.mergeDiscoveredFiles([completedEntry])

        // Test copyAndVerify when target file already exists with identical hash
        let duplicateCopyService = AudioFileCopyService()
        let reCopied = try duplicateCopyService.copyAndVerify(
            sourceURL: libFile,
            destinationDirectory: localLib,
            deleteSourceAfterVerification: false
        )
        #expect(reCopied.path == libFile.path)

        // 2. Handle watch directory files
        await coordinator.handleWatchDirectoryFiles([watchFile])
        #expect(coordinator.discoveredFiles.contains(where: { $0.displayName.contains("incoming_audio") }))

        // 3. Process the watched file -> verify it is copied to local library and deleted from watch folder
        let watchedAudioFile = coordinator.discoveredFiles.first(where: { $0.displayName.contains("incoming_audio") })!
        let exportedURL = try await coordinator.processRecording(watchedAudioFile)
        #expect(FileManager.default.fileExists(atPath: exportedURL.path))

        // Original watchFile was deleted from watchDir
        #expect(!FileManager.default.fileExists(atPath: watchFile.path))

        // Copied file is now in localLib
        let localCopiedFile = coordinator.discoveredFiles.first(where: { $0.displayName.contains("incoming_audio") })?.url
        #expect(localCopiedFile != nil)
        #expect(FileManager.default.fileExists(atPath: localCopiedFile!.path))

        // Handle empty watch files guard
        await coordinator.handleWatchDirectoryFiles([])

        // Test handleWatchDirectoryFiles with autoProcessOnInsert: true
        coordinator.autoProcessOnInsert = true
        let watchFile2 = watchDir.appendingPathComponent("incoming2.wav")
        try makeValidWAVData(durationSeconds: 0.5).write(to: watchFile2)
        await coordinator.handleWatchDirectoryFiles([watchFile2])

        // Re-scan local library
        let secondScan = await coordinator.scanLocalLibrary()
        #expect(secondScan.count >= 1)

        // 4. Test deleteRecording for local cached audio
        if let toDelete = coordinator.discoveredFiles.first(where: { $0.displayName.contains("incoming_audio") }) {
            try coordinator.deleteRecording(toDelete)
            #expect(!FileManager.default.fileExists(atPath: toDelete.url.path))
            #expect(!coordinator.discoveredFiles.contains(where: { $0.id == toDelete.id }))
        }

        // Stop monitoring
        coordinator.stopMonitoring()
    }
}
