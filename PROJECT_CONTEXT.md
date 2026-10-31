# Minuteer Project Context

## Purpose & Overview
Minuteer is a native macOS application designed to automate the ingestion, transcription, summarization, and archiving of audio recordings (specifically meetings and therapy sessions) from a Zoom recorder SD card (named `P2_SD` or configurable).

## Core User Workflows
1. **Automated SD Card Detection**:
   - Detects when `P2_SD` is inserted or already mounted on launch.
   - Scans the card for audio files (`.WAV`, `.wav`, `.mp3`, `.m4a`), automatically excluding system metadata directories (`.Spotlight-V100`, `.Trashes`, `._*`).
2. **Local Speech-to-Text Transcription**:
   - Uses WhisperKit (Apple Silicon Neural Engine / CoreML accelerated local Whisper models) for high-accuracy multi-speaker transcription.
   - Provides on-device Apple Speech (`SFSpeechRecognizer`) as a zero-download instant fallback.
   - Entirely self-contained; no external third-party apps required.
3. **Apple Intelligence Summarization**:
   - Uses native `FoundationModels` (`SystemLanguageModel` / `LanguageModelSession`) available on macOS 15+ / Apple Silicon.
   - Offers customizable prompt instructions tailored to:
     - **Meeting**: Executive summary, attendees/roles, key discussion points, decisions made, action items & owners.
     - **Therapy Session**: Core themes, emotional state & breakthroughs, insights, recurring patterns, personal goals & reflection questions.
     - **Custom**: User-editable prompt templates.
4. **Markdown Export & Safety Guarantees**:
   - Saves formatted markdown documents directly into the configured export inbox (`~/Documents/Minuteer/Inbox/` by default).
   - **Data Safety Principles**:
     - Never delete audio files without explicit user action/confirmation.
     - Never overwrite existing markdown files in `Inbox` without explicit user permission (prompts user or uses timestamped deduplication).
5. **Native macOS Experience**:
   - 100% responsive UI: all audio decoding, Whisper transcription, and LLM summarization run asynchronously on background worker actors/tasks; never blocks the main thread.
   - Audio inspector with full waveform / scrubber playback controls (`AVAudioPlayer`).
   - Side-by-side or tabbed inspection of audio file info, raw transcript, and formatted markdown summary.
   - One-click safe SD card ejection via `NSWorkspace`.
   - macOS user notifications when automated processing completes.
