import Foundation
import Speech
import AVFoundation
import WhisperKit

public protocol TranscriptionEngine: Sendable {
    var name: String { get }
    func transcribe(audioFileURL: URL, progress: (@Sendable (Double) -> Void)?) async throws -> String
}

public final class MockTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    public let name = "Mock Engine"
    public var mockTranscript: String
    public var shouldFail: Bool

    public init(mockTranscript: String = "Test transcript content.", shouldFail: Bool = false) {
        self.mockTranscript = mockTranscript
        self.shouldFail = shouldFail
    }

    public func transcribe(audioFileURL: URL, progress: (@Sendable (Double) -> Void)?) async throws -> String {
        if shouldFail {
            throw NSError(domain: "MockTranscriptionEngine", code: 500, userInfo: [NSLocalizedDescriptionKey: "Simulated transcription failure"])
        }
        progress?(0.25)
        progress?(0.50)
        progress?(0.75)
        progress?(1.0)
        return mockTranscript
    }
}

public final class AppleSpeechEngine: TranscriptionEngine, @unchecked Sendable {
    public let name = "Apple Speech (On-Device)"
    private let locale: Locale
    private let recognizer: SFSpeechRecognizer?
    var customRunner: (@Sendable (URL, (@Sendable (Double) -> Void)?) async throws -> String)?

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    public var isAvailable: Bool {
        guard let r = recognizer else { return false }
        return r.isAvailable
    }

    public func transcribe(audioFileURL: URL, progress: (@Sendable (Double) -> Void)?) async throws -> String {
        if let runner = customRunner {
            return try await runner(audioFileURL, progress)
        }

        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw NSError(domain: "AppleSpeechEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "SFSpeechRecognizer is unavailable."])
        }

        let request = SFSpeechURLRecognitionRequest(url: audioFileURL)
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        final class SpeechSession: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<String, Error>?
            private var task: SFSpeechRecognitionTask?

            init(continuation: CheckedContinuation<String, Error>) {
                self.continuation = continuation
            }

            func attachTask(_ task: SFSpeechRecognitionTask) {
                lock.lock()
                defer { lock.unlock() }
                self.task = task
            }

            func finish(result: Result<String, Error>) {
                lock.lock()
                let cont = continuation
                continuation = nil
                let t = task
                task = nil
                lock.unlock()

                cont?.resume(with: result)
                if case .failure = result {
                    t?.cancel()
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = SpeechSession(continuation: continuation)

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    session.finish(result: .failure(error))
                    return
                }

                if let result = result, result.isFinal {
                    progress?(1.0)
                    session.finish(result: .success(result.bestTranscription.formattedString))
                }
            }

            session.attachTask(task)

            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                session.finish(result: .failure(NSError(domain: "AppleSpeechEngine", code: 408, userInfo: [NSLocalizedDescriptionKey: "Speech recognition request timed out or cancelled."])))
            }
        }
    }
}

public enum PerformanceLevel: String, Sendable, Equatable {
    case optimal = "Recommended for your Mac"
    case fast = "Fast"
    case instant = "Instant"
    case moderate = "Moderate"
    case heavy = "Heavy (Slow)"
    case veryHeavy = "Very Slow"
}

public struct ModelPerformanceInfo: Sendable, Equatable {
    public let level: PerformanceLevel
    public let badgeText: String
    public let estimatedSpeedDescription: String
    public let recommendationNote: String
    public let isRecommendedForDevice: Bool

    public init(
        level: PerformanceLevel,
        badgeText: String,
        estimatedSpeedDescription: String,
        recommendationNote: String,
        isRecommendedForDevice: Bool
    ) {
        self.level = level
        self.badgeText = badgeText
        self.estimatedSpeedDescription = estimatedSpeedDescription
        self.recommendationNote = recommendationNote
        self.isRecommendedForDevice = isRecommendedForDevice
    }
}

public struct TranscriptionModelOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let accuracy: String
    public let speed: String
    public let sizeDescription: String
    public let isRecommended: Bool
    public let details: String

    public init(
        id: String,
        displayName: String,
        accuracy: String,
        speed: String,
        sizeDescription: String,
        isRecommended: Bool,
        details: String
    ) {
        self.id = id
        self.displayName = displayName
        self.accuracy = accuracy
        self.speed = speed
        self.sizeDescription = sizeDescription
        self.isRecommended = isRecommended
        self.details = details
    }

    public func performance(for tier: HardwareTier = DeviceHardware.currentTier) -> ModelPerformanceInfo {
        switch tier {
        case .m1Base:
            switch id {
            case "openai_whisper-base":
                return ModelPerformanceInfo(
                    level: .instant,
                    badgeText: "⚡️ Instant (<1m)",
                    estimatedSpeedDescription: "< 1 min for 30m audio",
                    recommendationNote: "Instant, lightweight transcription on Apple M1.",
                    isRecommendedForDevice: false
                )
            case "openai_whisper-small.en":
                return ModelPerformanceInfo(
                    level: .optimal,
                    badgeText: "⭐️ Best Balance for M1 (~2m)",
                    estimatedSpeedDescription: "~2–3 min for 30m audio",
                    recommendationNote: "Ideal speed and accuracy balance for Apple M1. High accuracy for English meetings.",
                    isRecommendedForDevice: true
                )
            case "distil-whisper_distil-large-v3_turbo":
                return ModelPerformanceInfo(
                    level: .optimal,
                    badgeText: "⚡️ 6x Fast (~3m)",
                    estimatedSpeedDescription: "~3–4 min for 30m audio",
                    recommendationNote: "Distilled model delivering Large-v3 quality at 6x speed on Apple M1.",
                    isRecommendedForDevice: true
                )
            case "openai_whisper-small":
                return ModelPerformanceInfo(
                    level: .fast,
                    badgeText: "⚡️ Fast (~3m)",
                    estimatedSpeedDescription: "~3 min for 30m audio",
                    recommendationNote: "Accurate multilingual speech recognition with solid throughput on M1.",
                    isRecommendedForDevice: false
                )
            case "openai_whisper-large-v3_turbo":
                return ModelPerformanceInfo(
                    level: .heavy,
                    badgeText: "🐢 Heavy on M1 (~20m)",
                    estimatedSpeedDescription: "~18–25 min for 30m audio",
                    recommendationNote: "Heavy compute load for base M1. Recommended for M2 Pro / M3 / M4 chips.",
                    isRecommendedForDevice: false
                )
            default:
                return ModelPerformanceInfo(
                    level: .veryHeavy,
                    badgeText: "🛑 Very Heavy (30m+)",
                    estimatedSpeedDescription: "30+ min for 30m audio",
                    recommendationNote: "Exceeds practical throughput on base M1. High RAM and Neural Engine load.",
                    isRecommendedForDevice: false
                )
            }
        case .m2Base:
            switch id {
            case "openai_whisper-base":
                return ModelPerformanceInfo(
                    level: .instant,
                    badgeText: "⚡️ Instant (<1m)",
                    estimatedSpeedDescription: "< 1 min for 30m audio",
                    recommendationNote: "Instant transcription with low power usage.",
                    isRecommendedForDevice: false
                )
            case "openai_whisper-small.en":
                return ModelPerformanceInfo(
                    level: .optimal,
                    badgeText: "⭐️ Best for M2 (~1.5m)",
                    estimatedSpeedDescription: "~1–2 min for 30m audio",
                    recommendationNote: "High English accuracy with rapid inference on M2.",
                    isRecommendedForDevice: true
                )
            case "distil-whisper_distil-large-v3_turbo":
                return ModelPerformanceInfo(
                    level: .optimal,
                    badgeText: "⚡️ Recommended (~2m)",
                    estimatedSpeedDescription: "~2–3 min for 30m audio",
                    recommendationNote: "High accuracy at 6x speed via model distillation.",
                    isRecommendedForDevice: true
                )
            case "openai_whisper-small":
                return ModelPerformanceInfo(
                    level: .fast,
                    badgeText: "⚡️ Fast (~2m)",
                    estimatedSpeedDescription: "~2 min for 30m audio",
                    recommendationNote: "Solid multilingual speech recognition.",
                    isRecommendedForDevice: false
                )
            case "openai_whisper-large-v3_turbo":
                return ModelPerformanceInfo(
                    level: .moderate,
                    badgeText: "Moderate (~8-12m)",
                    estimatedSpeedDescription: "~8–12 min for 30m audio",
                    recommendationNote: "Accurate, but uses significant CPU and Neural Engine capacity.",
                    isRecommendedForDevice: false
                )
            default:
                return ModelPerformanceInfo(
                    level: .heavy,
                    badgeText: "🐢 Heavy (~18m)",
                    estimatedSpeedDescription: "~15–20 min for 30m audio",
                    recommendationNote: "Very heavy on standard M2.",
                    isRecommendedForDevice: false
                )
            }
        case .proMaxUltra, .modernBase:
            switch id {
            case "openai_whisper-large-v3_turbo":
                return ModelPerformanceInfo(
                    level: .optimal,
                    badgeText: "⭐️ Best Accuracy (~2-3m)",
                    estimatedSpeedDescription: "~2–3 min for 30m audio",
                    recommendationNote: "Top accuracy with high throughput on your high-performance chip.",
                    isRecommendedForDevice: true
                )
            case "distil-whisper_distil-large-v3_turbo":
                return ModelPerformanceInfo(
                    level: .fast,
                    badgeText: "⚡️ Ultra Fast (<1m)",
                    estimatedSpeedDescription: "< 1 min for 30m audio",
                    recommendationNote: "Blazing speed with near-Large accuracy.",
                    isRecommendedForDevice: true
                )
            case "openai_whisper-small.en", "openai_whisper-small":
                return ModelPerformanceInfo(
                    level: .fast,
                    badgeText: "⚡️ Instant (<1m)",
                    estimatedSpeedDescription: "< 1 min for 30m audio",
                    recommendationNote: "Instant processing on your chip.",
                    isRecommendedForDevice: false
                )
            case "openai_whisper-base":
                return ModelPerformanceInfo(
                    level: .instant,
                    badgeText: "⚡️ Instant (<30s)",
                    estimatedSpeedDescription: "< 30 sec for 30m audio",
                    recommendationNote: "Instant lightweight transcription.",
                    isRecommendedForDevice: false
                )
            default:
                return ModelPerformanceInfo(
                    level: .moderate,
                    badgeText: "Moderate (~5-7m)",
                    estimatedSpeedDescription: "~5–7 min for 30m audio",
                    recommendationNote: "Maximum parameter model for complex audio.",
                    isRecommendedForDevice: false
                )
            }
        case .intelOrOther:
            switch id {
            case "openai_whisper-base":
                return ModelPerformanceInfo(
                    level: .optimal,
                    badgeText: "⚡️ Recommended (~2m)",
                    estimatedSpeedDescription: "~2 min for 30m audio",
                    recommendationNote: "Lightweight and compatible with non-Apple Silicon Macs.",
                    isRecommendedForDevice: true
                )
            case "openai_whisper-small.en", "openai_whisper-small":
                return ModelPerformanceInfo(
                    level: .moderate,
                    badgeText: "Moderate (~6m)",
                    estimatedSpeedDescription: "~5–8 min for 30m audio",
                    recommendationNote: "Good accuracy, uses CPU cores.",
                    isRecommendedForDevice: false
                )
            default:
                return ModelPerformanceInfo(
                    level: .heavy,
                    badgeText: "🐢 Slow (15m+)",
                    estimatedSpeedDescription: "15+ min for 30m audio",
                    recommendationNote: "Requires Apple Silicon Neural Engine for fast performance.",
                    isRecommendedForDevice: false
                )
            }
        }
    }

    public static let availableModels: [TranscriptionModelOption] = [
        TranscriptionModelOption(
            id: "openai_whisper-large-v3_turbo",
            displayName: "Whisper Large v3 Turbo",
            accuracy: "Highest",
            speed: "Fast (Apple Neural Engine)",
            sizeDescription: "~950 MB",
            isRecommended: true,
            details: "State-of-the-art accuracy with high performance optimized for Apple Silicon Neural Engine. Best for complex meetings and accents."
        ),
        TranscriptionModelOption(
            id: "distil-whisper_distil-large-v3_turbo",
            displayName: "Distil-Whisper Large v3",
            accuracy: "Very High",
            speed: "Ultra Fast (6x)",
            sizeDescription: "~600 MB",
            isRecommended: false,
            details: "Distilled version of Whisper Large v3. Delivers high accuracy at 6x speed."
        ),
        TranscriptionModelOption(
            id: "openai_whisper-small.en",
            displayName: "Whisper Small (English)",
            accuracy: "High",
            speed: "Very Fast",
            sizeDescription: "~460 MB",
            isRecommended: false,
            details: "English-only model optimized for higher accuracy than Base with low memory usage."
        ),
        TranscriptionModelOption(
            id: "openai_whisper-small",
            displayName: "Whisper Small (Multilingual)",
            accuracy: "High",
            speed: "Fast",
            sizeDescription: "~460 MB",
            isRecommended: false,
            details: "Multilingual model with significantly fewer errors and missed words than Base."
        ),
        TranscriptionModelOption(
            id: "openai_whisper-base",
            displayName: "Whisper Base",
            accuracy: "Standard",
            speed: "Instant",
            sizeDescription: "~140 MB",
            isRecommended: false,
            details: "Default lightweight model. Fast and low memory footprint."
        ),
        TranscriptionModelOption(
            id: "openai_whisper-large-v3",
            displayName: "Whisper Large v3",
            accuracy: "Maximum",
            speed: "Moderate",
            sizeDescription: "~1.5 GB",
            isRecommended: false,
            details: "The full uncompressed Whisper Large v3 model for maximum possible word-recognition accuracy."
        )
    ]

    public static func isModelDownloaded(_ variant: String) -> Bool {
        let fileManager = FileManager.default
        let docBase = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(variant)
        if let docBase = docBase, fileManager.fileExists(atPath: docBase.appendingPathComponent("AudioEncoder.mlmodelc").path) {
            return true
        }
        let cacheBase = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(variant)
        if let cacheBase = cacheBase, fileManager.fileExists(atPath: cacheBase.appendingPathComponent("AudioEncoder.mlmodelc").path) {
            return true
        }
        return false
    }
}

public actor WhisperKitEngine: TranscriptionEngine {
    nonisolated public let name = "WhisperKit (CoreML Apple Silicon)"
    public private(set) var modelName: String
    var runner: (@Sendable (URL, (@Sendable (Double) -> Void)?) async throws -> String)?
    private var cachedWhisperKit: WhisperKit?

    public init(modelName: String = "openai_whisper-base") {
        self.modelName = modelName
    }

    public func setModelName(_ newModel: String) {
        if modelName != newModel {
            modelName = newModel
            cachedWhisperKit = nil
        }
    }

    public func setRunner(_ runner: (@Sendable (URL, (@Sendable (Double) -> Void)?) async throws -> String)?) {
        self.runner = runner
    }

    nonisolated(unsafe) public static var downloadOverride: (@Sendable (String, (@Sendable (Double) -> Void)?) async throws -> URL)?

    public static func downloadModel(
        variant: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if let override = downloadOverride {
            return try await override(variant, progress)
        }
        return try await WhisperKit.download(variant: variant) { p in
            progress?(p.fractionCompleted)
        }
    }

    private func getOrInitWhisperKit() async throws -> WhisperKit {
        if let existing = cachedWhisperKit {
            return existing
        }
        let config = WhisperKitConfig(model: modelName, verbose: false)
        let wk = try await WhisperKit(config)
        cachedWhisperKit = wk
        return wk
    }

    public func transcribe(audioFileURL: URL, progress: (@Sendable (Double) -> Void)?) async throws -> String {
        progress?(0.05)
        if let runner = runner {
            let res = try await runner(audioFileURL, progress)
            progress?(1.0)
            return res
        }

        let wk = try await getOrInitWhisperKit()
        progress?(0.15)

        let asset = AVURLAsset(url: audioFileURL)
        let durationSeconds = (try? await asset.load(.duration))?.seconds ?? 60.0
        let estimatedWindows = max(1, Int(ceil(durationSeconds / 30.0)))

        let decodeOptions = DecodingOptions(skipSpecialTokens: true)
        let results = try await wk.transcribe(
            audioPath: audioFileURL.path,
            decodeOptions: decodeOptions
        ) { transcriptionProgress in
            if Task.isCancelled {
                return false
            }
            let windowProgress = Double(transcriptionProgress.windowId + 1) / Double(estimatedWindows)
            let currentFraction = 0.15 + (windowProgress * 0.80)
            progress?(min(currentFraction, 0.98))
            return nil
        }
        progress?(1.0)

        let timedSegments = results.flatMap { $0.segments.map { (start: $0.start, text: $0.text) } }
        let formatted = TranscriptTurn.formatTimedSegments(timedSegments)
        if !formatted.isEmpty {
            return formatted
        }
        let rawJoined = results.map { $0.text }.joined(separator: "\n")
        return TranscriptTurn.stripSpecialTokens(rawJoined)
    }
}
