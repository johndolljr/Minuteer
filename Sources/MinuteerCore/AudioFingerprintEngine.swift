import Foundation
import AVFoundation
import Accelerate

/// Lightweight, 100% on-device acoustic voiceprint engine.
/// Extracts compact mathematical feature vectors (~256 bytes) from speaker audio turns
/// without storing any audio recordings or slices on disk.
public struct AudioFingerprintEngine: Sendable {
    public static let featureDimension = 48
    public static let defaultMatchThreshold: Float = 0.58

    public init() {}

    /// Extract a compact, normalized acoustic voiceprint vector (48 floats) for specific time ranges in an audio file.
    public static func extractVoiceprint(
        from audioURL: URL,
        timeRanges: [(start: TimeInterval, end: TimeInterval)]
    ) throws -> [Float]? {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
        guard !timeRanges.isEmpty else { return nil }

        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        let sampleRate = Float(format.sampleRate)
        guard sampleRate > 0 else { return nil }

        // Process up to 45 seconds of speech across the speaker's turns to ensure fast, consistent fingerprinting
        var totalSamplesCollected: [Float] = []
        let maxSamples = Int(sampleRate * 45.0)

        for range in timeRanges {
            guard totalSamplesCollected.count < maxSamples else { break }
            let duration = max(0.5, range.end - range.start)
            let startFrame = AVAudioFramePosition(max(0, range.start * Double(sampleRate)))
            guard startFrame < file.length else { continue }
            let availableFrames = max(0, file.length - startFrame)
            let requestedFrames = Int64(duration * Double(sampleRate))
            let remainingCapacity = Int64(maxSamples - totalSamplesCollected.count)
            let framesToRead = AVAudioFrameCount(min(requestedFrames, availableFrames, remainingCapacity))
            guard framesToRead > 256 else { continue }

            file.framePosition = startFrame
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else { continue }
            do {
                try file.read(into: pcmBuffer, frameCount: framesToRead)
            } catch {
                continue
            }

            let readCount = Int(pcmBuffer.frameLength)
            guard readCount > 0, let channelData = pcmBuffer.floatChannelData else { continue }

            // Extract mono channel or downmix
            if format.channelCount == 1 {
                let channelPtr = channelData[0]
                totalSamplesCollected.append(contentsOf: UnsafeBufferPointer(start: channelPtr, count: readCount))
            } else {
                let ch0 = channelData[0]
                let ch1 = channelData[1]
                var monoChunk = [Float](repeating: 0, count: readCount)
                for i in 0..<readCount {
                    monoChunk[i] = (ch0[i] + ch1[i]) * 0.5
                }
                totalSamplesCollected.append(contentsOf: monoChunk)
            }
        }

        guard totalSamplesCollected.count >= 2048 else { return nil }
        return computeAcousticFeatures(samples: totalSamplesCollected, sampleRate: sampleRate)
    }

    /// Computes acoustic spectrum and formant distribution features using Accelerate vDSP
    private static func computeAcousticFeatures(samples: [Float], sampleRate: Float) -> [Float]? {
        let frameSize = 1024
        let hopSize = 512
        let numBands = 32
        guard samples.count >= frameSize else { return nil }

        let frameCount = (samples.count - frameSize) / hopSize
        guard frameCount > 0 else { return nil }

        // Pre-compute Hann window
        var window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))

        let log2n = vDSP_Length(log2(Double(frameSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let halfSize = frameSize / 2
        var realParts = [Float](repeating: 0, count: halfSize)
        var imagParts = [Float](repeating: 0, count: halfSize)
        var windowed = [Float](repeating: 0, count: frameSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)

        var bandAccumulator = [Float](repeating: 0, count: numBands)
        var centroidSum: Float = 0
        var rolloffSum: Float = 0
        var energySum: Float = 0
        var speechFramesCount = 0

        let maxFreq = min(sampleRate * 0.5, 7500.0)
        let minFreq: Float = 120.0
        let binFreqWidth = (sampleRate * 0.5) / Float(halfSize)

        // Precompute bin edges for 32 log-spaced frequency bands
        var bandBinRanges: [(start: Int, end: Int)] = []
        for b in 0..<numBands {
            let lowFreq = minFreq * pow(maxFreq / minFreq, Float(b) / Float(numBands))
            let highFreq = minFreq * pow(maxFreq / minFreq, Float(b + 1) / Float(numBands))
            let startBin = max(0, min(halfSize - 1, Int(lowFreq / binFreqWidth)))
            let endBin = max(startBin + 1, min(halfSize, Int(highFreq / binFreqWidth)))
            bandBinRanges.append((start: startBin, end: endBin))
        }

        for f in 0..<frameCount {
            let offset = f * hopSize
            guard offset + frameSize <= samples.count else { break }

            samples.withUnsafeBufferPointer { srcPtr in
                guard let base = srcPtr.baseAddress else { return }
                vDSP_vmul(base.advanced(by: offset), 1, window, 1, &windowed, 1, vDSP_Length(frameSize))
            }

            // Unpack into split complex for vDSP FFT
            windowed.withUnsafeBufferPointer { wPtr in
                guard let base = wPtr.baseAddress else { return }
                base.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPtr in
                    realParts.withUnsafeMutableBufferPointer { rPtr in
                        imagParts.withUnsafeMutableBufferPointer { iPtr in
                            guard let rBase = rPtr.baseAddress, let iBase = iPtr.baseAddress else { return }
                            var split = DSPSplitComplex(realp: rBase, imagp: iBase)
                            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfSize))
                            vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                            vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
                        }
                    }
                }
            }

            var frameEnergy: Float = 0
            vDSP_sve(magnitudes, 1, &frameEnergy, vDSP_Length(halfSize))

            // Ignore quiet background noise / silence frames
            guard frameEnergy > 1e-4 else { continue }
            speechFramesCount += 1

            // 1. Spectral bands accumulation (log energy)
            for b in 0..<numBands {
                let range = bandBinRanges[b]
                let count = range.end - range.start
                if count > 0 {
                    var bandSum: Float = 0
                    vDSP_sve(Array(magnitudes[range.start..<range.end]), 1, &bandSum, vDSP_Length(count))
                    bandAccumulator[b] += log1p(bandSum)
                }
            }

            // 2. Spectral Centroid
            var weightedSum: Float = 0
            for i in 0..<halfSize {
                weightedSum += Float(i) * magnitudes[i]
            }
            let centroid = (weightedSum / frameEnergy) / Float(halfSize)
            centroidSum += centroid

            // 3. Spectral Rolloff (85% energy concentration)
            let targetRolloffEnergy = frameEnergy * 0.85
            var runningEnergy: Float = 0
            var rolloffBin = halfSize - 1
            for i in 0..<halfSize {
                runningEnergy += magnitudes[i]
                if runningEnergy >= targetRolloffEnergy {
                    rolloffBin = i
                    break
                }
            }
            rolloffSum += Float(rolloffBin) / Float(halfSize)
            energySum += log1p(frameEnergy)
        }

        guard speechFramesCount >= 3 else { return nil }

        let invCount = 1.0 / Float(speechFramesCount)
        var featureVector = [Float](repeating: 0, count: featureDimension)

        // First 32 features: Normalized spectral band energies
        for b in 0..<numBands {
            featureVector[b] = bandAccumulator[b] * invCount
        }

        // Spectral shape metrics
        featureVector[32] = centroidSum * invCount
        featureVector[33] = rolloffSum * invCount
        featureVector[34] = energySum * invCount

        // Standard deviations and contrasts across frequency bins
        var meanBand: Float = 0
        vDSP_meanv(featureVector, 1, &meanBand, vDSP_Length(numBands))
        for b in 0..<12 {
            let diff = featureVector[b * 2] - meanBand
            featureVector[35 + b] = diff
        }

        featureVector[47] = Float(speechFramesCount) / Float(frameCount)

        return normalize(featureVector)
    }

    /// L2 normalize a feature vector
    public static func normalize(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return [] }
        var sumSquares: Float = 0
        vDSP_svesq(vector, 1, &sumSquares, vDSP_Length(vector.count))
        let norm = sqrt(sumSquares)
        guard norm > 1e-6 else { return vector }
        var result = [Float](repeating: 0, count: vector.count)
        var scale = 1.0 / norm
        vDSP_vsmul(vector, 1, &scale, &result, 1, vDSP_Length(vector.count))
        return result
    }

    /// Computes cosine similarity between two normalized acoustic vectors (-1.0 to 1.0)
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return max(-1.0, min(1.0, dot))
    }

    /// Performs running weighted average update of a speaker's voiceprint across meetings
    public static func updateVoiceprint(
        existing: [Float]?,
        sampleCount: Int,
        newPrint: [Float]
    ) -> (updated: [Float], newCount: Int) {
        guard let existing = existing, existing.count == newPrint.count, sampleCount > 0 else {
            return (normalize(newPrint), 1)
        }
        // Running weighted mean gives slightly more weight to recent samples while stabilizing
        let weightOld = Float(min(sampleCount, 20))
        let weightNew: Float = 1.0
        let totalWeight = weightOld + weightNew

        var blended = [Float](repeating: 0, count: existing.count)
        for i in 0..<existing.count {
            blended[i] = (existing[i] * weightOld + newPrint[i] * weightNew) / totalWeight
        }
        return (normalize(blended), sampleCount + 1)
    }

    /// Identify the best matching known speaker profile for an acoustic voiceprint
    public static func identifySpeaker(
        voiceprint: [Float],
        in directory: SpeakerDirectory,
        threshold: Float = defaultMatchThreshold
    ) -> (speaker: SpeakerProfile, confidence: Float)? {
        let speakers = directory.allSpeakers.filter { $0.voiceprint != nil && $0.voiceprint?.count == voiceprint.count }
        guard !speakers.isEmpty else { return nil }

        var bestMatch: SpeakerProfile?
        var bestScore: Float = -1.0

        for speaker in speakers {
            guard let spkPrint = speaker.voiceprint else { continue }
            let score = similarity(voiceprint, spkPrint)
            if score > bestScore {
                bestScore = score
                bestMatch = speaker
            }
        }

        if let best = bestMatch, bestScore >= threshold {
            return (best, bestScore)
        }
        return nil
    }

    /// Automatically identify speakers in a transcript given the recording's audio file
    public static func identifySpeakers(
        in audioURL: URL,
        turns: [TranscriptTurn],
        directory: SpeakerDirectory,
        threshold: Float = defaultMatchThreshold
    ) async -> [TranscriptTurn] {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return turns }
        let speakersWithVoiceprints = directory.allSpeakers.filter { $0.voiceprint != nil }
        guard !speakersWithVoiceprints.isEmpty else { return turns }

        // Find all detected generic speaker labels, e.g. "Speaker 1", "Speaker 2"
        let uniqueSpeakers = Array(Set(turns.map { $0.speaker })).filter {
            $0.lowercased().hasPrefix("speaker")
        }
        guard !uniqueSpeakers.isEmpty else { return turns }

        var updatedTurns = turns

        for genericSpeaker in uniqueSpeakers {
            let speakerTurns = turns.filter { $0.speaker == genericSpeaker }
            var timeRanges: [(start: TimeInterval, end: TimeInterval)] = []

            for turn in speakerTurns {
                if let sec = turn.timestampSeconds {
                    // Turn duration estimated between 2 to 15 seconds
                    timeRanges.append((start: sec, end: sec + 8.0))
                }
            }

            guard !timeRanges.isEmpty else { continue }
            guard let print = try? extractVoiceprint(from: audioURL, timeRanges: timeRanges) else { continue }

            if let (matched, _) = identifySpeaker(voiceprint: print, in: directory, threshold: threshold) {
                updatedTurns = TranscriptTurn.renameSpeaker(in: updatedTurns, from: genericSpeaker, to: matched.name)
            }
        }

        return updatedTurns
    }

    /// Asynchronously extracts and updates a speaker's voiceprint in the background when identified
    public static func fingerprintSpeakerInBackground(
        audioURL: URL,
        speakerName: String,
        turns: [TranscriptTurn],
        directory: SpeakerDirectory = .shared
    ) {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
        let cleanName = speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanName.lowercased().hasPrefix("speaker") else { return }

        // Gather turns attributed to this speaker
        let matchingTurns = turns.filter { $0.speaker.caseInsensitiveCompare(cleanName) == .orderedSame }
        guard !matchingTurns.isEmpty else { return }

        var timeRanges: [(start: TimeInterval, end: TimeInterval)] = []
        for (i, turn) in matchingTurns.enumerated() {
            guard let start = turn.timestampSeconds else { continue }
            let nextStart: TimeInterval
            if i + 1 < matchingTurns.count, let nSec = matchingTurns[i + 1].timestampSeconds, nSec > start {
                nextStart = min(start + 15.0, nSec)
            } else {
                nextStart = start + 8.0
            }
            timeRanges.append((start: start, end: nextStart))
        }
        guard !timeRanges.isEmpty else { return }

        Task.detached(priority: .utility) {
            guard let newPrint = try? extractVoiceprint(from: audioURL, timeRanges: timeRanges) else { return }
            directory.updateVoiceprint(forSpeakerNamed: cleanName, newVoiceprint: newPrint)
        }
    }

    /// Asynchronously extracts and updates a speaker's voiceprint directly from their dedicated microphone or source stem
    public static func fingerprintSpeakerFromStem(
        stemURL: URL,
        speakerName: String,
        directory: SpeakerDirectory = .shared
    ) {
        guard FileManager.default.fileExists(atPath: stemURL.path) else { return }
        let cleanName = speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanName.lowercased().hasPrefix("speaker") else { return }

        Task.detached(priority: .utility) {
            let timeRanges: [(start: TimeInterval, end: TimeInterval)] = [
                (start: 0.0, end: 45.0)
            ]
            guard let newPrint = try? extractVoiceprint(from: stemURL, timeRanges: timeRanges) else { return }
            directory.updateVoiceprint(forSpeakerNamed: cleanName, newVoiceprint: newPrint)
        }
    }
}
