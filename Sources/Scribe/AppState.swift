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
    private let sessionStore: SessionStore?

    init(sessionStore: SessionStore? = nil, storageError: String? = nil) {
        self.sessionStore = sessionStore
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
}
