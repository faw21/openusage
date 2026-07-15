import Foundation
import Observation

/// Owns the desktop widget's balance cards: fans the sources out concurrently off the main actor, each
/// on its own cadence (fast providers every few minutes, GCP every few hours because billing data barely
/// moves), and publishes the merged, declaration-ordered result for the SwiftUI grid.
@MainActor
@Observable
final class BalanceStore {
    private(set) var cards: [BalanceCard]
    private(set) var lastRefreshedAt: Date?
    private(set) var isRefreshing = false

    private let sources: [any BalanceSource]
    private var lastLoaded: [String: Date] = [:]
    private var refreshTask: Task<Void, Never>?

    init(sources: [any BalanceSource]) {
        self.sources = sources
        self.cards = sources.map {
            BalanceCard(id: $0.id, title: $0.title, iconSystemName: $0.iconSystemName,
                        accentHex: $0.accentHex, link: $0.link, state: .loading)
        }
    }

    /// Reload the sources whose per-source interval has elapsed (all of them when `force`).
    func refreshDue(manual: Bool = false) async {
        let now = Date()
        let due = sources.filter { source in
            if manual && source.refreshesOnManual { return true }
            return now.timeIntervalSince(lastLoaded[source.id] ?? .distantPast) >= source.refreshInterval
        }
        guard !due.isEmpty else { return }
        isRefreshing = true
        let loaded = await withTaskGroup(of: BalanceCard.self) { group in
            for source in due { group.addTask { await source.load() } }
            var out: [BalanceCard] = []
            for await card in group { out.append(card) }
            return out
        }
        var byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for card in loaded {
            byID[card.id] = card
            lastLoaded[card.id] = now
        }
        cards = sources.compactMap { byID[$0.id] }
        lastRefreshedAt = now
        isRefreshing = false
    }

    /// Force-reload everything — the widget's manual refresh button.
    func refreshAll() async { await refreshDue(manual: true) }

    /// Reload a single source now (e.g. right after the user saves its key).
    func refresh(id: String) async {
        guard let source = sources.first(where: { $0.id == id }) else { return }
        let card = await source.load()
        var byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        byID[id] = card
        lastLoaded[id] = Date()
        cards = sources.compactMap { byID[$0.id] }
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDue()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
