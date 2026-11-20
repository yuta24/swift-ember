---
name: swift-ember
description: Use swift-ember from Claude Code to hot reload Swift edits in a running Debug app. Use when iterating on SwiftUI or UIKit, checking a save on an iOS Simulator or device, or diagnosing a rejected patch or rebuild request.
---

# swift-ember

Work in the target app's repository. Use the background watcher to check
Swift edits in the existing Debug process, then verify the affected behavior.
See [reference.md](reference.md) for topic details.

## Before editing

1. Run `command -v swift-ember`. If missing, ask the user to install the CLI
   and add it to PATH. Use the swift-ember README's installation instructions.
2. Identify the project or workspace, scheme, Debug configuration, watched
   source directories, and destination. Read the app's run instructions and
   any existing `.swift-ember.json`.
3. Build and launch the same Debug app on the selected destination using the
   project's normal procedure. If a configured build is already running, use
   it. Start from source matching the running build.
4. Run `swift-ember doctor` with the same target arguments that you will use
   for `start`. Look for `Ready.` and check any module warnings. If the
   README's **Set Debug Build Settings** are missing, ask the user to set
   them and rebuild. A passed doctor checks the build and destination.
   Confirm the running runtime separately from the watcher log.

## Start and identify the session

Use the same working directory for each Bash call. Each call starts a fresh
shell. Repeat the target arguments and substitute the actual paths and UDID
in each command.

```sh
xcrun simctl list devices booted
swift-ember doctor --project App.xcodeproj --scheme App --configuration Debug \
  --sources Sources --simulator 'SIMULATOR_UDID' --derived-data-path .build-xcode
swift-ember status --project App.xcodeproj --scheme App --configuration Debug \
  --sources Sources --simulator 'SIMULATOR_UDID' --derived-data-path .build-xcode
swift-ember start --project App.xcodeproj --scheme App --configuration Debug \
  --sources Sources --simulator 'SIMULATOR_UDID' --derived-data-path .build-xcode
```

- Use `--workspace App.xcworkspace` for a workspace. Match
  `--derived-data-path` to the build's `-derivedDataPath` when you use one.
- Use `--simulator <UDID>` and keep it on every command. Without it, one
  booted Simulator is picked and both `start` and `status` show its UDID. For an
  authorized physical device use `--device <CoreDevice-ID>` instead.
- If project configuration supplies the target, keep using it consistently.
  Explicit project/workspace plus scheme bypasses automatic config discovery.
  Pass `--config <path>` to use both.
- Use `start` for a background session. `watch` runs in the foreground.
  If `status` shows a running daemon, check who owns it before taking over.
  Save the PID and log path printed by `start`. Wait for the successful
  `connected  pid <app-pid>, <app-identifier>` line before editing. Read
  [sessions](references/sessions.md) for startup and target selection.
- With several worktrees or agents, use one Simulator or device per
  worktree. Pick one that no other session uses, or ask the user. Read
  [parallel sessions](references/sessions.md#parallel-worktrees-and-agents)
  before starting.
- If an error names a denied localhost socket, `.ember` path, or app container,
  give the exact error to the user. See [sandbox](references/sandbox.md).

## Save, read the result, check the app

1. Before editing, save the exact log path printed by `start` and the first
   unread line to a file. Save one coherent change.
2. Run the [bounded log wait](references/logs.md#wait-for-a-save) in one Bash
   call. It checks only new lines and stops after 30 seconds. A small body
   edit often finishes in a few seconds.
3. `hot reloaded ... (gN)` with the expected declaration means the runtime
   acknowledged the image. Read any `not verified` or `already ran` lines
   before deciding how to check behavior.
4. A diagnostic starts with a stage such as `[CLASSIFY] Cart.swift`, followed
   by its reason and an `Action:` line. `Action: full rebuild required.`
   means rebuild and relaunch the Debug app, then start a fresh watcher.
   If the project opted in to `rebuildCommand`, follow its reported
   recovery instead. See [reloadability](references/reloadability.md).
5. Check the affected behavior after the acknowledgement. If available, use
   the device-relay skill with `relay screenshot --scale 1` and
   `relay source --format compact` on the same destination. Otherwise, for
   a Simulator use `xcrun simctl io 'SIMULATOR_UDID' screenshot after.png` and
   inspect the image. See [screen checks](references/screen-checks.md).

## Guardrails and cleanup

- Keep hot-reload flags and scheme actions scoped to Debug. Ask the user to
  make any needed Build Settings or scheme changes.
- SwiftUI tree changes require a built `@ObserveEmber` and outermost
  `.emberable()`. If missing, use the normal build workflow.
- When done, check the watcher PID against the one you started, run
  `swift-ember stop` with the same target arguments, and confirm
  `daemon             not running` with `status`. Uninstall an app only if
  it was absent before you installed it, since that deletes its data. Do not
  shut down a Simulator you did not boot.
- Keep `.ember/` and generated captures out of commits.
