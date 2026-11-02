import Testing
import Foundation
import AppKit
@testable import MinuteerCore

@Suite("SD Card & Audio Scanner Tests")
struct SDCardScannerTests {
    
    @Test("AudioRecordingFile initialization, formatting, and edge cases")
    func testAudioRecordingFileFormatting() {
        let tempURL = URL(fileURLWithPath: "/Volumes/P2_SD/250102_184844/MIX.WAV")
        let date = Date(timeIntervalSince1970: 1735843724) // 2025-01-02
        var file = AudioRecordingFile(
            url: tempURL,
            fileSize: 10_000_000, // 10 MB
            creationDate: date,
            duration: 125.5
        )
        
        #expect(file.filename == "MIX.WAV")
        #expect(file.displayName == "250102_184844/MIX.WAV")
        #expect(file.formattedFileSize == "10 MB")
        #expect(file.formattedDuration == "02:05")
        #expect(file.status == .discovered)

        // Test hours formatting
        file.duration = 3665 // 1h 1m 5s
        #expect(file.formattedDuration == "01:01:05")

        // Test zero duration
        file.duration = 0
        #expect(file.formattedDuration == "00:00")

        // Test root file display name
        let rootFile = AudioRecordingFile(url: URL(fileURLWithPath: "/MIX.WAV"))
        #expect(rootFile.displayName == "MIX.WAV")

        // Test Cases of IngestionStatus
        #expect(IngestionStatus.allCases.contains(.transcribing))
        #expect(IngestionStatus.allCases.contains(.completed))
        #expect(IngestionStatus.allCases.contains(.failed))
    }

    @Test("AudioScanner filters system files and identifies audio files")
    func testAudioScannerFiltering() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // Create audio files in a subfolder (typical Zoom recorder structure)
        let sessionFolder = tempDir.appendingPathComponent("250102_184844")
        try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        let wavFile = sessionFolder.appendingPathComponent("MIX.WAV")
        try makeValidWAVData(durationSeconds: 1.5).write(to: wavFile)

        let wavFile2 = sessionFolder.appendingPathComponent("TRACK2.WAV")
        try makeValidWAVData(durationSeconds: 2.0).write(to: wavFile2)
        
        // Create AppleDouble file that should be ignored
        let appleDouble = sessionFolder.appendingPathComponent("._MIX.WAV")
        try Data("metadata".utf8).write(to: appleDouble)
        
        // Create system folders that should be ignored
        let spotlightDir = tempDir.appendingPathComponent(".Spotlight-V100")
        try FileManager.default.createDirectory(at: spotlightDir, withIntermediateDirectories: true)
        try Data("index".utf8).write(to: spotlightDir.appendingPathComponent("index.db"))
        
        let trashesDir = tempDir.appendingPathComponent(".Trashes")
        try FileManager.default.createDirectory(at: trashesDir, withIntermediateDirectories: true)
        
        // Create a system file like ZOOM_P2.SYS
        let sysFile = tempDir.appendingPathComponent("ZOOM_P2.SYS")
        try Data("sys".utf8).write(to: sysFile)

        // Create a hidden dotfile audio that should be skipped by hasPrefix(".")
        let hiddenWav = tempDir.appendingPathComponent(".hidden.wav")
        try Data("dummy".utf8).write(to: hiddenWav)
        
        // Scanner
        let scanner = AudioScanner()
        #expect(scanner.isAudioFile(url: wavFile))
        #expect(!scanner.isAudioFile(url: appleDouble))
        #expect(!scanner.isAudioFile(url: sysFile))
        #expect(!scanner.isAudioFile(url: tempDir.appendingPathComponent("notes.txt")))

        let results = scanner.scanDirectory(at: tempDir, readDurations: true)
        #expect(results.count == 2)

        // Test async scanner and loadDuration
        let asyncResults = await scanner.scanDirectoryAsync(at: tempDir)
        #expect(asyncResults.count == 2)
        let loadedDuration = await AudioScanner.loadDuration(for: wavFile)
        #expect(loadedDuration >= 0)

        // Test nonexistent directory and loadDuration fallback
        let missingResults = scanner.scanDirectory(at: URL(fileURLWithPath: "/nonexistent/folder/12345"))
        #expect(missingResults.isEmpty)
        let missingDur = await AudioScanner.loadDuration(for: URL(fileURLWithPath: "/nonexistent/folder/12345.wav"))
        #expect(missingDur == 0)
    }

    @Test("SDCardMonitor volume detection with mock volumes")
    func testSDCardMonitorTargetDetection() {
        let monitor = SDCardMonitor(targetVolumeName: "P2_SD")
        
        let p2SDURL = URL(fileURLWithPath: "/Volumes/P2_SD")
        let macHDURL = URL(fileURLWithPath: "/Volumes/Macintosh HD")
        
        #expect(monitor.isTargetVolume(url: p2SDURL, name: "P2_SD"))
        #expect(!monitor.isTargetVolume(url: macHDURL, name: "Macintosh HD"))
        #expect(monitor.isTargetVolume(url: URL(fileURLWithPath: "/Volumes/p2_sd"), name: "p2_sd"))
    }

    @Test("SDCardMonitor lifecycle and current volume scanning")
    func testSDCardMonitorLifecycle() {
        final class StatusBox: @unchecked Sendable {
            var status: SDCardStatus?
        }
        let box = StatusBox()
        let monitor = SDCardMonitor(targetVolumeName: "P2_SD")
        monitor.onStatusChanged = { status in
            box.status = status
        }
        #expect(monitor.onStatusChanged != nil)

        final class CounterBox: @unchecked Sendable {
            var count = 0
        }
        let counter = CounterBox()
        monitor.addObserver { _ in
            counter.count += 1
        }
        monitor.updateStatus(.inserted(volumeURL: URL(fileURLWithPath: "/Volumes/P2_SD"), freeBytes: 1000, totalBytes: 2000))
        #expect(counter.count == 1)
        #expect(box.status != nil)

        // Duplicate update is ignored
        monitor.updateStatus(.inserted(volumeURL: URL(fileURLWithPath: "/Volumes/P2_SD"), freeBytes: 1000, totalBytes: 2000))
        #expect(counter.count == 1)

        // Test missing volume branch
        let missingMonitor = SDCardMonitor(targetVolumeName: "NONEXISTENT_VOLUME_XYZ")
        missingMonitor.startMonitoring()
        missingMonitor.checkCurrentVolumes()
        #expect(missingMonitor.currentStatus == .notInserted)
        missingMonitor.stopMonitoring()
    }

    @Test("SDCardMonitor delete safety checks")
    func testSDCardMonitorDeleteSafety() throws {
        let monitor = SDCardMonitor(targetVolumeName: "P2_SD")
        let dummyFile = AudioRecordingFile(url: URL(fileURLWithPath: "/Volumes/P2_SD/MIX.WAV"))

        // When not inserted, deleting must throw
        #expect(throws: Error.self) {
            try monitor.deleteAudioFile(dummyFile)
        }

        // When file is not inside volume path, must throw security error
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let customMonitor = SDCardMonitor(targetVolumeName: tempDir.lastPathComponent)
        customMonitor.updateStatus(.inserted(volumeURL: tempDir, freeBytes: 1000, totalBytes: 2000))
        let foreignFile = AudioRecordingFile(url: URL(fileURLWithPath: "/System/Library/test.wav"))
        
        #expect(throws: Error.self) {
            try customMonitor.deleteAudioFile(foreignFile)
        }

        // Test delete with valid file when inserted
        let localFile = tempDir.appendingPathComponent("recording.wav")
        try Data("audio".utf8).write(to: localFile)
        let validRecording = AudioRecordingFile(url: localFile)
        customMonitor.updateStatus(.inserted(volumeURL: tempDir, freeBytes: 1000, totalBytes: 2000))
        
        #expect(FileManager.default.fileExists(atPath: localFile.path))
        try customMonitor.deleteAudioFile(validRecording)
        #expect(!FileManager.default.fileExists(atPath: localFile.path))
    }

    @Test("SDCardMonitor notification handlers and unmount")
    @MainActor
    func testSDCardMonitorNotificationHandlers() async throws {
        let monitor = SDCardMonitor(targetVolumeName: "P2_SD")
        
        let tempP2 = FileManager.default.temporaryDirectory.appendingPathComponent("P2_SD")
        try? FileManager.default.createDirectory(at: tempP2, withIntermediateDirectories: true)

        // Eject when not inserted does nothing
        try await monitor.ejectCard()
        #expect(monitor.currentStatus == .notInserted)

        // Test isTargetVolume
        let otherURL = FileManager.default.temporaryDirectory.appendingPathComponent("OTHER_VOL")
        #expect(monitor.isTargetVolume(url: tempP2, name: "P2_SD"))
        #expect(!monitor.isTargetVolume(url: otherURL, name: "OTHER"))

        // Test direct checkCurrentVolumes
        monitor.checkCurrentVolumes()

        // Test mount notification with missing userInfo
        let emptyNotification = Notification(name: NSWorkspace.didMountNotification)
        monitor.handleMountNotification(emptyNotification)

        // Test mount notification with mock target volume
        let targetNotification = Notification(
            name: NSWorkspace.didMountNotification,
            object: nil,
            userInfo: ["NSDevicePath": tempP2.path]
        )
        monitor.handleMountNotification(targetNotification)

        // Test mount notification with NSWorkspace.volumeURLUserInfoKey
        let urlMountNotif = Notification(
            name: NSWorkspace.didMountNotification,
            object: nil,
            userInfo: [NSWorkspace.volumeURLUserInfoKey: tempP2]
        )
        monitor.handleMountNotification(urlMountNotif)

        // Test unmount notification with matching path
        let unmountMatching = Notification(
            name: NSWorkspace.didUnmountNotification,
            object: nil,
            userInfo: ["NSDevicePath": tempP2.path]
        )
        monitor.handleUnmountNotification(unmountMatching)
        #expect(monitor.currentStatus == .notInserted)

        // Test unmount notification with NSWorkspace.volumeURLUserInfoKey
        monitor.updateStatus(.inserted(volumeURL: tempP2, freeBytes: 100, totalBytes: 200))
        let urlUnmountNotif = Notification(
            name: NSWorkspace.didUnmountNotification,
            object: nil,
            userInfo: [NSWorkspace.volumeURLUserInfoKey: tempP2]
        )
        monitor.handleUnmountNotification(urlUnmountNotif)
        #expect(monitor.currentStatus == .notInserted)

        // Test unmount notification with non-matching path
        monitor.updateStatus(.inserted(volumeURL: URL(fileURLWithPath: "/Volumes/P2_SD"), freeBytes: 100, totalBytes: 200))
        let unmountOther = Notification(
            name: NSWorkspace.didUnmountNotification,
            object: nil,
            userInfo: ["NSDevicePath": "/Volumes/Other"]
        )
        monitor.handleUnmountNotification(unmountOther)

        let unmountEmpty = Notification(name: NSWorkspace.didUnmountNotification)
        monitor.handleUnmountNotification(unmountEmpty)

        let mountOther = Notification(
            name: NSWorkspace.didMountNotification,
            object: nil,
            userInfo: ["NSDevicePath": "/Volumes/NotTarget"]
        )
        monitor.handleMountNotification(mountOther)

        // Test ejectCard when not inserted
        monitor.updateStatus(.notInserted)
        try await monitor.ejectCard()

        // Test ejectCard with mock handler
        monitor.updateStatus(.inserted(volumeURL: URL(fileURLWithPath: "/Volumes/P2_SD"), freeBytes: 100, totalBytes: 200))
        final class BoolBox: @unchecked Sendable { var value = false }
        let ejectBox = BoolBox()
        monitor.ejectHandler = { url in
            ejectBox.value = true
        }
        try await monitor.ejectCard()
        #expect(ejectBox.value)
        #expect(monitor.currentStatus == .notInserted)

        // Test live notification center observers
        final class ObserverBox: @unchecked Sendable { var fired = false }
        let observerBox = ObserverBox()
        monitor.addObserver { _ in observerBox.fired = true }
        monitor.startMonitoring()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil, userInfo: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didUnmountNotification, object: nil, userInfo: nil)
        monitor.stopMonitoring()
        #expect(observerBox.fired || monitor.currentStatus == .notInserted)
    }
}
