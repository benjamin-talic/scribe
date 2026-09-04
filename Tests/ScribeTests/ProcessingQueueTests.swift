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
    func echoDetectorSuppressesOnlyUncontestedRemoteAudio() {
        let sampleRate = 16_000
        let sampleCount = sampleRate * 4
        var seed: UInt64 = 0x1234_5678
        let remote = (0..<sampleCount).map { _ -> Float in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max) * 0.2
        }
        let delay = Int(0.12 * Double(sampleRate))
        let echo = (0..<sampleCount).map { index -> Float in
            guard index >= delay else { return 0 }
            let direct = remote[index - delay] * 0.35
            let reflected = index >= delay + 80 ? remote[index - delay - 80] * 0.03 : 0
            return direct + reflected
        }
        let interval = 1.0..<3.0
        let arguments = (remoteSpeech: [interval], microphoneOffset: 0.0, remoteOffset: 0.0)

        #expect(EchoDetector.isEcho(
            segment: interval,
            remoteSpeech: arguments.remoteSpeech,
            microphoneAudio: echo,
            remoteAudio: remote,
            microphoneOffset: arguments.microphoneOffset,
            remoteOffset: arguments.remoteOffset
        ))

        seed = 0x8765_4321
        let doubleTalk = echo.enumerated().map { index, sample -> Float in
            guard interval.contains(Double(index) / Double(sampleRate)) else { return sample }
            seed = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            return sample + Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max) * 0.12
        }
        #expect(!EchoDetector.isEcho(
            segment: interval,
            remoteSpeech: arguments.remoteSpeech,
            microphoneAudio: doubleTalk,
            remoteAudio: remote,
            microphoneOffset: arguments.microphoneOffset,
            remoteOffset: arguments.remoteOffset
        ))
        #expect(!EchoDetector.isEcho(
            segment: interval,
            remoteSpeech: [3.0..<4.0],
            microphoneAudio: echo,
            remoteAudio: remote,
            microphoneOffset: arguments.microphoneOffset,
            remoteOffset: arguments.remoteOffset
        ))

        let equalWindow = Array(remote[sampleRate..<(sampleRate * 3)])
        let equalScore = EchoDetector.score(microphone: equalWindow, remote: equalWindow)
        #expect(equalScore?.correlation ?? 0 > 0.99)
        #expect(equalScore?.unmatchedPowerRatio == 0)

        let rising = (0..<8_000).map { Float($0 / 80 + 1) / 100 }
        let falling = (0..<8_000).map { Float(100 - $0 / 80) / 100 }
        #expect(EchoDetector.score(microphone: falling, remote: rising)?.correlation == 0)

        let microphoneOffset = 0.2
        let offsetEcho = (0..<sampleCount).map { index -> Float in
            let source = index + Int((microphoneOffset - 0.12) * Double(sampleRate))
            return source < remote.count ? remote[source] * 0.35 : 0
        }
        #expect(EchoDetector.isEcho(
            segment: interval,
            remoteSpeech: [interval],
            microphoneAudio: offsetEcho,
            remoteAudio: remote,
            microphoneOffset: microphoneOffset,
            remoteOffset: 0
        ))
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
        try await store.createSession(sourceApplication: "Zoom", id: "notes-failure")
        try await store.transition("notes-failure", to: .pendingTranscription)
        try await store.transition("notes-failure", to: .transcribing)
        try await store.transition("notes-failure", to: .transcribed)
        try Data("transcript".utf8).write(to: await store.sessionPaths(for: "notes-failure").transcript)
        let transcriber = FakeTranscriber()
        let notesGenerator = FakeNotesGenerator()
        let queue = ProcessingQueue(
            sessionStore: store,
            loadTranscriber: { transcriber },
            loadNotesGenerator: { _ in notesGenerator }
        )

        try await queue.processPendingTranscriptions()

        let sessions = try await store.allSessions()
        let successPath = try await store.sessionPaths(for: "success").transcript
        let completed = sessions.first { $0.id == "success" }
        #expect(completed?.stage == .complete)
        #expect(try String(contentsOf: successPath, encoding: .utf8) == "transcript")
        #expect(completed?.finalNotePath != nil)
        #expect(try String(contentsOfFile: completed!.finalNotePath!, encoding: .utf8).contains("## Transcript"))
        #expect(sessions.first { $0.id == "failure" }?.stage == .pendingTranscription)
        #expect(sessions.first { $0.id == "failure" }?.lastError == "Failed failure")
        #expect(sessions.first { $0.id == "notes-failure" }?.stage == .transcribed)
        #expect(sessions.first { $0.id == "notes-failure" }?.lastError == "Failed notes-failure")
        #expect(await transcriber.unloadCount == 1)
    }

    @Test
    func notesDocumentCombinesMetadataNotesAndTranscript() throws {
        let session = RecordingSession(
            id: "meeting",
            sourceApplication: "Zoom",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_125),
            stage: .transcribed
        )

        let result = try NotesDocument.render(
            generated: "# Weekly Sync\n\n## Notes\n\nSummary and actions.",
            transcript: "00:00 Me: Hello\n\n00:02 Speaker 1: Hi",
            session: session,
            place: "Inbox"
        )

        #expect(result.title == "Weekly Sync")
        #expect(result.markdown.contains("duration_seconds: 125"))
        #expect(result.markdown.contains("## Notes\n\nSummary and actions."))
        #expect(result.markdown.contains("**00:00 Me:** Hello\n\n**00:02 Speaker 1:** Hi"))
        #expect(NotesDocument.filename(for: result.title, date: session.startedAt).hasSuffix("-Weekly-Sync.md"))
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

private struct FakeNotesGenerator: SessionNotesGenerating {
    func generate(from transcript: URL) throws -> String {
        let id = transcript.deletingLastPathComponent().lastPathComponent
        if id == "notes-failure" { throw Failure(id) }
        return "# Test Meeting\n\n## Notes\n\nGenerated notes."
    }

    private struct Failure: LocalizedError {
        let id: String
        init(_ id: String) { self.id = id }
        var errorDescription: String? { "Failed \(id)" }
    }
}
