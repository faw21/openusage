import XCTest
@testable import OpenUsage

func makeDevinUserStatus(planName: String = "Max") -> [String: Any] {
    [
        "planStatus": [
            "planInfo": [
                "planName": planName,
                "billingStrategy": "BILLING_STRATEGY_QUOTA"
            ],
            "dailyQuotaRemainingPercent": 100,
            "weeklyQuotaRemainingPercent": 40,
            "overageBalanceMicros": "964220000",
            "dailyQuotaResetAtUnix": "1774080000",
            "weeklyQuotaResetAtUnix": "1774166400"
        ]
    ]
}

func makeDevinUserStatusBody(planName: String = "Max") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["userStatus": makeDevinUserStatus(planName: planName)])
}

func devinRequestBody(_ request: HTTPRequest?) throws -> [String: Any] {
    let data = try XCTUnwrap(request?.body)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

final class DevinFakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var value: String?
    var queryError: Error?
    var lastPath: String?
    var lastSQL: String?

    init(value: String? = nil, queryError: Error? = nil) {
        self.value = value
        self.queryError = queryError
    }

    func queryValue(path: String, sql: String) throws -> String? {
        lastPath = path
        lastSQL = sql
        if let queryError { throw queryError }
        return value
    }

    func execute(path: String, sql: String) throws {}
}

struct DevinUnreadableFiles: TextFileAccessing {
    func exists(_ path: String) -> Bool { true }
    func readText(_ path: String) throws -> String { throw DevinCredentialBoundaryTestError.unreadable }
    func writeText(_ path: String, _ text: String) throws {}
    func remove(_ path: String) throws {}
}

enum DevinCredentialBoundaryTestError: Error {
    case unreadable
}

final class DevinQueueHTTPClient: HTTPClient, @unchecked Sendable {
    var responses: [HTTPResponse]
    var requests: [HTTPRequest] = []

    init(responses: [HTTPResponse] = []) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            return HTTPResponse(statusCode: 500, headers: [:], body: Data("{}".utf8))
        }
        return responses.removeFirst()
    }
}
