// DayStructureTests.swift — the stored day-structure model (T-005.7, moved from Work42 in WOR-382).
//
// The agent authors five category MINUTE totals and persists them on the day's `PlannedDay`. These tests
// cover the derived totals the Overview headline uses. How a surface turns them into donut segments and
// "5.5h" labels belongs to the Work42 plugin's widget, which links only the SDK and has no test target.

import Foundation
import Todo42Core
import Testing

@Suite("DayStructure totals")
struct DayStructureTests {

    @Test("workMinutes = Focus + Reviews + Meetings")
    func workIsFocusPlusReviewsPlusMeetings() {
        let structure = DayStructure(focus: 180, reviews: 60, meetings: 90, personal: 480, free: 630)
        // Focus (180) + Reviews (60) + Meetings (90) = 330; Personal and Free are excluded.
        #expect(structure.workMinutes == 330)
    }

    @Test("workMinutes excludes personal and free")
    func workExcludesNonWork() {
        // No work-related blocks, but the day is otherwise full -> 0 work.
        let structure = DayStructure(focus: 0, reviews: 0, meetings: 0, personal: 600, free: 840)
        #expect(structure.workMinutes == 0)
    }

    @Test("plannedMinutes is every category but Free")
    func plannedExcludesFree() {
        let structure = DayStructure(focus: 120, reviews: 60, meetings: 60, personal: 0, free: 300)
        // 120 + 60 + 60 + 0 = 240 planned; Free (300) excluded.
        #expect(structure.plannedMinutes == 240)
    }

    @Test("an empty structure is all zero")
    func emptyIsZero() {
        let structure = DayStructure()
        #expect(structure.workMinutes == 0)
        #expect(structure.plannedMinutes == 0)
    }
}
