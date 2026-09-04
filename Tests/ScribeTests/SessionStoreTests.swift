import Foundation
import Testing
@testable import Scribe

struct SessionStoreTests {
    @Test
    func finishedRecordingSurvivesStoreReload() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootURL: root)
        let start = Date(timeIntervalSince1970: 1_000)
        let session = try await store.createSession(sourceApplication: "Zoom", startedAt: start, id: "meeting")
        try await store.transition(session.id, to: .pendingTranscription, at: start.addingTimeInterval(60))

        let reloadedStore = try SessionStore(rootURL: root)
        let sessions = try await reloadedStore.allSessions()

        #expect(sessions.count == 1)
        #expect(sessions[0].stage == .pendingTranscription)
        #expect(sessions[0].endedAt == start.addingTimeInterval(60))
        #expect(try await reloadedStore.pendingTranscriptionCount() == 1)
    }

    @Test
    func interruptedStagesReturnToRetryableWork() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootURL: root)
        let now = Date(timeIntervalSince1970: 2_000)
        try await store.createSession(sourceApplication: "Arc", id: "recording")
        try await store.createSession(sourceApplication: "Zoom", id: "transcribing")
        try await store.transition("transcribing", to: .pendingTranscription)
        try await store.transition("transcribing", to: .transcribing)
        try await store.createSession(sourceApplication: "Zoom", id: "notes")
        try await store.transition("notes", to: .pendingTranscription)
        try await store.transition("notes", to: .transcribing)
        try await store.transition("notes", to: .transcribed)
        try await store.transition("notes", to: .generatingNotes)
        try await store.createSession(sourceApplication: "Zoom", id: "complete")
        try await store.transition("complete", to: .pendingTranscription)
        try await store.transition("complete", to: .transcribing)
        try await store.transition("complete", to: .transcribed)
        try await store.transition("complete", to: .generatingNotes)
        try await store.transition("complete", to: .complete)

        _ = try await store.recoverInterruptedWork(at: now)
        _ = try await store.recoverInterruptedWork(at: now.addingTimeInterval(1))

        let sessions = try await store.allSessions()
        #expect(sessions.first { $0.id == "recording" }?.stage == .pendingTranscription)
        #expect(sessions.first { $0.id == "recording" }?.endedAt == now)
        #expect(sessions.first { $0.id == "transcribing" }?.stage == .pendingTranscription)
        #expect(sessions.first { $0.id == "notes" }?.stage == .transcribed)
        #expect(sessions.first { $0.id == "complete" }?.stage == .complete)
        #expect(try await store.pendingTranscriptionCount() == 2)
    }

    @Test
    func corruptMetadataDoesNotHideHealthySessions() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootURL: root)
        try await store.createSession(sourceApplication: "Zoom", id: "healthy")
        try await store.transition("healthy", to: .pendingTranscription)
        let broken = root.appending(path: "sessions/broken", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: broken.appending(path: "meta.json"))

        let scan = try await store.scanSessions()

        #expect(scan.sessions.map(\.id) == ["healthy"])
        #expect(scan.pendingTranscriptionCount == 1)
        #expect(scan.warnings.count == 1)
    }

    @Test
    func rejectsInvalidIDsAndStageJumps() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootURL: root)
        await #expect(throws: SessionStore.Error.self) {
            try await store.createSession(sourceApplication: nil, id: "../escape")
        }

        try await store.createSession(sourceApplication: nil, id: "valid")
        await #expect(throws: SessionStore.Error.self) {
            try await store.transition("valid", to: .complete)
        }
        #expect(try await store.allSessions().map(\.id) == ["valid"])
    }

    @Test
    func finishingRecordingPersistsTrackOffsets() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootURL: root)
        try await store.createSession(sourceApplication: "Zoom", id: "timed")

        let session = try await store.finishRecording(
            "timed",
            at: Date(timeIntervalSince1970: 100),
            meStartHostTime: 123,
            othersStartHostTime: 456
        )

        #expect(session.stage == .pendingTranscription)
        #expect(session.meStartHostTime == 123)
        #expect(session.othersStartHostTime == 456)
        #expect(try await SessionStore(rootURL: root).allSessions() == [session])
    }

    @Test
    func discardingFailedStartRemovesItsSessionDirectory() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootURL: root)
        try await store.createSession(sourceApplication: nil, id: "failed")
        let directory = try await store.sessionPaths(for: "failed").directory

        try await store.discardRecording("failed")

        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try await store.allSessions().isEmpty)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "scribe-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
