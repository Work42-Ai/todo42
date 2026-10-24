// PlannedDay.swift — the structured "Overview" artifact: a per-workspace,
// once-per-day time-blocked day plan the daily-planning routine writes
// and the Today page renders natively as the "<date> Overview" widget.
//
// This file owns the storage CONTRACT only — the Codable shape and schema
// validation. The on-disk store (a per-workspace SQLite `store.db`,
// modeled on meet42's `MeetProjectStore`) lives in
// `Flow42Core/PlannedDay/PlannedDayStore.swift`. The `todo42 planned-day`
// CLI and the app's Overview widget are built on top of these and never
// reach around them (the hard repo rule: CLI and app talk only via the
// store).
//
// The plan is **time-blocked**: it carries a `dayStructure` and an ordered
// `blocks` array of timed work-blocks (task / prReview / calendar /
// break). It is work42's OWN inner day plan — it NEVER writes to the user's
// real/external calendar (meet42 stays read-only there), and there is no
// draft → approve → scheduled lifecycle (nothing to approve). One record per
// calendar day, **per workspace**, retained forever.
//
// **Blocks-only artifact.** The `planned-day set` artifact carries only
// day-level fields (`date`, `generatedAt`, `source`, `sessionId`, `summary`,
// `dayStructure`) plus an optional `blocks` array. `focusTasks`
// and `prReviews` are **NOT** artifact inputs — they are **read-time
// projections** the store derives from the `planned_blocks` table (task
// blocks → focusTasks, prReview blocks → prReviews). These properties on
// this struct are populated by the store after reading; they are never
// decoded from or encoded to the artifact JSON.
//
// The `focusTasks`/`prReviews` **properties** are kept on the
// struct (the widget and CLI `show` still read them). The legacy single
// `focusTask`/`focusReason` read-only accessors are also kept so existing
// readers compile unchanged.

import Foundation

// MARK: - Model

/// The structured "Overview" briefing for a single calendar day in a
/// single workspace.
public nonisolated struct PlannedDay: Codable, Equatable, Sendable {

    /// How this plan was produced.
    public enum Source: String, Codable, Equatable, Sendable {
        /// Written by the daily-planning schedule's automatic fire.
        case scheduled
        /// Written by an on-demand "Plan my day now" / manual run.
        case manual
    }

    /// The calendar day this briefing is for, `YYYY-MM-DD`.
    public var date: String

    /// When the artifact was generated, ISO8601 (e.g. the routine's run
    /// time). Informational; the widget may surface it as a "generated at".
    public var generatedAt: String

    /// How the plan was produced — `scheduled` (the daily routine fired)
    /// or `manual` (an on-demand run). Defaults to `scheduled` when the
    /// writer omits it.
    public var source: Source

    /// The id of the planning session that produced this record (so the
    /// Overview's "View planning session" button can open it). Optional.
    public var sessionId: String?

    /// The AI-written hero line shown at the top of the Overview. Optional
    /// — when absent the app composes a line from `focusTasks`/`prReviews`.
    public var summary: String?

    /// The day's To-Dos — the generic, persistent items scheduled/due that
    /// day. This is a READ-TIME PROJECTION the store populates from the `todos`
    /// collection (via `listTodos(date:)`); it is NOT decoded from or encoded
    /// to the day-level artifact JSON (the artifact is summary + dayStructure
    /// only). Empty when the day has no To-Dos. The Overview renders these as a
    /// checklist; the timeline renders each timed slot + each all-day item.
    public var todos: [Todo]

    /// The agent-authored day-structure breakdown (category→duration in
    /// minutes) the Overview widget's donut renders verbatim. OPTIONAL —
    /// absent means the planning agent didn't author one (the donut then has
    /// nothing to render). The app NEVER computes this itself.
    public var dayStructure: DayStructure?

    public init(
        date: String,
        generatedAt: String,
        source: Source = .scheduled,
        sessionId: String? = nil,
        summary: String? = nil,
        todos: [Todo] = [],
        dayStructure: DayStructure? = nil
    ) {
        self.date = date
        self.generatedAt = generatedAt
        self.source = source
        self.sessionId = sessionId
        self.summary = summary
        self.todos = todos
        self.dayStructure = dayStructure
    }

    /// `source` defaults to `.scheduled` when the writer omits it, so an
    /// older / minimal artifact still decodes.
    ///
    /// **Blocks-only artifact:** `focusTasks` and `prReviews` are NOT decoded
    /// from the artifact — they are set to `nil`/`[]` and populated by the
    /// store's read-time projection from `planned_blocks`. Any `focusTasks`,
    /// `prReviews`, `focusTask`, or `focusReason` keys present in the artifact
    /// JSON are silently ignored.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.date = try c.decode(String.self, forKey: .date)
        self.generatedAt = try c.decode(String.self, forKey: .generatedAt)
        self.source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .scheduled
        self.sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary)
        // `todos` is NOT decoded from the artifact — it is a read-time
        // projection from the `todos` collection (populated by the store).
        self.todos = []
        self.dayStructure = try c.decodeIfPresent(DayStructure.self, forKey: .dayStructure)
    }

    /// Encode the day. Only day-level fields are emitted (`date`, `generatedAt`,
    /// `source`, `sessionId`, `summary`, `dayStructure`). `focusTasks` and
    /// `prReviews` are NOT emitted — they are read-time projections, not
    /// artifact fields.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(dayStructure, forKey: .dayStructure)
    }

    /// Artifact keys — day-level fields only. `focusTasks` and `prReviews`
    /// are read-time projections from `planned_blocks` and are not in the
    /// artifact.
    enum CodingKeys: String, CodingKey {
        case date, generatedAt, source, sessionId, summary, dayStructure
    }

}

// MARK: - Validation

extension PlannedDay {

    /// A human-readable schema-validation failure. Nonisolated so the CLI
    /// and the nonisolated store can call it off the main actor. The CLI prints
    /// `message` + `suggestion` and exits non-zero — never a stack trace.
    public struct ValidationError: Error, Equatable {
        public let message: String
        public let suggestion: String
    }

    /// Validate the decoded artifact against the schema's semantic rules
    /// (Codable already enforced the shape + required keys). Throws a
    /// `ValidationError` with an actionable message on the first problem.
    /// Only validates day-level fields — block-level validation lives in
    /// `PlannedBlock.validate()`. `focusTasks`/`prReviews` are NOT validated
    /// here (they are read-time projections, not artifact inputs).
    public nonisolated func validate() throws {
        // date — YYYY-MM-DD.
        guard Self.isValidDate(date) else {
            throw ValidationError(
                message: "\"date\" must be a calendar day in YYYY-MM-DD form (got \"\(date)\").",
                suggestion: "Set \"date\" to e.g. \"2026-06-06\"."
            )
        }
        // generatedAt — must parse as ISO8601.
        guard Self.isValidISO8601(generatedAt) else {
            throw ValidationError(
                message: "\"generatedAt\" must be an ISO8601 timestamp (got \"\(generatedAt)\").",
                suggestion: "Set \"generatedAt\" to e.g. \"2026-06-06T08:00:00Z\"."
            )
        }
        // dayStructure — when the agent authored one, every category
        // duration must be non-negative.
        try dayStructure?.validate()
    }

    /// `true` iff `s` is a real calendar date in `YYYY-MM-DD` form.
    nonisolated static func isValidDate(_ s: String) -> Bool {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: s) != nil
    }

    /// `true` iff `s` parses as an ISO8601 timestamp (with or without
    /// fractional seconds).
    nonisolated static func isValidISO8601(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let iso = ISO8601DateFormatter()
        if iso.date(from: trimmed) != nil { return true }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: trimmed) != nil
    }
}

// MARK: - Decode helper

extension PlannedDay {

    /// Today's date in `YYYY-MM-DD` (local calendar). Shared by the store
    /// and any caller that needs the day key.
    public static func todayString() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    /// Decode + validate raw JSON bytes into a `PlannedDay`, mapping decode
    /// failures to a human-readable `PlannedDay.ValidationError` (so the CLI
    /// never leaks a stack trace). Does NOT persist.
    public static func decodeAndValidate(_ data: Data) throws -> PlannedDay {
        let day: PlannedDay
        do {
            day = try JSONDecoder().decode(PlannedDay.self, from: data)
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw PlannedDay.ValidationError(
                message: "missing required field \"\(key.stringValue)\"\(context(ctx)).",
                suggestion: "The artifact needs top-level \"date\" + \"generatedAt\"; "
                    + "optional \"source\" (scheduled|manual), \"sessionId\", \"summary\", "
                    + "\"dayStructure\", and \"blocks\" (array of block objects). "
                    + "\"focusTasks\" and \"prReviews\" are NOT artifact "
                    + "fields — they are derived from planned_blocks at read time."
            )
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw PlannedDay.ValidationError(
                message: "wrong type for a field\(context(ctx)).",
                suggestion: "Check the field types: \"date\" is YYYY-MM-DD, "
                    + "\"generatedAt\" is ISO8601, \"source\" is scheduled|manual, "
                    + "\"blocks\" is an array of block objects."
            )
        } catch let DecodingError.valueNotFound(_, ctx) {
            throw PlannedDay.ValidationError(
                message: "null value for a required field\(context(ctx)).",
                suggestion: "Required fields (\"date\", \"generatedAt\") must be present and non-null."
            )
        } catch let DecodingError.dataCorrupted(ctx) {
            // Includes invalid JSON.
            throw PlannedDay.ValidationError(
                message: "the input is not valid PlannedDay JSON\(context(ctx)): \(ctx.debugDescription)",
                suggestion: "Ensure valid JSON matching the PlannedDay schema "
                    + "(date, generatedAt, and optional source/sessionId/summary/dayStructure/blocks)."
            )
        }
        try day.validate()
        return day
    }

    /// Render a coding path like " at prs[0].url" for an error message, or
    /// "" when the path is empty.
    private static func context(_ ctx: DecodingError.Context) -> String {
        guard !ctx.codingPath.isEmpty else { return "" }
        var out = ""
        for key in ctx.codingPath {
            if let idx = key.intValue {
                out += "[\(idx)]"
            } else {
                out += out.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return out.isEmpty ? "" : " at \(out)"
    }
}
