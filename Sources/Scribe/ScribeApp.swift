import AppKit
import SwiftUI

@main
struct ScribeApp: App {
    @State private var state: AppState

    init() {
        let state: AppState
        do {
            state = AppState(sessionStore: try SessionStore())
        } catch {
            state = AppState(storageError: error.localizedDescription)
        }
        _state = State(initialValue: state)
        Task { await state.restoreSessions() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(state)
        } label: {
            StatusLabel()
                .environment(state)
        }
        .menuBarExtraStyle(.window)

        Window("Scribe", id: "library") {
            LibraryView()
                .environment(state)
        }
        .defaultSize(width: 760, height: 500)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

private struct StatusLabel: View {
    @Environment(AppState.self) private var state

    @ViewBuilder
    var body: some View {
        if state.isRecording {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label(
                    state.statusText(at: context.date),
                    systemImage: "record.circle.fill"
                )
            }
        } else {
            Label(
                state.statusText(at: .now),
                systemImage: "waveform"
            )
        }
    }
}

private struct MenuView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.isRecording ? "Recording" : "Ready")
                .font(.headline)

            if state.pendingTranscriptions > 0 {
                Label(
                    "\(state.pendingTranscriptions) awaiting transcription",
                    systemImage: "text.badge.clock"
                )
                .foregroundStyle(.secondary)
            }

            if let storageError = state.storageError {
                Label(storageError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            Divider()

            Button("Open Scribe") {
                openWindow(id: "library")
                NSApp.activate()
            }
            .buttonStyle(.borderedProminent)

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(width: 280)
    }
}

private struct LibraryView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Label("Inbox", systemImage: "tray")
                Label("Places", systemImage: "folder")
                Label("Settings", systemImage: "gearshape")
            }
            .navigationTitle("Scribe")
        } detail: {
            ContentUnavailableView(
                "No meetings yet",
                systemImage: "waveform",
                description: Text("Completed meeting notes will appear here.")
            )
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
