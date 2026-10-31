import SwiftUI
import MinuteerCore

struct SplitTurnSheet: View {
    @Bindable var model: AppModel
    let file: AudioRecordingFile
    let turn: TranscriptTurn
    let detectedSpeakers: [String]
    @Environment(\.dismiss) private var dismiss

    @State private var part1: String = ""
    @State private var part2: String = ""
    @State private var selectedSpeaker: String = ""
    @State private var isCreatingNewSpeaker: Bool = false
    @State private var newSpeakerName: String = ""
    @State private var estimatedTimestamp: String = ""

    private var sentencePoints: [(sentence: String, endOffset: Int)] {
        TranscriptTurn.sentenceSplitPoints(in: turn.text)
    }

    private var availableSpeakers: [String] {
        var set: [String] = []
        for s in detectedSpeakers where !set.contains(s) {
            set.append(s)
        }
        for s in model.speakers.map(\.name) where !set.contains(s) {
            set.append(s)
        }
        if set.isEmpty {
            set = ["Speaker 1", "Speaker 2"]
        }
        return set
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "scissors")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                        Text("Split Dialogue Turn")
                            .font(.title2)
                            .fontWeight(.bold)
                    }
                    Text("Split this dialogue turn into two separate turns and assign the second speaker.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Original Turn Reference
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("Original Turn #\(turn.id + 1)")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 4) {
                                Image(systemName: "person.circle.fill")
                                Text(turn.speaker)
                            }
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())

                            if let ts = turn.timestamp, !ts.isEmpty {
                                HStack(spacing: 3) {
                                    Image(systemName: "play.circle.fill")
                                    Text(ts)
                                }
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .foregroundStyle(.secondary)
                                .clipShape(Capsule())
                            }
                        }
                    }

                    // Sentence Suggestions (if multiple sentences)
                    if sentencePoints.count > 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Suggested Sentence Breaks:")
                                .font(.subheadline)
                                .fontWeight(.semibold)

                            ForEach(Array(sentencePoints.dropLast().enumerated()), id: \.offset) { idx, point in
                                Button {
                                    applySplitAtOffset(point.endOffset)
                                } label: {
                                    HStack {
                                        Image(systemName: "scissors")
                                        Text("Split after sentence \(idx + 1):")
                                            .fontWeight(.medium)
                                        Text("\"\(point.sentence.prefix(50))\(point.sentence.count > 50 ? "..." : "")\"")
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .font(.caption)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Split Preview / Editing
                    VStack(alignment: .leading, spacing: 16) {
                        // Part 1
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label("First Part (\(turn.speaker))", systemImage: "person.fill")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                Spacer()
                                if let ts = turn.timestamp {
                                    Text("Starts at [\(ts)]")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            TextEditor(text: $part1)
                                .font(.body)
                                .frame(minHeight: 70)
                                .padding(6)
                                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                        }

                        // Divider / Split indicator
                        HStack {
                            VStack { Divider() }
                            Image(systemName: "scissors")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                            VStack { Divider() }
                        }

                        // Part 2
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Second Part", systemImage: "person.badge.plus")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                Spacer()
                                Text("Estimated at [\(estimatedTimestamp)]")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            // Speaker Selection for Part 2
                            HStack(spacing: 12) {
                                Text("Speaker:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Picker("Speaker", selection: $selectedSpeaker) {
                                    ForEach(availableSpeakers, id: \.self) { spk in
                                        Text(spk).tag(spk)
                                    }
                                    Text("+ New Speaker...").tag("__NEW__")
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 220)
                                .onChange(of: selectedSpeaker) { _, newValue in
                                    isCreatingNewSpeaker = (newValue == "__NEW__")
                                }

                                if isCreatingNewSpeaker {
                                    TextField("Enter speaker name", text: $newSpeakerName)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.callout)
                                        .frame(maxWidth: 180)
                                }
                            }

                            TextEditor(text: $part2)
                                .font(.body)
                                .frame(minHeight: 70)
                                .padding(6)
                                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    executeSplit()
                } label: {
                    Label("Split Turn", systemImage: "scissors")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(part1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          part2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          (isCreatingNewSpeaker && newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
            .padding()
        }
        .frame(width: 580, height: 600)
        .onAppear {
            initializeDefaults()
        }
        .onChange(of: part1) { _, _ in
            updateEstimatedTimestamp()
        }
    }

    private func initializeDefaults() {
        // Choose default split point
        if sentencePoints.count > 1 {
            applySplitAtOffset(sentencePoints[0].endOffset)
        } else {
            let mid = turn.text.count / 2
            applySplitAtOffset(max(1, mid))
        }

        // Choose default second speaker
        let other = availableSpeakers.first { $0.caseInsensitiveCompare(turn.speaker) != .orderedSame }
        selectedSpeaker = other ?? (turn.speaker == "Speaker 1" ? "Speaker 2" : "Speaker 1")
    }

    private func applySplitAtOffset(_ offset: Int) {
        let text = turn.text
        guard offset > 0 && offset < text.count else { return }
        let idx = text.index(text.startIndex, offsetBy: offset)
        part1 = String(text[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        part2 = String(text[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
        updateEstimatedTimestamp()
    }

    private func updateEstimatedTimestamp() {
        let startSec = turn.timestampSeconds ?? (Double(turn.id) * 15.0)
        let totalLen = max(1, part1.count + part2.count)
        let ratio = max(0.1, min(0.9, Double(part1.count) / Double(totalLen)))
        let nextStartSec = startSec + max(10.0, Double(totalLen) * 0.08)
        let splitSec = startSec + (ratio * (nextStartSec - startSec))
        estimatedTimestamp = TranscriptTurn.formatSeconds(Float(splitSec))
    }

    private func executeSplit() {
        let finalSpeaker: String
        if isCreatingNewSpeaker {
            let clean = newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
            finalSpeaker = clean.isEmpty ? "New Speaker" : clean
            model.addSpeaker(name: finalSpeaker)
        } else {
            finalSpeaker = selectedSpeaker
        }

        model.splitTurn(
            in: file,
            turnIndex: turn.id,
            part1Text: part1,
            part2Text: part2,
            newSpeaker: finalSpeaker,
            splitTimestamp: estimatedTimestamp
        )
        dismiss()
    }
}
