import Foundation

struct OpenCodeAuthState: Sendable, Equatable {
    var hasAnyProviderLogin: Bool
    var goAPIKey: String?
}

/// Reads OpenCode's credential footprint already on the machine. Local-only — never the network. The
/// loader exposes only whether any provider login exists plus the `opencode-go` key needed to identify
/// the Go plan; it never returns or logs external-provider secrets.
struct OpenCodeAuthStore: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    var dataDirectory: String {
        OpenCodePaths.dataDirectory(environment: environment, homeDirectory: homeDirectory())
    }

    var authFilePath: String {
        OpenCodePaths.authFilePath(dataDirectory: dataDirectory)
    }

    /// Reads the non-secret auth summary. A dictionary entry needs both a non-empty `type` and a known
    /// credential field to count as a provider login; schema objects and incomplete entries are ignored.
    /// A present file that can't be read or parsed throws `credentialsUnreadable` so broken storage is
    /// never mistaken for logout.
    func loadState() throws -> OpenCodeAuthState {
        let text: String?
        do {
            text = try files.readTextIfPresent(authFilePath)
        } catch {
            throw OpenCodeUsageError.credentialsUnreadable(detail: error.localizedDescription)
        }
        guard let text else { return OpenCodeAuthState(hasAnyProviderLogin: false, goAPIKey: nil) }
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw OpenCodeUsageError.credentialsUnreadable(detail: "auth.json is not valid JSON")
        }

        let credentialFields = ["key", "access", "refresh", "token"]
        let hasAnyProviderLogin = object.values.contains { value in
            guard let entry = value as? [String: Any],
                  let type = (entry["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return false }
            guard !type.isEmpty else { return false }
            return credentialFields.contains { field in
                ((entry[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty) != nil
            }
        }
        let goKey = ((object["opencode-go"] as? [String: Any])?["key"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return OpenCodeAuthState(hasAnyProviderLogin: hasAnyProviderLogin, goAPIKey: goKey)
    }

    func goAPIKey() throws -> String? {
        try loadState().goAPIKey
    }
}
