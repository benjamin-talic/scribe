import Accelerate
import CoreAudio
import Foundation
import SpeakerKit
import WhisperKit

struct TranscriptEntry: Sendable {
    enum Speaker: Sendable {
        case me
        case remote(Int?)
    }

    let startTime: TimeInterval
    let speaker: Speaker
    let text: String
}

enum TranscriptRenderer {
    static func render(
        me: [TranscriptEntry],
        others: [TranscriptEntry],
        meOffset: TimeInterval,
        othersOffset: TimeInterval
    ) -> String {
        (me.map { ($0, meOffset) } + others.map { ($0, othersOffset) })
            .compactMap { entry, offset -> (TimeInterval, String)? in
                let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let speaker = switch entry.speaker {
                case .me: "Me"
                case let .remote(id): id.map { "Speaker \($0 + 1)" } ?? "Others"
                }
                return (entry.startTime + offset, "\(timestamp(entry.startTime + offset)) \(speaker): \(text)")
            }
            .enumerated()
            .sorted {
                $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0
            }
            .map { $0.element.1 }
            .joined(separator: "\n\n")
    }

    private static func timestamp(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time))
        let hours = seconds / 3_600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

enum EchoDetector {
    private static let sourceSampleRate = 16_000.0
    private static let downsampleFactor = 4
    private static let padding = 0.15
    private static let maximumLag = 0.5

    static func isEcho(
        segment: Range<TimeInterval>,
        remoteSpeech: [Range<TimeInterval>],
        microphoneAudio: [Float],
        remoteAudio: [Float],
        microphoneOffset: TimeInterval,
        remoteOffset: TimeInterval
    ) -> Bool {
        let duration = segment.upperBound - segment.lowerBound
        let remoteOverlap = remoteSpeech.reduce(0) { $0 + overlap(segment, $1) }
        guard duration >= 0.75, remoteOverlap >= min(0.5, duration / 2) else {
            return false
        }

        let microphoneStart = max(segment.lowerBound - padding, microphoneOffset)
        let microphoneEnd = min(
            segment.upperBound + padding,
            microphoneOffset + Double(microphoneAudio.count) / sourceSampleRate
        )
        let remoteStart = max(microphoneStart - maximumLag, remoteOffset)
        let remoteEnd = min(
            microphoneEnd + maximumLag,
            remoteOffset + Double(remoteAudio.count) / sourceSampleRate
        )
        let microphone = samples(
            microphoneAudio,
            from: microphoneStart,
            to: microphoneEnd,
            trackOffset: microphoneOffset
        )
        let remote = samples(remoteAudio, from: remoteStart, to: remoteEnd, trackOffset: remoteOffset)

        guard let score = score(microphone: microphone, remote: remote) else { return false }
        return score.correlation >= 0.5 && score.unmatchedPowerRatio <= 0.5
    }

    static func score(microphone: [Float], remote: [Float]) -> (correlation: Float, unmatchedPowerRatio: Float)? {
        guard microphone.count >= 80, remote.count >= microphone.count,
              vDSP.sumOfSquares(microphone) / Float(microphone.count) > 1e-8 else { return nil }
        // ponytail: Broadband envelopes intentionally fail open; use band coherence if real recordings show missed echoes.
        let microphoneEnvelope = energyEnvelope(microphone)
        let remoteEnvelope = energyEnvelope(remote)
        guard remoteEnvelope.count >= microphoneEnvelope.count else { return nil }
        let microphoneMean = vDSP.sum(microphoneEnvelope) / Float(microphoneEnvelope.count)
        let centeredMicrophone = microphoneEnvelope.map { $0 - microphoneMean }
        let microphoneEnergy = vDSP.sumOfSquares(centeredMicrophone)
        guard microphoneEnergy > 0 else { return nil }

        var correlations = [Float](repeating: 0, count: remoteEnvelope.count - microphoneEnvelope.count + 1)
        vDSP.correlate(remoteEnvelope, withKernel: centeredMicrophone, result: &correlations)
        var prefix = [Float](repeating: 0, count: remoteEnvelope.count + 1)
        var prefixSquares = prefix
        for index in remoteEnvelope.indices {
            prefix[index + 1] = prefix[index] + remoteEnvelope[index]
            prefixSquares[index + 1] = prefixSquares[index] + remoteEnvelope[index] * remoteEnvelope[index]
        }

        var bestIndex = 0
        var bestCorrelation: Float = 0
        for index in correlations.indices {
            let count = Float(microphoneEnvelope.count)
            let sum = prefix[index + microphoneEnvelope.count] - prefix[index]
            let sumOfSquares = prefixSquares[index + microphoneEnvelope.count] - prefixSquares[index]
            let remoteEnergy = sumOfSquares - sum * sum / count
            guard remoteEnergy > 0 else { continue }
            let correlation = correlations[index] / sqrt(microphoneEnergy * remoteEnergy)
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestIndex = index
            }
        }

        let microphonePower = powerEnvelope(microphone)
        let remotePower = Array(powerEnvelope(remote)[bestIndex..<(bestIndex + microphonePower.count)])
        let remotePeak = remotePower.max() ?? 0
        let ratios = zip(microphonePower, remotePower).compactMap { microphone, remote -> Float? in
            remote > remotePeak * 0.01 ? microphone / remote : nil
        }.sorted()
        let totalMicrophonePower = microphonePower.reduce(0, +)
        guard !ratios.isEmpty, totalMicrophonePower > 0 else { return nil }
        let echoGain = ratios[ratios.count / 4]
        let unmatchedPower = zip(microphonePower, remotePower).reduce(Float(0)) {
            $0 + max(0, $1.0 - 3 * echoGain * $1.1)
        }
        return (bestCorrelation, unmatchedPower / totalMicrophonePower)
    }

    private static func samples(
        _ audio: [Float],
        from start: TimeInterval,
        to end: TimeInterval,
        trackOffset: TimeInterval
    ) -> [Float] {
        let lower = max(0, Int(((start - trackOffset) * sourceSampleRate).rounded(.down)))
        let upper = min(audio.count, Int(((end - trackOffset) * sourceSampleRate).rounded(.up)))
        guard upper - lower >= downsampleFactor else { return [] }
        let input = audio[lower..<upper]
        return stride(from: 0, to: input.count - downsampleFactor + 1, by: downsampleFactor).map { index in
            let start = input.startIndex + index
            return input[start..<(start + downsampleFactor)].reduce(0, +) / Float(downsampleFactor)
        }
    }

    private static func energyEnvelope(_ samples: [Float]) -> [Float] {
        powerEnvelope(samples).map { log10($0 + 1e-10) }
    }

    private static func powerEnvelope(_ samples: [Float]) -> [Float] {
        let frameLength = 80
        return stride(from: 0, to: samples.count - frameLength + 1, by: frameLength).map { start in
            vDSP.sumOfSquares(samples[start..<(start + frameLength)]) / Float(frameLength)
        }
    }

    private static func overlap(_ lhs: Range<TimeInterval>, _ rhs: Range<TimeInterval>) -> TimeInterval {
        max(0, min(lhs.upperBound, rhs.upperBound) - max(lhs.lowerBound, rhs.lowerBound))
    }
}

protocol SessionTranscribing: Sendable {
    func transcribe(session: RecordingSession, paths: SessionPaths) async throws -> String
    func unloadModels() async
}

actor ProcessingQueue {
    typealias TranscriberFactory = @Sendable () async throws -> any SessionTranscribing
    typealias NotesGeneratorFactory = @Sendable (NotesClient) async throws -> any SessionNotesGenerating

    private let sessionStore: SessionStore
    private let loadTranscriber: TranscriberFactory
    private let loadNotesGenerator: NotesGeneratorFactory
    private var isProcessing = false
    private var processAgain = false

    init(
        sessionStore: SessionStore,
        loadTranscriber: @escaping TranscriberFactory = { try await LocalTranscriber.load() },
        loadNotesGenerator: @escaping NotesGeneratorFactory = { CLINotesGenerator(client: $0) }
    ) {
        self.sessionStore = sessionStore
        self.loadTranscriber = loadTranscriber
        self.loadNotesGenerator = loadNotesGenerator
    }

    func processPendingTranscriptions() async throws {
        if isProcessing {
            processAgain = true
            return
        }
        isProcessing = true

        var transcriber: (any SessionTranscribing)?
        var attemptedSessionIDs: Set<String> = []
        var attemptedNotesSessionIDs: Set<String> = []
        var queueError: (any Swift.Error)?

        while queueError == nil {
            processAgain = false
            do {
                let sessions = try await sessionStore.allSessions()
                    .filter { $0.stage == .pendingTranscription && !attemptedSessionIDs.contains($0.id) }
                    .sorted { $0.startedAt < $1.startedAt }

                for session in sessions {
                    attemptedSessionIDs.insert(session.id)
                    do {
                        try await sessionStore.transition(session.id, to: .transcribing)
                        let paths = try await sessionStore.sessionPaths(for: session.id)
                        if transcriber == nil {
                            transcriber = try await loadTranscriber()
                        }
                        let transcript = try await transcriber!.transcribe(session: session, paths: paths)
                        try Data(transcript.utf8).write(to: paths.transcript, options: .atomic)
                        try await sessionStore.transition(session.id, to: .transcribed)
                    } catch {
                        _ = try? await sessionStore.transition(
                            session.id,
                            to: .pendingTranscription,
                            error: error.localizedDescription
                        )
                    }
                }

                let notesSessions = try await sessionStore.allSessions()
                    .filter { $0.stage == .transcribed && !attemptedNotesSessionIDs.contains($0.id) }
                    .sorted { $0.startedAt < $1.startedAt }

                for session in notesSessions {
                    attemptedNotesSessionIDs.insert(session.id)
                    do {
                        try await sessionStore.transition(session.id, to: .generatingNotes)
                        let paths = try await sessionStore.sessionPaths(for: session.id)
                        let transcript = try String(contentsOf: paths.transcript, encoding: .utf8)
                        let client = try await sessionStore.notesClient()
                        let generator = try await loadNotesGenerator(client)
                        let notes = try await generator.generate(from: paths.transcript)
                        try await sessionStore.writeNotes(session.id, generated: notes, transcript: transcript)
                    } catch {
                        _ = try? await sessionStore.transition(
                            session.id,
                            to: .transcribed,
                            error: error.localizedDescription
                        )
                    }
                }
            } catch {
                queueError = error
            }

            if processAgain && queueError == nil { continue }
            if let loadedTranscriber = transcriber {
                await loadedTranscriber.unloadModels()
                transcriber = nil
            }
            if processAgain && queueError == nil { continue }
            break
        }

        isProcessing = false
        if let queueError { throw queueError }
    }
}

private struct LocalTranscriber: SessionTranscribing, @unchecked Sendable {
    let whisperKit: WhisperKit
    let speakerKit: SpeakerKit

    static func load() async throws -> LocalTranscriber {
        let whisperKit = try await WhisperKit(WhisperKitConfig(model: "small", verbose: false, load: true))
        do {
            return try await LocalTranscriber(
                whisperKit: whisperKit,
                speakerKit: SpeakerKit(PyannoteConfig(modelDownloadConfig: nil, load: true, verbose: false))
            )
        } catch {
            await whisperKit.unloadModels()
            throw error
        }
    }

    func transcribe(session: RecordingSession, paths: SessionPaths) async throws -> String {
        let options = DecodingOptions(detectLanguage: true, skipSpecialTokens: true, wordTimestamps: true)
        let meAudio = try AudioProcessor.loadAudioAsFloatArray(fromPath: paths.meAudio.path)
        let meResults: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: meAudio,
            decodeOptions: options
        )
        let othersAudio = try AudioProcessor.loadAudioAsFloatArray(fromPath: paths.othersAudio.path)
        let othersResults: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: othersAudio,
            decodeOptions: options
        )
        let diarization = try await speakerKit.diarize(audioArray: othersAudio)
        let remoteSegments = diarization.addSpeakerInfo(to: othersResults).flatMap { $0 }
        let unassignedSegments = othersResults.flatMap(\.segments).filter { transcription in
            !remoteSegments.contains {
                max($0.startTime, transcription.start) < min($0.endTime, transcription.end)
            }
        }
        let (meOffset, othersOffset) = Self.trackOffsets(session)
        let otherSpeech = othersResults.flatMap(\.segments).map {
            (Double($0.start) + othersOffset)..<(Double($0.end) + othersOffset)
        }
        let meSegments = meResults.flatMap(\.segments).filter {
            !EchoDetector.isEcho(
                segment: (Double($0.start) + meOffset)..<(Double($0.end) + meOffset),
                remoteSpeech: otherSpeech,
                microphoneAudio: meAudio,
                remoteAudio: othersAudio,
                microphoneOffset: meOffset,
                remoteOffset: othersOffset
            )
        }

        return TranscriptRenderer.render(
            me: meSegments.map {
                TranscriptEntry(startTime: Double($0.start), speaker: .me, text: $0.text)
            },
            others: remoteSegments.map {
                TranscriptEntry(
                    startTime: Double($0.startTime),
                    speaker: .remote($0.speaker.speakerId),
                    text: $0.text
                )
            } + unassignedSegments.map {
                TranscriptEntry(startTime: Double($0.start), speaker: .remote(nil), text: $0.text)
            },
            meOffset: meOffset,
            othersOffset: othersOffset
        )
    }

    func unloadModels() async {
        await whisperKit.unloadModels()
        await speakerKit.unloadModels()
    }

    private static func trackOffsets(_ session: RecordingSession) -> (TimeInterval, TimeInterval) {
        guard let me = session.meStartHostTime, let others = session.othersStartHostTime else {
            return (0, 0)
        }
        if me < others {
            return (0, TimeInterval(AudioConvertHostTimeToNanos(others - me)) / 1_000_000_000)
        }
        return (TimeInterval(AudioConvertHostTimeToNanos(me - others)) / 1_000_000_000, 0)
    }
}
