// PlannedDayStore.swift — the per-workspace SQLite store for the daily
// "Overview" plan (`PlannedDay`). Lives at
// `~/.work42/todo42/projects/<slug>/store.db`, modeled on meet42's
// `MeetProjectStore` (same direct-libsqlite3 pattern, WAL at open, the
// directory *is* the scope so there is no `project_path` column).
//
// This REPLACES the old global, loose-JSON storage
// (`~/.work42/work42/planned-day/<date>.json`) — daily plans are now a
// first-class, per-workspace, **retained forever** record. The store is
// in Flow42Core so it opens identically from BOTH the `work42` CLI and
// the app's Overview widget.
//
// Schema:
//   `planned_days` — one row per `date` (primary key), holding day-level
//   fields only: `generatedAt`, `source`, `sessionId`, `summary`,
//   `dayStructure`, `createdAt`. The legacy focus columns
//   (`focus_task`, `focus_reason`, `focus_tasks_json`, `prs_json`) remain
//   in the schema as vestigial columns — they are no longer written or read
//   as a source (bound as NULL / '[]' in upsert, ignored in rowToPlan).
//
//   `todos` (+ child `todo_slots`) — the generic, TIMELESS To-Do collection.
//   A To-Do is not scoped to a day; its `slots` are intended work windows and
//   `due_date` is a deadline. `PlannedDay.todos` PROJECTS the ones scheduled
//   for a given day (`listTodos(date:)` = slot-that-day OR due-that-day). The
//   legacy `planned_blocks` table survives only as the one-time migration
//   SOURCE (see `migrateBlocksToTodosIfNeeded`).
//
// Concurrency: @MainActor, single-thread connection, WAL at open time so
// the in-process app writer and the `work42` CLI reader don't block.
// Mirrors MeetProjectStore exactly.

import Foundation
import SQLite3

private let SQLITE_TRANSIENT_PD = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self
)

@MainActor
public final class PlannedDayStore {

    public enum StoreError: Error, CustomStringConvertible {
        case openFailed(path: String, code: Int32, message: String)
        case prepareFailed(sql: String, message: String)
        case stepFailed(sql: String, message: String)

        public var description: String {
            switch self {
            case .openFailed(let p, let c, let m):
                return "Couldn't open todo42 store at \(p) (code \(c)): \(m)"
            case .prepareFailed(let sql, let m):
                return "prepare failed for `\(sql)`: \(m)"
            case .stepFailed(let sql, let m):
                return "step failed for `\(sql)`: \(m)"
            }
        }
    }

    private static let schema = """
    PRAGMA journal_mode = WAL;

    -- One daily "Overview" plan per calendar day for this workspace.
    -- Retained forever (light data — no pruning). Holds day-level fields
    -- only: generatedAt, source, sessionId, summary, dayStructure.
    -- The legacy focus columns (focus_task, focus_reason,
    -- focus_tasks_json, prs_json) are vestigial — kept for schema stability
    -- but no longer written or read as a source.
    CREATE TABLE IF NOT EXISTS planned_days (
      date          TEXT PRIMARY KEY,
      generated_at  TEXT NOT NULL,
      source        TEXT NOT NULL,
      session_id    TEXT,
      summary       TEXT,
      focus_task    TEXT,
      focus_reason  TEXT,
      focus_tasks_json TEXT,
      prs_json      TEXT NOT NULL DEFAULT '[]',
      day_structure_json TEXT,
      created_at    TEXT NOT NULL
    );

    -- LEGACY per-day work-blocks (T-005), retained ONLY as the one-time
    -- migration source into `todos` (migrateBlocksToTodosIfNeeded). Nothing
    -- reads or writes it as a live schedule anymore — the generic `todos`
    -- collection below is a day's schedule now.
    CREATE TABLE IF NOT EXISTS planned_blocks (
      date        TEXT NOT NULL,
      kind        TEXT NOT NULL,
      ref         TEXT NOT NULL,
      ref_id      TEXT,
      reason      TEXT,
      title       TEXT NOT NULL,
      start       TEXT NOT NULL,
      end         TEXT NOT NULL,
      created_at  TEXT NOT NULL,
      PRIMARY KEY (date, start, ref)
    );

    -- Generic, persistent To-Dos (feat/planning-generic-block-events).
    -- TIMELESS: one row per To-Do, addressable by `id`, not scoped to a day.
    -- `url` carries behavior (work42:// deep link / https / null); `due_date`
    -- is an optional DEADLINE (YYYY-MM-DD); `completed_at` is the explicit,
    -- stored completion. `archived_at` is a system-stamped soft-archive
    -- timestamp (ISO8601), written by the resolve-on-read hook when the linked
    -- session/task is archived; nil = not archived.
    CREATE TABLE IF NOT EXISTS todos (
      id            TEXT PRIMARY KEY,
      title         TEXT NOT NULL,
      due_date      TEXT,
      url           TEXT,
      reason        TEXT,
      completed_at  TEXT,
      archived_at   TEXT,
      created_at    TEXT NOT NULL
    );

    -- The intended WORK WINDOWS of a To-Do (feat/planning-generic-block-events).
    -- A To-Do owns 0..N slots (ordered by `idx`); each carries its own datetime
    -- and renders as one calendar block — "work on it then", NOT day-ownership.
    -- Deleting a To-Do cascades its slots.
    CREATE TABLE IF NOT EXISTS todo_slots (
      todo_id     TEXT NOT NULL,
      idx         INTEGER NOT NULL,
      start       TEXT NOT NULL,
      end         TEXT NOT NULL,
      PRIMARY KEY (todo_id, idx),
      FOREIGN KEY (todo_id) REFERENCES todos(id) ON DELETE CASCADE
    );
    """

    /// The project slug this store is scoped to.
    public let slug: String
    public let databasePath: String
    private nonisolated(unsafe) var db: OpaquePointer?

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Path

    /// `~/.work42/todo42/projects/<slug>/`.
    public static func defaultDir(slug: String) -> String {
        Todo42Paths.projectDir(slug: slug)
    }

    /// Default per-project store path: `~/.work42/todo42/projects/<slug>/store.db`.
    public static func defaultPath(slug: String) -> String {
        Todo42Paths.storePath(slug: slug)
    }

    /// Today's date in `YYYY-MM-DD` (local calendar).
    public static func todayString() -> String { PlannedDay.todayString() }

    // MARK: - Open

    /// Open (creating + bootstrapping if needed) the per-workspace store
    /// for `slug`. `baseDirOverride`, when set, replaces the default
    /// `~/.work42/todo42/projects/<slug>/` directory — used by tests for
    /// isolation. Idempotent across processes via WAL.
    public init(slug: String, baseDirOverride: String? = nil) throws {
        self.slug = slug
        let dir = baseDirOverride ?? Self.defaultDir(slug: slug)
        let path = (dir as NSString).appendingPathComponent("store.db")
        self.databasePath = path
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        // First open under todo42: bring over the store Work42 used to keep, once, leaving the original.
        if baseDirOverride == nil {
            Todo42Migration.copyLegacyStoreIfNeeded(slug: slug)
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        if rc != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown"
            if let h = handle { sqlite3_close_v2(h) }
            throw StoreError.openFailed(path: path, code: rc, message: msg)
        }
        self.db = handle
        try execBlock(Self.schema, label: "schema")
        try migrate()
        try migrateBlocksToTodosIfNeeded()
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - Forward-compat migration
    //
    // `planned_days` and `planned_blocks` may exist on user DBs that predate
    // certain columns. We use the additive `PRAGMA table_info` + `ALTER TABLE
    // ADD COLUMN` pattern (the EXACT idempotent guard CalendarStore uses):
    // each column is in `Self.schema` for fresh DBs, and added in place for
    // existing ones. `CREATE TABLE IF NOT EXISTS` doesn't add a column to a
    // pre-existing table, which is why this guard is required.

    /// Add any missing additive columns to `planned_days`, `planned_blocks`,
    /// and `todos` on an existing DB.
    private func migrate() throws {
        // Columns that should exist on `planned_days`. Order doesn't matter
        // for ALTER TABLE ADD COLUMN.
        let requiredDays: [(String, String)] = [
            ("day_structure_json", "TEXT"),
            ("focus_tasks_json", "TEXT"),
        ]
        let existingDays = try queryColumns(table: "planned_days")
        for (name, type) in requiredDays where !existingDays.contains(name) {
            try execBlock(
                "ALTER TABLE planned_days ADD COLUMN \(name) \(type)",
                label: "alter-days-\(name)"
            )
        }

        // Columns that should exist on `planned_blocks`.
        let requiredBlocks: [(String, String)] = [
            ("reason", "TEXT"),
        ]
        let existingBlocks = try queryColumns(table: "planned_blocks")
        for (name, type) in requiredBlocks where !existingBlocks.contains(name) {
            try execBlock(
                "ALTER TABLE planned_blocks ADD COLUMN \(name) \(type)",
                label: "alter-blocks-\(name)"
            )
        }

        // Columns that should exist on `todos` (AC-V2-8: pre-v2 DBs upgrade in
        // place, archivedAt nil on existing rows, no re-migration).
        let requiredTodos: [(String, String)] = [
            ("archived_at", "TEXT"),
        ]
        let existingTodos = try queryColumns(table: "todos")
        for (name, type) in requiredTodos where !existingTodos.contains(name) {
            try execBlock(
                "ALTER TABLE todos ADD COLUMN \(name) \(type)",
                label: "alter-todos-\(name)"
            )
        }
    }

    // MARK: - One-time planned_blocks → todos migration
    //
    // Existing workspaces have their schedule in `planned_blocks` (typed
    // task/prReview rows). This lifts those into the generic `todos`
    // collection ONCE, grouping rows that share a mapped url on the same day
    // into a single multi-slot To-Do (a task's several stretches → one To-Do
    // with several slots). Guarded by `PRAGMA user_version`: 0 ⇒ not migrated,
    // 1 ⇒ done. The flag bump rides inside the same transaction as the inserts,
    // so an interrupted run rolls back wholesale and retries next open.

    /// Migration schema version stamped in `PRAGMA user_version` once the
    /// planned_blocks → todos lift has run.
    private static let todosMigrationVersion: Int64 = 1

    /// Lift `planned_blocks` into `todos` exactly once. No-op when already at
    /// (or past) `todosMigrationVersion`, so fresh DBs (empty planned_blocks)
    /// simply stamp the version and move on.
    private func migrateBlocksToTodosIfNeeded() throws {
        guard try userVersion() < Self.todosMigrationVersion else { return }

        // Read every legacy block. Column order: date, kind, ref, reason,
        // title, start, end (ordered so grouping is deterministic).
        struct LegacyBlock {
            let date: String, kind: String, ref: String
            let reason: String?, title: String, start: String, end: String
        }
        let legacy: [LegacyBlock] = try query(
            """
            SELECT date, kind, ref, reason, title, start, end
            FROM planned_blocks ORDER BY date ASC, start ASC, ref ASC
            """,
            bind: { _ in },
            map: { stmt in
                LegacyBlock(
                    date: columnText(stmt, 0) ?? "",
                    kind: columnText(stmt, 1) ?? "task",
                    ref: columnText(stmt, 2) ?? "",
                    reason: columnText(stmt, 3),
                    title: columnText(stmt, 4) ?? "",
                    start: columnText(stmt, 5) ?? "",
                    end: columnText(stmt, 6) ?? ""
                )
            }
        )

        // Group by (mapped url, day) — preserving first-seen order — so several
        // stretches of the same task on one day collapse into one To-Do.
        struct Group {
            var title: String
            var reason: String?
            var url: String?
            var dueDate: String?
            var slots: [TodoSlot]
        }
        var order: [String] = []
        var groups: [String: Group] = [:]
        for block in legacy {
            let url = Self.migrateURL(kind: block.kind, ref: block.ref)
            let key = "\(url ?? "")\u{1}\(block.date)"
            let parseable = TodoSlot.parseISO8601(block.start) != nil
                && TodoSlot.parseISO8601(block.end) != nil
            if groups[key] == nil {
                order.append(key)
                groups[key] = Group(
                    title: block.title, reason: block.reason, url: url,
                    dueDate: parseable ? nil : (PlannedDay.isValidDate(block.date) ? block.date : nil),
                    slots: []
                )
            }
            if parseable {
                groups[key]?.slots.append(TodoSlot(start: block.start, end: block.end))
                // A group that later gains a real slot is no longer all-day.
                groups[key]?.dueDate = nil
            }
        }

        let nowIso = Self.iso.string(from: Date())
        try execBlock("BEGIN IMMEDIATE;", label: "begin-migrate")
        do {
            for key in order {
                guard let group = groups[key] else { continue }
                let todo = Todo(
                    id: UUID().uuidString.lowercased(),
                    title: group.title,
                    slots: group.slots,
                    dueDate: group.slots.isEmpty ? group.dueDate : nil,
                    url: group.url,
                    reason: group.reason,
                    completedAt: nil
                )
                try insertTodoRow(todo, createdAt: nowIso)
                try insertSlots(todoId: todo.id, slots: todo.slots)
            }
            try execBlock(
                "PRAGMA user_version = \(Self.todosMigrationVersion);",
                label: "stamp-version"
            )
        } catch {
            try? execBlock("ROLLBACK;", label: "rollback-migrate")
            throw error
        }
        try execBlock("COMMIT;", label: "commit-migrate")
    }

    /// Map a legacy block's `kind` + `ref` to a To-Do `url`:
    /// task → `work42://task/<ref>`, prReview → `work42://code-review?pr=<ref>`.
    /// An unknown kind maps to nil (a plain reminder carrying the ref only via
    /// its title).
    private static func migrateURL(kind: String, ref: String) -> String? {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch kind {
        case "task":
            return "work42://task/\(trimmed)"
        case "prReview":
            let encoded = trimmed.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) ?? trimmed
            return "work42://code-review?pr=\(encoded)"
        default:
            return nil
        }
    }

    /// Read `PRAGMA user_version`.
    private func userVersion() throws -> Int64 {
        let rows: [Int64] = try query(
            "PRAGMA user_version",
            bind: { _ in },
            map: { stmt in sqlite3_column_int64(stmt, 0) }
        )
        return rows.first ?? 0
    }

    /// The set of column names on `table`, via `PRAGMA table_info`.
    private func queryColumns(table: String) throws -> Set<String> {
        let rows: [String] = try query(
            "PRAGMA table_info(\(table))",
            bind: { _ in },
            map: { stmt in columnText(stmt, 1) ?? "" }
        )
        return Set(rows.filter { !$0.isEmpty })
    }

    // MARK: - Read / write

    /// Validate and upsert `plan`, keyed by its `date`. An existing row for
    /// the same date is overwritten (the `created_at` is preserved when one
    /// exists). Throws `PlannedDay.ValidationError` on a bad artifact.
    ///
    /// The legacy focus columns (`focus_task`, `focus_reason`,
    /// `focus_tasks_json`, `prs_json`) are vestigial — bound as NULL / '[]'
    /// and no longer written as a source. The genuine day-level columns
    /// (`generated_at`, `source`, `session_id`, `summary`, `day_structure_json`)
    /// are written as before.
    public func upsert(_ plan: PlannedDay) throws {
        try plan.validate()
        let nowIso = Self.iso.string(from: Date())
        // `dayStructure` is OPTIONAL — absent stays NULL so it reads back nil.
        let dayStructureJSON = try Self.encodeDayStructure(plan.dayStructure)
        try exec(
            """
            INSERT INTO planned_days
              (date, generated_at, source, session_id, summary,
               focus_task, focus_reason, focus_tasks_json, prs_json,
               day_structure_json, created_at)
            VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, '[]', ?, ?)
            ON CONFLICT(date) DO UPDATE SET
              generated_at = excluded.generated_at,
              source       = excluded.source,
              session_id   = excluded.session_id,
              summary      = excluded.summary,
              focus_task   = NULL,
              focus_reason = NULL,
              focus_tasks_json = NULL,
              prs_json     = '[]',
              day_structure_json = excluded.day_structure_json
            """,
            bind: { stmt in
                bindText(stmt, 1, plan.date)
                bindText(stmt, 2, plan.generatedAt)
                bindText(stmt, 3, plan.source.rawValue)
                bindOptText(stmt, 4, plan.sessionId)
                bindOptText(stmt, 5, plan.summary)
                bindOptText(stmt, 6, dayStructureJSON)
                bindText(stmt, 7, nowIso)
            }
        )
    }

    /// Read the plan for `date`, or nil if none exists. The returned
    /// `PlannedDay`'s `todos` are projected from the `todos` collection
    /// for that date.
    public func read(date: String) throws -> PlannedDay? {
        let rows = try query(
            """
            SELECT date, generated_at, source, session_id, summary,
                   day_structure_json
            FROM planned_days WHERE date = ?
            """,
            bind: { stmt in bindText(stmt, 1, date) },
            map: Self.rowToPlan
        )
        guard var plan = rows.first else { return nil }
        plan.todos = try listTodos(date: date)
        return plan
    }

    /// Read today's plan, or nil if none exists.
    public func readToday() throws -> PlannedDay? {
        try read(date: Self.todayString())
    }

    /// The most-recent plan by date (newest first), or nil when the store
    /// is empty. The returned `PlannedDay`'s `focusTasks` and
    /// `prReviews` are projected from the `planned_blocks` rows for that date.
    public func latest() throws -> PlannedDay? {
        let rows = try query(
            """
            SELECT date, generated_at, source, session_id, summary,
                   day_structure_json
            FROM planned_days ORDER BY date DESC LIMIT 1
            """,
            bind: { _ in },
            map: Self.rowToPlan
        )
        guard var plan = rows.first else { return nil }
        plan.todos = try listTodos(date: plan.date)
        return plan
    }

    /// All stored plan dates, newest first (history).
    public func listDates() throws -> [String] {
        try query(
            "SELECT date FROM planned_days ORDER BY date DESC",
            bind: { _ in },
            map: { stmt in columnText(stmt, 0) ?? "" }
        )
    }

    /// Remove the plan for `date`. Returns `true` iff a row was removed.
    @discardableResult
    public func clear(date: String) throws -> Bool {
        guard try read(date: date) != nil else { return false }
        try exec(
            "DELETE FROM planned_days WHERE date = ?",
            bind: { stmt in bindText(stmt, 1, date) }
        )
        return true
    }

    /// Remove today's plan. Returns `true` iff one existed.
    @discardableResult
    public func clearToday() throws -> Bool {
        try clear(date: Self.todayString())
    }

    // MARK: - To-Dos (todos + todo_slots)
    //
    // The generic, persistent To-Do collection — the day's schedule. A To-Do
    // owns 0..N slots; completion is stored on the To-Do. (The legacy
    // `planned_blocks` table remains only as the one-time migration SOURCE;
    // nothing reads or writes it as a live schedule anymore.)

    /// Insert a new To-Do (with its slots), validating first. Throws
    /// `PlannedDay.ValidationError` on a bad To-Do (nothing is written).
    public func addTodo(_ todo: Todo) throws {
        try todo.validate()
        let nowIso = Self.iso.string(from: Date())
        try execBlock("BEGIN IMMEDIATE;", label: "begin")
        do {
            try insertTodoRow(todo, createdAt: nowIso)
            try insertSlots(todoId: todo.id, slots: todo.slots)
        } catch {
            try? execBlock("ROLLBACK;", label: "rollback")
            throw error
        }
        try execBlock("COMMIT;", label: "commit")
    }

    /// Replace an existing To-Do wholesale (fields + the entire slot set),
    /// keyed by `todo.id`. Validates first. The `created_at` is preserved.
    /// Throws if no To-Do with that id exists.
    public func updateTodo(_ todo: Todo) throws {
        try todo.validate()
        guard let existingCreatedAt = try createdAt(todoId: todo.id) else {
            throw PlannedDay.ValidationError(
                message: "no To-Do with id \"\(todo.id)\".",
                suggestion: "List current To-Dos with `work42 todos list`."
            )
        }
        try execBlock("BEGIN IMMEDIATE;", label: "begin")
        do {
            try exec(
                """
                UPDATE todos SET title = ?, due_date = ?, url = ?, reason = ?,
                                 completed_at = ?, archived_at = ?
                WHERE id = ?
                """,
                bind: { stmt in
                    bindText(stmt, 1, todo.title)
                    bindOptText(stmt, 2, todo.dueDate)
                    bindOptText(stmt, 3, todo.url)
                    bindOptText(stmt, 4, todo.reason)
                    bindOptText(stmt, 5, todo.completedAt)
                    bindOptText(stmt, 6, todo.archivedAt)
                    bindText(stmt, 7, todo.id)
                }
            )
            try exec(
                "DELETE FROM todo_slots WHERE todo_id = ?",
                bind: { stmt in bindText(stmt, 1, todo.id) }
            )
            try insertSlots(todoId: todo.id, slots: todo.slots)
        } catch {
            try? execBlock("ROLLBACK;", label: "rollback")
            throw error
        }
        _ = existingCreatedAt  // created_at is intentionally left untouched.
        try execBlock("COMMIT;", label: "commit")
    }

    /// Mark a To-Do complete by setting `completed_at` (defaults to now).
    /// Returns `true` iff a row was updated.
    @discardableResult
    public func setCompleted(id: String, at iso: String? = nil) throws -> Bool {
        guard try createdAt(todoId: id) != nil else { return false }
        let stamp = iso ?? Self.iso.string(from: Date())
        try exec(
            "UPDATE todos SET completed_at = ? WHERE id = ?",
            bind: { stmt in
                bindText(stmt, 1, stamp)
                bindText(stmt, 2, id)
            }
        )
        return true
    }

    /// Reopen a To-Do by clearing `completed_at`. Returns `true` iff a row was
    /// updated.
    @discardableResult
    public func clearCompleted(id: String) throws -> Bool {
        guard try createdAt(todoId: id) != nil else { return false }
        try exec(
            "UPDATE todos SET completed_at = NULL WHERE id = ?",
            bind: { stmt in bindText(stmt, 1, id) }
        )
        return true
    }

    // MARK: - Slot scheduling (v3 manual calendar scheduling)
    //
    // A To-Do's `slots` are its intended work windows — each renders as a
    // calendar block via `WorkBlockEvent`. These helpers mutate a SINGLE slot
    // and persist through `updateTodo` (which already replaces the child
    // `todo_slots` rows), so the manual-scheduling UI never hand-writes SQL.
    // Times are ISO8601 via `Self.iso` — the exact format
    // `WorkBlockEvent.parseISO8601` reads back, so the projection round-trips.

    /// Append a work-window slot `[start, end)` to a To-Do. Returns `false` when
    /// no To-Do with that id exists. Throws if the resulting To-Do fails
    /// validation (e.g. `end` not after `start`).
    @discardableResult
    public func insertSlot(todoId: String, start: Date, end: Date) throws -> Bool {
        guard var todo = try todo(id: todoId) else { return false }
        todo.slots.append(TodoSlot(start: Self.iso.string(from: start),
                                   end: Self.iso.string(from: end)))
        try updateTodo(todo)
        return true
    }

    /// Replace slot `index` of a To-Do with a new window (move / resize).
    /// Returns `false` when the id is unknown or `index` is out of range.
    @discardableResult
    public func updateSlot(todoId: String, index: Int, start: Date, end: Date) throws -> Bool {
        guard var todo = try todo(id: todoId), todo.slots.indices.contains(index) else { return false }
        todo.slots[index] = TodoSlot(start: Self.iso.string(from: start),
                                     end: Self.iso.string(from: end))
        try updateTodo(todo)
        return true
    }

    /// Remove slot `index` of a To-Do (unschedule that block). Returns `false`
    /// when the id is unknown or `index` is out of range.
    @discardableResult
    public func removeSlot(todoId: String, index: Int) throws -> Bool {
        guard var todo = try todo(id: todoId), todo.slots.indices.contains(index) else { return false }
        todo.slots.remove(at: index)
        try updateTodo(todo)
        return true
    }

    /// Soft-archive a To-Do by setting `archived_at` (defaults to now, ISO8601).
    /// Returns `true` iff a row was updated; `false` when no To-Do with that id
    /// exists. Mirrors `setCompleted`.
    @discardableResult
    public func setArchived(id: String, at iso: String? = nil) throws -> Bool {
        guard try createdAt(todoId: id) != nil else { return false }
        let stamp = iso ?? Self.iso.string(from: Date())
        try exec(
            "UPDATE todos SET archived_at = ? WHERE id = ?",
            bind: { stmt in
                bindText(stmt, 1, stamp)
                bindText(stmt, 2, id)
            }
        )
        return true
    }

    /// Hard-delete every soft-archived To-Do (and its slots, via CASCADE) whose
    /// `archived_at` is non-null AND lexicographically less than `cutoffISO`
    /// (ISO8601 strings sort correctly without parsing). Returns the number of
    /// rows deleted.
    ///
    /// The `archived_at` column is written by `setArchived` using `Self.iso`
    /// (ISO8601 with fractional seconds + internet date-time options), so the
    /// lexicographic `<` comparison used here is correct for the same format.
    @discardableResult
    public func purgeArchivedTodos(before cutoffISO: String) throws -> Int {
        // Identify the ids to purge (avoid relying on SQLite cascade for the
        // count — we want to return an accurate deleted-row count).
        let ids: [String] = try query(
            """
            SELECT id FROM todos
            WHERE archived_at IS NOT NULL AND archived_at < ?
            """,
            bind: { stmt in bindText(stmt, 1, cutoffISO) },
            map: { stmt in columnText(stmt, 0) ?? "" }
        )
        guard !ids.isEmpty else { return 0 }

        try execBlock("BEGIN IMMEDIATE;", label: "begin-purge")
        do {
            for id in ids {
                // CASCADE on the FK deletes todo_slots automatically, but
                // SQLite only honours ON DELETE CASCADE when foreign_keys pragma
                // is ON; delete slots explicitly to be safe.
                try exec(
                    "DELETE FROM todo_slots WHERE todo_id = ?",
                    bind: { stmt in bindText(stmt, 1, id) }
                )
                try exec(
                    "DELETE FROM todos WHERE id = ?",
                    bind: { stmt in bindText(stmt, 1, id) }
                )
            }
        } catch {
            try? execBlock("ROLLBACK;", label: "rollback-purge")
            throw error
        }
        try execBlock("COMMIT;", label: "commit-purge")
        return ids.count
    }

    /// Delete a To-Do and its slots. Returns `true` iff a row was removed.
    @discardableResult
    public func removeTodo(id: String) throws -> Bool {
        guard try createdAt(todoId: id) != nil else { return false }
        try execBlock("BEGIN IMMEDIATE;", label: "begin")
        do {
            try exec(
                "DELETE FROM todo_slots WHERE todo_id = ?",
                bind: { stmt in bindText(stmt, 1, id) }
            )
            try exec(
                "DELETE FROM todos WHERE id = ?",
                bind: { stmt in bindText(stmt, 1, id) }
            )
        } catch {
            try? execBlock("ROLLBACK;", label: "rollback")
            throw error
        }
        try execBlock("COMMIT;", label: "commit")
        return true
    }

    /// Read one To-Do by id (with its slots), or nil.
    public func todo(id: String) throws -> Todo? {
        let rows = try query(
            """
            SELECT id, title, due_date, url, reason, completed_at, archived_at
            FROM todos WHERE id = ?
            """,
            bind: { stmt in bindText(stmt, 1, id) },
            map: Self.rowToTodoBase
        )
        guard var todo = rows.first else { return nil }
        todo.slots = try slots(todoId: id)
        return todo
    }

    /// List To-Dos, newest first by `created_at`. Optional filters:
    ///   - `date` — keep To-Dos with a slot overlapping that calendar day OR
    ///     due that day (`dueDate == date`).
    ///   - `open` / `done` — keep only open (no `completedAt`) or done ones.
    ///   - `resolver` — when supplied, each To-Do whose linked session/task is
    ///     archived (per the resolver) and whose `archivedAt` is still nil gets
    ///     stamped via `setArchived(id:)` before filtering (resolve-on-read).
    ///   - `includeArchived` — when `false` (default), To-Dos with a non-nil
    ///     `archivedAt` are excluded after the resolve-on-read stamp; `true`
    ///     includes them.
    /// Filtering happens in Swift over the light To-Do set (slots live in a
    /// child table; day comparison needs timestamp parsing).
    public func listTodos(
        date: String? = nil,
        open: Bool? = nil,
        done: Bool? = nil,
        resolver: (any TodoSessionArchiveResolving)? = nil,
        includeArchived: Bool = false
    ) throws -> [Todo] {
        let bases = try query(
            """
            SELECT id, title, due_date, url, reason, completed_at, archived_at
            FROM todos ORDER BY created_at DESC, id ASC
            """,
            bind: { _ in },
            map: Self.rowToTodoBase
        )
        var result: [Todo] = []
        for var todo in bases {
            todo.slots = try slots(todoId: todo.id)
            // Resolve-on-read: if a resolver is provided and the To-Do has no
            // archived stamp yet, check whether its linked session/task is now
            // archived and stamp it if so.
            if let resolver, todo.archivedAt == nil,
               resolver.isLinkedSessionArchived(todo) {
                let stamp = Self.iso.string(from: Date())
                _ = try? setArchived(id: todo.id, at: stamp)
                todo.archivedAt = stamp
            }
            // Archived filter (applied after potential stamping above).
            if !includeArchived, todo.archivedAt != nil { continue }
            if let date, !Self.todo(todo, matchesDate: date) { continue }
            if open == true, todo.isCompleted { continue }
            if done == true, !todo.isCompleted { continue }
            result.append(todo)
        }
        return result
    }

    /// List today's To-Dos (local calendar).
    public func todosToday() throws -> [Todo] {
        try listTodos(date: Self.todayString())
    }

    // MARK: To-Do helpers

    /// `true` iff `todo` belongs on `date` (`YYYY-MM-DD`): a slot overlaps the
    /// day, or (no slots) its `dueDate` equals the day.
    private static func todo(_ todo: Todo, matchesDate date: String) -> Bool {
        if todo.slots.isEmpty {
            return todo.dueDate == date
        }
        return todo.slots.contains { slot in
            guard let startDay = dayString(fromISO: slot.start) else { return false }
            let endDay = dayString(fromISO: slot.end) ?? startDay
            return startDay <= date && date <= endDay
        }
    }

    /// The local-calendar `YYYY-MM-DD` for an ISO8601 timestamp, or nil when it
    /// doesn't parse.
    private static func dayString(fromISO iso: String) -> String? {
        guard let date = TodoSlot.parseISO8601(iso) else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    /// The `created_at` for a To-Do id, or nil when the To-Do doesn't exist.
    /// Doubles as an existence check.
    private func createdAt(todoId: String) throws -> String? {
        let rows: [String] = try query(
            "SELECT created_at FROM todos WHERE id = ?",
            bind: { stmt in bindText(stmt, 1, todoId) },
            map: { stmt in columnText(stmt, 0) ?? "" }
        )
        return rows.first
    }

    /// Read a To-Do's slots, ordered by `idx`.
    private func slots(todoId: String) throws -> [TodoSlot] {
        try query(
            "SELECT start, end FROM todo_slots WHERE todo_id = ? ORDER BY idx ASC",
            bind: { stmt in bindText(stmt, 1, todoId) },
            map: { stmt in
                TodoSlot(start: columnText(stmt, 0) ?? "", end: columnText(stmt, 1) ?? "")
            }
        )
    }

    /// Insert the `todos` row (no slots).
    private func insertTodoRow(_ todo: Todo, createdAt: String) throws {
        try exec(
            """
            INSERT INTO todos (id, title, due_date, url, reason, completed_at, archived_at, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bind: { stmt in
                bindText(stmt, 1, todo.id)
                bindText(stmt, 2, todo.title)
                bindOptText(stmt, 3, todo.dueDate)
                bindOptText(stmt, 4, todo.url)
                bindOptText(stmt, 5, todo.reason)
                bindOptText(stmt, 6, todo.completedAt)
                bindOptText(stmt, 7, todo.archivedAt)
                bindText(stmt, 8, createdAt)
            }
        )
    }

    /// Insert `slots` for `todoId`, indexed in order.
    private func insertSlots(todoId: String, slots: [TodoSlot]) throws {
        for (idx, slot) in slots.enumerated() {
            try exec(
                "INSERT INTO todo_slots (todo_id, idx, start, end) VALUES (?, ?, ?, ?)",
                bind: { stmt in
                    bindText(stmt, 1, todoId)
                    sqlite3_bind_int64(stmt, 2, Int64(idx))
                    bindText(stmt, 3, slot.start)
                    bindText(stmt, 4, slot.end)
                }
            )
        }
    }

    /// Build a slot-less `Todo` from a SELECT row. Column order:
    /// id, title, due_date, url, reason, completed_at, archived_at. The caller
    /// overlays `slots`.
    private static func rowToTodoBase(_ stmt: OpaquePointer?) -> Todo {
        Todo(
            id: columnText(stmt, 0) ?? "",
            title: columnText(stmt, 1) ?? "",
            slots: [],
            dueDate: columnText(stmt, 2),
            url: columnText(stmt, 3),
            reason: columnText(stmt, 4),
            completedAt: columnText(stmt, 5),
            archivedAt: columnText(stmt, 6)
        )
    }

    // MARK: - Test hook

    /// Run `body` with the raw SQLite connection. **For tests only** — lets a
    /// test seed a row that predates a column (e.g. a pre-`focus_tasks_json`
    /// row) to exercise the read-time legacy fallback. Not part of the public
    /// store contract; the CLI/app never reach the connection directly.
    func withRawConnection(_ body: (OpaquePointer?) throws -> Void) rethrows {
        try body(db)
    }

    // MARK: - Row mapping + JSON

    /// Build a day-level `PlannedDay` from a SELECT row. Column order:
    /// date, generated_at, source, session_id, summary, day_structure_json.
    /// `todos` is left empty here — the caller (`read`/`latest`) overlays the
    /// projected To-Dos from the `todos` collection.
    private static func rowToPlan(_ stmt: OpaquePointer?) -> PlannedDay {
        let date = columnText(stmt, 0) ?? ""
        let generatedAt = columnText(stmt, 1) ?? ""
        let sourceRaw = columnText(stmt, 2) ?? "scheduled"
        let source = PlannedDay.Source(rawValue: sourceRaw) ?? .scheduled
        let sessionId = columnText(stmt, 3)
        let summary = columnText(stmt, 4)
        let dayStructure = decodeDayStructure(columnText(stmt, 5))
        return PlannedDay(
            date: date,
            generatedAt: generatedAt,
            source: source,
            sessionId: sessionId,
            summary: summary,
            dayStructure: dayStructure
        )
    }

    /// Encode the OPTIONAL `dayStructure` to a JSON string for the
    /// `day_structure_json` column, or `nil` to store SQL NULL when absent.
    private static func encodeDayStructure(_ ds: DayStructure?) throws -> String? {
        guard let ds else { return nil }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(ds)
        return String(decoding: data, as: UTF8.self)
    }

    /// Decode the `day_structure_json` column back to an optional
    /// `DayStructure` — `nil` (no donut) when the column is NULL/empty or
    /// unparseable.
    private static func decodeDayStructure(_ json: String?) -> DayStructure? {
        guard let json, !json.isEmpty else { return nil }
        return try? JSONDecoder().decode(DayStructure.self, from: Data(json.utf8))
    }

    // MARK: - Generic SQL helpers (mirror MeetProjectStore)

    private func query<T>(
        _ sql: String,
        bind: (OpaquePointer?) -> Void,
        map: (OpaquePointer?) -> T
    ) throws -> [T] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(
                sql: sql, message: String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var rows: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                rows.append(map(stmt))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw StoreError.stepFailed(
                    sql: sql, message: String(cString: sqlite3_errmsg(db))
                )
            }
        }
        return rows
    }

    private func exec(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(
                sql: sql, message: String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw StoreError.stepFailed(
                sql: sql, message: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    private func execBlock(_ sql: String, label: String) throws {
        guard let db else { return }
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
        let msg = errmsg.map { String(cString: $0) } ?? "(no message)"
        sqlite3_free(errmsg)
        if rc != SQLITE_OK {
            throw StoreError.stepFailed(
                sql: "[\(label)] \(sql.prefix(80))…", message: msg
            )
        }
    }
}

// MARK: - Free bind/column helpers

@MainActor
private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
    sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT_PD)
}

@MainActor
private func bindOptText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
    if let value {
        sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT_PD)
    } else {
        sqlite3_bind_null(stmt, idx)
    }
}

@MainActor
private func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
    guard let cstr = sqlite3_column_text(stmt, idx) else { return nil }
    return String(cString: cstr)
}
