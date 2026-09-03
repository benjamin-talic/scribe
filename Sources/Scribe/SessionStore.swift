import Foundation

struct RecordingSession: Codable, Equatable, Identifiable, Sendable {
    enum Stage: String, Codable, Sendable {
        case recording
        case pendingTranscription
        case transcribing
        case transcribed
        case generatingNotes
        case complete
    }

    let id: String
    let sourceApplication: String?
    let startedAt: Date
    var endedAt: Date?
    var transcribedAt: Date?
    var notesAt: Date?
    var stage: Stage
    var lastError: String?
}

struct SessionPaths: Sendable {
    let directory: URL

    var metadata: URL { directory.appending(path: "meta.json") }
    var meAudio: URL { directory.appending(path: "me.caf") }
    var othersAudio: URL { directory.appending(path: "others.caf") }
    var transcript: URL { directory.appending(path: "transcript.txt") }
}

struct SessionScan: Sendable {
    let sessions: [RecordingSession]
    let warnings: [String]

    var pendingTranscriptionCount: Int {
        sessions.count { $0.stage == .pendingTranscription || $0.stage == .transcribing }
    }
}

actor SessionStore {
    enum Error: LocalizedError {
        case invalidID(String)
        case invalidTransition(from: RecordingSession.Stage, to: RecordingSession.Stage)
        case missingSession(String)

        var errorDescription: String? {
            switch self {
            case let .invalidID(id): "Invalid session ID: \(id)"
            case let .invalidTransition(from, to): "Cannot transition a session from \(from.rawValue) to \(to.rawValue)."
            case let .missingSession(id): "Session \(id) does not exist."
            }
        }
    }

    private let fileManager: FileManager
    private let sessionsDirectory: URL

    init(rootURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let root = try rootURL ?? fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Scribe", directoryHint: .isDirectory)
        sessionsDirectory = root.appending(path: "sessions", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    }

    private func paths(for id: String) -> SessionPaths {
        SessionPaths(directory: sessionsDirectory.appending(path: id, directoryHint: .isDirectory))
    }

    @discardableResult
    func createSession(
        sourceApplication: String?,
        startedAt: Date = .now,
        id: String = UUID().uuidString.lowercased()
    ) throws -> RecordingSession {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw Error.invalidID(id)
        }

        let session = RecordingSession(
            id: id,
            sourceApplication: sourceApplication,
            startedAt: startedAt,
            stage: .recording
        )
        let directory = paths(for: id).directory
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try write(session)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        return session
    }

    @discardableResult
    func transition(
        _ id: String,
        to stage: RecordingSession.Stage,
        at date: Date = .now,
        error: String? = nil
    ) throws -> RecordingSession {
        var session = try load(id)
        guard canTransition(from: session.stage, to: stage) else {
            throw Error.invalidTransition(from: session.stage, to: stage)
        }
        session.stage = stage
        session.lastError = error

        switch stage {
        case .pendingTranscription:
            session.endedAt = session.endedAt ?? date
        case .transcribed:
            session.transcribedAt = date
        case .complete:
            session.notesAt = date
        case .recording, .transcribing, .generatingNotes:
            break
        }

        try write(session)
        return session
    }

    func scanSessions() throws -> SessionScan {
        let directories = try fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )
        var sessions: [RecordingSession] = []
        var warnings: [String] = []

        for directory in directories where (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
            let metadata = SessionPaths(directory: directory).metadata
            guard let data = fileManager.contents(atPath: metadata.path) else {
                let contents = try fileManager.contentsOfDirectory(atPath: directory.path)
                if contents.isEmpty {
                    try fileManager.removeItem(at: directory)
                } else {
                    warnings.append("Session \(directory.lastPathComponent) has no metadata.")
                }
                continue
            }

            do {
                sessions.append(try decode(data))
            } catch {
                warnings.append("Session \(directory.lastPathComponent) has invalid metadata: \(error.localizedDescription)")
            }
        }

        return SessionScan(
            sessions: sessions.sorted { $0.startedAt > $1.startedAt },
            warnings: warnings
        )
    }

    func allSessions() throws -> [RecordingSession] {
        try scanSessions().sessions
    }

    func pendingTranscriptionCount() throws -> Int {
        try scanSessions().pendingTranscriptionCount
    }

    func recoverInterruptedWork(at date: Date = .now) throws -> [String] {
        let scan = try scanSessions()
        var warnings = scan.warnings

        for var session in scan.sessions {
            switch session.stage {
            case .recording:
                session.stage = .pendingTranscription
                session.endedAt = date
                session.lastError = "Recording was interrupted when Scribe exited."
            case .transcribing:
                session.stage = .pendingTranscription
                session.lastError = "Transcription was interrupted when Scribe exited."
            case .generatingNotes:
                session.stage = .transcribed
                session.lastError = "Note generation was interrupted when Scribe exited."
            case .pendingTranscription, .transcribed, .complete:
                continue
            }
            do {
                try write(session)
            } catch {
                warnings.append("Could not recover session \(session.id): \(error.localizedDescription)")
            }
        }

        return warnings
    }

    private func load(_ id: String) throws -> RecordingSession {
        let url = paths(for: id).metadata
        guard let data = fileManager.contents(atPath: url.path) else {
            throw Error.missingSession(id)
        }
        return try decode(data)
    }

    private func decode(_ data: Data) throws -> RecordingSession {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingSession.self, from: data)
    }

    private func write(_ session: RecordingSession) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: paths(for: session.id).metadata, options: .atomic)
    }

    private func canTransition(from: RecordingSession.Stage, to: RecordingSession.Stage) -> Bool {
        if from == to { return true }

        return switch (from, to) {
        case (.recording, .pendingTranscription),
             (.pendingTranscription, .transcribing),
             (.transcribing, .pendingTranscription),
             (.transcribing, .transcribed),
             (.transcribed, .generatingNotes),
             (.generatingNotes, .transcribed),
             (.generatingNotes, .complete):
            true
        default:
            false
        }
    }
}
