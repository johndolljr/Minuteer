import Testing
import Foundation
@testable import MinuteerCore

@Suite("Audio Fingerprint Engine & Speaker Voiceprint Tests")
struct AudioFingerprintEngineTests {

    @Test("Vector normalization and cosine similarity")
    func testNormalizationAndSimilarity() {
        let v1: [Float] = [1.0, 0.0, 0.0]
        let v2: [Float] = [1.0, 0.0, 0.0]
        let v3: [Float] = [0.0, 1.0, 0.0]
        let v4: [Float] = [-1.0, 0.0, 0.0]

        let norm1 = AudioFingerprintEngine.normalize(v1)
        #expect(abs(norm1[0] - 1.0) < 1e-4)

        let simIdentical = AudioFingerprintEngine.similarity(norm1, AudioFingerprintEngine.normalize(v2))
        #expect(abs(simIdentical - 1.0) < 1e-4)

        let simOrthogonal = AudioFingerprintEngine.similarity(norm1, AudioFingerprintEngine.normalize(v3))
        #expect(abs(simOrthogonal - 0.0) < 1e-4)

        let simOpposite = AudioFingerprintEngine.similarity(norm1, AudioFingerprintEngine.normalize(v4))
        #expect(abs(simOpposite - (-1.0)) < 1e-4)

        // Edge cases
        #expect(AudioFingerprintEngine.normalize([]).isEmpty)
        #expect(AudioFingerprintEngine.similarity([], []) == 0)
        #expect(AudioFingerprintEngine.similarity([1.0], [1.0, 2.0]) == 0)
    }

    @Test("Running voiceprint updates across multiple sessions")
    func testVoiceprintOnlineLearning() {
        let firstPrint: [Float] = [1.0, 0.0, 0.0, 0.0]
        let (p1, count1) = AudioFingerprintEngine.updateVoiceprint(existing: nil, sampleCount: 0, newPrint: firstPrint)
        #expect(count1 == 1)
        #expect(p1.count == 4)

        let secondPrint: [Float] = [0.0, 1.0, 0.0, 0.0]
        let (p2, count2) = AudioFingerprintEngine.updateVoiceprint(existing: p1, sampleCount: count1, newPrint: secondPrint)
        #expect(count2 == 2)
        // Average should have both components
        #expect(p2[0] > 0.5)
        #expect(p2[1] > 0.5)

        // Ensure normalized
        let sim = AudioFingerprintEngine.similarity(p2, p2)
        #expect(abs(sim - 1.0) < 1e-4)
    }

    @Test("Speaker identification from directory using voiceprints")
    func testIdentifySpeaker() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directoryFile = tempDir.appendingPathComponent("speakers.json")
        let directory = SpeakerDirectory(fileURL: directoryFile)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var raviPrint = [Float](repeating: 0.05, count: AudioFingerprintEngine.featureDimension)
        raviPrint[0] = 0.9
        let normalizedRavi = AudioFingerprintEngine.normalize(raviPrint)

        var johnPrint = [Float](repeating: 0.05, count: AudioFingerprintEngine.featureDimension)
        johnPrint[5] = 0.9
        let normalizedJohn = AudioFingerprintEngine.normalize(johnPrint)

        let ravi = SpeakerProfile(name: "Ravi", voiceprint: normalizedRavi, sampleCount: 5)
        let john = SpeakerProfile(name: "John", voiceprint: normalizedJohn, sampleCount: 3)
        directory.addSpeaker(ravi)
        directory.addSpeaker(john)

        // Query matching Ravi closely
        var testQuery = normalizedRavi
        testQuery[1] = 0.1
        let normalizedQuery = AudioFingerprintEngine.normalize(testQuery)

        let match = AudioFingerprintEngine.identifySpeaker(voiceprint: normalizedQuery, in: directory, threshold: 0.70)
        #expect(match != nil)
        #expect(match?.speaker.name == "Ravi")
        #expect((match?.confidence ?? 0) >= 0.70)

        // Query that matches neither
        var unknownPrint = [Float](repeating: 0.0, count: AudioFingerprintEngine.featureDimension)
        unknownPrint[20] = 1.0
        let unknownMatch = AudioFingerprintEngine.identifySpeaker(voiceprint: unknownPrint, in: directory, threshold: 0.85)
        #expect(unknownMatch == nil)
    }

    @Test("Audio voiceprint extraction from WAV file")
    func testVoiceprintExtraction() throws {
        let tempWAV = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try makeValidWAVData(durationSeconds: 2.0).write(to: tempWAV)
        defer { try? FileManager.default.removeItem(at: tempWAV) }

        // Nonexistent file returns nil
        let missingURL = URL(fileURLWithPath: "/nonexistent/path.wav")
        let missingResult = try? AudioFingerprintEngine.extractVoiceprint(from: missingURL, timeRanges: [(0, 1)])
        #expect(missingResult == nil)

        // Empty time ranges returns nil
        let emptyResult = try? AudioFingerprintEngine.extractVoiceprint(from: tempWAV, timeRanges: [])
        #expect(emptyResult == nil)

        // Valid ranges extract feature vector using active tone data
        let toneWAV = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_tone.wav")
        try makeToneWAVData(durationSeconds: 2.0).write(to: toneWAV)
        defer { try? FileManager.default.removeItem(at: toneWAV) }

        let extracted = try? AudioFingerprintEngine.extractVoiceprint(
            from: toneWAV,
            timeRanges: [(start: 0.0, end: 1.5)]
        )
        #expect(extracted != nil)
        if let features = extracted {
            #expect(features.count == AudioFingerprintEngine.featureDimension)
            let norm = AudioFingerprintEngine.similarity(features, features)
            #expect(abs(norm - 1.0) < 1e-4)
        }

        // Stereo audio downmixing test
        let stereoWAV = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_stereo.wav")
        try makeStereoToneWAVData(durationSeconds: 2.0).write(to: stereoWAV)
        defer { try? FileManager.default.removeItem(at: stereoWAV) }

        let stereoExtracted = try? AudioFingerprintEngine.extractVoiceprint(
            from: stereoWAV,
            timeRanges: [(start: 0.0, end: 1.5)]
        )
        #expect(stereoExtracted != nil)

        // Default instance init
        _ = AudioFingerprintEngine()
    }

    @Test("Automatic speaker identification across transcript turns")
    func testIdentifySpeakersInTranscript() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tempWAV = tempDir.appendingPathComponent("test_speech.wav")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try makeToneWAVData(durationSeconds: 2.0).write(to: tempWAV)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let directory = SpeakerDirectory(fileURL: tempDir.appendingPathComponent("speakers.json"))
        let extractedPrint = try? AudioFingerprintEngine.extractVoiceprint(
            from: tempWAV,
            timeRanges: [(start: 0.0, end: 1.0)]
        )

        if let validPrint = extractedPrint {
            let knownSpeaker = SpeakerProfile(name: "Alice", voiceprint: validPrint, sampleCount: 1)
            directory.addSpeaker(knownSpeaker)

            let inputTurns = [
                TranscriptTurn(id: 0, speaker: "Speaker 1", timestamp: "00:00", text: "Hello everyone."),
                TranscriptTurn(id: 1, speaker: "Speaker 2", timestamp: "00:01", text: "Hi there.")
            ]

            let recognizedTurns = await AudioFingerprintEngine.identifySpeakers(
                in: tempWAV,
                turns: inputTurns,
                directory: directory,
                threshold: 0.50
            )

            #expect(recognizedTurns[0].speaker == "Alice")

            // Test background fingerprinting trigger
            AudioFingerprintEngine.fingerprintSpeakerInBackground(
                audioURL: tempWAV,
                speakerName: "Alice",
                turns: recognizedTurns,
                directory: directory
            )
            // Guard conditions
            AudioFingerprintEngine.fingerprintSpeakerInBackground(
                audioURL: tempWAV,
                speakerName: "Speaker 2",
                turns: recognizedTurns,
                directory: directory
            )
            AudioFingerprintEngine.fingerprintSpeakerInBackground(
                audioURL: URL(fileURLWithPath: "/nonexistent.wav"),
                speakerName: "Alice",
                turns: recognizedTurns,
                directory: directory
            )
        }
    }

    @Test("SpeakerDirectory updateVoiceprint and backward compatibility")
    func testSpeakerDirectoryVoiceprint() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = tempDir.appendingPathComponent("speakers.json")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let directory = SpeakerDirectory(fileURL: file)
        var speaker = SpeakerProfile(name: "Bob", aliases: ["Bobby"])
        directory.addSpeaker(speaker)
        speaker.contextNotes = "Updated notes"
        directory.updateSpeaker(speaker)

        let mockPrint = [Float](repeating: 0.1, count: AudioFingerprintEngine.featureDimension)
        directory.updateVoiceprint(forSpeakerNamed: "Bobby", newVoiceprint: mockPrint)

        let updated = directory.getSpeaker(named: "Bob")
        #expect(updated?.voiceprint != nil)
        #expect(updated?.sampleCount == 1)

        directory.deleteSpeaker(id: speaker.id)
        #expect(directory.getSpeaker(named: "Bob") == nil)

        // Evaluate fallback closures in init(from: decoder)
        let minimalJSON = """
        {"id": "33333333-4444-5555-6666-777777777777", "name": "Minimal Speaker"}
        """.data(using: .utf8)!
        let minimalSpeaker = try JSONDecoder().decode(SpeakerProfile.self, from: minimalJSON)
        #expect(minimalSpeaker.aliases.isEmpty)
        #expect(minimalSpeaker.contextNotes.isEmpty)

        // Test default nil fileURL
        let nilDir = SpeakerDirectory(fileURL: nil)
        #expect(!nilDir.allSpeakers.isEmpty || nilDir.allSpeakers.isEmpty)

        // Backward compatibility: Decode legacy JSON without voiceprint or sampleCount
        let legacyJSON = """
        [
            {
                "id": "11111111-2222-3333-4444-555555555555",
                "name": "Legacy Speaker",
                "aliases": [],
                "contextNotes": "Notes"
            }
        ]
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode([SpeakerProfile].self, from: legacyJSON)
        #expect(decoded.count == 1)
        #expect(decoded[0].name == "Legacy Speaker")
        #expect(decoded[0].voiceprint == nil)
        #expect(decoded[0].sampleCount == 0)
    }

    @Test("Unsupervised acoustic clustering and speaker diarization across anonymous turns")
    func testAcousticClusteringAnonymousTurns() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempWAV = tempDir.appendingPathComponent("multi_tone.wav")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a 6-second audio file:
        // 0.0 - 2.0s: 300Hz tone (Speaker 1)
        // 2.0 - 4.0s: 2500Hz tone (Speaker 2)
        // 4.0 - 6.0s: 300Hz tone (Speaker 1 again)
        var pcmSamples: [Int16] = []
        let sampleRate = 16000
        for i in 0..<(sampleRate * 2) {
            let t = Double(i) / Double(sampleRate)
            pcmSamples.append(Int16(sin(2.0 * .pi * 300.0 * t) * 16000.0))
        }
        for i in 0..<(sampleRate * 2) {
            let t = Double(i) / Double(sampleRate)
            pcmSamples.append(Int16(sin(2.0 * .pi * 2500.0 * t) * 16000.0))
        }
        for i in 0..<(sampleRate * 2) {
            let t = Double(i) / Double(sampleRate)
            pcmSamples.append(Int16(sin(2.0 * .pi * 300.0 * t) * 16000.0))
        }

        var wavData = Data()
        let subchunk2Size = pcmSamples.count * 2
        let chunkSize = 36 + subchunk2Size
        wavData.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(chunkSize).littleEndian) { Array($0) })
        wavData.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
        wavData.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
        wavData.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(subchunk2Size).littleEndian) { Array($0) })
        for s in pcmSamples {
            wavData.append(contentsOf: withUnsafeBytes(of: s.littleEndian) { Array($0) })
        }
        try wavData.write(to: tempWAV)

        let directory = SpeakerDirectory(fileURL: tempDir.appendingPathComponent("speakers.json"))

        let turns = [
            TranscriptTurn(id: 0, speaker: "Speaker 1", timestamp: "00:00", text: "Speaker 1 opening."),
            TranscriptTurn(id: 1, speaker: "Speaker 2", timestamp: "00:02", text: "Speaker 2 reply."),
            TranscriptTurn(id: 2, speaker: "Speaker 1", timestamp: "00:04", text: "Speaker 1 closing."),
            TranscriptTurn(id: 3, speaker: "Dave", timestamp: "00:05", text: "Explicit named speaker.")
        ]

        let clusteredTurns = await AudioFingerprintEngine.identifySpeakers(
            in: tempWAV,
            turns: turns,
            directory: directory,
            threshold: 0.90
        )

        #expect(clusteredTurns.count == 4)
        #expect(clusteredTurns[0].speaker == "Speaker 1")
        #expect(clusteredTurns[1].speaker == "Speaker 2")
        #expect(clusteredTurns[2].speaker == "Speaker 1")
        #expect(clusteredTurns[3].speaker == "Dave")

        // Test forceReidentify: true re-evaluates turns even if already named
        let forcedTurns = await AudioFingerprintEngine.identifySpeakers(
            in: tempWAV,
            turns: turns,
            directory: directory,
            threshold: 0.90,
            forceReidentify: true
        )
        #expect(forcedTurns.count == 4)
        #expect(forcedTurns[0].speaker == "Speaker 1")
        #expect(forcedTurns[1].speaker == "Speaker 2")
        #expect(forcedTurns[2].speaker == "Speaker 1")
        #expect(forcedTurns[3].speaker == "Speaker 1") // Tone at 00:05 matches 300Hz (Speaker 1)

        // Auto-enroll new speaker in directory when assigned
        directory.updateVoiceprint(forSpeakerNamed: "Dave", newVoiceprint: [Float](repeating: 0.1, count: AudioFingerprintEngine.featureDimension))
        #expect(directory.getSpeaker(named: "Dave") != nil)
        directory.updateVoiceprint(forSpeakerNamed: "Speaker 1", newVoiceprint: [Float](repeating: 0.1, count: AudioFingerprintEngine.featureDimension))
        #expect(directory.getSpeaker(named: "Speaker 1") == nil)

        // Test nil / missing file and empty turns
        let empty = await AudioFingerprintEngine.identifySpeakers(
            in: tempWAV,
            turns: [],
            directory: directory
        )
        #expect(empty.isEmpty)

        let missing = await AudioFingerprintEngine.identifySpeakers(
            in: URL(fileURLWithPath: "/missing.wav"),
            turns: turns,
            directory: directory
        )
        #expect(missing == turns)

        // Test trainAndPropagateSpeaker: assigning one turn trains voiceprint and propagates to remaining turns
        let propagationTurns = [
            TranscriptTurn(id: 0, speaker: "Glenn", timestamp: "00:00", text: "Glenn speaking 300Hz."),
            TranscriptTurn(id: 1, speaker: "Speaker 2", timestamp: "00:02", text: "Unrelated 2500Hz."),
            TranscriptTurn(id: 2, speaker: "Speaker 1", timestamp: "00:04", text: "Also Glenn 300Hz.")
        ]

        let (propagated, matchCount) = await AudioFingerprintEngine.trainAndPropagateSpeaker(
            audioURL: tempWAV,
            speakerName: "Glenn",
            turns: propagationTurns,
            directory: directory,
            threshold: 0.65
        )

        #expect(matchCount == 1)
        #expect(propagated[0].speaker == "Glenn")
        #expect(propagated[1].speaker == "Speaker 2")
        #expect(propagated[2].speaker == "Glenn") // Turn 2 auto-matched to Glenn!

        // Test edge cases: missing file, empty turns, generic speaker
        let propMissing = await AudioFingerprintEngine.trainAndPropagateSpeaker(
            audioURL: URL(fileURLWithPath: "/missing.wav"),
            speakerName: "Glenn",
            turns: propagationTurns,
            directory: directory
        )
        #expect(propMissing.matchedCount == 0)

        let propGeneric = await AudioFingerprintEngine.trainAndPropagateSpeaker(
            audioURL: tempWAV,
            speakerName: "Speaker 1",
            turns: propagationTurns,
            directory: directory
        )
        #expect(propGeneric.matchedCount == 0)
    }
}
