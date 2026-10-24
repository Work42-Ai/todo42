// TodosCommandTests.swift — feat/planning-generic-block-events-instead-of-first.9/.26.
//
// CLI-layer unit tests for `work42 todos`: the pure `--slot` parser and the
// one-line list renderer. The store CRUD these commands drive is covered by
// TodoTests (Flow42CoreTests); here we cover the CLI's own parsing/rendering.
//
// .26 additions: `line()` marks soft-archived rows with [archived]; default
// listTodos excludes soft-archived To-Dos (mirrors what `work42 todos list`
// does without `--archived`); listTodos(includeArchived: true) includes them
// with a non-null archivedAt (mirrors `work42 todos list --archived`).

import Foundation
import Testing
@testable import todo42
@testable import Todo42Core

@Suite("work42 todos CLI")
struct TodosCommandTests {

    // MARK: --slot parsing

    @Test("parseSlots parses repeated <startISO>/<endISO> values in order")
    func parseSlotsValid() throws {
        let slots = try TodosCommand.parseSlots([
            "2026-06-06T09:00:00Z/2026-06-06T11:00:00Z",
            "2026-06-06T14:00:00Z/2026-06-06T16:00:00Z",
        ])
        #expect(slots.count == 2)
        #expect(slots[0].start == "2026-06-06T09:00:00Z")
        #expect(slots[0].end == "2026-06-06T11:00:00Z")
        #expect(slots[1].start == "2026-06-06T14:00:00Z")
    }

    @Test("parseSlots returns empty for no --slot values")
    func parseSlotsEmpty() throws {
        #expect(try TodosCommand.parseSlots([]).isEmpty)
    }

    @Test("parseSlots rejects a value without a slash separator")
    func parseSlotsNoSlash() {
        #expect(throws: TodosCommand.InputError.self) {
            _ = try TodosCommand.parseSlots(["2026-06-06T09:00:00Z"])
        }
    }

    @Test("parseSlots rejects a value with an empty side")
    func parseSlotsEmptySide() {
        #expect(throws: TodosCommand.InputError.self) {
            _ = try TodosCommand.parseSlots(["/2026-06-06T11:00:00Z"])
        }
        #expect(throws: TodosCommand.InputError.self) {
            _ = try TodosCommand.parseSlots(["2026-06-06T09:00:00Z/"])
        }
    }

    // MARK: list line rendering

    @Test("line renders a multi-slot timed To-Do with its link")
    func lineMultiSlot() {
        let todo = Todo(
            id: "t1", title: "Land T-003",
            slots: [
                TodoSlot(start: "2026-06-06T09:00:00Z", end: "2026-06-06T11:00:00Z"),
                TodoSlot(start: "2026-06-06T14:00:00Z", end: "2026-06-06T16:00:00Z"),
            ],
            url: "work42://task/T-003"
        )
        let line = TodosCommand.line(todo)
        #expect(line.contains("t1"))
        #expect(line.contains("Land T-003"))
        #expect(line.contains("2 slots"))
        #expect(line.contains("work42://task/T-003"))
        #expect(line.hasPrefix("○"))  // open
    }

    @Test("line renders an all-day To-Do and marks a completed one")
    func lineAllDayAndCompleted() {
        let allDay = Todo(id: "t2", title: "Renew cert", dueDate: "2026-06-11")
        #expect(TodosCommand.line(allDay).contains("all-day 2026-06-11"))

        let done = Todo(id: "t3", title: "Read RFC", completedAt: "2026-06-05T00:00:00Z")
        let line = TodosCommand.line(done)
        #expect(line.hasPrefix("✔"))
        #expect(line.contains("backlog"))
    }

    @Test("line marks a soft-archived To-Do with [archived] suffix")
    func lineArchivedSuffix() {
        let archived = Todo(
            id: "ta1", title: "Archived task",
            archivedAt: "2026-09-01T10:00:00Z"
        )
        let line = TodosCommand.line(archived)
        #expect(line.contains("[archived]"), "expected [archived] suffix in: \(line)")

        // A non-archived To-Do must NOT have the suffix.
        let open = Todo(id: "ta2", title: "Open task")
        #expect(!TodosCommand.line(open).contains("[archived]"))
    }

    // MARK: soft-archive store semantics (mirrors --archived flag behavior)

    @MainActor
    @Test("default listTodos excludes soft-archived To-Dos; includeArchived: true includes them")
    func archivedExcludeInclude() throws {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("todos-cmd-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let store = try PlannedDayStore(slug: "fixture", baseDirOverride: dir)

        // Seed two To-Dos: one to archive, one to keep open.
        let keep = Todo(id: "keep1", title: "Keep me")
        let toArchive = Todo(id: "arc1", title: "Archive me")
        try store.addTodo(keep)
        try store.addTodo(toArchive)

        // Soft-archive one via setArchived — mirrors what the resolver stamps.
        let changed = try store.setArchived(id: toArchive.id)
        #expect(changed, "setArchived should stamp a previously un-archived To-Do")

        // Default list (no resolver, includeArchived: false) → excludes archived.
        let defaultList = try store.listTodos()
        let defaultIds = defaultList.map(\.id)
        #expect(defaultIds.contains("keep1"),
                "default list must contain the non-archived To-Do")
        #expect(!defaultIds.contains("arc1"),
                "default list must exclude the soft-archived To-Do")

        // includeArchived: true → includes archived row with non-null archivedAt.
        let withArchived = try store.listTodos(includeArchived: true)
        let archivedTodo = withArchived.first(where: { $0.id == "arc1" })
        #expect(archivedTodo != nil,
                "includeArchived: true must return the soft-archived To-Do")
        #expect(archivedTodo?.archivedAt != nil,
                "archived To-Do must carry a non-null archivedAt")

        // A subsequent default list still excludes it (stamped persists).
        let subsequentList = try store.listTodos()
        #expect(!subsequentList.map(\.id).contains("arc1"),
                "subsequent default list must still exclude the soft-archived To-Do")
    }

    @MainActor
    @Test("remove still hard-deletes a To-Do regardless of archived state")
    func removeHardDeletes() throws {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("todos-cmd-remove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let store = try PlannedDayStore(slug: "fixture", baseDirOverride: dir)
        let todo = Todo(id: "r1", title: "Remove me")
        try store.addTodo(todo)
        _ = try store.setArchived(id: todo.id)

        // Even when archived, removeTodo hard-deletes the row.
        let removed = try store.removeTodo(id: todo.id)
        #expect(removed, "removeTodo must hard-delete regardless of archived state")

        // Neither default nor includeArchived list should find it.
        #expect(try store.listTodos(includeArchived: true).map(\.id).contains("r1") == false,
                "hard-deleted To-Do must not appear even with includeArchived: true")
    }
}
