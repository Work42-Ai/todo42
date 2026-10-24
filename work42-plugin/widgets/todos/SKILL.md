---
name: widget-todos
description: |
  How the To-Dos widget (kindId widget:todos) works. It shows the project's whole To-Dos collection and reads and
  writes it through the `todo42` CLI. Use it to understand what the user sees when they tick, rename or date a To-Do,
  and which `todo42 todos` verb an agent should use for the same change.
---

# To-Dos widget

The project's whole To-Dos collection in one flat list, in the store's order (ticking a row never moves it). The
widget does nothing the CLI cannot do; it polls `todo42 todos list --json` every few seconds, so a To-Do added by an
agent shows up on its own.

| In the widget | The same change from an agent |
|---|---|
| **+** (or the empty state) adds a row; Return adds and keeps adding | `todo42 todos add --title "…" [--url …] [--due YYYY-MM-DD]` |
| the circle ticks or un-ticks | `todo42 todos complete <id>` / `todo42 todos reopen <id>` |
| click the title to rename | `todo42 todos update <id> --title "…"` |
| the **＋ Link** chip / the link chip | `todo42 todos update <id> --url "…"` (`--url ""` clears it) |
| **Set date… / Change date… / Clear date** (context menu) | `todo42 todos update <id> --due YYYY-MM-DD` (`--due ""` clears it) |
| the clock chip's ✕ | `todo42 todos update <id> --slot <startISO>/<endISO> …` (the full remaining set) or `--no-slots` |
| **Delete** (context menu) | `todo42 todos remove <id>` |

A To-Do whose link is `work42://task/<id>`, `work42://code-review?pr=<url>` or `work42://session/<id>` opens that session
when clicked and shows the session's workflow stage as a chip (asked of Work42's `work42-session` tools). An `https://`
link shows its host and opens through Work42's Open Link.

## When todo42 is missing

The widget says "todo42 is not installed". Ask the user whether to install it (never without their yes), then follow the
`todo42-setup` skill.

## Background agent

While a session or Home with this widget is live, an agent runs every 12 hours: it asks Work42 which of the sessions the
To-Dos link to are archived (`session_show` returns `archived_at`), then runs `todo42 todos sweep` to mark those To-Dos
archived and to delete archived ones older than the app's archive wait (at least 24 hours). It does nothing when the
archive wait setting is Never.
