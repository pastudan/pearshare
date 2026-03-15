import Foundation
import Network

/// Talks to the Tailscale daemon's local HTTP API over a Unix domain socket.
/// No API key needed — the socket is readable by the local user.
///
/// Docs: https://pkg.go.dev/tailscale.com/client/tailscale
final class TailscaleClient {

    // Tailscale daemon socket locations (tries in order)
    private static let socketPaths = [
        "/var/run/tailscale/tailscaled.sock",
        "/run/tailscale/tailscaled.sock",
    ]

    // MARK: - Public API

    /// Returns the current tailnet status including self and all peers.
    func status() async throws -> TailscaleStatus {
        let data = try await get(path: "/localapi/v0/status")
        return try JSONDecoder().decode(TailscaleStatus.self, from: data)
    }

    // MARK: - HTTP over Unix Socket

    private func get(path: String) async throws -> Data {
        guard let socketPath = TailscaleClient.socketPaths.first(where: {
            FileManager.default.fileExists(atPath: $0)
        }) else {
            throw TailscaleError.daemonNotRunning
        }

        return try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
            let accumulator = ResponseAccumulator(continuation: continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let request = "GET \(path) HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n"
                    connection.send(content: request.data(using: .utf8), completion: .idempotent)
                    accumulator.receive(from: connection)
                case .failed(let error):
                    accumulator.finish(error: error)
                case .cancelled:
                    accumulator.finish(error: TailscaleError.connectionCancelled)
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func extractHTTPBody(from data: Data) -> Data? {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let range = data.range(of: separator) else { return nil }
        let bodyStart = range.upperBound
        guard bodyStart <= data.count else { return nil }
        return Data(data[bodyStart...])
    }
}

// MARK: - Response accumulator (avoids inout-in-closure issues)

private final class ResponseAccumulator {
    private var buffer = Data()
    private var finished = false
    private let continuation: CheckedContinuation<Data, Error>

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func receive(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }

            if let error {
                connection.cancel()
                self.finish(error: error)
                return
            }

            if let data { self.buffer.append(data) }

            if isComplete || data == nil {
                connection.cancel()
                if let body = TailscaleClient.extractHTTPBody(from: self.buffer) {
                    self.finish(result: body)
                } else {
                    self.finish(error: TailscaleError.invalidResponse)
                }
                return
            }

            self.receive(from: connection)
        }
    }

    func finish(result: Data) {
        guard !finished else { return }
        finished = true
        continuation.resume(returning: result)
    }

    func finish(error: Error) {
        guard !finished else { return }
        finished = true
        continuation.resume(throwing: error)
    }
}

// MARK: - Error

enum TailscaleError: LocalizedError {
    case daemonNotRunning
    case connectionCancelled
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .daemonNotRunning:
            return "Tailscale daemon is not running. Start Tailscale and try again."
        case .connectionCancelled:
            return "Connection to Tailscale daemon was cancelled."
        case .invalidResponse:
            return "Received an invalid response from Tailscale daemon."
        }
    }
}
