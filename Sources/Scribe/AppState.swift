import AppKit
import Carbon.HIToolbox
import Observation

let notesApplicationPathKey = "notesApplicationPath"

@MainActor
@Observable
final class AppState {
    enum RecordingState: Equatable {
        case idle
        case recording(startedAt: Date)
    }

    enum DictationState: Equatable {
        case idle
        case starting
        case recording(startedAt: Date)
        case processing
        case copied
        case failed(String)
    }

    var recordingState: RecordingState = .idle
    var dictationState: DictationState = .idle
    var dictationHotKey: DictationHotKey
    var dictationHotKeyRegistrar: ((DictationHotKey) -> OSStatus)?
    var hotKeyError: String?
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
    private var recordingStartTask: Task<Void, Never>?
    private var recordingStopInProgress = false
    private var dictationEpoch = 0
    /// Every in-flight `stop()` operation, keyed by its generation — including ones the user has
    /// already cancelled at the UI level. An entry is only removed once its own Task finishes, so
    /// `shutdown()` can await every task-owned temp-file cleanup, not just the current generation.
    private var dictationTasks: [Int: Task<Void, Never>] = [:]
    private var dictationResetTask: Task<Void, Never>?
    private var isShuttingDown = false
    private var deletingNoteIDs: Set<URL> = []
    private let sessionStore: SessionStore?
    private let recorder: (any RecordingControlling)?
    private let processingQueue: ProcessingQueue?
    private let dictationController: (any DictationControlling)?
    private let pasteboard: any DictationPasteboard
    private let hotKeyDefaults: UserDefaults
    private let dictationTiming: any DictationTiming

    init(
        sessionStore: SessionStore? = nil,
        recorder: (any RecordingControlling)? = nil,
        processingQueue: ProcessingQueue? = nil,
        dictationController: (any DictationControlling)? = nil,
        pasteboard: any DictationPasteboard = NSPasteboard.general,
        hotKeyDefaults: UserDefaults = .standard,
        dictationTiming: any DictationTiming = OSLogDictationTiming(),
        storageError: String? = nil
    ) {
        self.sessionStore = sessionStore
        self.recorder = recorder
        self.processingQueue = processingQueue
        self.dictationController = dictationController
        self.pasteboard = pasteboard
        self.hotKeyDefaults = hotKeyDefaults
        self.dictationTiming = dictationTiming
        self.dictationHotKey = .loadPersisted(from: hotKeyDefaults)
        self.storageError = storageError
    }

    var isRecording: Bool {
        if case .recording = recordingState { return true }
        return false
    }

    /// True while dictation owns (or is claiming) capture hardware or a decode — i.e. every phase
    /// EXCEPT the transient `.copied`/`.failed` feedback, so that feedback window doesn't block
    /// meeting recording from starting.
    var isDictationBusy: Bool {
        switch dictationState {
        case .starting, .recording, .processing: true
        case .idle, .copied, .failed: false
        }
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

    /// Wraps the actual start in a Task stored in `recordingStartTask` so `shutdown()` — running on
    /// a different call stack — can await the exact same in-flight operation, rather than relying
    /// on `startRecording` to notice a shutdown after the fact (by which point `shutdown()` may
    /// already have returned). Every menu/toast/manual call site goes through this one method, so
    /// this tracking covers all of them without any call-site changes.
    func startRecording(for application: MeetingApplication? = nil, at date: Date = .now) async {
        guard let recorder, !isRecording, !recordingStartInProgress, !isShuttingDown else { return }
        guard !isDictationBusy else {
            recordingError = "Stop dictation before recording a meeting."
            return
        }
        recordingStartInProgress = true

        let task: Task<Void, Never> = Task { [weak self] in
            await self?.performStartRecording(recorder: recorder, application: application, at: date)
        }
        recordingStartTask = task
        await task.value
        recordingStartInProgress = false
        recordingStartTask = nil
    }

    private func performStartRecording(
        recorder: any RecordingControlling,
        application: MeetingApplication?,
        at date: Date
    ) async {
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

    /// Pressing the toggle while permission is pending (`.starting`) cancels the pending start,
    /// matching the panel's own Cancel affordance for that phase.
    func toggleDictation(at date: Date = .now) async {
        switch dictationState {
        case .idle, .copied, .failed:
            await startDictation(at: date)
        case .starting:
            cancelDictation()
        case .recording:
            requestStopDictation()
        case .processing:
            break
        }
    }

    func startDictation(at date: Date = .now) async {
        guard let dictationController, !isDictationBusy, !isShuttingDown else { return }
        guard !isRecording, !recordingStartInProgress else {
            dictationState = .failed("Stop the meeting recording before dictating.")
            scheduleDictationReset()
            return
        }
        dictationEpoch += 1
        let epoch = dictationEpoch
        dictationResetTask?.cancel()
        dictationState = .starting

        do {
            try await dictationController.start(generation: epoch)
            guard epoch == dictationEpoch, !isShuttingDown else { return }
            dictationState = .recording(startedAt: date)
        } catch {
            guard epoch == dictationEpoch, !isShuttingDown else { return }
            dictationState = .failed(error.localizedDescription)
            scheduleDictationReset()
        }
    }

    /// Fire-and-track: the actual stop/transcribe runs on a Task owned by `dictationTasks`, keyed
    /// by this operation's generation, so `shutdown()` can await it even if the UI has already
    /// moved on (e.g. the user cancelled while it was still processing).
    func requestStopDictation() {
        guard let dictationController, case .recording = dictationState, !isShuttingDown else { return }
        let epoch = dictationEpoch
        dictationState = .processing
        let stopRequestedAt = ContinuousClock.now
        dictationTasks[epoch] = Task { [weak self] in
            await self?.runStopDictation(epoch: epoch, controller: dictationController, stopRequestedAt: stopRequestedAt)
        }
    }

    private func runStopDictation(
        epoch: Int,
        controller: any DictationControlling,
        stopRequestedAt: ContinuousClock.Instant
    ) async {
        defer { dictationTasks.removeValue(forKey: epoch) }
        do {
            let text = try await controller.stop(generation: epoch)
            dictationTiming.recordDuration("dictation.stopToResult", ContinuousClock.now - stopRequestedAt)
            guard epoch == dictationEpoch, !isShuttingDown else { return }
            guard pasteboard.writeText(text) else {
                dictationState = .failed("Could not copy the transcript to the clipboard.")
                scheduleDictationReset()
                return
            }
            dictationTiming.recordDuration("dictation.stopToClipboard", ContinuousClock.now - stopRequestedAt)
            dictationState = .copied
            scheduleDictationReset()
        } catch {
            guard epoch == dictationEpoch, !isShuttingDown else { return }
            dictationState = .failed(error.localizedDescription)
            scheduleDictationReset()
        }
    }

    /// Synchronous and immediate: invalidates the current generation so any later completion
    /// (a pending `start()` past its permission await, or an in-flight `stop()`) is discarded
    /// rather than clearing newer state or hardware it no longer owns.
    func cancelDictation() {
        guard dictationState != .idle else { return }
        dictationResetTask?.cancel()
        switch dictationState {
        case .starting, .recording:
            dictationController?.cancel(generation: dictationEpoch)
        case .processing:
            dictationTasks[dictationEpoch]?.cancel()
        case .idle, .copied, .failed:
            break
        }
        dictationEpoch += 1
        dictationState = .idle
    }

    /// Called on Quit. Invalidates every dictation generation and cancels any owned capture
    /// synchronously, BEFORE any await, so a pending transcript from a stale generation cannot
    /// copy to the clipboard while the awaits below are in flight. Then drains an in-flight
    /// meeting start (a post-await `isShuttingDown` check inside `startRecording` alone isn't
    /// enough — `shutdown()` could already have returned by the time that check runs — so
    /// `shutdown()` itself awaits the exact same tracked task), stops/finalizes any recording that
    /// start resolved to, and finally waits for every task-owned dictation temp file to actually
    /// finish cleaning up — including tasks for generations the user already cancelled — before
    /// returning, so `NSApp.terminate` never kills any of this mid-flight.
    func shutdown() async {
        isShuttingDown = true
        cancelDictation()

        if let recordingStartTask {
            await recordingStartTask.value
        }
        await stopRecording()

        for task in dictationTasks.values {
            await task.value
        }

        await dictationController?.shutdown()
    }

    /// Re-registering the shortcut currently in effect is a no-op. Otherwise the new shortcut is
    /// registered before anything is persisted or replaces `dictationHotKey`; a failed
    /// registration leaves the previous, still-working shortcut untouched and reports why.
    func setDictationHotKey(_ hotKey: DictationHotKey) {
        guard hotKey != dictationHotKey else { return }
        guard let registrar = dictationHotKeyRegistrar else {
            dictationHotKey = hotKey
            hotKey.persist(to: hotKeyDefaults)
            return
        }
        let status = registrar(hotKey)
        guard status == noErr else {
            hotKeyError = "Could not register that shortcut (status \(status)). Keeping the previous one."
            return
        }
        dictationHotKey = hotKey
        hotKey.persist(to: hotKeyDefaults)
        hotKeyError = nil
    }

    private func scheduleDictationReset() {
        dictationResetTask?.cancel()
        dictationResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.dictationState = .idle
        }
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
