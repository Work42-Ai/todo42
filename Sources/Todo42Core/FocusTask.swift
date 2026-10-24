// FocusTask.swift — one entry in a day's priority-ordered focus list (T-005).
//
// The day plan supports **multiple focus tasks** — the planning agent selects
// the set of tasks worth the user's time today, most-important-first — instead
// of a single headline task. Each entry is a task42 id plus an optional
// one-clause reason it was chosen. The Overview (Today) widget renders every entry
// as a row in priority order.
//
// This is a SIBLING contract to `PlannedDay.PR`, `PlannedBlock`, and
// `DayStructure`. It attaches to `PlannedDay` as the OPTIONAL `focusTasks` list
// (replacing the legacy single `focusTask`/`focusReason`, with back-compat
// decode), and shares the same validation conventions
// (`PlannedDay.ValidationError`). The on-disk store + CLI round-trip live in
// `Flow42Core/PlannedDay/PlannedDayStore.swift` and the `work42 planned-day`
// CLI — the CLI and app talk only via the store.

import Foundation

// MARK: - Model

/// One focus task in a day's priority-ordered `focusTasks` list — a task42 id
/// (required, non-empty) and an optional one-clause reason it was chosen.
public nonisolated struct FocusTask: Codable, Equatable, Sendable {

    /// The task42 task id, e.g. `"T-003"`. Required, non-empty. The app
    /// resolves it to its real task42 task and renders the same `TaskRow` the
    /// Sessions list uses; an unresolvable id is skipped.
    public var id: String

    /// An optional one-line reason this task was chosen — surfaced as
    /// supporting context beside the focus row.
    public var reason: String?

    public init(id: String, reason: String? = nil) {
        self.id = id
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case id, reason
    }
}

// MARK: - Validation

extension FocusTask {

    /// Validate one focus entry against the schema's semantic rules: the `id`
    /// must be a non-empty task id. Throws the same `PlannedDay.ValidationError`
    /// shape the rest of the store uses (so the CLI prints `message` +
    /// `suggestion` and exits non-zero, never a stack trace). `index` is the
    /// entry's position in the list, for an actionable message.
    public nonisolated func validate(index: Int) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlannedDay.ValidationError(
                message: "focusTasks[\(index)].id must be a non-empty task id.",
                suggestion: "Use a single task42 task id, e.g. \"T-003\", "
                    + "or omit the entry."
            )
        }
    }
}
