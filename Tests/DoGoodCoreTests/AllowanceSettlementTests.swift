import XCTest
@testable import DoGoodCore

final class AllowanceSettlementTests: XCTestCase {
    func testRequestsRequirePositiveConfirmedUnpaidPeriod() {
        var period = SeedData.snapshot().allowancePeriods[0]
        period.archivedAt = Date()
        XCTAssertNil(period.paymentRequestMessage(parentName: "Daddy"))
        period.settlement = AllowanceSettlement(amountCents: 0, confirmedAt: Date())
        XCTAssertFalse(period.canRequestPayment)
        period.settlement = AllowanceSettlement(amountCents: 725, confirmedAt: Date())
        XCTAssertTrue(period.canRequestPayment)
        XCTAssertTrue(period.paymentRequestMessage(parentName: "Daddy")?.contains("$7.25") == true)
        XCTAssertEqual(period.displayedBalanceCents, 725)
        period.entries = []
        XCTAssertTrue(period.paymentRequestMessage(parentName: "Daddy")?.contains("$7.25") == true)
        period.settlement?.paidAt = Date()
        XCTAssertNil(period.paymentRequestMessage(parentName: "Daddy"))
        period.settlement?.paidAt = nil
        period.archivedAt = nil
        XCTAssertNil(period.paymentRequestMessage(parentName: "Daddy"))
    }

    func testLegacyPeriodDecodesWithoutSettlement() throws {
        let period = SeedData.snapshot().allowancePeriods[0]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(period)) as? [String: Any])
        object.removeValue(forKey: "settlement")
        let decoded = try JSONDecoder().decode(AllowancePeriod.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.settlement)
        XCTAssertFalse(decoded.canRequestPayment)
    }
}
