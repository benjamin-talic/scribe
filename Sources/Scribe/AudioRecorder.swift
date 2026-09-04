import AudioToolbox
import AVFAudio
import AVFoundation
import CoreAudio
import Foundation
import os

@MainActor
protocol RecordingControlling: AnyObject {
    func start(for application: MeetingApplication?, at date: Date) async throws -> RecordingSession
    func stop(at date: Date) async throws -> RecordingSession
}

@MainActor
final class RecordingController: RecordingControlling {
    enum Error: LocalizedError {
        case alreadyRecording
        case notRecording
        case audio(OSStatus)
        case microphonePermissionDenied
        case noInputFormat
        case noMatchingAudioProcess
        case systemAudioPermissionDenied

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: "A recording is already active."
            case .notRecording: "No recording is active."
            case let .audio(status): "Audio capture failed with status \(status)."
            case .microphonePermissionDenied: "Microphone access is required to record meetings."
            case .noInputFormat: "The microphone has no available input format."
            case .noMatchingAudioProcess: "No audio process was found for the detected meeting app."
            case .systemAudioPermissionDenied: "System Audio Recording permission is required to capture other speakers."
            }
        }
    }

    private struct ActiveRecording {
        let session: RecordingSession
        let microphone: MicrophoneCapture
        let systemAudio: ProcessTapCapture
    }

    private let sessionStore: SessionStore
    private var active: ActiveRecording?

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
    }

    func start(for application: MeetingApplication?, at date: Date = .now) async throws -> RecordingSession {
        guard active == nil else { throw Error.alreadyRecording }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw Error.microphonePermissionDenied
        }

        let processObjectIDs = try application.map { application in
            let ids = try CoreAudioMicScanner().processObjectIDs(for: application)
            guard !ids.isEmpty else { throw Error.noMatchingAudioProcess }
            return ids
        }

        let session = try await sessionStore.createSession(
            sourceApplication: application?.name,
            startedAt: date
        )
        let paths = try await sessionStore.sessionPaths(for: session.id)
        let microphone = MicrophoneCapture(url: paths.meAudio)
        let systemAudio = ProcessTapCapture(url: paths.othersAudio, processObjectIDs: processObjectIDs)

        do {
            try systemAudio.start()
            try microphone.start()
            active = ActiveRecording(session: session, microphone: microphone, systemAudio: systemAudio)
            return session
        } catch {
            microphone.stop()
            systemAudio.stop()
            try? await sessionStore.discardRecording(session.id)
            throw error
        }
    }

    @discardableResult
    func stop(at date: Date = .now) async throws -> RecordingSession {
        guard let active else { throw Error.notRecording }
        defer { self.active = nil }

        active.microphone.stop()
        active.systemAudio.stop()
        let failures = [active.microphone.failure, active.systemAudio.failure].compactMap { $0 }

        let session = try await sessionStore.finishRecording(
            active.session.id,
            at: date,
            meStartHostTime: active.microphone.firstHostTime,
            othersStartHostTime: active.systemAudio.firstHostTime,
            error: failures.isEmpty ? nil : failures.joined(separator: "\n")
        )
        return session
    }
}

private final class AudioFileWriter: @unchecked Sendable {
    private struct State {
        var failure: String?
        var firstHostTime: UInt64?
    }

    private let file: ExtAudioFileRef
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(url: URL, format: AVAudioFormat) throws {
        var streamDescription = format.streamDescription.pointee
        var file: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileCAFType,
            &streamDescription,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &file
        )
        guard createStatus == noErr, let file else { throw RecordingController.Error.audio(createStatus) }
        self.file = file

        let formatStatus = ExtAudioFileSetProperty(
            file,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout.size(ofValue: streamDescription)),
            &streamDescription
        )
        guard formatStatus == noErr else { throw RecordingController.Error.audio(formatStatus) }
        let primeStatus = ExtAudioFileWriteAsync(file, 0, nil)
        guard primeStatus == noErr else { throw RecordingController.Error.audio(primeStatus) }
    }

    func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        write(buffer.audioBufferList, frames: buffer.frameLength, hostTime: hostTime)
    }

    func write(_ buffers: UnsafePointer<AudioBufferList>, frames: UInt32, hostTime: UInt64) {
        let status = ExtAudioFileWriteAsync(file, frames, buffers)
        state.withLock {
            if hostTime != 0 { $0.firstHostTime = $0.firstHostTime ?? hostTime }
            if status != noErr { $0.failure = $0.failure ?? "Audio file write failed with status \(status)." }
        }
    }

    var firstHostTime: UInt64? { state.withLock { $0.firstHostTime } }
    var failure: String? { state.withLock { $0.failure } }

    deinit {
        ExtAudioFileDispose(file)
    }
}

private final class MicrophoneCapture {
    private let url: URL
    private let engine = AVAudioEngine()
    private var writer: AudioFileWriter?
    private var tapInstalled = false

    init(url: URL) {
        self.url = url
    }

    func start() throws {
        let input = engine.inputNode
        engine.prepare()
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw RecordingController.Error.noInputFormat
        }
        let writer = try AudioFileWriter(url: url, format: format)
        self.writer = writer
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, time in
            writer.write(buffer, hostTime: time.hostTime)
        }
        tapInstalled = true
        try engine.start()
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    var firstHostTime: UInt64? { writer?.firstHostTime }
    var failure: String? { writer?.failure }
}

private final class ProcessTapCapture {
    private let url: URL
    private let processObjectIDs: [AudioObjectID]?
    private let queue = DispatchQueue(label: "local.scribe.system-audio", qos: .userInitiated)
    private var tapID = kAudioObjectUnknown
    private var aggregateID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: AudioFileWriter?

    init(url: URL, processObjectIDs: [AudioObjectID]?) {
        self.url = url
        self.processObjectIDs = processObjectIDs
    }

    func start() throws {
        let description: CATapDescription
        if let processObjectIDs {
            description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
            description.isProcessRestoreEnabled = true
        } else {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        description.name = "Scribe System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try check(AudioHardwareCreateProcessTap(description, &tapID))
        do {
            let format = try tapFormat()
            let writer = try AudioFileWriter(url: url, format: format)
            self.writer = writer
            let outputUID = try defaultOutputDeviceUID()
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Scribe System Audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: 1,
                kAudioAggregateDeviceIsStackedKey: 0,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: 1,
                ]],
            ]
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID))
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
                _, inputData, inputTime, _, _ in
                let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
                guard bytesPerFrame > 0, inputData.pointee.mBuffers.mData != nil else { return }
                let frames = inputData.pointee.mBuffers.mDataByteSize / bytesPerFrame
                writer.write(inputData, frames: frames, hostTime: inputTime.pointee.mHostTime)
            })
            try check(AudioDeviceStart(aggregateID, ioProcID))
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    var firstHostTime: UInt64? { writer?.firstHostTime }
    var failure: String? { writer?.failure }

    private func tapFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: streamDescription))
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription))
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw RecordingController.Error.noInputFormat
        }
        return format
    }

    private func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout.size(ofValue: deviceID))
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID))

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout.size(ofValue: uid))
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid))
        guard let uid else { throw RecordingController.Error.noInputFormat }
        return uid.takeRetainedValue() as String
    }

    private func check(_ status: OSStatus) throws {
        if status == kAudioDevicePermissionsError {
            throw RecordingController.Error.systemAudioPermissionDenied
        }
        guard status == noErr else { throw RecordingController.Error.audio(status) }
    }
}
