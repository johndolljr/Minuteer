import SwiftUI
import MinuteerCore
import AVFoundation
import ScreenCaptureKit

struct MeetingRecorderView: View {
    @Bindable var model: AppModel
    @ObservedObject var engine: AudioMixerEngine
    @Environment(\.dismiss) private var dismiss

    @State private var elapsedSeconds: TimeInterval = 0
    @State private var timer: Timer? = nil
    @State private var showCalendarPicker: Bool = false
    @State private var showNewSpeakerDialog: Bool = false
    @State private var newSpeakerName: String = ""
    @State private var selectedChannelForNewSpeaker: UUID? = nil
    @State private var isFinalizing: Bool = false
    @State private var statusMessage: String? = nil
    @State private var availableMics: [AudioSourceDescriptor] = []
    @State private var availableApps: [AudioSourceDescriptor] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerView
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Calendar Event Linking Pill
            calendarLinkBanner
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            Divider()

            // Channels Mixer
            ScrollView {
                VStack(spacing: 12) {
                    if engine.channels.isEmpty {
                        emptyChannelsPlaceholder
                    } else {
                        ForEach(engine.channels) { channel in
                            channelStripView(channel)
                        }
                    }
                }
                .padding(20)
            }
            .frame(minHeight: 240)

            Divider()

            // Bottom Add Source & Master Controls
            footerControlsView
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 480, idealHeight: 540)
        .sheet(isPresented: $showCalendarPicker) {
            meetingCalendarPickerSheet
        }
        .sheet(isPresented: $showNewSpeakerDialog) {
            newSpeakerSheet
        }
        .onAppear {
            refreshSources()
            setupInitialSourcesIfNeeded()
            syncTimerState()
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: - Header
    private var headerView: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(statusIndicatorColor)
                .frame(width: 12, height: 12)
                .shadow(color: statusIndicatorColor.opacity(0.6), radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Meeting Recorder & Mixer")
                        .font(.headline)
                    Text(engine.state.title)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusIndicatorColor.opacity(0.15))
                        .foregroundStyle(statusIndicatorColor)
                        .clipShape(Capsule())
                }
                Text(elapsedTimeFormatted)
                    .font(.system(.title3, design: .monospaced, weight: .bold))
                    .foregroundStyle(engine.state.isRecording ? Color.primary : Color.secondary)
            }

            Spacer()

            if isFinalizing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(statusMessage ?? "Processing mixdown…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(engine.state.isRecording && !isFinalizing)
        }
    }

    // MARK: - Calendar Link Banner
    private var calendarLinkBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar")
                .foregroundStyle(engine.linkedCalendarEvent != nil ? Color.accentColor : Color.secondary)

            if let event = engine.linkedCalendarEvent {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(event.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text("(\(event.calendarTitle))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text(event.formattedTimeRange)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    engine.unlinkCalendarEvent()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Unlink calendar event")

                Button("Change…") {
                    showCalendarPicker = true
                }
                .controlSize(.small)
            } else {
                Text("No calendar meeting linked")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    showCalendarPicker = true
                } label: {
                    Label("Link Meeting…", systemImage: "link")
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Channel Strip View
    private func channelStripView(_ channel: AudioChannel) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // Source Icon
                Image(systemName: sourceIconName(for: channel.source.kind))
                    .font(.system(size: 16))
                    .frame(width: 28, height: 28)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                // Source Info & Speaker Assignment
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(channel.source.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)

                        Text(channel.source.kind.rawValue.capitalized)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Capsule())
                    }

                    // Speaker assignment dropdown
                    HStack(spacing: 6) {
                        Menu {
                            Button("None (General Audio)") {
                                engine.assignSpeaker(nil, for: channel.id)
                            }
                            Divider()
                            ForEach(model.coordinator.speakerDirectory.allSpeakers) { speaker in
                                Button(speaker.name) {
                                    engine.assignSpeaker(speaker.name, for: channel.id)
                                }
                            }
                            Divider()
                            Button("+ Add New Speaker…") {
                                selectedChannelForNewSpeaker = channel.id
                                newSpeakerName = ""
                                showNewSpeakerDialog = true
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "person.crop.circle")
                                    .font(.system(size: 10))
                                Text(channel.assignedSpeakerName ?? "Assign Speaker…")
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()

                        if let speaker = channel.assignedSpeakerName, !speaker.isEmpty {
                            Label("Stem Voiceprint Training", systemImage: "waveform.and.person.filled")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }

                Spacer()

                // Mute and Solo Buttons
                HStack(spacing: 4) {
                    Button {
                        engine.setMuted(for: channel.id, isMuted: !channel.isMuted)
                    } label: {
                        Text("M")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .frame(width: 24, height: 24)
                            .background(channel.isMuted ? Color.orange : Color.secondary.opacity(0.15))
                            .foregroundStyle(channel.isMuted ? Color.white : Color.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Mute stem")

                    Button {
                        engine.setSoloed(for: channel.id, isSoloed: !channel.isSolo)
                    } label: {
                        Text("S")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .frame(width: 24, height: 24)
                            .background(channel.isSolo ? Color.yellow : Color.secondary.opacity(0.15))
                            .foregroundStyle(channel.isSolo ? Color.black : Color.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Solo stem")
                }

                // Channel Gain Slider
                HStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { channel.volume },
                            set: { engine.setVolume($0, for: channel.id) }
                        ),
                        in: 0.0...1.5
                    )
                    .frame(width: 90)

                    Text("\(Int(channel.volume * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 34, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }

                // Remove stem button
                Button {
                    engine.removeChannel(id: channel.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(engine.state.isRecording)
                .help("Remove stem from recording")
            }

            // Real-time VU meter
            VULevelMeter(level: channel.isMuted ? 0.0 : channel.currentLevel)
                .frame(height: 5)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(channel.isSolo ? Color.yellow.opacity(0.6) : Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Footer & Transport Bar
    private var footerControlsView: some View {
        HStack(spacing: 14) {
            // Add Audio Source Menu
            Menu {
                Menu("Microphones") {
                    if availableMics.isEmpty {
                        Text("No microphones found")
                    } else {
                        ForEach(availableMics) { desc in
                            Button(desc.displayName) {
                                engine.addChannel(for: desc)
                            }
                        }
                    }
                }

                Menu("Applications") {
                    if availableApps.isEmpty {
                        Text("No running apps found")
                    } else {
                        ForEach(availableApps) { desc in
                            Button(desc.displayName) {
                                engine.addChannel(for: desc)
                            }
                        }
                    }
                }

                Divider()

                Button("System Audio (All Apps)") {
                    engine.addChannel(for: AudioCaptureDeviceManager.systemAudio())
                }
            } label: {
                Label("Add Source", systemImage: "plus")
            }
            .menuStyle(.borderedButton)
            .disabled(engine.state.isRecording)

            Spacer()

            // Master Volume
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { engine.masterVolume },
                        set: { engine.setMasterVolume($0) }
                    ),
                    in: 0.0...1.5
                )
                .frame(width: 80)
            }

            Divider()
                .frame(height: 20)

            // Transport Buttons
            switch engine.state {
            case .idle:
                Button {
                    startRecording()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle.fill")
                            .foregroundStyle(.red)
                        Text("Record Meeting")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(engine.channels.isEmpty || isFinalizing)

            case .recording:
                Button {
                    engine.pauseRecording()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .controlSize(.regular)

                Button {
                    stopAndIngest()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.circle.fill")
                        Text("Stop & Ingest")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(.red)
                .disabled(isFinalizing)

                Button("Discard", role: .destructive) {
                    cancelRecording()
                }
                .controlSize(.regular)

            case .paused:
                Button {
                    engine.resumeRecording()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .controlSize(.regular)

                Button {
                    stopAndIngest()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.circle.fill")
                        Text("Stop & Ingest")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(.red)
                .disabled(isFinalizing)

                Button("Discard", role: .destructive) {
                    cancelRecording()
                }
                .controlSize(.regular)

            case .mixing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finalizing mixdown…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions
    private func refreshSources() {
        availableMics = AudioCaptureDeviceManager.availableMicrophones()
        Task {
            let apps = await AudioCaptureDeviceManager.availableApplications()
            await MainActor.run {
                self.availableApps = apps
            }
        }
    }

    private func setupInitialSourcesIfNeeded() {
        if engine.channels.isEmpty {
            if let defaultMic = AudioCaptureDeviceManager.availableMicrophones().first {
                engine.addChannel(for: defaultMic)
            }
            engine.addChannel(for: AudioCaptureDeviceManager.systemAudio())
        }
    }

    private func startRecording() {
        Task {
            do {
                let tempSessionDir = model.coordinator.audioLibraryDirectory.appendingPathComponent(".session_temp", isDirectory: true)
                try await engine.startRecording(outputDirectory: tempSessionDir)
                await MainActor.run {
                    elapsedSeconds = 0
                    startTimer()
                }
            } catch {
                await MainActor.run {
                    model.alertErrorMessage = error.localizedDescription
                    model.showAlertError = true
                }
            }
        }
    }

    private func stopAndIngest() {
        isFinalizing = true
        statusMessage = "Finalizing stems & mixdown…"
        timer?.invalidate()
        timer = nil

        Task {
            do {
                let libraryDir = model.coordinator.audioLibraryDirectory
                try? FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
                let f = DateFormatter()
                f.dateFormat = "yyMMdd_HHmmss"
                let timestamp = f.string(from: Date())
                let destWAVURL = libraryDir.appendingPathComponent("\(timestamp)_MIX.WAV")

                let (finalURL, duration) = try await engine.stopRecording(finalOutputURL: destWAVURL)

                let size = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? 0
                let recFile = AudioRecordingFile(
                    url: finalURL,
                    fileSize: size,
                    creationDate: Date(),
                    duration: duration,
                    noteTitle: engine.linkedCalendarEvent?.title,
                    calendarEvent: engine.linkedCalendarEvent
                )

                await MainActor.run {
                    model.coordinator.mergeDiscoveredFiles([recFile])
                    model.selectedRecordingID = recFile.id
                    model.processFile(recFile)
                    isFinalizing = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isFinalizing = false
                    model.alertErrorMessage = error.localizedDescription
                    model.showAlertError = true
                }
            }
        }
    }

    private func cancelRecording() {
        timer?.invalidate()
        timer = nil
        elapsedSeconds = 0
        engine.cancelRecording()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak engine] _ in
            Task { @MainActor in
                if engine?.state.isRecording == true {
                    elapsedSeconds += 0.5
                }
            }
        }
    }

    private func syncTimerState() {
        if engine.state.isRecording {
            startTimer()
        }
    }

    // MARK: - Subviews & Sheets
    private var emptyChannelsPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No Audio Sources Added")
                .font(.headline)
            Text("Click '+ Add Source' below to attach a microphone, application, or system audio.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var meetingCalendarPickerSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Select Scheduled Calendar Meeting")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    showCalendarPicker = false
                }
            }
            .padding(16)

            Divider()

            List {
                if model.candidateCalendarEvents.isEmpty {
                    Text("No scheduled meetings found near today.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(model.candidateCalendarEvents) { event in
                        Button {
                            engine.linkCalendarEvent(event)
                            showCalendarPicker = false
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(event.title)
                                        .font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text(event.formattedTimeRange)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if !event.attendees.isEmpty {
                                    Text(event.attendees.joined(separator: ", "))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .onAppear {
                model.loadCalendarEventsForLiveMeeting()
            }
        }
        .frame(width: 440, height: 320)
    }

    private var newSpeakerSheet: some View {
        VStack(spacing: 16) {
            Text("Add Speaker Profile")
                .font(.headline)

            TextField("Speaker Name (e.g. John Doe)", text: $newSpeakerName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") {
                    showNewSpeakerDialog = false
                }
                Spacer()
                Button("Assign & Create") {
                    let clean = newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return }
                    if model.coordinator.speakerDirectory.getSpeaker(named: clean) == nil {
                        model.coordinator.speakerDirectory.addSpeaker(SpeakerProfile(name: clean))
                    }
                    if let chId = selectedChannelForNewSpeaker {
                        engine.assignSpeaker(clean, for: chId)
                    }
                    showNewSpeakerDialog = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    // MARK: - Helpers
    private var statusIndicatorColor: Color {
        switch engine.state {
        case .idle: return .secondary
        case .recording: return .red
        case .paused: return .orange
        case .mixing: return .yellow
        }
    }

    private var elapsedTimeFormatted: String {
        let total = Int(elapsedSeconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func sourceIconName(for kind: AudioSourceDescriptor.Kind) -> String {
        switch kind {
        case .microphone: return "mic.fill"
        case .runningApplication: return "app.fill"
        case .systemAudio: return "speaker.wave.2.fill"
        }
    }
}

// MARK: - VU Level Meter View
struct VULevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))

                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .green, location: 0.0),
                                .init(color: .green, location: 0.70),
                                .init(color: .yellow, location: 0.88),
                                .init(color: .red, location: 0.98)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(level))))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
    }
}
