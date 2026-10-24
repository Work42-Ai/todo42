---
name: widget-my-planned-day
description: |
  How the My Planned Day widget (kindId widget:my-planned-day) works. It shows one day's briefing from the todo42
  store: the summary, the day-structure donut and the To-Dos scheduled for that day. Use it to understand what the
  user sees and which `todo42 planned-day` / `todo42 todos` verbs produce it.
---

# My Planned Day widget

One day at a time, with its own previous / next / **Today** controls. It reads `todo42 planned-day show --json --date
<day>` every few seconds and shows, top to bottom:

1. the **summary** the daily-planning routine wrote (markdown; `task:<id>` links open the task);
2. the **day-structure donut** and legend (Focus, Reviews, Meetings, Personal, Free); the centre is real work
   (Focus + Reviews + Meetings). It is hidden when the briefing has no `dayStructure` or every category is zero;
3. the **To-Dos for the day**: those with a slot on that day or, with no slot, due that day. Tick one to complete it.

With no briefing for the day it says so and points at the daily-planning routine or the agent.

The widget never writes the plan. The briefing is written by the `planned-day` skill (`todo42 planned-day set`), and the
day's schedule is the To-Dos' own slots (`todo42 todos update <id> --slot …`).

## When todo42 is missing

The widget says "todo42 is not installed". Ask the user whether to install it (never without their yes), then follow the
`todo42-setup` skill.
