// Todo42Migration.swift — carries Work42's existing To-Dos and planned days over (WOR-382).
//
// Before todo42 existed Work42 kept this data in `~/.work42/work42/projects/<slug>/store.db`. On the first
// open of a project's todo42 store, if that file does not exist yet and the old one does, the old store is
// copied across with SQLite's online backup API (a consistent snapshot even while the app still has the
// old file open in WAL mode). The original is never touched, so rolling back to an older Work42 loses
// nothing; later writes go to the new file only.

import Foundation
import SQLite3

public nonisolated enum Todo42Migration {

    /// Copy the legacy store for `slug` to the todo42 location when the latter is missing.
    /// - Returns: `true` when a copy was made.
    @discardableResult
    public static func copyLegacyStoreIfNeeded(
        slug: String,
        legacyPath: String? = nil,
        destinationPath: String? = nil
    ) -> Bool {
        let fileManager = FileManager.default
        let source = legacyPath ?? Todo42Paths.legacyStorePath(slug: slug)
        let destination = destinationPath ?? Todo42Paths.storePath(slug: slug)
        guard !fileManager.fileExists(atPath: destination), fileManager.fileExists(atPath: source) else { return false }
        try? fileManager.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        var sourceHandle: OpaquePointer?
        guard sqlite3_open_v2(source, &sourceHandle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let sourceDB = sourceHandle else {
            if let sourceHandle { sqlite3_close_v2(sourceHandle) }
            return false
        }
        defer { sqlite3_close_v2(sourceDB) }

        var destinationHandle: OpaquePointer?
        guard sqlite3_open_v2(destination, &destinationHandle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let destinationDB = destinationHandle else {
            if let destinationHandle { sqlite3_close_v2(destinationHandle) }
            try? fileManager.removeItem(atPath: destination)
            return false
        }
        var copied = false
        if let backup = sqlite3_backup_init(destinationDB, "main", sourceDB, "main") {
            copied = sqlite3_backup_step(backup, -1) == SQLITE_DONE
            sqlite3_backup_finish(backup)
        }
        sqlite3_close_v2(destinationDB)
        if !copied {
            // A half-written copy would be taken for the real store on the next open.
            for suffix in ["", "-wal", "-shm"] { try? fileManager.removeItem(atPath: destination + suffix) }
        }
        return copied
    }
}
