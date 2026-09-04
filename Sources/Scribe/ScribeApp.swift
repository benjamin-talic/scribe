import AppKit
import SwiftUI

@main
struct ScribeApp: App {
    @State private var state: AppState
    private let meetingDetector: MeetingDetector
    private let meetingNotifications: MeetingNotifications

    init() {
        let state: AppState
        do {
            let store = try SessionStore()
            state = AppState(
                sessionStore: store,
                recorder: RecordingController(sessionStore: store),
                processingQueue: ProcessingQueue(sessionStore: store)
            )
        } catch {
            state = AppState(storageError: error.localizedDescription)
        }
        _state = State(initialValue: state)

        let detector = MeetingDetector()
        let notifications = MeetingNotifications()
        meetingDetector = detector
        meetingNotifications = notifications
        notifications.onStart = { [weak state] application in
            state?.requestedRecordingApplication = application
            Task { await state?.startRecording(for: application) }
        }
        notifications.configure()
        detector.onEvent = { [weak state, weak notifications] event in
            guard let notifications else { return }
            state?.handleMeetingEvent(event)
            switch event {
            case let .started(application): notifications.offerRecording(for: application)
            case let .ended(application):
                notifications.clearOffer(for: application)
                Task { await state?.stopRecording(ifMeetingEnded: application) }
            }
        }
        detector.onError = { [weak state] error in
            state?.meetingDetectionError = error
        }

        Task {
            await state.restoreSessions()
            if !(await notifications.requestAuthorization()) {
                state.meetingDetectionError = "Notifications are disabled, so meeting prompts cannot be shown."
            }
            detector.start()
        }
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

            if let application = state.activeMeetingApplications.first {
                Label("Meeting detected in \(application.name)", systemImage: "mic")
                    .foregroundStyle(.secondary)
            }

            if let storageError = state.storageError {
                Label(storageError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            if let meetingDetectionError = state.meetingDetectionError {
                Label(meetingDetectionError, systemImage: "mic.slash")
                    .foregroundStyle(.red)
            }

            if let recordingError = state.recordingError {
                Label(recordingError, systemImage: "waveform.badge.exclamationmark")
                    .foregroundStyle(.red)
            }

            Divider()

            if state.isRecording {
                Button("Stop Recording") {
                    Task { await state.stopRecording() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button("Start Recording") {
                    Task { await state.startRecording(for: state.manualRecordingApplication) }
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Open Scribe") {
                openWindow(id: "library")
                NSApp.activate()
            }
            .buttonStyle(.borderedProminent)

            Button("Quit") {
                Task {
                    await state.stopRecording()
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(width: 280)
    }
}

private struct LibraryView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case inbox
        case places
        case settings

        var id: Self { self }

        var title: String {
            switch self {
            case .inbox: "Inbox"
            case .places: "Places"
            case .settings: "Settings"
            }
        }

        var icon: String {
            switch self {
            case .inbox: "tray"
            case .places: "folder"
            case .settings: "gearshape"
            }
        }
    }

    @State private var selection: Section? = .inbox

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("Scribe")
        } detail: {
            detail
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .inbox {
        case .inbox:
            ContentUnavailableView(
                "No meetings yet",
                systemImage: "waveform",
                description: Text("Completed meeting notes will appear here.")
            )
        case .places:
            ContentUnavailableView(
                "No places configured",
                systemImage: "folder",
                description: Text("Folder management will be added with the library.")
            )
        case .settings:
            Form {
                LabeledContent("Meeting apps", value: "Zoom, Arc")
                LabeledContent("Transcription", value: "Whisper small")
                LabeledContent("Speaker labels", value: "SpeakerKit")
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
        }
    }
}
