// Todo42WorkspaceTests.swift — which project a command runs against (WOR-382).

import Foundation
import Testing
@testable import Todo42Core

@Suite("Project resolution")
struct Todo42WorkspaceTests {

    /// A scratch tree with a registry naming one project rooted at `<root>/repo`.
    private struct Tree {
        let root: String
        let repo: String
        let registry: String

        init() throws {
            root = ((NSTemporaryDirectory() + "todo42-ws-\(UUID().uuidString)") as NSString).resolvingSymlinksInPath
            repo = root + "/repo"
            try FileManager.default.createDirectory(atPath: repo + "/src/deep", withIntermediateDirectories: true)
            registry = root + "/projects.json"
            let json = #"{"acme":{"name":"Acme","repoPath":"\#(repo)"},"other":{"name":"Other","repoPath":"\#(root)/other"}}"#
            try Data(json.utf8).write(to: URL(fileURLWithPath: registry))
        }

        func remove() { try? FileManager.default.removeItem(atPath: root) }
    }

    @Test("a registered slug resolves, from anywhere")
    func bySlug() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let project = try Todo42Workspace.resolve(projectArg: "acme", cwd: "/", registryPath: tree.registry)
        #expect(project.slug == "acme" && project.name == "Acme")
    }

    @Test("a path at or below a registered root resolves")
    func byPath() throws {
        let tree = try Tree()
        defer { tree.remove() }
        #expect(try Todo42Workspace.resolve(projectArg: tree.repo, cwd: "/", registryPath: tree.registry).slug == "acme")
        #expect(try Todo42Workspace.resolve(projectArg: "src/deep", cwd: tree.repo, registryPath: tree.registry).slug == "acme")
    }

    @Test("without --project the working directory is walked up")
    func byWorkingDirectory() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let project = try Todo42Workspace.resolve(cwd: tree.repo + "/src/deep", registryPath: tree.registry)
        #expect(project.slug == "acme")
    }

    @Test("a linked git worktree resolves to its main checkout's project")
    func byGitWorktree() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let fileManager = FileManager.default
        let gitdir = tree.repo + "/.git/worktrees/feature"
        try fileManager.createDirectory(atPath: gitdir, withIntermediateDirectories: true)
        try Data("../..\n".utf8).write(to: URL(fileURLWithPath: gitdir + "/commondir"))
        let worktree = tree.root + "/elsewhere/feature"
        try fileManager.createDirectory(atPath: worktree + "/sub", withIntermediateDirectories: true)
        try Data("gitdir: \(gitdir)\n".utf8).write(to: URL(fileURLWithPath: worktree + "/.git"))

        let project = try Todo42Workspace.resolve(cwd: worktree + "/sub", registryPath: tree.registry)
        #expect(project.slug == "acme")
    }

    @Test("a container directory of worktrees resolves through its children")
    func byContainerScan() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let fileManager = FileManager.default
        let gitdir = tree.repo + "/.git/worktrees/w"
        try fileManager.createDirectory(atPath: gitdir, withIntermediateDirectories: true)
        try Data("../..\n".utf8).write(to: URL(fileURLWithPath: gitdir + "/commondir"))
        let container = tree.root + "/worktrees/acme"
        try fileManager.createDirectory(atPath: container + "/repo", withIntermediateDirectories: true)
        try Data("gitdir: \(gitdir)\n".utf8).write(to: URL(fileURLWithPath: container + "/repo/.git"))

        #expect(try Todo42Workspace.resolve(cwd: container, registryPath: tree.registry).slug == "acme")
    }

    @Test("nothing registered at or above the directory throws, naming the reason")
    func unresolved() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let stray = tree.root + "/stray"
        try FileManager.default.createDirectory(atPath: stray, withIntermediateDirectories: true)
        do {
            _ = try Todo42Workspace.resolve(cwd: stray, registryPath: tree.registry)
            Issue.record("expected an error")
        } catch let error as Todo42Error {
            #expect(error.description.contains("no registered project"))
        }
        do {
            _ = try Todo42Workspace.resolve(projectArg: "nope", cwd: stray, registryPath: tree.registry)
            Issue.record("expected an error")
        } catch let error as Todo42Error {
            #expect(error.description.contains("--project 'nope'"))
        }
    }

    @Test("a missing registry is an empty one")
    func missingRegistry() {
        #expect(Todo42Workspace.registry(at: "/nonexistent/projects.json").isEmpty)
    }
}
