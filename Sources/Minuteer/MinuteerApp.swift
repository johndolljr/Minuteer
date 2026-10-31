import SwiftUI
import MinuteerCore

@main
struct MinuteerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
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
                Button("Eject P2_SD") {
                    model.confirmEjectCard()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to eject 'P2_SD'?")
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
            .onDisappear {
                model.stop()
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView(model: model)
        }
    }
}
