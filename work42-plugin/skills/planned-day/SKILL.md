---
name: planned-day
description: |
  Build today's plan for the active workspace: from the TIMELESS To-Dos
  collection (sessions auto-create task/review To-Dos; you add the rest), PICK a
  few to do today and SCHEDULE work windows for them, then author a short
  summary + a day-structure donut and commit it. Invoke when the
  daily-planning routine fires or when I say "plan my day now" / "build my
  planned day" / "what should I focus on today". You READ my real calendar
  (read-only, via meet42) only to find busy slots; you WRITE To-Dos + the
  day-level briefing to the todo42 store via the `todo42` CLI. You NEVER create, edit,
  or delete an event on my real calendar.
---

# planned-day — build the whole day plan

The plan is **events + To-Dos**. Real calendar events (via `meet42`,
read-only) are the fixed shape of the day; **To-Dos** are the things I need to
do — a **timeless** collection: each To-Do persists until it's done, it is NOT
"for a day". Planning a day mostly means **picking** a few existing To-Dos to
work on today and **scheduling** time for them — not creating dated items.

Two things create To-Dos for you already, so **don't duplicate**:
- **Sessions auto-create their To-Do.** Opening a task or a code-review session
  makes a linked To-Do automatically (`work42://task/<id>` /
  `work42://code-review?pr=<url>`). So most task/review To-Dos already exist —
  `todo42 todos list` first.
- **You add the rest** (`todo42 todos add`) — reminders, external links, and any
  PR-to-review that has no session yet.

Scheduling is metadata ON the timeless To-Do, not day-ownership:
- **`slots`** = the time windows I intend to WORK on it (→ calendar blocks).
  "Which To-Dos are for today" is *derived* — the ones with a slot today.
- **`dueDate`** = a DEADLINE (finish before this day), an independent axis.

## ⛔ THE ONE RULE: never touch my real calendar

You may have real-calendar tools available (Google Calendar `create_event`,
EventKit, …). Using ANY of them to add/move/delete an event is a hard failure.
The real calendar is **READ-ONLY**, via `meet42` only, to learn which slots are
busy. Everything you *schedule* is a **To-Do** (`todo42 todos …`) or the day
briefing (`todo42 planned-day set`) — work42's own state, never the real
calendar.

## The To-Do CLI, precisely

- **Create** (a NEW item — only when no session already made one):
  `todo42 todos add --title "<what>" [--url <link>] [--reason "<why>"] [--due <yyyy-MM-dd>]`
- **Schedule for today** (add work windows to an EXISTING timeless To-Do — this
  is the main planning act): `todo42 todos update <id> --slot <startISO>/<endISO> [--slot …]`.
  `--slot` is repeatable; **one To-Do can carry several slots** (worked morning +
  afternoon, or across days). `update --slot` REPLACES the slot set — pass the
  full list. Unschedule = `update` with no `--slot`.
- **List / complete / remove:** `todo42 todos list [--open|--done]`,
  `todo42 todos complete <id>` / `reopen <id>`, `todo42 todos remove <id>`.
- **`--url`** carries the behavior when the To-Do is clicked:
  - `work42://task/<session-id>` — opens (or resumes) the task's session.
  - `work42://code-review?pr=<GitHub PR URL>` — opens (creating on first click,
    idempotently) the code-review session for that PR.
  - `https://…` — opens the link (browser / claiming widget).
  - omit `--url` — a plain reminder, no navigation.
- Completion is explicit: I tick it, `todo42 todos complete <id>`, or the
  session link scratches a task To-Do when its task reaches Done. Never infer
  completion ad-hoc from a linked task's status.

## Do it in one pass, in this order

### 0 — Anchor: the last plan + what's happened since (ALWAYS first)

Answer two questions with real data:

```bash
todo42 planned-day last --json --project work42        # the LAST plan (not
                                                        # literally yesterday)
```

If a plan exists, read its `generatedAt`, then list every session with activity
since then — across ALL kinds:

```bash
sessions_list(since: "<lastPlan.generatedAt>", project: "work42")
```

For each returned session:

- **event / routine sessions** → read its `summary` to understand what happened.
- **task sessions** (type `task`) → read the session's `plan/subtasks`
  (`storage_get`) to see remaining subtasks
  and its derived stage, and judge how much time finishing it still needs.

**Prefer finishing in-flight work over starting new.** Carry forward the
still-open task/review To-Dos from the last plan; add new items only after
placing the carry-forwards and only if open time honestly remains. If no plan
is stored yet, plan from scratch.

### 1 — Gather what's on my plate (real data only)

- **tasks** — `sessions_list` (task-type sessions). Consider
  non-Done sessions that need MY hands today (In-Progress; startable Planning;
  Testing only if QA came back to me). A task in Human Review / waiting on
  others' review is BLOCKED ON OTHERS — no To-Do.
- **PRs awaiting my review, Jira board, etc.** — this is where YOUR prompt says
  what to fetch and how (e.g. "check my Jira board", "how many reviews are
  assigned to me on GitHub"). The platform doesn't hardcode sources — the
  routine prompt does. Fetch per the prompt; never invent items.

### 2 — Read the real calendar for busy slots (`meet42`, READ-ONLY)

```bash
meet42 today                 # each event: start, title, source
meet42 show '<event_id>'     # precise start–end + Source: <source> (<calendarTitle>)
```

Collect each real event as a `{start, end}` busy interval + its calendar
identity (for step 4). Real data only. If `meet42` can't read the calendar,
say so and treat the day as having no known events.

### 3 — Pick + schedule the day's To-Dos

Start from what ALREADY exists — sessions auto-created the task/review To-Dos:

```bash
todo42 todos list --open --json --project work42   # the timeless backlog
```

Then, for the few worth my time TODAY, add today's work windows (schedule =
add slots to the existing To-Do; find the id in the list above):

```bash
# Schedule an existing task To-Do for two stretches, fitted around real events:
todo42 todos update <id> \
  --slot 2026-06-06T09:00:00Z/2026-06-06T11:00:00Z \
  --slot 2026-06-06T14:00:00Z/2026-06-06T16:00:00Z --project work42

# Schedule a code-review To-Do for a short window:
todo42 todos update <id> --slot 2026-06-06T11:30:00Z/2026-06-06T12:00:00Z --project work42
```

Create a NEW To-Do only when nothing exists for it yet — e.g. a PR to review
that has no session, or a reminder / deadline:

```bash
todo42 todos add --title "Review PR #42 — fix auth race" \
  --url "work42://code-review?pr=https://github.com/org/repo/pull/42" \
  --reason "review requested" --project work42          # then schedule it as above
todo42 todos add --title "Renew SSL cert" --due 2026-06-11 --project work42   # a deadline
```

Rules:
- **Fit slots into genuinely open gaps** — never overlap a real event.
- **Soft cap ~8h of timed work/day.** Schedule the highest-value stretches; a
  24h canvas is not an invitation to pack it.
- **Prefer picking existing To-Dos over creating** — sessions already made the
  task/review ones. Don't duplicate; `todo42 todos list` first.
- **Timeless:** a To-Do you don't schedule today just stays in the backlog for
  another day — don't delete it, don't force a slot on it.
- **Empty is honest:** nothing worth scheduling → schedule nothing. Say so.

### 4 — Author the day-structure donut (`dayStructure`)

Five non-negative integer MINUTE totals over a full 24h day:

- **`meetings` / `personal`** — classify the step-2 real events BY CALENDAR: a
  work-calendar event → `meetings`; a personal one (sleep / workout / meal) →
  `personal`; unknown → `meetings`. Sum `end − start`; skip all-day/canceled.
- **`focus` / `reviews`** — from the To-Do slots you scheduled: task-linked
  slot minutes → `focus`; code-review-linked slot minutes → `reviews`.
- **`free` = max(0, 1440 − (focus + reviews + meetings + personal))`**.

### 5 — Compose a short summary (markdown, 2–4 sentences)

A tight hero paragraph. Reference tasks by bare id (`T-003` — auto-linked) and
PRs by number or `[text](url)`. Real data only; mention how the day is shaped.

### 6 — Write the day briefing (ONE `todo42 planned-day set`)

The briefing carries ONLY `date`, `generatedAt`, `summary`, and `dayStructure`
— **NOT** the schedule (the To-Dos are their own rows, written in step 3).

```bash
DATE="$(date +%F)"; NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > /tmp/planned-day.json <<JSON
{
  "date": "$DATE", "generatedAt": "$NOW",
  "summary": "Land **T-003** today — already in Testing. One PR to review. Two focus stretches around the 10am standup.",
  "dayStructure": { "focus": 300, "reviews": 30, "meetings": 30, "personal": 600, "free": 480 }
}
JSON
todo42 planned-day set /tmp/planned-day.json --project work42
```

`planned-day set` **rejects** a legacy `blocks`/`kind`/`ref` artifact — the
schedule lives in `todo42 todos`, not here. Write the file (not a heredoc pipe)
and call `set` exactly once. A minimal day (summary only, no dayStructure) is
valid.

---

## Honesty rules

- **Never the real calendar.** Schedule via `todo42 todos` + the day briefing.
  `meet42` is read-only, for busy slots only. (THE ONE RULE.)
- **Anchor on the last plan + actual activity.** Step 0 (`planned-day last` +
  `sessions list --since`) is mandatory — reflect on what happened, prefer
  finishing over starting.
- **Only real data.** Tasks from `Work42 sessions`; PRs/Jira per the prompt's sources;
  events from `meet42`. Never invent a task, PR, or event.
- **Pick + schedule existing To-Dos; don't duplicate.** Sessions auto-create
  task/review To-Dos — `todo42 todos list` first, schedule those; add only what
  has no To-Do yet. To-Dos are timeless — an unscheduled one just waits.
- **dayStructure is authored from real data**, classified by calendar;
  `focus`/`reviews` match your To-Do slots; `free = 1440 − rest`.
- **Fail loud, in words.** If `gh`/`meet42`/a source can't run, say so in the
  summary and degrade honestly — never guess.
- **Empty is fine.** Nothing qualifying → fewer/zero To-Dos. Say so.
