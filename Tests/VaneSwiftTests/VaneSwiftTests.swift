import Foundation
import Testing

@testable import VaneSwift

#if canImport(Alamofire)
    import Alamofire
#endif

#if canImport(Darwin)
    import Darwin
#endif

#if canImport(Darwin)
    private func currentMallocUsageInBytes() -> UInt64? {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return UInt64(stats.size_in_use)
    }
#else
    private func currentMallocUsageInBytes() -> UInt64? { nil }
#endif

struct VaneSwiftTests {
    private let baseURL = ProcessInfo.processInfo.environment["VANE_TEST_BASE_URL"]
    private let runBenchmarks = ProcessInfo.processInfo.environment["VANE_RUN_BENCHMARKS"] == "1"
    private let warmups = 10
    private let iterations = 100

    private func integrationBaseURL() -> String? {
        guard let baseURL, baseURL.hasPrefix("https://") else {
            print("Skipping Vane integration test. Set VANE_TEST_BASE_URL to an HTTPS endpoint with HTTP/3 enabled.")
            return nil
        }

        return baseURL
    }

    private func shouldRunBenchmarks() -> Bool {
        guard runBenchmarks else {
            print("Skipping Vane benchmark tests. Set VANE_RUN_BENCHMARKS=1 to enable them.")
            return false
        }

        return true
    }

    final class CapturedRequestBox: @unchecked Sendable {
        var request: VaneRequest?
    }

    final class ProgressBox: @unchecked Sendable {
        var upload: (sent: UInt64, total: UInt64)?
        var download: (received: UInt64, total: UInt64)?
    }

    private func runBenchmark(
        summaryName: String,
        labelPrefix: String,
        iterations: Int,
        warmups: Int = 0,
        operations: [(label: String, action: () async throws -> Void)]
    ) async throws {
        var measurements: [(label: String, elapsed: TimeInterval, bytes: UInt64?)] = []

        for (label, action) in operations {
            if warmups > 0 {
                for _ in 0..<warmups {
                    try await action()
                }
            }

            let memBefore = currentMallocUsageInBytes()
            let start = Date()
            for _ in 0..<iterations {
                try await action()
            }
            let elapsed = Date().timeIntervalSince(start)
            let memAfter = currentMallocUsageInBytes()
            let bytesUsed = memAfter.flatMap { after in
                memBefore.flatMap { before in
                    after >= before ? after - before : nil
                }
            }
            measurements.append((label, elapsed, bytesUsed))
        }

        print("\n\(summaryName) summary:")
        for (label, elapsed, bytesUsed) in measurements {
            let name = "Benchmark\(labelPrefix)\(label)"
            let paddedName = name.padding(toLength: 24, withPad: " ", startingAt: 0)
            let nsPerOp = (elapsed / Double(iterations)) * 1_000_000_000
            let bytesColumn: String
            if let bytes = bytesUsed {
                bytesColumn = String(format: "%9.1f B/op", Double(bytes) / Double(iterations))
            } else {
                bytesColumn = "   n/a B/op"
            }
            let formattedLine = String(
                format: "%@%6d\t%9.0f ns/op\t%@\t(total %.3fs)",
                paddedName as NSString,
                iterations,
                nsPerOp,
                bytesColumn,
                elapsed
            )
            print(formattedLine)
        }
    }

    @Test
    func get() async throws {
        guard let baseURL = integrationBaseURL() else { return }
        let session = try VaneSession()
        let response = try await session.get("\(baseURL)/get")
        print("response[get]: \(response)")
    }

    @Test
    func http3OnlyGet() async throws {
        guard let baseURL = integrationBaseURL() else { return }
        let config = VaneConfigurationBuilder()
            .http3Only()
            .timeout(30)
            .build()
        let session = try VaneSession(configuration: config)
        let response = try await session.get("\(baseURL)/get")

        #expect(response.isSuccess)
    }

    @Test
    func warmupIsBestEffortAndNeverThrows() async throws {
        // Http3Only with no baseURL and no url: the no-op path. The contract
        // under test is that warmup can never throw — failures are swallowed
        // by the core — and that repeat calls are safe.
        let session = try VaneSession(
            configuration: VaneConfigurationBuilder()
                .http3Only()
                .timeout(2)
                .build()
        )
        await session.warmup()
        // A URL the core refuses (not https) is swallowed, not thrown.
        await session.warmup("http://example.com/")
        // Repeat calls stay cheap and equally silent.
        await session.warmup()

        // Same contract on the client-level async API.
        let client = try createVaneClient(
            config: VaneConfigurationBuilder()
                .http3Only()
                .timeout(2)
                .build()
        )
        await client.warmup()
        await client.warmup("not a url")
    }

    @Test
    func post() async throws {
        guard let baseURL = integrationBaseURL() else { return }
        let config = VaneConfigurationBuilder()
            .baseURL(baseURL)
            .defaultHeaders(["Authorization": "Bearer token"])
            .timeout(30)
            .build()

        let session = try VaneSession(configuration: config)
        let response = try await session.post(
            "/post", body: "{\"message\": \"post\"}".data(using: .utf8))
        print("response[post]: \(response)")
    }

    @Test
    func interceptorsApplyToRequestBuilderPaths() async throws {
        let config = VaneConfigurationBuilder()
            .http3Only()
            .build()
        let session = try VaneSession(
            configuration: config,
            requestInterceptors: [
                { request in
                    var request = request
                    request.headers["Authorization"] = "Bearer intercepted"
                    request.queryParams["source"] = "interceptor"
                    return request
                }
            ],
            responseInterceptors: [
                { response in
                    var response = response
                    response.headers["x-intercepted"] = "true"
                    return response
                }
            ],
            errorInterceptors: [
                { _ in
                    VaneResponse(
                        statusCode: 299,
                        headers: [:],
                        body: Data("synthetic".utf8),
                        isSuccess: true,
                        url: "interceptor://synthetic"
                    )
                }
            ]
        )

        let response = try await session.request("http://example.com/get")
            .header("Accept", "application/json")
            .execute()

        #expect(response.statusCode == 299)
        #expect(response.headers["x-intercepted"] == "true")
        #expect(String(data: response.body, encoding: .utf8) == "synthetic")
    }

    @Test
    func configurationBuilderSetsProxyOptions() throws {
        let config = VaneConfigurationBuilder()
            .proxy("http://proxy.example.com:8080", authorization: "Basic dXNlcjpwYXNz")
            .build()

        #expect(config.proxyUrl == "http://proxy.example.com:8080")
        #expect(config.proxyAuthorization == "Basic dXNlcjpwYXNz")
    }

    @Test
    func requestInterceptorFailuresProduceStableErrors() async throws {
        enum TestInterceptorError: Error {
            case blocked
        }

        let session = try VaneSession(
            requestInterceptors: [
                { _ in throw TestInterceptorError.blocked }
            ]
        )

        do {
            _ = try await session.get("http://example.com/get")
            Issue.record("Expected request interceptor to throw")
        } catch TestInterceptorError.blocked {
            return
        }
    }

    @Test
    func interceptorsCanBeAddedAndClearedAfterSessionCreation() async throws {
        let captured = CapturedRequestBox()
        let session = try VaneSession(
            configuration: VaneConfigurationBuilder().http3Only().build(),
            errorInterceptors: [
                { _ in
                    VaneResponse(
                        statusCode: 204,
                        headers: [:],
                        body: Data(),
                        isSuccess: true,
                        url: "interceptor://synthetic"
                    )
                }
            ]
        )

        session
            .addRequestInterceptor { request in
                var request = request
                request.headers["x-late"] = "1"
                captured.request = request
                return request
            }
            .addResponseInterceptor { response in
                var response = response
                response.headers["x-response"] = "1"
                return response
            }

        let response = try await session.get("http://example.com/late")

        #expect(captured.request?.headers["x-late"] == "1")
        #expect(response.headers["x-response"] == "1")

        session.clearInterceptors()
        captured.request = nil

        do {
            _ = try await session.get("http://example.com/clear")
            Issue.record("Expected clearInterceptors to remove synthetic error handling")
        } catch {
            #expect(captured.request == nil)
        }
    }

    @Test
    func certificatePinsCanBeUpdatedAfterSessionCreation() throws {
        let session = try VaneSession(configuration: VaneConfigurationBuilder().http3Only().build())

        try session
            .setCertificatePins(
                host: "api.example.com",
                pins: ["sha256/current", "sha256/backup"]
            )
            .addCertificatePin(host: "api.example.com", pin: "sha256-cert/current")
            .clearCertificatePins(host: "api.example.com")
    }

    @Test
    func requestBodyHelpersBuildTextAndFormRequests() async throws {
        let captured = CapturedRequestBox()
        let session = try VaneSession(
            configuration: VaneConfigurationBuilder().http3Only().build(),
            requestInterceptors: [
                { request in
                    captured.request = request
                    return request
                }
            ],
            errorInterceptors: [
                { _ in
                    VaneResponse(
                        statusCode: 204,
                        headers: [:],
                        body: Data(),
                        isSuccess: true,
                        url: "interceptor://synthetic"
                    )
                }
            ]
        )

        _ = try await session.request("http://example.com/post", method: .post)
            .textBody("hello")
            .execute()

        #expect(captured.request?.headers["Content-Type"] == "text/plain; charset=utf-8")
        #expect(captured.request?.body == Data("hello".utf8))

        _ = try await session.request("http://example.com/post", method: .post)
            .formBody(["space": "hello world", "token": "a&b"])
            .execute()

        #expect(captured.request?.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(String(data: captured.request?.body ?? Data(), encoding: .utf8) == "space=hello+world&token=a%26b")
    }

    @Test
    func multipartAndProgressHelpersDecorateRequests() async throws {
        let captured = CapturedRequestBox()
        let session = try VaneSession(
            configuration: VaneConfigurationBuilder().http3Only().build(),
            requestInterceptors: [
                { request in
                    captured.request = request
                    return request
                }
            ],
            errorInterceptors: [
                { _ in
                    VaneResponse(
                        statusCode: 204,
                        headers: [:],
                        body: Data(),
                        isSuccess: true,
                        url: "interceptor://synthetic"
                    )
                }
            ]
        )

        let progress = ProgressBox()
        _ = try await session.request("http://example.com/upload", method: .post)
            .multipart(
                fields: ["title": "avatar"],
                files: [
                    VaneMultipartFile(
                        fieldName: "photo",
                        data: Data([1, 2, 3]),
                        fileName: "me.jpg",
                        contentType: "image/jpeg"
                    )
                ]
            )
            .downloadToFile("/tmp/result.json")
            .onUploadProgress { sent, total in
                progress.upload = (sent, total)
            }
            .onDownloadProgress { received, total in
                progress.download = (received, total)
            }
            .execute()

        let contentType = captured.request?.headers["Content-Type"] ?? ""
        let body = String(data: captured.request?.body ?? Data(), encoding: .utf8) ?? ""
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        #expect(body.contains("name=\"title\""))
        #expect(body.contains("name=\"photo\"; filename=\"me.jpg\""))
        #expect(body.contains("Content-Type: image/jpeg"))
        #expect(captured.request?.responseBodyPath == "/tmp/result.json")
        #expect(captured.request?.progressId != nil)
        #expect(progress.upload != nil)
        #expect(progress.download != nil)
    }

    // MARK: - Streaming

    /// `VaneResponseStreamProtocol` stand-in mirroring the core's contract:
    /// `readChunk` holds the stream's lock while it blocks, `closeStream`
    /// must wait for that lock, and only the cancel token makes a parked
    /// read return.
    final class FakeResponseStream: VaneResponseStreamProtocol, @unchecked Sendable {
        /// Mirrors the core's stream mutex: held for the whole of a read.
        private let streamLock = NSLock()
        /// Signalled by the fake token; releases a parked read.
        private let interrupted = DispatchSemaphore(value: 0)
        /// Signalled when a read has entered its parked wait.
        let readParked = DispatchSemaphore(value: 0)
        private let stateLock = NSLock()
        private var remaining: [Data]
        private let failure: VaneError?
        private let blockAfterChunks: Bool
        private var recordedEvents: [String] = []
        private var reads = 0

        init(
            chunks: [Data] = [],
            failure: VaneError? = nil,
            blockAfterChunks: Bool = false
        ) {
            self.remaining = chunks
            self.failure = failure
            self.blockAfterChunks = blockAfterChunks
        }

        func note(_ event: String) {
            stateLock.lock()
            recordedEvents.append(event)
            stateLock.unlock()
        }

        var events: [String] {
            stateLock.lock()
            defer { stateLock.unlock() }
            return recordedEvents
        }

        var readsStarted: Int {
            stateLock.lock()
            defer { stateLock.unlock() }
            return reads
        }

        func interrupt() {
            interrupted.signal()
        }

        func head() -> VaneResponse {
            VaneResponse(
                statusCode: 200,
                headers: [:],
                body: Data(),
                isSuccess: true,
                url: "https://example.com/stream"
            )
        }

        func readChunk() throws -> Data? {
            streamLock.lock()
            defer { streamLock.unlock() }
            stateLock.lock()
            reads += 1
            let next = remaining.isEmpty ? nil : remaining.removeFirst()
            stateLock.unlock()
            if let next {
                return next
            }
            if let failure {
                throw failure
            }
            if blockAfterChunks {
                note("readParked")
                readParked.signal()
                guard interrupted.wait(timeout: .now() + 5) == .success else {
                    note("parkExpired")
                    throw VaneError.Generic("parked read was never interrupted — the wrapper lost the cancel token")
                }
                note("readReturnedAfterCancel")
                throw VaneError.Cancelled("Request was cancelled")
            }
            return nil
        }

        func closeStream() {
            // A close issued while a read is parked would sit here for the
            // whole 5 s park and fail the promptness assertion.
            streamLock.lock()
            defer { streamLock.unlock() }
            note("close")
        }
    }

    /// Design risk #3: cancelling a consumer whose read is parked in the FFI
    /// must fire the cancel token first (the only thing that releases the
    /// read), close strictly afterwards, and return promptly.
    @Test
    func cancellingABlockedStreamingReadFiresTheTokenThenClosesPromptly() async throws {
        let fake = FakeResponseStream(blockAfterChunks: true)
        let body = vaneStreamingBody(
            stream: fake,
            cancelToken: {
                fake.note("cancelToken")
                fake.interrupt()
            }
        )
        let consumer = Task {
            for try await _ in body {}
        }
        #expect(
            fake.readParked.wait(timeout: .now() + 2) == .success,
            "the pull never reached its blocking read"
        )
        let started = Date()
        consumer.cancel()
        let outcome = await consumer.result
        let elapsed = Date().timeIntervalSince(started)
        #expect(
            elapsed < 1.5,
            "cancel took \(elapsed)s — the token did not interrupt the parked read"
        )
        guard case .failure = outcome else {
            Issue.record("a stream cancelled mid-read must not end as a clean EOF")
            return
        }
        #expect(
            fake.events == ["readParked", "cancelToken", "readReturnedAfterCancel", "close"],
            "teardown order was \(fake.events)"
        )
    }

    /// The demand-driven shape must never read ahead of the consumer: an
    /// eager producer task (the shape this wrapper deliberately avoids)
    /// would race through every chunk while the consumer sleeps.
    @Test
    func aSlowConsumerNeverLetsTheStreamReadAhead() async throws {
        let fake = FakeResponseStream(chunks: (0..<5).map { Data([UInt8($0)]) })
        let body = vaneStreamingBody(stream: fake, cancelToken: {})
        var consumed = 0
        for try await chunk in body {
            consumed += 1
            #expect(chunk == Data([UInt8(consumed - 1)]))
            // Give an eager producer every chance to run ahead before looking.
            try await Task.sleep(nanoseconds: 50_000_000)
            let started = fake.readsStarted
            #expect(
                started == consumed,
                "\(started) reads started with only \(consumed) consumed — backpressure lost"
            )
        }
        #expect(consumed == 5)
        #expect(fake.events == ["close"], "EOF must close the stream, and nothing else")
    }

    /// A failure after the headers belongs to the stream: every chunk
    /// delivered before it stays delivered, the error surfaces from the
    /// iteration, and the stream still gets closed.
    @Test
    func aMidStreamFailureSurfacesOnTheStreamAndStillCloses() async throws {
        let fake = FakeResponseStream(
            chunks: [Data([1])],
            failure: VaneError.Transport("connection lost mid-body")
        )
        let body = vaneStreamingBody(stream: fake, cancelToken: { fake.note("cancelToken") })
        var received = 0
        do {
            for try await _ in body {
                received += 1
            }
            Issue.record("expected the mid-stream transport failure to throw")
        } catch let error as VaneError {
            guard case .Transport = error else {
                Issue.record("expected VaneError.Transport, got \(error)")
                return
            }
        }
        #expect(received == 1, "the chunk delivered before the failure must not be lost")
        #expect(fake.events == ["close"], "a failed stream must still be closed, without a token cancel")
    }

    @Test
    func cancelTokenLifecycleIsIdempotentAgainstTheNativeRegistry() {
        let first = VaneCancelToken()
        let second = VaneCancelToken()

        #expect(first.id != second.id)
        #expect(!first.isCancelled)

        first.cancel()
        first.cancel()

        #expect(first.isCancelled)
        #expect(!second.isCancelled)

        // Explicit free ahead of deinit: the deinit free that follows is the
        // double-free, and both it and cancel-after-free must be no-ops.
        freeCancelToken(id: first.id)
        cancelById(id: first.id)

        second.cancel()
        #expect(second.isCancelled)
    }

    @Test
    func builderCarriesCancelTokenIdOnRequests() async throws {
        let captured = CapturedRequestBox()
        let session = try VaneSession(
            configuration: VaneConfigurationBuilder().http3Only().build(),
            requestInterceptors: [
                { request in
                    captured.request = request
                    return request
                }
            ],
            errorInterceptors: [
                { _ in
                    VaneResponse(
                        statusCode: 204,
                        headers: [:],
                        body: Data(),
                        isSuccess: true,
                        url: "interceptor://synthetic"
                    )
                }
            ]
        )

        let token = VaneCancelToken()
        _ = try await session.request("http://example.com/slow")
            .cancelToken(token)
            .execute()

        #expect(captured.request?.cancelTokenId == token.id)

        _ = try await session.request("http://example.com/plain").execute()

        #expect(captured.request?.cancelTokenId == nil)
    }

    @Test
    func responseValidationHelpersThrowOnUnexpectedStatus() throws {
        let response = VaneResponse(
            statusCode: 404,
            headers: [:],
            body: Data("missing".utf8),
            isSuccess: false,
            url: "https://example.com/missing"
        )

        #expect(response.text == "missing")
        #expect(throws: VaneError.self) {
            _ = try response.validateStatus()
        }
    }

    @Test
    func pooledHttp3Requests() async throws {
        guard let baseURL = integrationBaseURL() else { return }
        let config = VaneConfigurationBuilder()
            .baseURL(baseURL)
            .connectionPooling(enabled: true, maxIdleConnections: 2, idleTimeoutSeconds: 30)
            .retry(maxAttempts: 2)
            .timeout(30)
            .build()

        let session = try VaneSession(configuration: config)
        let first = try await session.get("/get")
        let second = try await session.get("/get")

        #expect(first.isSuccess)
        #expect(second.isSuccess)
    }

    @Test
    func benchmarkVaneHTTPMethods() async throws {
        guard let baseURL = integrationBaseURL() else { return }
        guard shouldRunBenchmarks() else { return }
        let config = VaneConfigurationBuilder()
            .baseURL(baseURL)
            .defaultHeaders(["Authorization": "Bearer token"])
            .timeout(30)
            .build()

        let session = try VaneSession(configuration: config)
        let operations: [(label: String, action: () async throws -> Void)] = [
            ("GET", { _ = try await session.get("/get") }),
            (
                "POST",
                {
                    _ = try await session.post(
                        "/post", body: "{\"message\": \"post\"}".data(using: .utf8))
                }
            ),
            (
                "PUT",
                {
                    _ = try await session.put(
                        "/put", body: "{\"message\": \"put\"}".data(using: .utf8))
                }
            ),
            (
                "PATCH",
                {
                    _ = try await session.patch(
                        "/patch", body: "{\"message\": \"patch\"}".data(using: .utf8))
                }
            ),
            ("DELETE", { _ = try await session.delete("/delete") }),
        ]

        try await runBenchmark(
            summaryName: "Vane benchmark",
            labelPrefix: "Vane",
            iterations: iterations,
            warmups: warmups,
            operations: operations
        )
    }

    @Test
    func benchmarkAlamofireHTTPMethods() async throws {
        guard let baseURL = integrationBaseURL() else { return }
        guard shouldRunBenchmarks() else { return }
        #if canImport(Alamofire)
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            let session = Session(configuration: configuration)
            let headers: HTTPHeaders = ["Authorization": "Bearer token"]

            let operations: [(label: String, action: () async throws -> Void)] = [
                (
                    "GET",
                    {
                        _ =
                            try await session
                            .request("\(baseURL)/get", headers: headers)
                            .serializingData()
                            .value
                    }
                ),
                (
                    "POST",
                    {
                        _ =
                            try await session
                            .request(
                                "\(baseURL)/post",
                                method: .post,
                                parameters: ["message": "post"],
                                encoder: JSONParameterEncoder.default,
                                headers: headers
                            )
                            .serializingData()
                            .value
                    }
                ),
                (
                    "PUT",
                    {
                        _ =
                            try await session
                            .request(
                                "\(baseURL)/put",
                                method: .put,
                                parameters: ["message": "put"],
                                encoder: JSONParameterEncoder.default,
                                headers: headers
                            )
                            .serializingData()
                            .value
                    }
                ),
                (
                    "PATCH",
                    {
                        _ =
                            try await session
                            .request(
                                "\(baseURL)/patch",
                                method: .patch,
                                parameters: ["message": "patch"],
                                encoder: JSONParameterEncoder.default,
                                headers: headers
                            )
                            .serializingData()
                            .value
                    }
                ),
                (
                    "DELETE",
                    {
                        _ =
                            try await session
                            .request("\(baseURL)/delete", method: .delete, headers: headers)
                            .serializingData()
                            .value
                    }
                ),
            ]

            try await runBenchmark(
                summaryName: "Alamofire benchmark",
                labelPrefix: "Alamofire",
                iterations: iterations,
                warmups: warmups,
                operations: operations
            )
        #endif
    }
}
