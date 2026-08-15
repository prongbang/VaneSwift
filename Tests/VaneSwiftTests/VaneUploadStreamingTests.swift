import Foundation
import Testing

@testable import VaneSwift

/// Tests for `vaneStreamedUpload`, against a fake body-stream core that
/// mirrors the real contract: `write` PARKS its thread while the stream's
/// buffer is full, and only `free` (or the request's own death) releases a
/// parked write — `free` must therefore be reachable from a path that is
/// never itself parked, or cancelling an upload hangs forever. That teardown
/// ordering is design risk #2 of the upload plan and is asserted here so a
/// wrapper refactor cannot silently break it.
///
/// What these tests pin — and what they do not: they pin the WRAPPER's
/// write-pacing, teardown ordering, and error routing against injected
/// operations. The generated UniFFI calls beneath the production closures
/// and the core's own release latch are outside those tests; the glue test
/// at the end runs the real registry functions instead, and the core side is
/// covered by the Rust suite.
struct VaneUploadStreamingTests {
    enum StubError: Error {
        case appSourceFailed
    }

    /// The four operations with the real core's blocking semantics: `write`
    /// waits for a test-granted permit (an unanswered permit IS a write
    /// parked against a full send window) unless `autoAckWrites`; `free`
    /// latches, releases any parked write with the same `Cancelled` the real
    /// registry raises, and counts only once — the real registry drops the
    /// id, so a second free does not exist as an event. Waits are bounded so
    /// a lost free FAILS a test instead of hanging it.
    final class FakeUploadCore: @unchecked Sendable {
        private let condition = NSCondition()
        private var permits = 0
        private var freed = false
        private var finished = 0
        private var frees = 0
        private var writes = 0
        private var recordedEvents: [String] = []
        private let autoAckWrites: Bool
        private let writeFailure: VaneError?
        let writeParked = DispatchSemaphore(value: 0)

        init(autoAckWrites: Bool = false, writeFailure: VaneError? = nil) {
            self.autoAckWrites = autoAckWrites
            self.writeFailure = writeFailure
        }

        var events: [String] {
            condition.lock()
            defer { condition.unlock() }
            return recordedEvents
        }

        var writesStarted: Int {
            condition.lock()
            defer { condition.unlock() }
            return writes
        }

        var finishCalls: Int {
            condition.lock()
            defer { condition.unlock() }
            return finished
        }

        var freeCalls: Int {
            condition.lock()
            defer { condition.unlock() }
            return frees
        }

        func ackOneWrite() {
            condition.lock()
            permits += 1
            condition.broadcast()
            condition.unlock()
        }

        func write(_ chunk: Data) throws {
            condition.lock()
            writes += 1
            if let writeFailure {
                recordedEvents.append("writeFailed")
                condition.unlock()
                throw writeFailure
            }
            if autoAckWrites {
                recordedEvents.append("write")
                condition.unlock()
                return
            }
            if permits == 0 && !freed {
                recordedEvents.append("writeParked")
                writeParked.signal()
            }
            let deadline = Date().addingTimeInterval(5)
            while permits == 0 && !freed {
                guard condition.wait(until: deadline) else {
                    recordedEvents.append("parkExpired")
                    condition.unlock()
                    throw VaneError.Generic(
                        "parked write was never released — the wrapper lost the free path")
                }
            }
            if freed {
                recordedEvents.append("writeReleasedByFree")
                condition.unlock()
                throw VaneError.Cancelled("Request body stream was freed before finish()")
            }
            permits -= 1
            recordedEvents.append("write")
            condition.unlock()
        }

        func finish() throws {
            condition.lock()
            finished += 1
            recordedEvents.append("finish")
            condition.unlock()
        }

        func free() {
            condition.lock()
            if freed {
                condition.unlock()
                return
            }
            freed = true
            frees += 1
            recordedEvents.append("free")
            condition.broadcast()
            condition.unlock()
        }

        /// The induced request abort: waits until `free`, like a transport
        /// whose next pull finds the latch, then fails the request with the
        /// same `Cancelled` the real core raises. Bounded so a lost free
        /// fails the test (well past the promptness assertion) instead of
        /// hanging it.
        func awaitFreedThenThrowCancelled() async throws -> Never {
            var waited = 0.0
            while waited < 5.0 {
                condition.lock()
                let isFreed = freed
                condition.unlock()
                if isFreed { throw VaneError.Cancelled("Request was cancelled") }
                try? await Task.sleep(nanoseconds: 10_000_000)
                waited += 0.01
            }
            throw VaneError.Generic("the request was never aborted — free never fired")
        }
    }

    /// Design risk #2: cancelling an upload whose write is parked in the FFI
    /// must reach `free` from a never-parked path — free is the only thing
    /// that releases the write — and return promptly. The naive spelling
    /// (a bare `vaneBlockingFFI` write with no cancellation handler, and an
    /// execute with no `onCancel` free) parks until the fake's 5 s bail-out:
    /// cancellation has no path to the free that would release anything.
    @Test
    func cancellingAnUploadWhoseWriteIsParkedFreesTheStreamPromptly() async throws {
        let fake = FakeUploadCore()
        let consumer = Task {
            try await vaneStreamedUpload(
                source: AsyncStream(unfolding: { Data([1]) }),
                write: { chunk in try fake.write(chunk) },
                finish: { try fake.finish() },
                free: { fake.free() },
                execute: { try await fake.awaitFreedThenThrowCancelled() }
            )
        }
        #expect(
            fake.writeParked.wait(timeout: .now() + 2) == .success,
            "the writer never reached its blocking write"
        )
        let started = Date()
        consumer.cancel()
        let outcome = await consumer.result
        let elapsed = Date().timeIntervalSince(started)
        #expect(
            elapsed < 1.5,
            "cancel took \(elapsed)s — free did not reach the parked write"
        )
        guard case .failure = outcome else {
            Issue.record("an upload cancelled mid-write must not report success")
            return
        }
        #expect(
            fake.events == ["writeParked", "free", "writeReleasedByFree"],
            "teardown order was \(fake.events)"
        )
        #expect(fake.freeCalls == 1, "the registry frees an id exactly once")
    }

    /// The write direction's backpressure discriminator, the twin of the
    /// download side's read-ahead test: the SOURCE'S PRODUCTION COUNT must
    /// stay in lockstep with acknowledged writes. An implementation that
    /// pumps the source through a buffering task lets the counting sequence
    /// race ahead — the unbounded buffer the design forbids. Ends cleanly to
    /// also pin the terminal order: every chunk written once, then finish,
    /// then free, and the execute result comes back.
    @Test
    func theSourceIsHeldToOneWriteInFlightAndACleanFinishStillFrees() async throws {
        let fake = FakeUploadCore()
        let produced = VaneUploadCounterBox()
        let source = AsyncStream<Data>(unfolding: {
            let pulls = produced.increment()
            return pulls <= 12 ? Data([UInt8(pulls)]) : nil
        })
        let consumer = Task {
            try await vaneStreamedUpload(
                source: source,
                write: { chunk in try fake.write(chunk) },
                finish: { try fake.finish() },
                free: { fake.free() },
                execute: { () async throws -> String in
                    // The request outlives the writer, then settles cleanly.
                    var waited = 0.0
                    while fake.finishCalls == 0 && waited < 5.0 {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                        waited += 0.01
                    }
                    return "response"
                }
            )
        }
        for acked in 0..<12 {
            var waited = 0.0
            while fake.writesStarted < acked + 1 && waited < 5.0 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                waited += 0.01
            }
            #expect(
                fake.writesStarted == acked + 1,
                "writes must not run ahead of acks — backpressure lost"
            )
            // Give an eager pump every chance to run ahead before looking:
            // the counting source may sit one pull past the chunk in flight,
            // never further.
            try await Task.sleep(nanoseconds: 20_000_000)
            #expect(
                produced.value <= acked + 2,
                "the source produced \(produced.value) chunks with only \(acked) acked — buffering"
            )
            fake.ackOneWrite()
        }
        let response = try await consumer.value
        #expect(response == "response")
        #expect(fake.writesStarted == 12)
        #expect(fake.finishCalls == 1)
        #expect(fake.freeCalls == 1, "a clean finish still releases the id")
        #expect(
            fake.events.suffix(2) == ["finish", "free"],
            "finish must come after the last write, free after finish; got \(fake.events)"
        )
        #expect(!fake.events.contains("writeReleasedByFree"), "nothing aborts on a clean run")
    }

    /// A failure of the caller's own source aborts the upload; the abort
    /// fails the request as `Cancelled`, and the source's error — the actual
    /// story — must replace that induced error on the way out.
    @Test
    func aSourceFailureAbortsTheUploadAndReplacesTheInducedCancelled() async throws {
        let fake = FakeUploadCore(autoAckWrites: true)
        let pulls = VaneUploadCounterBox()
        let source = AsyncThrowingStream<Data, Error>(unfolding: {
            if pulls.increment() == 1 { return Data([1]) }
            throw StubError.appSourceFailed
        })
        do {
            _ = try await vaneStreamedUpload(
                source: source,
                write: { chunk in try fake.write(chunk) },
                finish: { try fake.finish() },
                free: { fake.free() },
                execute: { try await fake.awaitFreedThenThrowCancelled() }
            )
            Issue.record("expected the source's own error to be thrown")
        } catch StubError.appSourceFailed {
            // The story, not the induced Cancelled.
        }
        #expect(fake.finishCalls == 0, "an errored body must never finish")
        #expect(fake.freeCalls == 1, "the abort is the free")
    }

    /// A write the core fails carries the request's own error; the writer
    /// must stop quietly — no re-report — and the execute result stays
    /// authoritative. A dead upload must also stop pulling from the source.
    @Test
    func aCoreFailedWriteStopsTheWriterQuietlyAndTheExecuteResultIsAuthoritative() async throws {
        let fake = FakeUploadCore(writeFailure: VaneError.Timeout("request timed out"))
        let produced = VaneUploadCounterBox()
        let source = AsyncStream<Data>(unfolding: {
            let pulls = produced.increment()
            return pulls <= 50 ? Data([1]) : nil
        })
        do {
            _ = try await vaneStreamedUpload(
                source: source,
                write: { chunk in try fake.write(chunk) },
                finish: { try fake.finish() },
                free: { fake.free() },
                execute: { try await fake.awaitFreedThenThrowCancelled() }
            )
            Issue.record("expected the execute result's error")
        } catch let error as VaneError {
            guard case .Cancelled = error else {
                Issue.record("expected the induced Cancelled from execute, got \(error)")
                return
            }
        }
        #expect(
            produced.value <= 2,
            "a dead upload must stop pulling from the source, produced \(produced.value)"
        )
        #expect(fake.finishCalls == 0)
        #expect(fake.freeCalls == 1)
    }

    /// The production glue against the REAL native registry: the id it
    /// creates rides the request, the body is written and finished through
    /// the real generated calls, and — probed through the registry itself —
    /// the id is gone after the call returns, so the glue's terminal free
    /// really fired.
    @Test
    func streamedUploadGlueRunsTheRealRegistryAndFreesTheIdOnCompletion() async throws {
        let captured = VaneUploadCapturedRequestBox()
        let response = try await vaneRunStreamedUpload(
            source: AsyncStream<Data>(unfolding: {
                let pulls = captured.pulls.increment()
                return pulls <= 3 ? Data([UInt8(pulls)]) : nil
            }),
            contentLength: 3,
            request: VaneRequest(
                url: "https://example.com/upload",
                method: "POST",
                headers: [:],
                queryParams: [:],
                body: nil,
                bodyFilePath: nil,
                responseBodyPath: nil,
                cancelTokenId: nil,
                progressId: nil,
                timeoutSeconds: nil,
                followRedirects: true
            )
        ) { streamed in
            captured.request = streamed
            // Three 1-byte writes against an unattached registry stream
            // return in microseconds (the 256 KiB buffer absorbs them), so
            // this generous pause stands in for a transport draining the
            // upload before answering. The assertions below hold even if the
            // writer were somehow still mid-flight: the glue's terminal free
            // runs before this call returns either way.
            try? await Task.sleep(nanoseconds: 300_000_000)
            return VaneResponse(
                statusCode: 200,
                headers: [:],
                body: Data(),
                isSuccess: true,
                url: streamed.url
            )
        }
        #expect(response.isSuccess)
        let streamId = try #require(captured.request?.bodyStreamId)
        #expect(streamId != 0)
        // The registry probe: a freed id no longer exists, so finish must
        // fail with the unknown-id error. If the glue's terminal free never
        // fired, this finish returns Ok and the expectation fails.
        #expect(throws: VaneError.self) {
            try finishBodyStream(id: streamId)
        }
    }
}

/// Tiny locked counter for the demand-driven sources above.
final class VaneUploadCounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

final class VaneUploadCapturedRequestBox: @unchecked Sendable {
    var request: VaneRequest?
    let pulls = VaneUploadCounterBox()
}
