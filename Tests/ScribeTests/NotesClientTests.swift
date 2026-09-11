import Foundation
import Testing
@testable import Scribe

struct NotesClientTests {
    @Test
    func claudeReceivesLongTranscriptOnStdinAndRunsSonnetWithoutTools() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "scribe-cli-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "claude")
        let transcript = root.appending(path: "transcript.txt")
        // Longer than macOS's argument limit: transcripts must be streamed through stdin.
        try Data(String(repeating: "00:01 Me: Meeting update.\n", count: 20_000).utf8).write(to: transcript)
        let script = #"""
            #!/bin/zsh
            set -eu
            [[ "$*" == *"--model sonnet"* && "$*" == *"--safe-mode"* && "$*" == *"--no-session-persistence"* ]]
            [[ "$*" == *"--strict-mcp-config"* && "$*" == *"--output-format text"* ]]
            while (( $# )); do
                if [[ "$1" == "--tools" ]]; then
                    [[ "$2" == "" ]] || exit 2
                fi
                shift
            done
            input=$(</dev/stdin)
            [[ ${#input} -gt 262144 && "$input" == *"Meeting update."* ]]
            print '# Meeting summary\n\n## Notes\n\nThe team shared updates.'
            """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let output = try await CLINotesGenerator(client: .claude, executable: executable).generate(from: transcript)
        #expect(output == "# Meeting summary\n\n## Notes\n\nThe team shared updates.")

        try Data("#!/bin/zsh\nprint -u2 'Login required'\nexit 1\n".utf8).write(to: executable)
        do {
            _ = try await CLINotesGenerator(client: .claude, executable: executable).generate(from: transcript)
            Issue.record("Expected the CLI failure to be reported")
        } catch {
            #expect(error.localizedDescription.contains("Login required"))
        }
    }
}
