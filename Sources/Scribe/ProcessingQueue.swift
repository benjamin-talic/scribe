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

protocol SessionTranscribing: Sendable {
    func transcribe(session: RecordingSession, paths: SessionPaths) async throws -> String
    func unloadModels() async
}

actor ProcessingQueue {
    typealias TranscriberFactory = @Sendable () async throws -> any SessionTranscribing

    private let sessionStore: SessionStore
    private let loadTranscriber: TranscriberFactory
    private var isProcessing = false
    private var processAgain = false

    init(
        sessionStore: SessionStore,
        loadTranscriber: @escaping TranscriberFactory = { try await LocalTranscriber.load() }
    ) {
        self.sessionStore = sessionStore
        self.loadTranscriber = loadTranscriber
    }

    func processPendingTranscriptions() async throws {
        if isProcessing {
            processAgain = true
            return
        }
        isProcessing = true

        var transcriber: (any SessionTranscribing)?
        var attemptedSessionIDs: Set<String> = []
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
        let options = DecodingOptions(detectLanguage: true, wordTimestamps: true)
        let meResults: [TranscriptionResult] = try await whisperKit.transcribe(
            audioPath: paths.meAudio.path,
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

        return TranscriptRenderer.render(
            me: meResults.flatMap(\.segments).map {
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
