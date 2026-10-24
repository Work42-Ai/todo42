// DerivedSessionId.swift - Deterministic (project, taskId) → session id.
//
// Two requests with the same `(projectId, taskId)` always produce the
// same string. Used as the directory name under
// `<ownerDir>/chat/sessions/<id>/` so opening the same task on the same
// project always lands on the same on-disk session — no random UUIDs
// stored at task-creation time, no "No session yet" empty state when a
// task was created via the CLI rather than the app UI.
//
// Output is UUID-shaped (`8-4-4-4-12` lowercase hex) so it slots
// straight into existing ChatSession naming without any format-detection
// special cases. It is NOT a real UUID — no version/variant bits — but
// any code that just treats the id as an opaque string-of-hex-with-
// dashes is happy.

import CryptoKit
import Foundation

public nonisolated enum DerivedSessionId {

    /// Deterministic session id for `(projectId, taskId)`. Same inputs
    /// always produce the same output. The components are joined with
    /// `::` (a separator that never appears in either a project slug or
    /// a task id) so we don't get collisions from concatenation.
    public static func make(projectId: String, taskId: String) -> String {
        let key = "\(projectId)::\(taskId)"
        let digest = SHA256.hash(data: Data(key.utf8))
        let bytes = Array(digest.prefix(16))
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        // hex is 32 chars; carve into 8-4-4-4-12.
        let s = Array(hex)
        return [
            String(s[0..<8]),
            String(s[8..<12]),
            String(s[12..<16]),
            String(s[16..<20]),
            String(s[20..<32]),
        ].joined(separator: "-")
    }
}
