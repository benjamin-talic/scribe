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
        #expect(state.transcriptionFailures.map(\.id) == ["meeting"])
        #expect(state.storageError?.contains("broken") == true)
    }

    @Test
    func endedMeetingRequestsAutomaticStop() {
        let state = AppState()
        let zoom = MeetingApplication(bundleID: "us.zoom.xos", name: "Zoom")

        state.handleMeetingEvent(.started(zoom))
        state.handleMeetingEvent(.ended(zoom))

        #expect(state.activeMeetingApplications.isEmpty)
        #expect(state.requestedAutomaticStopApplication == zoom)
    }

    @Test
    func automaticStopOnlyMatchesTheRecordedApplication() {
        let zoom = MeetingApplication(bundleID: "us.zoom.xos", name: "Zoom")
        let arc = MeetingApplication(bundleID: "company.thebrowser.Browser", name: "Arc")

        #expect(AppState.shouldAutomaticallyStop(recordingApplication: zoom, endedApplication: zoom))
        #expect(!AppState.shouldAutomaticallyStop(recordingApplication: zoom, endedApplication: arc))
        #expect(!AppState.shouldAutomaticallyStop(recordingApplication: nil, endedApplication: zoom))
    }

    @Test
    func appStateCoordinatesRecordingLifecycle() async {
        let recorder = FakeRecorder()
        let state = AppState(recorder: recorder)
        let zoom = MeetingApplication(bundleID: "us.zoom.xos", name: "Zoom")
        let start = Date(timeIntervalSince1970: 100)

        await state.startRecording(for: zoom, at: start)
        #expect(state.recordingState == .recording(startedAt: start))

        await state.stopRecording(ifMeetingEnded: zoom, at: start.addingTimeInterval(10))
        #expect(state.recordingState == .idle)
        #expect(recorder.stopCount == 1)
    }
}

@MainActor
private final class FakeRecorder: RecordingControlling {
    var stopCount = 0

    func start(for application: MeetingApplication?, at date: Date) async throws -> RecordingSession {
        RecordingSession(
            id: "fake",
            sourceApplication: application?.name,
            startedAt: date,
            stage: .recording
        )
    }

    func stop(at date: Date) async throws -> RecordingSession {
        stopCount += 1
        return RecordingSession(
            id: "fake",
            sourceApplication: "Zoom",
            startedAt: date.addingTimeInterval(-10),
            endedAt: date,
            stage: .pendingTranscription
        )
    }
}
