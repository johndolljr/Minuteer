import Foundation
import AVFoundation
import Accelerate

/// Lightweight, 100% on-device acoustic voiceprint engine.
/// Extracts compact mathematical feature vectors (~256 bytes) from speaker audio turns
/// without storing any audio recordings or slices on disk.
public struct AudioFingerprintEngine: Sendable {
    public static let featureDimension = 48
    public static let defaultMatchThreshold: Float = 0.65

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

        // 1. Mean-subtract 32 log band energies to remove microphone and channel bias
        var sumBands: Float = 0
        vDSP_sve(bandAccumulator, 1, &sumBands, vDSP_Length(numBands))
        let meanBand = (sumBands * invCount) / Float(numBands)

        var normBands = [Float](repeating: 0, count: numBands)
        for b in 0..<numBands {
            normBands[b] = (bandAccumulator[b] * invCount) - meanBand
        }

        var featureVector = [Float](repeating: 0, count: featureDimension)

        // Features 0..<18: MFCC coefficients (DCT-II from 1 to 18)
        let pi = Float.pi
        for n in 1...18 {
            var sum: Float = 0
            for k in 0..<numBands {
                sum += normBands[k] * cos((pi * Float(n) * (Float(k) + 0.5)) / Float(numBands))
            }
            featureVector[n - 1] = sum
        }

        // Features 18..<24: Autocorrelation Pitch (F0) & Periodicity
        let minLag = max(20, min(1000, Int(sampleRate / 400.0)))
        let maxLag = max(minLag + 10, min(2000, Int(sampleRate / 70.0)))
        let testCount = min(4000, samples.count - maxLag)

        var bestLag = minLag
        var maxAutoCorr: Float = -1.0
        var zeroLagEnergy: Float = 0

        if testCount > 200 {
            samples.withUnsafeBufferPointer { sPtr in
                guard let base = sPtr.baseAddress else { return }
                vDSP_dotpr(base, 1, base, 1, &zeroLagEnergy, vDSP_Length(testCount))
                if zeroLagEnergy > 1e-4 {
                    for lag in stride(from: minLag, to: maxLag, by: 2) {
                        var ac: Float = 0
                        vDSP_dotpr(base, 1, base.advanced(by: lag), 1, &ac, vDSP_Length(testCount))
                        if ac > maxAutoCorr {
                            maxAutoCorr = ac
                            bestLag = lag
                        }
                    }
                }
            }
        }

        let f0 = (bestLag > 0) ? (sampleRate / Float(bestLag)) : 160.0
        let normPitch = (f0 - 160.0) / 100.0
        let pitchStrength = (zeroLagEnergy > 1e-4) ? max(0, min(1.0, maxAutoCorr / zeroLagEnergy)) : 0.0

        featureVector[18] = normPitch
        featureVector[19] = pitchStrength
        featureVector[20] = centroidSum * invCount
        featureVector[21] = rolloffSum * invCount
        featureVector[22] = energySum * invCount * 0.1
        featureVector[23] = Float(speechFramesCount) / Float(frameCount)

        // Features 24..<36: Formant and Spectral Subband Contrasts
        for i in 0..<12 {
            let lowIdx = i
            let highIdx = (i + 16) % numBands
            featureVector[24 + i] = normBands[lowIdx] - normBands[highIdx]
        }

        // Features 36..<48: Formant Curvature and Odd-Even Resonance Contrasts
        for i in 0..<12 {
            let oddIdx = (i * 2 + 1) % numBands
            let evenIdx = (i * 2) % numBands
            featureVector[36 + i] = normBands[oddIdx] - normBands[evenIdx]
        }

        // Zero-mean center the 48-dim feature vector so the baseline offset across features is 0
        var vMean: Float = 0
        vDSP_meanv(featureVector, 1, &vMean, vDSP_Length(featureDimension))
        var centeredVector = [Float](repeating: 0, count: featureDimension)
        var negVMean = -vMean
        vDSP_vsadd(featureVector, 1, &negVMean, &centeredVector, 1, vDSP_Length(featureDimension))

        return normalize(centeredVector)
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

    /// Automatically identify speakers in a transcript given the recording's audio file.
    /// 1. Turns matching a known speaker in the SpeakerDirectory with high confidence are labeled with that speaker's name.
    /// 2. Unregistered or low-confidence turns are clustered acoustically into unique generic speakers
    ///    ("Speaker 1", "Speaker 2", "Speaker 3", etc.) so distinct voices are cleanly separated within the recording.
    public static func identifySpeakers(
        in audioURL: URL,
        turns: [TranscriptTurn],
        directory: SpeakerDirectory,
        threshold: Float = defaultMatchThreshold,
        forceReidentify: Bool = false
    ) async -> [TranscriptTurn] {
        guard FileManager.default.fileExists(atPath: audioURL.path), !turns.isEmpty else { return turns }

        var updatedTurns = turns
        let highConfidenceThreshold = threshold
        let clusterThreshold: Float = 0.52

        // Anonymous clusters established within this audio recording:
        // (label: "Speaker 1", centroid: [Float], count: Int)
        var clusters: [(label: String, centroid: [Float], count: Int)] = []

        for i in 0..<updatedTurns.count {
            let currentTurn = updatedTurns[i]
            let cleanSpeaker = currentTurn.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            let isGenericSpeaker = cleanSpeaker.isEmpty || cleanSpeaker.lowercased().hasPrefix("speaker")

            let startTime = currentTurn.timestampSeconds ?? (Double(i) * 6.0)
            let nextStart: TimeInterval? = (i + 1 < updatedTurns.count) ? updatedTurns[i + 1].timestampSeconds : nil
            let endTime: TimeInterval
            if let next = nextStart, next > startTime {
                endTime = min(startTime + 25.0, next)
            } else {
                endTime = startTime + 6.0
            }

            let duration = max(0.6, endTime - startTime)
            let timeRanges = [(start: startTime, end: startTime + duration)]

            guard let voiceprint = try? extractVoiceprint(from: audioURL, timeRanges: timeRanges) else {
                // If audio could not be extracted for this turn (e.g., short affirmative turn or pause):
                // Keep consistent with previous turn if generic or forcing re-identification
                if i > 0 && (isGenericSpeaker || forceReidentify) {
                    updatedTurns[i].speaker = updatedTurns[i - 1].speaker
                }
                continue
            }

            // If turn already has an explicit named non-generic speaker, retain it unless forcing re-identification
            if !isGenericSpeaker && !forceReidentify {
                continue
            }

            // Step 1: Check known speakers in directory with high confidence
            if let (matched, _) = identifySpeaker(voiceprint: voiceprint, in: directory, threshold: highConfidenceThreshold) {
                updatedTurns[i].speaker = matched.name
                continue
            }

            // Step 2: Unsupervised acoustic clustering into unique generic speakers (Speaker 1, 2, 3...)
            if clusters.isEmpty {
                let firstLabel = "Speaker 1"
                clusters.append((label: firstLabel, centroid: voiceprint, count: 1))
                updatedTurns[i].speaker = firstLabel
            } else {
                var bestClusterIndex: Int?
                var bestSimilarity: Float = -1.0

                for (cIdx, cluster) in clusters.enumerated() {
                    let sim = similarity(voiceprint, cluster.centroid)
                    if sim > bestSimilarity {
                        bestSimilarity = sim
                        bestClusterIndex = cIdx
                    }
                }

                if let bestIdx = bestClusterIndex, bestSimilarity >= clusterThreshold {
                    let matchedCluster = clusters[bestIdx]
                    updatedTurns[i].speaker = matchedCluster.label

                    let (updatedCentroid, newCount) = updateVoiceprint(
                        existing: matchedCluster.centroid,
                        sampleCount: matchedCluster.count,
                        newPrint: voiceprint
                    )
                    clusters[bestIdx].centroid = updatedCentroid
                    clusters[bestIdx].count = newCount
                } else {
                    let newLabel = "Speaker \(clusters.count + 1)"
                    clusters.append((label: newLabel, centroid: voiceprint, count: 1))
                    updatedTurns[i].speaker = newLabel
                }
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
