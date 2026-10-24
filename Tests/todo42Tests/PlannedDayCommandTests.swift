// PlannedDayCommandTests.swift — the `todo42 planned-day` CLI. The schedule is
// the generic To-Do collection now (see TodosCommandTests + TodoTests); this
// covers the day-level briefing surface:
//   - WORK42_SESSION_ID capture into a session-less artifact,
//   - `set` REJECTS a legacy typed-block artifact (assertNoLegacyBlocks, AC5),
//   - list history ordering + the one-line summary (To-Do count),
//   - malformed input + --date validation,
//   - the `show --json` payload (day-level fields + todos),
//   - dayStructure decode + store round-trip.

import Foundation
import Testing
@testable import todo42
@testable import Todo42Core

@Suite("todo42 planned-day CLI")
struct PlannedDayCommandTests {

    // MARK: helpers

    private func tempDir() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("planned-day-cli-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        return dir
    }

    private func day(
        date: String = "2026-06-06", sessionId: String? = nil,
        source: PlannedDay.Source = .scheduled, summary: String? = "Plan for the day."
    ) -> PlannedDay {
        PlannedDay(date: date, generatedAt: "\(date)T08:00:00Z",
                   source: source, sessionId: sessionId, summary: summary)
    }

    /// A day-level artifact JSON with an optional spliced-in extra field (e.g. a
    /// legacy `blocks` array) — used to test the rejection + dayStructure paths.
    private func artifactJSON(date: String = "2026-06-06", extra: String? = nil) -> Data {
        let extraField = extra.map { ", \($0)" } ?? ""
        return Data("""
        { "date": "\(date)", "generatedAt": "\(date)T08:00:00Z"\(extraField) }
        """.utf8)
    }

    // MARK: WORK42_SESSION_ID capture

    @Test("env WORK42_SESSION_ID is stamped when the artifact omits a sessionId")
    func capturesEnvSessionId() {
        let out = PlannedDayCommand.captureSessionId(
            into: day(sessionId: nil), environment: ["WORK42_SESSION_ID": "sess-xyz"])
        #expect(out.sessionId == "sess-xyz")
    }

    @Test("a sessionId set in the JSON always wins over the env")
    func jsonSessionIdWinsOverEnv() {
        let out = PlannedDayCommand.captureSessionId(
            into: day(sessionId: "from-json"), environment: ["WORK42_SESSION_ID": "from-env"])
        #expect(out.sessionId == "from-json")
    }

    @Test("a blank / absent env value leaves the sessionId nil")
    func blankEnvIgnored() {
        #expect(PlannedDayCommand.captureSessionId(
            into: day(sessionId: nil), environment: ["WORK42_SESSION_ID": "   "]).sessionId == nil)
        #expect(PlannedDayCommand.captureSessionId(
            into: day(sessionId: nil), environment: [:]).sessionId == nil)
    }

    // MARK: set rejects legacy blocks (AC5)

    @Test("assertNoLegacyBlocks rejects a blocks array (and a block-shaped top level)")
    func rejectsLegacyBlocks() {
        #expect(throws: PlannedDayCommand.BlocksParseError.self) {
            try PlannedDayCommand.assertNoLegacyBlocks(
                artifactJSON(extra: "\"blocks\": [{\"kind\":\"task\",\"ref\":\"T-003\"}]"))
        }
        #expect(throws: PlannedDayCommand.BlocksParseError.self) {
            try PlannedDayCommand.assertNoLegacyBlocks(artifactJSON(extra: "\"blocks\": []"))
        }
        let blockShaped = Data("""
        {"kind":"task","ref":"T-003","date":"2026-06-06","generatedAt":"2026-06-06T08:00:00Z"}
        """.utf8)
        #expect(throws: PlannedDayCommand.BlocksParseError.self) {
            try PlannedDayCommand.assertNoLegacyBlocks(blockShaped)
        }
    }

    @Test("assertNoLegacyBlocks accepts a clean day-level artifact")
    func acceptsCleanArtifact() throws {
        try PlannedDayCommand.assertNoLegacyBlocks(artifactJSON())
        try PlannedDayCommand.assertNoLegacyBlocks(
            artifactJSON(extra: "\"dayStructure\": { \"focus\": 120 }"))
    }

    // MARK: list

    @MainActor
    @Test("list returns plan dates newest-first")
    func listHistoryOrdering() throws {
        let store = try PlannedDayStore(slug: "fixture", baseDirOverride: tempDir())
        try store.upsert(day(date: "2026-06-04"))
        try store.upsert(day(date: "2026-06-06"))
        try store.upsert(day(date: "2026-06-05"))
        #expect(try store.listDates() == ["2026-06-06", "2026-06-05", "2026-06-04"])
    }

    @MainActor
    @Test("the one-line list summary carries date · source · N To-Dos")
    func listLineShape() throws {
        let store = try PlannedDayStore(slug: "fixture", baseDirOverride: tempDir())
        try store.upsert(day(date: "2026-06-06", source: .manual))
        try store.addTodo(Todo(id: "t1", title: "A",
                               slots: [TodoSlot(start: "2026-06-06T09:00:00Z", end: "2026-06-06T10:00:00Z")]))
        let withOne = try #require(try store.read(date: "2026-06-06"))
        #expect(PlannedDayCommand.ListCommand.listLine(withOne) == "2026-06-06 · manual · 1 To-Do")

        let none = PlannedDay(date: "2026-06-01", generatedAt: "2026-06-01T08:00:00Z")
        #expect(PlannedDayCommand.ListCommand.listLine(none) == "2026-06-01 · scheduled · 0 To-Dos")
    }

    // MARK: malformed input + --date

    @Test("malformed JSON / bad date is rejected with a ValidationError")
    func malformedRejected() {
        #expect(throws: PlannedDay.ValidationError.self) {
            _ = try PlannedDay.decodeAndValidate(Data("{ not json".utf8))
        }
        #expect(throws: PlannedDay.ValidationError.self) {
            _ = try PlannedDay.decodeAndValidate(artifactJSON(date: "2026-13-99"))
        }
    }

    @Test("resolveDate accepts a valid day and rejects a malformed one")
    func resolveDate() throws {
        #expect(try PlannedDayCommand.resolveDate("2026-06-06") == "2026-06-06")
        #expect(throws: W42ExitError.self) { _ = try PlannedDayCommand.resolveDate("June 6th") }
    }

    // MARK: show --json payload (day-level + todos)

    @Test("the show --json payload flattens day fields and adds a todos array")
    func showJSONPayloadShape() throws {
        var d = day(date: "2026-06-06")
        d.todos = [Todo(id: "t1", title: "Land T-003",
                        slots: [TodoSlot(start: "2026-06-06T09:00:00Z", end: "2026-06-06T11:00:00Z")],
                        url: "work42://task/T-003")]
        let encoded = try JSONEncoder().encode(PlannedDayCommand.ShowCommand.JSONPayload(day: d))
        let obj = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(obj["date"] as? String == "2026-06-06")
        let todos = try #require(obj["todos"] as? [Any])
        #expect(todos.count == 1)
        let first = try #require(todos.first as? [String: Any])
        #expect(first["title"] as? String == "Land T-003")
        #expect(first["url"] as? String == "work42://task/T-003")
        let slots = try #require(first["slots"] as? [Any])
        #expect(slots.count == 1)
    }

    // MARK: dayStructure

    @Test("decodeAndValidate parses a top-level dayStructure; negative rejected")
    func dayStructure() throws {
        let day = try PlannedDay.decodeAndValidate(
            artifactJSON(extra: "\"dayStructure\": { \"focus\": 180, \"reviews\": 60 }"))
        #expect(day.dayStructure?.focus == 180)
        #expect(throws: PlannedDay.ValidationError.self) {
            _ = try PlannedDay.decodeAndValidate(
                artifactJSON(extra: "\"dayStructure\": { \"meetings\": -10 }"))
        }
    }
}
