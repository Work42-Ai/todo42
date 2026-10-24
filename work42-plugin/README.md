# todo42 plugin

Install: `work42 plugin install https://github.com/Work42-Ai/todo42 --path work42-plugin`, then ask the agent to set
todo42 up (the `todo42-setup` skill installs the signed CLI and checks your To-Dos came across).

The To-Dos and Planned Day vertical, extracted from Work42 into a first-party plugin (WOR-382). The plugin is **UI +
orchestration only**; the data and every write go through the standalone [`todo42` CLI](../) (same repository, own
signed release). The only contract between them is that CLI: verbs in, JSON and exit codes out.

## Contributions

| Kind | What |
|------|------|
| **Widget** `todos` | The whole To-Dos collection: add, tick, rename, set or clear a date and a link, unschedule a slot, delete. |
| **Widget** `my-planned-day` | The day's summary, the day-structure donut and the To-Dos scheduled for it, with date navigation. |
| **Background agent** (on `todos`) | Every 12 hours: asks Work42's `work42-session` tools which linked sessions are archived, then runs `todo42 todos sweep` to archive their To-Dos and purge archived ones older than `archive.autoArchiveHours` (at least 24 h; never when the setting is Never). |
| **Skill** `planned-day` | What the daily-planning routine follows to build the day. |
| **Skill** `todo42-setup` | Installs and updates the CLI. |

## Building

The widgets compile at install time against the shipped Widget SDK (`sdk_version: 2.8.0`, ABI 13). Shared Swift
sources live once in `shared/` and are copied next to each widget's `Widget.swift` by `scripts/sync-shared.sh`
(`--check` fails when a copy has drifted).
