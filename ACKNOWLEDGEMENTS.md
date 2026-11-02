# Acknowledgements & Open-Source Credits

Minuteer incorporates and adapts architectural patterns and code from the following excellent open-source projects:

### 1. [meeting-recorder](https://github.com/tonton-golio/meeting-recorder)
- **Author**: Pierre-Olivier Latour / SimplyAI
- **License**: MIT License
- **Contributions Adapted**:
  - `ScreenCaptureKit` system audio stream capture patterns and PCM buffer extraction (`CMSampleBuffer` conversion).
  - Voice-processed microphone capture (`AVAudioEngine` + Voice Processing I/O / Acoustic Echo Cancellation).
  - Stem-based multi-track recording and offline resampled audio mixer (`produceFinalMix`).

### 2. [Azayaka](https://github.com/Mnpn/Azayaka)
- **Author**: Martin Persson (`Mnpn`)
- **License**: MIT License
- **Contributions Adapted**:
  - `ScreenCaptureKit` application-level window and running process audio filtering (`SCRunningApplication` / `SCContentFilter`).
  - Audio container and lossless WAV/PCM configuration patterns.

### 3. [WhisperKit](https://github.com/argmaxinc/WhisperKit)
- **Author**: Argmax, Inc.
- **License**: MIT License
- **Contributions Adapted**:
  - On-device CoreML speech recognition and transcription runtime.
