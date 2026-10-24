// TodosUpdateClearTests.swift — `todo42 todos update` can clear a field (WOR-382).
//
// Work42's own widget cleared a To-Do's due date, link and slots straight in the store. The plugin's widget
// goes through this CLI, so `update` gained: an empty `--due ""`, `--url ""` or `--reason ""` clears that field,
// and `--no-slots` removes every slot. Not passing an option still keeps the stored value.

import Foundation
import Testing
@testable import todo42

@Suite("todos update: clearing fields")
struct TodosUpdateClearTests {

    @Test("an option that is not passed keeps the stored value")
    func notPassedKeeps() {
        #expect(TodosCommand.revised(nil, keeping: "2026-06-06") == "2026-06-06")
        #expect(TodosCommand.revised(nil, keeping: nil) == nil)
    }

    @Test("an empty or blank value clears the field")
    func emptyClears() {
        #expect(TodosCommand.revised("", keeping: "2026-06-06") == nil)
        #expect(TodosCommand.revised("   ", keeping: "https://example.com") == nil)
    }

    @Test("a value replaces the stored one, trimmed")
    func valueReplaces() {
        #expect(TodosCommand.revised(" 2026-07-01 ", keeping: "2026-06-06") == "2026-07-01")
        #expect(TodosCommand.revised("https://a.example", keeping: nil) == "https://a.example")
    }

    @Test("--no-slots parses, and an empty value is accepted for --due")
    func parsesTheFlags() throws {
        let command = try TodosCommand.UpdateCommand.parse(["abc", "--no-slots", "--due", "", "--url", ""])
        #expect(command.noSlots)
        #expect(command.slot.isEmpty)
        #expect(command.due == "")
        #expect(command.url == "")
    }
}
