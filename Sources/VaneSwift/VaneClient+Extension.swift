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

/// Runs every blocking core FFI call. Two deliberate choices:
///
/// - A GCD queue, not `Task.detached`: the core call parks its thread for the
///   whole request, and a detached task does that inside Swift's width-limited
///   cooperative pool — N concurrent requests could starve or deadlock it. GCD
///   overcommits instead, so blocked requests just occupy plain threads.
/// - Explicit `.default` QoS, never the caller's: `.utility` put every I/O
///   wakeup — and the lazily spawned tokio reactor thread, which inherits its
///   creator's QoS — in a low scheduler band, producing a fat p95 latency tail
///   on iOS. `.default` matches the band URLSession's own I/O threads run in.
///
/// Concurrent, not serial: the core client is internally synchronized, and a
/// serial queue would chain independent requests' network round-trips.
private let vaneFFIQueue = DispatchQueue(
    label: "com.vane.swift.blocking-ffi",
    qos: .default,
    attributes: .concurrent
)

/// Bridges one blocking core call on `vaneFFIQueue` back into async Swift.
/// `resume(with: Result(catching:))` resumes exactly once on every path.
/// A started core call runs to completion; cancel via `VaneCancelToken`.
@available(iOS 13.0, *)
private func vaneBlockingFFI<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T
) async throws -> T {
    return try await withCheckedThrowingContinuation { continuation in
        vaneFFIQueue.async {
            continuation.resume(with: Result(catching: work))
        }
    }
}

extension VaneClient {

    // MARK: - Async/Await Support

    /// See `vaneBlockingFFI` — kept as the call-site spelling every request
    /// method in this extension already uses.
    @available(iOS 13.0, *)
    private func runBlockingFFI<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        return try await vaneBlockingFFI(work)
    }

    @available(iOS 13.0, *)
    public func get(_ url: String) async throws -> VaneResponse {
        return try await runBlockingFFI { try self.getRequest(url: url) }
    }

    @available(iOS 13.0, *)
    public func post(_ url: String, body: Data? = nil) async throws -> VaneResponse {
        return try await runBlockingFFI { try self.postRequest(url: url, body: body) }
    }

    @available(iOS 13.0, *)
    public func put(_ url: String, body: Data? = nil) async throws -> VaneResponse {
        return try await runBlockingFFI { try self.putRequest(url: url, body: body) }
    }

    @available(iOS 13.0, *)
    public func delete(_ url: String) async throws -> VaneResponse {
        return try await runBlockingFFI { try self.deleteRequest(url: url) }
    }

    @available(iOS 13.0, *)
    public func patch(_ url: String, body: Data? = nil) async throws -> VaneResponse {
        return try await runBlockingFFI { try self.patchRequest(url: url, body: body) }
    }

    @available(iOS 13.0, *)
    public func execute(_ request: VaneRequest) async throws -> VaneResponse {
        return try await runBlockingFFI { try self.executeRequest(request: request) }
    }

    /// Best-effort warm-up of the client's one-time setup and connection
    /// cost, so the first real request doesn't pay it. Call it once, early
    /// (e.g. during app launch); it never throws and repeat calls are cheap.
    ///
    /// `url` picks the origin to pre-connect (HTTP/3) or probe (TCP); `nil`
    /// falls back to the client's `baseUrl`. Runs the blocking core call
    /// (`warmup(url:)`) off the caller's thread — see that method's docs for
    /// what each protocol mode warms.
    @available(iOS 13.0, *)
    public func warmup(_ url: String? = nil) async {
        // The core warmup never throws; `try?` only satisfies the shared
        // helper's signature.
        try? await runBlockingFFI { self.warmup(url: url) }
    }

    /// Like `execute(_:)`, but resumes as soon as the final response's
    /// headers are in, with the body left to stream; see
    /// `VaneStreamingResponse`.
    ///
    /// Everything up to the headers behaves exactly like `execute(_:)`: the
    /// same redirect chain, retry policy, HTTP/3-to-TCP fallback, cookies,
    /// pins and deadline. Differences, all deliberate:
    ///
    /// - `VaneRequest.responseBodyPath` is refused by the core: the stream
    ///   replaces the file escape hatch.
    /// - Progress callbacks are meaningless here: the chunks themselves are
    ///   the download progress.
    /// - `VaneRequest.cancelTokenId` composes: cancelling that token aborts
    ///   the header phase, or fails the body stream mid-flight. Cancelling
    ///   the consuming task cancels it too. When the request carries no
    ///   token, the wrapper runs one internally so cancelling a parked read
    ///   stays prompt.
    @available(iOS 13.0, *)
    public func executeStreaming(_ request: VaneRequest) async throws -> VaneStreamingResponse {
        var effectiveRequest = request
        let ownedToken: VaneCancelToken? = request.cancelTokenId == nil ? VaneCancelToken() : nil
        if let ownedToken {
            effectiveRequest.cancelTokenId = ownedToken.id
        }
        // On a header-phase failure the owned token deallocates here and its
        // deinit releases the native registry entry.
        let (stream, head) = try await runBlockingFFI {
            let stream = try self.executeStreamingRequest(request: effectiveRequest)
            return (stream, stream.head())
        }
        let cancelNative: @Sendable () -> Void
        if let ownedToken {
            // The closure keeps the owned token alive for the stream's life;
            // its deinit frees the native entry when the body is released.
            cancelNative = { ownedToken.cancel() }
        } else {
            // Non-nil by construction: no owned token means the caller set one.
            let callerTokenId = request.cancelTokenId!
            cancelNative = { cancelById(id: callerTokenId) }
        }
        return VaneStreamingResponse(
            head: head,
            body: vaneStreamingBody(stream: stream, cancelToken: cancelNative)
        )
    }
}

// MARK: - Streaming

/// A response whose headers have arrived and whose body is still streaming.
///
/// `head` is the familiar `VaneResponse` — status, headers, final URL,
/// cookies, negotiated protocol — with `VaneResponse.body` empty by contract:
/// `body` delivers it instead.
///
/// `body` is demand-driven and meant for a single consumer: chunks are pulled
/// off the native transport only as the consumer iterates, so a slow consumer
/// stalls the sender through QUIC/TCP flow control instead of buffering
/// without bound. Chunk boundaries carry no meaning. A failure after the
/// headers throws from the iteration, not as a failed request. Cancelling the
/// consuming task cancels the request's token first — that is what interrupts
/// a pull parked in the FFI — then closes the native stream, discarding its
/// connection; only a body iterated to the end returns the connection to the
/// pool.
///
/// Always iterate (or cancel the iteration of) `body`: an abandoned,
/// never-iterated body holds its connection until the stream object
/// deallocates.
@available(iOS 13.0, *)
public struct VaneStreamingResponse {
    public let head: VaneResponse
    public let body: AsyncThrowingStream<Data, Error>

    public init(head: VaneResponse, body: AsyncThrowingStream<Data, Error>) {
        self.head = head
        self.body = body
    }
}

/// Bridges one native response stream into a demand-driven
/// `AsyncThrowingStream`. The shape carries the invariants; refactor with
/// care:
///
/// - **No read-ahead, by construction.** `init(unfolding:)` runs one closure
///   call per consumer `next()`; there is no producer task and no buffer, so
///   the core is never asked for bytes the consumer has not asked for — and a
///   core that is not pulled does not read the socket, which stalls the
///   sender through QUIC/TCP flow control. Replacing this with the
///   continuation-based initializer plus a reading `Task` looks equivalent
///   and is not, twice over: `yield` never suspends, so that shape buffers an
///   unbounded run-ahead of the body, and its read loop parks a thread for
///   the stream's whole life.
/// - **Every blocking call stays off the cooperative pool.** Reads and closes
///   hop to `vaneFFIQueue` (default QoS — see its doc for the p95 history).
///   A GCD thread is parked only while one pull is in flight, not per live
///   stream: N streams blocked in reads park N threads, the same budget N
///   in-flight buffered requests already consume; streams idle between pulls
///   park none.
/// - **Token before close.** A pull parked in the FFI holds the native
///   stream's lock, and `closeStream` waits on that lock; only cancelling the
///   request's token makes a parked pull return. The cancellation handler
///   fires the token the moment the consuming task is cancelled, and
///   `closeStream` runs only after the pull has returned.
@available(iOS 13.0, *)
func vaneStreamingBody(
    stream: any VaneResponseStreamProtocol,
    cancelToken: @escaping @Sendable () -> Void
) -> AsyncThrowingStream<Data, Error> {
    return AsyncThrowingStream(unfolding: {
        do {
            let chunk = try await withTaskCancellationHandler {
                try await vaneBlockingFFI { try stream.readChunk() }
            } onCancel: {
                cancelToken()
            }
            if let chunk {
                return chunk
            }
            // EOF: the connection is already back in the pool and closeStream
            // is an idempotent no-op — called for symmetry with the error
            // path so the native stream is always left explicitly closed.
            _ = try? await vaneBlockingFFI { stream.closeStream() }
            return nil
        } catch {
            // Failure or cancellation: the read has returned, so this close
            // cannot block behind it. After a failure the connection is
            // already discarded; after a cancellation this is what discards
            // it.
            _ = try? await vaneBlockingFFI { stream.closeStream() }
            throw error
        }
    })
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

/// Cancels an in-flight request from any thread.
///
/// The native token is created eagerly at init — unlike Dart, whose token
/// reaches the core over an async platform channel and therefore latches a
/// cancel issued before registration — so `cancel()` always reaches the core
/// immediately.
///
/// Attach it with `VaneRequestBuilder.cancelToken(_:)`, or set `id` as
/// `VaneRequest.cancelTokenId` when building requests by hand. A cancelled
/// token stays cancelled, so reuse on a second request aborts that one too.
///
/// Ownership: the token owns its native registry entry and releases it in
/// `deinit`. Keep the token alive while the request is in flight — a request
/// whose token has been deallocated keeps running but can no longer be
/// cancelled. The core never reuses ids, so a cancel or free racing
/// deallocation is a safe no-op.
public final class VaneCancelToken: @unchecked Sendable {
    public let id: UInt64

    private let lock = NSLock()
    private var cancelled = false

    public init() {
        id = createCancelToken()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        cancelById(id: id)
    }

    deinit {
        freeCancelToken(id: id)
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

    /// Best-effort warm-up of the underlying client; see
    /// `VaneClient.warmup(_:)`. Never throws.
    public func warmup(_ url: String? = nil) async {
        await client.warmup(url)
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

    /// Like `execute(_:)`, but resolves as soon as the final response's
    /// headers are in, with the body left to stream; see
    /// `VaneStreamingResponse`.
    ///
    /// Request interceptors run; response and error interceptors do NOT — an
    /// interceptor written against a buffered `VaneResponse` cannot rewrite a
    /// body that has not arrived. Validate status off the head, e.g.
    /// `try response.head.validateStatus()`. The other deltas from
    /// `execute(_:)` are documented on `VaneClient.executeStreaming(_:)`.
    public func executeStreaming(_ request: VaneRequest) async throws -> VaneStreamingResponse {
        var interceptedRequest = request
        let requestInterceptors = requestInterceptors
        for interceptor in requestInterceptors {
            interceptedRequest = try await interceptor(interceptedRequest)
        }
        return try await client.executeStreaming(interceptedRequest)
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

    public func cancelToken(_ token: VaneCancelToken) -> VaneRequestBuilder {
        request.cancelTokenId = token.id
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
            throw VaneError.InvalidRequest("Failed to encode request text body")
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
            throw VaneError.InvalidRequest("Missing form value for \(key)")
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
