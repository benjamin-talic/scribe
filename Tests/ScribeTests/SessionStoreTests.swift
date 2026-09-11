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

    @Test
    func placePersistsAndMoveAvoidsExistingFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "team", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let store = try SessionStore(rootURL: root)
        let place = try await store.addPlace(name: "Team", directory: destination)
        await #expect(throws: SessionStore.Error.self) {
            try await store.addPlace(name: "Team Alias", directory: destination)
        }

        try await store.createSession(sourceApplication: "Zoom", startedAt: Date(timeIntervalSince1970: 1_000), id: "meeting")
        try await store.transition("meeting", to: .pendingTranscription)
        try await store.transition("meeting", to: .transcribing)
        try await store.transition("meeting", to: .transcribed)
        try await store.transition("meeting", to: .generatingNotes)
        let noteURL = try await store.writeNotes(
            "meeting",
            generated: "# Weekly Sync\n\n## Notes\n\nSummary.",
            transcript: "00:00 Me: Hello"
        )
        try Data("existing".utf8).write(to: destination.appending(path: noteURL.lastPathComponent))

        let note = try #require(try await store.librarySnapshot().notes.first)
        try await store.moveNote(note, to: place.id)

        let reloaded = try await SessionStore(rootURL: root).librarySnapshot()
        let moved = try #require(reloaded.notes.first)
        #expect(reloaded.places == [place])
        #expect(moved.placeID == place.id)
        #expect(moved.url.lastPathComponent.hasSuffix("-2.md"))
        let movedMarkdown = try String(contentsOf: moved.url, encoding: .utf8)
        #expect(movedMarkdown.contains("place: \"Inbox\""))
        #expect(try String(contentsOf: destination.appending(path: noteURL.lastPathComponent), encoding: .utf8) == "existing")

        try await store.renamePlace(place.id, to: "Team Sync")
        let renamed = try await store.librarySnapshot()
        #expect(renamed.places.first?.name == "Team Sync")
        #expect(try String(contentsOf: moved.url, encoding: .utf8) == movedMarkdown)
    }

    @Test
    func interruptedNotesNeverAdoptOrOverwriteAnotherFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootURL: root)
        try await store.createSession(sourceApplication: "Zoom", id: "meeting")
        try await store.transition("meeting", to: .pendingTranscription)
        try await store.transition("meeting", to: .transcribing)
        try await store.transition("meeting", to: .transcribed)
        try await store.transition("meeting", to: .generatingNotes)

        let paths = try await store.sessionPaths(for: "meeting")
        let unrelated = root.appending(path: "inbox/reserved.md")
        try Data("unrelated".utf8).write(to: unrelated)
        var session = try #require(try await store.allSessions().first)
        session.finalNotePath = unrelated.path
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: paths.metadata, options: .atomic)

        _ = try await store.recoverInterruptedWork()
        let recovered = try #require(try await store.allSessions().first)
        #expect(recovered.stage == .transcribed)
        try await store.transition("meeting", to: .generatingNotes)
        let written = try await store.writeNotes(
            "meeting",
            generated: "# Safe Note\n\n## Notes\n\nSummary.",
            transcript: "00:00 Me: Hello"
        )

        #expect(written != unrelated)
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "unrelated")
    }

    @Test
    func expiredAudioCleanupKeepsOnlyDurableRecordsAndRetryState() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootURL: root)
        let old = Date(timeIntervalSince1970: 1_000)
        let cleanupDate = old.addingTimeInterval(6 * 24 * 60 * 60)

        for id in ["complete", "embedded", "retry", "recent"] {
            try await store.createSession(sourceApplication: "Zoom", startedAt: old, id: id)
            try await store.transition(id, to: .pendingTranscription)
            try await store.transition(id, to: .transcribing)
            try await store.transition(
                id,
                to: .transcribed,
                at: id == "recent" ? cleanupDate.addingTimeInterval(-5 * 24 * 60 * 60) : old
            )
            let paths = try await store.sessionPaths(for: id)
            try Data("audio".utf8).write(to: paths.meAudio)
            try Data("audio".utf8).write(to: paths.othersAudio)
            try Data("transcript".utf8).write(to: paths.transcript)
        }
        try await store.transition("complete", to: .generatingNotes)
        let note = try await store.writeNotes(
            "complete",
            generated: "# Complete\n\n## Notes\n\nSummary.",
            transcript: "00:00 Me: Hello",
            at: old
        )
        try await store.transition("embedded", to: .generatingNotes)
        let embeddedPublished = try await store.writeNotes(
            "embedded",
            generated: "# Embedded\n\n## Notes\n\nSummary.",
            transcript: "00:00 Me: Hello",
            at: old
        )
        let embeddedPaths = try await store.sessionPaths(for: "embedded")
        let embeddedNote = embeddedPaths.directory.appending(path: embeddedPublished.lastPathComponent)
        try FileManager.default.moveItem(at: embeddedPublished, to: embeddedNote)
        var embeddedSession = try #require(try await store.allSessions().first { $0.id == "embedded" })
        embeddedSession.finalNotePath = embeddedNote.path
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(embeddedSession).write(to: embeddedPaths.metadata, options: .atomic)

        await #expect(throws: SessionStore.Error.self) {
            try await store.addPlace(name: "Internal", directory: embeddedPaths.directory)
        }

        #expect(try await store.cleanupExpiredAudio(at: cleanupDate).isEmpty)

        #expect(FileManager.default.fileExists(atPath: note.path))
        await #expect(throws: SessionStore.Error.self) { try await store.sessionPaths(for: "complete") }
        let retryPaths = try await store.sessionPaths(for: "retry")
        #expect(FileManager.default.fileExists(atPath: retryPaths.metadata.path))
        #expect(FileManager.default.fileExists(atPath: retryPaths.transcript.path))
        #expect(!FileManager.default.fileExists(atPath: retryPaths.meAudio.path))
        #expect(!FileManager.default.fileExists(atPath: retryPaths.othersAudio.path))
        #expect(FileManager.default.fileExists(atPath: embeddedNote.path))
        #expect(!FileManager.default.fileExists(atPath: embeddedPaths.meAudio.path))
        #expect(!FileManager.default.fileExists(atPath: embeddedPaths.othersAudio.path))
        let recentPaths = try await store.sessionPaths(for: "recent")
        #expect(FileManager.default.fileExists(atPath: recentPaths.meAudio.path))
        #expect(FileManager.default.fileExists(atPath: recentPaths.othersAudio.path))
    }

    @Test(arguments: [false, true])
    func trashRemovesNoteAndSessionWithoutRegenerating(inPlace: Bool) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootURL: root)
        try await store.createSession(sourceApplication: "Zoom", id: "delete-me")
        for stage in [RecordingSession.Stage.pendingTranscription, .transcribing, .transcribed, .generatingNotes] {
            try await store.transition("delete-me", to: stage)
        }
        try await store.writeNotes("delete-me", generated: "# Disposable\n\n## Notes\n\nSummary.", transcript: "Hello")
        let paths = try await store.sessionPaths(for: "delete-me")
        try Data("audio".utf8).write(to: paths.meAudio)
        var note = try #require(try await store.librarySnapshot().notes.first)
        if inPlace {
            let directory = root.appending(path: "place", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let place = try await store.addPlace(name: "Team", directory: directory)
            try await store.moveNote(note, to: place.id)
            note = try #require(try await store.librarySnapshot().notes.first)
        }

        let trashed = try await store.trashNote(note)
        defer { for url in trashed { try? FileManager.default.removeItem(at: url) } }
        #expect(trashed.count == 2)
        #expect(trashed.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(!FileManager.default.fileExists(atPath: note.url.path))
        #expect(!FileManager.default.fileExists(atPath: paths.directory.path))
        let reloaded = try SessionStore(rootURL: root)
        #expect(try await reloaded.recoverInterruptedWork().isEmpty)
        #expect(try await reloaded.allSessions().isEmpty)
        #expect(try await reloaded.librarySnapshot().notes.isEmpty)
    }

    @Test
    func trashWorksAfterRetentionAndRejectsReplacedNotes() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootURL: root)
        let url = root.appending(path: "inbox/old.md")
        let markdown = "---\nscribe_id: old\n---\n# Old note\n"
        try Data(markdown.utf8).write(to: url)
        let note = try #require(try await store.librarySnapshot().notes.first)

        try Data("unrelated file".utf8).write(to: url)
        await #expect(throws: SessionStore.Error.self) { try await store.trashNote(note) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "unrelated file")

        try Data(markdown.utf8).write(to: url)
        let outside = root.appending(path: "outside.md")
        try FileManager.default.moveItem(at: url, to: outside)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        await #expect(throws: SessionStore.Error.self) { try await store.trashNote(note) }
        let unmanaged = MeetingNote(url: outside, scribeID: note.scribeID, title: note.title, date: note.date, placeID: nil)
        await #expect(throws: SessionStore.Error.self) { try await store.trashNote(unmanaged) }
        #expect(FileManager.default.fileExists(atPath: outside.path))

        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: outside, to: url)
        let trashed = try await store.trashNote(note)
        defer { for url in trashed { try? FileManager.default.removeItem(at: url) } }
        #expect(trashed.count == 1)
        #expect(try await store.librarySnapshot().notes.isEmpty)
    }

    @Test
    func notesClientDefaultsToClaudeAndPreservesSavedChoice() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootURL: root)
        #expect(try await store.notesClient() == .claude)
        try Data(#"{"notesClient":"openCode","places":[]}"#.utf8).write(to: root.appending(path: "settings.json"))
        #expect(try await SessionStore(rootURL: root).notesClient() == .openCode)
        try await store.setNotesClient(.pi)
        #expect(try await SessionStore(rootURL: root).notesClient() == .pi)
        try await store.setNotesClient(.claude)
        #expect(try await SessionStore(rootURL: root).notesClient() == .claude)
    }

    @Test(arguments: [nil, "invalid metadata"] as [String?])
    func trashWorksWithUnreadableSessionMetadata(metadata: String?) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootURL: root)
        let directory = root.appending(path: "sessions/orphan")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let metadata {
            try Data(metadata.utf8).write(to: directory.appending(path: "meta.json"))
        }
        try Data("remaining audio".utf8).write(to: directory.appending(path: "me.caf"))
        try Data("---\nscribe_id: orphan\n---\n# Old note\n".utf8).write(to: root.appending(path: "inbox/orphan.md"))
        let note = try #require(try await store.librarySnapshot().notes.first)

        let trashed = try await store.trashNote(note)
        defer { for url in trashed { try? FileManager.default.removeItem(at: url) } }
        #expect(trashed.count == 1)
        #expect(try await store.librarySnapshot().notes.isEmpty)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "me.caf").path))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "scribe-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
