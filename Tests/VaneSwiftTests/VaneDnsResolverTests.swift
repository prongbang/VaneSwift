import Foundation
import Network
import Testing

@testable import VaneSwift

/// The Swift-side check for the caller-supplied DNS resolver through the
/// packaged core: the foreign-trait callback crosses UniFFI's generated call
/// sites, `resolve` is invoked with the URL host, and the address it returns
/// is where the connection actually goes — proven by a local listener
/// observing the connection arrive.
///
/// `.invalid` never resolves (RFC 2606) and the system resolver is never
/// consulted once a resolver is installed, so the accepted connection can
/// only have come from the resolver's answer. The listener speaks no TLS, so
/// the request itself must fail — after the connect, which is the part under
/// test. `http1Only` keeps the path deterministic.
struct VaneDnsResolverTests {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() {
            lock.lock()
            raised = true
            lock.unlock()
        }
        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return raised
        }
    }

    private final class RecordingResolver: VaneDnsResolver, @unchecked Sendable {
        private let lock = NSLock()
        private var hosts: [String] = []
        func resolve(host: String) -> [String] {
            lock.lock()
            hosts.append(host)
            lock.unlock()
            return ["127.0.0.1"]
        }
        var recorded: [String] {
            lock.lock()
            defer { lock.unlock() }
            return hosts
        }
    }

    @Test
    func aCallerSuppliedResolverSteersTheTcpTransport() async throws {
        let accepted = Flag()
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { connection in
            accepted.raise()
            connection.cancel()
        }
        let resumed = Flag()
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                guard !resumed.value else { return }
                switch state {
                case .ready:
                    resumed.raise()
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    resumed.raise()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }

        let client = try createVaneClient(
            config: VaneConfigurationBuilder()
                .http1Only()
                .timeout(10)
                .build()
        )
        let resolver = RecordingResolver()
        client.setDnsResolver(resolver: resolver)

        await #expect(throws: (any Error).self) {
            _ = try await client.get("https://vane-dns-probe.invalid:\(port)/")
        }

        #expect(resolver.recorded == ["vane-dns-probe.invalid"])
        // The failed request proves the reply crossed back; give the accept
        // callback a moment in case it races the client-side failure.
        var patience = 0
        while !accepted.value && patience < 50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            patience += 1
        }
        #expect(accepted.value, "the resolver's address never received the connection")
        listener.cancel()
    }
}
