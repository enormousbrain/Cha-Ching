import XCTest
@testable import DoGoodCore

final class ChoreOccurrenceGroupTests: XCTestCase {
    func testGroupsRepeatedDatesButSeparatesChildrenChoresAndTimes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let child = UUID(), chore = UUID(), week = UUID()
        func task(day: Int, hour: Int, childId: UUID = child, choreId: UUID = chore) -> TaskOccurrence {
            let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
            return TaskOccurrence(choreDefinitionId: choreId, childId: childId, weekId: week,
                scheduledAt: date, dueAt: date, expiresAt: date, status: .missed)
        }
        let first = task(day: 1, hour: 10), second = task(day: 2, hour: 10)
        let groups = ChoreOccurrenceGroup.grouped([second, task(day: 1, hour: 18), first,
            task(day: 1, hour: 10, childId: UUID()), task(day: 1, hour: 10, choreId: UUID())], calendar: calendar)
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.first { $0.occurrences.count == 2 }?.occurrences.map(\.id), [first.id, second.id])
        XCTAssertTrue(ChoreOccurrenceGroup.grouped([], calendar: calendar).isEmpty)
    }

    func testNoPhotoClaimPreservesEmptyNoteAsDistinctFromOrdinarySubmission() throws {
        let claim = ChoreSubmission(taskOccurrenceId: UUID(), childId: UUID(), imageName: "no-photo", reportedDoneNote: "")
        let decoded = try JSONDecoder().decode(ChoreSubmission.self, from: JSONEncoder().encode(claim))
        XCTAssertEqual(decoded.reportedDoneNote, "")
        let ordinary = ChoreSubmission(taskOccurrenceId: UUID(), childId: UUID(), imageName: "no-photo")
        XCTAssertNil(try JSONDecoder().decode(ChoreSubmission.self, from: JSONEncoder().encode(ordinary)).reportedDoneNote)
    }
}
