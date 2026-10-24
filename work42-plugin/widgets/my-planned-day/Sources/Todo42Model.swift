// Todo42Model.swift — shared by the To-Dos and My Planned Day widgets (copied into each widget's Sources by
// scripts/sync-shared.sh, because every widget compiles on its own).
//
// The plugin never touches the store: every read and write goes through the `todo42` CLI. This file holds the
// tolerant decoders for its `--json` output, the thin async wrapper that runs it through the session's shell
// service, and the small formatting helpers both widgets use.

import CryptoKit
import Foundation
import SwiftUI
import Work42UI
import Work42PluginKit

// MARK: - Values (the CLI's JSON)

nonisolated struct Todo42Slot: Codable, Equatable, Sendable {
    var start: String
    var end: String
}

/// What a To-Do's `url` points at. Derived, never stored (the same rules the CLI's `TodoDerivedKind` applies).
nonisolated enum Todo42Kind: Sendable {
    case task, review, session, link, todo

    init(url: String?) {
        guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { self = .todo; return }
        guard let parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased() else { self = .link; return }
        guard scheme == "work42" else { self = .link; return }
        switch parts.host?.lowercased() {
        case "task": self = .task
        case "code-review": self = .review
        case "session": self = .session
        default: self = .link
        }
    }

    /// The SF Symbol shown when nothing more is known about the link.
    var glyph: String {
        switch self {
        case .task: return "checklist"
        case .review: return "checkmark.shield"
        case .session: return "bubble.left"
        case .link: return "link"
        case .todo: return "circle.dashed"
        }
    }
}

nonisolated struct Todo42Item: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var slots: [Todo42Slot]
    var dueDate: String?
    var url: String?
    var reason: String?
    var completedAt: String?
    var archivedAt: String?

    var isCompleted: Bool { completedAt != nil }
    var kind: Todo42Kind { Todo42Kind(url: url) }

    private enum Keys: String, CodingKey { case id, title, slots, dueDate, url, reason, completedAt, archivedAt }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        slots = try c.decodeIfPresent([Todo42Slot].self, forKey: .slots) ?? []
        dueDate = try c.decodeIfPresent(String.self, forKey: .dueDate)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
        archivedAt = try c.decodeIfPresent(String.self, forKey: .archivedAt)
    }
}

/// The five minute totals the planning agent authors for the day's donut.
nonisolated struct Todo42DayStructure: Codable, Equatable, Sendable {
    var focus: Int
    var reviews: Int
    var meetings: Int
    var personal: Int
    var free: Int

    /// Focus + Reviews + Meetings: the headline "work" figure.
    var workMinutes: Int { focus + reviews + meetings }
}

/// `todo42 planned-day show --json`: the day's briefing plus the To-Dos scheduled for it.
nonisolated struct Todo42Day: Decodable, Sendable {
    var date: String
    var generatedAt: String?
    var source: String?
    var sessionId: String?
    var summary: String?
    var dayStructure: Todo42DayStructure?
    var todos: [Todo42Item]

    private enum Keys: String, CodingKey { case date, generatedAt, source, sessionId, summary, dayStructure, todos }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        date = try c.decode(String.self, forKey: .date)
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        dayStructure = try c.decodeIfPresent(Todo42DayStructure.self, forKey: .dayStructure)
        todos = try c.decodeIfPresent([Todo42Item].self, forKey: .todos) ?? []
    }
}

nonisolated private struct Todo42ListResult: Decodable {
    var slug: String
    var todos: [Todo42Item]
}

// MARK: - The CLI

nonisolated enum Todo42Failure: Error, Equatable {
    /// `todo42` is not on the PATH.
    case notInstalled
    /// The command ran and failed (or printed something that is not the expected JSON).
    case failed(command: String, message: String)

    var message: String {
        switch self {
        case .notInstalled: return "todo42 is not installed."
        case .failed(_, let message): return message
        }
    }
}

enum Todo42CLI {

    /// POSIX single-quote escaping for a value placed in a `/bin/sh -c` command line.
    nonisolated static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Run `todo42 <args>` through the widget's shell service and return its stdout.
    @discardableResult
    static func run(_ arguments: [String], shell: any WidgetShellService) async throws -> String {
        let command = (["todo42"] + arguments.map(quote)).joined(separator: " ")
        let result: WidgetShellResult
        do {
            result = try await shell.run(command: command)
        } catch {
            throw Todo42Failure.failed(command: command, message: error.localizedDescription)
        }
        if result.exitCode == 127 { throw Todo42Failure.notInstalled }
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Todo42Failure.failed(command: command, message: detail.isEmpty ? "todo42 exited with \(result.exitCode)." : detail)
        }
        return result.stdout
    }

    private static func decode<T: Decodable>(_ type: T.Type, from output: String, command: String) throws -> T {
        guard let data = output.data(using: .utf8) else {
            throw Todo42Failure.failed(command: command, message: "todo42 printed nothing readable.")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw Todo42Failure.failed(command: command, message: "Couldn\u{2019}t read todo42\u{2019}s output: \(error.localizedDescription)")
        }
    }

    /// The whole open and done collection, in the store's order (archived To-Dos excluded).
    static func list(shell: any WidgetShellService) async throws -> (slug: String, todos: [Todo42Item]) {
        let output = try await run(["todos", "list", "--json"], shell: shell)
        let result = try decode(Todo42ListResult.self, from: output, command: "todo42 todos list --json")
        return (result.slug, result.todos)
    }

    /// The briefing for `date` (`YYYY-MM-DD`, default today) with its scheduled To-Dos, or nil when there is none.
    static func day(_ date: String?, shell: any WidgetShellService) async throws -> Todo42Day? {
        var arguments = ["planned-day", "show", "--json"]
        if let date { arguments += ["--date", date] }
        let output = try await run(arguments, shell: shell)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "null" || trimmed.isEmpty { return nil }
        return try decode(Todo42Day.self, from: output, command: "todo42 " + arguments.joined(separator: " "))
    }

    // MARK: Writes

    static func add(title: String, shell: any WidgetShellService) async throws {
        try await run(["todos", "add", "--title", title], shell: shell)
    }

    static func setCompleted(_ id: String, _ completed: Bool, shell: any WidgetShellService) async throws {
        try await run(["todos", completed ? "complete" : "reopen", id], shell: shell)
    }

    static func rename(_ id: String, to title: String, shell: any WidgetShellService) async throws {
        try await run(["todos", "update", id, "--title", title], shell: shell)
    }

    /// Set the due date (`YYYY-MM-DD`), or clear it with nil.
    static func setDueDate(_ id: String, _ date: String?, shell: any WidgetShellService) async throws {
        try await run(["todos", "update", id, "--due", date ?? ""], shell: shell)
    }

    /// Set the link, or clear it with nil.
    static func setURL(_ id: String, _ url: String?, shell: any WidgetShellService) async throws {
        try await run(["todos", "update", id, "--url", url ?? ""], shell: shell)
    }

    /// Replace the slots with `slots` (all of them removed when empty).
    static func setSlots(_ id: String, _ slots: [Todo42Slot], shell: any WidgetShellService) async throws {
        if slots.isEmpty {
            try await run(["todos", "update", id, "--no-slots"], shell: shell)
        } else {
            try await run(["todos", "update", id] + slots.flatMap { ["--slot", "\($0.start)/\($0.end)"] }, shell: shell)
        }
    }

    static func remove(_ id: String, shell: any WidgetShellService) async throws {
        try await run(["todos", "remove", id], shell: shell)
    }
}

// MARK: - Links to sessions

/// Which session a To-Do's `work42://` link points at, so the widget can show its stage and the background agent
/// can ask whether it is archived. Mirrors the CLI's `Work42Link` / `TodoSessionLink.linkedSessionId`.
nonisolated enum Todo42Link {

    enum Target: Equatable {
        /// `work42://task/<id>`: the id is the task session's own id.
        case task(id: String)
        /// A session the id of which is derived from the project and the PR (`work42://code-review?pr=<url>`).
        case session(id: String)
        case none
    }

    /// The session behind `url` for the project `slug`; `.none` for a plain, external or unrecognised link.
    static func target(url: String?, slug: String) -> Target {
        guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let parts = URLComponents(string: raw), parts.scheme?.lowercased() == "work42" else { return .none }
        let tail = parts.path.hasPrefix("/") ? String(parts.path.dropFirst()) : parts.path
        switch parts.host?.lowercased() {
        case "task":
            return tail.isEmpty ? .none : .task(id: tail)
        case "code-review":
            guard let pr = parts.queryItems?.first(where: { $0.name == "pr" })?.value, let key = prKey(pr) else { return .none }
            return .session(id: derivedSessionId(project: slug, task: key))
        case "session":
            if tail.isEmpty { return .none }
            if let marker = tail.range(of: "/artifact/", options: .backwards) {
                let id = String(tail[..<marker.lowerBound])
                return id.isEmpty ? .none : .session(id: id)
            }
            return .session(id: tail)
        default:
            return .none
        }
    }

    /// The session id to ask Work42 about, whichever form the link has.
    static func sessionId(url: String?, slug: String) -> String? {
        switch target(url: url, slug: slug) {
        case .task(let id), .session(let id): return id
        case .none: return nil
        }
    }

    /// `github.com/<owner>/<repo>/pull/<N>` (lower-cased) for a PR web URL; nil for anything else.
    static func prKey(_ urlString: String) -> String? {
        guard let parts = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
        let segments = parts.path.split(separator: "/").map(String.init)
        guard segments.count >= 4, segments[2].lowercased() == "pull", let number = Int(segments[3]) else { return nil }
        let owner = segments[0].lowercased(), repo = segments[1].lowercased()
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return "github.com/\(owner)/\(repo)/pull/\(number)"
    }

    /// The deterministic, UUID-shaped session id Work42 derives for `(project, task)`.
    static func derivedSessionId(project: String, task: String) -> String {
        let digest = SHA256.hash(data: Data("\(project)::\(task)".utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let s = Array(hex)
        return [String(s[0..<8]), String(s[8..<12]), String(s[12..<16]), String(s[16..<20]), String(s[20..<32])].joined(separator: "-")
    }
}

// MARK: - Formatting

nonisolated enum Todo42Format {

    /// `YYYY-MM-DD` in the local calendar for `date`.
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func date(fromDay day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }

    /// An ISO8601 timestamp with or without fractional seconds.
    static func parseISO(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// "HH:mm\u{2013}HH:mm" for a slot, or nil when its times do not parse.
    static func slotRange(_ slot: Todo42Slot) -> String? {
        guard let start = parseISO(slot.start), let end = parseISO(slot.end) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: start))\u{2013}\(formatter.string(from: end))"
    }

    /// A due date as "Jun 6, 2026"; the raw text when it does not parse.
    static func dueLabel(_ day: String) -> String {
        guard let date = date(fromDay: day) else { return day }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// "5.5h", "2h", "45m": the minute total as the donut and chips show it. Negative clamps to zero.
    static func minutes(_ total: Int) -> String {
        let clamped = max(0, total)
        if clamped < 60 { return "\(clamped)m" }
        let hours = Double(clamped) / 60
        return hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
    }

    /// The host of an https link, without "www.", cut to 28 characters.
    static func host(_ link: String) -> String {
        guard let host = URL(string: link)?.host else { return link }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return bare.count > 28 ? String(bare.prefix(28)) + "\u{2026}" : bare
    }
}
