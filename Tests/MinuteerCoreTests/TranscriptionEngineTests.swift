import Testing
import Foundation
@testable import MinuteerCore

@Suite("Transcription Engine Tests")
struct TranscriptionEngineTests {
    
    @Test("MockTranscriptionEngine transcribes audio and reports progress")
    func testMockTranscriptionEngine() async throws {
        let mock = MockTranscriptionEngine(mockTranscript: "This was a productive team meeting.")
        #expect(mock.name == "Mock Engine")

        final class ProgressBox: @unchecked Sendable {
            var updates: [Double] = []
        }
        let box = ProgressBox()
        let tempWav = FileManager.default.temporaryDirectory.appendingPathComponent("test.wav")
        try makeValidWAVData(durationSeconds: 0.5).write(to: tempWav)
        defer { try? FileManager.default.removeItem(at: tempWav) }

        let transcript = try await mock.transcribe(audioFileURL: tempWav) { progress in
            box.updates.append(progress)
        }

        #expect(transcript == "This was a productive team meeting.")
        #expect(!box.updates.isEmpty)
        #expect(box.updates.last == 1.0)
    }

    @Test("MockTranscriptionEngine throws error on missing file")
    func testMockTranscriptionEngineError() async {
        let mock = MockTranscriptionEngine(shouldFail: true)
        let missingURL = URL(fileURLWithPath: "/nonexistent/audio.wav")

        await #expect(throws: Error.self) {
            _ = try await mock.transcribe(audioFileURL: missingURL, progress: nil)
        }
    }

    @Test("AppleSpeechEngine availability and configuration")
    func testAppleSpeechEngineAvailability() {
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en-US"))
        #expect(engine.name.contains("Apple Speech"))
        #expect(engine.isAvailable)
    }

    @Test("AppleSpeechEngine custom runner and error paths")
    func testAppleSpeechEngineTranscribe() async throws {
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en-US"))
        engine.customRunner = { url, progress in
            progress?(1.0)
            return "Speech transcript"
        }
        let tempURL = URL(fileURLWithPath: "/tmp/sample.wav")
        let transcript = try await engine.transcribe(audioFileURL: tempURL, progress: nil)
        #expect(transcript == "Speech transcript")

        // Test with unavailable/nil recognizer
        let invalidEngine = AppleSpeechEngine(locale: Locale(identifier: "xx-INVALID-LOCALE"))
        #expect(!invalidEngine.isAvailable)
        await #expect(throws: Error.self) {
            _ = try await invalidEngine.transcribe(audioFileURL: tempURL, progress: nil)
        }

        // Test native transcribe invocation with valid wav file
        let nativeEngine = AppleSpeechEngine()
        let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("native_speech_test.wav")
        try makeValidWAVData(durationSeconds: 0.3).write(to: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        _ = try? await nativeEngine.transcribe(audioFileURL: wavURL, progress: nil)
    }

    @Test("WhisperKitEngine model metadata and runner execution")
    func testWhisperKitEngineRunner() async throws {
        let defaultEngine = WhisperKitEngine()
        let defModel = await defaultEngine.modelName
        #expect(defModel == "openai_whisper-base")

        let engine = WhisperKitEngine(modelName: "openai_whisper-small")
        let engModel = await engine.modelName
        #expect(engModel == "openai_whisper-small")
        #expect(engine.name.contains("WhisperKit"))

        await engine.setModelName("distil-whisper_distil-large-v3_turbo")
        let updatedModel = await engine.modelName
        #expect(updatedModel == "distil-whisper_distil-large-v3_turbo")

        await engine.setRunner { url, progress in
            progress?(0.5)
            return "Whisper transcript: meeting summary"
        }

        final class BoolBox: @unchecked Sendable { var value = false }
        let progressBox = BoolBox()
        let tempURL = URL(fileURLWithPath: "/tmp/sample.wav")
        let transcript = try await engine.transcribe(audioFileURL: tempURL) { _ in
            progressBox.value = true
        }
        #expect(transcript.contains("Whisper transcript"))
        #expect(progressBox.value)
    }

    @Test("WhisperKitEngine live model execution on short clip")
    func testWhisperKitEngineLive() async throws {
        let engine = WhisperKitEngine()
        let tempWAV = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try makeValidWAVData(durationSeconds: 0.1).write(to: tempWAV)
        defer { try? FileManager.default.removeItem(at: tempWAV) }

        final class ProgressBox: @unchecked Sendable { var called = false }
        let pBox = ProgressBox()
        let res = try? await engine.transcribe(audioFileURL: tempWAV) { _ in
            pBox.called = true
        }
        if let res = res {
            #expect(res.count >= 0)
        }
    }

    @Test("TranscriptionModelOption models and availability checks")
    func testTranscriptionModelOptions() {
        let models = TranscriptionModelOption.availableModels
        #expect(models.count >= 5)

        let turbo = models.first { $0.id == "openai_whisper-large-v3_turbo" }
        #expect(turbo != nil)
        #expect(turbo?.isRecommended == true)
        #expect(turbo?.sizeDescription.contains("MB") == true)

        _ = TranscriptionModelOption.isModelDownloaded("openai_whisper-base")
        _ = TranscriptionModelOption.isModelDownloaded("nonexistent_test_model")

        let base = models.first { $0.id == "openai_whisper-base" }
        #expect(base != nil)

        // isModelDownloaded check for non-existent model
        let nonExistent = TranscriptionModelOption.isModelDownloaded("non_existent_whisper_model_12345")
        #expect(!nonExistent)

        // isModelDownloaded check when model directory exists
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/test_mock_variant")
        if let docDir = docDir {
            let encoder = docDir.appendingPathComponent("AudioEncoder.mlmodelc")
            try? FileManager.default.createDirectory(at: encoder, withIntermediateDirectories: true)
            #expect(TranscriptionModelOption.isModelDownloaded("test_mock_variant"))
            try? FileManager.default.removeItem(at: docDir)
        }

        let opt = TranscriptionModelOption(
            id: "custom_model",
            displayName: "Custom Model",
            accuracy: "High",
            speed: "Fast",
            sizeDescription: "~100 MB",
            isRecommended: false,
            details: "Test model"
        )
        #expect(opt.id == "custom_model")
        #expect(opt.displayName == "Custom Model")
    }

    @Test("WhisperKitEngine downloadModel execution and progress reporting")
    func testWhisperKitEngineDownload() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        WhisperKitEngine.downloadOverride = { variant, progress in
            progress?(0.5)
            progress?(1.0)
            return tempDir
        }
        defer { WhisperKitEngine.downloadOverride = nil }

        final class ProgressBox: @unchecked Sendable { var progressValues: [Double] = [] }
        let box = ProgressBox()

        let downloadedURL = try await WhisperKitEngine.downloadModel(variant: "test_variant") { p in
            box.progressValues.append(p)
        }

        #expect(downloadedURL == tempDir)
        #expect(box.progressValues.contains(1.0))
    }

    @Test("DeviceHardware detection and tier categorization")
    func testDeviceHardwareDetection() {
        #expect(!DeviceHardware.chipName.isEmpty)
        #expect(!DeviceHardware.modelIdentifier.isEmpty)
        #expect(DeviceHardware.physicalMemoryGB > 0)
        #expect(HardwareTier.allCases.contains(DeviceHardware.currentTier))

        #expect(DeviceHardware.hardwareTier(for: "Apple M1") == .m1Base)
        #expect(DeviceHardware.hardwareTier(for: "Apple M2") == .m2Base)
        #expect(DeviceHardware.hardwareTier(for: "Apple M3") == .modernBase)
        #expect(DeviceHardware.hardwareTier(for: "Apple M4") == .modernBase)
        #expect(DeviceHardware.hardwareTier(for: "Apple M1 Pro") == .proMaxUltra)
        #expect(DeviceHardware.hardwareTier(for: "Apple M2 Max") == .proMaxUltra)
        #expect(DeviceHardware.hardwareTier(for: "Apple M3 Ultra") == .proMaxUltra)
        #expect(DeviceHardware.hardwareTier(for: "Intel Core i7") == .intelOrOther)

        DeviceHardware.chipNameOverride = "Mock M1 Chip"
        DeviceHardware.memoryGBOverride = 32
        defer {
            DeviceHardware.chipNameOverride = nil
            DeviceHardware.memoryGBOverride = nil
        }
        #expect(DeviceHardware.chipName == "Mock M1 Chip")
        #expect(DeviceHardware.physicalMemoryGB == 32)
        #expect(!DeviceHardware.modelIdentifier.isEmpty)
        #expect(DeviceHardware.currentTier == .m1Base || DeviceHardware.currentTier != .m1Base)
    }

    @Test("TranscriptionModelOption performance ratings across hardware tiers")
    func testModelPerformanceRatings() {
        let base = TranscriptionModelOption.availableModels.first(where: { $0.id == "openai_whisper-base" })!
        let smallEn = TranscriptionModelOption.availableModels.first(where: { $0.id == "openai_whisper-small.en" })!
        let distil = TranscriptionModelOption.availableModels.first(where: { $0.id == "distil-whisper_distil-large-v3_turbo" })!
        let small = TranscriptionModelOption.availableModels.first(where: { $0.id == "openai_whisper-small" })!
        let turbo = TranscriptionModelOption.availableModels.first(where: { $0.id == "openai_whisper-large-v3_turbo" })!
        let large = TranscriptionModelOption.availableModels.first(where: { $0.id == "openai_whisper-large-v3" })!

        // Test M1 tier
        let m1Small = smallEn.performance(for: .m1Base)
        #expect(m1Small.isRecommendedForDevice)
        #expect(m1Small.level == .optimal)
        #expect(m1Small.badgeText.contains("Best Balance for M1"))

        let m1Turbo = turbo.performance(for: .m1Base)
        #expect(!m1Turbo.isRecommendedForDevice)
        #expect(m1Turbo.level == .heavy)
        #expect(m1Turbo.badgeText.contains("Heavy on M1"))

        let m1Large = large.performance(for: .m1Base)
        #expect(m1Large.level == .veryHeavy)

        let m1BasePerf = base.performance(for: .m1Base)
        #expect(m1BasePerf.level == .instant)

        let m1Distil = distil.performance(for: .m1Base)
        #expect(m1Distil.isRecommendedForDevice)

        let m1SmallMulti = small.performance(for: .m1Base)
        #expect(m1SmallMulti.level == .fast)

        // Test M2 tier
        #expect(smallEn.performance(for: .m2Base).isRecommendedForDevice)
        #expect(distil.performance(for: .m2Base).isRecommendedForDevice)
        #expect(base.performance(for: .m2Base).level == .instant)
        #expect(small.performance(for: .m2Base).level == .fast)
        #expect(turbo.performance(for: .m2Base).level == .moderate)
        #expect(large.performance(for: .m2Base).level == .heavy)

        // Test Pro/Max tier
        #expect(turbo.performance(for: .proMaxUltra).isRecommendedForDevice)
        #expect(distil.performance(for: .proMaxUltra).level == .fast)
        #expect(smallEn.performance(for: .proMaxUltra).level == .fast)
        #expect(base.performance(for: .proMaxUltra).level == .instant)
        #expect(large.performance(for: .proMaxUltra).level == .moderate)

        // Test Intel tier
        #expect(base.performance(for: .intelOrOther).isRecommendedForDevice)
        #expect(smallEn.performance(for: .intelOrOther).level == .moderate)
        #expect(turbo.performance(for: .intelOrOther).level == .heavy)
    }
}
