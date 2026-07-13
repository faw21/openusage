import Foundation

/// The result of a local OpenCode scan: every provider's daily session usage (for the spend tiles +
/// trend, via `SpendTileMapper`) and the Go-only plan windows (for the meters). `goWindows` is `nil`
/// when the machine has no `opencode-go` footprint, so external-auth users see usage without empty caps.
struct OpenCodeUsageScan: Sendable {
    var logScan: LogUsageScan
    var goWindows: OpenCodeGoWindows?
    var warning: String?
}

/// Reads OpenCode's local SQLite logs (`~/.local/share/opencode/opencode*.db`, all release channels) and
/// builds the usage the provider renders. Cookie-free and network-free: positive per-message API-rate
/// values are kept from OpenCode's logs. A zero-cost external row (for example ChatGPT OAuth) is priced
/// through OpenUsage's shared catalog when possible. Rows that cannot be priced are excluded from both
/// token and dollar totals so the figures always describe the same usage.
///
/// A `Sendable` struct (like the Grok scanner), `async` and nonisolated, so the SQLite reads run off the
/// main actor when the `@MainActor` provider `await`s it.
struct OpenCodeUsageScanner: Sendable {
    /// OpenCode-hosted provider IDs use their recorded accounting value, including a legitimate zero.
    /// Every other provider ID is still scanned, but a zero recorded cost may be imputed locally.
    static let hostedProviderIDs: Set<String> = ["opencode-go", "opencode"]
    static let goProviderID = "opencode-go"

    var sqlite: SQLiteAccessing
    var databasePaths: @Sendable () throws -> [String]
    private let readFailureReporter: UsageLogReadFailureReporter
    private let invalidCostReporter: UsageLogReadFailureReporter

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: @escaping @Sendable () throws -> [String] = OpenCodeUsageScanner.defaultDatabasePaths,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.sqlite = sqlite
        self.databasePaths = databasePaths
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("opencode"),
            warning: readFailureWarning
        )
        self.invalidCostReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("opencode"),
            warning: { _ in
                AppLog.warn(
                    LogTag.plugin("opencode"),
                    "Found completed hosted OpenCode usage with invalid cost data; excluding affected usage"
                )
            }
        )
    }

    static let defaultDatabasePaths: @Sendable () throws -> [String] = {
        let dir = OpenCodePaths.dataDirectory(
            environment: ProcessEnvironmentReader(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        return try OpenCodePaths.databaseFiles(in: dir)
    }

    /// Scan the last `daysBack` days. Returns `nil` only when there is no OpenCode database at all (→ the
    /// provider shows "No data"); a present-but-empty database yields an empty scan (idle tiles collapse
    /// to "No data" via `SpendTileMapper`). Throws `databaseUnreadable` when databases exist but none
    /// could be read — an all-failed refresh has no data source and must not render as zero usage.
    /// 33 days covers the widest meter window (anchored month) plus slack; the tiles/trend are
    /// re-bounded to 31 calendar days below.
    func scan(
        now: Date,
        daysBack: Int = 33,
        hasGoKey: Bool = false,
        pricing: ModelPricing = .empty
    ) async throws -> OpenCodeUsageScan? {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            // The data directory exists but couldn't be enumerated — same failure class as unreadable
            // databases, edge-logged through the reporter so a persistent failure doesn't spam.
            let marker = "<data directory>"
            let newlyFailing = await readFailureReporter.update(checkedPaths: [marker], failingPaths: [marker])
            if !newlyFailing.isEmpty {
                AppLog.warn(LogTag.plugin("opencode"), "data directory unreadable: \(error.localizedDescription)")
            }
            throw OpenCodeUsageError.databaseUnreadable
        }
        guard !paths.isEmpty else {
            await readFailureReporter.update(checkedPaths: [], failingPaths: [])
            return nil
        }

        let cutoffMs = Int((now.timeIntervalSince1970 - Double(daysBack) * 86_400) * 1000)
        var rows: [Row] = []
        var anchorMs: Double?
        var checked: Set<String> = []
        var failures: [String: String] = [:]

        for path in paths {
            checked.insert(path)
            do {
                if let json = try sqlite.queryValue(path: path, sql: Self.dataSQL(cutoffMs: cutoffMs)) {
                    rows.append(contentsOf: Self.parseRows(json))
                }
            } catch {
                failures[path] = error.localizedDescription
                continue
            }
            // Monthly cycle anchor: the earliest-ever local Go usage (unbounded, so it survives the
            // day-window cutoff). Cheap and best-effort — a failure just falls back to the calendar month.
            if let text = (try? sqlite.queryValue(path: path, sql: Self.anchorSQL)) ?? nil,
               let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                anchorMs = Swift.min(anchorMs ?? value, value)
            }
        }
        // Per-path detail is logged only for newly failing paths (the reporter edge-triggers), so a
        // persistently locked database warns once, not on every 5-minute refresh.
        let newlyFailing = await readFailureReporter.update(checkedPaths: checked, failingPaths: Set(failures.keys))
        for path in newlyFailing.sorted() {
            AppLog.warn(LogTag.plugin("opencode"), "usage query failed for \(path): \(failures[path] ?? "unknown error")")
        }
        if failures.count == checked.count {
            throw OpenCodeUsageError.databaseUnreadable
        }

        // OpenCode may copy sessions between release-channel databases. Message IDs are stable, so union
        // those files without double-counting copied rows. Prefer the newest, most complete copy instead
        // of whichever release-channel filename happened to sort first.
        rows = Self.deduplicated(rows.filter(\.hasExplicitCompletion))

        // A malformed hosted cost is not a legitimate free message. Exclude its usage, surface a soft
        // warning, and suppress Go meters only when the bad record belongs to Go. The reporter
        // edge-triggers the log once until the bad row ages out or is repaired.
        let invalidHostedCost = rows.contains {
            Self.hostedProviderIDs.contains($0.providerID) && $0.recordedCost == nil && $0.tokens > 0
        }
        let invalidGoCost = rows.contains {
            $0.providerID == Self.goProviderID && $0.recordedCost == nil && $0.tokens > 0
        }
        let invalidCostMarker = "<invalid hosted cost>"
        await invalidCostReporter.update(
            checkedPaths: [invalidCostMarker],
            failingPaths: invalidHostedCost ? [invalidCostMarker] : []
        )
        let warning: String? = if invalidGoCost {
            "Some completed OpenCode messages have invalid cost data. Affected usage and Go meters are unavailable."
        } else if invalidHostedCost {
            "Some completed OpenCode messages have invalid cost data. Affected usage is excluded from totals."
        } else {
            nil
        }

        // All-provider daily series → spend tiles + usage trend. Hosted values and positive external
        // API-rate values stay as OpenCode recorded them. Zero-cost external rows are imputed from their
        // non-overlapping token buckets; rows that cannot be priced stay out of both totals and surface
        // through the unknown-model warning.
        let tileSince = JSONLScanning.sinceDate(daysBack: 30, now: now)
        var accumulator = DailyUsageAccumulator()
        for row in rows {
            let date = Date(timeIntervalSince1970: row.ms / 1000)
            guard date >= tileSince else { continue }
            let day = DailyUsageAccumulator.dayKey(from: date)
            let displayModel = row.displayModel

            if Self.hostedProviderIDs.contains(row.providerID) {
                if let recordedCost = row.recordedCost {
                    accumulator.add(day: day, tokens: row.tokens, cost: recordedCost, model: displayModel)
                } else if row.tokens > 0 {
                    accumulator.addUnknownModel(day: day, model: displayModel)
                }
                continue
            }
            if let recordedCost = row.recordedCost, recordedCost > 0 {
                // OpenCode derives external costs from model metadata. Keep its positive value, but the
                // provider marks every dollar as an API-rate estimate at the display boundary.
                accumulator.add(day: day, tokens: row.tokens, cost: recordedCost, model: displayModel)
                continue
            }

            // Without component buckets there is no honest way to price a total-only record. Exclude it
            // from both totals and surface the incomplete-dollar warning instead of inventing $0.
            guard row.bucketTokens > 0 else {
                if row.tokens > 0 {
                    accumulator.addUnknownModel(day: day, model: displayModel)
                }
                continue
            }
            let tokenBreakdown = TokenBreakdown(
                input: row.input,
                cacheWrite5m: row.cacheWrite,
                cacheRead: row.cacheRead,
                output: row.output + row.reasoning
            )
            let estimated = Self.estimatedCost(
                providerID: row.providerID,
                model: row.model,
                tokens: tokenBreakdown,
                pricing: pricing
            )
            if let estimated {
                accumulator.add(day: day, tokens: row.tokens, cost: estimated, model: displayModel)
            } else if row.tokens > 0 {
                accumulator.addUnknownModel(day: day, model: displayModel)
            }
        }
        let logScan = accumulator.build()

        // Go-only windows → the Session / Weekly / Monthly caps. Shown only on a CURRENT Go signal: the
        // user is logged into Go (`hasGoKey`), or has spent on Go within the window. A stale anchor from
        // old usage must NOT resurrect the caps or the "Go" plan for a lapsed or Zen-only user — the
        // anchor only sets the monthly-cycle boundary once we've decided to show the meters.
        let goCosts = rows
            .compactMap { row -> (ms: Double, cost: Double)? in
                guard row.providerID == Self.goProviderID, let cost = row.recordedCost else { return nil }
                return (ms: row.ms, cost: cost)
            }
        let goWindows: OpenCodeGoWindows? = !invalidGoCost && (hasGoKey || !goCosts.isEmpty)
            ? OpenCodeGoWindowMath.compute(costs: goCosts, anchorMs: anchorMs, now: now)
            : nil

        return OpenCodeUsageScan(logScan: logScan, goWindows: goWindows, warning: warning)
    }

    /// OpenCode stores a few provider/model spellings that differ from the public pricing catalogs.
    /// Prefer provider-qualified exact matches, then bare exact matches, before allowing a bare fuzzy
    /// lookup. That keeps reseller-specific rates authoritative without letting an unrelated fuzzy
    /// provider key shadow a known bare model.
    private static func estimatedCost(
        providerID: String,
        model: String,
        tokens: TokenBreakdown,
        pricing: ModelPricing
    ) -> Double? {
        let models = pricingModelCandidates(model)
        let normalizedProvider = providerID.replacingOccurrences(of: "-", with: "_")
        var qualified = ["\(providerID)/\(model)"]
        for candidate in models where candidate != model {
            qualified.append("\(providerID)/\(candidate)")
        }
        if normalizedProvider != providerID {
            qualified.append("\(normalizedProvider)/\(model)")
            for candidate in models where candidate != model {
                qualified.append("\(normalizedProvider)/\(candidate)")
            }
        }

        for candidate in unique(qualified) {
            if let cost = pricing.estimatedCostDollarsExact(model: candidate, tokens: tokens) {
                return cost
            }
        }
        for candidate in models {
            if let cost = pricing.estimatedCostDollarsExact(model: candidate, tokens: tokens) {
                return cost
            }
        }
        for candidate in models {
            if let cost = pricing.estimatedCostDollars(model: candidate, tokens: tokens) {
                return cost
            }
        }
        return nil
    }

    private static func pricingModelCandidates(_ model: String) -> [String] {
        let normalized: String = switch model {
        case "k2p6": "kimi-k2.6"
        case "gemini-3-pro-high": "gemini-3-pro-preview"
        default: normalizedClaudeModel(model)
        }
        return unique([normalized, model])
    }

    /// OpenCode has emitted both dotted (`claude-sonnet-4.5`) and compact
    /// (`claude-sonnet-45`) family versions; catalogs use `claude-sonnet-4-5`.
    private static func normalizedClaudeModel(_ model: String) -> String {
        let prefixes = ["claude-haiku-", "claude-opus-", "claude-sonnet-"]
        guard let prefix = prefixes.first(where: model.hasPrefix) else { return model }
        let suffix = String(model.dropFirst(prefix.count))
        let characters = Array(suffix)
        guard characters.count >= 2, characters[0].isNumber else { return model }

        if characters.count >= 3, characters[1] == ".", characters[2].isNumber {
            return prefix + String(characters[0]) + "-" + String(characters.dropFirst(2))
        }
        if characters[1].isNumber, characters.count == 2 || characters[2] == "-" {
            return prefix + String(characters[0]) + "-" + String(characters.dropFirst())
        }
        return model
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    /// Cheap local probe for `hasLocalCredentials()`: does any tracked database hold an assistant row
    /// from any provider? Read-only, no network. Failures are logged (this runs only
    /// during first-run / new-provider detection, so there's no refresh spam to throttle); an unreadable
    /// data directory counts as an OpenCode footprint so `refresh()` gets to surface the real error.
    func hasUsage() -> Bool {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            AppLog.warn(LogTag.plugin("opencode"), "usage probe: data directory unreadable: \(error.localizedDescription)")
            return true
        }
        for path in paths {
            do {
                if let value = try sqlite.queryValue(path: path, sql: Self.probeSQL), !value.isEmpty {
                    return true
                }
            } catch {
                AppLog.warn(LogTag.plugin("opencode"), "usage probe failed for \(path): \(error.localizedDescription)")
            }
        }
        return false
    }

    // MARK: - Parsing

    private struct Row {
        var ms: Double
        var recordedCost: Double?
        var tokens: Int
        var model: String
        var providerID: String
        var input: Int
        var cacheRead: Int
        var cacheWrite: Int
        var output: Int
        var reasoning: Int
        var messageID: String?
        var hasExplicitCompletion: Bool

        var bucketTokens: Int {
            min(input + cacheRead + cacheWrite + output + reasoning, 1_000_000_000_000_000)
        }

        var qualifiedModel: String {
            let modelName = model.isEmpty ? ModelUsageEntry.unattributedModelName : model
            return "\(providerID)/\(modelName)"
        }

        var displayModel: String {
            OpenCodeUsageScanner.hostedProviderIDs.contains(providerID)
                ? (model.isEmpty ? ModelUsageEntry.unattributedModelName : model)
                : qualifiedModel
        }
    }

    /// Parse the `json_group_array(json_array(...))` payload: an array of
    /// `[completedAt, cost, total, modelID, providerID, input, cacheRead, cacheWrite, output, reasoning,
    /// messageID, hasExplicitCompletion]`. Rows with a missing timestamp or provider ID are skipped at
    /// this boundary. Production SQL always supplies the explicit-completion column; the shorter form is
    /// retained only for direct parser compatibility with older tests and callers.
    private static func parseRows(_ json: String) -> [Row] {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }

        var rows: [Row] = []
        rows.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count >= 10,
                  let ms = ProviderParse.number(entry[0]),
                  let providerID = (entry[4] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !providerID.isEmpty
            else { continue }

            let input = clampedTokens(entry[5])
            let cacheRead = clampedTokens(entry[6])
            let cacheWrite = clampedTokens(entry[7])
            let output = clampedTokens(entry[8])
            let reasoning = clampedTokens(entry[9])
            let bucketTotal = min(input + cacheRead + cacheWrite + output + reasoning, 1_000_000_000_000_000)
            let storedTotal = ProviderParse.number(entry[2]).map(clampedTokens) ?? 0
            // OpenCode's stats path treats the non-overlapping buckets as canonical. Fall back to the
            // optional provider total only for legacy total-only records.
            let tokens = bucketTotal > 0 ? bucketTotal : storedTotal
            let recordedCost = ProviderParse.number(entry[1]).flatMap { $0 >= 0 ? $0 : nil }
            let model = ((entry[3] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let messageID = (entry.count > 10 ? entry[10] as? String : nil)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let hasExplicitCompletion = entry.count <= 11 || (ProviderParse.number(entry[11]) ?? 0) > 0
            rows.append(Row(
                ms: ms,
                recordedCost: recordedCost,
                tokens: tokens,
                model: model,
                providerID: providerID,
                input: input,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                output: output,
                reasoning: reasoning,
                messageID: messageID,
                hasExplicitCompletion: hasExplicitCompletion
            ))
        }
        return rows
    }

    /// Clamp before converting so corrupt values above `Int.max` cannot trap. 1e15 is far beyond any
    /// real per-message token count while leaving ample headroom for additions on 64-bit macOS.
    private static func clampedTokens(_ value: Any) -> Int {
        clampedTokens(ProviderParse.number(value) ?? 0)
    }

    private static func clampedTokens(_ value: Double) -> Int {
        Int(min(max(value, 0), 1_000_000_000_000_000))
    }

    private static func deduplicated(_ rows: [Row]) -> [Row] {
        var withoutID: [Row] = []
        var byID: [String: Row] = [:]
        for row in rows {
            guard let messageID = row.messageID else {
                withoutID.append(row)
                continue
            }
            guard let existing = byID[messageID] else {
                byID[messageID] = row
                continue
            }
            if rowIsPreferred(row, over: existing) {
                byID[messageID] = row
            }
        }
        return withoutID + byID.values
    }

    private static func rowIsPreferred(_ candidate: Row, over existing: Row) -> Bool {
        if candidate.ms != existing.ms { return candidate.ms > existing.ms }
        if (candidate.recordedCost != nil) != (existing.recordedCost != nil) {
            return candidate.recordedCost != nil
        }
        if candidate.bucketTokens != existing.bucketTokens {
            return candidate.bucketTokens > existing.bucketTokens
        }
        if candidate.tokens != existing.tokens { return candidate.tokens > existing.tokens }
        return (candidate.recordedCost ?? 0) > (existing.recordedCost ?? 0)
    }

    // MARK: - SQL

    static func dataSQL(cutoffMs: Int) -> String {
        let creationCutoffMs = cutoffMs - 7 * 86_400_000
        return """
        SELECT json_group_array(json_array(
                 COALESCE(json_extract(data,'$.time.completed'),time_created),
                 json_extract(data,'$.cost'),
                 COALESCE(
                   json_extract(data,'$.tokens.total'),
                   COALESCE(json_extract(data,'$.tokens.input'),0)
                     + COALESCE(json_extract(data,'$.tokens.output'),0)
                     + COALESCE(json_extract(data,'$.tokens.reasoning'),0)
                     + COALESCE(json_extract(data,'$.tokens.cache.read'),0)
                     + COALESCE(json_extract(data,'$.tokens.cache.write'),0)),
                 json_extract(data,'$.modelID'),
                 json_extract(data,'$.providerID'),
                 COALESCE(json_extract(data,'$.tokens.input'),0),
                 COALESCE(json_extract(data,'$.tokens.cache.read'),0),
                 COALESCE(json_extract(data,'$.tokens.cache.write'),0),
                 COALESCE(json_extract(data,'$.tokens.output'),0),
                 COALESCE(json_extract(data,'$.tokens.reasoning'),0),
                 id,
                 CASE WHEN json_type(data,'$.time.completed') IN ('integer','real')
                            OR json_type(data,'$.finish') = 'text'
                      THEN 1 ELSE 0 END))
        FROM message
        WHERE time_created >= \(creationCutoffMs)
          AND json_valid(data)
          AND COALESCE(json_extract(data,'$.time.completed'),time_created) >= \(cutoffMs)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_type(data,'$.providerID') = 'text'
          AND TRIM(json_extract(data,'$.providerID')) <> '';
        """
    }

    static let anchorSQL = """
        SELECT MIN(time_created) FROM message
        WHERE json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_extract(data,'$.providerID') = '\(goProviderID)'
          AND json_type(data,'$.cost') IN ('integer','real')
          AND (json_type(data,'$.time.completed') IN ('integer','real')
               OR json_type(data,'$.finish') = 'text');
        """

    static let probeSQL = """
        SELECT 1 FROM message
        WHERE json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_type(data,'$.providerID') = 'text'
          AND TRIM(json_extract(data,'$.providerID')) <> ''
        LIMIT 1;
        """
}
