import Foundation

/// Builds metric lines from the Z.ai `/api/monitor/usage/quota/limit` payload and the plan name from
/// `/api/biz/subscription/list`. Ports and extends the legacy Tauri plugin's mapping:
/// - a `TOKENS_LIMIT` entry whose window is sub-daily (`unit: 3`, hours) is the 5-hour session meter,
/// - a `TOKENS_LIMIT` entry whose window is multi-day (`unit: 6`, weeks) is the weekly meter,
/// - a `TIME_LIMIT` entry (`unit: 5`, monthly) is the web-search/reader count meter (used / limit).
///
/// Both endpoints are undocumented internal APIs used by Z.ai's own subscription UI; the response
/// shapes are stable in practice. The mapper is pure (no I/O) so it tests cleanly against sample
/// payloads, exactly like the legacy plugin's fixture-based tests.
enum ZAIUsageMapper {
    /// One monthly web-search cycle, in milliseconds (Z.ai reports `unit: 5, number: 1`). The session
    /// and weekly meters instead carry the *payload's* actual window (see `classifyTokenWindow`), so
    /// their cadence tracks the plan rather than a hardcoded assumption; this monthly constant is only a
    /// fallback for the web-search line and the widget-descriptor default.
    static let monthlyPeriodMs = 30 * 24 * 60 * 60 * 1000

    /// `(plan, lines)` from the quota + subscription payloads. `subscription` may be `nil` (the
    /// request is best-effort) and the quota's `limits` array may carry one to three entries — only
    /// what's present is mapped, so a plan without web searches still shows the session meter.
    static func map(quotaBody: Data, subscriptionBody: Data?) throws -> (plan: String?, lines: [MetricLine]) {
        let plan = subscriptionBody.flatMap { planName(from: $0) }
        let lines = try mapQuota(quotaBody)
        return (plan, lines)
    }

    /// Session + weekly + web-search meters from the quota payload. Only an explicit, correctly-shaped
    /// empty `limits` array means "No usage data"; malformed envelopes, business failures, and nonempty
    /// arrays that cannot produce a valid meter are errors rather than silent empty-state fallbacks.
    static func mapQuota(_ body: Data) throws -> [MetricLine] {
        guard let root = ProviderParse.jsonObject(body) else {
            throw ZAIUsageError.invalidResponse
        }

        if let successValue = root["success"] {
            guard let success = jsonBoolean(successValue) else {
                throw ZAIUsageError.invalidResponse
            }
            if !success {
                if isNoCodingPlan(root) {
                    throw ZAIUsageError.noCodingPlan
                }
                throw ZAIUsageError.businessFailure(code: businessCode(root))
            }
        }

        // The limits array lives under `data.limits`; the legacy plugin also tolerated the root object
        // being the container directly (no `data` wrapper), so honor both.
        let container: [String: Any]
        if let data = root["data"] {
            guard let data = data as? [String: Any] else {
                throw ZAIUsageError.invalidResponse
            }
            container = data
        } else {
            container = root
        }
        guard let rawLimits = container["limits"],
              let limits = rawLimits as? [[String: Any]] else {
            throw ZAIUsageError.invalidResponse
        }
        guard !limits.isEmpty else {
            return [.noUsageData]
        }

        var lines: [MetricLine] = []

        // Split the TOKENS_LIMIT entries by window length: a sub-daily window is the session meter,
        // a multi-day window is the weekly meter. Z.ai reports both, and both are percentage meters.
        let tokenLimits = limits.filter { ($0["type"] as? String) == "TOKENS_LIMIT" || ($0["name"] as? String) == "TOKENS_LIMIT" }
        for entry in tokenLimits {
            switch try classifyTokenWindow(entry) {
            case .session(let periodMs):
                lines.append(try percentLine(entry, label: "Session", periodMs: periodMs))
            case .weekly(let periodMs):
                lines.append(try percentLine(entry, label: "Weekly", periodMs: periodMs))
            }
        }
        if let web = findLimit(limits, type: "TIME_LIMIT") {
            lines.append(try webSearchLine(from: web))
        }

        guard !lines.isEmpty else {
            throw ZAIUsageError.invalidResponse
        }
        return lines
    }

    /// `productName` from the first valid subscription entry (e.g. "GLM Coding Max").
    static func planName(from body: Data) -> String? {
        guard let root = ProviderParse.jsonObject(body),
              let list = root["data"] as? [[String: Any]],
              let first = list.first,
              let name = (first["productName"] as? String)?.nilIfEmpty
        else {
            return nil
        }
        return name
    }

    // MARK: - Private

    /// How a `TOKENS_LIMIT` entry's window maps to a meter. Z.ai encodes the window as a `(unit, number)`
    /// pair: `unit: 3` is hours (session), `unit: 6` is weeks (weekly), `unit: 5` is months. A sub-daily
    /// window is the session meter and a multi-day window is the weekly meter. A recognized token-limit
    /// entry with an unknown/missing window is invalid schema, not an empty quota.
    private enum TokenWindow {
        case session(periodMs: Int)
        case weekly(periodMs: Int)
    }

    private static func classifyTokenWindow(_ entry: [String: Any]) throws -> TokenWindow {
        let periodMs = try periodDurationMs(for: entry)
        // Sub-daily → session; multi-day → weekly. The computed window rides along so the meter's
        // cadence reflects the payload instead of a hardcoded constant.
        if periodMs < 24 * 60 * 60 * 1000 {
            return .session(periodMs: periodMs)
        }
        return .weekly(periodMs: periodMs)
    }

    /// Resolve a `(unit, number)` window to milliseconds. `unit` is Z.ai's internal time-unit code.
    private static func periodDurationMs(for entry: [String: Any]) throws -> Int {
        guard let unit = quotaNumber(entry["unit"]),
              let number = quotaNumber(entry["number"]),
              number > 0 else {
            throw ZAIUsageError.invalidResponse
        }
        let unitMs: Double
        switch unit {
        case 3: unitMs = 60 * 60 * 1000           // hours
        case 4: unitMs = 24 * 60 * 60 * 1000      // days
        case 6: unitMs = 7 * 24 * 60 * 60 * 1000  // weeks
        case 5: unitMs = 30 * 24 * 60 * 60 * 1000 // months
        default: throw ZAIUsageError.invalidResponse
        }
        let periodMs = unitMs * number
        guard periodMs >= 1, periodMs < Double(Int.max) else {
            throw ZAIUsageError.invalidResponse
        }
        return Int(periodMs)
    }

    /// A percentage meter (Session or Weekly) from a `TOKENS_LIMIT` entry.
    private static func percentLine(_ entry: [String: Any], label: String, periodMs: Int) throws -> MetricLine {
        guard let rawPercentage = quotaNumber(entry["percentage"]) else {
            throw ZAIUsageError.invalidResponse
        }
        let percentage = ProviderParse.clampPercent(rawPercentage)
        let resetsAt = try optionalNumber(entry["nextResetTime"]).map { epochMsToDate($0) }
        return .progress(
            label: label,
            used: percentage,
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: periodMs
        )
    }

    /// TIME_LIMIT → a count meter (used / limit) for monthly web-search/reader calls.
    private static func webSearchLine(from entry: [String: Any]) throws -> MetricLine {
        guard let rawUsed = quotaNumber(entry["currentValue"]),
              let rawLimit = quotaNumber(entry["usage"]),
              rawUsed >= 0,
              rawLimit >= 0 else {
            throw ZAIUsageError.invalidResponse
        }
        // TIME_LIMIT carries a nextResetTime in current payloads (monthly renewal); honor it when
        // present so the countdown shows the real reset, otherwise the period cadence reads "monthly".
        let resetsAt = try optionalNumber(entry["nextResetTime"]).map { epochMsToDate($0) }
        return .progress(
            label: "Web Searches",
            used: rawUsed,
            limit: rawLimit,
            format: .count(suffix: "searches"),
            resetsAt: resetsAt,
            periodDurationMs: monthlyPeriodMs
        )
    }

    /// A limit entry matches by `type` or `name`; the legacy plugin checked both because Z.ai's
    /// payload has used either field across revisions.
    private static func findLimit(_ limits: [[String: Any]], type: String) -> [String: Any]? {
        for entry in limits {
            if (entry["type"] as? String) == type || (entry["name"] as? String) == type {
                return entry
            }
        }
        return nil
    }

    /// The known "valid key, no GLM Coding Plan" business response includes `success:false` and an
    /// absence phrase around "coding plan" inside its otherwise-localized message. A generic service
    /// failure that merely mentions coding plans must remain a business error.
    private static func isNoCodingPlan(_ root: [String: Any]) -> Bool {
        let message = ((root["msg"] as? String) ?? "").lowercased()
        return message.contains("不存在coding plan")
            || message.contains("no coding plan")
            || message.contains("coding plan does not exist")
            || message.contains("coding plan not found")
    }

    private static func businessCode(_ root: [String: Any]) -> Int? {
        guard let number = quotaNumber(root["code"]),
              number.rounded() == number,
              number >= Double(Int.min),
              number < Double(Int.max) else {
            return nil
        }
        return Int(number)
    }

    /// Optional numeric fields may be absent/null, but a present value with the wrong type is a schema
    /// error. This keeps a malformed reset timestamp from being silently treated as "no reset".
    private static func optionalNumber(_ value: Any?) throws -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = quotaNumber(value) else {
            throw ZAIUsageError.invalidResponse
        }
        return number
    }

    /// `JSONSerialization` bridges both JSON booleans and numbers through `NSNumber`; reject the
    /// boolean subtype before using the shared permissive numeric parser.
    private static func quotaNumber(_ value: Any?) -> Double? {
        if let number = value as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() {
            return nil
        }
        return ProviderParse.number(value)
    }

    private static func jsonBoolean(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    /// `nextResetTime` arrives as epoch milliseconds (e.g. `1770648402389`).
    private static func epochMsToDate(_ ms: Double) -> Date {
        Date(timeIntervalSince1970: ms / 1000)
    }
}
