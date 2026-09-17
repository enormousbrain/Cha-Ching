import XCTest
@testable import DoGoodCore

final class MutationCommitterTests: XCTestCase {
    @MainActor
    func testRemoteFailureDoesNotCommitLocally() async {
        var didAttemptRemoteSave = false
        var didCommitLocally = false

        do {
            try await MutationCommitter.commit(
                mode: .remoteRequired,
                remoteSave: {
                    didAttemptRemoteSave = true
                    throw TestError.remoteFailure
                },
                localCommit: {
                    didCommitLocally = true
                }
            )
            XCTFail("Expected the remote save to fail")
        } catch {
            XCTAssertEqual(error as? TestError, .remoteFailure)
        }

        XCTAssertTrue(didAttemptRemoteSave)
        XCTAssertFalse(didCommitLocally)
    }

    @MainActor
    func testRemoteSuccessCommitsLocallyAfterSaving() async throws {
        var events: [String] = []

        try await MutationCommitter.commit(
            mode: .remoteRequired,
            remoteSave: {
                events.append("remote")
            },
            localCommit: {
                events.append("local")
            }
        )

        XCTAssertEqual(events, ["remote", "local"])
    }

    @MainActor
    func testLocalPreviewSkipsRemoteSave() async throws {
        var didAttemptRemoteSave = false
        var didCommitLocally = false

        try await MutationCommitter.commit(
            mode: .localPreview,
            remoteSave: {
                didAttemptRemoteSave = true
            },
            localCommit: {
                didCommitLocally = true
            }
        )

        XCTAssertFalse(didAttemptRemoteSave)
        XCTAssertTrue(didCommitLocally)
    }
}

private enum TestError: Error, Equatable {
    case remoteFailure
}
