# Sessions and Debug setup

Use the app's existing build and run procedure. Run `doctor`, `status`, and
`start` with the same project/workspace, scheme, Debug configuration,
destination, source roots, and DerivedData as applicable. Source roots default
to the project's `SRCROOT`. Use comma-separated `--sources` for multiple roots
or the configured source list, including any local package you plan to edit.
The nearest `.swift-ember.json` can supply these settings when you omit an
explicit project/workspace plus scheme (or an explicit `--context`).

## Preflight

Check the official README section **Set Debug Build Settings**. The app target
needs `-Onone`, Enable Testability, and the following Debug Other Swift Flags.

```text
$(inherited) -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports
```

The runtime must be linked and started by the app. With the package's Debug
products, the runtime enables itself at compile time. Set the app's Debug
`EMBER_ENABLED` only if its own code uses the condition or compiles the runtime
sources directly. Local package targets need their own flags, since app target
settings do not propagate into them. Check the selected binary's exported keys,
watched modules, and private imports with `doctor`. If setup is missing, give
the user the failing checks and ask for the Debug setup and a new build. Keep
Release settings and the user's schemes intact.

For a terminal-managed Simulator build, use the same UDID and DerivedData
directory throughout. If the repo already has an equivalent procedure, use it.
Substitute the selected UDID, project paths, and bundle ID in each Bash call.

```sh
xcrun simctl list devices booted
xcodebuild -project App.xcodeproj -scheme App -configuration Debug \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' -derivedDataPath .build-xcode build
xcrun simctl install 'SIMULATOR_UDID' '.build-xcode/Build/Products/Debug-iphonesimulator/App.app'
xcrun simctl launch 'SIMULATOR_UDID' 'com.example.App'
```

Match the installed `.app` and its `CFBundleIdentifier` to the build. Pass
`--derived-data-path .build-xcode --simulator 'SIMULATOR_UDID'` to the Ember commands.
If you need to boot a Simulator, choose an existing destination with
`xcrun simctl list devices available` and wait with
`xcrun simctl bootstatus 'SIMULATOR_UDID' -b`. For an authorized device, find the
CoreDevice identifier with `xcrun devicectl list devices`, then use
`--device <CoreDevice-ID>`. The Debug app and patch need the same Development
signing team. Keep the device unlocked and the app foreground-runnable.

## Startup and stop

`status` resolves the build context and reports the daemon PID, target, binary
and sources. `start` prints `started            pid …` or `already running pid …`
and the exact `log` path. A successful start means the watcher is listening.
Use the actual printed path in a separate Bash call, for example
`tail -n 40 '/absolute/path/from/start.log'`.
Wait for the accepted runtime connection before editing. If you see
`connected  pid …, but …`, read the following lines for a build mismatch.
On a Simulator, `simctl launch` prints `<bundle-id>: <app-pid>`. Compare that
PID with the PID in the successful connection line. The PID printed by
`swift-ember start` belongs to the watcher and is used for cleanup.

On startup failure or the default 60-second background startup timeout, read
the log path and latest `[STARTUP]` stage from the error. If a runtime connection
is missing, confirm the app is installed and foreground on the selected
destination, and that it is running the same Debug build. A missing source
manifest warning means edits made between the build and watcher startup cannot
be verified. If there were any, rebuild and relaunch with the current sources
before starting over.
For a denied socket, app container, or `.ember` path, see [sandbox](sandbox.md).

When finished, stop only the session you started. Use the same project,
workspace or context, scheme, configuration, and destination arguments as
`start`. These select the session record. A different explicit Simulator,
including switching between explicit and implicit selection, changes the
session. `stop` works even if the selected build is now unavailable.
It says `stopped            pid …` or `not running` and leaves the log for
inspection. Confirm the session with `status` if the build is still available.

```sh
swift-ember stop --project App.xcodeproj --scheme App --configuration Debug \
  --sources Sources --simulator 'SIMULATOR_UDID' --derived-data-path .build-xcode
swift-ember status --project App.xcodeproj --scheme App --configuration Debug \
  --sources Sources --simulator 'SIMULATOR_UDID' --derived-data-path .build-xcode
```

## Parallel worktrees and agents

Each worktree keeps its own `.ember/` beside its project, with separate
session records, logs, locks, and patches. `status` and `stop` see only the
current worktree's sessions. Two worktrees can hot reload the same bundle ID
at the same time when each uses its own Simulator. Stopping one leaves the
other running.

- Use one Simulator or device per worktree or agent. Give each worktree its
  own DerivedData. Install each build only on its own Simulator.
- Pass `--simulator 'SIMULATOR_UDID'` to every `doctor`, `status`, `start`,
  and `stop`, even when only one Simulator is booted. Do not mix it with
  implicit selection.
- Choose a Simulator that no other session is using. If you cannot tell,
  ask the user which one to use.
- Before editing, compare the PID in the watcher log's
  `connected  pid <app-pid>, <bundle-id>` line with the PID that your
  `simctl launch` printed. `started` and `daemon running` only describe the
  watcher.
- Stop only the watcher you started. Run `stop` from the same worktree and
  check that it prints the watcher PID that your `start` printed.
- Do not shut down a Simulator that you did not boot.
- Before installing, check whether the app is already on the Simulator.
  `simctl uninstall` deletes the app's data container, so uninstall at the
  end only if the app was absent before you installed it. If it was already
  there, leave it installed, or ask the user before removing it and its data.
  A previous run's app can remain on the Simulator.

```sh
xcrun simctl get_app_container 'SIMULATOR_UDID' 'com.example.App' data
# Exit status 0 means it was already installed. Record that before installing.
```

```sh
xcrun simctl uninstall 'SIMULATOR_UDID' 'com.example.App'
```

### Implicit selection

Without `--simulator`, `start` picks one booted Simulator even when several
are booted. `status` then shows `transport simulator` without the UDID, so
you cannot tell which one was picked. A `status` or `stop` with a different
explicit UDID can still find that implicit session. It can show it as
running or stop it, for example `not running` followed by
`stopped            pid …`. An implicit `status` does not see a session
started with an explicit UDID.

### Shared Simulator and bundle ID

Two watchers on the same Simulator and bundle ID both start with exit code 0
and no warning, and both show as running in `status`. They overwrite the
port in the app container's `Documents/splice-session.json`, so the app
connects to only one of them. Symptoms:

- Edits from the other watcher end with `no app is connected` and
  `Action: restart the app.`
- A watcher can reject the other worktree's app with
  `connected  pid …, but this is not the build being watched`.
- Installing the other worktree's build on the same Simulator terminates
  the running app.

To recover, stop one of the watchers from its own worktree and confirm
`not running` with `status`. Install and launch the remaining worktree's
build again, then wait for its `connected  pid …` line and compare the PID.
To keep both running, move one worktree to its own Simulator. Install its
build there, and restart its watcher with that `--simulator`.
