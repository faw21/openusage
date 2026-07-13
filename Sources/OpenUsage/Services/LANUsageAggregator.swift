import Foundation

/// Selects and combines the only metrics that are safe to add across Macs: usage reconstructed from
/// machine-local logs/CSV files. Account-wide quota meters are deliberately never exported because two
/// Macs signed in to the same account would report the same quota and double-count it.
enum LANUsageAggregator {
    static func shareableSnapshots(
        _ snapshots: [String: ProviderSnapshot],
        registry: WidgetRegistry
    ) -> [String: ProviderSnapshot] {
        snapshots.compactMapValues { snapshot in
            let labels = shareableLabels(for: snapshot.providerID, registry: registry)
            let lines = snapshot.lines.compactMap { line in
                labels.contains(line.label) ? sanitizedShareableLine(line) : nil
            }
            guard !lines.isEmpty else { return nil }
            return ProviderSnapshot(
                providerID: snapshot.providerID,
                displayName: snapshot.displayName,
                lines: lines,
                refreshedAt: snapshot.refreshedAt
            )
        }
    }

    static func combinedSnapshots(
        local: [String: ProviderSnapshot],
        remotes: [String: [String: ProviderSnapshot]],
        registry: WidgetRegistry
    ) -> [String: ProviderSnapshot] {
        var result = local
        let remoteSnapshots = remotes.values.flatMap { $0.values }
        let providerIDs = Set(remoteSnapshots.map(\.providerID))

        for providerID in providerIDs.union(local.keys) {
            let labels = shareableLabels(for: providerID, registry: registry)
            guard !labels.isEmpty else { continue }
            let sources = ([local[providerID]] + remoteSnapshots.filter { $0.providerID == providerID })
                .compactMap { $0 }
            guard let template = local[providerID] ?? sources.first else { continue }

            var linesByLabel: [String: [MetricLine]] = [:]
            for snapshot in sources {
                for line in snapshot.lines where labels.contains(line.label) {
                    linesByLabel[line.label, default: []].append(line)
                }
            }

            // Only this Mac is authoritative for account-wide rows. A remote-only provider starts with
            // no quota/plan data at all, then receives just the additive local-usage rows below.
            let mergedLines = (local[providerID]?.lines.filter { !labels.contains($0.label) } ?? [])
                + registry.descriptors(for: providerID)
                    .map(\.metricLabel)
                    .uniqued()
                    .compactMap { label in
                        guard let lines = linesByLabel[label], !lines.isEmpty else { return nil }
                        return merge(lines, label: label)
                    }

            result[providerID] = ProviderSnapshot(
                providerID: providerID,
                displayName: template.displayName,
                plan: local[providerID]?.plan,
                lines: mergedLines,
                refreshedAt: sources.map(\.refreshedAt).max() ?? template.refreshedAt,
                warning: local[providerID]?.warning,
                errorCategory: local[providerID]?.errorCategory
            )
        }
        return result
    }

    private static func shareableLabels(for providerID: String, registry: WidgetRegistry) -> Set<String> {
        Set(registry.descriptors(for: providerID).compactMap { descriptor in
            guard !descriptor.isAccountWideUsage else { return nil }
            return descriptor.isSpendTile || descriptor.sample.isChart ? descriptor.metricLabel : nil
        })
    }

    /// The wire is a system boundary even for an approved peer. Keep the additive shapes bounded and
    /// numeric so a malformed/older peer cannot feed NaN, negatives, or an unbounded chart into the UI.
    private static func sanitizedShareableLine(_ line: MetricLine) -> MetricLine? {
        switch line {
        case .values(let label, let values, _, _, let unknownModels, _):
            let valid = values.filter { $0.number.isFinite && $0.number >= 0 }
            guard !valid.isEmpty else { return nil }
            return .values(
                label: label,
                values: valid,
                unknownModels: unknownModels.prefix(100).map { String($0.prefix(128)) }
            )
        case .chart(let label, let points, _):
            let valid = points.filter { $0.value.isFinite && $0.value >= 0 }.prefix(64)
            guard !valid.isEmpty else { return nil }
            return .chart(
                label: label,
                points: valid.map {
                    MetricChartPoint(
                        value: $0.value,
                        label: String($0.label.prefix(64)),
                        valueLabel: MetricFormatter.number($0.value, kind: .count, style: .row) + " tokens"
                    )
                }
            )
        default:
            return nil
        }
    }

    private static func merge(_ lines: [MetricLine], label: String) -> MetricLine? {
        if lines.count == 1 { return lines[0] }
        if lines.allSatisfy({ if case .values = $0 { true } else { false } }) {
            return mergeValues(lines, label: label)
        }
        if lines.allSatisfy({ if case .chart = $0 { true } else { false } }) {
            return mergeCharts(lines, label: label)
        }
        // A peer on a newer protocol may someday send a different shape. Do not invent a conversion;
        // keep the local/first value and log the incompatibility at the boundary.
        AppLog.warn(.localAPI, "LAN sync skipped incompatible \(label) metric shapes")
        return lines.first
    }

    private struct ValueKey: Hashable {
        let kind: MetricKind
        let label: String?
    }

    private static func mergeValues(_ lines: [MetricLine], label: String) -> MetricLine {
        var order: [ValueKey] = []
        var totals: [ValueKey: Double] = [:]
        var estimates: [ValueKey: Bool] = [:]
        var unknownModels = Set<String>()

        for case .values(_, let values, _, _, let unknown, _) in lines {
            unknownModels.formUnion(unknown)
            for value in values {
                let key = ValueKey(kind: value.kind, label: value.label)
                if totals[key] == nil { order.append(key) }
                totals[key, default: 0] += value.number
                estimates[key, default: false] = estimates[key, default: false] || value.estimated
            }
        }

        let values = order.compactMap { key -> MetricValue? in
            guard let total = totals[key], total.isFinite else { return nil }
            return MetricValue(number: total, kind: key.kind, label: key.label, estimated: estimates[key] ?? false)
        }
        return .values(label: label, values: values, unknownModels: unknownModels.sorted())
    }

    private static func mergeCharts(_ lines: [MetricLine], label: String) -> MetricLine {
        let series = lines.compactMap { line -> [MetricChartPoint]? in
            if case .chart(_, let points, _) = line { return points }
            return nil
        }
        let labels = series.max(by: { $0.count < $1.count }) ?? []
        let points = labels.indices.compactMap { index -> MetricChartPoint? in
            let total = series.compactMap { $0.indices.contains(index) ? $0[index].value : nil }.reduce(0, +)
            guard total.isFinite else { return nil }
            return MetricChartPoint(
                value: total,
                label: labels[index].label,
                valueLabel: MetricFormatter.number(total, kind: .count, style: .row) + " tokens"
            )
        }
        return .chart(label: label, points: points, note: "Local usage across connected Macs")
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
