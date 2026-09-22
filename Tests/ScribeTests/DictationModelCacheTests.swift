import Foundation
import Testing
import os
@testable import Scribe

/// No hardware, no permission, no real WhisperKit, and no real 5-minute wait: everything here
/// exercises the real `DictationModelCache` against a fake transcriber loader and a fake,
/// manually-fireable sleeper standing in for the idle-eviction clock.
struct DictationModelCacheTests {
    @Test
    func prewarmLoadsOnceAndTheFollowingDecodeReusesIt() async {
        let transcriber = FakeDictationTranscriber()
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let cache = DictationModelCache(loadTranscriber: { loadCount.withLock { $0 += 1 }; return transcriber })

        await cache.prewarm()
        _ = try? await cache.transcribe(url: scratchURL())

        #expect(loadCount.withLock { $0 } == 1)
        #expect(transcriber.calls == ["transcribe"])
    }

    @Test
    func concurrentPrewarmAndTranscribeCoalesceIntoOneLoad() async throws {
        let transcriber = FakeDictationTranscriber()
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let loadGate = ContinuationBox<any DictationTranscribing>()
        let cache = DictationModelCache(loadTranscriber: {
            loadCount.withLock { $0 += 1 }
            return await withCheckedContinuation { loadGate.store($0) }
        })

        let prewarmTask = Task { await cache.prewarm() }
        let transcribeTask = Task { try await cache.transcribe(url: scratchURL()) }
        try await waitUntilLoadRequested(loadCount)
        // Both callers are now waiting on the same in-flight load — resolve it once.
        loadGate.resume(returning: transcriber)

        await prewarmTask.value
        _ = try await transcribeTask.value

        #expect(loadCount.withLock { $0 } == 1)
    }

    @Test
    func secondTranscribeReusesTheWarmModelWithoutReloading() async throws {
        let transcriber = FakeDictationTranscriber()
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let cache = DictationModelCache(loadTranscriber: { loadCount.withLock { $0 += 1 }; return transcriber })

        _ = try await cache.transcribe(url: scratchURL())
        _ = try await cache.transcribe(url: scratchURL())

        #expect(loadCount.withLock { $0 } == 1)
        #expect(transcriber.calls == ["transcribe", "transcribe"])
    }

    @Test
    func decodesAreSerializedAndNeverOverlap() async throws {
        let transcriber = FakeDictationTranscriber()
        transcriber.delayDecode = true
        let cache = DictationModelCache(loadTranscriber: { transcriber })

        let first = Task { try await cache.transcribe(url: scratchURL()) }
        try await waitUntilCallCount(transcriber, 1)
        let second = Task { try await cache.transcribe(url: scratchURL()) }
        // Give the second request every chance to (wrongly) start decoding before the first
        // finishes; the fake's reentrancy trip-wire would catch it if the cache failed to
        // serialize them.
        try await Task.sleep(for: .milliseconds(30))
        transcriber.resumeDecode()
        _ = try await first.value
        transcriber.resumeDecode()
        _ = try await second.value

        #expect(!transcriber.overlapDetected)
        #expect(transcriber.calls == ["transcribe", "transcribe"])
    }

    @Test
    func idleEvictionFiresAfterTheConfiguredTimeoutOnceDemandDrops() async throws {
        let transcriber = FakeDictationTranscriber()
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let sleeper = FakeSleeper()
        let cache = DictationModelCache(
            loadTranscriber: { loadCount.withLock { $0 += 1 }; return transcriber },
            idleTimeout: .seconds(300),
            sleeper: sleeper
        )

        _ = try await cache.transcribe(url: scratchURL())
        try await waitUntilSleepRequested(sleeper)
        #expect(sleeper.lastRequestedDuration == .seconds(300))

        sleeper.fireAll()
        try await waitUntilCallCount(transcriber, 2, expecting: "unload") // "transcribe","unload"

        // A decode after eviction must reload.
        _ = try await cache.transcribe(url: scratchURL())
        #expect(loadCount.withLock { $0 } == 2)
    }

    @Test
    func newDemandCancelsAnAlreadyScheduledIdleTimer() async throws {
        let transcriber = FakeDictationTranscriber()
        let sleeper = FakeSleeper()
        let cache = DictationModelCache(loadTranscriber: { transcriber }, sleeper: sleeper)

        _ = try await cache.transcribe(url: scratchURL())
        try await waitUntilSleepRequested(sleeper)

        // New demand (another decode) arrives before the timer fires.
        _ = try await cache.transcribe(url: scratchURL())

        #expect(sleeper.cancelledCount >= 1)
        #expect(transcriber.calls == ["transcribe", "transcribe"])
    }

    @Test
    func cancelledRecordingDemandStillAllowsEvictionOncePrewarmFinishesLater() async throws {
        let transcriber = FakeDictationTranscriber()
        let loadGate = ContinuationBox<any DictationTranscribing>()
        let sleeper = FakeSleeper()
        let cache = DictationModelCache(
            loadTranscriber: { await withCheckedContinuation { loadGate.store($0) } },
            sleeper: sleeper
        )

        await cache.beginDemand() // simulates "recording started"
        let prewarmTask = Task { await cache.prewarm() }
        try await Task.sleep(for: .milliseconds(20))

        await cache.endDemand() // simulates "recording cancelled" — prewarm's own demand remains
        #expect(sleeper.pendingCount == 0) // still no timer: prewarm's load hasn't resolved yet

        loadGate.resume(returning: transcriber)
        await prewarmTask.value

        try await waitUntilSleepRequested(sleeper) // now that prewarm is done, eviction can be scheduled
    }

    @Test
    func failedPrewarmNeverThrowsAndTheNextTranscribeRetries() async throws {
        struct LoadFailure: Error {}
        let transcriber = FakeDictationTranscriber()
        let attempt = OSAllocatedUnfairLock(initialState: 0)
        let cache = DictationModelCache(loadTranscriber: {
            let count = attempt.withLock { state -> Int in
                state += 1
                return state
            }
            if count == 1 { throw LoadFailure() }
            return transcriber
        })

        await cache.prewarm() // fails silently, does not throw, does not crash

        let text = try await cache.transcribe(url: scratchURL())

        #expect(text == "hello world")
        #expect(attempt.withLock { $0 } == 2)
    }

    @Test
    func shutdownUnloadsAPrewarmOnlySessionThatNeverDecoded() async throws {
        let transcriber = FakeDictationTranscriber()
        let cache = DictationModelCache(loadTranscriber: { transcriber })

        await cache.prewarm()
        await cache.shutdown()

        #expect(transcriber.calls == ["unload"])
    }

    @Test
    func shutdownDrainsAnInFlightDecodeBeforeUnloadingExactlyOnce() async throws {
        let transcriber = FakeDictationTranscriber()
        transcriber.delayDecode = true
        let cache = DictationModelCache(loadTranscriber: { transcriber })

        let decodeTask = Task { try await cache.transcribe(url: scratchURL()) }
        try await waitUntilCallCount(transcriber, 1)

        let shutdownTask = Task { await cache.shutdown() }
        try await Task.sleep(for: .milliseconds(30))
        transcriber.resumeDecode()

        _ = try await decodeTask.value
        await shutdownTask.value
        await cache.shutdown() // idempotent

        #expect(transcriber.calls == ["transcribe", "unload"])
    }

    @Test
    func cancellingAQueuedDecodeSkipsItsTranscribeCallAndLetsTheNextOneProceed() async throws {
        // Regression for: an unstructured queued Task didn't inherit its caller's cancellation, so
        // a decode cancelled while still queued behind a blocked load could still run to
        // completion ahead of the very session that superseded it.
        let transcriberB = FakeDictationTranscriber()
        transcriberB.result = .success("op B result")
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let loadGate = ContinuationBox<any DictationTranscribing>()
        let cache = DictationModelCache(loadTranscriber: {
            loadCount.withLock { $0 += 1 }
            return await withCheckedContinuation { loadGate.store($0) }
        })

        // Block the very first load (simulating prewarm still in flight, or A's own load).
        let prewarmTask = Task { await cache.prewarm() }
        try await waitUntilLoadRequested(loadCount)

        // Enqueue A's decode behind the blocked load, then cancel A before it can ever run.
        let taskA = Task { try await cache.transcribe(url: scratchURL()) }
        try await Task.sleep(for: .milliseconds(30)) // let A genuinely enqueue behind the load
        taskA.cancel()

        // Enqueue B after cancelling A — it must be served by the one shared (already-requested) load.
        let taskB = Task { try await cache.transcribe(url: scratchURL()) }

        loadGate.resume(returning: transcriberB)
        await prewarmTask.value
        _ = try? await taskA.value
        let resultB = try await taskB.value

        #expect(resultB == "op B result")
        // Only B's decode ever actually ran — A's was skipped once its turn came up cancelled.
        #expect(transcriberB.calls == ["transcribe"])
        #expect(loadCount.withLock { $0 } == 1)

        await cache.shutdown()
        #expect(transcriberB.calls == ["transcribe", "unload"])
    }

    @Test
    func cancellingBeforeEnqueueingNeverCallsTranscribe() async throws {
        let transcriber = FakeDictationTranscriber()
        let cache = DictationModelCache(loadTranscriber: { transcriber })

        let task = Task { try await cache.transcribe(url: scratchURL()) }
        task.cancel()
        _ = try? await task.value

        #expect(transcriber.calls.isEmpty)
    }

    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "scribe-cache-test-\(UUID()).caf")
    }

    private func waitUntilLoadRequested(
        _ counter: OSAllocatedUnfairLock<Int>,
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while counter.withLock({ $0 }) == 0 {
            guard ContinuousClock.now < deadline else { throw WaitTimedOut(description: "load never requested") }
            await Task.yield()
        }
    }

    private func waitUntilCallCount(
        _ transcriber: FakeDictationTranscriber,
        _ count: Int,
        expecting label: String = "",
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while transcriber.calls.count < count {
            guard ContinuousClock.now < deadline else {
                throw WaitTimedOut(description: "expected \(count) calls\(label.isEmpty ? "" : " (\(label))"), got \(transcriber.calls)")
            }
            await Task.yield()
        }
    }

    private func waitUntilSleepRequested(_ sleeper: FakeSleeper, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while sleeper.pendingCount == 0 {
            guard ContinuousClock.now < deadline else { throw WaitTimedOut(description: "idle timer never armed") }
            await Task.yield()
        }
    }
}

private struct WaitTimedOut: Error, CustomStringConvertible {
    let description: String
}

/// Stands in for the real clock behind `DictationModelCache`'s idle timer. `sleep(for:)` never
/// actually waits — it suspends until the test calls `fireAll()`, or resumes with
/// `CancellationError` if the owning Task is cancelled (mirroring real `Task.sleep`), so
/// `beginDemand()`'s `idleTask?.cancel()` genuinely interrupts a pending fake sleep too.
final class FakeSleeper: DictationSleeping, @unchecked Sendable {
    private struct State {
        var pending: [UUID: CheckedContinuation<Void, any Error>] = [:]
        var lastRequestedDuration: Duration?
        var cancelledCount = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var pendingCount: Int { lock.withLock { $0.pending.count } }
    var lastRequestedDuration: Duration? { lock.withLock { $0.lastRequestedDuration } }
    var cancelledCount: Int { lock.withLock { $0.cancelledCount } }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        lock.withLock { $0.lastRequestedDuration = duration }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { $0.pending[id] = continuation }
            }
        } onCancel: { [lock] in
            let continuation = lock.withLock { state -> CheckedContinuation<Void, any Error>? in
                defer {
                    if state.pending.removeValue(forKey: id) != nil { state.cancelledCount += 1 }
                }
                return state.pending[id]
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func fireAll() {
        let continuations = lock.withLock { state -> [CheckedContinuation<Void, any Error>] in
            defer { state.pending.removeAll() }
            return Array(state.pending.values)
        }
        for continuation in continuations { continuation.resume() }
    }
}
