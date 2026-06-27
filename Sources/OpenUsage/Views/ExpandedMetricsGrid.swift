import SwiftUI

/// EXPLORATION (issue #596): the sticky area that opens at the bottom of a provider card when its
/// caret is expanded, laying the "Shown on Expand" (secondary) metrics **up to three across** instead
/// of the single-column vertical list the always-shown rows use. Each cell takes the column's width
/// and sizes to its own content; rows wrap 1–3 per line by count and the metrics' shape.
///
/// The grid is geometry-only: it does not own the per-metric gestures, context menus, or reorder
/// frames. The caller passes a `cell` builder that wraps each metric in exactly the same
/// `WidgetRowView` + drag/menu/frame chrome the single-column list uses, so reorder and customize keep
/// working unchanged — only the placement of the cells differs.
///
/// Column count is decided by ``columnCount(metricCount:hasWideMetric:)`` so the heuristic is a pure,
/// unit-tested function rather than buried in view code: bounded meter rows and charts are "wide" and
/// pull the grid back to fewer columns (they don't fit legibly three-up at the popover's ~292pt card
/// width); compact text-only metrics get the full three.
struct ExpandedMetricsGrid<Cell: View>: View {
    /// Stable identifiers for the metrics being laid out, in display order. One cell is built per id.
    let metricIDs: [String]
    /// True when any metric in this set is a bounded meter row or a chart — content too wide to read
    /// three-up at the card width, so the grid drops to at most two columns.
    let hasWideMetric: Bool
    @ViewBuilder var cell: (String) -> Cell

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    /// Hard ceiling from the owner's proposal: never more than three metrics across.
    static var maxColumns: Int { 3 }

    /// Pure column-count rule, factored out for unit testing.
    /// - One metric is always a single full-width column (no reason to box it in a third of the row).
    /// - Any wide metric (bounded meter / chart) caps the grid at two columns, since three wide cells
    ///   don't fit legibly at ~292pt; with two metrics that means side-by-side, with three+ a 2-wide
    ///   wrap. Narrow text-only metrics fill up to three across, capped by how many there are.
    static func columnCount(metricCount: Int, hasWideMetric: Bool) -> Int {
        guard metricCount > 1 else { return 1 }
        let ceiling = hasWideMetric ? 2 : maxColumns
        return min(metricCount, ceiling)
    }

    private var columns: [GridItem] {
        let count = Self.columnCount(metricCount: metricIDs.count, hasWideMetric: hasWideMetric)
        // `.flexible` columns split the card width evenly and let each cell size its own height, so a
        // taller bounded cell beside a one-line text cell aligns to the top without stretching.
        return Array(repeating: GridItem(.flexible(), spacing: density.expandedGridSpacing, alignment: .top),
                     count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: density.expandedGridSpacing) {
            ForEach(metricIDs, id: \.self) { id in
                cell(id)
            }
        }
    }
}
