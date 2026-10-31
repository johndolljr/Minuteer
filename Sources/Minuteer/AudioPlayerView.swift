import SwiftUI
import MinuteerCore

struct AudioPlayerView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            // Studio Acoustic Waveform Visualizer & Diarization Scrubber
            WaveformDeckView(model: model)

            // Transport & Playback Utilities Bar
            HStack(alignment: .center) {
                // Current Time
                Text(formatTime(model.audioCurrentTime))
                    .font(.caption.monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)

                Spacer()

                // Center Transport Controls
                HStack(spacing: 20) {
                    Button {
                        model.player.skip(by: -15)
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Skip backward 15 seconds (J)")

                    Button {
                        model.player.togglePlayPause()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 36, height: 36)
                                .shadow(color: Color.accentColor.opacity(0.3), radius: 4, x: 0, y: 2)

                            Image(systemName: model.isAudioPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: model.isAudioPlaying ? 0 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .help(model.isAudioPlaying ? "Pause (Space)" : "Play (Space)")

                    Button {
                        model.player.skip(by: 15)
                    } label: {
                        Image(systemName: "goforward.15")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Skip forward 15 seconds (L)")
                }

                Spacer()

                // Speed Pill & Total Duration
                HStack(spacing: 8) {
                    Button {
                        model.cyclePlaybackRate()
                    } label: {
                        Text(formatPlaybackRate(model.playbackRate))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .foregroundStyle(.primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Cycle playback speed (1.0×, 1.25×, 1.5×, 2.0×)")

                    Text(formatTime(model.audioDuration > 0 ? model.audioDuration : model.player.duration))
                        .font(.caption.monospacedDigit())
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func formatPlaybackRate(_ rate: Float) -> String {
        if rate == Float(Int(rate)) {
            return String(format: "%.1f×", rate)
        } else {
            return String(format: "%.2g×", rate)
        }
    }
}

/// Studio acoustic waveform with live playhead and speaker diarization timeline track
struct WaveformDeckView: View {
    @Bindable var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let progress = model.audioDuration > 0
                ? max(0, min(1.0, model.audioCurrentTime / model.audioDuration))
                : 0.0

            ZStack(alignment: .leading) {
                // Background waveform card
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.textBackgroundColor).opacity(0.4))

                // Waveform Bars
                waveformBars(width: width, height: height - 6, progress: progress)
                    .padding(.bottom, 6)

                // Speaker Diarization Segments Lane along bottom
                diarizationLane(width: width)
                    .frame(height: 4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 2))

                // Playhead Scrubber Line
                if model.audioDuration > 0 {
                    let playheadX = max(0, min(width - 2, width * progress))
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 2)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 0)
                        .overlay(
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                                .frame(maxHeight: .infinity, alignment: .top)
                        )
                        .offset(x: playheadX)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard model.audioDuration > 0, width > 0 else { return }
                        let pct = max(0, min(1.0, value.location.x / width))
                        model.player.seek(to: pct * model.audioDuration)
                    }
            )
        }
        .frame(height: 48)
    }

    @ViewBuilder
    private func waveformBars(width: CGFloat, height: CGFloat, progress: Double) -> some View {
        let barWidth: CGFloat = 2.5
        let barSpacing: CGFloat = 2.0
        let totalStep = barWidth + barSpacing
        let barCount = max(20, Int(width / totalStep))
        let activeFile = model.selectedRecording

        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                let barFraction = Double(index) / Double(barCount)
                let isPlayed = barFraction <= progress
                let barHeight = computeBarHeight(index: index, count: barCount, maxHeight: height, file: activeFile)

                RoundedRectangle(cornerRadius: 1)
                    .fill(isPlayed ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: barWidth, height: barHeight)
                    .animation(.linear(duration: 0.1), value: isPlayed)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 4)
    }

    private func computeBarHeight(index: Int, count: Int, maxHeight: CGFloat, file: AudioRecordingFile?) -> CGFloat {
        // Deterministic audio acoustic profile using harmonic waves and file duration seed
        let seed = Double(file?.displayName.utf8.reduce(0, { $0 + Int($1) }) ?? 42)
        let phase = Double(index) * 0.16 + (seed * 0.01)
        let wave1 = sin(phase) * 0.4
        let wave2 = sin(phase * 2.3 + 1.2) * 0.3
        let wave3 = cos(phase * 0.7) * 0.2
        let normalized = max(0.15, min(0.95, abs(wave1 + wave2 + wave3) + 0.15))
        return max(4, maxHeight * CGFloat(normalized))
    }

    @ViewBuilder
    private func diarizationLane(width: CGFloat) -> some View {
        if let file = model.selectedRecording,
           model.audioDuration > 0 {
            let turns = model.turns(for: file)
            if !turns.isEmpty {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))

                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        let startSec = turn.timestampSeconds ?? 0
                        let nextSec = (index + 1 < turns.count)
                            ? (turns[index + 1].timestampSeconds ?? model.audioDuration)
                            : model.audioDuration
                        let segDuration = max(1.0, nextSec - startSec)
                        let startFrac = max(0, min(1.0, startSec / model.audioDuration))
                        let segWidth = max(2, (segDuration / model.audioDuration) * width)
                        let speakerColor = speakerColorFor(turn.speaker)

                        Rectangle()
                            .fill(speakerColor.opacity(0.85))
                            .frame(width: segWidth)
                            .offset(x: startFrac * width)
                    }
                }
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))
            }
        } else {
            Rectangle().fill(Color.secondary.opacity(0.12))
        }
    }

    private func speakerColorFor(_ speaker: String) -> Color {
        let normalized = speaker.trimmingCharacters(in: .whitespaces).lowercased()
        if normalized.contains("1") || normalized.contains("a") {
            return Color.accentColor
        } else if normalized.contains("2") || normalized.contains("b") {
            return Color.purple
        } else if normalized.contains("3") || normalized.contains("c") {
            return Color.orange
        } else if normalized.contains("4") || normalized.contains("d") {
            return Color.teal
        } else {
            return Color.accentColor.opacity(0.7)
        }
    }
}
