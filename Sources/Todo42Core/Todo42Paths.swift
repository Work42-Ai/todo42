// Todo42Paths.swift — the on-disk locations todo42 owns (WOR-382).
//
// todo42 has no dependency on work42/Flow42Core, so it cannot use `Work42Paths`. These are the same
// `~/.work42/…` locations, reproduced here. The store lives at
// `~/.work42/todo42/projects/<slug>/store.db`. Work42 itself used `~/.work42/work42/projects/<slug>/store.db`;
// `Todo42Migration` copies that file across on first open (the original is left in place).

import Foundation

public nonisolated enum Todo42Paths {

    /// `~/.work42` — the shared Work42 data root. `TODO42_HOME` replaces it (tests and sandboxed runs).
    public static func root() -> String {
        if let override = ProcessInfo.processInfo.environment["TODO42_HOME"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".work42")
    }

    /// `~/.work42/todo42` — the todo42 subsystem root.
    public static func todo42Root() -> String {
        (root() as NSString).appendingPathComponent("todo42")
    }

    /// `~/.work42/todo42/projects/<slug>` — the per-project data directory.
    public static func projectDir(slug: String) -> String {
        (todo42Root() as NSString).appendingPathComponent("projects/\(slug)")
    }

    /// `~/.work42/todo42/projects/<slug>/store.db`.
    public static func storePath(slug: String) -> String {
        (projectDir(slug: slug) as NSString).appendingPathComponent("store.db")
    }

    /// `~/.work42/work42/projects/<slug>/store.db` — where Work42 kept the same store before todo42.
    public static func legacyStorePath(slug: String) -> String {
        let legacy = (root() as NSString).appendingPathComponent("work42/projects/\(slug)")
        return (legacy as NSString).appendingPathComponent("store.db")
    }

    /// `~/.work42/task42/projects.json` — the registry of Work42 projects (slug -> name + repo root).
    public static func projectRegistryPath() -> String {
        (root() as NSString).appendingPathComponent("task42/projects.json")
    }
}
