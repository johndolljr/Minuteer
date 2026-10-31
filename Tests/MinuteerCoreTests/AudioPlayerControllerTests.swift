import Testing
import Foundation
import AVFoundation
@testable import MinuteerCore

@Suite("Audio Player Controller Tests")
struct AudioPlayerControllerTests {

    @Test("AudioPlayerController lifecycle, playback, and seeking")
    @MainActor
    func testAudioPlayerController() async throws {
        let tempWAV = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try makeValidWAVData(durationSeconds: 2.0).write(to: tempWAV)
        defer { try? FileManager.default.removeItem(at: tempWAV) }

        let controller = AudioPlayerController()
        #expect(!controller.isPlaying)
        #expect(controller.currentTime == 0)
        #expect(controller.duration == 0)
        #expect(controller.formattedCurrentTime == "00:00")
        #expect(controller.formattedDuration == "00:00")

        // Test guard paths when player is nil
        controller.play()
        controller.pause()
        controller.seek(to: 5.0)
        controller.skip(by: 2.0)
        #expect(!controller.isPlaying)

        final class CallbackBox: @unchecked Sendable {
            var stateChanged = false
            var progressUpdated = false
        }
        let box = CallbackBox()
        controller.onPlaybackStateChanged = { _ in box.stateChanged = true }
        controller.onProgressUpdated = { _, _ in box.progressUpdated = true }

        // Load valid file
        try controller.load(url: tempWAV)
        #expect(controller.currentURL == tempWAV)
        #expect(controller.duration > 0)
        #expect(box.progressUpdated)

        // Play
        controller.play()
        #expect(controller.isPlaying)
        #expect(box.stateChanged)

        // Wait for timer to fire
        try? await Task.sleep(nanoseconds: 350_000_000)

        // Pause
        controller.pause()
        #expect(!controller.isPlaying)

        // Toggle
        controller.togglePlayPause()
        #expect(controller.isPlaying)
        controller.togglePlayPause()
        #expect(!controller.isPlaying)

        // Seek and Skip
        controller.seek(to: 1.0)
        #expect(controller.currentTime == 1.0)
        controller.skip(by: 0.5)
        #expect(controller.currentTime >= 1.0)
        controller.skip(by: -10.0) // Clamp to 0
        #expect(controller.currentTime == 0.0)

        // Finish playing callback
        let player = try AVAudioPlayer(contentsOf: tempWAV)
        controller.audioPlayerDidFinishPlaying(player, successfully: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!controller.isPlaying)

        // Playback rate tests
        #expect(controller.playbackRate == 1.0)
        controller.setPlaybackRate(1.5)
        #expect(controller.playbackRate == 1.5)
        controller.setPlaybackRate(0.1) // clamped to 0.5
        #expect(controller.playbackRate == 0.5)
        controller.setPlaybackRate(5.0) // clamped to 2.5
        #expect(controller.playbackRate == 2.5)

        // Reload to verify rate preserved
        try controller.load(url: tempWAV)
        #expect(controller.playbackRate == 2.5)

        // Stop
        controller.stop()
        #expect(!controller.isPlaying)
        #expect(controller.currentURL == nil)

        // Nonexistent file error
        let missingURL = URL(fileURLWithPath: "/tmp/nonexistent-song.wav")
        #expect(throws: Error.self) {
            try controller.load(url: missingURL)
        }

        // Corrupted / non-audio file error handling
        let corruptFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try "corrupted audio data".write(to: corruptFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: corruptFile) }
        #expect(throws: Error.self) {
            try controller.load(url: corruptFile)
        }
        #expect(controller.duration == 0)
        #expect(controller.currentTime == 0)
        #expect(!controller.isPlaying)

        // Test deinit
        do {
            let tempCtrl = AudioPlayerController()
            tempCtrl.play()
        }
    }
}
