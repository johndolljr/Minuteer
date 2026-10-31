import Foundation

public func makeValidWAVData(sampleRate: Int = 16000, durationSeconds: Double = 1.0) -> Data {
    var data = Data()
    let numSamples = Int(Double(sampleRate) * durationSeconds)
    let subchunk2Size = numSamples * 2 // 16-bit mono = 2 bytes per sample
    let chunkSize = 36 + subchunk2Size

    // RIFF header
    data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
    data.append(contentsOf: withUnsafeBytes(of: UInt32(chunkSize).littleEndian) { Array($0) })
    data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

    // fmt subchunk
    data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
    data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // Subchunk1Size
    data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // AudioFormat (PCM)
    data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // NumChannels (1)
    data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) }) // SampleRate
    data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Array($0) }) // ByteRate
    data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })  // BlockAlign
    data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // BitsPerSample

    // data subchunk
    data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
    data.append(contentsOf: withUnsafeBytes(of: UInt32(subchunk2Size).littleEndian) { Array($0) })
    data.append(Data(repeating: 0, count: subchunk2Size))

    return data
}

public func makeToneWAVData(sampleRate: Int = 16000, durationSeconds: Double = 1.0, frequency: Float = 440.0) -> Data {
    var data = Data()
    let numSamples = Int(Double(sampleRate) * durationSeconds)
    let subchunk2Size = numSamples * 2
    let chunkSize = 36 + subchunk2Size

    data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
    data.append(contentsOf: withUnsafeBytes(of: UInt32(chunkSize).littleEndian) { Array($0) })
    data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
    data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
    data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // Mono
    data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
    data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
    data.append(contentsOf: withUnsafeBytes(of: UInt32(subchunk2Size).littleEndian) { Array($0) })

    for i in 0..<numSamples {
        let sample = sin(2.0 * Float.pi * frequency * Float(i) / Float(sampleRate))
        let intSample = Int16(max(-32767, min(32767, sample * 16000.0)))
        data.append(contentsOf: withUnsafeBytes(of: intSample.littleEndian) { Array($0) })
    }

    return data
}

public func makeStereoToneWAVData(sampleRate: Int = 16000, durationSeconds: Double = 1.0) -> Data {
    var data = Data()
    let numSamples = Int(Double(sampleRate) * durationSeconds)
    let subchunk2Size = numSamples * 4 // 2 channels * 2 bytes
    let chunkSize = 36 + subchunk2Size

    data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
    data.append(contentsOf: withUnsafeBytes(of: UInt32(chunkSize).littleEndian) { Array($0) })
    data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
    data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
    data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) }) // Stereo
    data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 4).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(4).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
    data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
    data.append(contentsOf: withUnsafeBytes(of: UInt32(subchunk2Size).littleEndian) { Array($0) })

    for i in 0..<numSamples {
        let sample = sin(2.0 * Float.pi * 440.0 * Float(i) / Float(sampleRate))
        let intSample = Int16(max(-32767, min(32767, sample * 16000.0)))
        data.append(contentsOf: withUnsafeBytes(of: intSample.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: intSample.littleEndian) { Array($0) })
    }

    return data
}
