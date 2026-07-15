import Foundation

/// Small, dependency-free formatting helpers shared by the balance sources so every card renders money,
/// bandwidth, and dates the same way.
enum BalanceFormat {
    static func money(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = abs(value) >= 100 ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    static func gb(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f GB", value) }
        if value >= 10 { return String(format: "%.1f GB", value) }
        return String(format: "%.2f GB", value)
    }

    /// Parse an ISO / Webshare date string and render "Jul 30". Falls back to the raw string on failure.
    static func day(_ raw: String) -> String {
        guard let date = parseDate(raw) else { return raw }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = "MMM d"
        return out.string(from: date)
    }

    static func parseDate(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss"] {
            plain.dateFormat = format
            if let date = plain.date(from: raw) { return date }
        }
        return nil
    }

    // MARK: - Month boundaries (for the spend APIs)

    static func startOfMonthUnix(now: Date = Date()) -> Int {
        Int(startOfMonth(now: now).timeIntervalSince1970)
    }

    static func startOfMonthISO(now: Date = Date()) -> String { isoString(startOfMonth(now: now)) }
    static func nowISO(now: Date = Date()) -> String { isoString(now) }

    private static func startOfMonth(now: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: now)
        return calendar.date(from: components) ?? now
    }

    private static func isoString(_ date: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.string(from: date)
    }
}
