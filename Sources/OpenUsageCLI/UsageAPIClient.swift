import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct UsageAPIClient: Sendable {
    static let baseURL = URL(string: "http://127.0.0.1:6736/v1/usage")!

    func fetch(providerID: String?) async throws -> (Data, [UsageSnapshot]) {
        let url = providerID.map { Self.baseURL.appendingPathComponent($0) } ?? Self.baseURL
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response): (Data, URLResponse)
        do {
            // The CLI is a one-shot local client. An ephemeral session avoids creating a disk cache or
            // persisting any response metadata for normalized usage values.
            (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        } catch {
            throw Self.classifyTransportError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CLIError.request("OpenUsage returned an invalid response.")
        }
        switch http.statusCode {
        case 200:
            let decoder = JSONDecoder()
            let snapshots: [UsageSnapshot]
            if providerID == nil {
                snapshots = try decoder.decode([UsageSnapshot].self, from: data)
            } else {
                snapshots = [try decoder.decode(UsageSnapshot.self, from: data)]
            }
            return (data, snapshots)
        case 204:
            return (Data(providerID == nil ? "[]".utf8 : "null".utf8), [])
        default:
            let code = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.error
                ?? "HTTP \(http.statusCode)"
            throw CLIError.request(code.replacingOccurrences(of: "_", with: " "))
        }
    }

    /// Connection refusal means no process owns the loopback port, so the caller may launch the app
    /// and retry. Every other transport failure is a real request error; reporting it as "not running"
    /// would hide timeouts, dropped connections, and local networking failures behind the wrong exit code.
    static func classifyTransportError(_ error: Error) -> CLIError {
        if (error as? URLError)?.code == .cannotConnectToHost {
            return .appUnavailable
        }
        return .request(error.localizedDescription)
    }
}
