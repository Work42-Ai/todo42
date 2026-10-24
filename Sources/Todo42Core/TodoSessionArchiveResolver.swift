// TodoSessionArchiveResolver.swift — the resolve-on-read seam for the To-Do soft-archive lifecycle
// (feat/planning-generic-block-events-instead-of-first.20/.21, WOR-382).
//
// `TodoSessionArchiveResolving` is what `PlannedDayStore.listTodos` consumes to stamp `archived_at` on any
// To-Do whose linked session/task has been archived since the last read.
//
// `TodoSessionArchiveResolver` answers from two sets of archived ids and does no I/O. todo42 cannot look
// sessions up itself (it has no Work42 code), so whoever calls it brings the sets: the Work42 plugin's
// background agent asks the app's `work42-session` tools which linked sessions are archived. Fail-soft by
// construction — an id that is not in a set is not archived, so a failed lookup never archives anything.
//
// Concurrency: nonisolated, so it can be called from any context (the store's @MainActor `listTodos`
// calls it synchronously).

import Foundation

/// A type that can say whether a To-Do's linked session or task has been archived.
///
/// Conformers answer `isLinkedSessionArchived` synchronously with no I/O (when in doubt, return `false`
/// so nothing is wrongly archived).
public protocol TodoSessionArchiveResolving: Sendable {

    /// `true` iff the session or task linked by `todo.url` is currently archived. `false` for plain,
    /// external and nil urls.
    func isLinkedSessionArchived(_ todo: Todo) -> Bool
}

/// The `TodoSessionArchiveResolving` backed by precomputed archived-id sets.
///
/// `isLinkedSessionArchived` routes by `Work42Link` case:
///   - `.task(id)` -> `archivedTaskIds.contains(id)`
///   - `.codeReview` / `.session` / `.artifact` -> derive the session id with
///     `TodoSessionLink.linkedSessionId(url:slug:)`, then check `archivedSessionIds`
///   - `.external` or a nil url -> `false`
public struct TodoSessionArchiveResolver: TodoSessionArchiveResolving {

    private let slug: String
    private let archivedTaskIds: Set<String>
    private let archivedSessionIds: Set<String>

    /// - Parameters:
    ///   - slug: the project slug, used to derive the session id a task or code-review link resolves to.
    ///   - archivedTaskIds: ids of archived tasks (the id in a `work42://task/<id>` link).
    ///   - archivedSessionIds: ids of archived sessions (derived from code-review, session and artifact links).
    public init(slug: String, archivedTaskIds: Set<String> = [], archivedSessionIds: Set<String> = []) {
        self.slug = slug
        self.archivedTaskIds = archivedTaskIds
        self.archivedSessionIds = archivedSessionIds
    }

    public func isLinkedSessionArchived(_ todo: Todo) -> Bool {
        guard let url = todo.url, !url.isEmpty else { return false }
        switch Work42Link(string: url) {
        case .task(let id):
            return archivedTaskIds.contains(id)
        case .codeReview, .session, .artifact:
            guard let sid = TodoSessionLink.linkedSessionId(url: url, slug: slug) else { return false }
            return archivedSessionIds.contains(sid)
        case .external:
            return false
        }
    }
}
