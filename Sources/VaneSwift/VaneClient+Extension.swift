import Foundation

#if canImport(vaneFFI)
    import vaneFFI
#endif

// MARK: - Usage Examples

/*
// Basic usage
let session = try VaneSession()
let response = try await session.get("https://api.example.com/users")

// With configuration
let config = VaneConfigurationBuilder()
    .baseURL("https://api.example.com")
    .defaultHeaders(["Authorization": "Bearer token"])
    .timeout(30)
    .build()

let session = try VaneSession(configuration: config)

// Request builder pattern
let users = try await session.request("/users")
    .header("Accept", "application/json")
    .queryParam("page", "1")
    .responseJSON([User].self)

// POST with JSON
let newUser = User(name: "John", email: "john@example.com")
let response = try await session.request("/users", method: .post)
    .jsonBody(newUser)
    .execute()
*/

// MARK: - Swift Extensions and Helpers

// Shared, never reconfigured — JSONEncoder/JSONDecoder are Sendable and safe to
// reuse concurrently as long as nothing mutates their configuration.
private let vaneJSONEncoder = JSONEncoder()
private let vaneJSONDecoder = JSONDecoder()

public extension VaneResponse {
    init(statusCode: UInt16, headers: [String: String], body: Data, isSuccess: Bool, url: String) {
        self.init(
            statusCode: statusCode,
            headers: headers,
            body: body,
            bodyFilePath: nil,
            isSuccess: isSuccess,
            url: url
        )
    }
}

extension VaneClient {

    // MARK: - Async/Await Support

    @available(iOS 13.0, *)
    public func get(_ url: String) async throws -> VaneResponse {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .utility) { @Sendable in
                do {
                    let response = try self.getRequest(url: url)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @available(iOS 13.0, *)
    public func post(_ url: String, body: Data? = nil) async throws -> VaneResponse {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .utility) { @Sendable in
                do {
                    let response = try self.postRequest(url: url, body: body)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @available(iOS 13.0, *)
    public func put(_ url: String, body: Data? = nil) async throws -> VaneResponse {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .utility) { @Sendable in
                do {
                    let response = try self.putRequest(url: url, body: body)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @available(iOS 13.0, *)
    public func delete(_ url: String) async throws -> VaneResponse {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .utility) { @Sendable in
                do {
                    let response = try self.deleteRequest(url: url)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @available(iOS 13.0, *)
    public func patch(_ url: String, body: Data? = nil) async throws -> VaneResponse {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .utility) { @Sendable in
                do {
                    let response = try self.patchRequest(url: url, body: body)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @available(iOS 13.0, *)
    public func execute(_ request: VaneRequest) async throws -> VaneResponse {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .utility) { @Sendable in
                do {
                    let response = try self.executeRequest(request: request)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Alamofire-style Interface

@available(iOS 13.0, *)
public typealias VaneRequestInterceptor = @Sendable (VaneRequest) async throws -> VaneRequest

@available(iOS 13.0, *)
public typealias VaneResponseInterceptor = @Sendable (VaneResponse) async throws -> VaneResponse

@available(iOS 13.0, *)
public typealias VaneErrorInterceptor = @Sendable (Error) async throws -> VaneResponse?

@available(iOS 13.0, *)
public typealias VaneProgressCallback = @Sendable (_ transferred: UInt64, _ total: UInt64) -> Void

public struct VaneMultipartFile: Sendable {
    public let fieldName: String
    public let data: Data
    public let fileName: String
    public let contentType: String

    public init(
        fieldName: String,
        data: Data,
        fileName: String? = nil,
        contentType: String = "application/octet-stream"
    ) {
        self.fieldName = fieldName
        self.data = data
        self.fileName = fileName ?? fieldName
        self.contentType = contentType
    }
}

@available(iOS 13.0, *)
public class VaneSession {
    private let client: VaneClient
    private var requestInterceptors: [VaneRequestInterceptor]
    private var responseInterceptors: [VaneResponseInterceptor]
    private var errorInterceptors: [VaneErrorInterceptor]

    public init(
        configuration: VaneClientConfig = createDefaultConfig(),
        requestInterceptors: [VaneRequestInterceptor] = [],
        responseInterceptors: [VaneResponseInterceptor] = [],
        errorInterceptors: [VaneErrorInterceptor] = []
    ) throws {
        self.client = try createVaneClient(config: configuration)
        self.requestInterceptors = requestInterceptors
        self.responseInterceptors = responseInterceptors
        self.errorInterceptors = errorInterceptors
    }

    // MARK: - Request Building

    public func request(_ url: String, method: HTTPMethod = .get) -> VaneRequestBuilder {
        return VaneRequestBuilder(url: url, method: method, executor: execute)
    }

    @discardableResult
    public func addRequestInterceptor(_ interceptor: @escaping VaneRequestInterceptor) -> VaneSession {
        requestInterceptors.append(interceptor)
        return self
    }

    @discardableResult
    public func addResponseInterceptor(_ interceptor: @escaping VaneResponseInterceptor) -> VaneSession {
        responseInterceptors.append(interceptor)
        return self
    }

    @discardableResult
    public func addErrorInterceptor(_ interceptor: @escaping VaneErrorInterceptor) -> VaneSession {
        errorInterceptors.append(interceptor)
        return self
    }

    @discardableResult
    public func clearInterceptors() -> VaneSession {
        requestInterceptors.removeAll()
        responseInterceptors.removeAll()
        errorInterceptors.removeAll()
        return self
    }

    @discardableResult
    public func setCertificatePins(host: String, pins: [String]) throws -> VaneSession {
        try client.setCertificatePins(host: host, pins: pins)
        return self
    }

    @discardableResult
    public func addCertificatePin(host: String, pin: String) throws -> VaneSession {
        try client.addCertificatePin(host: host, pin: pin)
        return self
    }

    @discardableResult
    public func clearCertificatePins(host: String) throws -> VaneSession {
        try client.clearCertificatePins(host: host)
        return self
    }

    // MARK: - Direct Methods

    public func get(_ url: String) async throws -> VaneResponse {
        return try await request(url, method: .get).execute()
    }

    public func post(_ url: String, body: Data? = nil) async throws -> VaneResponse {
        let builder = request(url, method: .post)
        if let body { _ = builder.body(body) }
        return try await builder.execute()
    }

    public func put(_ url: String, body: Data? = nil) async throws -> VaneResponse {
        let builder = request(url, method: .put)
        if let body { _ = builder.body(body) }
        return try await builder.execute()
    }

    public func delete(_ url: String) async throws -> VaneResponse {
        return try await request(url, method: .delete).execute()
    }

    public func patch(_ url: String, body: Data? = nil) async throws -> VaneResponse {
        let builder = request(url, method: .patch)
        if let body { _ = builder.body(body) }
        return try await builder.execute()
    }

    public func postJSON<T: Codable>(_ url: String, _ object: T) async throws -> VaneResponse {
        return try await request(url, method: .post)
            .jsonBody(object)
            .execute()
    }

    public func postForm(_ url: String, fields: [String: String]) async throws -> VaneResponse {
        return try await request(url, method: .post)
            .formBody(fields)
            .execute()
    }

    public func uploadFile(
        _ url: String,
        path: String,
        method: HTTPMethod = .post,
        onUploadProgress: VaneProgressCallback? = nil,
        onDownloadProgress: VaneProgressCallback? = nil
    ) async throws -> VaneResponse {
        let builder = request(url, method: method)
            .bodyFile(path)
        if let onUploadProgress {
            _ = builder.onUploadProgress(onUploadProgress)
        }
        if let onDownloadProgress {
            _ = builder.onDownloadProgress(onDownloadProgress)
        }
        return try await builder.execute()
    }

    public func download(
        _ url: String,
        to path: String,
        onDownloadProgress: VaneProgressCallback? = nil
    ) async throws -> VaneResponse {
        let builder = request(url, method: .get)
            .downloadToFile(path)
        if let onDownloadProgress {
            _ = builder.onDownloadProgress(onDownloadProgress)
        }
        return try await builder.execute()
    }

    public func execute(_ request: VaneRequest) async throws -> VaneResponse {
        var interceptedRequest = request
        let requestInterceptors = requestInterceptors
        for interceptor in requestInterceptors {
            interceptedRequest = try await interceptor(interceptedRequest)
        }

        do {
            var response = try await client.execute(interceptedRequest)
            let responseInterceptors = responseInterceptors
            for interceptor in responseInterceptors {
                response = try await interceptor(response)
            }
            return response
        } catch {
            let errorInterceptors = errorInterceptors
            for interceptor in errorInterceptors {
                if let response = try await interceptor(error) {
                    var interceptedResponse = response
                    let responseInterceptors = responseInterceptors
                    for responseInterceptor in responseInterceptors {
                        interceptedResponse = try await responseInterceptor(interceptedResponse)
                    }
                    return interceptedResponse
                }
            }

            throw error
        }
    }
}

// MARK: - HTTP Methods

public enum HTTPMethod: String, CaseIterable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
    case head = "HEAD"
    case options = "OPTIONS"
}

// MARK: - Request Builder

@available(iOS 13.0, *)
public class VaneRequestBuilder {
    private let executor: (VaneRequest) async throws -> VaneResponse
    private var request: VaneRequest
    private var uploadProgress: VaneProgressCallback?
    private var downloadProgress: VaneProgressCallback?

    internal init(
        url: String,
        method: HTTPMethod,
        executor: @escaping (VaneRequest) async throws -> VaneResponse
    ) {
        self.executor = executor
        self.request = VaneRequest(
            url: url,
            method: method.rawValue,
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
    }

    // MARK: - Builder Methods

    public func headers(_ headers: [String: String]) -> VaneRequestBuilder {
        request.headers = headers
        return self
    }

    public func header(_ key: String, _ value: String) -> VaneRequestBuilder {
        request.headers[key] = value
        return self
    }

    public func queryParams(_ params: [String: String]) -> VaneRequestBuilder {
        request.queryParams = params
        return self
    }

    public func queryParam(_ key: String, _ value: String) -> VaneRequestBuilder {
        request.queryParams[key] = value
        return self
    }

    public func body(_ body: Data) -> VaneRequestBuilder {
        request.body = body
        request.bodyFilePath = nil
        return self
    }

    public func bodyFile(_ path: String) -> VaneRequestBuilder {
        request.bodyFilePath = path
        request.body = nil
        return self
    }

    public func downloadToFile(_ path: String) -> VaneRequestBuilder {
        request.responseBodyPath = path
        return self
    }

    public func onUploadProgress(_ callback: @escaping VaneProgressCallback) -> VaneRequestBuilder {
        uploadProgress = callback
        return self
    }

    public func onDownloadProgress(_ callback: @escaping VaneProgressCallback) -> VaneRequestBuilder {
        downloadProgress = callback
        return self
    }

    public func multipart(
        fields: [String: String] = [:],
        files: [VaneMultipartFile] = []
    ) -> VaneRequestBuilder {
        let boundary = "vane-\(UInt64(Date().timeIntervalSince1970 * 1_000_000))"
        var body = Data()

        for key in fields.keys.sorted() {
            guard let value = fields[key] else { continue }
            body.appendMultipartString("--\(boundary)\r\n")
            body.appendMultipartString("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            body.appendMultipartString(value)
            body.appendMultipartString("\r\n")
        }

        for file in files {
            body.appendMultipartString("--\(boundary)\r\n")
            body.appendMultipartString(
                "Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.fileName)\"\r\n"
            )
            body.appendMultipartString("Content-Type: \(file.contentType)\r\n\r\n")
            body.append(file.data)
            body.appendMultipartString("\r\n")
        }

        body.appendMultipartString("--\(boundary)--\r\n")
        return self
            .body(body)
            .setDefaultHeaderReturning("Content-Type", "multipart/form-data; boundary=\(boundary)")
    }

    public func textBody(
        _ text: String,
        encoding: String.Encoding = .utf8,
        contentType: String = "text/plain; charset=utf-8"
    ) throws -> VaneRequestBuilder {
        guard let data = text.data(using: encoding) else {
            throw VaneError.Generic("Failed to encode request text body")
        }
        _ = body(data)
        setDefaultHeader("Content-Type", contentType)
        return self
    }

    public func jsonBody<T: Codable>(_ object: T) throws -> VaneRequestBuilder {
        _ = body(try vaneJSONEncoder.encode(object))
        setDefaultHeader("Content-Type", "application/json")
        return self
    }

    public func formBody(_ fields: [String: String]) throws -> VaneRequestBuilder {
        if let data = try formURLEncoded(fields).data(using: .utf8) {
            _ = body(data)
        }
        setDefaultHeader("Content-Type", "application/x-www-form-urlencoded")
        return self
    }

    public func timeout(_ seconds: UInt64) -> VaneRequestBuilder {
        request.timeoutSeconds = seconds
        return self
    }

    public func followRedirects(_ follow: Bool) -> VaneRequestBuilder {
        request.followRedirects = follow
        return self
    }

    // MARK: - Execution

    public func execute() async throws -> VaneResponse {
        var executableRequest = request
        let progressId: UInt64?
        let progressTask: Task<Void, Never>?

        if uploadProgress != nil || downloadProgress != nil {
            let id = createProgress()
            executableRequest.progressId = id
            progressId = id
            progressTask = Task { [uploadProgress, downloadProgress] in
                while !Task.isCancelled {
                    let progress = progressSnapshotById(id: id)
                    uploadProgress?(progress.uploadSent, progress.uploadTotal)
                    downloadProgress?(progress.downloadReceived, progress.downloadTotal)
                    if progress.done {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        } else {
            progressId = nil
            progressTask = nil
        }

        do {
            let response = try await executor(executableRequest)
            finishProgress(progressId, progressTask)
            return response
        } catch {
            finishProgress(progressId, progressTask)
            throw error
        }
    }

    public func validateStatus(_ range: ClosedRange<UInt16> = 200...299) async throws -> VaneResponse {
        let response = try await execute()
        return try response.validateStatus(range)
    }

    public func responseBytes() async throws -> Data {
        let response = try await validateStatus()
        return response.body
    }

    public func responseJSON<T: Codable>(_ type: T.Type) async throws -> T {
        let response = try await validateStatus()

        return try vaneJSONDecoder.decode(type, from: response.body)
    }

    public func responseString() async throws -> String {
        let response = try await validateStatus()

        if let string = String(data: response.body, encoding: .utf8) {
            return string
        }
        return ""
    }

    private func setDefaultHeader(_ key: String, _ value: String) {
        let hasHeader = request.headers.keys.contains { $0.caseInsensitiveCompare(key) == .orderedSame }
        if !hasHeader {
            request.headers[key] = value
        }
    }

    private func setDefaultHeaderReturning(_ key: String, _ value: String) -> VaneRequestBuilder {
        setDefaultHeader(key, value)
        return self
    }

    private func finishProgress(_ progressId: UInt64?, _ task: Task<Void, Never>?) {
        guard let progressId else { return }
        task?.cancel()
        let progress = progressSnapshotById(id: progressId)
        uploadProgress?(progress.uploadSent, progress.uploadTotal)
        downloadProgress?(progress.downloadReceived, progress.downloadTotal)
        freeProgress(id: progressId)
    }
}

private extension Data {
    mutating func appendMultipartString(_ value: String) {
        append(Data(value.utf8))
    }
}

public extension VaneResponse {
    func validateStatus(_ range: ClosedRange<UInt16> = 200...299) throws -> VaneResponse {
        guard range.contains(statusCode) else {
            throw VaneError.Generic("Request failed with status \(statusCode)")
        }
        return self
    }

    var text: String {
        String(data: body, encoding: .utf8) ?? ""
    }
}

private func formURLEncoded(_ fields: [String: String]) throws -> String {
    try fields.keys.sorted().map { key in
        guard let value = fields[key] else {
            throw VaneError.Generic("Missing form value for \(key)")
        }
        return "\(formEncode(key))=\(formEncode(value))"
    }.joined(separator: "&")
}

private func formEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
    return value.addingPercentEncoding(withAllowedCharacters: allowed)?
        .replacingOccurrences(of: "%20", with: "+") ?? value
}

// MARK: - Configuration Builder

public class VaneConfigurationBuilder {
    private var config = createDefaultConfig()

    public func baseURL(_ url: String) -> VaneConfigurationBuilder {
        config.baseUrl = url
        return self
    }

    public func defaultHeaders(_ headers: [String: String]) -> VaneConfigurationBuilder {
        config.defaultHeaders = headers
        return self
    }

    public func dnsOverrides(_ overrides: [String: String]) -> VaneConfigurationBuilder {
        config.dnsOverrides = overrides
        return self
    }

    public func dnsOverride(host: String, ipAddress: String) -> VaneConfigurationBuilder {
        config.dnsOverrides[host] = ipAddress
        return self
    }

    public func proxy(_ url: String, authorization: String? = nil) -> VaneConfigurationBuilder {
        config.proxyUrl = url
        config.proxyAuthorization = authorization
        return self
    }

    public func proxyAuthorization(_ authorization: String?) -> VaneConfigurationBuilder {
        config.proxyAuthorization = authorization
        return self
    }

    public func certificatePins(_ pins: [String: [String]]) -> VaneConfigurationBuilder {
        config.certificatePins = pins
        return self
    }

    public func certificatePin(host: String, pins: [String]) -> VaneConfigurationBuilder {
        config.certificatePins[host] = pins
        return self
    }

    public func cookiesEnabled(_ enabled: Bool = true) -> VaneConfigurationBuilder {
        config.cookiesEnabled = enabled
        return self
    }

    public func cookiePersistencePath(_ path: String?) -> VaneConfigurationBuilder {
        config.cookiePersistencePath = path
        return self
    }

    public func connectionPooling(
        enabled: Bool = true,
        maxIdleConnections: UInt64 = 4,
        idleTimeoutSeconds: UInt64 = 30
    ) -> VaneConfigurationBuilder {
        config.connectionPoolEnabled = enabled
        config.maxIdleConnections = maxIdleConnections
        config.connectionIdleTimeoutSeconds = idleTimeoutSeconds
        return self
    }

    public func retry(
        maxAttempts: UInt64,
        initialDelayMillis: UInt64 = 100,
        maxDelayMillis: UInt64 = 1_000,
        retryUnsafeMethods: Bool = false
    ) -> VaneConfigurationBuilder {
        config.retryMaxAttempts = maxAttempts
        config.retryInitialDelayMillis = initialDelayMillis
        config.retryMaxDelayMillis = maxDelayMillis
        config.retryUnsafeMethods = retryUnsafeMethods
        return self
    }

    public func bodyLimits(
        maxRequestBodyBytes: UInt64,
        maxResponseBodyBytes: UInt64
    ) -> VaneConfigurationBuilder {
        config.maxRequestBodyBytes = maxRequestBodyBytes
        config.maxResponseBodyBytes = maxResponseBodyBytes
        return self
    }

    public func timeout(_ seconds: UInt64) -> VaneConfigurationBuilder {
        config.timeoutSeconds = seconds
        return self
    }

    public func userAgent(_ agent: String) -> VaneConfigurationBuilder {
        config.userAgent = agent
        return self
    }

    public func protocolMode(_ mode: VaneProtocolMode) -> VaneConfigurationBuilder {
        config.protocolMode = mode
        return self
    }

    public func http3ThenHttp2ThenHttp1() -> VaneConfigurationBuilder {
        config.protocolMode = .http3ThenHttp2ThenHttp1
        return self
    }

    public func http3Only() -> VaneConfigurationBuilder {
        config.protocolMode = .http3Only
        return self
    }

    public func http2ThenHttp1() -> VaneConfigurationBuilder {
        config.protocolMode = .http2ThenHttp1
        return self
    }

    public func http2Only() -> VaneConfigurationBuilder {
        config.protocolMode = .http2Only
        return self
    }

    public func http1Only() -> VaneConfigurationBuilder {
        config.protocolMode = .http1Only
        return self
    }

    public func followRedirects(_ follow: Bool) -> VaneConfigurationBuilder {
        config.followRedirects = follow
        return self
    }

    public func build() -> VaneClientConfig {
        return config
    }
}

// MARK: - Convenience Extensions

extension VaneResponse {

    public var isSuccessful: Bool {
        return isSuccess
    }

    public func json<T: Codable>(_ type: T.Type) throws -> T {
        return try vaneJSONDecoder.decode(type, from: body)
    }

    public var prettyJSON: String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: body),
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
            let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }
}
