// Work42Link.swift — the internal `work42://` deep-link grammar
// (feat/planning-generic-block-events-instead-of-first.4).
//
// A To-Do's `url` carries its behavior. Internal `work42://` links resolve to
// an in-app surface; everything else (https, file, the `task:` summary scheme)
// routes through the existing Open Link path. The three internal shapes:
//
//   work42://task/<id>                 → the task's session (id may contain
//                                        "/", e.g. "feat/foo").
//   work42://code-review?pr=<web-url>  → the PR's code-review session
//                                        (created-or-opened idempotently).
//   work42://session/<id>              → an existing session by id.
//   work42://session/<id>/artifact/<artifact-id>
//                                      → that session, with that artifact shown
//                                        in its Artifacts widget (the form a
//                                        spec published to Linear links back
//                                        with). The session id may contain "/";
//                                        the LAST "/artifact/" splits the link.
//
// These links are IDEMPOTENT by construction: the resolver derives a stable
// session id from the link, so opening the same link twice lands on the same
// session (open == create). This file owns ONLY the pure parsing — the URL →
// case classification, the GitHub PR-URL parse, the stable PR key, and the
// git-remote owner/repo parse. No app state, no I/O — unit-testable in
// isolation. The app-side resolution (materializing sessions) lives in
// Work42App.

import Foundation

/// A classified internal link (or `.external` for anything the Open Link path
/// should handle unchanged).
public nonisolated enum Work42Link: Equatable {
    /// `work42://task/<id>` — open the task's session.
    case task(id: String)
    /// `work42://code-review?pr=<web-url>` — open (creating if needed) the PR's
    /// code-review session. Carries the raw `pr` value (a GitHub web URL).
    case codeReview(prURL: String)
    /// `work42://session/<id>` — open that exact session.
    case session(id: String)
    /// `work42://session/<id>/artifact/<artifact-id>` — open that session and show the artifact.
    case artifact(sessionId: String, artifactId: String)
    /// Not an internal work42 link (https, file, `task:`, or a malformed
    /// work42 URL) — the caller routes it via the existing Open Link path.
    case external

    /// Classify a URL string. A non-`work42` scheme, or a work42 URL with an
    /// unknown host / missing required part, yields `.external`.
    public init(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed),
              comps.scheme?.lowercased() == "work42" else {
            self = .external
            return
        }
        switch comps.host?.lowercased() {
        case "task":
            let id = Self.pathTail(comps.path)
            self = id.isEmpty ? .external : .task(id: id)
        case "code-review":
            if let pr = comps.queryItems?.first(where: { $0.name == "pr" })?.value,
               !pr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self = .codeReview(prURL: pr)
            } else {
                self = .external
            }
        case "session":
            let tail = Self.pathTail(comps.path)
            if tail.isEmpty {
                self = .external
            } else if let marker = tail.range(of: "/artifact/", options: .backwards) {
                let sessionId = String(tail[..<marker.lowerBound])
                let artifactId = String(tail[marker.upperBound...])
                self = (!sessionId.isEmpty && Self.isValidArtifactId(artifactId))
                    ? .artifact(sessionId: sessionId, artifactId: artifactId)
                    : .external
            } else {
                self = .session(id: tail)
            }
        default:
            self = .external
        }
    }

    /// An artifact id: `[a-z0-9][a-z0-9-]*` (the same rule `Artifact` enforces on disk).
    private static func isValidArtifactId(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first,
              ("a"..."z").contains(first) || ("0"..."9").contains(first)
        else { return false }
        return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// The path with a single leading slash removed — the task/session id
    /// (which may itself contain slashes, e.g. `feat/foo`).
    private static func pathTail(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }
}

// MARK: - GitHub PR parsing

public extension Work42Link {

    /// Parse a GitHub PR **web** URL into `(owner, repo, number)`, or nil when
    /// it is not a `github.com/<owner>/<repo>/pull/<N>` URL. Owner/repo are
    /// lower-cased; a trailing `/files`, query, or fragment is ignored.
    static func parseGitHubPR(_ urlString: String) -> (owner: String, repo: String, number: Int)? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed),
              let host = comps.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        // ["owner", "repo", "pull", "N", …]
        guard parts.count >= 4,
              parts[2].lowercased() == "pull",
              let number = Int(parts[3]) else { return nil }
        let owner = parts[0].lowercased()
        let repo = parts[1].lowercased()
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return (owner, repo, number)
    }

    /// A STABLE, normalized key for a PR web URL — `github.com/<owner>/<repo>/pull/<N>`
    /// (lower-cased, query/fragment/`/files` stripped) — so `…/pull/42` and
    /// `…/pull/42/files#L10` map to the SAME code-review session. Nil when the
    /// input is not a GitHub PR URL.
    static func normalizedPRKey(_ urlString: String) -> String? {
        guard let pr = parseGitHubPR(urlString) else { return nil }
        return "github.com/\(pr.owner)/\(pr.repo)/pull/\(pr.number)"
    }

    /// Parse a git remote URL into `(owner, repo)` (lower-cased), or nil for a
    /// non-GitHub remote. Handles the three forms:
    ///   git@github.com:owner/repo.git        (SSH shorthand)
    ///   https://github.com/owner/repo(.git)  (HTTPS)
    ///   ssh://git@github.com/owner/repo.git  (SSH explicit)
    static func parseGitHubOwnerRepo(_ remoteURL: String) -> (owner: String, repo: String)? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // SSH shorthand: git@github.com:owner/repo.git
        let sshPrefix = "git@github.com:"
        if trimmed.hasPrefix(sshPrefix) {
            return splitOwnerRepo(String(trimmed.dropFirst(sshPrefix.count)))
        }
        guard let comps = URLComponents(string: trimmed),
              let host = comps.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else { return nil }
        return splitOwnerRepo(comps.path)
    }

    /// Split `"owner/repo(.git)(/)"` (with or without a leading slash) into a
    /// lower-cased `(owner, repo)`; nil unless there are exactly two segments.
    private static func splitOwnerRepo(_ raw: String) -> (owner: String, repo: String)? {
        var path = raw
        if path.hasPrefix("/") { path.removeFirst() }
        if path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let owner = parts[0].lowercased()
        let repo = parts[1].lowercased()
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return (owner, repo)
    }
}
