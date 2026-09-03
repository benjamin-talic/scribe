import Foundation
import Testing
@testable import Scribe

@MainActor
struct AppStateTests {
    @Test
    func idleStatusWithoutBacklogShowsAppName() {
        #expect(AppState().statusText(at: .now) == "Scribe")
    }

    @Test
    func recordingStatusShowsElapsedTime() {
        let state = AppState()
        let start = Date(timeIntervalSince1970: 100)

        state.recordingState = .recording(startedAt: start)

        #expect(state.statusText(at: start.addingTimeInterval(125)) == "02:05")
    }

    @Test
    func idleStatusShowsBacklog() {
        let state = AppState()
        state.pendingTranscriptions = 2

        #expect(state.statusText(at: .now) == "Scribe 2")
    }
}
