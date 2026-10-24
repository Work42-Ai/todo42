// TodoSessionLinkTests.swift — feat/planning-generic-block-events-instead-of-first.15.
//
// Unit tests for the session↔To-Do link (TodoSessionLink): url builders +
// the three lifecycle hooks (ensure on create + dedup, complete on Done,
// delete on archive) against a temp-dir store.

import Foundation
import Testing
@testable import Todo42Core

@Suite("Session ↔ To-Do link")
@MainActor
struct TodoSessionLinkTests {

    private func store() throws -> PlannedDayStore {
        let tmp = NSTemporaryDirectory() + "todo-link-\(UUID().uuidString)"
        return try PlannedDayStore(slug: "test-ws", baseDirOverride: tmp)
    }

    @Test("url builders produce the work42:// deep links")
    func urlBuilders() {
        #expect(TodoSessionLink.taskURL(taskId: "feat/foo") == "work42://task/feat/foo")
        #expect(TodoSessionLink.codeReviewURL(prURL: "https://github.com/o/r/pull/42")
            == "work42://code-review?pr=https://github.com/o/r/pull/42")
    }

    @Test("ensureTodo creates an open To-Do on first call and DEDUPES after")
    func ensureDedupes() throws {
        let s = try store()
        let url = TodoSessionLink.taskURL(taskId: "T-003")

        let first = TodoSessionLink.ensureTodo(store: s, url: url, title: "Land T-003")
        #expect(first != nil)
        #expect(try s.listTodos().count == 1)
        #expect(try s.listTodos().first?.url == url)
        #expect(try s.listTodos().first?.isCompleted == false)

        // Second call with the same url is a no-op (returns the existing one).
        let second = TodoSessionLink.ensureTodo(store: s, url: url, title: "Land T-003 (again)")
        #expect(second?.id == first?.id)
        #expect(try s.listTodos().count == 1)  // not doubled
    }

    @Test("completeTodo scratches the linked To-Do; no-op when none matches")
    func complete() throws {
        let s = try store()
        let url = TodoSessionLink.taskURL(taskId: "T-003")
        TodoSessionLink.ensureTodo(store: s, url: url, title: "Land T-003")

        TodoSessionLink.completeTodo(store: s, url: url)
        #expect(try s.listTodos().first?.isCompleted == true)

        // Unknown url → no crash, no change.
        TodoSessionLink.completeTodo(store: s, url: "work42://task/nope")
        #expect(try s.listTodos().count == 1)
    }

    @Test("linkedSessionId resolves task + code-review To-Do urls to their session id")
    func linkedSessionId() {
        let slug = "test-ws"
        let taskId = TodoSessionLink.linkedSessionId(url: "work42://task/T-003", slug: slug)
        #expect(taskId == DerivedSessionId.make(projectId: slug, taskId: "T-003"))

        let prURL = "https://github.com/o/r/pull/42"
        let key = Work42Link.normalizedPRKey(prURL)!
        let crId = TodoSessionLink.linkedSessionId(
            url: "work42://code-review?pr=\(prURL)", slug: slug)
        #expect(crId == DerivedSessionId.make(projectId: slug, taskId: key))

        // A /files variant of the same PR resolves to the SAME session id.
        let crId2 = TodoSessionLink.linkedSessionId(
            url: "work42://code-review?pr=\(prURL)/files", slug: slug)
        #expect(crId2 == crId)

        #expect(TodoSessionLink.linkedSessionId(url: "https://example.com", slug: slug) == nil)
    }

    // MARK: Regression: eager-delete API retired in .21

    // `deleteTodoForArchivedSession` and `deleteTodo` were removed from
    // TodoSessionLink in .21. The archive lifecycle is now enforced by:
    //   1. Resolve-on-read (TodoSessionArchiveResolver + PlannedDayStore.listTodos)
    //      stamps `archivedAt` on any To-Do whose linked session/task is archived.
    //   2. A timed purge (ArchiveScheduler.sweepArchivedTodosOffMain, .22)
    //      hard-deletes soft-archived To-Dos past the retention window.
    //
    // A "regression that the API is gone" cannot reference a non-existent symbol
    // in a compiling test. The positive evidence that the replacement path works is:
    //   - The tests above (ensureTodo, completeTodo, linkedSessionId) compile and
    //     pass without any `deleteTodoForArchivedSession` or `deleteTodo` symbol.
    //   - PlannedDayStoreTodosArchiveTests exercises the resolve-on-read path end-
    //     to-end (see resolveOnRead test).
    //   - TodoSessionArchiveResolverTests exercises the routing logic of the
    //     concrete resolver.
    //
    // This comment serves as the permanent audit trail for the removal (.21) and
    // the corresponding test guard (.27).
}
