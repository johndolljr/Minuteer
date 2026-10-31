import SwiftUI
import MinuteerCore

struct SidebarView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            // SD Card Status Header Card
            sdCardHeaderView
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            // Recordings List
            recordingsListView

            Divider()

            // Bottom Status / Controls
            bottomControlsView
                .padding(10)
        }
    }

    private var sdCardHeaderView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isCardInserted ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .shadow(color: isCardInserted ? Color.green.opacity(0.4) : Color.clear, radius: 3)

                Image(systemName: "sdcard.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(isCardInserted ? Color.primary : Color.secondary)

                Text(model.targetVolumeName)
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Button {
                    model.rescanCard()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Rescan SD card")

                Button {
                    model.promptEjectCard()
                } label: {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .disabled(!isCardInserted)
                .help("Eject \(model.targetVolumeName) safely")
            }

            if case .inserted(_, let freeBytes, let totalBytes) = model.sdCardStatus {
                let freeGB = Double(freeBytes) / 1_073_741_824.0
                let totalGB = Double(totalBytes) / 1_073_741_824.0
                let usedRatio = totalBytes > 0 ? max(0, min(1.0, 1.0 - (Double(freeBytes) / Double(totalBytes)))) : 0.0

                VStack(spacing: 4) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.18))
                            Capsule()
                                .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.8)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(4, g.size.width * CGFloat(usedRatio)))
                        }
                    }
                    .frame(height: 4)

                    HStack {
                        Text(String(format: "%.1f GB free", freeGB))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "of %.1f GB", totalGB))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                }
            } else {
                Text("Insert SD card '\(model.targetVolumeName)' to begin")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if model.watchDirectoryEnabled && !model.watchDirectoryPath.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "eye.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.purple)
                    Text("Watch: \(URL(fileURLWithPath: model.watchDirectoryPath).lastPathComponent)")
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Circle()
                        .fill(Color.purple)
                        .frame(width: 6, height: 6)
                }
                .padding(.top, 2)
            }

            Divider()
                .padding(.vertical, 2)

            HStack {
                Label("Auto-process", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: $model.autoProcessOnInsert)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private var isCardInserted: Bool {
        if case .inserted = model.sdCardStatus {
            return true
        }
        return false
    }

    private func sessionGlyph(for slug: String) -> String {
        SessionTypeConfig.glyph(for: slug)
    }

    struct DayGroup: Identifiable {
        let id: Date
        let title: String
        let recordings: [AudioRecordingFile]
    }

    private var groupedRecordings: [DayGroup] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: model.recordings) { file in
            calendar.startOfDay(for: file.creationDate)
        }
        let sortedDays = groups.keys.sorted(by: >)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none

        return sortedDays.compactMap { day in
            guard let files = groups[day], !files.isEmpty else { return nil }
            let title: String
            if calendar.isDateInToday(day) {
                title = "Today"
            } else if calendar.isDateInYesterday(day) {
                title = "Yesterday"
            } else {
                title = dateFormatter.string(from: day)
            }
            let sortedFiles = files.sorted(by: { $0.creationDate > $1.creationDate })
            return DayGroup(id: day, title: title, recordings: sortedFiles)
        }
    }

    private var recordingsListView: some View {
        List(selection: Binding(
            get: { model.selectedRecordingID ?? model.recordings.first?.id },
            set: { newID in
                if let newID = newID, let file = model.recordings.first(where: { $0.id == newID }) {
                    model.selectFile(file)
                } else if let newID = newID {
                    model.selectedRecordingID = newID
                } else if let currentID = model.selectedRecordingID, model.recordings.contains(where: { $0.id == currentID }) {
                    model.selectedRecordingID = currentID
                } else {
                    model.selectedRecordingID = model.recordings.first?.id
                }
            }
        )) {
            if model.recordings.isEmpty {
                Section {
                    Text("No audio recordings found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } header: {
                    Text("Recordings")
                }
            } else {
                ForEach(groupedRecordings) { group in
                    Section {
                        ForEach(group.recordings) { file in
                            recordingRow(for: file)
                                .tag(file.id)
                                .contextMenu {
                                    Menu("Set Session Type") {
                                        ForEach(model.sessionTypes) { session in
                                            Button {
                                                model.setSessionType(for: file, to: session)
                                            } label: {
                                                HStack {
                                                    Text(session.name)
                                                    if (file.sessionType ?? model.activeSessionType.name) == session.name {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    Divider()
                                    Button("Process Recording") {
                                        model.processFile(file)
                                    }
                                    Button(role: .destructive) {
                                        model.promptDeleteFile(file)
                                    } label: {
                                        Text("Delete Audio")
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text(group.title)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(group.recordings.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: model.selectedRecordingID) { _, _ in
            model.loadAudioForSelectedFile()
        }
    }

    private var hasUnprocessedFiles: Bool {
        model.recordings.contains { $0.status != .completed }
    }

    private func recordingRow(for file: AudioRecordingFile) -> some View {
        let isSelected = file.id == model.selectedRecordingID

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: fileGlyphIcon(for: file))
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                Text(file.noteTitle ?? file.displayName)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)

                Spacer()

                statusBadge(for: file)
            }

            if file.status == .transcribing {
                ProgressView(value: max(file.transcriptionProgress, 0.03))
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
            }

            HStack(spacing: 4) {
                Text(file.formattedTime)
                Text("•")
                Text(file.formattedDuration)
                Text("•")
                Text(file.formattedFileSize)
                Text("•")
                let sessionSlug = file.sessionType ?? model.sessionConfig(for: file).slug
                let sessionName = file.sessionType ?? model.sessionConfig(for: file).name
                HStack(spacing: 3) {
                    Text(sessionGlyph(for: sessionSlug))
                        .font(.system(size: 8))
                    Text(sessionName)
                        .font(.system(size: 9, weight: .semibold))
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.12))
                .foregroundStyle(Color.accentColor)
                .clipShape(Capsule())

                if let conf = file.classificationConfidence, conf > 0.80 {
                    Text("✨")
                        .font(.system(size: 9))
                        .help("Auto-classified with \(Int(conf * 100))% confidence")
                }
                if let cconf = file.calendarMatchConfidence, cconf > 0.80 {
                    Text("🗓️")
                        .font(.system(size: 9))
                        .help("Auto-matched meeting with \(Int(cconf * 100))% confidence")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectFile(file)
        }
    }

    private func fileGlyphIcon(for file: AudioRecordingFile) -> String {
        switch file.status {
        case .completed:
            return "waveform"
        case .transcribing:
            return "waveform.badge.magnifyingglass"
        case .summarizing:
            return "brain.head.profile"
        case .discovered, .transcribed:
            return "mic"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    private func statusBadge(for file: AudioRecordingFile) -> some View {
        HStack(spacing: 3) {
            switch file.status {
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text("Done")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
            case .transcribing:
                ProgressView()
                    .controlSize(.mini)
                Text("\(Int(file.transcriptionProgress * 100))%")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.blue)
            case .transcribed:
                Text("Transcribed")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.blue)
            case .summarizing:
                ProgressView()
                    .controlSize(.mini)
                Text("Summarizing")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.purple)
            case .discovered:
                Text("Pending")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                Text("Error")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(statusBadgeBackground(for: file.status))
        .clipShape(Capsule())
        .help(file.status == .failed ? (file.errorMessage ?? "An error occurred during processing.") : file.status.rawValue)
    }

    private func statusBadgeBackground(for status: IngestionStatus) -> Color {
        switch status {
        case .completed:
            return Color.green.opacity(0.12)
        case .transcribing, .transcribed:
            return Color.blue.opacity(0.12)
        case .summarizing:
            return Color.purple.opacity(0.12)
        case .discovered:
            return Color.secondary.opacity(0.08)
        case .failed:
            return Color.red.opacity(0.12)
        }
    }

    private var bottomControlsView: some View {
        HStack(spacing: 8) {
            switch model.pipelineStatus {
            case .idle:
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Ready")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .completed(let name, _):
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text("Processed \(name)")
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                }
            case .error(let name, let msg):
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(name != nil ? "Error: \(name!)" : "Error: \(msg)")
                        .font(.caption2)
                        .lineLimit(1)
                }
            case .scanning, .transcribing, .summarizing, .exporting:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.pipelineStatus.statusDescription)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Neural Engine Dock Badge
            Text("CoreML ANE")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
                .help("Processing with Apple Neural Engine on-device")

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("App Settings & Prompt Instructions (⌘,)")
        }
    }
}
