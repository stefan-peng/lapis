import AppKit
import SwiftUI

@main
struct LapisAppMain: App {
    @State private var appState: AppState?
    @State private var launchError: String?

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Lapis", id: "main") {
            Group {
                if let appState {
                    ContentView(state: appState)
                } else if let launchError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                        Text("Failed to launch Lapis")
                            .font(.headline)
                        Text(launchError)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 480, minHeight: 300)
                } else {
                    ProgressView()
                        .task {
                            do {
                                appState = try AppState(environment: .live())
                            } catch {
                                launchError = error.localizedDescription
                            }
                        }
                }
            }
            .frame(minWidth: 900, minHeight: 700)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandMenu("Library") {
                Button("Import Folder") {
                    appState?.importFolders()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(appState == nil)

                Button("Apply GPX") {
                    appState?.importGPX()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(appState == nil)

                Button("Export Selection") {
                    appState?.exportSelection()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(appState?.selectedAssetIDs.isEmpty ?? true)

                Button("Write XMP Sidecar") {
                    appState?.writeMetadataSidecar()
                }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                .disabled(appState?.selectedAsset == nil)

                Divider()

                Button(appState?.libraryDetailMode == .compare ? "Done Comparing" : "Compare Selection") {
                    guard let appState else { return }
                    if appState.libraryDetailMode == .compare {
                        appState.exitCompareMode()
                    } else {
                        appState.activateCompareMode()
                    }
                }
                .disabled(
                    !(
                        appState?.workspaceMode == .library &&
                        (
                            appState?.libraryDetailMode == .compare ||
                            appState?.canCompareSelection == true
                        )
                    )
                )
            }

            SidebarCommands()
            InspectorCommands()
        }
    }
}
