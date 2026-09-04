import Foundation
import Testing
@testable import Scribe

struct ProcessingQueueTests {
    @Test
    func transcriptMergesTracksChronologically() {
        let transcript = TranscriptRenderer.render(
            me: [
                TranscriptEntry(startTime: 0.25, speaker: .me, text: " My update "),
            ],
            others: [
                TranscriptEntry(startTime: 0, speaker: .remote(0), text: "Hello"),
                TranscriptEntry(startTime: 1.25, speaker: .remote(2), text: "Same time"),
                TranscriptEntry(startTime: 62.9, speaker: .remote(1), text: "Next topic"),
                TranscriptEntry(startTime: 70, speaker: .remote(nil), text: "  "),
            ],
            meOffset: 1,
            othersOffset: 0
        )

        #expect(
            transcript == "00:00 Speaker 1: Hello\n\n00:01 Me: My update\n\n00:01 Speaker 3: Same time\n\n01:02 Speaker 2: Next topic"
        )
    }

    @Test
    func queuePersistsSuccessAndKeepsFailureRetryable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scribe-processing-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootURL: root)
        try await store.createSession(sourceApplication: "Zoom", id: "success")
        try await store.transition("success", to: .pendingTranscription)
        try await store.createSession(sourceApplication: "Arc", id: "failure")
        try await store.transition("failure", to: .pendingTranscription)
        let transcriber = FakeTranscriber()
        let queue = ProcessingQueue(sessionStore: store) { transcriber }

        try await queue.processPendingTranscriptions()

        let sessions = try await store.allSessions()
        let successPath = try await store.sessionPaths(for: "success").transcript
        #expect(sessions.first { $0.id == "success" }?.stage == .transcribed)
        #expect(try String(contentsOf: successPath, encoding: .utf8) == "transcript")
        #expect(sessions.first { $0.id == "failure" }?.stage == .pendingTranscription)
        #expect(sessions.first { $0.id == "failure" }?.lastError == "Failed failure")
        #expect(await transcriber.unloadCount == 1)
    }
}

private actor FakeTranscriber: SessionTranscribing {
    private(set) var unloadCount = 0

    func transcribe(session: RecordingSession, paths: SessionPaths) throws -> String {
        if session.id == "failure" { throw Failure(session.id) }
        return "transcript"
    }

    func unloadModels() {
        unloadCount += 1
    }

    private struct Failure: LocalizedError {
        let id: String

        init(_ id: String) {
            self.id = id
        }

        var errorDescription: String? { "Failed \(id)" }
    }
}
