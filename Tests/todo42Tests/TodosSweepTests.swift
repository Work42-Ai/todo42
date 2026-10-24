// TodosSweepTests.swift — `todo42 todos sweep`, the archive pass the Work42 plugin runs (WOR-382).
//
// The old in-app sweep stamped archived_at on To-Dos whose linked task/session had been archived (resolve on
// read) and then purged those archived longer ago than the window. todo42 can't look sessions up, so the caller
// names the archived ids; the stamping and purging are the same store operations.

import Foundation
import Testing
@testable import todo42
@testable import Todo42Core

@Suite("todos sweep")
struct TodosSweepTests {

    private func store() throws -> (PlannedDayStore, String) {
        let dir = NSTemporaryDirectory() + "todo42-sweep-\(UUID().uuidString)"
        return (try PlannedDayStore(slug: "p", baseDirOverride: dir), dir)
    }

    @Test("a To-Do linked to an archived task is stamped, an unrelated one is not")
    func stampsLinkedTodos() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try store.addTodo(Todo(id: "a", title: "task", url: "work42://task/sess-1"))
        try store.addTodo(Todo(id: "b", title: "other task", url: "work42://task/sess-2"))
        try store.addTodo(Todo(id: "c", title: "plain"))

        let result = try TodosCommand.sweep(
            store: store, archivedTaskIds: ["sess-1"], archivedSessionIds: [], purgeAfterHours: nil)
        #expect(result.stamped == 1 && result.purged == 0)
        #expect(try store.todo(id: "a")?.isArchived == true)
        #expect(try store.todo(id: "b")?.isArchived == false)
        #expect(try store.todo(id: "c")?.isArchived == false)
    }

    @Test("a To-Do linked to an archived session id is stamped through its derived id")
    func stampsBySessionId() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try store.addTodo(Todo(id: "s", title: "session", url: "work42://session/abc-123"))
        let result = try TodosCommand.sweep(
            store: store, archivedTaskIds: [], archivedSessionIds: ["abc-123"], purgeAfterHours: nil)
        #expect(result.stamped == 1)
        #expect(try store.todo(id: "s")?.isArchived == true)
    }

    @Test("only To-Dos archived longer ago than the window are purged")
    func purgesByAge() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try store.addTodo(Todo(id: "old", title: "old"))
        try store.addTodo(Todo(id: "new", title: "new"))
        try store.setArchived(id: "old", at: "2026-01-01T00:00:00.000Z")
        try store.setArchived(id: "new", at: "2026-06-06T11:00:00.000Z")

        let now = ISO8601DateFormatter().date(from: "2026-06-06T12:00:00Z")!
        let result = try TodosCommand.sweep(
            store: store, archivedTaskIds: [], archivedSessionIds: [], purgeAfterHours: 24, now: now)
        #expect(result.purged == 1)
        #expect(try store.todo(id: "old") == nil)
        #expect(try store.todo(id: "new") != nil)
    }

    @Test("without a window nothing is purged")
    func keepsWithoutWindow() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try store.addTodo(Todo(id: "old", title: "old"))
        try store.setArchived(id: "old", at: "2020-01-01T00:00:00.000Z")
        let result = try TodosCommand.sweep(
            store: store, archivedTaskIds: [], archivedSessionIds: [], purgeAfterHours: nil)
        #expect(result.purged == 0)
        #expect(try store.todo(id: "old") != nil)
    }

    @Test("--purge-after-hours is parsed with the repeatable id options")
    func parses() throws {
        let command = try TodosCommand.SweepCommand.parse(
            ["--archived-task", "a", "--archived-task", "b", "--archived-session", "c", "--purge-after-hours", "48", "--json"])
        #expect(command.archivedTask == ["a", "b"])
        #expect(command.archivedSession == ["c"])
        #expect(command.purgeAfterHours == 48)
        #expect(command.json)
    }
}
