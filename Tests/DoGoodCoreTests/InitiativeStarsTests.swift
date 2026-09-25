import XCTest
@testable import DoGoodCore

final class InitiativeStarsTests: XCTestCase {
    func testStarsStaySeparateAndScopedToChild() {
        let child = UUID()
        let entries = (0..<6).map { _ in InitiativeStar(id: UUID(), childId: child, amount: 1, reason: "Initiative", createdAt: Date()) }
        let spent = InitiativeStar(id: UUID(), childId: child, amount: -5, reason: "Credit", createdAt: Date())
        let sibling = InitiativeStar(id: UUID(), childId: UUID(), amount: 1, reason: "Initiative", createdAt: Date())
        XCTAssertEqual(InitiativeStars.balance(entries + [spent, sibling], childId: child), 1)
    }

    func testOnlyUnsettledMissedDeductionsAreCreditEligible() {
        var task = TaskOccurrence(choreDefinitionId: UUID(), childId: UUID(), weekId: UUID(),
            scheduledAt: Date(), dueAt: Date(), expiresAt: Date(), status: .missed)
        var deduction = LedgerEntry(weekId: task.weekId, type: .deduction, title: "Missed", amountCents: 100, relatedOccurrenceId: task.id)
        XCTAssertTrue(InitiativeStars.creditEligible(task, entries: [deduction], settled: false, requests: []))
        XCTAssertFalse(InitiativeStars.creditEligible(task, entries: [deduction], settled: true, requests: []))
        for status in ["pending", "approved", "declined"] {
            let request = StarCreditRequest(id: UUID(), childId: task.childId, occurrenceId: task.id, status: status, createdAt: Date())
            XCTAssertFalse(InitiativeStars.creditEligible(task, entries: [deduction], settled: false, requests: [request]))
        }
        deduction.isVoided = true
        XCTAssertFalse(InitiativeStars.creditEligible(task, entries: [deduction], settled: false, requests: []))
        deduction.isVoided = false
        task.status = .submitted
        XCTAssertFalse(InitiativeStars.creditEligible(task, entries: [deduction], settled: false, requests: []))
    }
}
