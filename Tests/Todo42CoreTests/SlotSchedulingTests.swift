// SlotSchedulingTests.swift — feat/planning-generic-block-events-instead-of-first.31.
//
// The manual-scheduling seam: PlannedDayStore.insertSlot / updateSlot /
// removeSlot — single-slot edits that persist through updateTodo. Asserted on
// the stored `Todo.slots` directly (the Todo → calendar-item projection that
// these once round-tripped through was removed with the calendar vertical).

import Foundation
import Testing
@testable import Todo42Core

@Suite("PlannedDayStore — slot scheduling")
@MainActor
struct PlannedDayStoreSlotTests {

    private func store() throws -> PlannedDayStore {
        let tmp = NSTemporaryDirectory() + "slot-\(UUID().uuidString)"
        return try PlannedDayStore(slug: "ws", baseDirOverride: tmp)
    }
    private let base = Date(timeIntervalSince1970: 1_800_000_000)  // fixed, deterministic
    private func at(_ minutes: Int) -> Date { base.addingTimeInterval(Double(minutes) * 60) }

    /// Parses a stored slot timestamp (the store writes fractional-second ISO8601).
    private func date(_ iso: String) throws -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return try #require(f.date(from: iso))
    }
    private func expectSlot(_ slot: TodoSlot, from start: Date, to end: Date) throws {
        #expect(abs(try date(slot.start).timeIntervalSince(start)) < 1)
        #expect(abs(try date(slot.end).timeIntervalSince(end)) < 1)
    }

    @Test("insertSlot appends (multiple slots per To-Do) with the right times")
    func insert() throws {
        let s = try store()
        try s.addTodo(Todo(id: "t", title: "Land it", url: "work42://task/feat/x"))

        #expect(try s.insertSlot(todoId: "t", start: at(0), end: at(45)) == true)
        #expect(try s.insertSlot(todoId: "t", start: at(120), end: at(180)) == true)
        let todo = try #require(try s.todo(id: "t"))
        #expect(todo.slots.count == 2)

        try expectSlot(todo.slots[0], from: at(0), to: at(45))
        try expectSlot(todo.slots[1], from: at(120), to: at(180))

        // Unknown id → false, no throw.
        #expect(try s.insertSlot(todoId: "nope", start: at(0), end: at(30)) == false)
    }

    @Test("updateSlot replaces a slot (move/resize); out-of-range + unknown → false")
    func update() throws {
        let s = try store()
        try s.addTodo(Todo(id: "t", title: "x"))
        try s.insertSlot(todoId: "t", start: at(0), end: at(45))

        #expect(try s.updateSlot(todoId: "t", index: 0, start: at(60), end: at(90)) == true)
        let todo = try #require(try s.todo(id: "t"))
        #expect(todo.slots.count == 1)
        try expectSlot(todo.slots[0], from: at(60), to: at(90))

        #expect(try s.updateSlot(todoId: "t", index: 5, start: at(0), end: at(30)) == false)
        #expect(try s.updateSlot(todoId: "nope", index: 0, start: at(0), end: at(30)) == false)
    }

    @Test("removeSlot deletes one slot; out-of-range + unknown → false")
    func remove() throws {
        let s = try store()
        try s.addTodo(Todo(id: "t", title: "x"))
        try s.insertSlot(todoId: "t", start: at(0), end: at(45))
        try s.insertSlot(todoId: "t", start: at(120), end: at(180))

        #expect(try s.removeSlot(todoId: "t", index: 0) == true)
        var todo = try #require(try s.todo(id: "t"))
        #expect(todo.slots.count == 1)
        // The surviving slot is the second one (120–180).
        try expectSlot(todo.slots[0], from: at(120), to: at(180))

        #expect(try s.removeSlot(todoId: "t", index: 9) == false)
        #expect(try s.removeSlot(todoId: "nope", index: 0) == false)

        #expect(try s.removeSlot(todoId: "t", index: 0) == true)
        todo = try #require(try s.todo(id: "t"))
        #expect(todo.slots.isEmpty)
    }
}
