// TodoTests.swift — feat/planning-generic-block-events-instead-of-first.8.
//
// Unit tests for the generic `Todo` model (Sources/Flow42Core/Common/Todo.swift)
// and its store surface in `PlannedDayStore` (todos + todo_slots tables + the
// one-time planned_blocks → todos migration). Covers:
//   - Todo/TodoSlot validation (title, slot ordering, dueDate),
//   - TodoDerivedKind(from:url) mapping,
//   - decode + validate round-trip,
//   - store CRUD (add → todo(id:)/list, update replaces slots, complete/reopen,
//     remove cascades slots) + list filters (date/open/done),
//   - the planned_blocks → todos migration (multi-slot grouping, malformed row,
//     idempotency).
//
// The pure model tests touch no filesystem. The store tests use a temp-dir
// `baseDirOverride` so they never touch a real workspace.

import Foundation
import SQLite3
import Testing
@testable import Todo42Core

@Suite("Todo model + todos store")
struct TodoTests {

    // MARK: - Validation

    @Test("a valid multi-slot To-Do validates")
    func validMultiSlotValidates() throws {
        let todo = Todo(
            id: "t1", title: "Land T-003",
            slots: [
                TodoSlot(start: "2026-06-06T09:00:00Z", end: "2026-06-06T11:00:00Z"),
                TodoSlot(start: "2026-06-06T14:00:00Z", end: "2026-06-06T16:00:00Z"),
            ],
            url: "work42://task/T-003"
        )
        try todo.validate()  // does not throw
    }

    @Test("an empty title is rejected")
    func emptyTitleRejected() {
        let todo = Todo(id: "t1", title: "   ")
        #expect(throws: PlannedDay.ValidationError.self) { try todo.validate() }
    }

    @Test("a slot whose end is not after start is rejected")
    func badSlotOrderingRejected() {
        let todo = Todo(
            id: "t1", title: "x",
            slots: [TodoSlot(start: "2026-06-06T11:00:00Z", end: "2026-06-06T09:00:00Z")]
        )
        #expect(throws: PlannedDay.ValidationError.self) { try todo.validate() }
    }

    @Test("a slot with a non-ISO8601 timestamp is rejected")
    func badSlotTimestampRejected() {
        let todo = Todo(
            id: "t1", title: "x",
            slots: [TodoSlot(start: "nope", end: "2026-06-06T09:00:00Z")]
        )
        #expect(throws: PlannedDay.ValidationError.self) { try todo.validate() }
    }

    @Test("an invalid dueDate is rejected")
    func badDueDateRejected() {
        let todo = Todo(id: "t1", title: "x", dueDate: "6th June")
        #expect(throws: PlannedDay.ValidationError.self) { try todo.validate() }
    }

    @Test("an all-day To-Do (no slots, valid dueDate) validates")
    func allDayValidates() throws {
        try Todo(id: "t1", title: "Renew cert", dueDate: "2026-06-11").validate()
    }

    @Test("an undated backlog To-Do (no slots, no dueDate) validates")
    func backlogValidates() throws {
        try Todo(id: "t1", title: "Read the RFC").validate()
    }

    // MARK: - archivedAt / isArchived

    @Test("archivedAt defaults to nil; isArchived reflects it")
    func archivedAtDefaultsNil() {
        let todo = Todo(id: "t1", title: "Backlog item")
        #expect(todo.archivedAt == nil)
        #expect(todo.isArchived == false)
    }

    @Test("archivedAt round-trips through Codable; isArchived reflects a non-nil stamp")
    func archivedAtCodableRoundTrip() throws {
        let stamp = "2026-09-01T10:00:00Z"
        let original = Todo(id: "t1", title: "Archived task", archivedAt: stamp)
        #expect(original.isArchived == true)

        // Encode → decode.
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Todo.self, from: data)
        #expect(decoded.archivedAt == stamp)
        #expect(decoded.isArchived == true)
    }

    @Test("a Todo with no archivedAt in JSON decodes with archivedAt == nil")
    func archivedAtAbsentInJSON() throws {
        let json = """
        { "id": "t1", "title": "Plain task", "slots": [] }
        """
        let todo = try JSONDecoder().decode(Todo.self, from: Data(json.utf8))
        #expect(todo.archivedAt == nil)
        #expect(todo.isArchived == false)
    }

    // MARK: - DerivedKind

    @Test("derivedKind maps from the url")
    func derivedKindMapping() {
        #expect(TodoDerivedKind(from: "work42://task/T-003") == .task)
        #expect(TodoDerivedKind(from: "work42://code-review?pr=https://github.com/o/r/pull/42") == .review)
        #expect(TodoDerivedKind(from: "work42://code-review?pr=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F42") == .review)
        #expect(TodoDerivedKind(from: "work42://session/abc123") == .session)
        #expect(TodoDerivedKind(from: "https://example.com/dashboard") == .link)
        #expect(TodoDerivedKind(from: "work42://unknown/thing") == .link)
        #expect(TodoDerivedKind(from: nil) == .todo)
        #expect(TodoDerivedKind(from: "   ") == .todo)
    }

    // MARK: - decode + validate

    @Test("decodeAndValidate round-trips a To-Do")
    func decodeRoundTrips() throws {
        let json = """
        {
          "id": "t1",
          "title": "Land T-003",
          "slots": [{ "start": "2026-06-06T09:00:00Z", "end": "2026-06-06T11:00:00Z" }],
          "url": "work42://task/T-003",
          "reason": "closest to done"
        }
        """
        let todo = try Todo.decodeAndValidate(Data(json.utf8))
        #expect(todo.id == "t1")
        #expect(todo.slots.count == 1)
        #expect(todo.derivedKind == .task)
        #expect(todo.isTimed == true)
        #expect(todo.isCompleted == false)
    }

    // MARK: - Store CRUD

    @MainActor
    @Test("add → todo(id:)/list, update replaces slots, complete/reopen, remove")
    func storeCRUD() throws {
        let tmp = NSTemporaryDirectory() + "todo-crud-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let store = try PlannedDayStore(slug: "test-ws", baseDirOverride: tmp)

        let todo = Todo(
            id: "t1", title: "Land T-003",
            slots: [TodoSlot(start: "2026-06-06T09:00:00Z", end: "2026-06-06T11:00:00Z")],
            url: "work42://task/T-003", reason: "closest to done"
        )
        try store.addTodo(todo)

        // Read back one, with its slots.
        let readBack = try store.todo(id: "t1")
        #expect(readBack?.title == "Land T-003")
        #expect(readBack?.slots.count == 1)
        #expect(readBack?.url == "work42://task/T-003")
        #expect(try store.listTodos().count == 1)

        // Update replaces the whole slot set + fields.
        var revised = todo
        revised.title = "Land T-003 (revised)"
        revised.slots = [
            TodoSlot(start: "2026-06-06T09:00:00Z", end: "2026-06-06T11:00:00Z"),
            TodoSlot(start: "2026-06-06T14:00:00Z", end: "2026-06-06T16:00:00Z"),
        ]
        try store.updateTodo(revised)
        let afterUpdate = try store.todo(id: "t1")
        #expect(afterUpdate?.title == "Land T-003 (revised)")
        #expect(afterUpdate?.slots.count == 2)

        // Complete / reopen.
        #expect(try store.setCompleted(id: "t1", at: "2026-06-06T16:30:00Z") == true)
        #expect(try store.todo(id: "t1")?.isCompleted == true)
        #expect(try store.clearCompleted(id: "t1") == true)
        #expect(try store.todo(id: "t1")?.isCompleted == false)

        // Unknown-id completion is a no-op false, not an error.
        #expect(try store.setCompleted(id: "nope") == false)

        // Remove cascades slots.
        #expect(try store.removeTodo(id: "t1") == true)
        #expect(try store.todo(id: "t1") == nil)
        #expect(try store.listTodos().isEmpty == true)
        // No orphan slots left behind.
        var slotCount = -1
        store.withRawConnection { db in
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM todo_slots", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW { slotCount = Int(sqlite3_column_int64(stmt, 0)) }
            }
            sqlite3_finalize(stmt)
        }
        #expect(slotCount == 0)
    }

    @MainActor
    @Test("updateTodo on an unknown id throws")
    func updateUnknownThrows() throws {
        let tmp = NSTemporaryDirectory() + "todo-upd-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let store = try PlannedDayStore(slug: "test-ws", baseDirOverride: tmp)
        #expect(throws: PlannedDay.ValidationError.self) {
            try store.updateTodo(Todo(id: "ghost", title: "x"))
        }
    }

    @MainActor
    @Test("listTodos filters by date, open, and done")
    func listFilters() throws {
        let tmp = NSTemporaryDirectory() + "todo-filter-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let store = try PlannedDayStore(slug: "test-ws", baseDirOverride: tmp)

        // A timed To-Do on 2026-06-06.
        try store.addTodo(Todo(
            id: "timed", title: "Timed",
            slots: [TodoSlot(start: "2026-06-06T09:00:00Z", end: "2026-06-06T10:00:00Z")]
        ))
        // An all-day To-Do due 2026-06-06.
        try store.addTodo(Todo(id: "allday", title: "All-day", dueDate: "2026-06-06"))
        // An all-day To-Do due a different day.
        try store.addTodo(Todo(id: "other", title: "Other day", dueDate: "2026-06-07"))
        // An undated backlog item, already completed.
        try store.addTodo(Todo(id: "backlog", title: "Backlog",
                               completedAt: "2026-06-05T00:00:00Z"))

        // --date keeps the timed + all-day items for that day only.
        let onSix = try store.listTodos(date: "2026-06-06")
        #expect(Set(onSix.map(\.id)) == ["timed", "allday"])

        // --open excludes the completed backlog item.
        let open = try store.listTodos(open: true)
        #expect(open.contains { $0.id == "backlog" } == false)
        #expect(open.count == 3)

        // --done keeps only the completed one.
        let done = try store.listTodos(done: true)
        #expect(done.map(\.id) == ["backlog"])
    }

    // MARK: - Migration

    @MainActor
    @Test("planned_blocks → todos migration groups same-url/day into one multi-slot To-Do, idempotently")
    func migrationLiftsBlocks() throws {
        let tmp = NSTemporaryDirectory() + "todo-migrate-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // First open migrates an empty planned_blocks → user_version = 1.
        let seed = try PlannedDayStore(slug: "test-ws", baseDirOverride: tmp)

        // Seed legacy planned_blocks directly (the write API is gone — the table
        // survives only as the migration source): two task stretches (same ref +
        // day → one multi-slot To-Do), a prReview, and a malformed-start row.
        // Then reset user_version to 0 so the next open re-runs the migration.
        seed.withRawConnection { db in
            let rows = [
                "('2026-06-06','task','T-003','Land T-003','2026-06-06T09:00:00Z','2026-06-06T11:00:00Z','2026-06-06T08:00:00Z')",
                "('2026-06-06','task','T-003','Land T-003','2026-06-06T14:00:00Z','2026-06-06T16:00:00Z','2026-06-06T08:00:00Z')",
                "('2026-06-06','prReview','https://github.com/o/r/pull/42','Fix race','2026-06-06T11:30:00Z','2026-06-06T12:00:00Z','2026-06-06T08:00:00Z')",
                "('2026-06-07','task','T-009','Broken','bad','bad','2026-06-06T08:00:00Z')",
            ]
            for values in rows {
                sqlite3_exec(db,
                    "INSERT INTO planned_blocks (date, kind, ref, title, start, end, created_at) VALUES \(values)",
                    nil, nil, nil)
            }
            sqlite3_exec(db, "PRAGMA user_version = 0", nil, nil, nil)
        }

        // Reopen → migration runs.
        let migrated = try PlannedDayStore(slug: "test-ws", baseDirOverride: tmp)
        let todos = try migrated.listTodos()

        let taskTodo = todos.first { $0.url == "work42://task/T-003" }
        #expect(taskTodo != nil)
        #expect(taskTodo?.slots.count == 2)  // AM + PM stretches collapsed into one To-Do.
        #expect(taskTodo?.title == "Land T-003")

        let prTodo = todos.first { $0.url?.hasPrefix("work42://code-review?pr=") == true }
        #expect(prTodo != nil)
        #expect(prTodo?.slots.count == 1)
        #expect(prTodo?.derivedKind == .review)

        let broken = todos.first { $0.url == "work42://task/T-009" }
        #expect(broken != nil)
        #expect(broken?.slots.isEmpty == true)   // unparseable start → no slot…
        #expect(broken?.dueDate == "2026-06-07") // …becomes an all-day To-Do on its date.

        // Idempotent: reopening does not duplicate (user_version now 1).
        let countAfter = try migrated.listTodos().count
        let reopened = try PlannedDayStore(slug: "test-ws", baseDirOverride: tmp)
        #expect(try reopened.listTodos().count == countAfter)
    }
}
