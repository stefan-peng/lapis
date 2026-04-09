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
            SidebarCommands()
            InspectorCommands()
        }
    }
}
