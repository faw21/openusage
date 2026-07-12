import Foundation

enum TerminalRenderer {
    static func render(_ snapshots: [UsageSnapshot], now: Date = Date()) -> String {
        guard !snapshots.isEmpty else { return "No usage data yet." }
        return snapshots.map { snapshot in
            var rows = [header(snapshot)]
            rows += snapshot.lines.map { "  \($0.label): \(value($0, now: now))" }
            rows.append("  Updated: \(relativeDate(snapshot.fetchedAt, now: now))")
            return rows.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func header(_ snapshot: UsageSnapshot) -> String {
        guard let plan = snapshot.plan, !plan.isEmpty else { return snapshot.displayName }
        return "\(snapshot.displayName) (\(plan))"
    }

    private static func value(_ line: UsageLine, now: Date) -> String {
        switch line.type {
        case "progress":
            guard let used = line.used, let limit = line.limit else { return "No data" }
            let rendered: String
            if line.format?.kind == "percent", limit != 0 {
                rendered = "\(integerOrDecimal(used / limit * 100))% used"
            } else {
                let suffix = line.format?.suffix.map { " \($0)" } ?? ""
                rendered = "\(integerOrDecimal(used)) / \(integerOrDecimal(limit))\(suffix)"
            }
            guard let resetsAt = line.resetsAt else { return rendered }
            return "\(rendered) · resets \(relativeDate(resetsAt, now: now))"
        case "badge":
            return line.text ?? "No data"
        case "barChart":
            guard let point = line.points?.last else { return "No data" }
            return point.valueLabel ?? "\(compactCount(point.value)) tokens"
        default:
            return line.value ?? "No data"
        }
    }

    private static func integerOrDecimal(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func compactCount(_ value: Double) -> String {
        value.formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0...1))
                .locale(Locale(identifier: "en_US"))
        )
    }

    private static func relativeDate(_ value: String, now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else { return value }
        let seconds = Int(date.timeIntervalSince(now))
        if abs(seconds) < 60 { return seconds >= 0 ? "in <1m" : "just now" }
        let minutes = abs(seconds) / 60
        if minutes < 60 { return seconds >= 0 ? "in \(minutes)m" : "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 48 { return seconds >= 0 ? "in \(hours)h" : "\(hours)h ago" }
        let days = hours / 24
        return seconds >= 0 ? "in \(days)d" : "\(days)d ago"
    }
}
