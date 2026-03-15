import Foundation

/// Talks to the Tailscale daemon via its local HTTP API.
/// Reads port + token directly from /Library/Tailscale/ — no CLI subprocess needed.
/// Port:  symlink target of /Library/Tailscale/ipnport
/// Token: contents of /Library/Tailscale/sameuserproof-<port>
final class TailscaleClient {

    private static let ipnportPath = "/Library/Tailscale/ipnport"

    // MARK: - Public API

    func status() async throws -> TailscaleStatus {
        let (port, token) = try localCreds()
        let data = try await httpGet(port: port, token: token, path: "/localapi/v0/status")
        do {
            return try JSONDecoder().decode(TailscaleStatus.self, from: data)
        } catch {
            throw TailscaleError.invalidResponse
        }
    }

    // MARK: - Read credentials from disk

    private func localCreds() throws -> (port: Int, token: String) {
        // /Library/Tailscale/ipnport is a symlink whose target name IS the port number
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(
            atPath: Self.ipnportPath
        ), let port = Int(dest) else {
            throw TailscaleError.daemonNotRunning
        }

        let tokenPath = "/Library/Tailscale/sameuserproof-\(port)"
        guard let token = try? String(contentsOfFile: tokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw TailscaleError.daemonNotRunning
        }

        return (port: port, token: token)
    }

    // MARK: - HTTP request to local API

    private func httpGet(port: Int, token: String, path: String) async throws -> Data {
        guard let url = URL(string: "http://localhost:\(port)\(path)") else {
            throw TailscaleError.invalidResponse
        }

        var request = URLRequest(url: url)
        let credentials = Data(":\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TailscaleError.daemonNotRunning
        }
        return data
    }
}

// MARK: - Error

enum TailscaleError: LocalizedError {
    case cliNotFound
    case daemonNotRunning
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Tailscale CLI not found. Install Tailscale from tailscale.com."
        case .daemonNotRunning:
            return "Tailscale is not running. Start Tailscale and try again."
        case .invalidResponse:
            return "Received an unexpected response from Tailscale."
        }
    }
}
