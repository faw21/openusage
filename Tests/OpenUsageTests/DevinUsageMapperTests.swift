import XCTest
@testable import OpenUsage

final class DevinUsageMapperTests: XCTestCase {
    func testMapsQuotaLinesAndExtraUsageBalance() throws {
        let mapped = try DevinUsageMapper.mapUserStatus(makeDevinUserStatus())

        XCTAssertEqual(mapped.plan, "Max")
        XCTAssertEqual(progress(mapped.lines, "Daily quota")?.used, 0)
        XCTAssertEqual(progress(mapped.lines, "Daily quota")?.periodDurationMs, DevinUsageMapper.dayPeriodMs)
        XCTAssertEqual(progress(mapped.lines, "Weekly quota")?.used, 60)
        XCTAssertEqual(progress(mapped.lines, "Weekly quota")?.periodDurationMs, DevinUsageMapper.weekPeriodMs)
        XCTAssertEqual(try XCTUnwrap(dollars(mapped.lines, "Extra usage balance")), 964.22, accuracy: 0.0001)
        XCTAssertNotNil(progress(mapped.lines, "Weekly quota")?.resetsAt)
    }

    func testZeroOverageBalanceReadsZeroDollarsNotNoData() throws {
        var userStatus = makeDevinUserStatus()
        var planStatus = userStatus["planStatus"] as! [String: Any]
        planStatus["overageBalanceMicros"] = "0"
        userStatus["planStatus"] = planStatus

        let mapped = try DevinUsageMapper.mapUserStatus(userStatus)

        // A present balance of zero is a real, measured value → 0, not "No data" (that's reserved
        // for the field being absent entirely).
        XCTAssertEqual(dollars(mapped.lines, "Extra usage balance"), 0)
    }

    func testUsesHiddenDailyQuotaAsWeeklyUsageWhenWeeklyIsAbsent() throws {
        var userStatus = makeDevinUserStatus()
        var planStatus = userStatus["planStatus"] as! [String: Any]
        var planInfo = planStatus["planInfo"] as! [String: Any]
        planInfo["hideDailyQuota"] = true
        planStatus["planInfo"] = planInfo
        planStatus["dailyQuotaRemainingPercent"] = 30
        planStatus.removeValue(forKey: "weeklyQuotaRemainingPercent")
        userStatus["planStatus"] = planStatus

        let mapped = try DevinUsageMapper.mapUserStatus(userStatus)

        XCTAssertNil(progress(mapped.lines, "Daily quota"))
        // The hidden daily quota fills the missing Weekly row and is still flipped from "remaining"
        // to "used": 30% remaining -> 70% used (not passed through raw as 30).
        XCTAssertEqual(progress(mapped.lines, "Weekly quota")?.used, 70)
        XCTAssertEqual(try XCTUnwrap(dollars(mapped.lines, "Extra usage balance")), 964.22, accuracy: 0.0001)
    }

    func testThrowsQuotaUnavailableWhenNoDisplayableFieldsExist() {
        let userStatus: [String: Any] = [
            "planStatus": [
                "planInfo": ["planName": "Max"]
            ]
        ]

        XCTAssertThrowsError(try DevinUsageMapper.mapUserStatus(userStatus)) { error in
            XCTAssertEqual(error as? DevinUsageError, .quotaUnavailable)
        }
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }

    /// The first dollar value's raw number on a `.values` line (the shape extra-usage balance now uses).
    private func dollars(_ lines: [MetricLine], _ label: String) -> Double? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values.first(where: { $0.kind == .dollars })?.number
    }
}
