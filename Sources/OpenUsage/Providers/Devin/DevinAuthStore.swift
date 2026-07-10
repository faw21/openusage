import Foundation

struct DevinAuth: Hashable, Sendable {
    var apiKey: String
    var apiServerUrl: String?
}

enum DevinAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case credentialStoreUnreadable
    case invalidCredentialData

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Run devin auth login or sign in to Devin and try again."
        case .credentialStoreUnreadable:
            return "Couldn't read Devin credentials. Check access to the Devin credential file and app data, then try again."
        case .invalidCredentialData:
            return "Devin credentials are invalid. Run `devin auth login` or sign in to Devin again."
        }
    }
}

struct DevinAuthStore: Sendable {
    static let credentialsPath = "~/.local/share/devin/credentials.toml"
    static let stateDBPath = "~/Library/Application Support/Devin/User/globalStorage/state.vscdb"
    static let defaultAPIServerURL = "https://server.codeium.com"

    var files: TextFileAccessing
    var sqlite: SQLiteAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        sqlite: SQLiteAccessing = SQLiteCLIAccessor()
    ) {
        self.files = files
        self.sqlite = sqlite
    }

    func loadCredentialsFile() throws -> DevinAuth? {
        let text: String
        do {
            guard let stored = try files.readTextIfPresent(Self.credentialsPath) else { return nil }
            text = stored
        } catch {
            AppLog.error(LogTag.auth("devin"), "CLI credential file read failed: \(error.localizedDescription)")
            throw DevinAuthError.credentialStoreUnreadable
        }

        do {
            guard let apiKey = try Self.readTomlString(text, key: "windsurf_api_key") else {
                throw DevinAuthError.invalidCredentialData
            }
            let rawServerURL = try Self.readTomlString(text, key: "api_server_url")
            let serverURL: String?
            if let rawServerURL {
                guard let cleaned = Self.cleanAPIServerURL(rawServerURL) else {
                    throw DevinAuthError.invalidCredentialData
                }
                serverURL = cleaned
            } else {
                serverURL = nil
            }
            return DevinAuth(apiKey: apiKey, apiServerUrl: serverURL)
        } catch {
            AppLog.error(LogTag.auth("devin"), "CLI credential file is malformed")
            throw DevinAuthError.invalidCredentialData
        }
    }

    func loadAppAuth() throws -> DevinAuth? {
        let sql = "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1"
        let value: String?
        do {
            value = try sqlite.queryValue(path: Self.stateDBPath, sql: sql)
        } catch {
            AppLog.error(LogTag.auth("devin"), "app credential database read failed: \(error.localizedDescription)")
            throw DevinAuthError.credentialStoreUnreadable
        }
        guard let value else { return nil }

        let auth: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else {
                throw DevinAuthError.invalidCredentialData
            }
            auth = object
        } catch {
            AppLog.error(LogTag.auth("devin"), "app credential database value is malformed")
            throw DevinAuthError.invalidCredentialData
        }

        guard let rawAPIKey = auth["apiKey"] else { return nil }
        guard let apiKeyString = rawAPIKey as? String else {
            AppLog.error(LogTag.auth("devin"), "app credential database apiKey has an invalid type")
            throw DevinAuthError.invalidCredentialData
        }
        let apiKey = apiKeyString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return nil }

        return DevinAuth(apiKey: apiKey, apiServerUrl: nil)
    }

    func effectiveAPIServerURL(_ auth: DevinAuth) -> String {
        auth.apiServerUrl ?? Self.defaultAPIServerURL
    }

    static func cleanAPIServerURL(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false
        else {
            return nil
        }
        let withoutTrailingSlashes = trimmed.trimmingTrailingSlashes
        return withoutTrailingSlashes.isEmpty ? nil : withoutTrailingSlashes
    }

    static func readTomlString(_ text: String, key: String) throws -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == key
            else {
                continue
            }

            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw DevinAuthError.invalidCredentialData }

            if value.first == "\"" || value.first == "'" {
                guard let quoted = readQuotedTomlString(value) else {
                    throw DevinAuthError.invalidCredentialData
                }
                return quoted
            }

            if let comment = value.firstIndex(of: "#") {
                value = value[..<comment].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !value.isEmpty else { throw DevinAuthError.invalidCredentialData }
            return String(value)
        }
        return nil
    }

    private static func readQuotedTomlString(_ value: String) -> String? {
        guard let quote = value.first else { return nil }
        var output = ""
        var previous: Character?
        for character in value.dropFirst() {
            if character == quote, previous != "\\" {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            output.append(character)
            previous = character
        }
        return nil
    }
}
