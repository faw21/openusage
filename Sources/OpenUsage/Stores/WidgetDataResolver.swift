import Foundation

/// Focused boundary mapping from a provider's normalized `MetricLine` into renderable `WidgetData`.
/// Refresh/cache/notification orchestration stays in `WidgetDataStore`; this type owns the one place
/// where live provider values are combined with a descriptor's presentation metadata.
enum WidgetDataResolver {
    static func resolve(_ line: MetricLine, descriptor: WidgetDescriptor) -> WidgetData? {
        switch line {
        case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs, _):
            // A percent meter is a bounded 0...100 domain. Non-percent meters retain real overages.
            let normalizedUsed = format == .percent ? ProviderParse.clampPercent(used) : used
            var result = WidgetData(
                title: descriptor.sample.title,
                icon: descriptor.sample.icon,
                kind: format.metricKind,
                used: normalizedUsed,
                limit: limit,
                countSuffix: format.countSuffix,
                valuePrefix: descriptor.sample.valuePrefix,
                resetsAt: resetsAt,
                periodDurationMs: periodDurationMs,
                limitNoun: descriptor.sample.limitNoun,
                infoNote: descriptor.sample.infoNote
            )
            result.isSessionWindow = descriptor.sample.isSessionWindow
            return result

        case .text(_, let value, _, _):
            return resolveText(value, descriptor: descriptor)

        case .values(_, let values, _, let expiriesAt, let unknownModels, let modelBreakdown):
            // Presentation comes from the descriptor; the line remains the only source of live values.
            var data = descriptor.sample
            data.values = values
            data.limit = nil
            data.expiriesAt = expiriesAt
            data.unknownModels = unknownModels
            data.modelBreakdown = modelBreakdown
            data.hasData = !data.selectedValues.isEmpty
            data.infoNote = data.selectedValues.contains(where: \.estimated)
                ? WidgetData.localEstimateNote
                : descriptor.sample.infoNote
            return data

        case .badge(_, let text, _, let subtitle):
            var data = descriptor.sample
            data.valueTextOverride = text
            data.subtitleOverride = subtitle
            return data

        case .chart(_, let points, let note):
            var data = descriptor.sample
            data.isChart = true
            data.chartPoints = points
            data.chartNote = note
            data.hasData = !points.isEmpty
            return data
        }
    }

    private static func resolveText(_ value: String, descriptor: WidgetDescriptor) -> WidgetData? {
        let sample = descriptor.sample
        switch sample.kind {
        case .dollars:
            guard let amount = firstCurrencyAmount(in: value) else { return nil }
            return textData(
                sample,
                kind: .dollars,
                used: amount,
                limit: sample.limit,
                valueTextOverride: sample.preservesRawText ? value : nil,
                unboundedValueWord: sample.unboundedValueWord
            )

        case .count:
            guard let count = firstNumber(in: value) else { return nil }
            return textData(
                sample,
                kind: .count,
                used: count,
                limit: sample.limit,
                valueTextOverride: sample.preservesRawText ? value : nil,
                unboundedValueWord: sample.unboundedValueWord
            )

        case .percent:
            guard let percent = firstNumber(in: value) else { return nil }
            return textData(
                sample,
                kind: .percent,
                used: ProviderParse.clampPercent(percent),
                limit: sample.limit ?? 100
            )
        }
    }

    /// Build a fresh text row instead of inheriting live-state fields such as reset timing, display
    /// mode, raw-text behavior, or no-data state from the descriptor sample.
    private static func textData(
        _ sample: WidgetData,
        kind: MetricKind,
        used: Double,
        limit: Double?,
        valueTextOverride: String? = nil,
        unboundedValueWord: String? = nil
    ) -> WidgetData {
        WidgetData(
            title: sample.title,
            icon: sample.icon,
            kind: kind,
            used: used,
            limit: limit,
            countSuffix: sample.countSuffix,
            valuePrefix: sample.valuePrefix,
            valueTextOverride: valueTextOverride,
            subtitleOverride: sample.subtitleOverride,
            unboundedValueWord: unboundedValueWord,
            infoNote: sample.infoNote
        )
    }

    private static func firstCurrencyAmount(in value: String) -> Double? {
        let pattern = #"[-+]?\$([0-9][0-9,]*(?:\.[0-9]+)?)"#
        guard let match = value.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let matched = value[match].replacingOccurrences(of: "$", with: "")
        return Double(matched.replacingOccurrences(of: ",", with: ""))
    }

    private static func firstNumber(in value: String) -> Double? {
        let pattern = #"[-+]?[0-9][0-9,]*(?:\.[0-9]+)?"#
        guard let match = value.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return Double(value[match].replacingOccurrences(of: ",", with: ""))
    }
}
