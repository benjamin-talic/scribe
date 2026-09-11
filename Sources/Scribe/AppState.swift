import AppKit
import Observation

let notesApplicationPathKey = "notesApplicationPath"

@MainActor
@Observable
final class AppState {
    enum RecordingState: Equatable {
        case idle
        case recording(startedAt: Date)
    }

    var recordingState: RecordingState = .idle
    var pendingTranscriptions = 0
    var storageError: String?
    var meetingDetectionError: String?
    var recordingError: String?
    var notesClient: NotesClient = .claude
    var places: [Place] = []
    var notes: [MeetingNote] = []
    var transcriptionFailures: [RecordingSession] = []
    var noteGenerationFailures: [RecordingSession] = []
    var activeMeetingApplications: Set<MeetingApplication> = []
    var requestedRecordingApplication: MeetingApplication?
    var requestedAutomaticStopApplication: MeetingApplication?
    var onRecordingStarted: (() -> Void)?
    private var recordingApplication: MeetingApplication?
    private var recordingStartInProgress = false
    private var recordingStopInProgress = false
    private var deletingNoteIDs: Set<URL> = []
    private let sessionStore: SessionStore?
    private let recorder: (any RecordingControlling)?
    private let processingQueue: ProcessingQueue?

    init(
        sessionStore: SessionStore? = nil,
        recorder: (any RecordingControlling)? = nil,
        processingQueue: ProcessingQueue? = nil,
        storageError: String? = nil
    ) {
        self.sessionStore = sessionStore
        self.recorder = recorder
        self.processingQueue = processingQueue
        self.storageError = storageError
    }

    var isRecording: Bool {
        if case .recording = recordingState { return true }
        return false
    }

    func statusText(at date: Date) -> String {
        guard case let .recording(startedAt) = recordingState else {
            return pendingTranscriptions == 0 ? "Scribe" : "Scribe \(pendingTranscriptions)"
        }

        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func restoreSessions(at date: Date = .now) async {
        guard let sessionStore else { return }

        do {
            let recoveryWarnings = try await sessionStore.recoverInterruptedWork(at: date)
            let cleanupWarnings = try await sessionStore.cleanupExpiredAudio(at: date)
            let scan = try await sessionStore.scanSessions()
            pendingTranscriptions = scan.pendingTranscriptionCount
            transcriptionFailures = scan.sessions.filter { $0.stage == .pendingTranscription && $0.lastError != nil }
            noteGenerationFailures = scan.sessions.filter { $0.stage == .transcribed && $0.lastError != nil }
            let library = try await sessionStore.librarySnapshot()
            notesClient = library.notesClient
            places = library.places
            notes = library.notes
            let warnings = Set(recoveryWarnings + cleanupWarnings + scan.warnings + library.warnings).sorted()
            storageError = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        } catch {
            storageError = error.localizedDescription
        }
        processPendingTranscriptions()
    }

    func performMaintenance(at date: Date = .now) async {
        guard let sessionStore else { return }
        do {
            let warnings = try await sessionStore.cleanupExpiredAudio(at: date)
            if !warnings.isEmpty { storageError = warnings.joined(separator: "\n") }
        } catch {
            storageError = error.localizedDescription
        }
    }

    func handleMeetingEvent(_ event: MeetingEvent) {
        meetingDetectionError = nil
        switch event {
        case let .started(application):
            activeMeetingApplications.insert(application)
        case let .ended(application):
            activeMeetingApplications.remove(application)
            requestedAutomaticStopApplication = application
        }
    }

    func startRecording(for application: MeetingApplication? = nil, at date: Date = .now) async {
        guard let recorder, !isRecording, !recordingStartInProgress else { return }
        recordingStartInProgress = true
        defer { recordingStartInProgress = false }

        do {
            let session = try await recorder.start(for: application, at: date)
            recordingState = .recording(startedAt: session.startedAt)
            onRecordingStarted?()
            recordingApplication = application
            requestedRecordingApplication = nil
            requestedAutomaticStopApplication = nil
            recordingError = nil
        } catch {
            recordingError = error.localizedDescription
        }
    }

    func stopRecording(at date: Date = .now) async {
        guard let recorder, isRecording, !recordingStopInProgress else { return }
        recordingStopInProgress = true
        defer { recordingStopInProgress = false }

        do {
            _ = try await recorder.stop(at: date)
            recordingState = .idle
            recordingApplication = nil
            pendingTranscriptions = try await sessionStore?.pendingTranscriptionCount() ?? 0
            recordingError = nil
            processPendingTranscriptions()
        } catch {
            recordingState = .idle
            recordingApplication = nil
            recordingError = error.localizedDescription
            await loadLibrary()
        }
    }

    func stopRecording(ifMeetingEnded application: MeetingApplication, at date: Date = .now) async {
        guard Self.shouldAutomaticallyStop(
            recordingApplication: recordingApplication,
            endedApplication: application
        ) else { return }
        await stopRecording(at: date)
    }

    var manualRecordingApplication: MeetingApplication? {
        activeMeetingApplications.count == 1 ? activeMeetingApplications.first : nil
    }

    func loadLibrary() async {
        guard let sessionStore else { return }
        do {
            let library = try await sessionStore.librarySnapshot()
            notesClient = library.notesClient
            places = library.places
            notes = library.notes
            let sessions = try await sessionStore.allSessions()
            transcriptionFailures = sessions.filter { $0.stage == .pendingTranscription && $0.lastError != nil }
            noteGenerationFailures = sessions.filter { $0.stage == .transcribed && $0.lastError != nil }
            if !library.warnings.isEmpty { storageError = library.warnings.joined(separator: "\n") }
        } catch {
            storageError = error.localizedDescription
        }
    }

    func setNotesClient(_ client: NotesClient) async {
        guard let sessionStore else { return }
        do {
            try await sessionStore.setNotesClient(client)
            notesClient = client
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
    }

    func addPlace(name: String, directory: URL) async {
        guard let sessionStore else { return }
        do {
            try await sessionStore.addPlace(name: name, directory: directory)
            storageError = nil
            await loadLibrary()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func renamePlace(_ id: UUID, to name: String) async {
        guard let sessionStore else { return }
        do {
            try await sessionStore.renamePlace(id, to: name)
            storageError = nil
            await loadLibrary()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func removePlace(_ id: UUID) async {
        guard let sessionStore else { return }
        do {
            try await sessionStore.removePlace(id)
            storageError = nil
            await loadLibrary()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func moveNote(_ note: MeetingNote, to placeID: UUID?) async {
        guard let sessionStore else { return }
        do {
            try await sessionStore.moveNote(note, to: placeID)
            storageError = nil
            await loadLibrary()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func trashNote(_ note: MeetingNote) async {
        guard let sessionStore, notes.contains(where: { $0.id == note.id }),
              deletingNoteIDs.insert(note.id).inserted else { return }
        defer { deletingNoteIDs.remove(note.id) }
        do {
            try await sessionStore.trashNote(note)
            storageError = nil
            await loadLibrary()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func openNote(_ note: MeetingNote) async {
        let applicationPath = UserDefaults.standard.string(forKey: notesApplicationPathKey) ?? ""
        if applicationPath.isEmpty {
            if !NSWorkspace.shared.open(note.url) {
                storageError = "Could not open \(note.url.lastPathComponent). Choose an app in Settings."
            }
        } else {
            do {
                try await NSWorkspace.shared.open(
                    [note.url],
                    withApplicationAt: URL(filePath: applicationPath),
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } catch {
                storageError = "Could not open the note with your selected app: \(error.localizedDescription)"
            }
        }
    }

    func retryFailedProcessing() {
        processPendingTranscriptions()
    }

    static func shouldAutomaticallyStop(
        recordingApplication: MeetingApplication?,
        endedApplication: MeetingApplication
    ) -> Bool {
        recordingApplication == endedApplication
    }

    private func processPendingTranscriptions() {
        guard let processingQueue, let sessionStore else { return }
        Task { [weak self] in
            do {
                try await processingQueue.processPendingTranscriptions()
                self?.pendingTranscriptions = try await sessionStore.pendingTranscriptionCount()
                await self?.loadLibrary()
            } catch {
                self?.storageError = error.localizedDescription
            }
        }
    }
}
