import XCTest
@testable import DoGoodCore

final class ChildSelectionTests: XCTestCase {
    func testParentPreferenceSurvivesProfileOrdering() {
        let seed = SeedData.snapshot()
        let first = seed.childProfiles[0]
        var second = first
        second.id = UUID()
        second.createdAt = first.createdAt.addingTimeInterval(60)
        for profiles in [[first, second], [second, first]] {
            XCTAssertEqual(ChildProfile.selected(from: profiles, familyId: seed.familyId,
                role: .parent, userId: seed.parentId, preferredId: second.id)?.id, second.id)
        }
    }

    func testDeletedPreferenceFallsBackWithinFamilyOnly() {
        let seed = SeedData.snapshot()
        let child = seed.childProfiles[0]
        var stranger = child
        stranger.id = UUID()
        stranger.familyId = UUID()
        stranger.createdAt = .distantPast
        XCTAssertEqual(ChildProfile.selected(from: [stranger, child], familyId: seed.familyId,
            role: .parent, userId: seed.parentId, preferredId: stranger.id)?.id, child.id)
        XCTAssertNil(ChildProfile.selected(from: [stranger], familyId: seed.familyId,
            role: .parent, userId: seed.parentId, preferredId: stranger.id))
    }

    func testChildCannotFallBackToSiblingOrParentPreference() {
        let seed = SeedData.snapshot()
        var child = seed.childProfiles[0]
        let userId = UUID()
        child.linkedUserId = userId
        var sibling = child
        sibling.id = UUID()
        sibling.linkedUserId = UUID()
        XCTAssertEqual(ChildProfile.selected(from: [sibling, child], familyId: seed.familyId,
            role: .child, userId: userId, preferredId: sibling.id)?.id, child.id)
        XCTAssertNil(ChildProfile.selected(from: [sibling], familyId: seed.familyId,
            role: .child, userId: userId, preferredId: sibling.id))
    }
}
