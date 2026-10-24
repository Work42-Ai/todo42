// main.swift — the todo42 command line.
//
//   todo42 todos add|list|update|complete|reopen|remove
//   todo42 planned-day set|show|last|list|clear
//
// Dispatch is explicit so a thrown `W42ExitError` becomes the shell exit code (ArgumentParser would
// otherwise collapse every thrown error to 1); parse errors, --help and --version go through ArgumentParser.

import ArgumentParser
import Foundation

/// The release version. `scripts/release.sh <version>` refuses to run when this disagrees with its argument.
let todo42Version = "0.1.0"

struct Todo42Command: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "todo42",
        abstract: "Work42 To-Dos and Planned Day, from the command line.",
        discussion: """
            To-Dos are a flat, timeless collection per project (a title, optional time slots, an optional
            link, an explicit completion). The planned day is the once-per-day briefing an agent writes:
            a summary and a day structure. Data lives in ~/.work42/todo42/projects/<slug>/store.db.
            Every verb takes --project <slug|path> (default: the project at or above the working
            directory) and --json.
            """,
        version: todo42Version,
        subcommands: [TodosCommand.self, PlannedDayCommand.self]
    )
}

do {
    var command = try Todo42Command.parseAsRoot()
    try command.run()
    Foundation.exit(W42ExitCode.ok)
} catch let error as W42ExitError {
    Foundation.exit(error.code)
} catch {
    Todo42Command.exit(withError: error)
}
