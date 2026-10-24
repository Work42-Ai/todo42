// Output.swift — exit codes and stdout/stderr helpers shared by every todo42 verb.
//
// Machine-readable results go to stdout (`--json`); diagnostics go to stderr, so a script that pipes stdout
// never sees an error message mixed into its JSON.

import Foundation

nonisolated enum W42ExitCode {
    static let ok: Int32 = 0
    static let usage: Int32 = 64
    static let failure: Int32 = 1
}

/// A thrown error carrying a shell exit code. `main.swift` maps it to `exit(code)` after the command has
/// already printed its human-readable message.
nonisolated struct W42ExitError: Error {
    let code: Int32
    init(_ code: Int32) { self.code = code }
}

/// Write a line to stderr.
nonisolated func errPrint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

/// Pretty-print a `Codable` value as JSON to stdout with stable key ordering, then a trailing newline.
nonisolated func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    if let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}
