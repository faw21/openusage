import Foundation

/// A GitHub token already on the machine, usable against the Copilot usage endpoint.
struct CopilotToken: Hashable, Sendable {
    var value: String
}

struct CopilotAuthLoadResult: Sendable {
    var token: CopilotToken?
    var firstError: CopilotAuthError?
}

enum CopilotAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case tokenInvalid
    case credentialStoreUnreadable
    case invalidCredentialData

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Sign in to GitHub Copilot in your editor, or run gh auth login, and try again."
        case .tokenInvalid:
            return "GitHub token invalid or expired. Re-authenticate (gh auth login) and try again."
        case .credentialStoreUnreadable:
            return "Couldn't read GitHub Copilot credentials. Check access to your editor and GitHub CLI credentials, then try again."
        case .invalidCredentialData:
            return "GitHub Copilot credentials are invalid. Sign in to Copilot in your editor or run `gh auth login` again."
        }
    }
}

/// Reads a GitHub token that Copilot tooling already left on the machine — no login flow, no browser
/// cookies. Sources are tried prompt-free files first, Keychain last:
/// 1. Copilot editor config `~/.config/github-copilot/apps.json` (older `hosts.json`) — the OAuth token
///    the VS Code / JetBrains / Neovim Copilot plugins write. Universal and file-based.
/// 2. GitHub CLI `~/.config/gh/hosts.yml` `oauth_token` — present when `gh` stores the token in a file.
/// 3. GitHub CLI Keychain item (service `gh:github.com`) — go-keyring-wrapped, used when `gh` stores the
///    token in the system keyring instead of the file.
struct CopilotAuthStore: Sendable {
    static let editorAppsPath = "~/.config/github-copilot/apps.json"
    static let editorHostsPath = "~/.config/github-copilot/hosts.json"
    static let ghHostsPath = "~/.config/gh/hosts.yml"
    static let ghKeychainService = "gh:github.com"

    var files: TextFileAccessing
    var keychain: KeychainAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor()
    ) {
        self.files = files
        self.keychain = keychain
    }

    /// First non-empty source wins. Broken sources are retained as a deferred error while later
    /// siblings are tried; the provider surfaces that error only when no valid token loads.
    /// Blocking (files + Keychain) — call off the main actor.
    func loadTokenResult() -> CopilotAuthLoadResult {
        var firstError: CopilotAuthError?

        do {
            if let token = try loadFromEditorConfig() {
                return CopilotAuthLoadResult(token: token, firstError: nil)
            }
        } catch let error as CopilotAuthError {
            firstError = error
        } catch {
            AppLog.error(LogTag.auth("copilot"), "unexpected editor credential load failure")
            firstError = .credentialStoreUnreadable
        }

        var ghConfig: GhConfig?
        do {
            ghConfig = try loadGhConfig()
            if let token = ghConfig?.token {
                return CopilotAuthLoadResult(token: token, firstError: nil)
            }
        } catch let error as CopilotAuthError {
            if firstError == nil { firstError = error }
        } catch {
            AppLog.error(LogTag.auth("copilot"), "unexpected GitHub CLI credential load failure")
            if firstError == nil { firstError = .credentialStoreUnreadable }
        }

        do {
            if let token = try loadFromGhKeychain(account: ghConfig?.username) {
                return CopilotAuthLoadResult(token: token, firstError: nil)
            }
        } catch let error as CopilotAuthError {
            if firstError == nil { firstError = error }
        } catch {
            AppLog.error(LogTag.auth("copilot"), "unexpected keychain credential load failure")
            if firstError == nil { firstError = .credentialStoreUnreadable }
        }

        return CopilotAuthLoadResult(token: nil, firstError: firstError)
    }

    /// Compatibility view for callers/tests that only need a successfully loaded token.
    func loadToken() -> CopilotToken? {
        loadTokenResult().token
    }

    // MARK: - Sources

    func loadFromEditorConfig() throws -> CopilotToken? {
        var firstError: CopilotAuthError?
        for path in [Self.editorAppsPath, Self.editorHostsPath] {
            let text: String
            do {
                guard let stored = try files.readTextIfPresent(path) else { continue }
                text = stored
            } catch {
                AppLog.error(LogTag.auth("copilot"), "editor credential file read failed")
                if firstError == nil { firstError = .credentialStoreUnreadable }
                continue
            }

            switch Self.editorToken(fromJSON: text) {
            case .token(let token):
                return CopilotToken(value: token)
            case .compatibleAccountAbsent:
                // Enterprise-only files are valid but cannot authenticate api.github.com. Keep
                // walking to the older editor file, gh config, and Keychain.
                continue
            case .invalid:
                AppLog.error(LogTag.auth("copilot"), "editor credential file is malformed")
                if firstError == nil { firstError = .invalidCredentialData }
            }
        }
        if let firstError { throw firstError }
        return nil
    }

    private struct GhConfig {
        var token: CopilotToken?
        var username: String?
    }

    private func loadGhConfig() throws -> GhConfig? {
        let text: String
        do {
            guard let stored = try files.readTextIfPresent(Self.ghHostsPath) else { return nil }
            text = stored
        } catch {
            AppLog.error(LogTag.auth("copilot"), "GitHub CLI credential file read failed")
            throw CopilotAuthError.credentialStoreUnreadable
        }

        guard Self.isPlausibleHostsYAML(text) else {
            AppLog.error(LogTag.auth("copilot"), "GitHub CLI credential file is malformed")
            throw CopilotAuthError.invalidCredentialData
        }

        let token = Self.yamlValue(text, key: "oauth_token").map(CopilotToken.init(value:))
        let username = Self.yamlValue(text, key: "user")
        return GhConfig(token: token, username: username)
    }

    private func loadFromGhKeychain(account: String?) throws -> CopilotToken? {
        var firstError: CopilotAuthError?

        if let account {
            do {
                if let raw = try keychain.readGenericPassword(service: Self.ghKeychainService, account: account) {
                    if let token = ProviderParse.unwrapGoKeyring(raw) {
                        return CopilotToken(value: token)
                    }
                    AppLog.error(LogTag.auth("copilot"), "account-scoped keychain credential is malformed")
                    firstError = .invalidCredentialData
                }
            } catch {
                AppLog.error(LogTag.auth("copilot"), "account-scoped keychain credential read failed")
                firstError = .credentialStoreUnreadable
            }
        }

        do {
            if let raw = try keychain.readGenericPassword(service: Self.ghKeychainService) {
                guard let token = ProviderParse.unwrapGoKeyring(raw) else {
                    AppLog.error(LogTag.auth("copilot"), "keychain credential is malformed")
                    throw CopilotAuthError.invalidCredentialData
                }
                return CopilotToken(value: token)
            }
        } catch let error as CopilotAuthError {
            if firstError == nil { firstError = error }
        } catch {
            AppLog.error(LogTag.auth("copilot"), "keychain credential read failed")
            if firstError == nil { firstError = .credentialStoreUnreadable }
        }

        if let firstError { throw firstError }
        return nil
    }

    // MARK: - Parsing (pure)

    /// Pull a github.com `oauth_token` from the Copilot editor config. The file is a JSON object keyed by
    /// host — `"github.com"` (older `hosts.json`) or `"github.com:<appId>"` (newer `apps.json`) — each
    /// value an object carrying `oauth_token`. Only github.com entries are used: another host's token
    /// (e.g. GitHub Enterprise) must not be sent to api.github.com, and returning `nil` lets the chain
    /// fall through to gh config / keychain, which may hold a valid github.com token.
    static func oauthToken(fromEditorJSON text: String) -> String? {
        guard case .token(let token) = editorToken(fromJSON: text) else { return nil }
        return token
    }

    private enum EditorTokenParse {
        case token(String)
        case compatibleAccountAbsent
        case invalid
    }

    private static func editorToken(fromJSON text: String) -> EditorTokenParse {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalid
        }

        func token(in value: Any?) -> String? {
            guard let dict = value as? [String: Any],
                  let token = (dict["oauth_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty
            else {
                return nil
            }
            return token
        }

        let compatible = object.filter { key, _ in key == "github.com" || key.hasPrefix("github.com:") }
        guard !compatible.isEmpty else { return .compatibleAccountAbsent }
        for (_, value) in compatible {
            if let token = token(in: value) { return .token(token) }
        }
        return .invalid
    }

    /// Narrow validation for the simple host map `gh` writes. Enterprise-only files remain valid and
    /// simply produce no github.com token; empty/garbled lines are treated as malformed credentials.
    private static func isPlausibleHostsYAML(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else { return false }
        var sawRootHeader = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if line.first?.isWhitespace == true {
                guard trimmed.contains(":") else { return false }
            } else {
                guard trimmed.hasSuffix(":"), !trimmed.dropLast().isEmpty else { return false }
                sawRootHeader = true
            }
        }
        return sawRootHeader
    }

    /// Read an indented `key: value` from within a specific host block of the `hosts.yml` GitHub CLI
    /// writes. `gh` keys each host block by a top-level (unindented) `<host>:` line; reading must be
    /// scoped to the `github.com` block, because a GitHub Enterprise block in the same file would
    /// otherwise let its `oauth_token` win and get sent to api.github.com (a guaranteed 401/403).
    /// `users:` (the nested map) doesn't match `user:` because the colon position differs.
    static func yamlValue(_ text: String, key: String, host: String = "github.com") -> String? {
        let prefix = key + ":"
        let hostHeader = host + ":"
        var inHost = false
        for line in text.split(whereSeparator: \.isNewline) {
            // An unindented line starts a new top-level block (a host header or other root key); only
            // the github.com block's children should be read.
            if let first = line.first, !first.isWhitespace {
                inHost = line.trimmingCharacters(in: .whitespaces) == hostHeader
                continue
            }
            guard inHost else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return unquoted.isEmpty ? nil : unquoted
        }
        return nil
    }

}
