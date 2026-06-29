import SwiftUI

/// The Customize detail for one provider (L2): two distinct cards — **Always Visible** (shown on the
/// dashboard card) and **On Demand** (tucked behind the card's caret). Drag a metric onto a row in
/// the other card to move it across; an empty card shows a small dashed "Drag metrics here" drop zone
/// that's also the drop target for moving a metric into it. Each metric row is grip · name · star ·
/// toggle (drag left, toggle right — same shape as the provider rows). The star is always visible:
/// outline when not starred, filled accent when starred. Providers that need an API key get their own
/// "API Key" section here too.
///
/// The two sections are separate `ForEach`es (so they're visually distinct cards). That reintroduces
/// the stuck-drag risk: when a dragged row crosses into the other card, SwiftUI tears down the source
/// view (and its gesture) mid-drag, so `onEnded` never fires and the lift overlay would stick. Each
/// row clears the drag state on `.onDisappear` — by the time the source view is removed, the metric
/// has already moved to the other card, so the drag is genuinely over and the lift unsticks.
struct CustomizeProviderDetailView: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(AppContainer.self) private var container
    let providerID: String
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    let rowFrames: [String: CGRect]

    @State private var activeMetricID: String?
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        if let group = layout.customizeDetail(for: providerID) {
            VStack(alignment: .leading, spacing: density.sectionSpacing) {
                metricSection("Always Visible", metrics: group.alwaysShownMetrics, providerID: providerID)
                metricSection("On Demand", metrics: group.expandedMetrics, providerID: providerID)
                // Providers that need a user-supplied key (OpenRouter today) get their own "API Key"
                // section here — the same editor logic the Settings ▸ API Keys card used, scoped to
                // this one provider. Hidden for providers that don't need a key.
                if let keyProvider = container.apiKeyProviders.first(where: { $0.provider.id == providerID }) {
                    APIKeysSection(providers: [keyProvider])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Motion.spring, value: layout.expandedMetricIDs)
        } else {
            // Unknown provider — L1 only lists known providers, so this is unreachable in practice.
            EmptyView()
        }
    }

    // MARK: - Metric sections

    private func metricSection(_ title: String, metrics: [WidgetDescriptor], providerID: String) -> some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                if metrics.isEmpty {
                    emptyDropZone(providerID: providerID)
                } else {
                    ForEach(metrics, id: \.id) { metric in
                        metricRow(metric, in: providerID)
                    }
                }
            }
            .cardSurface()
        }
    }

    /// A small dashed drop target shown when a section is empty, so there's always somewhere to drop
    /// a metric into. It carries the divider's reorder frame — dropping a metric here moves it into
    /// this section via `applyMetricDividerOrder` (the sentinel sits at the empty section's edge).
    private func emptyDropZone(providerID: String) -> some View {
        let yOutset = max(0, (density.estimatedMetricRowHeight - 30) / 2)
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(.tertiary)
            .frame(height: 30)
            .padding(8)
            .overlay(
                Text("Drag metrics here")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            )
            .reorderFrame(id: expandedDividerID(for: providerID), in: .named(reorderSpaceName), yOutset: yOutset)
            .accessibilityLabel("Drag metrics here")
    }

    private func metricRow(_ metric: WidgetDescriptor, in providerID: String) -> some View {
        let isActive = activeMetricID == metric.id
        return CustomizeMetricRow(
            title: metric.title,
            handle: { $0.highPriorityGesture(metricDragGesture(for: metric.id, providerID: providerID, title: metric.title)) },
            trailing: {
                StarButton(metric: metric)
                Toggle("", isOn: Binding(
                    get: { layout.isMetricEnabled(metric.id) },
                    set: { layout.setMetricEnabled(metric.id, $0) }
                ))
                .settingsSwitchStyle()
            }
        )
        .contentShape(Rectangle())
        .opacity(isActive ? 0 : 1)
        // Two-card stuck-drag safeguard: when a dragged row crosses into the other section's card,
        // SwiftUI removes this source view (and its drag gesture) mid-drag, so onEnded never fires and
        // the lift overlay would stick. By the time onDisappear fires, the metric has already moved to
        // the other card, so the drag is genuinely over — clear the state so the lift unsticks.
        .onDisappear {
            if activeMetricID == metric.id {
                activeMetricID = nil
                reorderLift = nil
            }
        }
        .reorderFrame(id: metric.id, in: .named(reorderSpaceName))
    }

    // MARK: - Metric drag-reorder

    private func metricDragGesture(for metricID: String, providerID: String, title: String) -> some Gesture {
        reorderDragGesture(
            id: metricID,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeMetricID,
            lift: $reorderLift,
            makeLift: { makeMetricLift(metricID: metricID, title: title, value: $0) },
            orderedIDs: { reorderTargetIDs(for: providerID) },
            reorder: { target in
                let current = reorderTargetIDs(for: providerID)
                guard let next = LayoutStore.reordered(current, dragged: metricID, target: target) else {
                    return false
                }
                return layout.applyMetricDividerOrder(next, dragged: metricID, dividerID: expandedDividerID(for: providerID), in: providerID)
            }
        )
    }

    private func reorderTargetIDs(for providerID: String) -> [String] {
        layout.metricOrderWithDivider(for: providerID, dividerID: expandedDividerID(for: providerID))
    }

    private func expandedDividerID(for providerID: String) -> String {
        "\(providerID)::expanded-divider"
    }

    private func makeMetricLift(metricID: String, title: String, value: DragGesture.Value) -> ReorderLift? {
        ReorderLift.make(
            id: metricID,
            payload: .customizeMetric(title: title),
            value: value,
            frames: rowFrames
        )
    }
}

/// The star (menu-bar pin) control on a metric row — always visible: an outline star when not
/// starred, a filled accent star when starred. A denied click (over the per-provider cap) shakes the
/// star; the hover tooltip carries the reason.
private struct StarButton: View {
    let metric: WidgetDescriptor
    @Environment(LayoutStore.self) private var layout
    @State private var shakeTrigger = 0

    var body: some View {
        if metric.pinnable {
            let pinned = layout.isPinned(metric.id)
            Button {
                if layout.canPin(metric.id) {
                    layout.togglePin(metric.id)
                } else {
                    shakeTrigger += 1
                }
            } label: {
                Image(systemName: pinned ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
            .hoverTooltip(pinned ? "Unstar" : (layout.pinDenialReason(metric.id) ?? "Star for menu bar"))
            .denyShake(trigger: shakeTrigger)
            .animation(Motion.spring, value: pinned)
        }
    }
}
