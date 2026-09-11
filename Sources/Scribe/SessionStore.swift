import Darwin
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
    var meStartHostTime: UInt64?
    var othersStartHostTime: UInt64?
    var finalNotePath: String?
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

struct Place: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let directory: URL
}

struct MeetingNote: Hashable, Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let scribeID: String
    let title: String
    let date: Date
    let placeID: UUID?
}

struct LibrarySnapshot: Sendable {
    let notesClient: NotesClient
    let places: [Place]
    let notes: [MeetingNote]
    let warnings: [String]
}

private struct ScribeSettings: Codable {
    var notesClient: NotesClient = .claude
    var places: [Place] = []
}

private struct NoteScan {
    var notes: [MeetingNote] = []
    var warnings: [String] = []
}

actor SessionStore {
    enum Error: LocalizedError {
        case invalidID(String)
        case invalidPlaceName
        case invalidPlaceDirectory
        case invalidTransition(from: RecordingSession.Stage, to: RecordingSession.Stage)
        case placeAlreadyExists(String)
        case placeNotFound
        case missingSession(String)
        case unmanagedNote

        var errorDescription: String? {
            switch self {
            case let .invalidID(id): "Invalid session ID: \(id)"
            case .invalidPlaceName: "Place names cannot be empty or contain line breaks."
            case .invalidPlaceDirectory: "The selected place must be a unique, accessible folder."
            case let .invalidTransition(from, to): "Cannot transition a session from \(from.rawValue) to \(to.rawValue)."
            case let .placeAlreadyExists(name): "A place named \(name) already exists."
            case .placeNotFound: "The selected place no longer exists."
            case let .missingSession(id): "Session \(id) does not exist."
            case .unmanagedNote: "The selected note is not in the Scribe library."
            }
        }
    }

    private let fileManager: FileManager
    private let sessionsDirectory: URL
    private let inboxDirectory: URL
    private let settingsFile: URL

    init(rootURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let root = try rootURL ?? fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Scribe", directoryHint: .isDirectory)
        sessionsDirectory = root.appending(path: "sessions", directoryHint: .isDirectory)
        inboxDirectory = root.appending(path: "inbox", directoryHint: .isDirectory)
        settingsFile = root.appending(path: "settings.json")
        try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
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
        guard isValidID(id) else {
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

    func sessionPaths(for id: String) throws -> SessionPaths {
        guard isValidID(id) else {
            throw Error.invalidID(id)
        }
        guard fileManager.fileExists(atPath: paths(for: id).directory.path) else {
            throw Error.missingSession(id)
        }
        return paths(for: id)
    }

    func discardRecording(_ id: String) throws {
        let session = try load(id)
        guard session.stage == .recording else {
            throw Error.invalidTransition(from: session.stage, to: .recording)
        }
        try fileManager.removeItem(at: paths(for: id).directory)
    }

    @discardableResult
    func finishRecording(
        _ id: String,
        at date: Date = .now,
        meStartHostTime: UInt64?,
        othersStartHostTime: UInt64?,
        error: String? = nil
    ) throws -> RecordingSession {
        var session = try load(id)
        guard session.stage == .recording else {
            throw Error.invalidTransition(from: session.stage, to: .pendingTranscription)
        }
        session.endedAt = date
        session.meStartHostTime = meStartHostTime
        session.othersStartHostTime = othersStartHostTime
        session.stage = .pendingTranscription
        session.lastError = error
        try write(session)
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
            session.transcribedAt = session.transcribedAt ?? date
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
                let session = try decode(data)
                guard isValidID(session.id), session.id == directory.lastPathComponent else {
                    warnings.append("Session \(directory.lastPathComponent) has mismatched metadata.")
                    continue
                }
                sessions.append(session)
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

    func librarySnapshot() throws -> LibrarySnapshot {
        let settings = try loadSettings()
        var scan = meetingNotes(in: inboxDirectory, placeID: nil)
        for place in settings.places {
            let placeScan = meetingNotes(in: place.directory, placeID: place.id)
            scan.notes += placeScan.notes
            scan.warnings += placeScan.warnings
        }
        return LibrarySnapshot(
            notesClient: settings.notesClient,
            places: settings.places.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            notes: scan.notes.sorted { $0.date > $1.date },
            warnings: scan.warnings
        )
    }

    func setNotesClient(_ client: NotesClient) throws {
        var settings = try loadSettings()
        settings.notesClient = client
        try write(settings)
    }

    func notesClient() throws -> NotesClient {
        try loadSettings().notesClient
    }

    @discardableResult
    func addPlace(name: String, directory: URL) throws -> Place {
        var settings = try loadSettings()
        let name = try validPlaceName(name)
        guard !settings.places.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw Error.placeAlreadyExists(name)
        }
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        let managedDirectories = [inboxDirectory] + settings.places.map(\.directory)
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fileManager.isWritableFile(atPath: directory.path),
              !isWithin(directory, directory: sessionsDirectory),
              !managedDirectories.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == directory }) else {
            throw Error.invalidPlaceDirectory
        }
        let place = Place(id: UUID(), name: name, directory: directory)
        settings.places.append(place)
        try write(settings)
        return place
    }

    func renamePlace(_ id: UUID, to name: String) throws {
        var settings = try loadSettings()
        let name = try validPlaceName(name)
        guard let index = settings.places.firstIndex(where: { $0.id == id }) else { throw Error.placeNotFound }
        guard !settings.places.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw Error.placeAlreadyExists(name)
        }
        settings.places[index].name = name
        try write(settings)
    }

    func removePlace(_ id: UUID) throws {
        var settings = try loadSettings()
        guard settings.places.contains(where: { $0.id == id }) else { throw Error.placeNotFound }
        settings.places.removeAll { $0.id == id }
        try write(settings)
    }

    func moveNote(_ note: MeetingNote, to placeID: UUID?) throws {
        let settings = try loadSettings()
        try validateNote(note, settings: settings)

        let place = try placeID.map { id in
            guard let place = settings.places.first(where: { $0.id == id }) else { throw Error.placeNotFound }
            return place
        }
        let destinationDirectory = place?.directory ?? inboxDirectory
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destinationDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue, fileManager.isWritableFile(atPath: destinationDirectory.path) else {
            throw Error.invalidPlaceDirectory
        }
        let destination = availableURL(in: destinationDirectory, filename: note.url.lastPathComponent)
        var moved = false
        do {
            try fileManager.moveItem(at: note.url, to: destination)
            moved = true
            guard isOwnedNote(destination, sessionID: note.scribeID) else { throw Error.unmanagedNote }
            if var session = try? load(note.scribeID) {
                session.finalNotePath = destination.path
                try write(session)
            }
        } catch {
            if moved { try? fileManager.moveItem(at: destination, to: note.url) }
            throw error
        }
    }

    @discardableResult
    func trashNote(_ note: MeetingNote) throws -> [URL] {
        try validateNote(note, settings: loadSettings())
        var sessionDirectory: URL?
        if let session = try? load(note.scribeID) {
            guard session.stage == .complete else {
                throw Error.invalidTransition(from: session.stage, to: .complete)
            }
            if session.finalNotePath.map({ URL(filePath: $0).standardizedFileURL }) == note.url.standardizedFileURL {
                sessionDirectory = paths(for: session.id).directory
            }
        }

        var trashedNote: NSURL?
        try fileManager.trashItem(at: note.url, resultingItemURL: &trashedNote)
        var trashedItems = trashedNote.map { [$0 as URL] } ?? []
        if let sessionDirectory {
            do {
                var trashedSession: NSURL?
                try fileManager.trashItem(at: sessionDirectory, resultingItemURL: &trashedSession)
                if let trashedSession { trashedItems.append(trashedSession as URL) }
            } catch {
                if let trashedNote { try fileManager.moveItem(at: trashedNote as URL, to: note.url) }
                throw error
            }
        }
        return trashedItems
    }

    private func validateNote(_ note: MeetingNote, settings: ScribeSettings) throws {
        let managedDirectories = [inboxDirectory] + settings.places.map(\.directory)
        let sourceDirectory = note.url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard managedDirectories.contains(where: {
            $0.standardizedFileURL.resolvingSymlinksInPath() == sourceDirectory
        }), isOwnedNote(note.url, sessionID: note.scribeID) else { throw Error.unmanagedNote }
    }

    @discardableResult
    func writeNotes(_ id: String, generated: String, transcript: String, at date: Date = .now) throws -> URL {
        var session = try load(id)
        guard session.stage == .generatingNotes else {
            throw Error.invalidTransition(from: session.stage, to: .complete)
        }
        let rendered = try NotesDocument.render(generated: generated, transcript: transcript, session: session, place: "Inbox")
        let destination: URL
        if let existing = meetingNotes(in: inboxDirectory, placeID: nil).notes
            .first(where: { $0.scribeID == session.id })?.url {
            destination = existing
        } else {
            destination = try publishNote(
                Data(rendered.markdown.utf8),
                in: inboxDirectory,
                filename: NotesDocument.filename(for: rendered.title, date: session.startedAt)
            )
        }
        session.finalNotePath = destination.path
        session.stage = .complete
        session.notesAt = date
        session.lastError = nil
        try write(session)
        return destination
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
                let recordedURL = session.finalNotePath.map { URL(filePath: $0) }
                let recoveredURL = if let recordedURL,
                                      isInboxURL(recordedURL),
                                      isOwnedNote(recordedURL, sessionID: session.id) {
                    recordedURL
                } else {
                    meetingNotes(in: inboxDirectory, placeID: nil).notes
                        .first(where: { $0.scribeID == session.id })?.url
                }
                if let recoveredURL {
                    session.finalNotePath = recoveredURL.path
                    session.stage = .complete
                    session.notesAt = date
                    session.lastError = nil
                } else {
                    session.stage = .transcribed
                    session.lastError = "Note generation was interrupted when Scribe exited."
                }
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

    func cleanupExpiredAudio(at date: Date = .now) throws -> [String] {
        let cutoff = date.addingTimeInterval(-5 * 24 * 60 * 60)
        var warnings: [String] = []

        for session in try scanSessions().sessions where session.transcribedAt.map({ $0 < cutoff }) == true {
            let sessionPaths = paths(for: session.id)
            do {
                if session.stage == .complete,
                   let notePath = session.finalNotePath,
                   isOwnedNote(URL(filePath: notePath), sessionID: session.id),
                   !isWithin(URL(filePath: notePath), directory: sessionPaths.directory) {
                    try fileManager.removeItem(at: sessionPaths.directory)
                } else {
                    for audio in [sessionPaths.meAudio, sessionPaths.othersAudio]
                    where fileManager.fileExists(atPath: audio.path) {
                        try fileManager.removeItem(at: audio)
                    }
                }
            } catch {
                warnings.append("Could not clean up session \(session.id): \(error.localizedDescription)")
            }
        }

        return warnings
    }

    private func load(_ id: String) throws -> RecordingSession {
        guard isValidID(id) else { throw Error.invalidID(id) }
        let url = paths(for: id).metadata
        guard let data = fileManager.contents(atPath: url.path) else {
            throw Error.missingSession(id)
        }
        let session = try decode(data)
        guard session.id == id else { throw Error.invalidID(session.id) }
        return session
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

    private func loadSettings() throws -> ScribeSettings {
        guard let data = fileManager.contents(atPath: settingsFile.path) else { return ScribeSettings() }
        return try JSONDecoder().decode(ScribeSettings.self, from: data)
    }

    private func write(_ settings: ScribeSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: settingsFile, options: .atomic)
    }

    private func meetingNotes(in directory: URL, placeID: UUID?) -> NoteScan {
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: .skipsHiddenFiles
            )
        } catch {
            return NoteScan(warnings: ["Could not read \(directory.path): \(error.localizedDescription)"])
        }

        var scan = NoteScan()
        for url in files where url.pathExtension.lowercased() == "md" {
            do {
                let values = try url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let markdown = try String(contentsOf: url, encoding: .utf8)
                guard let scribeID = frontmatterValue("scribe_id", in: markdown) else { continue }
                let title = markdown.components(separatedBy: .newlines)
                    .first(where: { $0.hasPrefix("# ") })
                    .map { String($0.dropFirst(2)) } ?? url.deletingPathExtension().lastPathComponent
                let date = frontmatterValue("date", in: markdown)
                    .flatMap { ISO8601DateFormatter().date(from: $0) } ?? values.contentModificationDate ?? .distantPast
                scan.notes.append(
                    MeetingNote(url: url, scribeID: scribeID, title: title, date: date, placeID: placeID)
                )
            } catch {
                scan.warnings.append("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return scan
    }

    private func availableURL(in directory: URL, filename: String) -> URL {
        let requested = directory.appending(path: filename)
        guard pathExists(requested) else { return requested }
        let stem = requested.deletingPathExtension().lastPathComponent
        let pathExtension = requested.pathExtension
        var suffix = 2
        while true {
            let candidate = directory.appending(path: "\(stem)-\(suffix)").appendingPathExtension(pathExtension)
            if !pathExists(candidate) { return candidate }
            suffix += 1
        }
    }

    private func publishNote(_ data: Data, in directory: URL, filename: String) throws -> URL {
        let temporary = directory.appending(path: ".scribe-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        defer { try? fileManager.removeItem(at: temporary) }
        let requested = directory.appending(path: filename)
        let stem = requested.deletingPathExtension().lastPathComponent
        let pathExtension = requested.pathExtension
        var suffix = 1
        while true {
            let candidate = suffix == 1
                ? requested
                : directory.appending(path: "\(stem)-\(suffix)").appendingPathExtension(pathExtension)
            if link(temporary.path, candidate.path) == 0 { return candidate }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            suffix += 1
        }
    }

    private func pathExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func validPlaceName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(where: \.isNewline) else { throw Error.invalidPlaceName }
        return name
    }

    private func frontmatterValue(_ key: String, in markdown: String) -> String? {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        let prefix = "\(key):"
        guard let line = lines[1..<end].first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private func isInboxURL(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            == inboxDirectory.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func isWithin(_ url: URL, directory: URL) -> Bool {
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private func isOwnedNote(_ url: URL, sessionID: String) -> Bool {
        // URL resource values can be cached across a file replacement; recheck the actual directory entry.
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let markdown = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return frontmatterValue("scribe_id", in: markdown) == sessionID
    }

    private func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
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
