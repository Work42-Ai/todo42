// Todo42Workspace.swift — which Work42 project a todo42 command operates on (WOR-382).
//
// Same rules Work42's `WorkspaceResolver` applied, read straight from the project registry
// (`~/.work42/task42/projects.json`, written by Work42) so todo42 needs no Work42 code:
//   1. `--project <slug|path>` wins: a registered slug, else a path at or under a registered root.
//   2. Otherwise the working directory is walked up against the registered roots, then, for a git
//      worktree, the main checkout it belongs to (read from the `.git` file — no subprocess).
//   3. Last, the direct children of each directory on the way up are checked, so a container
//      directory holding one worktree per repo (`~/.work42/worktrees/<slug>/`) resolves too.
// No fallback project: when nothing matches, resolution throws and the CLI prints the reason.

import Foundation

public nonisolated struct Todo42Project: Sendable, Equatable {
    public let slug: String
    public let name: String
    public let root: String

    public init(slug: String, name: String, root: String) {
        self.slug = slug
        self.name = name
        self.root = root
    }
}

public nonisolated enum Todo42Error: Error, CustomStringConvertible {
    case projectNotResolved(reason: String)

    public var description: String {
        switch self {
        case .projectNotResolved(let reason): return "project not resolved: \(reason)"
        }
    }
}

public nonisolated enum Todo42Workspace {

    /// Resolve the project for `projectArg` (a slug or a path) or, when nil, for `cwd`.
    public static func resolve(projectArg: String? = nil, cwd: String? = nil,
                               registryPath: String = Todo42Paths.projectRegistryPath()) throws -> Todo42Project {
        let workingDir = cwd ?? FileManager.default.currentDirectoryPath
        let projects = registry(at: registryPath)

        if let raw = projectArg?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            if let project = projects.first(where: { $0.slug == raw }) { return project }
            let absolute = absolutePath(raw, relativeTo: workingDir)
            if let project = locate(startingFrom: absolute, in: projects) { return project }
            throw Todo42Error.projectNotResolved(
                reason: "--project '\(raw)' is not a registered slug and does not resolve to a registered project path")
        }
        if let project = locate(startingFrom: workingDir, in: projects) { return project }
        throw Todo42Error.projectNotResolved(
            reason: "no registered project found at or above '\(workingDir)' (cwd-walk + git-worktree)")
    }

    /// The registered projects, sorted by slug. Empty when the registry is missing or unreadable.
    public static func registry(at path: String = Todo42Paths.projectRegistryPath()) -> [Todo42Project] {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        return json.compactMap { slug, entry in
            guard let root = entry["repoPath"] as? String ?? entry["root"] as? String,
                  let name = entry["name"] as? String else { return nil }
            return Todo42Project(slug: slug, name: name, root: root)
        }
        .sorted { $0.slug < $1.slug }
    }

    // MARK: - Locating

    static func locate(startingFrom start: String, in projects: [Todo42Project]) -> Todo42Project? {
        let resolvedRoots = projects.map { (project: $0, resolved: ($0.root as NSString).resolvingSymlinksInPath) }
        func match(_ path: String) -> Todo42Project? {
            resolvedRoots.first(where: { $0.resolved == path })?.project
        }
        /// The project whose root is `path` or the nearest ancestor of it.
        func walkUp(from path: String) -> Todo42Project? {
            var current = URL(fileURLWithPath: path).standardizedFileURL
            while current.path != "/" {
                if let project = match((current.path as NSString).resolvingSymlinksInPath) { return project }
                current.deleteLastPathComponent()
            }
            return nil
        }

        // 1. The directory itself or an ancestor is a registered root.
        if let project = walkUp(from: start) { return project }

        // 2. A git worktree: its main checkout (or an ancestor of it) is a registered root.
        var scan = URL(fileURLWithPath: start).standardizedFileURL
        while scan.path != "/" {
            let gitEntry = scan.appendingPathComponent(".git").path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: gitEntry, isDirectory: &isDirectory), !isDirectory.boolValue,
               let mainRoot = linkedWorktreeMainRoot(gitFile: gitEntry), let project = walkUp(from: mainRoot) {
                return project
            }
            scan.deleteLastPathComponent()
        }

        // 3. A container directory whose children are worktrees or clones of a registered root.
        var container = URL(fileURLWithPath: start).standardizedFileURL
        while container.path != "/" {
            if let project = childScan(in: container.path, match: match, walkUp: walkUp) { return project }
            container.deleteLastPathComponent()
        }
        return nil
    }

    private static func childScan(in directory: String, match: (String) -> Todo42Project?,
                                  walkUp: (String) -> Todo42Project?) -> Todo42Project? {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { return nil }
        for entry in entries.sorted() {
            let child = (directory as NSString).appendingPathComponent(entry)
            var childIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child, isDirectory: &childIsDirectory), childIsDirectory.boolValue else { continue }
            let gitEntry = (child as NSString).appendingPathComponent(".git")
            var gitIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: gitEntry, isDirectory: &gitIsDirectory) else { continue }
            if !gitIsDirectory.boolValue, let mainRoot = linkedWorktreeMainRoot(gitFile: gitEntry),
               let project = walkUp(mainRoot) {
                return project
            }
            if let project = match((child as NSString).resolvingSymlinksInPath) { return project }
        }
        return nil
    }

    /// The main checkout a linked worktree's `.git` file points at, read from the filesystem only.
    /// The file holds `gitdir: <main>/.git/worktrees/<name>`; that directory's `commondir` names the
    /// main `.git`, whose parent is the checkout. Without `commondir`, three components are stripped.
    static func linkedWorktreeMainRoot(gitFile: String) -> String? {
        let fileManager = FileManager.default
        guard let data = fileManager.contents(atPath: gitFile), let text = String(data: data, encoding: .utf8) else { return nil }
        var rawGitDir: String?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gitdir:") {
                rawGitDir = String(trimmed.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard let raw = rawGitDir, !raw.isEmpty else { return nil }
        let gitFileDirectory = (gitFile as NSString).deletingLastPathComponent
        let absolute = raw.hasPrefix("/") ? raw : (gitFileDirectory as NSString).appendingPathComponent(raw)
        let gitDir = URL(fileURLWithPath: absolute).standardizedFileURL.path

        let commonDirFile = (gitDir as NSString).appendingPathComponent("commondir")
        if let commonData = fileManager.contents(atPath: commonDirFile), let common = String(data: commonData, encoding: .utf8) {
            let trimmed = common.trimmingCharacters(in: .whitespacesAndNewlines)
            let mainDotGit = trimmed.hasPrefix("/") ? trimmed : (gitDir as NSString).appendingPathComponent(trimmed)
            let resolved = URL(fileURLWithPath: mainDotGit).standardizedFileURL.path
            return (resolved as NSString).deletingLastPathComponent
        }
        let root = ((((gitDir as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent) as NSString)
            .deletingLastPathComponent
        return root.isEmpty || root == "/" ? nil : root
    }

    private static func absolutePath(_ raw: String, relativeTo base: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (base as NSString).appendingPathComponent(expanded)
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
    }
}
