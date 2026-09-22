import AppKit
import AVFoundation
import Carbon.HIToolbox
import Foundation
import WhisperKit
import os

let dictationHotKeyDefaultsKey = "dictationHotKey"

/// A global toggle shortcut, captured from a real key-down event so its display label always
/// matches what RegisterEventHotKey will actually fire on. At least one of Cmd/Ctrl/Option is
/// required so an unmodified letter (or Shift alone) can never become a global toggle.
struct DictationHotKey: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var displayString: String

    static let `default` = DictationHotKey(
        keyCode: UInt32(kVK_ANSI_D),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        displayString: "⇧⌘D"
    )

    var hasPrimaryModifier: Bool {
        carbonModifiers & UInt32(cmdKey | controlKey | optionKey) != 0
    }

    static func captured(from event: NSEvent) -> DictationHotKey? {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let hasPrimary = modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)
        guard hasPrimary, let label = event.charactersIgnoringModifiers?.uppercased(), !label.isEmpty else {
            return nil
        }
        var carbon: UInt32 = 0
        var symbols = ""
        if modifiers.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        return DictationHotKey(keyCode: UInt32(event.keyCode), carbonModifiers: carbon, displayString: symbols + label)
    }

    /// Falls back to `.default` for anything missing, corrupt, or (from an older build) lacking a
    /// primary modifier, so a stale persisted value can never bypass the safety invariant.
    static func loadPersisted(from defaults: UserDefaults = .standard) -> DictationHotKey {
        guard let data = defaults.data(forKey: dictationHotKeyDefaultsKey),
              let decoded = try? JSONDecoder().decode(DictationHotKey.self, from: data),
              decoded.hasPrimaryModifier else {
            return .default
        }
        return decoded
    }

    func persist(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: dictationHotKeyDefaultsKey)
    }
}

/// Fires `onTrigger` once per physical key-down of the registered hotkey. Carbon delivers a
/// pressed event per key-repeat tick while a hotkey is held, so a press/release gate (not just
/// "pressed fires once") is required to avoid repeated toggles from a held key. Event identity
/// (signature + id) is checked so only our own registration can ever trigger it.
final class GlobalHotKeyMonitor: @unchecked Sendable {
    private static let signature = OSType(0x5343_5262) // 'SCRb'
    private static let hotKeyID = EventHotKeyID(signature: signature, id: 1)

    private struct State: Sendable {
        // Stored as a bit pattern (not `EventHotKeyRef`/`OpaquePointer`, which isn't Sendable) so
        // this struct can cross the `@Sendable` boundary of `OSAllocatedUnfairLock.withLock`.
        var hotKeyRefBits: Int?
        var isDown = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private var eventHandler: EventHandlerRef?
    private var installStatus: OSStatus = noErr
    var onTrigger: (@Sendable () -> Void)?

    init() {
        // `self` can't be passed to InstallEventHandler until every stored property has some
        // value, so these start as placeholders and are overwritten immediately below.
        eventHandler = nil
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyReleased)),
        ]
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            scribeHotKeyEventHandler,
            2,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        installStatus = status
        eventHandler = handler
    }

    /// Registers `hotKey` before unregistering the previous one, so a failed registration leaves
    /// the working shortcut completely untouched. Returns the raw Carbon status (`noErr` on
    /// success). Rejects up front — before ever calling `RegisterEventHotKey` — if the event
    /// handler failed to install, so a "successful" registration can never silently be a shortcut
    /// that will never fire.
    @discardableResult
    func register(_ hotKey: DictationHotKey) -> OSStatus {
        if let failure = HotKeyRegistrationGate.precondition(installStatus: installStatus, hasHandler: eventHandler != nil) {
            return failure
        }
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode, hotKey.carbonModifiers, Self.hotKeyID, GetApplicationEventTarget(), 0, &newRef
        )
        guard status == noErr else { return status }
        guard let newRef else { return OSStatus(eventNotHandledErr) }
        let newRefBits = Int(bitPattern: newRef)
        let oldRefBits = state.withLock { state -> Int? in
            let old = state.hotKeyRefBits
            state.hotKeyRefBits = newRefBits
            state.isDown = false
            return old
        }
        if let oldRef = oldRefBits.flatMap({ OpaquePointer(bitPattern: $0) }) {
            UnregisterEventHotKey(oldRef)
        }
        return noErr
    }

    fileprivate func handleEvent(_ event: EventRef?) {
        guard let event else { return }
        var receivedID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &receivedID
        )
        guard status == noErr, receivedID.signature == Self.signature, receivedID.id == Self.hotKeyID.id else { return }

        let kind = GetEventKind(event)
        let shouldTrigger = state.withLock { state -> Bool in
            switch kind {
            case UInt32(kEventHotKeyPressed):
                guard !state.isDown else { return false }
                state.isDown = true
                return true
            case UInt32(kEventHotKeyReleased):
                state.isDown = false
                return false
            default:
                return false
            }
        }
        if shouldTrigger { onTrigger?() }
    }

    deinit {
        let refBits = state.withLock { $0.hotKeyRefBits }
        if let ref = refBits.flatMap({ OpaquePointer(bitPattern: $0) }) { UnregisterEventHotKey(ref) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

/// The install/register precondition check, extracted as a pure function so it's testable without
/// any real Carbon call — `GlobalHotKeyMonitor.register` consults it before ever calling
/// `RegisterEventHotKey`. Returns the failure status to report immediately, or nil to proceed.
enum HotKeyRegistrationGate {
    static func precondition(installStatus: OSStatus, hasHandler: Bool) -> OSStatus? {
        guard installStatus == noErr else { return installStatus }
        guard hasHandler else { return OSStatus(eventNotHandledErr) }
        return nil
    }
}

private func scribeHotKeyEventHandler(
    _: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    Unmanaged<GlobalHotKeyMonitor>.fromOpaque(userData).takeUnretainedValue().handleEvent(event)
    return noErr
}

/// Every capture/stop/cancel call is scoped to the caller's own operation `generation`, so a late
/// completion from a superseded or cancelled operation can never touch hardware or state that
/// belongs to a newer one.
@MainActor
protocol DictationControlling: AnyObject {
    func start(generation: Int) async throws
    func stop(generation: Int) async throws -> String
    func cancel(generation: Int)
}

/// The subset of `MicrophoneCapture` dictation depends on, so tests can inject a fake that never
/// touches AVAudioEngine, CoreAudio, or the microphone permission prompt.
protocol DictationCapturing: AnyObject {
    func start() throws
    /// Stops audio callbacks and closes/flushes the writer; returns a failure description if any
    /// write or close failed. Must be called — and must return — before the captured file is read.
    func finalize() -> String?
}

extension MicrophoneCapture: DictationCapturing {}

protocol DictationTranscribing: Sendable {
    func transcribe(url: URL) async throws -> String
    func unloadModels() async
}

/// Isolates dictation's clipboard write from the concrete `NSPasteboard.general` so tests never
/// touch the developer's real clipboard.
@MainActor
protocol DictationPasteboard: AnyObject {
    @discardableResult
    func writeText(_ text: String) -> Bool
}

extension NSPasteboard: DictationPasteboard {
    /// Copies existing items into independent `NSPasteboardItem`s before clearing — items fetched
    /// from the pasteboard are invalidated by `clearContents()`, so writing them back directly
    /// would silently restore nothing. Restores that backup, best-effort, if the write fails.
    func writeText(_ text: String) -> Bool {
        let backup: [NSPasteboardItem] = (pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        clearContents()
        guard setString(text, forType: .string) else {
            clearContents()
            if !backup.isEmpty { writeObjects(backup) }
            return false
        }
        return true
    }
}

/// Conservative, meaning-preserving cleanup: only collapses whitespace. No lexical filtering —
/// acronyms, names, multilingual tokens, repetitions, and self-corrections are never inferred to
/// be filler, so nothing is ever dropped from what Whisper recognized.
enum DictationCleanup {
    static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class DictationController: DictationControlling {
    enum Error: LocalizedError {
        case alreadyDictating
        case notDictating
        case microphonePermissionDenied
        case captureFailed(String)
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .alreadyDictating: "Dictation is already active."
            case .notDictating: "No dictation is active."
            case .microphonePermissionDenied: "Microphone access is required to dictate."
            case let .captureFailed(reason): reason
            case .emptyTranscript: "No speech was recognized."
            }
        }
    }

    typealias CaptureFactory = @Sendable (URL, String?) -> any DictationCapturing
    typealias TranscriberLoader = @Sendable () async throws -> any DictationTranscribing
    typealias PermissionRequester = @Sendable () async -> Bool
    typealias MicrophoneUIDProvider = @Sendable () -> String?

    private let makeCapture: CaptureFactory
    private let loadTranscriber: TranscriberLoader
    private let requestMicrophoneAccess: PermissionRequester
    private let selectedMicrophoneUID: MicrophoneUIDProvider

    private var activeGeneration: Int?
    private var capture: (any DictationCapturing)?
    private var captureURL: URL?

    init(
        makeCapture: @escaping CaptureFactory = { url, uid in MicrophoneCapture(url: url, deviceUID: uid) },
        loadTranscriber: @escaping TranscriberLoader = { try await WhisperDictationTranscriber.load() },
        requestMicrophoneAccess: @escaping PermissionRequester = { await AVCaptureDevice.requestAccess(for: .audio) },
        selectedMicrophoneUID: @escaping MicrophoneUIDProvider = {
            UserDefaults.standard.string(forKey: microphoneDeviceUIDKey)
        }
    ) {
        self.makeCapture = makeCapture
        self.loadTranscriber = loadTranscriber
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.selectedMicrophoneUID = selectedMicrophoneUID
    }

    func start(generation: Int) async throws {
        guard activeGeneration == nil else { throw Error.alreadyDictating }
        activeGeneration = generation

        guard await requestMicrophoneAccess() else {
            if activeGeneration == generation { activeGeneration = nil }
            throw Error.microphonePermissionDenied
        }
        guard activeGeneration == generation else { throw CancellationError() }

        let url = FileManager.default.temporaryDirectory.appending(path: "scribe-dictation-\(UUID().uuidString).caf")
        let mic = makeCapture(url, selectedMicrophoneUID())
        do {
            try mic.start()
        } catch {
            try? FileManager.default.removeItem(at: url)
            if activeGeneration == generation { activeGeneration = nil }
            throw error
        }
        guard activeGeneration == generation else {
            _ = mic.finalize()
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        capture = mic
        captureURL = url
    }

    func stop(generation: Int) async throws -> String {
        guard activeGeneration == generation, let capture, let captureURL else { throw Error.notDictating }
        activeGeneration = nil
        self.capture = nil
        self.captureURL = nil
        defer { try? FileManager.default.removeItem(at: captureURL) }

        if let failure = capture.finalize() {
            throw Error.captureFailed(failure)
        }
        try Task.checkCancellation()

        let transcriber = try await loadTranscriber()
        let text: String
        do {
            try Task.checkCancellation()
            // Once decoding starts it always runs to completion; unload only ever follows it,
            // on both the success and failure path, never interrupting an active decode.
            text = try await transcriber.transcribe(url: captureURL)
        } catch {
            await transcriber.unloadModels()
            throw error
        }
        // Unload happens exactly once, here, regardless of whether the cleaned result below turns
        // out empty — that check must never cause a second unload.
        await transcriber.unloadModels()

        let cleaned = DictationCleanup.clean(text)
        guard !cleaned.isEmpty else { throw Error.emptyTranscript }
        return cleaned
    }

    func cancel(generation: Int) {
        guard activeGeneration == generation else { return }
        activeGeneration = nil
        _ = capture?.finalize()
        if let captureURL { try? FileManager.default.removeItem(at: captureURL) }
        capture = nil
        captureURL = nil
    }
}

/// Mic-only, diarization-free transcription for dictation — deliberately separate from the
/// meeting `LocalTranscriber` in ProcessingQueue.swift, which always loads SpeakerKit. Loaded
/// fresh per dictation operation (see `DictationController.stop`) rather than cached, so the
/// model never sits in memory indefinitely and two operations can never share one live instance.
struct WhisperDictationTranscriber: DictationTranscribing, @unchecked Sendable {
    let whisperKit: WhisperKit

    static func load() async throws -> WhisperDictationTranscriber {
        WhisperDictationTranscriber(whisperKit: try await WhisperKit(WhisperKitConfig(model: "small", verbose: false, load: true)))
    }

    func transcribe(url: URL) async throws -> String {
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        let options = DecodingOptions(detectLanguage: true, skipSpecialTokens: true)
        let results: [TranscriptionResult] = try await whisperKit.transcribe(audioArray: audio, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
    }

    func unloadModels() async {
        await whisperKit.unloadModels()
    }
}
