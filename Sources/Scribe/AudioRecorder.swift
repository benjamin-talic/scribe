import AudioToolbox
import AVFAudio
import AVFoundation
import CoreAudio
import Foundation
import os

let microphoneDeviceUIDKey = "microphoneDeviceUID"
let systemAudioPermissionGrantedKey = "systemAudioPermissionGranted"

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let objectID: AudioObjectID
    let isDefault: Bool

    static func available() -> [AudioInputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &size) == noErr else { return [] }
        var objectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &devicesAddress, 0, nil, &size, &objectIDs) == noErr else { return [] }

        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultID = kAudioObjectUnknown
        size = UInt32(MemoryLayout.size(ofValue: defaultID))
        AudioObjectGetPropertyData(system, &defaultAddress, 0, nil, &size, &defaultID)

        return objectIDs.compactMap { objectID in
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(objectID, &streamsAddress, 0, nil, &streamsSize) == noErr,
                  streamsSize > 0,
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: objectID),
                  let name = stringProperty(kAudioObjectPropertyName, of: objectID) else { return nil }
            return AudioInputDevice(id: uid, name: name, objectID: objectID, isDefault: objectID == defaultID)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

func interleavedAudioFileFormat(_ clientFormat: AudioStreamBasicDescription) -> AudioStreamBasicDescription {
    guard clientFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 else { return clientFormat }
    var fileFormat = clientFormat
    fileFormat.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved
    fileFormat.mBytesPerFrame *= fileFormat.mChannelsPerFrame
    fileFormat.mBytesPerPacket *= fileFormat.mChannelsPerFrame
    return fileFormat
}

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
        case audio(String, OSStatus)
        case microphonePermissionDenied
        case noInputFormat
        case noMatchingAudioProcess
        case systemAudioPermissionDenied
        case selectedMicrophoneUnavailable

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: "A recording is already active."
            case .notRecording: "No recording is active."
            case let .audio(operation, status): "Audio capture failed while \(operation) (status \(status))."
            case .microphonePermissionDenied: "Microphone access is required to record meetings."
            case .noInputFormat: "The microphone has no available input format."
            case .noMatchingAudioProcess: "No audio process was found for the detected meeting app."
            case .systemAudioPermissionDenied: "System Audio Recording permission is required to capture other speakers."
            case .selectedMicrophoneUnavailable: "The selected microphone is disconnected. Choose another microphone in Settings."
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
        let microphone = MicrophoneCapture(
            url: paths.meAudio,
            deviceUID: UserDefaults.standard.string(forKey: microphoneDeviceUIDKey)
        )
        let systemAudio = ProcessTapCapture(url: paths.othersAudio, processObjectIDs: processObjectIDs)

        do {
            try systemAudio.start()
            try microphone.start()
            UserDefaults.standard.set(true, forKey: systemAudioPermissionGrantedKey)
            active = ActiveRecording(session: session, microphone: microphone, systemAudio: systemAudio)
            return session
        } catch {
            if let recordingError = error as? Error, case .systemAudioPermissionDenied = recordingError {
                UserDefaults.standard.set(false, forKey: systemAudioPermissionGrantedKey)
            }
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

        let microphoneFailure = active.microphone.finalize()
        active.systemAudio.stop()
        let failures = [microphoneFailure, active.systemAudio.failure].compactMap { $0 }

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

final class AudioFileWriter: @unchecked Sendable {
    private struct State {
        var failure: String?
        var firstHostTime: UInt64?
        var isClosed = false
    }

    private let file: ExtAudioFileRef
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(url: URL, format: AVAudioFormat) throws {
        var clientFormat = format.streamDescription.pointee
        var fileFormat = interleavedAudioFileFormat(clientFormat)
        var file: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileCAFType,
            &fileFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &file
        )
        guard createStatus == noErr, let file else {
            throw RecordingController.Error.audio("creating an audio file", createStatus)
        }
        self.file = file

        let formatStatus = ExtAudioFileSetProperty(
            file,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout.size(ofValue: clientFormat)),
            &clientFormat
        )
        guard formatStatus == noErr else {
            throw RecordingController.Error.audio("configuring an audio file", formatStatus)
        }
        let primeStatus = ExtAudioFileWriteAsync(file, 0, nil)
        guard primeStatus == noErr else {
            throw RecordingController.Error.audio("preparing an audio file", primeStatus)
        }
    }

    func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        write(buffer.audioBufferList, frames: buffer.frameLength, hostTime: hostTime)
    }

    /// The closed-check, the actual `ExtAudioFileWriteAsync` call, and the metadata update all
    /// happen under the same lock `close()` disposes under — `removeTap`/`engine.stop()` cannot be
    /// trusted to drain an audio callback that has already entered this function, so the writer
    /// itself, not the caller, is what must serialize a write against a concurrent close.
    func write(_ buffers: UnsafePointer<AudioBufferList>, frames: UInt32, hostTime: UInt64) {
        // UnsafePointer isn't Sendable, so it's passed into the @Sendable lock closure as a bit
        // pattern and reconstructed inside — the pointer is only ever dereferenced synchronously,
        // still on this same call stack, under the lock.
        let buffersAddress = Int(bitPattern: buffers)
        state.withLock { state in
            guard !state.isClosed, let pointer = UnsafePointer<AudioBufferList>(bitPattern: buffersAddress) else {
                return
            }
            let status = ExtAudioFileWriteAsync(file, frames, pointer)
            if hostTime != 0 { state.firstHostTime = state.firstHostTime ?? hostTime }
            if status != noErr { state.failure = state.failure ?? "Audio file write failed with status \(status)." }
        }
    }

    var firstHostTime: UInt64? { state.withLock { $0.firstHostTime } }
    var failure: String? { state.withLock { $0.failure } }

    /// Idempotent: disposes the file exactly once, merging any dispose failure into the same
    /// failure state as write errors. Callers must ensure no `write` is still in flight.
    @discardableResult
    func close() -> String? {
        state.withLock { state in
            guard !state.isClosed else { return state.failure }
            state.isClosed = true
            let status = ExtAudioFileDispose(file)
            if status != noErr {
                state.failure = state.failure ?? "Closing the audio file failed with status \(status)."
            }
            return state.failure
        }
    }

    deinit {
        let alreadyClosed = state.withLock { state -> Bool in
            let was = state.isClosed
            state.isClosed = true
            return was
        }
        if !alreadyClosed {
            ExtAudioFileDispose(file)
        }
    }
}

final class MicrophoneCapture {
    private let url: URL
    private let deviceUID: String?
    private let engine = AVAudioEngine()
    private var writer: AudioFileWriter?
    private var tapInstalled = false

    init(url: URL, deviceUID: String?) {
        self.url = url
        self.deviceUID = deviceUID
    }

    func start() throws {
        // Resolved before touching `engine.inputNode` at all: merely accessing that property can
        // itself trigger microphone hardware configuration (and the TCC permission prompt) on
        // some macOS versions, so an invalid selected UID must fail before any engine access.
        let selectedDeviceID = try SelectedMicrophoneResolver.resolve(uid: deviceUID)

        let input = engine.inputNode
        if var objectID = selectedDeviceID, let audioUnit = input.audioUnit {
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &objectID,
                UInt32(MemoryLayout.size(ofValue: objectID))
            )
            if status != noErr {
                throw RecordingController.Error.audio("selecting the microphone", status)
            }
        }
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

    /// Stops audio callbacks (`stop()`) before closing the writer, so no write can race a close,
    /// then flushes/closes the file. Callers reading the captured file must wait for this to
    /// return first — `stop()` alone leaves the writer's `ExtAudioFile` open.
    @discardableResult
    func finalize() -> String? {
        stop()
        return writer?.close()
    }

    var firstHostTime: UInt64? { writer?.firstHostTime }
    var failure: String? { writer?.failure }
}

/// Translates a persisted microphone UID to a CoreAudio device — pure device enumeration via
/// `AudioObjectGetPropertyData`, with no dependency on `AVAudioEngine` and no interaction with
/// the microphone capture permission at all, so it's safe to call from a unit test or before any
/// audio hardware is touched. Returns nil for "use the default device" (no UID persisted) but
/// throws when a persisted UID is set and can't be resolved — a disconnected selected microphone
/// must be a visible error, never a silent fallback to whatever device happens to be default.
enum SelectedMicrophoneResolver {
    static func resolve(uid: String?) throws -> AudioObjectID? {
        guard let uid, !uid.isEmpty else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var objectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout.size(ofValue: objectID))
        let uidSize = UInt32(MemoryLayout.size(ofValue: cfUID))
        let status = withUnsafePointer(to: &cfUID) {
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                uidSize,
                $0,
                &size,
                &objectID
            )
        }
        guard status == noErr else {
            throw RecordingController.Error.audio("finding the selected microphone", status)
        }
        guard objectID != kAudioObjectUnknown else {
            throw RecordingController.Error.selectedMicrophoneUnavailable
        }
        return objectID
    }
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

        try check(AudioHardwareCreateProcessTap(description, &tapID), operation: "creating the system audio tap")
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
            try check(
                AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID),
                operation: "creating the system audio device"
            )
            try check(
                AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
                    _, inputData, inputTime, _, _ in
                    let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
                    guard bytesPerFrame > 0, inputData.pointee.mBuffers.mData != nil else { return }
                    let frames = inputData.pointee.mBuffers.mDataByteSize / bytesPerFrame
                    writer.write(inputData, frames: frames, hostTime: inputTime.pointee.mHostTime)
                },
                operation: "installing system audio capture"
            )
            try check(AudioDeviceStart(aggregateID, ioProcID), operation: "starting system audio capture")
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
        writer?.close()
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
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription),
            operation: "reading the system audio format"
        )
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
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
            operation: "finding the output device"
        )

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout.size(ofValue: uid))
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid),
            operation: "reading the output device"
        )
        guard let uid else { throw RecordingController.Error.noInputFormat }
        return uid.takeRetainedValue() as String
    }

    private func check(_ status: OSStatus, operation: String) throws {
        if status == kAudioDevicePermissionsError {
            throw RecordingController.Error.systemAudioPermissionDenied
        }
        guard status == noErr else { throw RecordingController.Error.audio(operation, status) }
    }
}
