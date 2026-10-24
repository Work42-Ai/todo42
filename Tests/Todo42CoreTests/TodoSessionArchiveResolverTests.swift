// TodoSessionArchiveResolverTests.swift — feat/planning-generic-block-events-instead-of-first.27
//
// Unit tests for TodoSessionArchiveResolver's routing logic in
// `isLinkedSessionArchived`. Uses the package-internal
// `init(slug:archivedTaskIds:archivedSessionIds:)` test seam (added in .27) to
// inject pre-computed sets without needing a real on-disk project
// (ProjectRegistry / archive.db / ChatSession). The seam note is in the .27
// report.
//
// Coverage:
//   - .task url whose id ∈ archivedTaskIds → true
//   - .task url whose id ∉ archivedTaskIds → false
//   - .codeReview url whose derived session id ∈ archivedSessionIds → true
//   - .session url whose id ∈ archivedSessionIds → true
//   - .external url → false
//   - nil/empty url → false
//   - unknown task id → false (set membership miss)

import Foundation
import Testing
@testable import Todo42Core

// The suite is @MainActor because isLinkedSessionArchived for .codeReview /
// .session calls TodoSessionLink.linkedSessionId (which is @MainActor), and the
// synchronous call is safe on the main actor.
@Suite("TodoSessionArchiveResolver — routing")
@MainActor
struct TodoSessionArchiveResolverTests {

    private let slug = "test-ws"

    // MARK: .task routing

    @Test("task url with id in archivedTaskIds returns true")
    func taskURLArchived() {
        let taskId = "T-archive-001"
        let resolver = TodoSessionArchiveResolver(
            slug: slug,
            archivedTaskIds: [taskId],
            archivedSessionIds: []
        )
        let todo = Todo(id: "t1", title: "x", url: "work42://task/\(taskId)")
        #expect(resolver.isLinkedSessionArchived(todo) == true)
    }

    @Test("task url with id NOT in archivedTaskIds returns false")
    func taskURLNotArchived() {
        let resolver = TodoSessionArchiveResolver(
            slug: slug,
            archivedTaskIds: ["other-task"],
            archivedSessionIds: []
        )
        let todo = Todo(id: "t1", title: "x", url: "work42://task/T-not-archived")
        #expect(resolver.isLinkedSessionArchived(todo) == false)
    }

    @Test("task url with no archived task ids at all returns false")
    func taskURLNoArchivedIds() {
        let resolver = TodoSessionArchiveResolver(
            slug: slug,
            archivedTaskIds: [],
            archivedSessionIds: []
        )
        let todo = Todo(id: "t1", title: "x", url: "work42://task/T-001")
        #expect(resolver.isLinkedSessionArchived(todo) == false)
    }

    // MARK: .codeReview routing

    @Test("code-review url whose derived session id is in archivedSessionIds returns true")
    func codeReviewURLArchived() {
        let prURL = "https://github.com/o/r/pull/42"
        // Compute the expected session id the same way the resolver does:
        // normalizedPRKey → DerivedSessionId.make(projectId:taskId:).
        let key = Work42Link.normalizedPRKey(prURL)!
        let expectedSessionId = DerivedSessionId.make(projectId: slug, taskId: key)

        let resolver = TodoSessionArchiveResolver(
            slug: slug,
            archivedTaskIds: [],
            archivedSessionIds: [expectedSessionId]
        )
        let url = "work42://code-review?pr=\(prURL)"
        let todo = Todo(id: "t1", title: "x", url: url)
        #expect(resolver.isLinkedSessionArchived(todo) == true)
    }

    @Test("code-review url whose derived session id is NOT in archivedSessionIds returns false")
    func codeReviewURLNotArchived() {
        let resolver = TodoSessionArchiveResolver(
            slug: slug,
            archivedTaskIds: [],
            archivedSessionIds: ["some-other-session-id"]
        )
        let todo = Todo(
            id: "t1", title: "x",
            url: "work42://code-review?pr=https://github.com/o/r/pull/99"
        )
        #expect(resolver.isLinkedSessionArchived(todo) == false)
    }

    // MARK: .session routing

    @Test("session url whose id is in archivedSessionIds returns true")
    func sessionURLArchived() {
        let sessionId = "abc-123-session"
        let resolver = TodoSessionArchiveResolver(
            slug: slug,
            archivedTaskIds: [],
            archivedSessionIds: [sessionId]
        )
        let todo = Todo(id: "t1", title: "x", url: "work42://session/\(sessionId)")
        #expect(resolver.isLinkedSessionArchived(todo) == true)
    }

    @Test("session url whose id is NOT in archivedSessionIds returns false")
    func sessionURLNotArchived() {
        let resolver = TodoSessionArchiveResolver(
            slug: slug,
            archivedTaskIds: [],
            archivedSessionIds: ["other-session"]
        )
        let todo = Todo(id: "t1", title: "x", url: "work42://session/my-session-id")
        #expect(resolver.isLinkedSessionArchived(todo) == false)
    }

    // MARK: .external / nil url

    @Test("external (https) url always returns false")
    func externalURLReturnsFalse() {
        let resolver = TodoSessionArchiveResolver(
            slug: slug,
            archivedTaskIds: ["anything"],
            archivedSessionIds: ["anything"]
        )
        let todo = Todo(id: "t1", title: "x", url: "https://example.com/dashboard")
        #expect(resolver.isLinkedSessionArchived(todo) == false)
    }

    @Test("nil url always returns false")
    func nilURLReturnsFalse() {
        let resolver = TodoSessionArchiveResolver(
            slug: slug,
            archivedTaskIds: ["anything"],
            archivedSessionIds: ["anything"]
        )
        let todo = Todo(id: "t1", title: "x", url: nil)
        #expect(resolver.isLinkedSessionArchived(todo) == false)
    }

    @Test("empty url always returns false")
    func emptyURLReturnsFalse() {
        let resolver = TodoSessionArchiveResolver(
            slug: slug,
            archivedTaskIds: ["anything"],
            archivedSessionIds: ["anything"]
        )
        let todo = Todo(id: "t1", title: "x", url: "")
        #expect(resolver.isLinkedSessionArchived(todo) == false)
    }
}
