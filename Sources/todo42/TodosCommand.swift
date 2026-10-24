// TodosCommand.swift — the `todo42 todos` command group
// (feat/planning-generic-block-events-instead-of-first.9/.26).
//
// The generic, persistent To-Do collection that replaces the per-day typed
// work-blocks. A To-Do is a title + zero-or-more committed time SLOTS + an
// optional link (a work42:// deep link, an https URL, or nothing) + an
// explicit completion tick. Not scoped to a day. Both the user (app checkbox)
// and an agent (this CLI) can complete a To-Do; completion is stored, never
// inferred from a linked task42 task.
//
// Soft-archive semantics: `list` excludes To-Dos whose linked session/task is
// archived (stamping their `archived_at` on read — resolve-on-read — and
// filtering them out by default). Use `--archived` to include not-yet-purged
// soft-archived rows. Archived To-Dos are purged automatically after the
// workspace's `archive.autoArchiveHours` window.
//
// Verbs:
//
//   todo42 todos add --title <t> [--slot <startISO>/<endISO> …]
//                    [--due YYYY-MM-DD] [--url <url>] [--reason <r>]
//       Create a To-Do. `--slot` is repeatable — one per committed window.
//       A To-Do with slots is timed (each slot renders as a calendar block);
//       with no slots but a `--due` it is all-day; with neither it is undated
//       backlog. A generated id is minted and printed.
//
//   todo42 todos list [--date YYYY-MM-DD] [--open|--done] [--archived] [--json]
//       List To-Dos, newest first. `--date` keeps To-Dos with a slot
//       overlapping that day OR (all-day) due that day. `--open`/`--done`
//       filter on completion. By default, To-Dos whose linked session/task is
//       archived are excluded (and their `archived_at` is stamped on read).
//       Pass `--archived` to include not-yet-purged soft-archived rows.
//
//   todo42 todos update <id> [--title …] [--slot … | --no-slots] [--due …]
//                            [--url …] [--reason …]
//       Partial update. Passing `--slot` (one or more) REPLACES the slot set;
//       omitting it keeps the existing slots; `--no-slots` removes them all.
//       Other omitted fields are left unchanged, and an empty `--due ""`,
//       `--url ""` or `--reason ""` clears that field.
//
//   todo42 todos sweep [--archived-task <id> …] [--archived-session <id> …]
//                      [--purge-after-hours <n>]
//       The archive pass the Work42 plugin runs on a timer. todo42 cannot look sessions
//       up, so the caller names the archived ones: every To-Do linked to a named task or
//       session gets `archivedAt` stamped, and with `--purge-after-hours` the To-Dos
//       archived longer ago than that are deleted. Prints how many of each.
//
//   todo42 todos complete <id>     Set completedAt (now) on the whole To-Do.
//   todo42 todos reopen   <id>     Clear completedAt.
//   todo42 todos remove   <id>     Delete the To-Do (and its slots).
//
// Storage goes through Flow42Core's `PlannedDayStore` (todos + todo_slots
// tables); the CLI never reaches around it. Workspace resolution reuses
// `PlannedDayCommand.openStore` (--project slug|path, else cwd-walk +
// git-worktree; no Personal fallback).

import ArgumentParser
import Foundation
import Todo42Core

struct TodosCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "todos",
        abstract: "Manage the workspace's generic To-Do collection.",
        discussion: """
            A To-Do is a title + committed time slots + an optional link + an
            explicit completion. Not scoped to a day. A To-Do with slots is
            timed (calendar blocks); with a --due but no slots it is all-day;
            with neither it is undated backlog. The link carries behavior — a
            work42:// deep link (task/code-review/session), an https URL, or
            nothing.

            Soft-archive: `list` excludes To-Dos whose linked session/task is
            archived (stamping archived_at on read). Pass `--archived` to
            include not-yet-purged soft-archived rows. Purge fires after the
            workspace's archive.autoArchiveHours window.
            """,
        subcommands: [
            AddCommand.self,
            ListCommand.self,
            UpdateCommand.self,
            CompleteCommand.self,
            ReopenCommand.self,
            RemoveCommand.self,
            SweepCommand.self,
        ]
    )
}

// MARK: - Shared helpers

extension TodosCommand {

    /// A CLI-local human-readable parse failure (message + suggestion),
    /// mirroring `PlannedDay.ValidationError` so the CLI prints them
    /// identically and exits non-zero (no stack trace).
    nonisolated struct InputError: Error {
        let message: String
        let suggestion: String
    }

    /// Parse repeatable `--slot "<startISO>/<endISO>"` values into `TodoSlot`s.
    /// ISO8601 timestamps contain no `/`, so a single `/` cleanly separates the
    /// pair. A malformed value throws `InputError` (no write happens).
    nonisolated static func parseSlots(_ raw: [String]) throws -> [TodoSlot] {
        var slots: [TodoSlot] = []
        for value in raw {
            let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw InputError(
                    message: "--slot \"\(value)\" must be \"<startISO>/<endISO>\".",
                    suggestion: "e.g. --slot 2026-06-06T09:00:00Z/2026-06-06T11:00:00Z"
                )
            }
            slots.append(TodoSlot(start: String(parts[0]), end: String(parts[1])))
        }
        return slots
    }

    /// The value of an optional field after `update`: not passed keeps it, an empty value clears it.
    nonisolated static func revised(_ passed: String?, keeping existing: String?) -> String? {
        guard let passed else { return existing }
        let trimmed = passed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One To-Do row in `--json` output — the Todo encodes as
    /// `{id,title,slots:[{start,end}],dueDate,url,reason,completedAt}`.
    struct ListResult: Encodable {
        let slug: String
        let count: Int
        let todos: [Todo]
    }

    /// A one-line human summary of a To-Do for the list table.
    /// Soft-archived rows carry an `[archived]` suffix so an operator can tell
    /// them apart when `--archived` is passed.
    static func line(_ todo: Todo) -> String {
        let mark = todo.isCompleted ? "✔" : "○"
        let when: String
        if !todo.slots.isEmpty {
            when = todo.slots.count == 1
                ? "\(todo.slots[0].start)→\(todo.slots[0].end)"
                : "\(todo.slots.count) slots"
        } else if let due = todo.dueDate {
            when = "all-day \(due)"
        } else {
            when = "backlog"
        }
        let link = todo.url.map { " · \($0)" } ?? ""
        let archived = todo.isArchived ? " [archived]" : ""
        return "\(mark) \(todo.id)  \(todo.title)  [\(when)]\(link)\(archived)"
    }
}

// MARK: - add

extension TodosCommand {
    struct AddCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Create a To-Do (repeat --slot for multiple committed windows)."
        )

        @Option(name: .long, help: "The To-Do title (required).")
        var title: String

        @Option(name: .customLong("slot"), help: "A committed window \"<startISO>/<endISO>\". Repeatable.")
        var slot: [String] = []

        @Option(name: .long, help: "All-day due date (YYYY-MM-DD) — used when no --slot is given.")
        var due: String?

        @Option(name: .long, help: "The link: a work42:// deep link, an https URL, or omit for a plain reminder.")
        var url: String?

        @Option(name: .long, help: "An optional one-clause reason.")
        var reason: String?

        @Option(name: .long, help: "Workspace slug or path. Defaults to the cwd's project.")
        var project: String?

        @Flag(name: .long, help: "Emit machine-readable JSON.")
        var json: Bool = false

        struct Result: Encodable {
            let ok: Bool
            let id: String
            let slug: String
        }

        func run() throws { try MainActor.assumeIsolated { try runOnMain() } }

        @MainActor
        private func runOnMain() throws {
            let slots: [TodoSlot]
            do {
                slots = try TodosCommand.parseSlots(slot)
            } catch let e as TodosCommand.InputError {
                errPrint("error: \(e.message)")
                errPrint("suggestion: \(e.suggestion)")
                throw W42ExitError(W42ExitCode.usage)
            }

            let todo = Todo(
                id: UUID().uuidString.lowercased(),
                title: title,
                slots: slots,
                dueDate: due,
                url: url,
                reason: reason
            )
            // Validate before opening the store so a bad To-Do fails fast.
            do {
                try todo.validate()
            } catch let e as PlannedDay.ValidationError {
                errPrint("error: \(e.message)")
                errPrint("suggestion: \(e.suggestion)")
                throw W42ExitError(W42ExitCode.usage)
            }

            let store = try PlannedDayCommand.openStore(projectArg: project)
            do {
                try store.addTodo(todo)
            } catch let e as PlannedDay.ValidationError {
                errPrint("error: \(e.message)")
                errPrint("suggestion: \(e.suggestion)")
                throw W42ExitError(W42ExitCode.usage)
            } catch {
                errPrint("error: failed to add To-Do: \(error)")
                throw W42ExitError(W42ExitCode.failure)
            }

            if json {
                try printJSON(Result(ok: true, id: todo.id, slug: store.slug))
            } else {
                print("✔ added To-Do \(todo.id): \(todo.title) in \(store.slug).")
            }
        }
    }
}

// MARK: - list

extension TodosCommand {
    struct ListCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List To-Dos (newest first); filter by --date/--open/--done/--archived.",
            discussion: """
                By default, To-Dos whose linked session or task has been archived are
                excluded from results (their archived_at is stamped on read — shared
                resolve-on-read with the UI). Pass --archived to include not-yet-purged
                soft-archived rows; they appear with an [archived] suffix in human output
                and carry a non-null archivedAt in --json output. Archived To-Dos are
                purged automatically after the workspace's archive.autoArchiveHours window.
                """
        )

        @Option(name: .long, help: "Keep To-Dos with a slot overlapping this day OR all-day due it (YYYY-MM-DD).")
        var date: String?

        @Flag(name: .long, help: "Only open (not completed) To-Dos.")
        var open: Bool = false

        @Flag(name: .long, help: "Only completed To-Dos.")
        var done: Bool = false

        @Flag(name: .long, help: "Include soft-archived (not-yet-purged) To-Dos.")
        var archived: Bool = false

        @Option(name: .long, help: "Workspace slug or path. Defaults to the cwd's project.")
        var project: String?

        @Flag(name: .long, help: "Emit machine-readable JSON.")
        var json: Bool = false

        func run() throws { try MainActor.assumeIsolated { try runOnMain() } }

        @MainActor
        private func runOnMain() throws {
            if open, done {
                errPrint("error: --open and --done are mutually exclusive.")
                errPrint("suggestion: pass at most one of --open / --done.")
                throw W42ExitError(W42ExitCode.usage)
            }
            let target: String?
            if let date {
                target = try PlannedDayCommand.resolveDate(date)
            } else {
                target = nil
            }
            let store = try PlannedDayCommand.openStore(projectArg: project)
            // Build the resolver in the same @MainActor context as the store.
            let resolver = TodoSessionArchiveResolver(slug: store.slug)
            let todos: [Todo]
            do {
                todos = try store.listTodos(
                    date: target,
                    open: open ? true : nil,
                    done: done ? true : nil,
                    resolver: resolver,
                    includeArchived: archived
                )
            } catch {
                errPrint("error: couldn't list To-Dos: \(error)")
                throw W42ExitError(W42ExitCode.failure)
            }

            if json {
                try printJSON(TodosCommand.ListResult(
                    slug: store.slug, count: todos.count, todos: todos
                ))
                return
            }
            guard !todos.isEmpty else {
                print("no To-Dos\(target.map { " for \($0)" } ?? "") in \(store.slug).")
                print("  add one with `todo42 todos add --title \"…\"`.")
                return
            }
            print("To-Dos — \(store.slug) (\(todos.count))")
            for todo in todos { print("  " + TodosCommand.line(todo)) }
        }
    }
}

// MARK: - update

extension TodosCommand {
    struct UpdateCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update",
            abstract: "Update a To-Do; passing --slot replaces the whole slot set, an empty value clears a field."
        )

        @Argument(help: "The To-Do id.")
        var id: String

        @Option(name: .long, help: "New title.")
        var title: String?

        @Option(name: .customLong("slot"), help: "Replacement window \"<startISO>/<endISO>\". Repeatable; replaces all slots.")
        var slot: [String] = []

        @Flag(name: .customLong("no-slots"), help: "Remove every slot (unschedule the To-Do).")
        var noSlots: Bool = false

        @Option(name: .long, help: "New all-day due date (YYYY-MM-DD); pass \"\" to clear it.")
        var due: String?

        @Option(name: .long, help: "New link; pass \"\" to clear it.")
        var url: String?

        @Option(name: .long, help: "New reason; pass \"\" to clear it.")
        var reason: String?

        @Option(name: .long, help: "Workspace slug or path. Defaults to the cwd's project.")
        var project: String?

        @Flag(name: .long, help: "Emit machine-readable JSON.")
        var json: Bool = false

        struct Result: Encodable {
            let ok: Bool
            let id: String
            let slug: String
        }

        func run() throws { try MainActor.assumeIsolated { try runOnMain() } }

        @MainActor
        private func runOnMain() throws {
            let store = try PlannedDayCommand.openStore(projectArg: project)
            guard let existing = try store.todo(id: id) else {
                errPrint("error: no To-Do with id \"\(id)\".")
                errPrint("suggestion: list current To-Dos with `todo42 todos list`.")
                throw W42ExitError(W42ExitCode.usage)
            }

            if noSlots && !slot.isEmpty {
                errPrint("error: --no-slots and --slot are mutually exclusive.")
                errPrint("suggestion: pass --slot to replace the windows, or --no-slots to remove them all.")
                throw W42ExitError(W42ExitCode.usage)
            }
            let newSlots: [TodoSlot]
            if noSlots {
                newSlots = []
            } else if slot.isEmpty {
                newSlots = existing.slots
            } else {
                do {
                    newSlots = try TodosCommand.parseSlots(slot)
                } catch let e as TodosCommand.InputError {
                    errPrint("error: \(e.message)")
                    errPrint("suggestion: \(e.suggestion)")
                    throw W42ExitError(W42ExitCode.usage)
                }
            }

            let revised = Todo(
                id: existing.id,
                title: title ?? existing.title,
                slots: newSlots,
                dueDate: TodosCommand.revised(due, keeping: existing.dueDate),
                url: TodosCommand.revised(url, keeping: existing.url),
                reason: TodosCommand.revised(reason, keeping: existing.reason),
                completedAt: existing.completedAt,
                archivedAt: existing.archivedAt
            )
            do {
                try store.updateTodo(revised)
            } catch let e as PlannedDay.ValidationError {
                errPrint("error: \(e.message)")
                errPrint("suggestion: \(e.suggestion)")
                throw W42ExitError(W42ExitCode.usage)
            } catch {
                errPrint("error: failed to update To-Do: \(error)")
                throw W42ExitError(W42ExitCode.failure)
            }

            if json {
                try printJSON(Result(ok: true, id: id, slug: store.slug))
            } else {
                print("✔ updated To-Do \(id) in \(store.slug).")
            }
        }
    }
}

// MARK: - complete / reopen / remove

extension TodosCommand {

    /// Shared shape for the three id-only mutations.
    struct MutationResult: Encodable {
        let ok: Bool
        let id: String
        let slug: String
        let changed: Bool
    }

    struct CompleteCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "complete",
            abstract: "Mark a To-Do complete (sets completedAt)."
        )
        @Argument(help: "The To-Do id.") var id: String
        @Option(name: .long, help: "Workspace slug or path.") var project: String?
        @Flag(name: .long, help: "Emit machine-readable JSON.") var json: Bool = false

        func run() throws { try MainActor.assumeIsolated { try runOnMain() } }

        @MainActor
        private func runOnMain() throws {
            let store = try PlannedDayCommand.openStore(projectArg: project)
            let changed = try TodosCommand.mutate(store: store, id: id, verb: "complete") {
                try store.setCompleted(id: id)
            }
            try TodosCommand.report(json: json, id: id, slug: store.slug, changed: changed,
                                doneWord: "completed")
        }
    }

    struct ReopenCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reopen",
            abstract: "Reopen a To-Do (clears completedAt)."
        )
        @Argument(help: "The To-Do id.") var id: String
        @Option(name: .long, help: "Workspace slug or path.") var project: String?
        @Flag(name: .long, help: "Emit machine-readable JSON.") var json: Bool = false

        func run() throws { try MainActor.assumeIsolated { try runOnMain() } }

        @MainActor
        private func runOnMain() throws {
            let store = try PlannedDayCommand.openStore(projectArg: project)
            let changed = try TodosCommand.mutate(store: store, id: id, verb: "reopen") {
                try store.clearCompleted(id: id)
            }
            try TodosCommand.report(json: json, id: id, slug: store.slug, changed: changed,
                                doneWord: "reopened")
        }
    }

    struct RemoveCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Delete a To-Do (and its slots)."
        )
        @Argument(help: "The To-Do id.") var id: String
        @Option(name: .long, help: "Workspace slug or path.") var project: String?
        @Flag(name: .long, help: "Emit machine-readable JSON.") var json: Bool = false

        func run() throws { try MainActor.assumeIsolated { try runOnMain() } }

        @MainActor
        private func runOnMain() throws {
            let store = try PlannedDayCommand.openStore(projectArg: project)
            let changed = try TodosCommand.mutate(store: store, id: id, verb: "remove") {
                try store.removeTodo(id: id)
            }
            try TodosCommand.report(json: json, id: id, slug: store.slug, changed: changed,
                                doneWord: "removed")
        }
    }

    /// Run an id-only store mutation, mapping a failure to a clean CLI error.
    @MainActor
    static func mutate(
        store: PlannedDayStore, id: String, verb: String, _ body: () throws -> Bool
    ) throws -> Bool {
        do {
            return try body()
        } catch {
            errPrint("error: failed to \(verb) To-Do \(id): \(error)")
            throw W42ExitError(W42ExitCode.failure)
        }
    }

    /// Print the outcome of an id-only mutation. An unknown id
    /// (`changed == false`) is a clean non-zero usage error, never a crash.
    @MainActor
    static func report(
        json: Bool, id: String, slug: String, changed: Bool, doneWord: String
    ) throws {
        if json {
            try printJSON(MutationResult(ok: changed, id: id, slug: slug, changed: changed))
            if !changed {
                errPrint("error: no To-Do with id \"\(id)\" in \(slug).")
                throw W42ExitError(W42ExitCode.usage)
            }
        } else if changed {
            print("✔ \(doneWord) To-Do \(id) in \(slug).")
        } else {
            errPrint("error: no To-Do with id \"\(id)\" in \(slug).")
            errPrint("suggestion: list current To-Dos with `todo42 todos list`.")
            throw W42ExitError(W42ExitCode.usage)
        }
    }
}

// MARK: - sweep

extension TodosCommand {
    struct SweepCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sweep",
            abstract: "Stamp To-Dos whose linked session is archived, and purge old archived ones.",
            discussion: """
                todo42 has no way to look a session up, so the caller says which are archived:
                --archived-task for a `work42://task/<id>` link (the id is the session's id) and
                --archived-session for a session id (what a code-review, session or artifact link
                resolves to). A To-Do linked to one of them is stamped archived. With
                --purge-after-hours N, To-Dos archived more than N hours ago are deleted. Without
                it nothing is deleted.
                """
        )

        @Option(name: .customLong("archived-task"), help: "The id in a work42://task/<id> link whose session is archived. Repeatable.")
        var archivedTask: [String] = []

        @Option(name: .customLong("archived-session"), help: "A session id that is archived. Repeatable.")
        var archivedSession: [String] = []

        @Option(name: .customLong("purge-after-hours"), help: "Delete To-Dos archived more than this many hours ago.")
        var purgeAfterHours: Int?

        @Option(name: .long, help: "Workspace slug or path. Defaults to the cwd's project.")
        var project: String?

        @Flag(name: .long, help: "Emit machine-readable JSON.")
        var json: Bool = false

        struct Result: Encodable {
            let ok: Bool
            let slug: String
            let stamped: Int
            let purged: Int
        }

        func run() throws { try MainActor.assumeIsolated { try runOnMain() } }

        @MainActor
        private func runOnMain() throws {
            if let hours = purgeAfterHours, hours < 0 {
                errPrint("error: --purge-after-hours must not be negative.")
                errPrint("suggestion: pass 0 or more hours, or omit it to keep archived To-Dos.")
                throw W42ExitError(W42ExitCode.usage)
            }
            let store = try PlannedDayCommand.openStore(projectArg: project)
            do {
                let result = try TodosCommand.sweep(
                    store: store, archivedTaskIds: Set(archivedTask), archivedSessionIds: Set(archivedSession),
                    purgeAfterHours: purgeAfterHours)
                if json {
                    try printJSON(Result(ok: true, slug: store.slug, stamped: result.stamped, purged: result.purged))
                } else {
                    print("✔ \(store.slug): archived \(result.stamped) To-Do(s), purged \(result.purged).")
                }
            } catch {
                errPrint("error: sweep failed: \(error)")
                throw W42ExitError(W42ExitCode.failure)
            }
        }
    }

    /// Stamp the To-Dos linked to an archived task or session, then purge the ones archived longer ago than
    /// `purgeAfterHours` (when given). Pure over the store, so it is testable without a process.
    @MainActor
    static func sweep(
        store: PlannedDayStore, archivedTaskIds: Set<String>, archivedSessionIds: Set<String>,
        purgeAfterHours: Int?, now: Date = Date()
    ) throws -> (stamped: Int, purged: Int) {
        let before = try store.listTodos(includeArchived: true).filter(\.isArchived).count
        let resolver = TodoSessionArchiveResolver(
            slug: store.slug, archivedTaskIds: archivedTaskIds, archivedSessionIds: archivedSessionIds)
        let after = try store.listTodos(resolver: resolver, includeArchived: true).filter(\.isArchived).count
        var purged = 0
        if let hours = purgeAfterHours {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let cutoff = formatter.string(from: now.addingTimeInterval(-Double(hours) * 3600))
            purged = try store.purgeArchivedTodos(before: cutoff)
        }
        return (stamped: max(0, after - before), purged: purged)
    }
}
