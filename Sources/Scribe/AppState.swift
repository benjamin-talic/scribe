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
}
