# Minuteer Architecture

## Modules & Targets

1. **`MinuteerCore`** (Library)
   - `SDCardMonitor`: Subscribes to `NSWorkspace.didMountNotification` and `didUnmountNotification`; tracks mounted volumes, verifies volume name (`P2_SD`), and provides safe unmount/eject via `NSWorkspace.shared.unmountAndEjectValue(at:)`.
   - `AudioScanner`: Recursively inspects volume paths for audio files, filtering out `.Spotlight-V100`, `.Trashes`, hidden files (`._*`), and non-audio files. Extracts metadata (file size, creation date, duration).
   - `TranscriptionEngine`: Protocol defining speech-to-text contract.
     - `WhisperKitEngine`: CoreML / Apple Neural Engine Whisper runner utilizing on-device models.
     - `AppleSpeechEngine`: On-device `SFSpeechRecognizer` fallback.
   - `SummarizerEngine`: Interfaces with Apple Intelligence via `FoundationModels` (`SystemLanguageModel` / `LanguageModelSession`). Handles prompt templating for meetings and therapy sessions.
   - `MarkdownExporter`: Formats transcripts and summaries into structured markdown notes with frontmatter, and writes safely to the configured export inbox (`~/Documents/Minuteer/Inbox` by default), enforcing overwrite checks.
   - `IngestionCoordinator`: Background actor managing the automated ingestion workflow: detection -> scanning -> transcribing -> summarizing -> exporting -> user notification.

2. **`Minuteer`** (Executable App)
   - `@Observable AppModel`: Central UI state manager.
   - `MainWindow`: Split-view macOS interface with sidebar (SD Card status, discovered & processed files), detail view (Audio playback, transcript, markdown summary), and settings view.
   - `AudioPlayerController`: Background-safe `AVAudioPlayer` controller for listening to selected recordings with play/pause, seek slider, and elapsed/remaining time displays.
   - `SettingsView`: Editor for Apple Intelligence prompt instructions and model preferences.

3. **`MinuteerCoreTests`** (Unit Test Suite)
   - Unit tests covering volume detection, audio scanning, safety checks (no overwrite without permission, no delete without confirmation), prompt generation, and markdown formatting.
   - Enforces coverage thresholds (85% region, 80% line, 90% functions).
