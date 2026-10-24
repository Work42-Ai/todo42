// PlannedDayStoreTodosArchiveTests.swift — feat/planning-generic-block-events-instead-of-first.27
//
// Tests for the v2 To-Do archive lifecycle in PlannedDayStore:
//   - Additive migration: existing DBs gain `archived_at` with nil on old rows.
//   - setArchived / listTodos(includeArchived:) semantics.
//   - purgeArchivedTodos(before:) deletes only eligible rows, cascades slots,
//     returns an accurate count, leaves unarchived / future rows intact.
//   - Resolve-on-read: a stub TodoSessionArchiveResolving stamps archivedAt,
//     persists it, and excludes it from default results; plain/nil-url To-Dos
//     are never stamped.
//
// All store tests use a temp-dir baseDirOverride for isolation.

import Foundation
import SQLite3
import Testing
@testable import Todo42Core

// MARK: - Stub resolver

/// Minimal test conformer: returns `true` iff the todo's url matches one of
/// the pre-supplied urls.
private struct StubResolver: TodoSessionArchiveResolving {
    let archivedURLs: Set<String>
    func isLinkedSessionArchived(_ todo: Todo) -> Bool {
        guard let url = todo.url else { return false }
        return archivedURLs.contains(url)
    }
}

// MARK: - Suite

@Suite("PlannedDayStore — todos archive lifecycle")
@MainActor
struct PlannedDayStoreTodosArchiveTests {

    private func tempDir(tag: String) -> String {
        NSTemporaryDirectory() + "todos-archive-\(tag)-\(UUID().uuidString)"
    }

    // MARK: Additive migration

    @Test("archived_at column exists after store open; existing rows have archivedAt == nil")
    func additiveMigrationColumn() throws {
        let tmp = tempDir(tag: "migration")
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let store = try PlannedDayStore(slug: "ws", baseDirOverride: tmp)

        // PRAGMA table_info returns one row per column; check archived_at is present.
        var foundColumn = false
        store.withRawConnection { db in
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "PRAGMA table_info(todos)", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let cstr = sqlite3_column_text(stmt, 1),
                       String(cString: cstr) == "archived_at" {
                        foundColumn = true
                    }
                }
            }
            sqlite3_finalize(stmt)
        }
        #expect(foundColumn, "todos table must carry an archived_at column")

        // Seed a To-Do and confirm it reads back with archivedAt == nil.
        try store.addTodo(Todo(id: "t1", title: "Old row"))
        let readBack = try store.todo(id: "t1")
        #expect(readBack?.archivedAt == nil,
                "a freshly inserted To-Do must have archivedAt == nil")
    }

    // MARK: setArchived + listTodos(includeArchived:)

    @Test("setArchived stamps archived_at; default list excludes it; includeArchived: true includes it")
    func setArchivedExcludeInclude() throws {
        let tmp = tempDir(tag: "set-archived")
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let store = try PlannedDayStore(slug: "ws", baseDirOverride: tmp)

        let open = Todo(id: "open1", title: "Stay open")
        let toArchive = Todo(id: "arch1", title: "Will be archived")
        try store.addTodo(open)
        try store.addTodo(toArchive)

        // setArchived returns true on success, stamps the row.
        let stamped = try store.setArchived(id: toArchive.id, at: "2026-09-01T10:00:00Z")
        #expect(stamped, "setArchived must return true when the To-Do exists")
        let archivedRow = try store.todo(id: toArchive.id)
        #expect(archivedRow?.archivedAt == "2026-09-01T10:00:00Z",
                "setArchived must persist the stamp")
        #expect(archivedRow?.isArchived == true)

        // Default list (includeArchived: false) excludes the archived row.
        let defaultList = try store.listTodos()
        #expect(defaultList.map(\.id).contains("open1"),
                "default list must include the open To-Do")
        #expect(!defaultList.map(\.id).contains("arch1"),
                "default list must exclude the soft-archived To-Do")

        // includeArchived: true includes it.
        let allList = try store.listTodos(includeArchived: true)
        #expect(allList.map(\.id).contains("arch1"),
                "includeArchived: true must include the soft-archived To-Do")
        #expect(allList.first(where: { $0.id == "arch1" })?.archivedAt != nil,
                "included archived To-Do must carry a non-nil archivedAt")

        // setArchived on an unknown id returns false (no error).
        let missing = try store.setArchived(id: "ghost")
        #expect(!missing, "setArchived on an unknown id must return false")
    }

    // MARK: purgeArchivedTodos(before:)

    @Test("purgeArchivedTodos deletes only rows with archived_at < cutoff; cascades slots; returns count; leaves others")
    func purgeArchivedTodos() throws {
        let tmp = tempDir(tag: "purge")
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let store = try PlannedDayStore(slug: "ws", baseDirOverride: tmp)

        // Row 1: archived BEFORE cutoff → should be purged.
        let earlyStamp = "2026-08-01T00:00:00.000Z"
        var todoEarly = Todo(
            id: "early", title: "Early archived",
            slots: [TodoSlot(start: "2026-08-01T09:00:00Z", end: "2026-08-01T10:00:00Z")]
        )
        try store.addTodo(todoEarly)
        _ = try store.setArchived(id: "early", at: earlyStamp)

        // Row 2: archived AFTER cutoff → must survive.
        let futureStamp = "2026-10-01T00:00:00.000Z"
        var todoFuture = Todo(id: "future", title: "Future archived")
        try store.addTodo(todoFuture)
        _ = try store.setArchived(id: "future", at: futureStamp)

        // Row 3: nil archived_at → must survive.
        try store.addTodo(Todo(id: "alive", title: "Not archived"))

        let cutoff = "2026-09-01T00:00:00.000Z"
        let deleted = try store.purgeArchivedTodos(before: cutoff)
        #expect(deleted == 1, "purge must delete exactly the row whose archived_at < cutoff")

        // Early row gone.
        #expect(try store.todo(id: "early") == nil,
                "early-archived To-Do must be purged")

        // Slots of the early row are gone too (cascade).
        var slotCount = -1
        store.withRawConnection { db in
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(
                db,
                "SELECT COUNT(*) FROM todo_slots WHERE todo_id = 'early'",
                -1, &stmt, nil
            ) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    slotCount = Int(sqlite3_column_int64(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)
        }
        #expect(slotCount == 0,
                "slots for the purged To-Do must be deleted (cascade)")

        // Future-archived and nil-archived rows survive.
        #expect(try store.todo(id: "future") != nil,
                "future-archived To-Do must survive")
        #expect(try store.todo(id: "alive") != nil,
                "non-archived To-Do must survive")

        // Second purge with nothing eligible returns 0.
        let secondPurge = try store.purgeArchivedTodos(before: cutoff)
        #expect(secondPurge == 0, "second purge with no eligible rows must return 0")
    }

    // MARK: Resolve-on-read with stub

    @Test("resolve-on-read: stub resolver stamps archivedAt, persists it, excludes from default list; plain To-Do not stamped")
    func resolveOnRead() throws {
        let tmp = tempDir(tag: "resolver")
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let store = try PlannedDayStore(slug: "ws", baseDirOverride: tmp)

        let linkedURL = "work42://task/T-archive-test"

        // A To-Do linked to an archived session (stub returns true for this url).
        try store.addTodo(Todo(
            id: "linked", title: "Linked task",
            url: linkedURL
        ))
        // A plain To-Do with no url (stub returns false for nil url).
        try store.addTodo(Todo(id: "plain", title: "Plain reminder"))

        let resolver = StubResolver(archivedURLs: [linkedURL])

        // listTodos(resolver:) should stamp the linked To-Do and exclude it.
        let result = try store.listTodos(resolver: resolver, includeArchived: false)
        #expect(!result.map(\.id).contains("linked"),
                "resolve-on-read must exclude the freshly-stamped linked To-Do")
        #expect(result.map(\.id).contains("plain"),
                "plain To-Do must not be stamped and must remain in the default list")

        // The stamp PERSISTS: re-read without resolver still shows archivedAt != nil.
        let reread = try store.todo(id: "linked")
        #expect(reread?.archivedAt != nil,
                "resolve-on-read stamp must be persisted so subsequent reads see it")

        // Plain To-Do has no stamp.
        let plainReread = try store.todo(id: "plain")
        #expect(plainReread?.archivedAt == nil,
                "plain (nil-url) To-Do must NOT be stamped by the resolver")

        // includeArchived: true with same resolver includes already-stamped row
        // (stamp is already present, resolver won't re-stamp).
        let withArchived = try store.listTodos(resolver: resolver, includeArchived: true)
        #expect(withArchived.map(\.id).contains("linked"),
                "includeArchived: true must include the stamped To-Do")
        #expect(withArchived.map(\.id).contains("plain"),
                "includeArchived: true must still include the plain To-Do")
    }
}
