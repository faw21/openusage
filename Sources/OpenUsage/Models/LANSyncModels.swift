import Foundation

struct LANPairedDevice: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
}

struct LANNearbyDevice: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let isPaired: Bool
}

struct LANIncomingPairRequest: Identifiable, Sendable {
    let id: UUID
    let deviceID: String
    let name: String
    let code: String
}

enum LANOutgoingPairing: Equatable, Sendable {
    case connecting(name: String)
    case compareCode(name: String, code: String)
    case failed(name: String, message: String)
}

struct LANPeerSyncState: Equatable, Sendable {
    var isAvailable = false
    var isSyncing = false
    var lastSyncedAt: Date?
    var errorMessage: String?
}
