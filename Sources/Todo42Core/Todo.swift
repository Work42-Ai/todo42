// Todo.swift — the generic, persistent To-Do that replaces the typed
// `PlannedBlock` (feat/planning-generic-block-events-instead-of-first).
//
// A To-Do is the single internal "thing you need to do": a title, an optional
// link, and an explicit completion tick. It is **TIMELESS** — one flat
// collection in the per-workspace `store.db`, its identity independent of any
// day. It persists until completed, soft-archived, or removed.
//
// Scheduling is metadata ON the timeless item, NOT day-ownership:
//   - `slots` — the time windows I INTEND TO WORK on it. A slot means "work
//               on this then," never "this To-Do belongs to that day." A slot
//               carries its own datetime, so "which To-Dos are for today" is
//               DERIVED (the ones with a slot today) — never stored. A To-Do
//               worked across two days simply has two slots on different days
//               and shows up in both days' Overview; empty ⇒ unscheduled.
//   - `dueDate` — a DEADLINE (`YYYY-MM-DD`): finish it before this day. An
//               independent axis from `slots`; optional. Neither set ⇒ a plain
//               backlog item.
//
// The link (`url`) carries all behavior. An internal `work42://` deep link
// (`task/<id>`, `code-review?pr=<url>`, `session/<id>`) resolves to an in-app
// surface; an `https://` link opens externally; nil is a plain reminder. The
// item's *nature* (glyph, Overview bucket) is a COMPUTED `derivedKind` off the
// url — nothing is stored for it.
//
// Completion is a stored `completedAt` on the whole To-Do, asserted explicitly
// (user checkbox / `work42 todos complete <id>`) or by the session↔To-Do link
// (a completed task/review scratches its To-Do) — never inferred ad-hoc from a
// linked task's status on read.
//
// Archive lifecycle: `archivedAt` is a SYSTEM-STAMPED soft-archive timestamp
// (ISO8601). A linked session/task being archived stamps the To-Do via the
// resolve-on-read hook (`PlannedDayStore.listTodos` + `TodoSessionArchiveResolving`)
// rather than eager delete. Soft-archived To-Dos are excluded from default list
// results and purged after the workspace's auto-archive window. Hard-delete
// (`work42 todos remove`) still exists for explicit removal.
//
// This file owns the storage CONTRACT only — the Codable shape + schema
// validation. The on-disk `todos` + `todo_slots` tables and the read/write API
// live in `Flow42Core/PlannedDay/PlannedDayStore.swift`, exactly as
// `PlannedBlock`/`PlannedDay` do. It reuses `PlannedDay.ValidationError` +
// `PlannedDay.isValidISO8601` so the CLI prints `message` + `suggestion` and
// exits non-zero, never a stack trace.

import Foundation

// MARK: - Slot

/// One committed time window on a `Todo` — an ISO8601 `start`/`end` pair with
/// `end` strictly after `start`. Renders as a single block on the calendar.
public nonisolated struct TodoSlot: Codable, Equatable, Sendable {

    /// The slot's start, ISO8601 (e.g. "2026-06-06T09:00:00Z").
    public var start: String

    /// The slot's end, ISO8601. Must be strictly after `start`.
    public var end: String

    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }

    enum CodingKeys: String, CodingKey {
        case start, end
    }
}

// MARK: - DerivedKind

/// The COMPUTED nature of a To-Do, derived from its `url` — never stored.
/// Drives the glyph a surface shows and the Overview bucket it counts under.
public nonisolated enum TodoDerivedKind: String, Equatable, Sendable {
    /// `work42://task/<id>` — an ongoing task42 task.
    case task
    /// `work42://code-review?pr=<url>` — a PR to review.
    case review
    /// `work42://session/<id>` — an existing session.
    case session
    /// Any non-`work42` link (`https://…`) — an external thing.
    case link
    /// No link — a plain reminder.
    case todo

    /// Derive the kind from a To-Do's optional `url`. Scheme + first path
    /// segment decide it; anything unrecognized with a scheme is `.link`, and
    /// a nil/empty url is `.todo`.
    public init(from url: String?) {
        guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            self = .todo
            return
        }
        guard let parsed = URLComponents(string: raw),
              let scheme = parsed.scheme?.lowercased() else {
            // Unparseable but non-empty — treat as an external link.
            self = .link
            return
        }
        guard scheme == "work42" else {
            self = .link
            return
        }
        // work42://<host>/<path…> — the host is the first segment
        // ("task", "code-review", "session").
        switch parsed.host?.lowercased() {
        case "task": self = .task
        case "code-review": self = .review
        case "session": self = .session
        default: self = .link
        }
    }
}

public extension TodoDerivedKind {
    /// The SF Symbol a surface shows for this kind when it knows nothing more about the link. Work42 shows
    /// the icon of the linked session's own type instead where it can resolve one (the plugin does, through
    /// its `work42-session` tools); these are the built-in task, code-review and chat icons.
    var defaultGlyphSymbol: String {
        switch self {
        case .task: return "checklist"
        case .review: return "checkmark.shield"
        case .session: return "bubble.left"
        case .link: return "link"
        case .todo: return "circle.dashed"
        }
    }
}

// MARK: - Todo

/// One generic, persistent To-Do in a workspace's `todos` collection. Not
/// scoped to a day; owns zero or more `slots`; completion is stored on the
/// whole item.
public nonisolated struct Todo: Codable, Equatable, Sendable {

    /// Stable, generated id — addressable across days (e.g. for
    /// `work42 todos complete <id>`).
    public var id: String

    /// The human label shown on the To-Do (non-empty).
    public var title: String

    /// Intended work windows — zero or more. Each carries its own datetime and
    /// renders as one calendar block; a To-Do can occupy several stretches in a
    /// day or across days. Empty ⇒ unscheduled (does NOT put it "on" any day).
    public var slots: [TodoSlot]

    /// Optional DEADLINE (`YYYY-MM-DD`) — finish the To-Do before this day. An
    /// independent axis from `slots`; nil ⇒ no deadline.
    public var dueDate: String?

    /// The optional link that carries the To-Do's behavior — a `work42://`
    /// deep link, an `https://` URL, or nil (a plain reminder).
    public var url: String?

    /// An optional one-clause explanation for why this To-Do exists / is scheduled.
    public var reason: String?

    /// When the To-Do was ticked complete, ISO8601; nil ⇒ open. Set/cleared
    /// explicitly (user or agent, or the session↔To-Do link on completion).
    public var completedAt: String?

    /// When the To-Do was soft-archived, ISO8601; nil ⇒ not archived.
    /// System-stamped by the resolve-on-read hook when the linked session/task
    /// is archived — never set by user input or validation. Soft-archived
    /// To-Dos are excluded from default list results and purged after the
    /// workspace's auto-archive window.
    public var archivedAt: String?

    public init(
        id: String,
        title: String,
        slots: [TodoSlot] = [],
        dueDate: String? = nil,
        url: String? = nil,
        reason: String? = nil,
        completedAt: String? = nil,
        archivedAt: String? = nil
    ) {
        self.id = id
        self.title = title
        self.slots = slots
        self.dueDate = dueDate
        self.url = url
        self.reason = reason
        self.completedAt = completedAt
        self.archivedAt = archivedAt
    }

    /// The COMPUTED nature of this To-Do, from its `url`. Never stored.
    public var derivedKind: TodoDerivedKind { TodoDerivedKind(from: url) }

    /// `true` when the To-Do carries at least one committed slot (renders on
    /// the calendar grid).
    public var isTimed: Bool { !slots.isEmpty }

    /// `true` when the To-Do is complete (has a `completedAt`).
    public var isCompleted: Bool { completedAt != nil }

    /// `true` when the To-Do has been soft-archived (has an `archivedAt`).
    public var isArchived: Bool { archivedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id, title, slots, dueDate, url, reason, completedAt, archivedAt
    }
}

// MARK: - Validation

extension Todo {

    /// Validate the To-Do against the schema's semantic rules. Throws the same
    /// `PlannedDay.ValidationError` shape the rest of the store uses. Reuses
    /// `PlannedDay`'s ISO8601 + date helpers.
    public nonisolated func validate() throws {
        // title — non-empty.
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlannedDay.ValidationError(
                message: "\"title\" must not be empty.",
                suggestion: "Give the To-Do a label, e.g. \"Land T-003\"."
            )
        }

        // Each slot must have valid, strictly-ordered timestamps.
        for (index, slot) in slots.enumerated() {
            try slot.validate(index: index)
        }

        // dueDate — when present, must be a real calendar day.
        if let dueDate, !PlannedDay.isValidDate(dueDate) {
            throw PlannedDay.ValidationError(
                message: "\"dueDate\" must be a calendar day in YYYY-MM-DD form (got \"\(dueDate)\").",
                suggestion: "Set \"dueDate\" to e.g. \"2026-06-06\", or omit it."
            )
        }
    }
}

extension TodoSlot {

    /// Validate one slot: both timestamps parse as ISO8601 and `end` is
    /// strictly after `start`. `index` is the slot's position for an
    /// actionable message.
    public nonisolated func validate(index: Int) throws {
        guard PlannedDay.isValidISO8601(start) else {
            throw PlannedDay.ValidationError(
                message: "slots[\(index)].start must be an ISO8601 timestamp (got \"\(start)\").",
                suggestion: "Set it to e.g. \"2026-06-06T09:00:00Z\"."
            )
        }
        guard PlannedDay.isValidISO8601(end) else {
            throw PlannedDay.ValidationError(
                message: "slots[\(index)].end must be an ISO8601 timestamp (got \"\(end)\").",
                suggestion: "Set it to e.g. \"2026-06-06T10:00:00Z\"."
            )
        }
        guard let startDate = Self.parseISO8601(start),
              let endDate = Self.parseISO8601(end),
              endDate > startDate else {
            throw PlannedDay.ValidationError(
                message: "slots[\(index)].end must be strictly after start "
                    + "(got start \"\(start)\", end \"\(end)\").",
                suggestion: "Set \"end\" to a timestamp later than \"start\"."
            )
        }
    }

    /// Parse an ISO8601 timestamp (with or without fractional seconds) to a
    /// `Date`, or nil. Mirrors `PlannedDay`'s parsing.
    nonisolated static func parseISO8601(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: trimmed)
    }
}

// MARK: - Decode helper

extension Todo {

    /// Decode + validate raw JSON bytes into a `Todo`, mapping decode failures
    /// to a human-readable `PlannedDay.ValidationError` (so the CLI never leaks
    /// a stack trace). Does NOT persist.
    public static func decodeAndValidate(_ data: Data) throws -> Todo {
        let todo: Todo
        do {
            todo = try JSONDecoder().decode(Todo.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            throw PlannedDay.ValidationError(
                message: "missing required field \"\(key.stringValue)\".",
                suggestion: "A To-Do needs \"id\" and \"title\"; optional "
                    + "\"slots\" (array of {start,end}), \"dueDate\", \"url\", "
                    + "\"reason\", \"completedAt\", \"archivedAt\"."
            )
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw PlannedDay.ValidationError(
                message: "wrong type for a field\(ctx.codingPath.isEmpty ? "" : " at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))").",
                suggestion: "\"slots\" is an array of {start,end} strings; "
                    + "\"id\"/\"title\"/\"dueDate\"/\"url\"/\"reason\"/\"completedAt\"/\"archivedAt\" are strings."
            )
        } catch let DecodingError.dataCorrupted(ctx) {
            throw PlannedDay.ValidationError(
                message: "the input is not valid Todo JSON: \(ctx.debugDescription)",
                suggestion: "Ensure valid JSON matching the Todo schema "
                    + "({id, title, slots, dueDate, url, reason, completedAt, archivedAt})."
            )
        }
        try todo.validate()
        return todo
    }
}
