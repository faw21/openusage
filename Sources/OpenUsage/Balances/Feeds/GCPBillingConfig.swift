import Foundation

/// Configuration for the GCP current-month spend card. There is no API-key path for GCP billing, so the
/// only reliable figure comes from a BigQuery billing export the user has enabled. Point us at that table
/// via `~/.config/openusage/gcp.json`:
/// `{"bqTable":"project.dataset.gcp_billing_export_v1_XXXX", "bqBinary":"/opt/homebrew/bin/bq"}`
/// (`bqBinary` optional). `GCP_BILLING_BQ_TABLE` / `GCP_BQ_BINARY` env vars are also honored.
struct GCPBillingConfig: Sendable {
    var bqTable: String?
    var bqBinary: String?

    static func load(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) -> GCPBillingConfig {
        var table = environment.value(for: "GCP_BILLING_BQ_TABLE")?.trimmingCharacters(in: .whitespacesAndNewlines)
        var binary = environment.value(for: "GCP_BQ_BINARY")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text = try? files.readText("~/.config/openusage/gcp.json"),
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            table = (object["bqTable"] as? String) ?? table
            binary = (object["bqBinary"] as? String) ?? binary
        }
        if table?.isEmpty == true { table = nil }
        return GCPBillingConfig(bqTable: table, bqBinary: binary)
    }

    /// Resolve the `bq` executable: explicit config, then common Cloud SDK install locations, then the
    /// captured login-shell PATH (a Finder-launched app doesn't inherit an interactive PATH).
    func resolveBQ(environment: EnvironmentReading = ProcessEnvironmentReader()) -> String? {
        let fileManager = FileManager.default
        if let bqBinary, !bqBinary.isEmpty, fileManager.isExecutableFile(atPath: bqBinary) { return bqBinary }
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/bq",
            "/usr/local/bin/bq",
            "/opt/homebrew/share/google-cloud-sdk/bin/bq",
            "/usr/local/share/google-cloud-sdk/bin/bq",
            "\(home)/google-cloud-sdk/bin/bq"
        ]
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) { return candidate }
        if let path = environment.value(for: "PATH") {
            for directory in path.split(separator: ":") {
                let candidate = "\(directory)/bq"
                if fileManager.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    /// Login-shell PATH handed to the child so `bq`'s own `python`/`gcloud` lookups resolve.
    static func childEnvironment(environment: EnvironmentReading = ProcessEnvironmentReader()) -> [String: String] {
        guard let path = environment.value(for: "PATH"), !path.isEmpty else { return [:] }
        return ["PATH": path]
    }
}
