import SwiftUI

/// A desktop card for one AI coding tool (Claude Code, Codex): plan, progress meters, and stat rows,
/// rendered from the same `ProviderSnapshot` the menu-bar popover uses. Falls back to a status/error row.
struct CodingUsageCardView: View {
    let title: String
    let iconSystemName: String
    let accentHex: String
    let snapshot: ProviderSnapshot?
    let error: String?

    private var accent: Color { Color(hexString: accentHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .desktopCard()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: iconSystemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 26, height: 26)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if let plan = snapshot?.plan, !plan.isEmpty {
                    Text(plan).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let warning = snapshot?.warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Color(nsColor: .systemOrange))
                    .help(warning)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let error, snapshot == nil {
            statusRow(text: error, color: Color(nsColor: .systemRed))
        } else if let snapshot {
            let lines = snapshot.lines.filter { !$0.isError }
            if lines.isEmpty {
                statusRow(text: "No usage data", color: .secondary)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
            }
        } else {
            statusRow(text: "Loading…", color: .secondary)
        }
    }

    @ViewBuilder private func lineView(_ line: MetricLine) -> some View {
        switch line {
        case let .progress(label, used, limit, format, resetsAt, _, _):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(progressReadout(used: used, limit: limit, format: format))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                MeterBar(fraction: limit > 0 ? used / limit : 0)
                if let resetsAt {
                    Text("Resets \(resetsAt, format: .relative(presentation: .named))")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        case let .values(label, values, _, _, _, _):
            statRow(label: label,
                    value: values.map { MetricFormatter.string(for: $0, style: .row) }.joined(separator: " · "))
        case let .text(label, value, _, _):
            statRow(label: label, value: value)
        case let .badge(label, text, colorHex, _):
            statRow(label: label, value: text, valueColor: colorHex.map { Color(hexString: $0) })
        case .chart:
            EmptyView()
        }
    }

    private func progressReadout(used: Double, limit: Double, format: ProgressFormat) -> String {
        switch format {
        case .percent:
            return "\(Int(used.rounded()))%"
        case .dollars:
            return "\(MetricFormatter.number(used, kind: .dollars, style: .row)) / \(MetricFormatter.number(limit, kind: .dollars, style: .row))"
        case .count:
            return "\(MetricFormatter.number(used, kind: .count, style: .row)) / \(MetricFormatter.number(limit, kind: .count, style: .row))"
        }
    }

    private func statRow(label: String, value: String, valueColor: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(valueColor ?? .primary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func statusRow(text: String, color: Color) -> some View {
        HStack { Text(text).font(.system(size: 12)).foregroundStyle(color); Spacer() }
    }
}
