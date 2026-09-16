import XCTest
@testable import DoGoodCore

final class AIReviewResultTests: XCTestCase {
    func testHighConfidenceIncompleteReviewStaysIncomplete() {
        let result = AIReviewResult(
            completed: false,
            confidence: 0.95,
            reason: "The bowl appears empty.",
            retakeSuggested: false
        )

        XCTAssertEqual(result.verdict, .likelyIncomplete)
    }

    func testUncertainReviewNeedsParentReview() {
        let result = AIReviewResult(
            completed: nil,
            confidence: 0.88,
            reason: "The task area is partly obscured.",
            retakeSuggested: false,
            parentReviewPriority: "high"
        )

        XCTAssertEqual(result.verdict, .needsParentReview)
    }
}
