// Todo42MigrationTests.swift — the first-open copy of Work42's old store (WOR-382).

import Foundation
import Testing
@testable import Todo42Core

@Suite("Legacy store migration")
struct Todo42MigrationTests {

    private func scratch() throws -> String {
        let dir = NSTemporaryDirectory() + "todo42-migration-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A store at `<dir>/store.db` holding one To-Do, closed again.
    private func seedStore(in dir: String, title: String) throws {
        let store = try PlannedDayStore(slug: "p", baseDirOverride: dir)
        try store.addTodo(Todo(id: "t1", title: title))
    }

    @Test("a missing todo42 store is copied from the legacy one, and the original stays")
    func copiesOnce() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let legacyDir = root + "/legacy", newDir = root + "/new"
        try seedStore(in: legacyDir, title: "carried over")

        let copied = Todo42Migration.copyLegacyStoreIfNeeded(
            slug: "p", legacyPath: legacyDir + "/store.db", destinationPath: newDir + "/store.db")
        #expect(copied)
        #expect(FileManager.default.fileExists(atPath: legacyDir + "/store.db"))

        let store = try PlannedDayStore(slug: "p", baseDirOverride: newDir)
        #expect(try store.listTodos().map(\.title) == ["carried over"])
    }

    @Test("an existing todo42 store is never overwritten")
    func doesNotOverwrite() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let legacyDir = root + "/legacy", newDir = root + "/new"
        try seedStore(in: legacyDir, title: "old")
        try seedStore(in: newDir, title: "new")

        let copied = Todo42Migration.copyLegacyStoreIfNeeded(
            slug: "p", legacyPath: legacyDir + "/store.db", destinationPath: newDir + "/store.db")
        #expect(!copied)
        let store = try PlannedDayStore(slug: "p", baseDirOverride: newDir)
        #expect(try store.listTodos().map(\.title) == ["new"])
    }

    @Test("with no legacy store there is nothing to copy and no empty file is left behind")
    func nothingToCopy() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let copied = Todo42Migration.copyLegacyStoreIfNeeded(
            slug: "p", legacyPath: root + "/missing/store.db", destinationPath: root + "/new/store.db")
        #expect(!copied)
        #expect(!FileManager.default.fileExists(atPath: root + "/new/store.db"))
    }

    @Test("a legacy file that is not a database is not copied")
    func corruptLegacyIsRefused() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/legacy", withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: root + "/legacy/store.db"))
        let copied = Todo42Migration.copyLegacyStoreIfNeeded(
            slug: "p", legacyPath: root + "/legacy/store.db", destinationPath: root + "/new/store.db")
        #expect(!copied)
        #expect(!FileManager.default.fileExists(atPath: root + "/new/store.db"))
    }
}
