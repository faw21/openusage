import Foundation

struct UsageSnapshot: Decodable, Sendable {
    var providerId: String
    var displayName: String
    var plan: String?
    var lines: [UsageLine]
    var fetchedAt: String
}

struct UsageLine: Decodable, Sendable {
    struct Format: Decodable, Sendable {
        var kind: String
        var suffix: String?
    }

    var type: String
    var label: String
    var value: String?
    var used: Double?
    var limit: Double?
    var format: Format?
    var resetsAt: String?
    var text: String?
    var points: [ChartPoint]?

    init(
        type: String,
        label: String,
        value: String? = nil,
        used: Double? = nil,
        limit: Double? = nil,
        format: Format? = nil,
        resetsAt: String? = nil,
        text: String? = nil,
        points: [ChartPoint]? = nil
    ) {
        self.type = type
        self.label = label
        self.value = value
        self.used = used
        self.limit = limit
        self.format = format
        self.resetsAt = resetsAt
        self.text = text
        self.points = points
    }
}

struct ChartPoint: Decodable, Sendable {
    var label: String
    var value: Double
    var valueLabel: String?
}

struct APIErrorBody: Decodable, Sendable {
    var error: String
}
