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
            await state?.startRecording(for: application)
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
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3_600))
                guard !Task.isCancelled else { return }
                await state.performMaintenance()
            }
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
    @State private var date = Date.now

    @ViewBuilder
    var body: some View {
        if state.isRecording {
            Label(state.statusText(at: date), systemImage: "record.circle.fill")
                .labelStyle(.titleAndIcon)
                .task(id: state.recordingState) {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled else { return }
                        date = .now
                    }
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
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 38, height: 38)
                        .clipShape(.rect(cornerRadius: 9))
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)

            if hasDetails {
                VStack(alignment: .leading, spacing: 7) {
                    if state.pendingTranscriptions > 0 {
                        Label(
                            "\(state.pendingTranscriptions) awaiting transcription",
                            systemImage: "text.badge.clock"
                        )
                    }
                    if !state.noteGenerationFailures.isEmpty {
                        Label(
                            "\(state.noteGenerationFailures.count) note generation failed",
                            systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
                        )
                        .foregroundStyle(.orange)
                    }
                    if !state.transcriptionFailures.isEmpty {
                        Label(
                            "\(state.transcriptionFailures.count) transcription failed",
                            systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
                        )
                        .foregroundStyle(.orange)
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
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary, in: .rect(cornerRadius: 9))
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            VStack(spacing: 8) {
                Button {
                    Task {
                        if state.isRecording {
                            await state.stopRecording()
                        } else {
                            await state.startRecording(for: state.manualRecordingApplication)
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: state.isRecording ? "stop.fill" : "record.circle")
                        Text(state.isRecording ? "Stop Recording" : "Start Recording")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 9))
                .tint(state.isRecording ? .red : .accentColor)

                Button {
                    openWindow(id: "library")
                    NSApp.activate()
                } label: {
                    HStack {
                        Image(systemName: "rectangle.stack")
                        Text("Open Scribe")
                            .fontWeight(.medium)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 9))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            Divider()

            Button {
                Task {
                    await state.stopRecording()
                    NSApp.terminate(nil)
                }
            } label: {
                HStack {
                    Text("Quit Scribe")
                    Spacer()
                }
                .font(.caption)
                .contentShape(.rect)
                .padding(.horizontal, 14)
                .frame(height: 34)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 300)
    }

    private var statusSubtitle: String {
        if state.isRecording {
            return "Capturing meeting audio"
        }
        if let application = state.activeMeetingApplications.first {
            return "\(application.name) meeting detected"
        }
        return "Watching Zoom and Arc"
    }

    private var statusTitle: String {
        if state.recordingError != nil || state.storageError != nil || state.meetingDetectionError != nil {
            return "Needs Attention"
        }
        return state.isRecording ? "Recording" : "Scribe"
    }

    private var statusColor: Color {
        if state.recordingError != nil || state.storageError != nil || state.meetingDetectionError != nil { return .red }
        if !state.noteGenerationFailures.isEmpty || !state.transcriptionFailures.isEmpty { return .orange }
        return state.isRecording ? .red : .green
    }

    private var hasDetails: Bool {
        state.pendingTranscriptions > 0
            || !state.transcriptionFailures.isEmpty
            || !state.noteGenerationFailures.isEmpty
            || state.storageError != nil
            || state.meetingDetectionError != nil
            || state.recordingError != nil
    }
}

private struct LibraryView: View {
    @Environment(AppState.self) private var state

    private enum Selection: Hashable {
        case inbox
        case place(UUID)
        case places
        case settings
    }

    @State private var selection: Selection? = .inbox

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    Label("Inbox", systemImage: "tray")
                        .tag(Selection.inbox)
                    ForEach(state.places) { place in
                        Label(place.name, systemImage: "folder")
                            .tag(Selection.place(place.id))
                    }
                }
                Section {
                    Label("Places", systemImage: "folder.badge.gearshape")
                        .tag(Selection.places)
                    Label("Settings", systemImage: "gearshape")
                        .tag(Selection.settings)
                }
            }
            .navigationTitle("Scribe")
        } detail: {
            detail
        }
        .toolbar {
            Button {
                Task {
                    if state.isRecording {
                        await state.stopRecording()
                    } else {
                        await state.startRecording(for: state.manualRecordingApplication)
                    }
                }
            } label: {
                Label(
                    state.isRecording ? "Stop Recording" : "Start Recording",
                    systemImage: state.isRecording ? "stop.circle.fill" : "record.circle"
                )
            }
            .tint(state.isRecording ? .red : nil)
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            Task { await state.loadLibrary() }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
        .alert(
            "Scribe Error",
            isPresented: Binding(
                get: { state.storageError != nil },
                set: { if !$0 { state.storageError = nil } }
            )
        ) {
            Button("OK") { state.storageError = nil }
        } message: {
            Text(state.storageError ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .inbox {
        case .inbox:
            meetingList(title: "Inbox", notes: state.notes.filter { $0.placeID == nil }, showFailures: true)
        case let .place(id):
            if let place = state.places.first(where: { $0.id == id }) {
                meetingList(title: place.name, notes: state.notes.filter { $0.placeID == id })
            } else {
                ContentUnavailableView("Place Not Found", systemImage: "folder.badge.questionmark")
            }
        case .places:
            placesView
        case .settings:
            SettingsView()
        }
    }

    private func meetingList(title: String, notes: [MeetingNote], showFailures: Bool = false) -> some View {
        List {
            if showFailures, !processingFailures.isEmpty {
                Section {
                    ForEach(processingFailures) { session in
                        VStack(alignment: .leading) {
                            Label(
                                session.sourceApplication ?? "Manual recording",
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.orange)
                            Text(session.lastError ?? "Processing failed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HStack {
                        Text("Needs Attention")
                        Spacer()
                        Button("Retry All") { state.retryFailedProcessing() }
                    }
                }
            }
            ForEach(notes) { note in
                HStack {
                    Button {
                        NSWorkspace.shared.open(note.url)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(note.title)
                            Text(note.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if note.placeID != nil || state.places.contains(where: isAvailable) {
                        Menu {
                            if note.placeID != nil {
                                Button("Inbox") { Task { await state.moveNote(note, to: nil) } }
                            }
                            ForEach(state.places.filter { $0.id != note.placeID && isAvailable($0) }) { place in
                                Button(place.name) { Task { await state.moveNote(note, to: place.id) } }
                            }
                        } label: {
                            Label("Move", systemImage: "folder")
                        }
                        .menuStyle(.borderlessButton)
                    }
                }
            }
        }
        .overlay {
            if notes.isEmpty && (!showFailures || processingFailures.isEmpty) {
                ContentUnavailableView("No Meetings", systemImage: "waveform")
            }
        }
        .navigationTitle(title)
    }

    private var processingFailures: [RecordingSession] {
        state.transcriptionFailures + state.noteGenerationFailures
    }

    private var placesView: some View {
        VStack(spacing: 0) {
            List(state.places) { place in
                HStack {
                    VStack(alignment: .leading) {
                        Text(place.name)
                        Text(place.directory.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !isAvailable(place) {
                            Text("Unavailable")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    Menu {
                        Button("Rename") { rename(place) }
                        Button("Remove", role: .destructive) {
                            if selection == .place(place.id) { selection = .inbox }
                            Task { await state.removePlace(place.id) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            .overlay {
                if state.places.isEmpty {
                    ContentUnavailableView("No Places", systemImage: "folder")
                }
            }
            Divider()
            Button("Add Folder…", systemImage: "plus") { addPlace() }
                .padding()
        }
        .navigationTitle("Places")
    }

    private func addPlace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Place"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task { await state.addPlace(name: directory.lastPathComponent, directory: directory) }
    }

    private func rename(_ place: Place) {
        let field = NSTextField(string: place.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let alert = NSAlert()
        alert.messageText = "Rename Place"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await state.renamePlace(place.id, to: field.stringValue) }
    }

    private func isAvailable(_ place: Place) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: place.directory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: place.directory.path)
    }

}
