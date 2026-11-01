import SwiftUI
import MinuteerCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // Keep running in the menu bar for background auto-ingestion
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NotificationCenter.default.post(name: .openMinuteerMainWindow, object: nil)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }
}

extension Notification.Name {
    static let openMinuteerMainWindow = Notification.Name("openMinuteerMainWindow")
}

@main
struct MinuteerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Minuteer", id: "main") {
            MainWindowContentView(model: model)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra {
            MinuteerMenuBarView(model: model)
                .onReceive(NotificationCenter.default.publisher(for: .openMinuteerMainWindow)) { _ in
                    openMainWindow()
                }
        } label: {
            Label("Minuteer", systemImage: model.menuBarIconName)
        }
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

struct MainWindowContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        } detail: {
            DetailView(model: model)
        }
        .frame(minWidth: 880, minHeight: 560)
        .confirmationDialog(
            "Delete Recording?",
            isPresented: $model.showDeleteAlert,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                model.confirmDeleteFile()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let file = model.filePendingDelete {
                Text("Are you sure you want to delete '\(file.displayName)'? This will remove the cached audio copy and notes from your library.")
            } else {
                Text("Are you sure you want to delete this recording from your library?")
            }
        }
        .confirmationDialog(
            "Eject SD Card?",
            isPresented: $model.showEjectAlert,
            titleVisibility: .visible
        ) {
            Button("Eject \(model.config.targetVolumeName)") {
                model.confirmEjectCard()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to eject '\(model.config.targetVolumeName)'?")
        }
        .alert(
            "Notice",
            isPresented: $model.showAlertError
        ) {
            Button("OK") {
                model.showAlertError = false
            }
        } message: {
            Text(model.alertErrorMessage ?? "An unknown error occurred.")
        }
        .onAppear {
            model.start()
        }
    }
}
