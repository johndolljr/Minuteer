import SwiftUI
import MinuteerCore

struct MinuteerMenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Minuteer")
            .font(.headline)

        if model.pipelineStatus.isRunning {
            Text("⚡ \(model.pipelineStatus.statusDescription)")
        } else if case .inserted(let volumeURL, let freeBytes, _) = model.sdCardStatus {
            let freeFormatted = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
            Text("🟢 \(volumeURL.lastPathComponent) connected (\(freeFormatted) free)")
        } else {
            Text("⚪ Ready — monitoring for '\(model.config.targetVolumeName)'")
        }

        Divider()

        Button("Open Minuteer") {
            openMainWindow()
        }
        .keyboardShortcut("o", modifiers: .command)

        Button("Record Meeting…") {
            model.openMeetingRecorder()
            openMainWindow()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])

        if case .inserted(let volumeURL, _, _) = model.sdCardStatus {
            Button("Scan Audio Files") {
                Task {
                    await model.coordinator.scanAudioFiles(volumeURL: volumeURL)
                }
            }

            Button("Eject \(volumeURL.lastPathComponent)") {
                model.confirmEjectCard()
            }
        }

        if !model.recentRecordings.isEmpty {
            Divider()

            Text("Recent Recordings")
                .font(.caption)

            ForEach(model.recentRecordings) { file in
                Button {
                    model.selectFile(file)
                    openMainWindow()
                } label: {
                    Text("\(file.displayName) (\(file.formattedDuration))")
                }
            }
        }

        Divider()

        Toggle("Auto-process on Insert", isOn: $model.autoProcessOnInsert)

        Button("Reveal Notes Inbox…") {
            let url = URL(fileURLWithPath: model.exportDirectoryPath)
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        }

        Divider()

        Button("Settings…") {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Minuteer") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private func openMainWindow() {
        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
