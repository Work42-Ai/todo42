// TodoSessionLink.swift — the session ↔ To-Do lifecycle link
// (feat/planning-generic-block-events-instead-of-first.15/.21).
//
// A task or code-review SESSION and its To-Do are linked by the To-Do's `url`:
//   - a task session      → `work42://task/<taskId>`
//   - a code-review session → `work42://code-review?pr=<prURL>`
//
// The link is derived (no stored session-id on the To-Do), so it stays correct
// however the session is created/reopened. The app calls these hooks:
//   - session CREATED  → `ensureTodo`  (create an open backlog To-Do, deduped)
//   - task reaches Done → `completeTodo` (scratch the linked To-Do)
//
// The archive lifecycle is now enforced by RESOLVE-ON-READ (not eager delete):
//   - `PlannedDayStore.listTodos(resolver:)` stamps `archivedAt` on any To-Do
//     whose linked session/task is archived (via `TodoSessionArchiveResolver`).
//   - A timed purge sweep (ArchiveScheduler.sweepArchivedTodosOffMain, .22)
//     hard-deletes soft-archived To-Dos past the retention window.
//   - There is NO eager hard-delete on archive.
//
// Code-review completion is intentionally NOT automated (manual — the user
// checks it off). Every hook is FAIL-SOFT: a store error never propagates, so
// session create/archive is never broken by a To-Do write.

import Foundation

public nonisolated enum TodoSessionLink {

    /// The `work42://task/<taskId>` link url for a task session's To-Do.
    public static func taskURL(taskId: String) -> String { "work42://task/\(taskId)" }

    /// The `work42://code-review?pr=<prURL>` link url for a code-review To-Do.
    public static func codeReviewURL(prURL: String) -> String {
        "work42://code-review?pr=\(prURL)"
    }

    /// On session CREATE: ensure an OPEN To-Do exists for `url`. Deduped — if
    /// any To-Do already carries this url, this is a no-op (re-opening a session
    /// never doubles its To-Do). `idFactory` is injectable for tests.
    @MainActor
    @discardableResult
    public static func ensureTodo(
        store: PlannedDayStore,
        url: String,
        title: String,
        reason: String? = nil,
        idFactory: () -> String = { UUID().uuidString.lowercased() }
    ) -> Todo? {
        let all = (try? store.listTodos()) ?? []
        if let existing = all.first(where: { $0.url == url }) { return existing }
        let todo = Todo(id: idFactory(), title: title, url: url, reason: reason)
        do {
            try store.addTodo(todo)
            return todo
        } catch {
            return nil
        }
    }

    /// On task DONE: scratch (complete) the To-Do linked to `url`. No-op when
    /// none matches or it's already complete.
    @MainActor
    public static func completeTodo(store: PlannedDayStore, url: String) {
        let all = (try? store.listTodos()) ?? []
        guard let match = all.first(where: { $0.url == url }) else { return }
        if !match.isCompleted { _ = try? store.setCompleted(id: match.id) }
    }

    /// The session id a To-Do's `url` resolves to (task / code-review / session
    /// link), or nil for a non-linking url — mirrors how the app derives a
    /// session id from a link. Task/code-review links resolve through
    /// `DerivedSessionId.make`, so a To-Do matches its session regardless of
    /// which url form it stores.
    @MainActor
    public static func linkedSessionId(url: String, slug: String) -> String? {
        switch Work42Link(string: url) {
        case .task(let id):
            return DerivedSessionId.make(projectId: slug, taskId: id)
        case .codeReview(let prURL):
            guard let key = Work42Link.normalizedPRKey(prURL) else { return nil }
            return DerivedSessionId.make(projectId: slug, taskId: key)
        case .session(let id):
            return id
        case .artifact(let id, _):
            return id
        case .external:
            return nil
        }
    }

    // MARK: - Slug-scoped convenience (open the store for a project slug)

    /// `ensureTodo` opening the per-workspace store for `slug`. Fail-soft.
    @MainActor
    public static func ensureTodo(slug: String, url: String, title: String, reason: String? = nil) {
        guard let store = try? PlannedDayStore(slug: slug) else { return }
        _ = ensureTodo(store: store, url: url, title: title, reason: reason)
    }

    /// `completeTodo` opening the per-workspace store for `slug`. Fail-soft.
    @MainActor
    public static func completeTodo(slug: String, url: String) {
        guard let store = try? PlannedDayStore(slug: slug) else { return }
        completeTodo(store: store, url: url)
    }
}
