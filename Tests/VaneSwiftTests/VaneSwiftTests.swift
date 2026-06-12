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
