---
name: todo42-setup
description: |
  Install and set up the todo42 command-line tool: download the signed release, install it as ~/.work42/todo42.app with the command linked into ~/.work42/bin, verify it, and carry over the To-Dos Work42 kept before todo42 existed. Use it whenever `command -v todo42` prints nothing, a todo42 command fails because the tool is missing or too old, the To-Dos or My Planned Day widget says todo42 is not installed, or the user asks to set up or update todo42.
---

# todo42-setup — install and set up todo42

todo42 is a separate, signed and notarized command-line tool (github.com/Work42-Ai/todo42), not part of the
Work42 app. This plugin's widgets and the `planned-day` skill call it. **Always ask the user first.** Before
installing or updating anything, tell them what you are about to do (download the signed todo42 app from
github.com/Work42-Ai/todo42 into `~/.work42` and link it into `~/.work42/bin`) and wait for a yes. If they decline,
stop and carry on without todo42; do not install it later on your own. Then follow these steps in order and stop at
the first one that fails; say what failed instead of working around it.

## 1. Install or update the tool

1. Check what is there: `command -v todo42 && todo42 --version`. `~/.work42/bin` is on `PATH` in Work42 sessions.
   If it prints a version, only continue with this step to update; otherwise install.
2. Download, verify and install the latest release:

   ```bash
   mkdir -p ~/.work42/bin && cd "$(mktemp -d)"
   curl -fsSLO https://github.com/Work42-Ai/todo42/releases/latest/download/todo42.zip
   curl -fsSLO https://github.com/Work42-Ai/todo42/releases/latest/download/todo42.zip.sha256
   shasum -a 256 -c todo42.zip.sha256
   ```

   `shasum` must print `todo42.zip: OK`. If it does not, stop and tell the user; do not install the file.
3. Unpack it (it is a small app bundle, `todo42.app`) and check it is signed by Work42's Developer ID before
   trusting it:

   ```bash
   ditto -x -k todo42.zip .
   codesign --verify --deep --strict todo42.app
   codesign -dv --verbose=2 todo42.app 2>&1 | grep -E "Identifier=com.work42.todo42|TeamIdentifier=74RFQFPVQ9"
   ```

   Both `Identifier` and `TeamIdentifier` lines must print and `--verify` must print nothing. If not, stop and
   tell the user.
4. Put the app in place and link the command:

   ```bash
   rm -rf ~/.work42/todo42.app && mv todo42.app ~/.work42/todo42.app
   ln -sf ~/.work42/todo42.app/Contents/MacOS/todo42 ~/.work42/bin/todo42
   todo42 --version
   ```

## 2. Your existing To-Dos

todo42 needs no macOS permission. The first time it opens a project's store it copies the store Work42 used to keep
(`~/.work42/work42/projects/<slug>/store.db`) into `~/.work42/todo42/projects/<slug>/store.db`; the original stays
where it is. Check with `todo42 todos list --json` from inside the project: the To-Dos and planned days the user had
should be there. If the project cannot be resolved, pass `--project <slug|path>`.

## Done

Tell the user what is installed (`todo42 --version`) and, if they had To-Dos before, how many `todo42 todos list`
shows.
