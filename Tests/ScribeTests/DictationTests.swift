import AppKit
import AVFoundation
import Carbon.HIToolbox
import Foundation
import Testing
import os
@testable import Scribe

// MARK: - AppState-level tests (real AppState, fake DictationControlling/RecordingControlling)

@MainActor
struct DictationTests {
    @Test
    func toggleDictationCopiesRecognizedTextToClipboard() async throws {
        let controller = FakeDictationController()
        controller.stopResult = .success("hello there")
        let pasteboard = FakePasteboard(initial: "sentinel")
        let state = AppState(dictationController: controller, pasteboard: pasteboard)

        await state.toggleDictation()
        guard case .recording = state.dictationState else {
            Issue.record("expected recording state after first toggle")
            return
        }
        #expect(controller.startCalls == 1)

        await state.toggleDictation()
        try await waitUntil("copied") { state.dictationState == .copied }

        #expect(state.dictationState == .copied)
        #expect(controller.stopCalls == 1)
        #expect(pasteboard.lastWritten == "hello there")
    }

    @Test
    func cancellingWhileStartingSkipsHardwareOpenAndShowsNoFailure() async throws {
        let controller = FakeDictationController()
        controller.delayStart = true
        let pasteboard = FakePasteboard(initial: "sentinel")
        let state = AppState(dictationController: controller, pasteboard: pasteboard)

        let startTask = Task { await state.startDictation() }
        try await waitUntil("starting") { state.dictationState == .starting }

        state.cancelDictation()
        #expect(state.dictationState == .idle)

        controller.resumeStart()
        await startTask.value

        #expect(state.dictationState == .idle)
        #expect(pasteboard.lastWritten == "sentinel")
    }

    @Test
    func cancellingWhileRecordingSkipsTranscriptionAndClipboard() async {
        let controller = FakeDictationController()
        let pasteboard = FakePasteboard(initial: "sentinel")
        let state = AppState(dictationController: controller, pasteboard: pasteboard)

        await state.startDictation()
        state.cancelDictation()

        #expect(state.dictationState == .idle)
        #expect(controller.cancelCalls == 1)
        #expect(controller.stopCalls == 0)
        #expect(pasteboard.lastWritten == "sentinel")
    }

    @Test
    func cancellingDuringProcessingLetsANewDictationStartAndStopIndependently() async throws {
        let controller = FakeDictationController()
        controller.delayStop = true
        let pasteboard = FakePasteboard(initial: "sentinel")
        let state = AppState(dictationController: controller, pasteboard: pasteboard)

        await state.startDictation()
        state.requestStopDictation()
        try await waitUntil("processing") { state.dictationState == .processing }

        state.cancelDictation()
        #expect(state.dictationState == .idle)

        // A fresh dictation can start and finish while the cancelled one is still transcribing.
        controller.delayStop = false
        controller.stopResult = .success("second pass")
        await state.startDictation()
        state.requestStopDictation()
        try await waitUntil("second pass copied") { state.dictationState == .copied }
        #expect(pasteboard.lastWritten == "second pass")

        // The stale first operation resolving afterward must not clobber the second's result.
        controller.resumeStop()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(state.dictationState == .copied)
        #expect(pasteboard.lastWritten == "second pass")
    }

    @Test
    func emptyOrFailedTranscriptionDoesNotOverwriteClipboard() async throws {
        let controller = FakeDictationController()
        controller.stopResult = .failure(DictationController.Error.emptyTranscript)
        let pasteboard = FakePasteboard(initial: "sentinel")
        let state = AppState(dictationController: controller, pasteboard: pasteboard)

        await state.startDictation()
        state.requestStopDictation()
        try await waitUntil("failed") { if case .failed = state.dictationState { true } else { false } }

        guard case .failed = state.dictationState else {
            Issue.record("expected a visible failure state")
            return
        }
        #expect(pasteboard.lastWritten == "sentinel")
    }

    @Test
    func pasteboardWriteFailureReportsFailedNotCopied() async throws {
        let controller = FakeDictationController()
        controller.stopResult = .success("hello")
        let pasteboard = FakePasteboard(initial: "sentinel")
        pasteboard.shouldFailWrite = true
        let state = AppState(dictationController: controller, pasteboard: pasteboard)

        await state.startDictation()
        state.requestStopDictation()
        try await waitUntil("failed") { if case .failed = state.dictationState { true } else { false } }

        guard case .failed = state.dictationState else {
            Issue.record("expected a visible failure state")
            return
        }
    }

    @Test
    func meetingRecordingAndDictationAreMutuallyExclusiveIncludingInFlightStarts() async throws {
        let recorder = FakeMeetingRecorder()
        let dictation = FakeDictationController()
        let state = AppState(recorder: recorder, dictationController: dictation)

        // Meeting start still in flight -> dictation is refused, not silently allowed to race in.
        recorder.delayStart = true
        let meetingStart = Task { await state.startRecording(at: .now) }
        try await waitUntil("meeting start in flight") { recorder.startCalls > 0 }

        await state.startDictation()
        guard case let .failed(message) = state.dictationState else {
            Issue.record("expected dictation to be refused while a meeting start is in flight")
            return
        }
        #expect(message.localizedCaseInsensitiveContains("meeting"))
        #expect(dictation.startCalls == 0)

        recorder.resumeStart()
        await meetingStart.value
        #expect(state.isRecording)

        await state.stopRecording()
        #expect(!state.isRecording)

        // Dictation still starting (.starting) -> meeting recording is refused, not raced.
        dictation.delayStart = true
        let dictationStart = Task { await state.startDictation() }
        try await waitUntil("dictation starting") { state.dictationState == .starting }

        await state.startRecording(at: .now)
        #expect(!state.isRecording)
        #expect(state.recordingError?.localizedCaseInsensitiveContains("dictation") == true)

        dictation.resumeStart()
        await dictationStart.value
        #expect(state.isDictationBusy)
    }

    @Test
    func shutdownDrainsAnInFlightMeetingStartAndStopsAnyRecordingItResolvesTo() async throws {
        let recorder = FakeMeetingRecorder()
        recorder.delayStart = true
        let state = AppState(recorder: recorder)

        let startTask = Task { await state.startRecording(at: .now) }
        try await waitUntil("meeting start in flight") { recorder.startCalls > 0 }

        // shutdown() is called while the start is still suspended in recorder.start(). A post-await
        // `isShuttingDown` check inside `startRecording` alone would be too late here — shutdown()
        // must itself await the same tracked start.
        let shutdownTask = Task { await state.shutdown() }
        try await Task.sleep(for: .milliseconds(30))

        recorder.resumeStart()
        await startTask.value
        await shutdownTask.value

        // By the time shutdown() has returned, any recording the drained start resolved to must
        // already be stopped — proving shutdown genuinely waited for it rather than missing it.
        #expect(!state.isRecording)
        #expect(recorder.stopCalls == 1)
    }

    @Test
    func shutdownInvalidatesBeforeAwaitingDrainedOperations() async throws {
        let recorder = FakeMeetingRecorder()
        recorder.delayStop = true
        let dictation = FakeDictationController()
        dictation.delayStop = true
        dictation.stopResult = .success("late text")
        let pasteboard = FakePasteboard(initial: "sentinel")
        let state = AppState(recorder: recorder, dictationController: dictation, pasteboard: pasteboard)

        // A dictation stop is in flight, then cancelled — its task keeps running independently
        // (cancel() cannot abort a real decode), which frees the mutual-exclusion gate so a
        // meeting recording can start concurrently. This reproduces "processing plus meeting" for
        // shutdown ordering without requiring two capture devices active at once, which the app
        // never allows.
        await state.startDictation()
        state.requestStopDictation()
        try await waitUntil("processing") { state.dictationState == .processing }
        state.cancelDictation()
        #expect(state.dictationState == .idle)

        await state.startRecording(at: .now)
        #expect(state.isRecording)

        let shutdownTask = Task { await state.shutdown() }
        try await waitUntil("meeting stop reached") { recorder.stopCalls > 0 }

        // The cancelled dictation's stop() resolves while shutdown() is still awaiting the
        // meeting's stop() -- the epoch invalidation set when it was cancelled (before shutdown()
        // was even called) keeps this late result off the clipboard regardless of exactly where
        // shutdown() itself is in its own await chain.
        dictation.resumeStop()
        try await Task.sleep(for: .milliseconds(30))
        #expect(pasteboard.lastWritten == "sentinel")
        #expect(state.dictationState == .idle)

        recorder.resumeStop()
        await shutdownTask.value

        #expect(!state.isRecording)
        #expect(state.dictationState == .idle)
        #expect(pasteboard.lastWritten == "sentinel")
        #expect(dictation.stopCalls == 1)
        #expect(recorder.stopCalls == 1)
    }

    @Test
    func shutdownAwaitsEveryTrackedDictationTaskIncludingCancelledPriorGenerations() async throws {
        let dictation = FakeDictationController()
        dictation.delayStop = true
        let state = AppState(dictationController: dictation)

        await state.startDictation()
        state.requestStopDictation()
        try await waitUntil("processing") { state.dictationState == .processing }
        state.cancelDictation()
        #expect(state.dictationState == .idle)

        let shutdownTask = Task { await state.shutdown() }
        try await Task.sleep(for: .milliseconds(20))
        dictation.resumeStop()
        await shutdownTask.value

        // shutdown() only returns once the cancelled generation's stop() actually finished.
        #expect(dictation.stopCalls == 1)
    }

    @Test
    func realControllerWhitespaceOnlyTranscriptDoesNotOverwriteClipboard() async throws {
        // Combines the real DictationController (only its capture/transcriber/permission seams are
        // faked) with real AppState and a fake pasteboard, so the whitespace-then-empty guard is
        // exercised end to end, not just at the controller unit level.
        let capture = FakeCapture()
        let transcriber = FakeDictationTranscriber()
        transcriber.result = .success("  \n\t  ")
        let controller = DictationController(
            makeCapture: { _, _ in capture },
            requestMicrophoneAccess: { true },
            selectedMicrophoneUID: { nil },
            cache: DictationModelCache(loadTranscriber: { transcriber })
        )
        let pasteboard = FakePasteboard(initial: "sentinel")
        let state = AppState(dictationController: controller, pasteboard: pasteboard)

        await state.startDictation()
        state.requestStopDictation()
        try await waitUntil("failed") { if case .failed = state.dictationState { true } else { false } }

        guard case .failed = state.dictationState else {
            Issue.record("expected a visible failure state")
            return
        }
        #expect(pasteboard.lastWritten == "sentinel")
        #expect(transcriber.calls == ["transcribe"])
    }

    @Test
    func identicalHotKeyReRegistrationIsANoOp() {
        var registrations = 0
        let state = AppState()
        state.dictationHotKeyRegistrar = { _ in registrations += 1; return noErr }

        state.setDictationHotKey(state.dictationHotKey)

        #expect(registrations == 0)
    }

    @Test
    func failedHotKeyRegistrationKeepsPreviousWorkingShortcut() {
        let state = AppState()
        let previous = state.dictationHotKey
        state.dictationHotKeyRegistrar = { _ in OSStatus(eventNotHandledErr) }
        let candidate = DictationHotKey(keyCode: 99, carbonModifiers: UInt32(cmdKey), displayString: "⌘Z")

        state.setDictationHotKey(candidate)

        #expect(state.dictationHotKey == previous)
        #expect(state.hotKeyError != nil)
    }

    @Test
    func successfulHotKeyRegistrationUpdatesAndPersistsIsolated() {
        let suiteName = "scribe-dictation-hotkey-set-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(hotKeyDefaults: defaults)
        state.dictationHotKeyRegistrar = { _ in noErr }
        let candidate = DictationHotKey(keyCode: 99, carbonModifiers: UInt32(cmdKey), displayString: "⌘Z")

        state.setDictationHotKey(candidate)

        #expect(state.dictationHotKey == candidate)
        #expect(state.hotKeyError == nil)
        #expect(DictationHotKey.loadPersisted(from: defaults) == candidate)
    }

}

private struct WaitTimedOut: Error, CustomStringConvertible {
    let description: String
}

/// Throws (failing the calling test) if `condition` never becomes true within `timeout`, so a
/// race test can never silently pass without having reached the phase it's meant to exercise.
@MainActor
private func waitUntil(
    _ label: String = "condition",
    timeout: Duration = .seconds(2),
    file: String = #filePath,
    line: Int = #line,
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw WaitTimedOut(description: "timed out waiting for \(label) (\(file):\(line))")
        }
        await Task.yield()
    }
}

// MARK: - DictationController-level tests (real controller, fully fake I/O — no mic/permission/model)

@MainActor
struct DictationControllerTests {
    @Test
    func finalizeRunsBeforeTranscribeAndModelStaysWarmAfterSuccess() async throws {
        let capture = FakeCapture()
        let transcriber = FakeDictationTranscriber()
        transcriber.result = .success("real words")
        let controller = DictationController(
            makeCapture: { _, _ in capture },
            requestMicrophoneAccess: { true },
            selectedMicrophoneUID: { nil },
            cache: DictationModelCache(loadTranscriber: { transcriber })
        )

        try await controller.start(generation: 1)
        let text = try await controller.stop(generation: 1)

        #expect(text == "real words")
        #expect(capture.calls == ["start", "finalize"])
        // No unload on the success path any more — the model stays warm for reuse; only the idle
        // timer or shutdown ever unloads it now.
        #expect(transcriber.calls == ["transcribe"])
    }

    @Test
    func modelStaysWarmAfterFailedTranscriptionForRetry() async {
        let capture = FakeCapture()
        let transcriber = FakeDictationTranscriber()
        transcriber.result = .failure(DictationController.Error.emptyTranscript)
        let controller = DictationController(
            makeCapture: { _, _ in capture },
            requestMicrophoneAccess: { true },
            selectedMicrophoneUID: { nil },
            cache: DictationModelCache(loadTranscriber: { transcriber })
        )

        try? await controller.start(generation: 1)
        _ = try? await controller.stop(generation: 1)

        #expect(transcriber.calls == ["transcribe"])
    }

    @Test
    func whitespaceOnlyResultIsNormalizedThenRejectedWithoutUnloading() async {
        let capture = FakeCapture()
        let transcriber = FakeDictationTranscriber()
        transcriber.result = .success("  \n\t  ")
        let controller = DictationController(
            makeCapture: { _, _ in capture },
            requestMicrophoneAccess: { true },
            selectedMicrophoneUID: { nil },
            cache: DictationModelCache(loadTranscriber: { transcriber })
        )
        try? await controller.start(generation: 1)

        await #expect(throws: DictationController.Error.self) {
            try await controller.stop(generation: 1)
        }

        #expect(transcriber.calls == ["transcribe"])
    }

    @Test
    func emptyResultIsRejectedWithoutUnloading() async {
        let capture = FakeCapture()
        let transcriber = FakeDictationTranscriber()
        transcriber.result = .success("")
        let controller = DictationController(
            makeCapture: { _, _ in capture },
            requestMicrophoneAccess: { true },
            selectedMicrophoneUID: { nil },
            cache: DictationModelCache(loadTranscriber: { transcriber })
        )
        try? await controller.start(generation: 1)

        await #expect(throws: DictationController.Error.self) {
            try await controller.stop(generation: 1)
        }

        #expect(transcriber.calls == ["transcribe"])
    }

    @Test
    func checkCancellationSkipsDecodeRequestWhenAlreadyCancelledBeforeStop() async {
        // start() now also kicks off a best-effort prewarm load unconditionally, so a load can
        // legitimately happen regardless of whether stop() itself is cancelled — what must never
        // happen is an actual decode request for a cancelled stop().
        let capture = FakeCapture()
        let transcriber = FakeDictationTranscriber()
        let controller = DictationController(
            makeCapture: { _, _ in capture },
            requestMicrophoneAccess: { true },
            selectedMicrophoneUID: { nil },
            cache: DictationModelCache(loadTranscriber: { transcriber })
        )
        try? await controller.start(generation: 1)

        let task = Task { try await controller.stop(generation: 1) }
        task.cancel()
        _ = try? await task.value

        #expect(!transcriber.calls.contains("transcribe"))
    }

    @Test
    func cancellingDuringPermissionAwaitSkipsHardwareOpen() async {
        let capture = FakeCapture()
        let permission = ContinuationBox<Bool>()
        let controller = DictationController(
            makeCapture: { _, _ in capture },
            requestMicrophoneAccess: { await withCheckedContinuation { permission.store($0) } },
            selectedMicrophoneUID: { nil },
            cache: DictationModelCache(loadTranscriber: { FakeDictationTranscriber() })
        )

        let startTask = Task { try await controller.start(generation: 1) }
        while !permission.isSet { await Task.yield() }

        controller.cancel(generation: 1)
        permission.resume(returning: true)

        await #expect(throws: (any Error).self) { try await startTask.value }
        #expect(capture.calls.isEmpty)
    }

    @Test
    func startReturnsWithoutAwaitingPrewarmLoad() async throws {
        // "Begin best-effort prewarm ... without awaiting it or delaying recording UI": start()
        // must resolve while the model load is still in flight, not after it.
        let capture = FakeCapture()
        let transcriber = FakeDictationTranscriber()
        let loadGate = ContinuationBox<any DictationTranscribing>()
        let controller = DictationController(
            makeCapture: { _, _ in capture },
            requestMicrophoneAccess: { true },
            selectedMicrophoneUID: { nil },
            cache: DictationModelCache(loadTranscriber: {
                await withCheckedContinuation { loadGate.store($0) }
            })
        )

        try await controller.start(generation: 1)

        // start() already returned even though the prewarm load has not resolved yet.
        #expect(transcriber.calls.isEmpty)
        loadGate.resume(returning: transcriber)
    }

    @Test
    func prewarmedModelIsReusedByTheFollowingStop() async throws {
        let capture = FakeCapture()
        let transcriber = FakeDictationTranscriber()
        transcriber.result = .success("prewarmed result")
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let controller = DictationController(
            makeCapture: { _, _ in capture },
            requestMicrophoneAccess: { true },
            selectedMicrophoneUID: { nil },
            cache: DictationModelCache(loadTranscriber: { loadCount.withLock { $0 += 1 }; return transcriber })
        )

        try await controller.start(generation: 1)
        // Give the fire-and-forget prewarm Task a chance to actually run and finish loading.
        try await waitUntil("prewarm loaded") { loadCount.withLock { $0 } == 1 }

        let text = try await controller.stop(generation: 1)

        #expect(text == "prewarmed result")
        #expect(loadCount.withLock { $0 } == 1)
    }

    @Test
    func disconnectedMicrophoneUIDErrorsWithoutTouchingAudioEngineOrPermission() {
        // SelectedMicrophoneResolver only calls AudioObjectGetPropertyData (device-UID lookup);
        // it never constructs an AVAudioEngine or touches `.inputNode`, so this cannot trigger the
        // microphone permission prompt or any hardware access.
        #expect(throws: RecordingController.Error.self) {
            try SelectedMicrophoneResolver.resolve(uid: "definitely-not-a-real-microphone-uid")
        }
    }

    @Test
    func emptyOrMissingPersistedUIDResolvesToDefaultDeviceWithoutError() throws {
        #expect(try SelectedMicrophoneResolver.resolve(uid: nil) == nil)
        #expect(try SelectedMicrophoneResolver.resolve(uid: "") == nil)
    }
}

// MARK: - Hotkey / cleanup unit tests (no real Carbon delivery, no real UserDefaults.standard)

struct DictationHotKeyTests {
    @Test
    func hotKeyPersistsAcrossLoads() {
        let suiteName = "scribe-dictation-hotkey-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hotKey = DictationHotKey(keyCode: 3, carbonModifiers: UInt32(cmdKey | controlKey), displayString: "⌃⌘F")

        hotKey.persist(to: defaults)

        #expect(DictationHotKey.loadPersisted(from: defaults) == hotKey)
    }

    @Test
    func hotKeyFallsBackToDefaultWhenNothingIsPersisted() {
        let suiteName = "scribe-dictation-hotkey-empty-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(DictationHotKey.loadPersisted(from: defaults) == .default)
    }

    @Test
    func hotKeyFallsBackToDefaultWhenPersistedValueLacksAPrimaryModifier() {
        let suiteName = "scribe-dictation-hotkey-invalid-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let shiftOnly = DictationHotKey(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(shiftKey), displayString: "⇧D")
        shiftOnly.persist(to: defaults)

        #expect(DictationHotKey.loadPersisted(from: defaults) == .default)
    }

    @Test
    func capturingRequiresAPrimaryModifier() {
        let plain = keyEvent(modifiers: [])
        let shiftOnly = keyEvent(modifiers: [.shift])

        #expect(DictationHotKey.captured(from: plain) == nil)
        #expect(DictationHotKey.captured(from: shiftOnly) == nil)
    }

    @Test
    func capturingAcceptsCommandControlOrOption() {
        #expect(DictationHotKey.captured(from: keyEvent(modifiers: [.command])) != nil)
        #expect(DictationHotKey.captured(from: keyEvent(modifiers: [.control])) != nil)
        #expect(DictationHotKey.captured(from: keyEvent(modifiers: [.option])) != nil)
    }

    @Test
    func capturingBuildsADisplayStringFromTheModifiersPressed() {
        let event = keyEvent(modifiers: [.command, .shift])

        let hotKey = DictationHotKey.captured(from: event)

        #expect(hotKey?.displayString == "⇧⌘D")
        #expect(hotKey?.carbonModifiers == UInt32(cmdKey | shiftKey))
        #expect(hotKey?.keyCode == UInt32(kVK_ANSI_D))
    }

    private func keyEvent(modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false,
            keyCode: UInt16(kVK_ANSI_D)
        )!
    }
}

struct DictationCleanupTests {
    @Test
    func cleanupOnlyCollapsesWhitespace() {
        #expect(DictationCleanup.clean("So,   I think   we should ship it.") == "So, I think we should ship it.")
    }

    @Test
    func cleanupPreservesAcronymsAndNamesEvenWhenTheyLookLikeFillerWords() {
        let text = "Send it to UM, not them."
        #expect(DictationCleanup.clean(text) == text)
    }

    @Test
    func cleanupPreservesMultilingualAndAmbiguousTokens() {
        let text = "Uh, señor, gracias — no, wait, muchas gracias."
        #expect(DictationCleanup.clean(text) == text)
    }

    @Test
    func cleanupTrimsLeadingAndTrailingWhitespace() {
        #expect(DictationCleanup.clean("  hello world  \n") == "hello world")
    }
}

// MARK: - Hotkey install/registration gating (pure logic, no real Carbon call)

struct HotKeyRegistrationGateTests {
    @Test
    func rejectsBeforeAnyNativeCallWhenEventHandlerFailedToInstall() {
        #expect(HotKeyRegistrationGate.precondition(installStatus: OSStatus(eventNotHandledErr), hasHandler: false) == OSStatus(eventNotHandledErr))
    }

    @Test
    func rejectsWhenInstallSucceededButNoHandlerIsPresent() {
        #expect(HotKeyRegistrationGate.precondition(installStatus: noErr, hasHandler: false) == OSStatus(eventNotHandledErr))
    }

    @Test
    func allowsRegistrationOnlyWhenInstallSucceededAndAHandlerIsPresent() {
        #expect(HotKeyRegistrationGate.precondition(installStatus: noErr, hasHandler: true) == nil)
    }
}

// MARK: - AudioFileWriter write-vs-close synchronization (synthetic scratch file, no mic/engine/permission)

struct AudioFileWriterTests {
    @Test
    func writeAfterCloseIsSkippedAndNeverTouchesTheDisposedFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "scribe-writer-test-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let writer = try AudioFileWriter(url: url, format: format)

        // Simulates the exact scenario the finding describes: an audio callback that has already
        // entered `write` arriving just after `close()` disposed the file. With write's isClosed
        // check and the dispose both under the same lock, this is a deterministic no-op rather
        // than a use-after-free on the disposed ExtAudioFileRef.
        #expect(writer.close() == nil)

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16
        writer.write(buffer, hostTime: 123)

        #expect(writer.firstHostTime == nil)
        #expect(writer.failure == nil)
    }

    @Test
    func writeBeforeCloseIsRecordedNormally() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "scribe-writer-test-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let writer = try AudioFileWriter(url: url, format: format)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16

        writer.write(buffer, hostTime: 123)

        #expect(writer.firstHostTime == 123)
        #expect(writer.close() == nil)
    }
}

// MARK: - Test helpers

/// A `resume` that races ahead of its matching `store` (e.g. because a test observed some other
/// indirect side effect — a counter, an appended call — that happens a moment before the
/// continuation is actually stored) must not be dropped: it's remembered as a pending value and
/// delivered as soon as `store` runs, instead of silently no-opping and stranding that `store`'s
/// continuation forever.
final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private enum State {
        case empty
        case stored(CheckedContinuation<T, Never>)
        case pendingResume(T)
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: .empty)

    var isSet: Bool {
        lock.withLock {
            if case .stored = $0 { return true }
            return false
        }
    }

    func store(_ continuation: CheckedContinuation<T, Never>) {
        let pending: T? = lock.withLock { state in
            switch state {
            case let .pendingResume(value):
                state = .empty
                return value
            case .empty, .stored:
                state = .stored(continuation)
                return nil
            }
        }
        if let pending {
            continuation.resume(returning: pending)
        }
    }

    func resume(returning value: T) {
        let continuation: CheckedContinuation<T, Never>? = lock.withLock { state in
            switch state {
            case let .stored(continuation):
                state = .empty
                return continuation
            case .empty, .pendingResume:
                state = .pendingResume(value)
                return nil
            }
        }
        continuation?.resume(returning: value)
    }
}

// MARK: - Fakes

@MainActor
private final class FakeDictationController: DictationControlling {
    var startCalls = 0
    var stopCalls = 0
    var cancelCalls = 0
    var shutdownCalls = 0
    var startError: (any Error)?
    var stopResult: Result<String, any Error> = .success("hello world")
    var delayStart = false
    var delayStop = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?

    func start(generation: Int) async throws {
        startCalls += 1
        if delayStart {
            await withCheckedContinuation { startContinuation = $0 }
        }
        if let startError { throw startError }
    }

    func stop(generation: Int) async throws -> String {
        stopCalls += 1
        if delayStop {
            await withCheckedContinuation { stopContinuation = $0 }
        }
        return try stopResult.get()
    }

    func cancel(generation: Int) {
        cancelCalls += 1
    }

    func shutdown() async {
        shutdownCalls += 1
    }

    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func resumeStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

@MainActor
private final class FakeMeetingRecorder: RecordingControlling {
    var startCalls = 0
    var stopCalls = 0
    var delayStart = false
    var delayStop = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?

    func start(for application: MeetingApplication?, at date: Date) async throws -> RecordingSession {
        startCalls += 1
        if delayStart {
            await withCheckedContinuation { startContinuation = $0 }
        }
        return RecordingSession(id: "fake", sourceApplication: application?.name, startedAt: date, stage: .recording)
    }

    func stop(at date: Date) async throws -> RecordingSession {
        stopCalls += 1
        if delayStop {
            await withCheckedContinuation { stopContinuation = $0 }
        }
        return RecordingSession(
            id: "fake",
            sourceApplication: nil,
            startedAt: date.addingTimeInterval(-10),
            endedAt: date,
            stage: .pendingTranscription
        )
    }

    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func resumeStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

@MainActor
private final class FakePasteboard: DictationPasteboard {
    private(set) var lastWritten: String?
    var shouldFailWrite = false

    init(initial: String?) {
        lastWritten = initial
    }

    func writeText(_ text: String) -> Bool {
        guard !shouldFailWrite else { return false }
        lastWritten = text
        return true
    }
}

final class FakeCapture: DictationCapturing, @unchecked Sendable {
    private(set) var calls: [String] = []
    var startError: (any Error)?
    var finalizeFailure: String?

    func start() throws {
        calls.append("start")
        if let startError { throw startError }
    }

    func finalize() -> String? {
        calls.append("finalize")
        return finalizeFailure
    }
}

/// `isDecoding` is a reentrancy trip-wire: if the cache's serialization ever let two decodes run
/// concurrently, a second `transcribe(url:)` entering while one is still in flight would find it
/// already `true` and record a violation instead of silently racing.
final class FakeDictationTranscriber: DictationTranscribing, @unchecked Sendable {
    private struct State {
        var calls: [String] = []
        var isDecoding = false
        var overlapDetected = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    var result: Result<String, any Error> = .success("hello world")
    var delayDecode = false
    private let decodeContinuation = ContinuationBox<Void>()

    var calls: [String] { lock.withLock { $0.calls } }
    var overlapDetected: Bool { lock.withLock { $0.overlapDetected } }

    func transcribe(url: URL) async throws -> String {
        lock.withLock { state in
            if state.isDecoding { state.overlapDetected = true }
            state.isDecoding = true
            state.calls.append("transcribe")
        }
        if delayDecode {
            await withCheckedContinuation { decodeContinuation.store($0) }
        }
        lock.withLock { $0.isDecoding = false }
        return try result.get()
    }

    func resumeDecode() {
        decodeContinuation.resume(returning: ())
    }

    func unloadModels() async {
        lock.withLock { $0.calls.append("unload") }
    }
}
