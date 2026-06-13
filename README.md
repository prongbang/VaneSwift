# VaneSwift

Swift Package for Vane's Rust HTTP/3 client core.

VaneSwift currently uses the HTTP/3-only Rust transport. HTTP/1.1 and HTTP/2
fallbacks are intentionally removed from the core. See the repository root
`README.md` for the full cross-platform guide.

## Install

```swift
.package(path: "../VaneSwift")
```

```swift
.product(name: "VaneSwift", package: "VaneSwift")
```

## Usage

```swift
import VaneSwift

let config = VaneConfigurationBuilder()
    .baseURL("https://api.example.com")
    .defaultHeaders(["Accept": "application/json"])
    .cookiesEnabled(true)
    .cookiePersistencePath("/tmp/vane-cookies.txt")
    .connectionPooling(enabled: true, maxIdleConnections: 8, idleTimeoutSeconds: 30)
    .retry(maxAttempts: 3)
    .timeout(30)
    .http3Only()
    .build()

let session = try VaneSession(configuration: config)

let users = try await session.request("/users")
    .queryParam("page", "1")
    .responseString()

let created = try await session.postJSON("/users", ["name": "Ada"])
    .validateStatus()

let upload = try await session.uploadFile(
    "/upload",
    path: "/tmp/input.bin",
    onUploadProgress: { sent, total in }
)

let download = try await session.download(
    "/reports/latest",
    to: "/tmp/report.json",
    onDownloadProgress: { received, total in }
)

let multipart = try await session.request("/upload", method: .post)
    .multipart(
        fields: ["title": "avatar"],
        files: [
            VaneMultipartFile(
                fieldName: "photo",
                data: imageData,
                fileName: "me.jpg",
                contentType: "image/jpeg"
            )
        ]
    )
    .execute()
```

## Performance Usage

- Create one `VaneSession` per API domain or app service and reuse it.
- Do not create a new `VaneSession` for every request; that loses connection
  pooling and cookie reuse.
- Use direct helpers such as `get`, `postJSON`, `uploadFile`, and `download` for
  common requests.
- Use `request(...).header(...).queryParam(...)` only when a request needs
  custom per-request options.
- Add interceptors to the existing session when auth/logging behavior changes;
  this keeps the native client and connection pool alive.
- Add `onUploadProgress` / `onDownloadProgress` only when the UI needs progress.
- Use `download(..., to:)` or `downloadToFile` for large responses.
- Current multipart helpers build the body in memory, so keep multipart for
  small/medium payloads.

```swift
session
    .addRequestInterceptor { request in
        var request = request
        request.headers["Authorization"] = "Bearer \(token)"
        return request
    }
    .addResponseInterceptor { response in
        response
    }

session.clearInterceptors()
```

## Live Tests

Run SwiftPM tests against an HTTP/3-capable endpoint:

```bash
VANE_TEST_BASE_URL=https://<http3-enabled-host> swift test
```
