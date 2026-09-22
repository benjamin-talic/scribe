import Foundation
import Testing
import os
@testable import Scribe

/// Opt-in, real-model comparison of the old per-operation load+decode+unload path against the
/// actual production dictation path — real `AppState` + real `DictationController` + real
/// `DictationModelCache` (default WhisperKit "small" loader) — with only capture, microphone
/// permission/UID, and the clipboard faked. Off by default: `swift test` never runs this unless
/// `SCRIBE_DICTATION_BENCHMARK=1` is set, since it downloads/runs a real model and can take a
/// couple of minutes.
///
/// Usage:
///   1. Generate (or supply your own) a synthetic speech fixture and note what it actually says.
///      macOS `say` never touches a real microphone or plays audio out loud:
///        say -o fixture.aiff "The quick brown fox jumps over the lazy dog."
///        afconvert fixture.aiff fixture.caf -d LEI16@16000 -c 1
///        afinfo fixture.caf   # note the duration for SCRIBE_DICTATION_BENCHMARK_LEAD_SECONDS
///   2. Run it:
///        SCRIBE_DICTATION_BENCHMARK=1 \
///        SCRIBE_DICTATION_BENCHMARK_FIXTURE=/tmp/fixture.caf \
///        SCRIBE_DICTATION_BENCHMARK_LEAD_SECONDS=13.159 \
///        SCRIBE_DICTATION_BENCHMARK_SAMPLES=5 \
///        SCRIBE_DICTATION_BENCHMARK_REFERENCE_TEXT="The quick brown fox jumps over the lazy dog." \
///        swift test --filter DictationBenchmark
///      `SCRIBE_DICTATION_BENCHMARK_SAMPLES` (default 5) and `_LEAD_SECONDS` (default 13.159, the
///      known duration of the fixture this benchmark was developed against) are both optional.
///      `_REFERENCE_TEXT` is optional too — without it, recognized text is printed but accuracy is
///      explicitly reported as unchecked rather than silently skipped.
///
/// Prints measured durations and a recognized-text comparison; it makes no pass/fail claim about
/// how fast either path "should" be, and no "machine-cold" claim — only what was actually observed
/// on this machine, in this fixed run order, for this fixture, this run. OS file-system/page-cache
/// state is NOT controlled between samples (no fresh-boot/cache-drop protocol here), so only the
/// WhisperKit INSTANCE's own cold/warm state is meaningfully compared, never absolute wall time
/// across unrelated runs.
@MainActor
struct DictationBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SCRIBE_DICTATION_BENCHMARK"] != nil))
    func productionPrewarmPathVsOldPerOperationPath() async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["SCRIBE_DICTATION_BENCHMARK_FIXTURE"] else {
            Issue.record(
                """
                Set SCRIBE_DICTATION_BENCHMARK_FIXTURE to a WhisperKit-readable audio file. \
                Generate one with: say -o fixture.aiff "some sentence" && \
                afconvert fixture.aiff fixture.caf -d LEI16@16000 -c 1
                """
            )
            return
        }
        let fixtureURL = URL(filePath: fixturePath)
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            Issue.record("Fixture not found at \(fixturePath)")
            return
        }

        let environment = ProcessInfo.processInfo.environment
        let samples = environment["SCRIBE_DICTATION_BENCHMARK_SAMPLES"].flatMap(Int.init) ?? 5
        let leadSeconds = environment["SCRIBE_DICTATION_BENCHMARK_LEAD_SECONDS"].flatMap(Double.init) ?? 13.159
        let referenceText = environment["SCRIBE_DICTATION_BENCHMARK_REFERENCE_TEXT"]
        guard samples > 0 else {
            Issue.record("SCRIBE_DICTATION_BENCHMARK_SAMPLES must be positive")
            return
        }

        print("""
        Dictation benchmark — \(samples) sample(s), fixture \(fixturePath), simulated recording lead \(leadSeconds)s.
        OS file-system/page-cache state across samples is UNCONTROLLED here — treat only the \
        WhisperKit INSTANCE cold/warm distinction below as meaningful, never any absolute "machine-cold" claim. \
        Samples run in a fixed order (old baseline first, then the production path), so later \
        samples may benefit from OS file-cache warmed by earlier ones.\(referenceText == nil ? " No reference text supplied — recognized-text accuracy is UNCHECKED below." : "")
        """)

        try await runOldPerOperationBaseline(fixtureURL: fixtureURL, samples: samples, referenceText: referenceText)
        try await runProductionPath(
            fixtureURL: fixtureURL,
            samples: samples,
            leadSeconds: leadSeconds,
            referenceText: referenceText
        )
    }

    /// Unchanged from before: a fresh `WhisperDictationTranscriber` load, one decode, then unload —
    /// exactly what ran on every Stop before this task's cache. Reads the fixture directly; it
    /// never goes through capture, so it isn't a fair stand-in for "recording", only for the old
    /// per-operation model lifecycle cost.
    private func runOldPerOperationBaseline(
        fixtureURL: URL,
        samples: Int,
        referenceText: String?
    ) async throws {
        for i in 1...samples {
            let start = ContinuousClock.now
            let transcriber = try await WhisperDictationTranscriber.load()
            let loaded = ContinuousClock.now
            let text = try await transcriber.transcribe(url: fixtureURL)
            let decoded = ContinuousClock.now
            await transcriber.unloadModels()
            let unloaded = ContinuousClock.now
            let instanceState = i == 1 ? "instance-cold" : "fresh instance, OS-cache likely warm"
            print(
                "  old[\(i)/\(samples)] (\(instanceState)): load \(ms(loaded - start)) " +
                    "decode \(ms(decoded - loaded)) unload \(ms(unloaded - decoded)) total \(ms(unloaded - start))"
            )
            printAccuracy(label: "old[\(i)/\(samples)]", recognized: text, referenceText: referenceText)
        }
    }

    /// The actual feature under test: one real `AppState` + `DictationController` +
    /// `DictationModelCache` (production default WhisperKit "small" loader) reused across all
    /// samples, so sample 1 measures "fresh cache, prewarmed during the simulated recording lead"
    /// and samples 2+ measure "already-warm repeat" against the SAME loaded instance. Capture is
    /// faked to copy the fixture into the exact per-operation scratch CAF path the real controller
    /// creates; permission/UID/clipboard are faked too. No microphone, no real pasteboard.
    private func runProductionPath(
        fixtureURL: URL,
        samples: Int,
        leadSeconds: Double,
        referenceText: String?
    ) async throws {
        let timing = RecordingTimingSink()
        let pasteboard = BenchmarkPasteboard()
        let cache = DictationModelCache(timing: timing)
        let controller = DictationController(
            makeCapture: { url, _ in FixtureCapture(fixtureURL: fixtureURL, destinationURL: url) },
            requestMicrophoneAccess: { true },
            selectedMicrophoneUID: { nil },
            cache: cache
        )
        let state = AppState(dictationController: controller, pasteboard: pasteboard, dictationTiming: timing)
        let leadDuration = Duration.milliseconds(Int(leadSeconds * 1_000))

        for i in 1...samples {
            pasteboard.reset()
            timing.drain() // discard anything from a previous sample's stragglers

            await state.startDictation()
            try await Task.sleep(for: leadDuration)
            let stopRequestedAt = ContinuousClock.now
            state.requestStopDictation()
            try await waitUntilTerminal(state, timeout: .seconds(120))
            let stopSettledAt = ContinuousClock.now

            let events = timing.drain()
            let eventSummary = events.map { "\($0.label)=\(ms($0.duration))" }.joined(separator: ", ")
            let cacheState = i == 1 ? "cold cache, prewarmed during the \(leadSeconds)s lead" : "already-warm repeat"
            let outcome: String
            switch state.dictationState {
            case .copied: outcome = "copied"
            case let .failed(message): outcome = "FAILED: \(message)"
            default: outcome = "unexpected terminal state \(state.dictationState)"
            }
            print(
                "  new[\(i)/\(samples)] (\(cacheState)): \(outcome), stop-to-settled \(ms(stopSettledAt - stopRequestedAt))" +
                    (eventSummary.isEmpty ? "" : ", \(eventSummary)")
            )
            if let text = pasteboard.lastWritten {
                printAccuracy(label: "new[\(i)/\(samples)]", recognized: text, referenceText: referenceText)
            }
        }

        await controller.shutdown()
    }

    private func printAccuracy(label: String, recognized: String, referenceText: String?) {
        guard let referenceText else {
            print("  \(label) recognized (accuracy unchecked): \"\(recognized)\"")
            return
        }
        let reference = normalizedWords(referenceText)
        let hypothesis = normalizedWords(recognized)
        if reference == hypothesis {
            print("  \(label) recognized text matches reference exactly (normalized): \"\(recognized)\"")
        } else {
            let wer = wordErrorRate(reference: reference, hypothesis: hypothesis)
            print(
                "  \(label) recognized text differs from reference — word error rate \(String(format: "%.2f", wer)): " +
                    "\"\(recognized)\""
            )
        }
    }

    private func ms(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.0fms", value)
    }
}

private func normalizedWords(_ text: String) -> [String] {
    text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
}

/// Classic word-level Levenshtein edit distance divided by reference length.
private func wordErrorRate(reference: [String], hypothesis: [String]) -> Double {
    guard !reference.isEmpty else { return hypothesis.isEmpty ? 0 : 1 }
    var previousRow = Array(0...hypothesis.count)
    for (i, referenceWord) in reference.enumerated() {
        var currentRow = [i + 1]
        for (j, hypothesisWord) in hypothesis.enumerated() {
            if referenceWord == hypothesisWord {
                currentRow.append(previousRow[j])
            } else {
                currentRow.append(1 + min(previousRow[j], previousRow[j + 1], currentRow[j]))
            }
        }
        previousRow = currentRow
    }
    return Double(previousRow[hypothesis.count]) / Double(reference.count)
}

private struct BenchmarkTimedOut: Error, CustomStringConvertible {
    let description: String
}

/// Bounded, throwing wait so a stuck production path fails the benchmark instead of hanging it.
@MainActor
private func waitUntilTerminal(_ state: AppState, timeout: Duration) async throws {
    let deadline = ContinuousClock.now + timeout
    while true {
        switch state.dictationState {
        case .copied, .failed: return
        default: break
        }
        guard ContinuousClock.now < deadline else {
            throw BenchmarkTimedOut(description: "dictation never reached a terminal state within \(timeout)")
        }
        await Task.yield()
    }
}

/// Copies the supplied fixture into the exact scratch CAF path the real `DictationController`
/// creates for each operation, on `finalize()` — standing in for "the recording that just
/// happened produced this audio" without any AVAudioEngine/microphone/permission involvement.
private final class FixtureCapture: DictationCapturing {
    private let fixtureURL: URL
    private let destinationURL: URL

    init(fixtureURL: URL, destinationURL: URL) {
        self.fixtureURL = fixtureURL
        self.destinationURL = destinationURL
    }

    func start() throws {}

    func finalize() -> String? {
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: fixtureURL, to: destinationURL)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

@MainActor
private final class BenchmarkPasteboard: DictationPasteboard {
    private(set) var lastWritten: String?

    func writeText(_ text: String) -> Bool {
        lastWritten = text
        return true
    }

    func reset() {
        lastWritten = nil
    }
}

/// Captures the same fixed-label `DictationTiming` events the app logs to OSLog, per sample, so
/// the benchmark can report load/queue-wait/decode/unload durations without parsing the system log.
private final class RecordingTimingSink: DictationTiming, @unchecked Sendable {
    struct Event {
        let label: String
        let duration: Duration
    }

    private let lock = OSAllocatedUnfairLock(initialState: [Event]())

    func recordDuration(_ label: String, _ duration: Duration) {
        lock.withLock { $0.append(Event(label: label, duration: duration)) }
    }

    @discardableResult
    func drain() -> [Event] {
        lock.withLock { state in
            defer { state.removeAll() }
            return state
        }
    }
}
