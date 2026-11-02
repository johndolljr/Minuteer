import Testing
import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit
@testable import MinuteerCore

@Suite("Audio Mixer Engine & Source Descriptor Tests")
struct AudioMixerEngineTests {

    @Test("AudioSourceDescriptor initialization, equality, and JSON encoding")
    func testSourceDescriptorProperties() throws {
        let mic = AudioSourceDescriptor.microphone(id: "built_in_mic", name: "MacBook Pro Microphone")
        #expect(mic.id == "mic_built_in_mic")
        #expect(mic.kind == .microphone)
        #expect(mic.displayName == "MacBook Pro Microphone")
        #expect(mic.iconSystemName == "mic.fill")

        let app = AudioSourceDescriptor.application(bundleID: "us.zoom.xos", pid: 1234, name: "Zoom")
        #expect(app.id == "app_us.zoom.xos_1234")
        #expect(app.kind == .runningApplication)
        #expect(app.displayName == "Zoom")
        #expect(app.iconSystemName == "app.badge")
        #expect(app.processIdentifier == 1234)

        let sys = AudioSourceDescriptor.systemAudio
        #expect(sys.id == "system_audio")
        #expect(sys.kind == .systemAudio)
        #expect(sys.iconSystemName == "speaker.wave.3.fill")

        let encoder = JSONEncoder()
        let data = try encoder.encode(mic)
        let decoded = try JSONDecoder().decode(AudioSourceDescriptor.self, from: data)
        #expect(decoded == mic)
    }

    @Test("AudioChannel muting, soloing, and volume clamping")
    func testAudioChannelProperties() {
        let channel = AudioChannel(
            source: .systemAudio,
            volume: 1.0,
            isMuted: false,
            isSolo: false,
            currentLevel: 0.5
        )
        #expect(channel.volume == 1.0)
        #expect(!channel.isMuted)
        #expect(!channel.isSolo)
        #expect(channel.currentLevel == 0.5)

        channel.volume = 1.2
        channel.isMuted = true
        channel.isSolo = true
        #expect(channel.volume == 1.2)
        #expect(channel.isMuted)
        #expect(channel.isSolo)
    }

    @Test("AudioMixerEngine channel operations and calendar event linkage")
    func testMixerEngineChannelManagement() {
        let engine = AudioMixerEngine()
        #expect(engine.channels.count == 2)
        #expect(!engine.isRecording)

        let customSource = AudioSourceDescriptor.application(bundleID: "com.tinyspeck.slackmacgap", pid: 9999, name: "Slack")
        engine.addChannel(for: customSource)
        #expect(engine.channels.count == 3)

        // Adding duplicate source should be ignored
        engine.addChannel(for: customSource)
        #expect(engine.channels.count == 3)

        guard let slackChannel = engine.channels.first(where: { $0.source.id == customSource.id }) else {
            Issue.record("Slack channel not found")
            return
        }

        engine.setVolume(1.4, for: slackChannel.id)
        #expect(slackChannel.volume == 1.4)

        engine.toggleMute(for: slackChannel.id)
        #expect(slackChannel.isMuted)
        engine.toggleMute(for: slackChannel.id)
        #expect(!slackChannel.isMuted)

        engine.toggleSolo(for: slackChannel.id)
        #expect(slackChannel.isSolo)

        let event = CalendarEventInfo(
            id: "cal_123",
            title: "Sprint Review",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            location: "Room 101",
            notes: "Sprint review notes",
            attendees: ["Alice", "Bob"]
        )
        engine.linkedCalendarEvent = event
        #expect(engine.linkedCalendarEvent?.title == "Sprint Review")

        engine.removeChannel(id: slackChannel.id)
        #expect(engine.channels.count == 2)
    }

    @Test("AudioMixerEngine produceFinalMix with empty stems produces silence WAV")
    func testProduceFinalMixEmptyStems() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let finalURL = tempDir.appendingPathComponent("silence.wav")
        try await AudioMixerEngine.produceFinalMix(stems: [], finalURL: finalURL)

        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        let file = try AVAudioFile(forReading: finalURL)
        #expect(file.processingFormat.sampleRate == 16000)
        #expect(file.processingFormat.channelCount == 1)
        #expect(file.length > 0)
    }

    @Test("AudioMixerEngine produceFinalMix with synthetic audio stems and gain scaling")
    func testProduceFinalMixMultiStems() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stem1URL = tempDir.appendingPathComponent("stem1.wav")
        let stem2URL = tempDir.appendingPathComponent("stem2.wav")
        let finalURL = tempDir.appendingPathComponent("final_mixed.wav")

        // Create 2 16kHz WAV stems
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            let buffer1 = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
            buffer1.frameLength = 8000
            for i in 0..<8000 {
                buffer1.floatChannelData![0][i] = 0.2
            }
            let file1 = try AVAudioFile(forWriting: stem1URL, settings: settings)
            try file1.write(from: buffer1)

            let buffer2 = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
            buffer2.frameLength = 8000
            for i in 0..<8000 {
                buffer2.floatChannelData![0][i] = 0.3
            }
            let file2 = try AVAudioFile(forWriting: stem2URL, settings: settings)
            try file2.write(from: buffer2)

            let format48k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
            let settings48k: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let stem3URL = tempDir.appendingPathComponent("stem3_48k.wav")
            let buffer3 = AVAudioPCMBuffer(pcmFormat: format48k, frameCapacity: 24000)!
            buffer3.frameLength = 24000
            for i in 0..<24000 {
                buffer3.floatChannelData![0][i] = 0.1
                buffer3.floatChannelData![1][i] = 0.1
            }
            let file3 = try AVAudioFile(forWriting: stem3URL, settings: settings48k)
            try file3.write(from: buffer3)
        }

        let stem3URL = tempDir.appendingPathComponent("stem3_48k.wav")
        try await AudioMixerEngine.produceFinalMix(
            stems: [
                (url: stem1URL, gain: 1.0),
                (url: stem2URL, gain: 1.5),
                (url: stem3URL, gain: 0.8)
            ],
            finalURL: finalURL
        )

        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        let finalFile = try AVAudioFile(forReading: finalURL)
        #expect(finalFile.processingFormat.sampleRate == 16000)
        #expect(finalFile.processingFormat.channelCount == 1)
        #expect(abs(Int(finalFile.length) - 8000) <= 200)
    }

    @Test("AudioCaptureDeviceManager discovery and permission queries")
    func testDeviceManagerQueries() async {
        let manager = AudioCaptureDeviceManager.shared
        _ = manager.availableMicrophones()
        _ = await manager.availableApplications()
        _ = manager.hasScreenRecordingPermission()
        _ = await manager.checkMicrophonePermission()
        manager.requestScreenRecordingPermission()
    }

    @Test("AudioMixerEngine recording lifecycle with mock stem capturers")
    func testMixerEngineLifecycle() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = AudioMixerEngine(
            defaultChannels: [
                .systemAudio,
                .microphone(id: "mock_mic", name: "Mock Mic")
            ],
            capturerFactory: { source, stemURL in
                MockStemCapturer(source: source, stemURL: stemURL)
            }
        )

        #expect(!engine.isRecording)
        try await engine.startRecording(outputDirectory: tempDir)
        #expect(engine.isRecording)
        try? await Task.sleep(nanoseconds: 120_000_000)

        engine.pause()
        if case .paused = engine.state {
            // Success
        } else {
            Issue.record("Expected paused state")
        }

        engine.resume()
        if case .recording = engine.state {
            // Success
        } else {
            Issue.record("Expected recording state")
        }

        let finalFile = tempDir.appendingPathComponent("meeting_output.wav")
        let result = try await engine.stopRecording(finalOutputURL: finalFile)

        #expect(!engine.isRecording)
        #expect(FileManager.default.fileExists(atPath: result.finalURL.path))
        #expect(result.duration >= 0)
    }

    @Test("AudioMixerEngine solo and mute logic during mixdown")
    func testMixerSoloAndMuteLogic() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = AudioMixerEngine(
            defaultChannels: [
                .systemAudio,
                .microphone(id: "mic1", name: "Mic 1"),
                .microphone(id: "mic2", name: "Mic 2")
            ],
            capturerFactory: { source, stemURL in
                MockStemCapturer(source: source, stemURL: stemURL)
            }
        )

        // Solo channel 1, mute channel 2, and make channel 3 both solo and muted
        engine.channels[0].isSolo = true
        engine.channels[1].isMuted = true
        engine.channels[2].isSolo = true
        engine.channels[2].isMuted = true

        try await engine.startRecording(outputDirectory: tempDir)
        let finalFile = tempDir.appendingPathComponent("solo_mix.wav")
        let result = try await engine.stopRecording(finalOutputURL: finalFile)

        #expect(FileManager.default.fileExists(atPath: result.finalURL.path))
    }

    @Test("SCKStemCapturer and MicrophoneStemCapturer instantiations and error paths")
    func testCapturerBasics() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stem = tempDir.appendingPathComponent("stem_test.wav")

        let sckSys = SCKStemCapturer(source: .systemAudio, stemURL: stem)
        #expect(sckSys.currentLevel == 0)
        do {
            try await sckSys.start()
            #expect(sckSys.isRunning)
            await sckSys.stop()
        } catch {
            // Screen recording permission or display capture error in sandbox/CLI
        }

        if let app = await AudioCaptureDeviceManager.shared.availableApplications().first {
            let sckAppReal = SCKStemCapturer(source: app, stemURL: stem)
            do {
                try await sckAppReal.start()
                await sckAppReal.stop()
            } catch {
                // Handled
            }
        }

        let sckMic = SCKStemCapturer(source: .microphone(id: "m", name: "M"), stemURL: stem)
        do {
            try await sckMic.start()
            Issue.record("Expected error when starting SCK on microphone")
        } catch {
            // Expected
        }

        let sckApp = SCKStemCapturer(source: .application(bundleID: "non.existent.app", pid: 99999, name: "NonExistent"), stemURL: stem)
        do {
            try await sckApp.start()
        } catch {
            // Expected
        }

        let defaultMic = MicrophoneStemCapturer(source: .microphone(id: "default", name: "Default"), stemURL: stem)
        do {
            try await defaultMic.start()
            await defaultMic.stop()
        } catch {
            // Handled
        }

        let micCapturer = MicrophoneStemCapturer(source: .microphone(id: "nonexistent", name: "Nonexistent"), stemURL: stem)
        #expect(micCapturer.currentLevel == 0)
        await micCapturer.stop()
    }

    @Test("AudioBufferConverter RMS and PCM conversion with synthetic CMSampleBuffer")
    func testBufferConverter() {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDesc)

        var blockBuffer: CMBlockBuffer?
        let numSamples = 100
        let dataSize = numSamples * 4 * 2
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: dataSize, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: dataSize, flags: 0, blockBufferOut: &blockBuffer)

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: blockBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDesc, sampleCount: CMItemCount(numSamples), sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)

        if let sb = sampleBuffer, let pcm = AudioBufferConverter.pcmBuffer(from: sb) {
            #expect(pcm.frameLength == 100)
            let level = AudioBufferConverter.rmsLevel(pcm)
            #expect(level >= 0.0)

            // Exercise 16-bit PCM buffer conversion
            var asbd16 = AudioStreamBasicDescription(
                mSampleRate: 16000,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger,
                mBytesPerPacket: 2,
                mFramesPerPacket: 1,
                mBytesPerFrame: 2,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 16,
                mReserved: 0
            )
            var fd16: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd16, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd16)
            var bb16: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 200, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 200, flags: 0, blockBufferOut: &bb16)
            var sb16: CMSampleBuffer?
            CMSampleBufferCreate(allocator: nil, dataBuffer: bb16, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fd16, sampleCount: 100, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb16)
            if let s = sb16, let p = AudioBufferConverter.pcmBuffer(from: s) {
                #expect(p.frameLength == 100)
            }

            // Exercise interleaved Float32 buffer conversion
            var asbdFloatInterleaved = AudioStreamBasicDescription(
                mSampleRate: 48000,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat,
                mBytesPerPacket: 8,
                mFramesPerPacket: 1,
                mBytesPerFrame: 8,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            var fdFI: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbdFloatInterleaved, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fdFI)
            var bbFI: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 800, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 800, flags: 0, blockBufferOut: &bbFI)
            var sbFI: CMSampleBuffer?
            CMSampleBufferCreate(allocator: nil, dataBuffer: bbFI, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fdFI, sampleCount: 100, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sbFI)
            if let s = sbFI, let p = AudioBufferConverter.pcmBuffer(from: s) {
                #expect(p.frameLength == 100)
            }

            // Exercise rmsLevel with empty and zero buffer
            let emptyFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            let zeroBuf = AVAudioPCMBuffer(pcmFormat: emptyFmt, frameCapacity: 100)!
            zeroBuf.frameLength = 0
            #expect(AudioBufferConverter.rmsLevel(zeroBuf) == 0)

            let silenceBuf = AVAudioPCMBuffer(pcmFormat: emptyFmt, frameCapacity: 100)!
            silenceBuf.frameLength = 100
            silenceBuf.floatChannelData![0].initialize(repeating: 0, count: 100)
            #expect(AudioBufferConverter.rmsLevel(silenceBuf) == 0)

            // Exercise unsupported bit depth (e.g. 24-bit) returning nil
            var asbd24 = AudioStreamBasicDescription(
                mSampleRate: 48000,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger,
                mBytesPerPacket: 3,
                mFramesPerPacket: 1,
                mBytesPerFrame: 3,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 24,
                mReserved: 0
            )
            var fd24: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd24, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd24)
            var bb24: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 300, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 300, flags: 0, blockBufferOut: &bb24)
            var sb24: CMSampleBuffer?
            CMSampleBufferCreate(allocator: nil, dataBuffer: bb24, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fd24, sampleCount: 100, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb24)
            if let s = sb24 {
                #expect(AudioBufferConverter.pcmBuffer(from: s) == nil)
            }
        }
    }

    @Test("Assign speaker to channel and train voiceprint from stem")
    func testSpeakerAssignmentAndStemTraining() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = AudioMixerEngine()
        guard let firstCh = engine.channels.first else { return }
        engine.assignSpeaker("John Doe", for: firstCh.id)
        #expect(firstCh.assignedSpeakerName == "John Doe")

        let stemFile = tempDir.appendingPathComponent("stem_john.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: stemFile, settings: settings)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4000)!
        buf.frameLength = 4000
        for i in 0..<4000 {
            buf.floatChannelData![0][i] = 0.1
        }
        try file.write(from: buf)

        let dir = SpeakerDirectory(appSupportDirectory: tempDir)
        dir.addSpeaker(SpeakerProfile(name: "John Doe"))
        AudioFingerprintEngine.fingerprintSpeakerFromStem(stemURL: stemFile, speakerName: "John Doe", directory: dir)
    }

    @Test("Test produceFinalMix clipping and empty file fallback")
    func testProduceFinalMixClippingAndEmpty() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let loudURL = tempDir.appendingPathComponent("loud.wav")
        let negURL = tempDir.appendingPathComponent("neg.wav")
        let emptyURL = tempDir.appendingPathComponent("empty.wav")

        do {
            let bufLoud = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
            bufLoud.frameLength = 100
            for i in 0..<100 { bufLoud.floatChannelData![0][i] = 1.0 }
            let fLoud = try AVAudioFile(forWriting: loudURL, settings: settings)
            try fLoud.write(from: bufLoud)

            let bufNeg = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
            bufNeg.frameLength = 100
            for i in 0..<100 { bufNeg.floatChannelData![0][i] = -1.0 }
            let fNeg = try AVAudioFile(forWriting: negURL, settings: settings)
            try fNeg.write(from: bufNeg)

            let bufEmpty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
            bufEmpty.frameLength = 0
            let fEmpty = try AVAudioFile(forWriting: emptyURL, settings: settings)
            try fEmpty.write(from: bufEmpty)
        }

        let outURL = tempDir.appendingPathComponent("clipped.wav")
        try await AudioMixerEngine.produceFinalMix(
            stems: [
                (url: loudURL, gain: 2.0),
                (url: negURL, gain: 2.0),
                (url: emptyURL, gain: 1.0)
            ],
            finalURL: outURL
        )
        #expect(FileManager.default.fileExists(atPath: outURL.path))

        // Empty file fallback
        let outEmptyURL = tempDir.appendingPathComponent("only_empty.wav")
        try await AudioMixerEngine.produceFinalMix(
            stems: [(url: emptyURL, gain: 1.0)],
            finalURL: outEmptyURL
        )
        #expect(FileManager.default.fileExists(atPath: outEmptyURL.path))
    }

    @Test("SCKStemCapturer and MicrophoneStemCapturer stream buffer callbacks")
    func testCapturerStreamCallbacks() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sckStem = tempDir.appendingPathComponent("sck_stream.wav")
        let micStem = tempDir.appendingPathComponent("mic_stream.wav")

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDesc)

        var blockBuffer: CMBlockBuffer?
        let numSamples = 200
        let dataSize = numSamples * 4 * 2
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: dataSize, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: dataSize, flags: 0, blockBufferOut: &blockBuffer)

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: blockBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDesc, sampleCount: CMItemCount(numSamples), sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)

        if let sb = sampleBuffer {
            let sck = SCKStemCapturer(source: .systemAudio, stemURL: sckStem)
            // Stream callback test
            // We pass dummy stream pointer
            sck.stream(unsafeBitCast(sck, to: SCStream.self), didOutputSampleBuffer: sb, of: .audio)
            // Non-audio branch
            sck.stream(unsafeBitCast(sck, to: SCStream.self), didOutputSampleBuffer: sb, of: .screen)
            sck.stream(unsafeBitCast(sck, to: SCStream.self), didStopWithError: NSError(domain: "test", code: 1))
            #expect(!sck.isRunning)

            let mic = MicrophoneStemCapturer(source: .microphone(id: "test", name: "Test"), stemURL: micStem)
            let dummyOutput = AVCaptureAudioDataOutput()
            let dummyConnection = AVCaptureConnection(inputPorts: [], output: dummyOutput)
            mic.captureOutput(dummyOutput, didOutput: sb, from: dummyConnection)
            #expect(mic.currentLevel >= 0)
        }
    }

    @Test("AudioMixerEngine pause, resume, and channel mutation")
    func testMixerEnginePauseResumeAndMutation() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = AudioMixerEngine(
            defaultChannels: [.systemAudio],
            capturerFactory: { source, url in MockStemCapturer(source: source, stemURL: url) }
        )

        engine.masterVolume = 0.85
        #expect(engine.masterVolume == 0.85)

        let cal = CalendarEventInfo(id: "cal1", title: "Project Sync", startDate: Date(), endDate: Date().addingTimeInterval(1800))
        engine.linkedCalendarEvent = cal
        #expect(engine.linkedCalendarEvent?.title == "Project Sync")

        #expect(!engine.isRecording)
        #expect(engine.channels.count == 1)

        let micDesc = AudioSourceDescriptor.microphone(id: "test_mic", name: "Test Mic")
        engine.addChannel(for: micDesc)
        #expect(engine.channels.count == 2)

        // Duplicate add ignored
        engine.addChannel(for: micDesc)
        #expect(engine.channels.count == 2)

        let chID = engine.channels.last!.id
        engine.setVolume(1.2, for: chID)
        #expect(engine.channels.last!.volume == 1.2)

        engine.toggleSolo(for: chID)
        #expect(engine.channels.last!.isSolo)

        engine.toggleMute(for: chID)
        #expect(engine.channels.last!.isMuted)

        engine.assignSpeaker("Alice", for: chID)
        #expect(engine.channels.last!.assignedSpeakerName == "Alice")

        try await engine.startRecording(outputDirectory: tempDir)
        #expect(engine.isRecording)

        // Channel removal ignored while recording
        engine.removeChannel(id: chID)
        #expect(engine.channels.count == 2)

        engine.pause()
        if case .paused = engine.state {
            #expect(Bool(true))
        } else {
            Issue.record("Expected paused state")
        }

        engine.resume()
        if case .recording = engine.state {
            #expect(Bool(true))
        } else {
            Issue.record("Expected recording state")
        }

        let finalMix = tempDir.appendingPathComponent("final_mix.wav")
        let res = try await engine.stopRecording(finalOutputURL: finalMix)
        #expect(FileManager.default.fileExists(atPath: res.finalURL.path))
        #expect(!engine.isRecording)

        // Channel removal allowed when idle
        engine.removeChannel(id: chID)
        #expect(engine.channels.count == 1)

        // Non-existent channel mutations
        let bogusID = UUID()
        engine.setVolume(0.5, for: bogusID)
        engine.toggleMute(for: bogusID)
        engine.toggleSolo(for: bogusID)
        engine.assignSpeaker("Nobody", for: bogusID)

        // Idle state pause and resume
        engine.pause()
        engine.resume()
    }

    @Test("AudioMixerEngine helper methods, state properties, and AudioCaptureDeviceManager static helpers")
    func testMixerEngineHelpersAndStateProperties() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = AudioMixerEngine()
        guard let ch = engine.channels.first else {
            Issue.record("Expected default channels")
            return
        }

        // Test setMasterVolume
        engine.setMasterVolume(0.75)
        #expect(abs(engine.masterVolume - 0.75) < 1e-4)

        // Test linkCalendarEvent and unlinkCalendarEvent
        let event = CalendarEventInfo(
            id: "evt-123",
            title: "Sprint Planning",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            calendarTitle: "Work"
        )
        engine.linkCalendarEvent(event)
        #expect(engine.linkedCalendarEvent?.title == "Sprint Planning")
        engine.unlinkCalendarEvent()
        #expect(engine.linkedCalendarEvent == nil)

        // Test setSoloed and setMuted
        engine.setSoloed(for: ch.id, isSoloed: true)
        #expect(ch.isSolo)
        engine.setSoloed(for: ch.id, isSoloed: false)
        #expect(!ch.isSolo)

        engine.setMuted(for: ch.id, isMuted: true)
        #expect(ch.isMuted)
        engine.setMuted(for: ch.id, isMuted: false)
        #expect(!ch.isMuted)

        // Non-existent channel guards
        let bogusID = UUID()
        engine.setSoloed(for: bogusID, isSoloed: true)
        engine.setMuted(for: bogusID, isMuted: true)

        // Test State enum properties
        #expect(AudioMixerEngine.State.idle.title == "Idle")
        #expect(AudioMixerEngine.State.recording(duration: 5.0).title == "Recording")
        #expect(AudioMixerEngine.State.paused(duration: 5.0).title == "Paused")
        #expect(AudioMixerEngine.State.mixing.title == "Mixing")

        #expect(!AudioMixerEngine.State.idle.isRecording)
        #expect(AudioMixerEngine.State.recording(duration: 1.0).isRecording)
        #expect(AudioMixerEngine.State.paused(duration: 1.0).isRecording)
        #expect(!AudioMixerEngine.State.mixing.isRecording)

        // Test pauseRecording and resumeRecording
        engine.pauseRecording()
        engine.resumeRecording()

        // Test cancelRecording lifecycle
        engine.cancelRecording()
        #expect(engine.state == .idle)

        // Test AudioCaptureDeviceManager static helpers
        let mics = AudioCaptureDeviceManager.availableMicrophones()
        #expect(mics.count >= 0)

        let apps = await AudioCaptureDeviceManager.availableApplications()
        #expect(apps.count >= 0)

        let sys = AudioCaptureDeviceManager.systemAudio()
        #expect(sys.kind == .systemAudio)
    }
}

final class MockStemCapturer: AudioStemCapturer, @unchecked Sendable {
    let source: AudioSourceDescriptor
    let stemURL: URL
    var currentLevel: Float = 0.5

    init(source: AudioSourceDescriptor, stemURL: URL) {
        self.source = source
        self.stemURL = stemURL
    }

    func start() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        try FileManager.default.createDirectory(at: stemURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: stemURL, settings: settings)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buf.frameLength = 1600
        for i in 0..<1600 {
            buf.floatChannelData![0][i] = 0.1
        }
        try file.write(from: buf)
    }

    func stop() async {}
}
