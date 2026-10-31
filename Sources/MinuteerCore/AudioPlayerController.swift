import Foundation
import AVFoundation

@MainActor
public final class AudioPlayerController: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var timer: Timer?

    private(set) public var currentURL: URL?
    private(set) public var isPlaying: Bool = false
    private(set) public var currentTime: TimeInterval = 0
    private(set) public var duration: TimeInterval = 0
    private(set) public var playbackRate: Float = 1.0

    public var onPlaybackStateChanged: ((@MainActor (Bool) -> Void))?
    public var onProgressUpdated: ((@MainActor (TimeInterval, TimeInterval) -> Void))?

    public override init() {
        super.init()
    }

    isolated deinit {
        timer?.invalidate()
        player?.stop()
    }

    public func load(url: URL) throws {
        stop()
        currentURL = url

        guard FileManager.default.fileExists(atPath: url.path) else {
            stop()
            throw NSError(
                domain: "AudioPlayerController",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Audio file not found at \(url.path)"]
            )
        }

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.enableRate = true
            newPlayer.rate = playbackRate
            newPlayer.prepareToPlay()
            self.player = newPlayer
            self.duration = newPlayer.duration
            self.currentTime = 0
            onProgressUpdated?(0, duration)
        } catch {
            stop()
            throw error
        }
    }

    public func play() {
        guard let player = player else { return }
        player.play()
        isPlaying = true
        startTimer()
        onPlaybackStateChanged?(true)
    }

    public func pause() {
        guard let player = player else { return }
        player.pause()
        isPlaying = false
        stopTimer()
        currentTime = player.currentTime
        onPlaybackStateChanged?(false)
        onProgressUpdated?(currentTime, duration)
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    public func seek(to time: TimeInterval) {
        guard let player = player else { return }
        let target = max(0, min(time, player.duration))
        player.currentTime = target
        currentTime = target
        onProgressUpdated?(target, duration)
    }

    public func skip(by delta: TimeInterval) {
        guard let player = player else { return }
        seek(to: player.currentTime + delta)
    }

    public func setPlaybackRate(_ rate: Float) {
        let clamped = max(0.5, min(rate, 2.5))
        self.playbackRate = clamped
        if let player = player {
            player.enableRate = true
            player.rate = clamped
        }
    }

    public func stop() {
        stopTimer()
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentURL = nil
        onPlaybackStateChanged?(false)
        onProgressUpdated?(0, 0)
    }

    public var formattedCurrentTime: String {
        formatTime(currentTime)
    }

    public var formattedDuration: String {
        formatTime(duration)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let player = self.player else { return }
                self.currentTime = player.currentTime
                self.onProgressUpdated?(self.currentTime, self.duration)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.isPlaying = false
            self.currentTime = 0
            self.stopTimer()
            self.onPlaybackStateChanged?(false)
            self.onProgressUpdated?(0, self.duration)
        }
    }
}
