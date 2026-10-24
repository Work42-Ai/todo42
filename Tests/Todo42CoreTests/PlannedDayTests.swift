// PlannedDayTests.swift — the day-level `PlannedDay` artifact + the
// per-workspace `PlannedDayStore` (day-level fields only). The schedule itself
// (the generic To-Do collection + the planned_blocks → todos migration) is
// covered by TodoTests; here we cover:
//   - decode + validate of the day-level artifact (summary / source / sessionId
//     / dayStructure), including that unknown/legacy keys are ignored,
//   - rejection of malformed input (bad JSON, missing fields, bad date/generatedAt),
//   - the per-workspace store round-trip (upsert → read → latest → listDates →
//     clear), keyed by date and retained,
//   - `read`/`latest` populating `todos` from the To-Do collection,
//   - the dayStructure decode / validate / store round-trip / ALTER migration.
//
// Uses a temp-dir `baseDirOverride` so store tests never touch a real workspace.

import Foundation
import SQLite3
import Testing
@testable import Todo42Core

@Suite("PlannedDay model + store")
struct PlannedDayTests {

    private func tempDir() -> String {
        let dir = NSTemporaryDirectory() + "planned-day-test-\(UUID().uuidString)"
        return dir
    }

    // MARK: decode + validate

    @Test("a fully-formed day-level artifact decodes and validates")
    func validArtifactDecodes() throws {
        let json = """
        {
          "date": "2026-06-06",
          "generatedAt": "2026-06-06T08:00:00Z",
          "source": "scheduled",
          "sessionId": "sess-abc",
          "summary": "Two focus stretches and a review today."
        }
        """
        let day = try PlannedDay.decodeAndValidate(Data(json.utf8))
        #expect(day.date == "2026-06-06")
        #expect(day.source == .scheduled)
        #expect(day.sessionId == "sess-abc")
        #expect(day.todos.isEmpty)  // a read-time projection, not an artifact input
    }

    @Test("unknown/legacy artifact keys (blocks/focusTasks/prReviews) are ignored")
    func legacyKeysIgnored() throws {
        let json = """
        {
          "date": "2026-06-06", "generatedAt": "2026-06-06T08:00:00Z",
          "focusTasks": [ { "id": "T-003" } ],
          "prReviews": [ { "prURL": "https://github.com/o/r/pull/42" } ],
          "blocks": [ { "kind": "task", "ref": "T-003" } ]
        }
        """
        let day = try PlannedDay.decodeAndValidate(Data(json.utf8))
        #expect(day.todos.isEmpty)  // none of those keys are decoded anymore
    }

    @Test("a minimal artifact validates")
    func minimalArtifactValidates() throws {
        let json = """
        { "date": "2026-01-01", "generatedAt": "2026-01-01T00:00:00Z" }
        """
        let day = try PlannedDay.decodeAndValidate(Data(json.utf8))
        #expect(day.source == .scheduled)
        #expect(day.todos.isEmpty)
    }

    @Test("invalid JSON is rejected with a ValidationError")
    func invalidJSONRejected() {
        #expect(throws: PlannedDay.ValidationError.self) {
            _ = try PlannedDay.decodeAndValidate(Data("{ not json".utf8))
        }
    }

    @Test("a missing required field is rejected")
    func missingFieldRejected() {
        #expect(throws: PlannedDay.ValidationError.self) {
            _ = try PlannedDay.decodeAndValidate(Data("{ \"date\": \"2026-06-06\" }".utf8))
        }
    }

    @Test("a bad date / non-ISO8601 generatedAt is rejected")
    func badDateOrGeneratedAtRejected() {
        #expect(throws: PlannedDay.ValidationError.self) {
            _ = try PlannedDay.decodeAndValidate(Data(
                "{ \"date\": \"2026-13-99\", \"generatedAt\": \"2026-06-06T08:00:00Z\" }".utf8))
        }
        #expect(throws: PlannedDay.ValidationError.self) {
            _ = try PlannedDay.decodeAndValidate(Data(
                "{ \"date\": \"2026-06-06\", \"generatedAt\": \"nope\" }".utf8))
        }
    }

    // MARK: store round-trip (day-level)

    @MainActor
    @Test("upsert → read → latest → listDates → clear round-trips (day-level fields)")
    func storeRoundTrips() throws {
        let tmp = tempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let store = try PlannedDayStore(slug: "test-ws", baseDirOverride: tmp)

        let day = PlannedDay(
            date: "2026-06-06", generatedAt: "2026-06-06T08:00:00Z",
            source: .manual, sessionId: "sess-xyz", summary: "Focus + a review."
        )
        try store.upsert(day)
        let readBack = try store.read(date: "2026-06-06")
        #expect(readBack?.date == "2026-06-06")
        #expect(readBack?.source == .manual)
        #expect(readBack?.sessionId == "sess-xyz")
        #expect(readBack?.summary == "Focus + a review.")
        #expect(readBack?.todos.isEmpty == true)  // no To-Dos scheduled that day

        let older = PlannedDay(date: "2026-06-01", generatedAt: "2026-06-01T08:00:00Z")
        try store.upsert(older)
        #expect(try store.latest()?.date == "2026-06-06")
        #expect(try store.listDates() == ["2026-06-06", "2026-06-01"])

        #expect(try store.clear(date: "2026-06-06") == true)
        #expect(try store.read(date: "2026-06-06") == nil)
        #expect(try store.clear(date: "2026-06-06") == false)
        #expect(try store.listDates() == ["2026-06-01"])
    }

    @MainActor
    @Test("upsert rejects an invalid artifact before touching the store")
    func upsertValidatesFirst() throws {
        let tmp = tempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let store = try PlannedDayStore(slug: "test-ws", baseDirOverride: tmp)
        #expect(throws: PlannedDay.ValidationError.self) {
            try store.upsert(PlannedDay(date: "nope", generatedAt: "2026-06-06T08:00:00Z"))
        }
    }

    @MainActor
    @Test("read / latest populate `todos` from the To-Do collection for that date")
    func readPopulatesTodos() throws {
        let tmp = tempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let store = try PlannedDayStore(slug: "test-ws", baseDirOverride: tmp)
        try store.upsert(PlannedDay(date: "2026-06-06", generatedAt: "2026-06-06T08:00:00Z"))
        try store.addTodo(Todo(
            id: "t1", title: "Land T-003",
            slots: [TodoSlot(start: "2026-06-06T09:00:00Z", end: "2026-06-06T11:00:00Z")],
            url: "work42://task/T-003"
        ))
        let read = try #require(try store.read(date: "2026-06-06"))
        #expect(read.todos.map(\.id) == ["t1"])
        let latest = try #require(try store.latest())
        #expect(latest.todos.map(\.id) == ["t1"])
    }

    // MARK: dayStructure

    @Test("a fully-formed dayStructure decodes with all five categories")
    func dayStructureDecodes() throws {
        let json = """
        { "date": "2026-06-06", "generatedAt": "2026-06-06T08:00:00Z",
          "dayStructure": { "focus": 180, "reviews": 60, "meetings": 90, "personal": 30, "free": 1080 } }
        """
        let day = try PlannedDay.decodeAndValidate(Data(json.utf8))
        #expect(day.dayStructure?.focus == 180)
        #expect(day.dayStructure?.free == 1080)
    }

    @Test("a dayStructure with a negative minute count is rejected")
    func dayStructureNegativeRejected() {
        let json = """
        { "date": "2026-06-06", "generatedAt": "2026-06-06T08:00:00Z",
          "dayStructure": { "focus": 60, "meetings": -10 } }
        """
        #expect(throws: PlannedDay.ValidationError.self) {
            _ = try PlannedDay.decodeAndValidate(Data(json.utf8))
        }
    }

    @MainActor
    @Test("upsert persists a dayStructure that reads back; absent stays nil")
    func dayStructureStoreRoundTrips() throws {
        let tmp = tempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let store = try PlannedDayStore(slug: "test-ws", baseDirOverride: tmp)
        var day = PlannedDay(date: "2026-06-06", generatedAt: "2026-06-06T08:00:00Z")
        day.dayStructure = DayStructure(focus: 120, reviews: 30, meetings: 60, personal: 15, free: 1215)
        try store.upsert(day)
        #expect(try store.read(date: "2026-06-06")?.dayStructure?.focus == 120)

        let bare = PlannedDay(date: "2026-06-07", generatedAt: "2026-06-07T08:00:00Z")
        try store.upsert(bare)
        #expect(try store.read(date: "2026-06-07")?.dayStructure == nil)
    }
}
