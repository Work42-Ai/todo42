// DayStructure.swift — the agent-authored day-structure breakdown for a
// single day (T-005). The day-structure DONUT in the Overview (Today) widget
// renders exactly these stored values: the breakdown is **authored by the
// planning agent and persisted on the day's artifact; the donut is a dumb
// renderer** (the same "agent writes, app reads" rule as the rest of the
// Today page — the app must NOT sum raw calendar-event durations to compute
// "Meetings", because events ≠ meetings).
//
// The shape is five named category durations in **minutes** (Int,
// non-negative), each defaulting to 0 so the donut maps category→color
// deterministically and the JSON an agent emits is obvious:
//
//   { "focus": 180, "reviews": 60, "meetings": 90, "personal": 30, "free": 360 }
//
//   - `focus`    — task-work minutes (the agent's scheduled task blocks).
//   - `reviews`  — PR-review minutes (the agent's scheduled review blocks).
//   - `meetings` — minutes on a WORK calendar (events ≠ meetings unless the
//                  agent classifies them so; unknown calendars default to
//                  work / meetings).
//   - `personal` — minutes on the user's PERSONAL calendar.
//   - `free`     — the day window minus everything else.
//
// This is a SIBLING contract to `PlannedDay` and `Todo`. It attaches
// to `PlannedDay` as an OPTIONAL `dayStructure` (absent = the agent didn't
// author one) and shares the same validation conventions
// (`PlannedDay.ValidationError`). The on-disk store + CLI round-trip live in
// `Flow42Core/PlannedDay/PlannedDayStore.swift` and the `todo42 planned-day`
// CLI — the CLI and app talk only via the store.

import Foundation

// MARK: - Model

/// The agent-authored day-structure breakdown — five category durations in
/// minutes — persisted on a `PlannedDay` and rendered verbatim by the
/// Overview widget's day-structure donut.
public nonisolated struct DayStructure: Codable, Equatable, Sendable {

    /// Task-work minutes (the agent's scheduled task blocks). Non-negative.
    public var focus: Int

    /// PR-review minutes (the agent's scheduled review blocks). Non-negative.
    public var reviews: Int

    /// Minutes on a WORK calendar — the donut's "Meetings" wedge.
    /// Non-negative.
    public var meetings: Int

    /// Minutes on the user's PERSONAL calendar. Non-negative.
    public var personal: Int

    /// Free minutes — the day window minus everything else. Non-negative.
    public var free: Int

    public init(
        focus: Int = 0,
        reviews: Int = 0,
        meetings: Int = 0,
        personal: Int = 0,
        free: Int = 0
    ) {
        self.focus = focus
        self.reviews = reviews
        self.meetings = meetings
        self.personal = personal
        self.free = free
    }

    /// Every category defaults to 0 when the writer omits it, so a partial
    /// breakdown (e.g. only `focus` + `free`) still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.focus = try c.decodeIfPresent(Int.self, forKey: .focus) ?? 0
        self.reviews = try c.decodeIfPresent(Int.self, forKey: .reviews) ?? 0
        self.meetings = try c.decodeIfPresent(Int.self, forKey: .meetings) ?? 0
        self.personal = try c.decodeIfPresent(Int.self, forKey: .personal) ?? 0
        self.free = try c.decodeIfPresent(Int.self, forKey: .free) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case focus, reviews, meetings, personal, free
    }

    /// Total minutes across all five categories (including `free`) — the
    /// full day window the breakdown covers.
    public var totalMinutes: Int {
        focus + reviews + meetings + personal + free
    }

    /// The PLANNED minutes — everything but `free`.
    public var plannedMinutes: Int {
        focus + reviews + meetings + personal
    }

    /// The user's actual WORK-related minutes — `focus` (task work) +
    /// `reviews` (PR review) + `meetings` (work-calendar time). `personal`
    /// and `free` are excluded. The donut's center label ("Xh work") is
    /// derived from this: on a full 24h day the all-but-free total would be
    /// a meaningless ~20h, so the headline number is the user's real
    /// work-related time instead.
    public var workMinutes: Int {
        focus + reviews + meetings
    }
}

// MARK: - Validation

extension DayStructure {

    /// Validate the breakdown against the schema's semantic rules: every
    /// category duration must be non-negative. Throws the same
    /// `PlannedDay.ValidationError` shape the rest of the store uses (so the
    /// CLI prints `message` + `suggestion` and exits non-zero, never a
    /// stack trace).
    public nonisolated func validate() throws {
        let fields: [(String, Int)] = [
            ("focus", focus),
            ("reviews", reviews),
            ("meetings", meetings),
            ("personal", personal),
            ("free", free),
        ]
        for (name, value) in fields where value < 0 {
            throw PlannedDay.ValidationError(
                message: "dayStructure.\(name) must be a non-negative number of minutes (got \(value)).",
                suggestion: "Use minutes ≥ 0 for each category "
                    + "(focus, reviews, meetings, personal, free)."
            )
        }
    }
}
