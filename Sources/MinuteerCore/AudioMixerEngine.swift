import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import CoreMedia

/// Represents an individual audio channel strip in the mixer.
public final class AudioChannel: Identifiable, ObservableObject, @unchecked Sendable {
    public let id: UUID
    public let source: AudioSourceDescriptor
    public var volume: Float
    public var isMuted: Bool
    public var isSolo: Bool
    public var currentLevel: Float
    public var assignedSpeakerName: String?

    public init(
        id: UUID = UUID(),
        source: AudioSourceDescriptor,
        volume: Float = 1.0,
        isMuted: Bool = false,
        isSolo: Bool = false,
        currentLevel: Float = 0.0,
        assignedSpeakerName: String? = nil
    ) {
        self.id = id
        self.source = source
        self.volume = volume
        self.isMuted = isMuted
        self.isSolo = isSolo
        self.currentLevel = currentLevel
        self.assignedSpeakerName = assignedSpeakerName
    }
}

/// Capture backend protocol for individual stems.
public protocol AudioStemCapturer: AnyObject, Sendable {
    var source: AudioSourceDescriptor { get }
    var stemURL: URL { get }
    var currentLevel: Float { get }
    func start() async throws
    func stop() async
}

/// ScreenCaptureKit capture backend for system or app audio.
@available(macOS 14.0, *)
public final class SCKStemCapturer: NSObject, AudioStemCapturer, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public let source: AudioSourceDescriptor
    public let stemURL: URL
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private let sampleQueue: DispatchQueue
    private let lock = NSLock()
    private var _level: Float = 0
    public private(set) var isRunning = false

    public var currentLevel: Float {
        lock.withLock { _level }
    }

    public init(source: AudioSourceDescriptor, stemURL: URL) {
        self.source = source
        self.stemURL = stemURL
        self.sampleQueue = DispatchQueue(label: "com.ragingcoders.minuteer.sck-\(stemURL.lastPathComponent)")
        super.init()
    }

    public func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "MinuteerAudioMixer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found for ScreenCaptureKit"])
        }

        let filter: SCContentFilter
        switch source.kind {
        case .systemAudio:
            let ownBundle = Bundle.main.bundleIdentifier ?? "com.ragingcoders.Minuteer"
            let excluded = content.applications.filter { $0.bundleIdentifier == ownBundle }
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        case .runningApplication:
            if let pid = source.processIdentifier,
               let targetApp = content.applications.first(where: { $0.processID == pid }) {
                filter = SCContentFilter(display: display, including: [targetApp], exceptingWindows: [])
            } else if let bundleID = source.bundleIdentifier,
                      let targetApp = content.applications.first(where: { $0.bundleIdentifier == bundleID }) {
                filter = SCContentFilter(display: display, including: [targetApp], exceptingWindows: [])
            } else {
                throw NSError(domain: "MinuteerAudioMixer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Application '\(source.displayName)' is not running"])
            }
        case .microphone:
            throw NSError(domain: "MinuteerAudioMixer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Microphone cannot use ScreenCaptureKit"])
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5
        config.sampleRate = 48_000
        config.channelCount = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        self.stream = stream

        try await stream.startCapture()
        isRunning = true
    }

    public func stop() async {
        guard let stream = stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        self.audioFile = nil
        self.isRunning = false
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let pcmBuffer = AudioBufferConverter.pcmBuffer(from: sampleBuffer) else { return }

        let level = AudioBufferConverter.rmsLevel(pcmBuffer)
        lock.withLock {
            _level = level
            if audioFile == nil {
                try? FileManager.default.createDirectory(at: stemURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                audioFile = try? AVAudioFile(forWriting: stemURL, settings: pcmBuffer.format.settings)
            }
            try? audioFile?.write(from: pcmBuffer)
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
    }
}

/// Audio buffer conversion and RMS level extraction utilities.
public enum AudioBufferConverter {
    public static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return 0 }
        var sumSq: Float = 0
        var count = 0
        for c in 0..<channels {
            let p = data[c]
            for i in 0..<frames {
                let v = p[i]
                sumSq += v * v
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let rms = sqrt(sumSq / Float(count))
        let db = rms > 0 ? 20 * log10f(rms) : -120
        return max(0, min(1, (db + 50) / 50))
    }

    public static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
              let fmt = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: asbd.mSampleRate,
                  channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
                  interleaved: false
              ) else { return nil }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(numSamples)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(numSamples)

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let channelCount = Int(fmt.channelCount)
        let inputBufferCount = isNonInterleaved ? channelCount : 1
        let ablPtr = AudioBufferList.allocate(maximumBuffers: inputBufferCount)
        defer { free(ablPtr.unsafeMutablePointer) }
        let ablSize = MemoryLayout<AudioBufferList>.size + (max(inputBufferCount, 1) - 1) * MemoryLayout<AudioBuffer>.stride

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr.unsafeMutablePointer,
            bufferListSize: ablSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let dstBuffers = pcm.floatChannelData else { return nil }
        let frames = Int(pcm.frameLength)

        if isFloat, isNonInterleaved {
            for channel in 0..<min(channelCount, ablPtr.count) {
                guard let src = ablPtr[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                memcpy(dstBuffers[channel], src, frames * MemoryLayout<Float>.size)
            }
        } else if isFloat {
            guard let src = ablPtr[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
            for frame in 0..<frames {
                for channel in 0..<channelCount {
                    dstBuffers[channel][frame] = src[frame * channelCount + channel]
                }
            }
        } else if bitsPerChannel == 16 {
            guard let src = ablPtr[0].mData?.assumingMemoryBound(to: Int16.self) else { return nil }
            for frame in 0..<frames {
                for channel in 0..<channelCount {
                    dstBuffers[channel][frame] = Float(src[frame * channelCount + channel]) / Float(Int16.max)
                }
            }
        } else {
            return nil
        }
        return pcm
    }
}

/// AVFoundation microphone stem capturer.
public final class MicrophoneStemCapturer: NSObject, AudioStemCapturer, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let source: AudioSourceDescriptor
    public let stemURL: URL
    private var session: AVCaptureSession?
    private var audioFile: AVAudioFile?
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var _level: Float = 0

    public var currentLevel: Float {
        lock.withLock { _level }
    }

    public init(source: AudioSourceDescriptor, stemURL: URL) {
        self.source = source
        self.stemURL = stemURL
        self.queue = DispatchQueue(label: "com.ragingcoders.minuteer.mic-\(stemURL.lastPathComponent)")
        super.init()
    }

    public func start() async throws {
        let session = AVCaptureSession()
        let rawID = source.id.replacingOccurrences(of: "mic_", with: "")

        let device: AVCaptureDevice?
        if let found = AVCaptureDevice(uniqueID: rawID) {
            device = found
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }

        guard let targetDevice = device else {
            throw NSError(domain: "MinuteerAudioMixer", code: 4, userInfo: [NSLocalizedDescriptionKey: "Microphone device not found"])
        }

        let input = try AVCaptureDeviceInput(device: targetDevice)
        guard session.canAddInput(input) else {
            throw NSError(domain: "MinuteerAudioMixer", code: 5, userInfo: [NSLocalizedDescriptionKey: "Cannot add microphone input to session"])
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw NSError(domain: "MinuteerAudioMixer", code: 6, userInfo: [NSLocalizedDescriptionKey: "Cannot add audio output to session"])
        }
        session.addOutput(output)

        self.session = session
        session.startRunning()
    }

    public func stop() async {
        session?.stopRunning()
        session = nil
        lock.withLock {
            audioFile = nil
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let pcmBuffer = AudioBufferConverter.pcmBuffer(from: sampleBuffer) else { return }

        let level = AudioBufferConverter.rmsLevel(pcmBuffer)
        lock.withLock {
            _level = level
            if audioFile == nil {
                try? FileManager.default.createDirectory(at: stemURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                audioFile = try? AVAudioFile(forWriting: stemURL, settings: pcmBuffer.format.settings)
            }
            try? audioFile?.write(from: pcmBuffer)
        }
    }
}

/// Central audio recording and mixing engine for meetings and multi-source capture.
public final class AudioMixerEngine: ObservableObject, @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case recording(duration: TimeInterval)
        case paused(duration: TimeInterval)
        case mixing
    }

    @Published public private(set) var state: State = .idle
    @Published public var channels: [AudioChannel] = []
    @Published public var masterVolume: Float = 1.0
    @Published public var linkedCalendarEvent: CalendarEventInfo?

    private var capturers: [UUID: any AudioStemCapturer] = [:]
    private var sessionDirectory: URL?
    private var recordStartTime: Date?
    private var accumulatedDuration: TimeInterval = 0
    private var meterTimer: Timer?
    private let lock = NSLock()

    public typealias CapturerFactory = @Sendable (AudioSourceDescriptor, URL) -> any AudioStemCapturer
    private let capturerFactory: CapturerFactory

    public init(
        defaultChannels: [AudioSourceDescriptor] = [],
        capturerFactory: CapturerFactory? = nil
    ) {
        self.capturerFactory = capturerFactory ?? { source, stemURL in
            switch source.kind {
            case .systemAudio, .runningApplication:
                return SCKStemCapturer(source: source, stemURL: stemURL)
            case .microphone:
                return MicrophoneStemCapturer(source: source, stemURL: stemURL)
            }
        }

        if defaultChannels.isEmpty {
            // Default setup: System Audio + Default Microphone
            self.channels = [
                AudioChannel(source: .systemAudio, volume: 1.0),
                AudioChannel(source: .microphone(id: "default", name: "Default Microphone"), volume: 1.0)
            ]
        } else {
            self.channels = defaultChannels.map { AudioChannel(source: $0, volume: 1.0) }
        }
    }

    public var isRecording: Bool {
        if case .recording = state { return true }
        if case .paused = state { return true }
        return false
    }

    public func addChannel(for source: AudioSourceDescriptor) {
        guard !channels.contains(where: { $0.source.id == source.id }) else { return }
        channels.append(AudioChannel(source: source, volume: 1.0))
    }

    public func removeChannel(id: UUID) {
        guard !isRecording else { return }
        channels.removeAll(where: { $0.id == id })
    }

    public func setVolume(_ volume: Float, for channelID: UUID) {
        if let ch = channels.first(where: { $0.id == channelID }) {
            ch.volume = max(0.0, min(1.5, volume))
        }
    }

    public func toggleMute(for channelID: UUID) {
        if let ch = channels.first(where: { $0.id == channelID }) {
            ch.isMuted.toggle()
        }
    }

    public func toggleSolo(for channelID: UUID) {
        if let ch = channels.first(where: { $0.id == channelID }) {
            ch.isSolo.toggle()
        }
    }

    public func assignSpeaker(_ name: String?, for channelID: UUID) {
        if let ch = channels.first(where: { $0.id == channelID }) {
            ch.assignedSpeakerName = name
        }
    }

    public func startRecording(
        outputDirectory: URL,
        filenamePrefix: String = "Meeting"
    ) async throws {
        guard !isRecording else { return }

        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = f.string(from: Date())
        let sessionDir = outputDirectory.appendingPathComponent(".session_\(timestamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        self.sessionDirectory = sessionDir

        capturers.removeAll()

        for channel in channels {
            let stemName = "stem_\(channel.id.uuidString).wav"
            let stemURL = sessionDir.appendingPathComponent(stemName)

            let capturer = capturerFactory(channel.source, stemURL)
            capturers[channel.id] = capturer
            try await capturer.start()
        }

        self.recordStartTime = Date()
        self.accumulatedDuration = 0
        self.state = .recording(duration: 0)

        startMeterTimer()
    }

    public func pause() {
        guard case .recording(let current) = state else { return }
        accumulatedDuration = current
        recordStartTime = nil
        state = .paused(duration: accumulatedDuration)
    }

    public func resume() {
        guard case .paused = state else { return }
        recordStartTime = Date()
        state = .recording(duration: accumulatedDuration)
    }

    public func stopRecording(
        finalOutputURL: URL
    ) async throws -> (finalURL: URL, duration: TimeInterval) {
        stopMeterTimer()
        let dur = currentElapsedDuration()

        state = .mixing

        for capturer in capturers.values {
            await capturer.stop()
        }

        try? await Task.sleep(nanoseconds: 150_000_000)

        // Stems collection
        let hasSolo = channels.contains(where: { $0.isSolo })
        var stemsToMix: [(url: URL, gain: Float)] = []

        for ch in channels {
            guard let capturer = capturers[ch.id] else { continue }
            let stemFile = capturer.stemURL
            guard FileManager.default.fileExists(atPath: stemFile.path) else { continue }

            let effectiveGain: Float
            if hasSolo {
                effectiveGain = ch.isSolo ? (ch.isMuted ? 0.0 : ch.volume * masterVolume) : 0.0
            } else {
                effectiveGain = ch.isMuted ? 0.0 : ch.volume * masterVolume
            }

            if effectiveGain > 0.001 {
                stemsToMix.append((url: stemFile, gain: effectiveGain))
            }
        }

        try await Self.produceFinalMix(stems: stemsToMix, finalURL: finalOutputURL)

        // Automatically train/update speaker voiceprints for channels that had an assigned speaker
        for ch in channels {
            if let speakerName = ch.assignedSpeakerName,
               let capturer = capturers[ch.id] {
                let stemFile = capturer.stemURL
                if FileManager.default.fileExists(atPath: stemFile.path) {
                    AudioFingerprintEngine.fingerprintSpeakerFromStem(
                        stemURL: stemFile,
                        speakerName: speakerName
                    )
                }
            }
        }

        if let sessionDir = sessionDirectory {
            try? FileManager.default.removeItem(at: sessionDir)
        }
        self.sessionDirectory = nil
        self.capturers.removeAll()
        self.state = .idle

        for ch in channels {
            ch.currentLevel = 0
        }

        return (finalOutputURL, dur)
    }

    private func currentElapsedDuration() -> TimeInterval {
        var dur = accumulatedDuration
        if let start = recordStartTime {
            dur += Date().timeIntervalSince(start)
        }
        return dur
    }

    private func startMeterTimer() {
        stopMeterTimer()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let current = self.currentElapsedDuration()
            if case .recording = self.state {
                self.state = .recording(duration: current)
            }
            for ch in self.channels {
                if let capturer = self.capturers[ch.id] {
                    ch.currentLevel = capturer.currentLevel
                }
            }
        }
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    /// Resamples all stems to 16kHz 16-bit mono and sums them with soft-saturation clipping.
    public static func produceFinalMix(
        stems: [(url: URL, gain: Float)],
        finalURL: URL
    ) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: finalURL)
        try fm.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let targetSR: Double = 16_000
        let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSR,
            channels: 1,
            interleaved: false
        )!

        let writeSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: targetSR,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        guard !stems.isEmpty else {
            // Generate 1-second silence file if no audible stems
            let empty = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 16000)!
            empty.frameLength = 16000
            let outFile = try AVAudioFile(forWriting: finalURL, settings: writeSettings)
            try outFile.write(from: empty)
            return
        }

        var resampledStems: [(buffer: AVAudioPCMBuffer, gain: Float)] = []
        var maxFrames: AVAudioFrameCount = 0

        for stem in stems {
            guard let file = try? AVAudioFile(forReading: stem.url, commonFormat: .pcmFormatFloat32, interleaved: false) else { continue }
            if let mono = try? readAndResample(file: file, to: outFormat) {
                resampledStems.append((buffer: mono, gain: stem.gain))
                maxFrames = max(maxFrames, mono.frameLength)
            }
        }

        guard maxFrames > 0, !resampledStems.isEmpty else {
            let empty = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 16000)!
            empty.frameLength = 16000
            let outFile = try AVAudioFile(forWriting: finalURL, settings: writeSettings)
            try outFile.write(from: empty)
            return
        }

        guard let mixed = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: maxFrames),
              let mixPtr = mixed.floatChannelData?[0] else {
            throw NSError(domain: "MinuteerAudioMixer", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate mix buffer"])
        }
        mixed.frameLength = maxFrames

        let framesCount = Int(maxFrames)
        for i in 0..<framesCount {
            var sum: Float = 0
            for stem in resampledStems {
                if i < Int(stem.buffer.frameLength), let ptr = stem.buffer.floatChannelData?[0] {
                    sum += ptr[i] * stem.gain
                }
            }
            // Soft-saturation limiter
            if sum > 1.0 { sum = 1.0 } else if sum < -1.0 { sum = -1.0 }
            mixPtr[i] = sum
        }

        let outFile = try AVAudioFile(forWriting: finalURL, settings: writeSettings)
        try outFile.write(from: mixed)
    }

    private static func readAndResample(file: AVAudioFile, to targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let srcFormat = file.processingFormat
        let length = AVAudioFrameCount(file.length)
        guard length > 0 else {
            let empty = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 1024)!
            empty.frameLength = 0
            return empty
        }

        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: length) else {
            throw NSError(domain: "MinuteerAudioMixer", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed to read stem"])
        }
        try file.read(into: srcBuffer)

        if srcFormat.sampleRate == targetFormat.sampleRate && srcFormat.channelCount == targetFormat.channelCount {
            return srcBuffer
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            throw NSError(domain: "MinuteerAudioMixer", code: 9, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
        }

        let ratio = targetFormat.sampleRate / srcFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(length) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            throw NSError(domain: "MinuteerAudioMixer", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate target buffer"])
        }

        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return srcBuffer
        }

        if let convError = convError {
            throw convError
        }
        guard status != .error else {
            throw NSError(domain: "MinuteerAudioMixer", code: 11, userInfo: [NSLocalizedDescriptionKey: "Converter returned error status"])
        }

        return outBuffer
    }
}
