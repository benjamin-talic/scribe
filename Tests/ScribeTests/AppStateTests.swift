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

    @Test
    func restoreSessionsLoadsBacklogAndSurfacesWarnings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scribe-app-state-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootURL: root)
        try await store.createSession(sourceApplication: "Zoom", id: "meeting")
        let broken = root.appending(path: "sessions/broken", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data().write(to: broken.appending(path: "meta.json"))
        let state = AppState(sessionStore: store)

        await state.restoreSessions(at: Date(timeIntervalSince1970: 10))

        #expect(state.pendingTranscriptions == 1)
        #expect(state.storageError?.contains("broken") == true)
    }
}
