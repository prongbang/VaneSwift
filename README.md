# VaneSwift

Swift package for Vane's Rust HTTP client core.

## Production Artifact

`Package.swift` imports `RustFramework.xcframework`, the full static
XCFramework profile. This profile supports HTTP/3 with HTTP/2 and HTTP/1.1
fallback.

`RustFramework.small.xcframework` is generated only as an optional size profile
for HTTP/3-only apps. It is not referenced by `Package.swift`.

## Live Tests

Run SwiftPM tests against an HTTP/3-capable endpoint:

```bash
VANE_TEST_BASE_URL=https://<http3-enabled-host> swift test
```
