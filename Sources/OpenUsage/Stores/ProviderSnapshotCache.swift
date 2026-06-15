import Foundation

struct ProviderSnapshotCache {
    private struct Payload: Codable {
        var snapshots: [String: ProviderSnapshot]
    }

    private let userDefaults: UserDefaults
    private let storageKey: String
    /// A snapshot stays fresh for exactly one refresh interval, which is what lets cached data survive a
    /// relaunch without an immediate refetch and expire precisely when the next refresh is due. Tests
    /// inject a fixed TTL for a deterministic freshness window.
    private let ttl: TimeInterval
    private let now: () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "openusage.providerSnapshots.v2",
        ttl: TimeInterval = RefreshSetting.interval,
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.ttl = ttl
        self.now = now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Every stored snapshot for the given providers, including expired ones. Display uses this
    /// (stale-while-revalidate: last-known values keep showing while a refresh runs); refresh gating
    /// still goes through the TTL-checked `snapshot(providerID:)`.
    func loadSnapshots(providerIDs: [String]) -> [String: ProviderSnapshot] {
        let providerIDSet = Set(providerIDs)
        return loadPayload().snapshots.filter { providerID, _ in
            providerIDSet.contains(providerID)
        }
    }

    func snapshot(providerID: String) -> ProviderSnapshot? {
        let snapshot = loadPayload().snapshots[providerID]
        guard let snapshot, isValid(snapshot) else { return nil }
        return snapshot
    }

    func store(_ snapshot: ProviderSnapshot) {
        guard !snapshot.lines.contains(where: \.isError) else { return }
        var payload = loadPayload()
        payload.snapshots[snapshot.providerID] = snapshot
        save(payload)
    }

    private func isValid(_ snapshot: ProviderSnapshot) -> Bool {
        now().timeIntervalSince(snapshot.refreshedAt) < ttl
    }

    private func loadPayload() -> Payload {
        guard let data = userDefaults.data(forKey: storageKey),
              let payload = try? decoder.decode(Payload.self, from: data)
        else {
            return Payload(snapshots: [:])
        }
        return payload
    }

    private func save(_ payload: Payload) {
        guard let data = try? encoder.encode(payload) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}

