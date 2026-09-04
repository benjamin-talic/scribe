import Darwin
import Foundation

enum NotesClient: String, CaseIterable, Codable, Identifiable, Sendable {
    case openCode
    case pi

    var id: Self { self }

    var name: String {
        switch self {
        case .openCode: "OpenCode"
        case .pi: "Pi"
        }
    }
}

protocol SessionNotesGenerating: Sendable {
    func generate(from transcript: URL) async throws -> String
}

struct CLINotesGenerator: SessionNotesGenerating, Sendable {
    enum Error: LocalizedError {
        case executableMissing(String)
        case failed(String, Int32, String)
        case emptyOutput(String)
        case outputTooLarge(String)
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case let .executableMissing(name):
                "The \(name) CLI is not installed."
            case let .failed(name, status, message):
                "\(name) failed with status \(status): \(message)"
            case let .emptyOutput(name):
                "\(name) returned no notes."
            case let .outputTooLarge(name):
                "\(name) produced more than 5 MB of output."
            case let .timedOut(name):
                "\(name) did not finish within five minutes."
            }
        }
    }

    private static let model = "openai/gpt-5.6-terra"
    private static let prompt = """
        Create concise meeting notes from the attached transcript. Return only Markdown with a short descriptive H1 title followed by an H2 named Notes. Include a summary, key points, decisions, and action items when present. Do not repeat the transcript.
        """

    let client: NotesClient

    func generate(from transcript: URL) async throws -> String {
        try await Task.detached {
            try Self.run(client: client, transcript: transcript)
        }.value
    }

    private static func run(client: NotesClient, transcript: URL) throws -> String {
        let executable = try executableURL(for: client)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "scribe-notes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appending(path: "stdout")
        let errorURL = temporaryDirectory.appending(path: "stderr")
        try Data().write(to: outputURL)
        try Data().write(to: errorURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? errors.close()
        }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        process.arguments = switch client {
        case .openCode:
            ["run", prompt, "--pure", "--agent", "scribe", "--model", model, "--file", transcript.path]
        case .pi:
            [
                "--print", "--no-session", "--no-tools", "--no-extensions", "--no-skills",
                "--no-context-files", "--no-approve", "--model", model, "@\(transcript.path)", prompt,
            ]
        }
        if client == .openCode {
            var environment = ProcessInfo.processInfo.environment
            environment["PWD"] = temporaryDirectory.path
            environment["XDG_CONFIG_HOME"] = temporaryDirectory.path
            environment["OPENCODE_CONFIG_DIR"] = temporaryDirectory.path
            environment.removeValue(forKey: "OPENCODE_CONFIG")
            environment.removeValue(forKey: "OPENCODE_AUTO_SHARE")
            environment["OPENCODE_DISABLE_CLAUDE_CODE"] = "true"
            environment["OPENCODE_DISABLE_CLAUDE_CODE_PROMPT"] = "true"
            environment["OPENCODE_CONFIG_CONTENT"] = #"{"share":"disabled","agent":{"scribe":{"mode":"primary","permission":"deny"}}}"#
            process.environment = environment
        }
        try process.run()
        let deadline = Date().addingTimeInterval(300)
        var processError: Error?
        while process.isRunning && processError == nil {
            Thread.sleep(forTimeInterval: 0.1)
            let size = [outputURL, errorURL].reduce(Int64(0)) { total, url in
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
            }
            if size > 5 * 1_024 * 1_024 {
                processError = .outputTooLarge(client.name)
            } else if Date() >= deadline {
                processError = .timedOut(client.name)
            }
        }
        if let processError {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw processError
        }
        process.waitUntilExit()
        try output.synchronize()
        try errors.synchronize()

        let outputText = try String(contentsOf: outputURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let errorText = try String(contentsOf: errorURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Error.failed(client.name, process.terminationStatus, errorText.isEmpty ? "No details provided." : errorText)
        }
        guard !outputText.isEmpty else { throw Error.emptyOutput(client.name) }
        return outputText
    }

    private static func executableURL(for client: NotesClient) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = switch client {
        case .openCode:
            [home.appending(path: ".opencode/bin/opencode")]
        case .pi:
            [home.appending(path: ".local/bin/pi")]
        }
        let executableName = client == .openCode ? "opencode" : "pi"
        candidates += ["/opt/homebrew/bin", "/usr/local/bin"].map {
            URL(filePath: $0).appending(path: executableName)
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map {
                URL(filePath: String($0)).appending(path: executableName)
            }
        }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw Error.executableMissing(client.name)
        }
        return executable
    }
}

struct RenderedNotes: Equatable, Sendable {
    let title: String
    let markdown: String
}

enum NotesDocument {
    enum Error: LocalizedError {
        case missingTitle
        case missingNotes

        var errorDescription: String? {
            switch self {
            case .missingTitle: "The notes client did not return one H1 title."
            case .missingNotes: "The notes client did not return a non-empty Notes section."
            }
        }
    }

    static func render(generated: String, transcript: String, session: RecordingSession, place: String) throws -> RenderedNotes {
        var lines = generated.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        if let openingFence = lines.firstIndex(where: { $0.hasPrefix("```") }),
           let closingFence = lines.lastIndex(of: "```"), openingFence < closingFence,
           lines[openingFence..<closingFence].contains(where: { $0.hasPrefix("# ") }) {
            lines.remove(at: closingFence)
            lines.remove(at: openingFence)
        }
        let titleIndices = lines.indices.filter { lines[$0].hasPrefix("# ") }
        guard titleIndices.count == 1, let titleIndex = titleIndices.first else { throw Error.missingTitle }
        let title = String(lines[titleIndex].dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { throw Error.missingTitle }
        guard let notesIndex = lines[(titleIndex + 1)...].firstIndex(of: "## Notes") else { throw Error.missingNotes }
        let notesBody = lines.dropFirst(notesIndex + 1).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notesBody.isEmpty else { throw Error.missingNotes }
        let source = yamlString(session.sourceApplication ?? "Manual")
        let duration = max(0, Int((session.endedAt ?? session.startedAt).timeIntervalSince(session.startedAt)))
        let markdown = """
            ---
            scribe_id: \(session.id)
            date: \(ISO8601DateFormatter().string(from: session.startedAt))
            source_app: \(source)
            duration_seconds: \(duration)
            place: \(yamlString(place))
            ---

            # \(title)

            ## Notes

            \(notesBody)

            ## Transcript

            \(markdownTranscript(transcript))
            """
        return RenderedNotes(title: title, markdown: markdown + "\n")
    }

    static func filename(for title: String, date: Date) -> String {
        let day = ISO8601DateFormatter().string(from: date).prefix(10)
        let slug = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
        return "\(day)-\(slug.isEmpty ? "Meeting" : slug).md"
    }

    private static func markdownTranscript(_ transcript: String) -> String {
        transcript.components(separatedBy: "\n\n").map { paragraph in
            guard let separator = paragraph.range(of: ": ") else { return paragraph }
            return "**\(paragraph[..<separator.lowerBound]):** \(paragraph[separator.upperBound...])"
        }.joined(separator: "\n\n")
    }

    private static func yamlString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
