// PlannedDayCommand.swift — the `todo42 planned-day` command group.
//
// The daily-planning routine writes a structured "Overview" briefing
// through this CLI; the Today page renders it natively. The artifact is
// **per-workspace** and **retained forever**, stored in the work42
// per-workspace SQLite store (`~/.work42/todo42/projects/<slug>/store.db`,
// table `planned_days`) — NOT the old global JSON. All storage I/O goes
// through Flow42Core's `PlannedDayStore`; the CLI never reaches around it.
//
// Verbs:
//
//   todo42 planned-day set [<file>] [--project <slug|path>] [--json]
//       Read PlannedDay JSON from <file>, or from stdin when no file is
//       given. Validate against the schema; reject malformed input with a
//       clear human-readable error (non-zero exit, no stack trace). Upsert
//       into the resolved workspace's store, keyed by the artifact's `date`.
//       When the env var `WORK42_SESSION_ID` is set and the artifact does
//       NOT already carry a `sessionId`, stamp it in — this links the plan
//       to the planning session that wrote it (the app's "View planning
//       session" button). `source` is honored from the JSON, defaulting to
//       `scheduled`.
//
//       The artifact MAY also carry an OPTIONAL top-level `blocks` array —
//       the day's app-internal scheduled WORK-BLOCKS (T-005). Each block is a
//       `PlannedBlock` in one of two forms:
//         • `{kind: task, ref: <task42-id>, title, start, end}` — focus work.
//         • `{kind: prReview, ref: <GitHub-PR-URL>, title, start, end}` — a
//           "PR awaiting review" item; ref must be an http(s) URL.
//       The blocks travel with the plan and round-trip through `show --json`.
//       Semantics, keyed by the artifact's `date`:
//         • `blocks` ABSENT  → leave the day's existing blocks UNTOUCHED.
//         • `blocks` PRESENT → REPLACE the day's blocks with the array
//                              (an EMPTY array `[]` clears the day's blocks).
//       Each block is validated via `PlannedBlock.validate()`; a bad block
//       (empty title, end ≤ start, a prReview
//       `ref` that is not a URL, …) is rejected with a clear message + non-zero
//       exit, and NOTHING is written (the block write is transactional).
//       Persisted via `PlannedDayStore.setBlocks` — independent of the
//       `PlannedDay` upsert.
//
//       The artifact MAY ALSO carry an OPTIONAL top-level `dayStructure`
//       object (T-005) — the agent-authored day-structure breakdown the
//       Overview widget's donut renders. It is five non-negative minute counts:
//       `{focus, reviews, meetings, personal, free}` (any omitted defaults to
//       0). It travels INSIDE the PlannedDay (a member of the model), so it
//       decodes + validates with the rest of the artifact and persists on the
//       `planned_days` row (column `day_structure_json`). Absent = no donut.
//
//   todo42 planned-day show [--date YYYY-MM-DD] [--json] [--project …]
//       Print the plan for a day (default today) — a human summary by
//       default, raw JSON with --json. A clear message (not an error) when
//       none exists. With `--json` the emitted object ALSO carries the day's
//       `blocks` array (from the schedule store) so the set→show round-trip
//       of work-blocks is observable, plus the day's `dayStructure` object
//       (when the agent authored one) flattened with the PlannedDay fields.
//
//   todo42 planned-day list [--json] [--project …]
//       List stored plan dates (history, newest first) with a one-line
//       summary each: "<date> · <source> · focus <id|—> · N PR reviews".
//
//   todo42 planned-day clear [--date YYYY-MM-DD] [--project …] [--json]
//       Remove the plan for a day (default today) from the workspace store.
//
// Project resolution (every verb): `--project <slug|path>` wins (registry
// slug OR filesystem path); otherwise the cwd is walked up / matched
// against the workspace registry + git-worktree via the shared
// `WorkspaceResolver`. No Personal fallback — when nothing resolves, the
// CLI prints a clear error and exits non-zero.

import ArgumentParser
import Foundation
import Todo42Core

struct PlannedDayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "planned-day",
        abstract: "Write — and read back — the structured \"My Planned Day\" briefing.",
        discussion: """
            A per-workspace, once-per-day time-blocked plan the daily-planning
            routine writes and the Today page renders as the "<date>
            Overview" widget: a hero summary, a `dayStructure`, and an ordered
            `blocks` array of timed work-blocks (task / prReview /
            calendar / break). It is work42's OWN inner day plan — it never
            writes to the user's real/external calendar, and there is nothing
            to approve. Stored in the workspace store and retained forever.
            """,
        subcommands: [
            SetCommand.self,
            ShowCommand.self,
            LastCommand.self,
            ListCommand.self,
            ClearCommand.self,
        ]
    )
}

// MARK: - Workspace resolution + session capture

extension PlannedDayCommand {

    /// The environment key the agent session exports — the planning session
    /// that runs `planned-day set` carries it, and we stamp it into the
    /// record when the artifact doesn't already set a `sessionId`.
    static let sessionEnvKey = "WORK42_SESSION_ID"

    /// Resolve the workspace slug for the `planned-day` store via the
    /// shared `WorkspaceResolver`: `--project` (registry slug OR filesystem
    /// path) wins, else cwd-walk + git-worktree. No Personal fallback — on
    /// no match, print a clear error and throw a non-zero exit.
    ///
    /// `baseDirOverride` is for tests only — it replaces the default
    /// `~/.work42/todo42/projects/<slug>/` directory so a test never touches
    /// a real workspace store.
    @MainActor
    static func openStore(
        projectArg: String?,
        baseDirOverride: String? = nil
    ) throws -> PlannedDayStore {
        let slug: String
        do {
            slug = try Todo42Workspace.resolve(projectArg: projectArg).slug
        } catch {
            errPrint("error: \(error)")
            errPrint("suggestion: pass --project <slug|path>, or run from inside a registered project's directory.")
            throw W42ExitError(W42ExitCode.usage)
        }
        do {
            return try PlannedDayStore(slug: slug, baseDirOverride: baseDirOverride)
        } catch {
            errPrint("error: couldn't open the planned-day store for \(slug): \(error)")
            throw W42ExitError(W42ExitCode.failure)
        }
    }

    /// A CLI-local, human-readable parse failure carrying a `message` +
    /// `suggestion` — mirrors `PlannedDay.ValidationError`'s shape so the
    /// `set` path prints them identically and exits non-zero (no trace). Used
    /// for the CLI's OWN block-parsing errors; `PlannedBlock`'s validation
    /// errors flow through as `PlannedDay.ValidationError` unchanged.
    nonisolated struct BlocksParseError: Error {
        let message: String
        let suggestion: String
    }

    /// Reject a legacy typed-block artifact. The schedule no longer lives on
    /// the PlannedDay artifact — it moved to the generic To-Do collection
    /// (`todo42 todos`). So `planned-day set` accepts ONLY the day-level
    /// briefing (`summary` + `dayStructure`); an artifact carrying a top-level
    /// `blocks` array, or a top-level object shaped like an old block
    /// (`kind` + `ref`), is refused with a pointer to `todo42 todos add`.
    /// A non-object top level or plain JSON error is left for the PlannedDay
    /// decode path to report.
    nonisolated static func assertNoLegacyBlocks(_ data: Data) throws {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        let hasBlocks = obj.keys.contains("blocks")
        let looksLikeBlock = obj.keys.contains("kind") && obj.keys.contains("ref")
        guard hasBlocks || looksLikeBlock else { return }
        throw BlocksParseError(
            message: "planned-day artifacts no longer carry a \"blocks\" array — "
                + "the day's schedule moved to the generic To-Do collection.",
            suggestion: "Drop \"blocks\"/\"kind\"/\"ref\" from the artifact and create "
                + "each item with `todo42 todos add --title … [--slot <startISO>/<endISO>] "
                + "[--url work42://task/<id> | work42://code-review?pr=<url> | https://…]`. "
                + "`planned-day set` now takes only \"summary\" + \"dayStructure\"."
        )
    }

    /// Stamp the planning session id into `day.sessionId` when the artifact
    /// didn't carry one and the environment exports `WORK42_SESSION_ID`.
    /// Pure + injectable so it's testable without mutating the real process
    /// environment. A `sessionId` the JSON already set always wins; a blank
    /// env value is ignored.
    nonisolated static func captureSessionId(
        into day: PlannedDay,
        environment: [String: String]
    ) -> PlannedDay {
        let existing = day.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing, !existing.isEmpty { return day }
        let envValue = environment[sessionEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let envValue, !envValue.isEmpty else { return day }
        var stamped = day
        stamped.sessionId = envValue
        return stamped
    }
}

// MARK: - set

extension PlannedDayCommand {
    struct SetCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Validate and persist the day-level briefing JSON (stdin if no file).",
            discussion: """
                The artifact carries only day-level fields — "date",
                "generatedAt", optional "source"/"sessionId"/"summary", and an
                optional "dayStructure" (the donut breakdown). The day's
                SCHEDULE is no longer part of this artifact: it moved to the
                generic To-Do collection. An artifact carrying a "blocks" array
                (or an old "kind"/"ref" block shape) is rejected with a pointer
                to `todo42 todos add`. Create the day's items with
                `todo42 todos add --title … [--slot <startISO>/<endISO>]
                [--url work42://task/<id> | work42://code-review?pr=<url>]`.
                """
        )

        @Argument(help: "Path to a PlannedDay JSON file. If omitted, JSON is read from stdin.")
        var file: String?

        @Option(name: .long, help: "Workspace slug or path. Defaults to the cwd's project.")
        var project: String?

        @Flag(name: .long, help: "Emit machine-readable JSON instead of human-readable text.")
        var json: Bool = false

        struct Result: Encodable {
            let ok: Bool
            let date: String
            let slug: String
            let source: String
            let sessionId: String?
            /// `true` when the artifact carried a `dayStructure` (persisted on
            /// the planned_days row) — so the writer can confirm the donut
            /// breakdown landed. Absent in the JSON when false.
            let dayStructure: Bool?
        }

        func run() throws {
            try MainActor.assumeIsolated { try runOnMain() }
        }

        @MainActor
        private func runOnMain() throws {
            // Read raw JSON — file arg or stdin.
            let data: Data
            do {
                data = try Self.readInput(file: file)
            } catch {
                errPrint("error: \(error.localizedDescription)")
                errPrint("suggestion: pass a readable JSON file path, or pipe PlannedDay JSON on stdin.")
                throw W42ExitError(W42ExitCode.usage)
            }

            guard !data.isEmpty else {
                errPrint("error: refusing to set an empty planned-day artifact.")
                errPrint("suggestion: provide a PlannedDay JSON document (file or stdin).")
                throw W42ExitError(W42ExitCode.usage)
            }

            // Decode + validate against the schema. Malformed input is
            // rejected with a clear message + suggestion — never a trace.
            var day: PlannedDay
            do {
                day = try PlannedDay.decodeAndValidate(data)
            } catch let e as PlannedDay.ValidationError {
                errPrint("error: \(e.message)")
                errPrint("suggestion: \(e.suggestion)")
                throw W42ExitError(W42ExitCode.usage)
            }

            // Link the planning session that wrote the plan (env capture),
            // unless the artifact already named one.
            day = PlannedDayCommand.captureSessionId(
                into: day,
                environment: ProcessInfo.processInfo.environment
            )

            // Refuse a legacy typed-block artifact BEFORE any write — the
            // schedule moved to the generic To-Do collection (`todo42 todos`).
            do {
                try PlannedDayCommand.assertNoLegacyBlocks(data)
            } catch let e as PlannedDayCommand.BlocksParseError {
                errPrint("error: \(e.message)")
                errPrint("suggestion: \(e.suggestion)")
                throw W42ExitError(W42ExitCode.usage)
            }

            let store = try PlannedDayCommand.openStore(projectArg: project)
            do {
                try store.upsert(day)
            } catch {
                errPrint("error: failed to write planned-day artifact: \(error)")
                throw W42ExitError(W42ExitCode.failure)
            }

            if json {
                try printJSON(Result(
                    ok: true,
                    date: day.date,
                    slug: store.slug,
                    source: day.source.rawValue,
                    sessionId: day.sessionId,
                    dayStructure: day.dayStructure != nil ? true : nil
                ))
            } else {
                let session = day.sessionId.map { ", session \($0)" } ?? ""
                print("✔ planned day saved for \(day.date) in \(store.slug) "
                    + "(\(day.source.rawValue)\(session)).")
                if let ds = day.dayStructure {
                    print("  day structure: focus \(ds.focus)m, reviews \(ds.reviews)m, "
                        + "meetings \(ds.meetings)m, personal \(ds.personal)m, free \(ds.free)m.")
                }
                print("  schedule your day's items with `todo42 todos add`.")
                print("  store: \(store.databasePath)")
            }
        }

        /// Read raw bytes from `file`, or from stdin when nil.
        static func readInput(file: String?) throws -> Data {
            if let file {
                return try Data(contentsOf: URL(fileURLWithPath: file))
            }
            return FileHandle.standardInput.readDataToEndOfFile()
        }
    }
}

// MARK: - show

extension PlannedDayCommand {
    struct ShowCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Print a day's planned-day artifact (default today; raw JSON with --json)."
        )

        @Option(name: .long, help: "Workspace slug or path. Defaults to the cwd's project.")
        var project: String?

        @Option(name: .long, help: "The calendar day (YYYY-MM-DD) to show. Defaults to today.")
        var date: String?

        @Flag(name: .long, help: "Emit the raw stored JSON instead of a human-readable summary.")
        var json: Bool = false

        /// The `--json` payload: the stored `PlannedDay`'s day-level fields,
        /// FLATTENED, plus the day's `todos` array (the projected To-Do
        /// collection). Encoding the day inline (not nested) keeps the existing
        /// top-level shape the app/skill already read.
        struct JSONPayload: Encodable {
            let day: PlannedDay

            func encode(to encoder: Encoder) throws {
                // Emit day-level artifact fields (date, generatedAt, source,
                // sessionId, summary, dayStructure).
                try day.encode(to: encoder)
                var c = encoder.container(keyedBy: ExtraKey.self)
                // Emit the day's To-Dos (a read-time projection — not an
                // artifact field, but part of the show output).
                try c.encode(day.todos, forKey: .todos)
            }

            private enum ExtraKey: String, CodingKey {
                case todos
            }
        }

        func run() throws {
            try MainActor.assumeIsolated { try runOnMain() }
        }

        @MainActor
        private func runOnMain() throws {
            let target = try PlannedDayCommand.resolveDate(date)
            let store = try PlannedDayCommand.openStore(projectArg: project)
            let day: PlannedDay?
            do {
                day = try store.read(date: target)
            } catch {
                errPrint("error: the planned-day artifact for \(target) exists but couldn't be read: \(error)")
                errPrint("suggestion: re-run `todo42 planned-day set` to rewrite it, "
                    + "or `todo42 planned-day clear` to remove it.")
                throw W42ExitError(W42ExitCode.failure)
            }

            guard let day else {
                if json {
                    print("null")
                } else {
                    print("no planned day for \(target) yet in \(store.slug).")
                    print("  the daily-planning routine writes it via `todo42 planned-day set`.")
                }
                return
            }

            if json {
                try printJSON(JSONPayload(day: day))
                return
            }

            print("Overview — \(day.date) (\(store.slug))")
            if let summary = day.summary, !summary.isEmpty {
                print("  \(summary)")
            }
            print("  source: \(day.source.rawValue)   generated: \(day.generatedAt)")
            if let sid = day.sessionId, !sid.isEmpty {
                print("  planning session: \(sid)")
            }

            print("")
            print("  To-Dos (\(day.todos.count))")
            if day.todos.isEmpty {
                print("    (none)")
            }
            for todo in day.todos {
                let mark = todo.isCompleted ? "✔" : "○"
                let when: String
                if !todo.slots.isEmpty {
                    when = todo.slots.map { "\($0.start)→\($0.end)" }.joined(separator: ", ")
                } else if let due = todo.dueDate {
                    when = "all-day \(due)"
                } else {
                    when = "backlog"
                }
                print("    \(mark) \(todo.title)  [\(when)]")
                if let url = todo.url { print("        \(url)") }
                if let reason = todo.reason, !reason.isEmpty { print("        \(reason)") }
            }

            print("")
            print("  Day structure (donut)")
            if let ds = day.dayStructure {
                print("    focus    \(ds.focus)m")
                print("    reviews  \(ds.reviews)m")
                print("    meetings \(ds.meetings)m")
                print("    personal \(ds.personal)m")
                print("    free     \(ds.free)m")
                print("    (\(ds.plannedMinutes)m planned of \(ds.totalMinutes)m total)")
            } else {
                print("    (none — the agent didn't author a breakdown)")
            }
        }

    }
}

// MARK: - last

extension PlannedDayCommand {
    struct LastCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "last",
            abstract: "Print the most recent stored day-level briefing across ALL dates.",
            discussion: """
                Returns the newest planned-day briefing regardless of date — so
                the planning routine can anchor "what was the last plan?" on the
                actual last one (Friday's, on a Monday), not literally yesterday.
                Emits the day-level fields only (date, generatedAt, summary,
                dayStructure); the day's To-Dos live in `todo42 todos`. A clear
                message (not an error) when no plan is stored yet.
                """
        )

        @Option(name: .long, help: "Workspace slug or path. Defaults to the cwd's project.")
        var project: String?

        @Flag(name: .long, help: "Emit the raw stored JSON instead of a human-readable summary.")
        var json: Bool = false

        /// Day-level `--json` payload: the newest plan's briefing fields only
        /// (no blocks/projections — the schedule lives in `todo42 todos`).
        struct JSONPayload: Encodable {
            let date: String
            let generatedAt: String
            let source: String
            let sessionId: String?
            let summary: String?
            let dayStructure: DayStructure?
        }

        func run() throws { try MainActor.assumeIsolated { try runOnMain() } }

        @MainActor
        private func runOnMain() throws {
            let store = try PlannedDayCommand.openStore(projectArg: project)
            let day: PlannedDay?
            do {
                day = try store.latest()
            } catch {
                errPrint("error: couldn't read the latest planned-day briefing: \(error)")
                throw W42ExitError(W42ExitCode.failure)
            }

            guard let day else {
                if json {
                    print("null")
                } else {
                    print("no planned day stored yet in \(store.slug).")
                    print("  the daily-planning routine writes it via `todo42 planned-day set`.")
                }
                return
            }

            if json {
                try printJSON(JSONPayload(
                    date: day.date,
                    generatedAt: day.generatedAt,
                    source: day.source.rawValue,
                    sessionId: day.sessionId,
                    summary: day.summary,
                    dayStructure: day.dayStructure
                ))
                return
            }

            print("Last planned day — \(day.date) (\(store.slug))")
            if let summary = day.summary, !summary.isEmpty {
                print("  \(summary)")
            }
            print("  source: \(day.source.rawValue)   generated: \(day.generatedAt)")
            if let sid = day.sessionId, !sid.isEmpty {
                print("  planning session: \(sid)")
            }
            if let ds = day.dayStructure {
                print("  day structure: focus \(ds.focus)m, reviews \(ds.reviews)m, "
                    + "meetings \(ds.meetings)m, personal \(ds.personal)m, free \(ds.free)m.")
            }
        }
    }
}

// MARK: - list

extension PlannedDayCommand {
    struct ListCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List stored plan dates (history, newest first), one-line each."
        )

        @Option(name: .long, help: "Workspace slug or path. Defaults to the cwd's project.")
        var project: String?

        @Flag(name: .long, help: "Emit machine-readable JSON instead of human-readable text.")
        var json: Bool = false

        /// One history row — the shape the app/skill can rely on in `--json`.
        struct Entry: Encodable {
            let date: String
            let source: String
            let sessionId: String?
            /// The number of To-Dos on the day (open + done).
            let todos: Int
            let summary: String?
        }

        struct Result: Encodable {
            let slug: String
            let count: Int
            let plans: [Entry]
        }

        func run() throws {
            try MainActor.assumeIsolated { try runOnMain() }
        }

        @MainActor
        private func runOnMain() throws {
            let store = try PlannedDayCommand.openStore(projectArg: project)
            let dates: [String]
            do {
                dates = try store.listDates()
            } catch {
                errPrint("error: couldn't list planned-day history: \(error)")
                throw W42ExitError(W42ExitCode.failure)
            }

            // listDates is already newest-first; resolve each to its plan so
            // we can show the one-line summary.
            var plans: [PlannedDay] = []
            for d in dates {
                if let plan = try? store.read(date: d) { plans.append(plan) }
            }

            if json {
                let entries = plans.map { plan in
                    Entry(
                        date: plan.date,
                        source: plan.source.rawValue,
                        sessionId: plan.sessionId,
                        todos: plan.todos.count,
                        summary: plan.summary
                    )
                }
                try printJSON(Result(slug: store.slug, count: entries.count, plans: entries))
                return
            }

            guard !plans.isEmpty else {
                print("no planned days stored yet in \(store.slug).")
                print("  the daily-planning routine writes them via `todo42 planned-day set`.")
                return
            }

            print("Planned days — \(store.slug) (\(plans.count), newest first)")
            for plan in plans {
                print("  " + Self.listLine(plan))
            }
        }

        /// The one-line history summary:
        /// "<date> · <source> · N To-Dos".
        static func listLine(_ plan: PlannedDay) -> String {
            let n = plan.todos.count
            return "\(plan.date) · \(plan.source.rawValue) · \(n) To-Do\(n == 1 ? "" : "s")"
        }
    }
}

// MARK: - clear

extension PlannedDayCommand {
    struct ClearCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear",
            abstract: "Remove a day's planned-day artifact (default today)."
        )

        @Option(name: .long, help: "Workspace slug or path. Defaults to the cwd's project.")
        var project: String?

        @Option(name: .long, help: "The calendar day (YYYY-MM-DD) to clear. Defaults to today.")
        var date: String?

        @Flag(name: .long, help: "Emit machine-readable JSON.")
        var json: Bool = false

        struct Result: Encodable {
            let ok: Bool
            let date: String
            let slug: String
            let removed: Bool
        }

        func run() throws {
            try MainActor.assumeIsolated { try runOnMain() }
        }

        @MainActor
        private func runOnMain() throws {
            let target = try PlannedDayCommand.resolveDate(date)
            let store = try PlannedDayCommand.openStore(projectArg: project)
            let removed: Bool
            do {
                removed = try store.clear(date: target)
            } catch {
                errPrint("error: failed to clear planned-day artifact: \(error)")
                throw W42ExitError(W42ExitCode.failure)
            }

            if json {
                try printJSON(Result(ok: true, date: target, slug: store.slug, removed: removed))
            } else if removed {
                print("✔ cleared planned day for \(target) in \(store.slug).")
            } else {
                print("nothing to clear — no planned day for \(target) in \(store.slug).")
            }
        }
    }
}

// MARK: - --date resolution

extension PlannedDayCommand {

    /// Resolve an optional `--date` argument to a `YYYY-MM-DD` key,
    /// defaulting to today. A malformed `--date` is rejected with a clear
    /// non-zero usage error (no stack trace).
    static func resolveDate(_ raw: String?) throws -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return PlannedDay.todayString()
        }
        guard Self.isValidDate(raw) else {
            errPrint("error: --date must be a calendar day in YYYY-MM-DD form (got \"\(raw)\").")
            errPrint("suggestion: use e.g. --date 2026-06-06, or omit --date for today.")
            throw W42ExitError(W42ExitCode.usage)
        }
        return raw
    }

    /// `true` iff `s` is a real calendar date in `YYYY-MM-DD` form. Mirrors
    /// the model's validator (kept CLI-local so the model's stays internal).
    static func isValidDate(_ s: String) -> Bool {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: s) != nil
    }
}
