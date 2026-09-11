import Foundation

/// Thin wrapper over `UserAPIKeyStore` for the desktop widget's balance sources: a key at
/// `~/.config/openusage/<name>.json` (JSON `apiKey`/`api_key`/`key`, or plain text), with environment
/// fallbacks. Mirrors how the OpenRouter/Z.ai providers resolve a user-supplied key, so dropping a file
/// under `~/.config/openusage/` is all it takes to light a card up.
struct BalanceKeyStore: Sendable {
    private let store: UserAPIKeyStore

    /// `files`/`environment` default to the real machine; the provider auth stores take the same pair so
    /// tests can point a key lookup at a fixture instead of the developer's own `~/.config`.
    init(
        name: String,
        environmentNames: [String] = [],
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        store = UserAPIKeyStore(
            configPaths: ["~/.config/openusage/\(name).json"],
            environmentNames: environmentNames,
            files: files,
            environment: environment,
            makeError: { _ in BalanceKeyError.saveFailed }
        )
    }

    func key() -> String? { store.loadKey() }
    func status() -> APIKeyStatus { store.keyStatus() }
    func save(_ key: String) throws { try store.saveKey(key) }
    func clear() throws { try store.deleteKey() }
}

enum BalanceKeyError: Error { case saveFailed }
