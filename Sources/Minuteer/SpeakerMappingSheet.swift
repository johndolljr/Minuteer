import SwiftUI
import MinuteerCore

struct SpeakerMappingSheet: View {
    @Bindable var model: AppModel
    let file: AudioRecordingFile
    @Environment(\.dismiss) private var dismiss

    @State private var mappings: [String: String] = [:]
    @State private var newSpeakerNames: [String: String] = [:]
    @State private var showNewSpeakerField: [String: Bool] = [:]

    private var parsedTurns: [TranscriptTurn] {
        TranscriptTurn.parseTurns(from: model.activeTranscript(for: file))
    }

    private var detectedSpeakers: [String] {
        var seen: [String] = []
        for turn in parsedTurns {
            let spk = turn.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            if !spk.isEmpty && !seen.contains(spk) {
                seen.append(spk)
            }
        }
        return seen
    }

    private func turnCount(for speaker: String) -> Int {
        parsedTurns.filter { $0.speaker.caseInsensitiveCompare(speaker) == .orderedSame }.count
    }

    private func sampleQuote(for speaker: String) -> String {
        let first = parsedTurns.first { $0.speaker.caseInsensitiveCompare(speaker) == .orderedSame }
        if let text = first?.text {
            return text.count > 80 ? "\(text.prefix(80))..." : text
        }
        return ""
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Identify & Map Speakers")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Assign detected speakers to known people or create new profiles. The app learns their acoustic voiceprint in the background to automatically identify them in future meetings without saving audio files.")
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

            // Speaker List
            ScrollView {
                VStack(spacing: 16) {
                    if detectedSpeakers.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("No speakers detected in this transcript.")
                                .font(.headline)
                            Text("Transcribe the audio file first to detect speakers.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 40)
                    } else {
                        ForEach(detectedSpeakers, id: \.self) { speaker in
                            speakerRow(for: speaker)
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Footer Actions
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Apply Mapping") {
                    applyMapping(reprocessSummary: false)
                }
                .controlSize(.regular)

                Button {
                    applyMapping(reprocessSummary: true)
                } label: {
                    Label("Apply & Reprocess Summary", systemImage: "sparkles")
                }
                .controlSize(.regular)
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 540, minHeight: 420)
        .onAppear {
            initializeMappings()
        }
    }

    private func initializeMappings() {
        for speaker in detectedSpeakers {
            if let matched = model.speakers.first(where: { $0.name.caseInsensitiveCompare(speaker) == .orderedSame || $0.aliases.contains(where: { $0.caseInsensitiveCompare(speaker) == .orderedSame }) }) {
                mappings[speaker] = matched.name
            } else {
                mappings[speaker] = speaker
            }
        }

        // Concurrently query acoustic voiceprints to auto-select recognized speakers
        Task {
            let identified = await AudioFingerprintEngine.identifySpeakers(
                in: file.url,
                turns: parsedTurns,
                directory: model.coordinator.speakerDirectory
            )
            for speaker in detectedSpeakers {
                if let turn = identified.first(where: { $0.id == parsedTurns.first(where: { $0.speaker == speaker })?.id }),
                   turn.speaker != speaker {
                    mappings[speaker] = turn.speaker
                }
            }
        }
    }

    private func speakerRow(for speaker: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                // Speaker avatar icon
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(speaker)
                            .font(.headline)
                        Text("(\(turnCount(for: speaker)) turns)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    let quote = sampleQuote(for: speaker)
                    if !quote.isEmpty {
                        Text("\"\(quote)\"")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Target Speaker Picker
                Picker("", selection: Binding(
                    get: { mappings[speaker] ?? speaker },
                    set: { newVal in
                        if newVal == "__new__" {
                            showNewSpeakerField[speaker] = true
                        } else {
                            showNewSpeakerField[speaker] = false
                            mappings[speaker] = newVal
                        }
                    }
                )) {
                    Section("Current File") {
                        Text(speaker).tag(speaker)
                    }

                    if !model.speakers.isEmpty {
                        Section("Known Speakers") {
                            ForEach(model.speakers) { known in
                                Text(known.name).tag(known.name)
                            }
                        }
                    }

                    Section {
                        Text("+ Create New Speaker...").tag("__new__")
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            // Inline New Speaker Input Field if "+ Create New Speaker" selected
            if showNewSpeakerField[speaker] == true {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                    TextField("Enter full name (e.g. Jane Doe)", text: Binding(
                        get: { newSpeakerNames[speaker] ?? "" },
                        set: { newSpeakerNames[speaker] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)

                    Button("Confirm") {
                        let name = (newSpeakerNames[speaker] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty {
                            mappings[speaker] = name
                            showNewSpeakerField[speaker] = false
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 32)
                .transition(.opacity)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func applyMapping(reprocessSummary: Bool) {
        for (oldName, newName) in mappings {
            if oldName != newName && !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.renameSpeaker(in: file, from: oldName, to: newName, saveToDirectory: true)
            }
        }

        dismiss()

        if reprocessSummary {
            let configToUse = model.sessionConfig(for: file)
            model.resummarizeFile(file, sessionConfig: configToUse)
        }
    }
}
