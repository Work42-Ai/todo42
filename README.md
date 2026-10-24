# todo42

Work42's To-Dos and Planned Day as a small command-line tool for macOS: a flat, timeless collection of To-Dos (a title,
optional time slots, an optional link, an explicit completion) and a once-per-day briefing an agent writes (a summary and a
day structure). Any agent or script can drive it, and it ships with an optional
[Work42](https://github.com/work42-ai/work42) plugin that puts it inside Work42.

Everything stays on your Mac, in `~/.work42/todo42/projects/<slug>/store.db`, one store per Work42 project.

## Install

todo42 is a small signed, notarized app bundle (`todo42.app`, no window and no Dock icon; the command-line tool is its
executable). Download the latest release, check its checksum, put the app in `~/.work42` and link the command into
`~/.work42/bin` (Work42 puts that folder on `PATH` for its agent sessions and widget commands):

```bash
mkdir -p ~/.work42/bin && cd "$(mktemp -d)"
curl -fsSLO https://github.com/Work42-Ai/todo42/releases/latest/download/todo42.zip
curl -fsSLO https://github.com/Work42-Ai/todo42/releases/latest/download/todo42.zip.sha256
shasum -a 256 -c todo42.zip.sha256          # must print: todo42.zip: OK
ditto -x -k todo42.zip .
rm -rf ~/.work42/todo42.app && mv todo42.app ~/.work42/todo42.app
ln -sf ~/.work42/todo42.app/Contents/MacOS/todo42 ~/.work42/bin/todo42
todo42 --version
```

todo42 needs no macOS permission.

## Use

```bash
todo42 todos add --title "Renew SSL cert" --due 2026-06-11
todo42 todos add --title "Review PR #42" --url "work42://code-review?pr=https://github.com/org/repo/pull/42"
todo42 todos list --open --json
todo42 todos update <id> --slot 2026-06-06T09:00:00Z/2026-06-06T11:00:00Z   # schedule it
todo42 todos update <id> --due ""                                           # clear a field
todo42 todos update <id> --no-slots                                         # unschedule
todo42 todos complete <id>
todo42 planned-day set briefing.json        # {"date": …, "generatedAt": …, "summary": …, "dayStructure": {…}}
todo42 planned-day show --json              # today's briefing with the To-Dos scheduled for it
```

Every verb takes `--project <slug|path>` (default: the Work42 project at or above the working directory, found
through `~/.work42/task42/projects.json`, git worktrees included) and `--json`. Errors go to stderr as
`error:` / `suggestion:`; exit codes are 0 (ok), 64 (bad usage) and 1 (failure).

The link on a To-Do carries its behaviour: `work42://task/<id>`, `work42://code-review?pr=<url>`,
`work42://session/<id>`, an `https://` URL, or nothing.

`todo42 todos sweep` is the archive pass the Work42 plugin runs on a timer: the caller names the archived task and session
ids, the To-Dos linked to them are marked archived, and with `--purge-after-hours` older archived ones are deleted.

### Coming from Work42

Work42 used to keep this data in `~/.work42/work42/projects/<slug>/store.db`. The first time todo42 opens a project it copies
that file to its own location with SQLite's backup API; the original is left where it is. Anything written afterwards goes to
the new file only.

## The Work42 plugin

`work42-plugin/` is the Work42 plugin: the **To-Dos** and **My Planned Day** widgets, a background agent that archives To-Dos
whose linked session is archived, the `planned-day` skill the daily-planning routine follows, and `todo42-setup`. Install it
from this repository:

```bash
work42 plugin install https://github.com/Work42-Ai/todo42 --path work42-plugin
```

then ask the agent in any Work42 session to set up todo42.

## Develop

```bash
swift build --product todo42        # debug build
swift test                          # unit tests
scripts/build-todo42.sh             # release build, signed when DEVELOPER_ID is set
scripts/sync-shared.sh --check      # the plugin's shared Swift files are copied into each widget
```

## Release

```bash
cp .env.release.example .env.release.local      # fill in your Developer ID and notary profile
scripts/release.sh 0.1.0 --check                # what is ready, what is blocked
scripts/release.sh 0.1.0                        # build, sign, notarize a candidate in dist/0.1.0
scripts/release.sh 0.1.0 --publish              # create GitHub release v0.1.0 with the two assets
```

The version is the `todo42Version` constant in `Sources/todo42/main.swift`; the release script refuses to run if it disagrees
with the version you pass.

## Origin

Extracted from [`work42`](https://github.com/Work42-Ai/work42) (`Flow42Core` To-Dos and planned-day store, its todos and
planned-day commands, and the Home To-Dos and Overview widgets).

## License

MIT, see [LICENSE](LICENSE).
