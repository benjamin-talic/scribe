import Foundation
import Observation

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
    var activeMeetingApplications: Set<MeetingApplication> = []
    var requestedRecordingApplication: MeetingApplication?
    var requestedAutomaticStopApplication: MeetingApplication?
    private var recordingApplication: MeetingApplication?
    private var recordingStartInProgress = false
    private let sessionStore: SessionStore?
    private let recorder: (any RecordingControlling)?

    init(
        sessionStore: SessionStore? = nil,
        recorder: (any RecordingControlling)? = nil,
        storageError: String? = nil
    ) {
        self.sessionStore = sessionStore
        self.recorder = recorder
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
            let scan = try await sessionStore.scanSessions()
            pendingTranscriptions = scan.pendingTranscriptionCount
            let warnings = Set(recoveryWarnings + scan.warnings).sorted()
            storageError = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
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
            recordingApplication = application
            requestedRecordingApplication = nil
            requestedAutomaticStopApplication = nil
            recordingError = nil
        } catch {
            recordingError = error.localizedDescription
        }
    }

    func stopRecording(at date: Date = .now) async {
        guard let recorder, isRecording else { return }

        do {
            _ = try await recorder.stop(at: date)
            recordingState = .idle
            recordingApplication = nil
            pendingTranscriptions = try await sessionStore?.pendingTranscriptionCount() ?? 0
            recordingError = nil
        } catch {
            recordingState = .idle
            recordingApplication = nil
            recordingError = error.localizedDescription
            await restoreSessions(at: date)
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

    static func shouldAutomaticallyStop(
        recordingApplication: MeetingApplication?,
        endedApplication: MeetingApplication
    ) -> Bool {
        recordingApplication == endedApplication
    }
}
