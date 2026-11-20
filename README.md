# swift-ember

[![CI](https://github.com/yuta24/swift-ember/actions/workflows/ci.yml/badge.svg)](https://github.com/yuta24/swift-ember/actions/workflows/ci.yml)

Apply Swift implementation changes to a running iOS Simulator or development-device app without
restarting it or losing its state.

Save a file, and the implementation you changed takes effect in the process
that is already running, with its heap, its navigation, and its login session
intact.

```
$ swift-ember watch --project App.xcodeproj --scheme App
watching examples/CounterApp/Sources
listening on 127.0.0.1:51237

connected  pid 8621, dev.swift-ember.CounterApp

hot reloaded 1 declaration in 511 ms  (g1)
  Cart.subtotalLabel()
classify                  19 ms
generate                   1 ms
compile                  348 ms
transfer                 111 ms
load                       32 ms
--------------------------------
total                    511 ms
```

There is no Swift interpreter here and no reimplementation of the language.
The installed Swift compiler does the compiling, the Swift runtime does the
dispatch, and dyld does the loading. What this project adds is the part in
between: deciding whether a change is safe to apply, writing the replacement,
and getting it into the process.

Status: **M5 of 5**, and it works against a real `.xcodeproj`. Bodies reload
end to end on Simulator and a physical iPhone --- overrides and `private` helpers among them ---
and the classifier's refusals are pinned by tests. SwiftUI `body` reloads too
when the View opts into a stable type-erasure boundary; an unannotated body is
still refused for a measured reason --- see below.
Read `PRD.md` for what is and is not promised.

A reload takes about 350 ms and, unlike a build, does not care how big your
project is. On a module of ten thousand declarations a full build takes 50
seconds and a patch still takes 352 ms.

## Installation

The host CLI and the in-app runtime use the same release. Install both before
configuring the project.

### Host CLI

Download the `0.4.0` binary and install it in `$HOME/.local/bin`:

```sh
version=0.4.0
curl -fL \
  "https://github.com/yuta24/swift-ember/releases/download/$version/swift-ember.zip" \
  -o swift-ember.zip
curl -fL \
  "https://github.com/yuta24/swift-ember/releases/download/$version/swift-ember.zip.sha256" \
  -o swift-ember.zip.sha256
shasum -a 256 --check swift-ember.zip.sha256
unzip swift-ember.zip
./swift-ember/install.sh "$HOME/.local"
```

Add `$HOME/.local/bin` to your shell's `PATH` if it is not already there, then
check the installation with `swift-ember --help`.

Each release also includes `swift-ember.artifactbundle.zip` for SwiftPM binary
targets and build-tool plugins. Normal command-line installation should use
`swift-ember.zip` above.

To build the host CLI from source instead:

```sh
git clone --branch 0.4.0 --depth 1 https://github.com/yuta24/swift-ember.git
cd swift-ember
swift build -c release --package-path Tools/swift-ember
mkdir -p "$HOME/.local/bin"
install -m 755 \
  "$(swift build -c release --package-path Tools/swift-ember --show-bin-path)/swift-ember" \
  "$HOME/.local/bin/swift-ember"
```

Use a release build of the host tool. Classification is SwiftSyntax parsing,
and unoptimised it costs fourteen times as much — enough to be most of the loop
on a large file. The host tool is a separate package so applications that add
the root package resolve no SwiftSyntax dependency.

### In-app runtime

In Xcode, choose **File > Add Package Dependencies**, enter
`https://github.com/yuta24/swift-ember.git`, and select **Up to Next Minor
Version** starting at `0.4.0`. Add `EmberRuntime` to a UIKit target, or
`EmberSwiftUI` to a SwiftUI target; `EmberSwiftUI` brings and re-exports the
runtime.

In another Swift package, declare the same dependency as:

```swift
.package(
    url: "https://github.com/yuta24/swift-ember.git",
    .upToNextMinor(from: "0.4.0")
)
```

### Claude Code

From your app's repository, run `swift-ember skill install` to copy the skill
to `.claude/skills/swift-ember`. Use `--global` for
`~/.claude/skills/swift-ember`. The skill guides Claude Code through Debug
preflight, background hot reload, verification, and cleanup.
See [agent skill installation](docs/agent-skill.md) for scopes and updates.

## Try it

Boot a simulator, then:

```
examples/CounterApp/demo.sh
```

It builds the app, starts the daemon, edits a method body, and screenshots
before and after. `examples/CounterApp/README.md` walks through what happened.

## Configuring your project

### Add the runtime

Add the [Ember package product](#in-app-runtime), import `EmberRuntime` for
UIKit or `EmberSwiftUI` for SwiftUI, and call `Ember.start()` once at launch.
The package compiles its active runtime only for Debug and provides an inert
entry point in Release.

A SwiftUI View whose `body` should reload adds two explicit boundaries:

``` swift
import EmberSwiftUI

struct ReceiptView: View {
    @ObserveEmber private var ember

    var body: some View {
        ReceiptContents()
            .emberable()
    }
}
```

The observer makes SwiftUI evaluate the replaced body after a patch, and the
outermost modifier pins the value SwiftUI stores to `AnyView`. Adding the two
lines changes the View's layout, so do it before launching the session and
rebuild once. The source file must import `EmberSwiftUI` directly so the
conservative classifier can prove that both names are this package's API. Both
opt-ins are no-ops in Release.

`Ember.start()` also decides what a UIKit app does when a patch lands. By
default it invalidates layout and reloads lists, which is what makes the edit
visible; `Ember.start(refresh: .none)` turns that off if the app would rather
do it itself.

### Set Debug Build Settings

In Xcode, select your app target, open **Build Settings**, and set these values
for **Debug** only. Append both flag pairs to any existing Other Swift Flags
and keep `$(inherited)` to preserve flags from the project.

| Xcode setting | Debug value | Reason |
| --- | --- | --- |
| Other Swift Flags (`OTHER_SWIFT_FLAGS`) | `-Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports` | Implicit dynamic makes declarations replaceable. Private imports let patches replace and refer to `private` and `fileprivate` declarations. Both are frontend options and each needs its own `-Xfrontend`. |
| Enable Testability (`ENABLE_TESTABILITY`) | `YES` | Exports the replacement keys for internal declarations so patches can bind to them. |
| Optimization Level (`SWIFT_OPTIMIZATION_LEVEL`, under Swift Compiler) | **No Optimization [-Onone]** | Replacement dispatch only survives without optimization. |

Add `EMBER_ENABLED` to the app target's Debug **Active Compilation Conditions**
only if the app's own code uses `#if EMBER_ENABLED` or you compile the runtime
sources directly. The package product enables its active runtime in Debug
through its manifest. Xcode does not pass the app target's conditions into
package targets. Ember forwards the app target's condition to patch
compilation so a patched body takes the same branch.

Configure each local Swift package you want to reload separately. Xcode does
not pass the app target's flags to package targets. See
[Making a Swift package patchable](integrations/xcode/Package.md).
Keep these settings out of Release and check the shipping build with
[`swift-ember doctor --release`](#checking-a-shipping-build).

### Configure the watcher (optional)

You can put your target, source roots, and exclusions in `.swift-ember.json`
beside the project or workspace, or supply them as command-line arguments.
Paths in the file are relative to the file, so it works across checkouts.

```json
{
  "workspace": "App.xcworkspace",
  "scheme": "App",
  "sources": [
    "Sources",
    "Packages/Feature/Sources"
  ],
  "exclude": [
    "Sources/Generated",
    "Sources/Legacy/DoNotWatch.swift"
  ],
  "sourceModules": {
    "Frameworks/Checkout/Sources": "CheckoutKit"
  }
}
```

`project` may be used instead of `workspace`. `configuration` defaults to
`Debug`, `sources` defaults to the app target's `SRCROOT`, and the nearest
`.swift-ember.json` is found by walking upward from the current directory (or
Xcode's `SRCROOT`). `exclude` accepts files or directories; a directory omits
its complete subtree from change monitoring. Excluded Swift sources may still
be read once when the watcher starts for cross-file safety validation. Paths
are relative to `.swift-ember.json`, just like `sources`. Command-line options
override the file, including `--exclude` for an explicit comma-separated list.
Unknown keys are rejected so a misspelled `sources` or `exclude` cannot silently
change what is watched.

`sourceModules` optionally maps paths relative to the configuration file to
Swift module names. A file or directory entry overrides automatic target
membership, and the most specific path wins. The mapping uses the Swift module
name (Xcode's `PRODUCT_MODULE_NAME`) and applies within the watched source roots.

For SwiftPM sources, Ember uses the files listed by `swift package describe`,
including custom target paths, source lists, and exclusions. For Xcode, it
uses the selected build's Swift compilation file lists. Build the watched
targets before running `doctor` or `watch`, and pass `--derived-data-path` if
the build used a custom DerivedData directory. Xcode dependencies in another
project can be listed in the scheme's Build action or mapped with
`sourceModules`. SwiftPM test targets and Xcode unit and UI test targets are
excluded from watching. Files with unknown or ambiguous membership produce a
warning in `doctor`. `doctor` still requires at least one watched module and
checks that each resolved module is patchable. Use `exclude` for other files
you do not intend to patch, such as package manifests. When a new file has
no entry in the build's source list, `watch` asks you to rebuild. `watch`
evaluates watched packages at startup, and `doctor` reuses the project's
SwiftPM manifest cache under `.ember/cache`.

`rebuildCommand` is optional and explicitly opts into automatic recovery for a
change that cannot be patched, such as adding a stored property. It runs through
`zsh -lc` from the configuration file's directory, must rebuild and relaunch the
app, and receives `SWIFT_EMBER_REBUILD=1`. The watcher accepts recovery only
after a different process connects and proves that it is running the new Mach-O
UUID, then discards every old patch generation and atomically adopts the exact
source snapshot used for that build. A command that only relaunches the old
binary is refused: the Mach-O UUID on disk must change. Sources are checked both
across the command and after the replacement process connects; a change reruns
the command up to three times so the baseline cannot absorb an edit the build
missed. SIGINT and SIGTERM stop the command's complete process group.
`rebuildTimeout` controls how long it waits for the replacement process and
defaults to 300 seconds.
Command-line equivalents are `--rebuild-command`, `--rebuild-directory`, and
`--rebuild-timeout`.

```json
{
  "rebuildCommand": "scripts/rebuild-and-launch.sh",
  "rebuildTimeout": 300
}
```

A complete explicit target (`--project`/`--workspace` together with `--scheme`,
or `--context`) bypasses automatic discovery. Pass `--config <path>` to use a
specific file anyway, or `--no-config` to disable discovery explicitly. A
manifest passed with `--context` and an Xcode project/workspace are separate
target modes and cannot be combined.

### Build, run, and watch

Select your app scheme and a Simulator in Xcode, then build and run the Debug
app. With the app running, open a terminal and run the following commands from
the project directory. Wait for `watch` to report a connection before editing
a method body.

```sh
swift-ember doctor --project App.xcodeproj --scheme App --sources Sources
swift-ember watch --project App.xcodeproj --scheme App --sources Sources
```

Use `--workspace App.xcworkspace` for a workspace. If you created
`.swift-ember.json`, Ember can discover the target and sources from it.

```sh
swift-ember doctor
swift-ember watch
```

`doctor` names missing settings and checks the built binary for replacement
keys. `watch` stays in the foreground. If you build with a custom DerivedData
directory, pass the same directory to both terminal commands.

```sh
xcodebuild -project App.xcodeproj -scheme App -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .build-xcode build
swift-ember doctor --project App.xcodeproj --scheme App --sources Sources \
  --derived-data-path .build-xcode
swift-ember watch --project App.xcodeproj --scheme App --sources Sources \
  --derived-data-path .build-xcode
```

When more than one Simulator is booted, select one by UDID. Without
`--simulator`, the watcher chooses one booted Simulator and warns when there
are several. It keeps using the selected UDID for the life of the watcher.

```sh
xcrun simctl list devices booted

swift-ember doctor --project App.xcodeproj --scheme App \
  --simulator <Simulator-UDID>
swift-ember watch --project App.xcodeproj --scheme App \
  --simulator <Simulator-UDID>
```

For a physical device, build and run the Debug app on that device once, then
select its CoreDevice identifier.

```sh
xcrun devicectl list devices

swift-ember doctor --project App.xcodeproj --scheme App \
  --device <CoreDevice-ID>
swift-ember watch --project App.xcodeproj --scheme App \
  --device <CoreDevice-ID>
```

The patch is signed with the build's Development identity and its Team ID is
checked against the app before transfer. If a project does not expose an
expanded identity through its build settings, pass
`--signing-identity <certificate-name-or-SHA>`. The phone must be paired,
unlocked, in Developer Mode, and the app must remain foreground-runnable while
a patch is applied. iOS may suspend the file client in the background.

See [XcodeApp](examples/XcodeApp) for SwiftUI with a local package and
[UIKitApp](examples/UIKitApp) for storyboards, navigation, and a table view.
Before publishing a release, run the [physical iPhone release checklist](docs/release-checklist.md).

### Scheme actions (optional)

Add scheme actions if you want a build source manifest, automatic watcher
startup, or hot-reload messages in Xcode's debug console. The manifest lets
the watcher detect edits made between the build and watcher startup.
Build and run the app once on the selected destination before enabling
`xcode start` so the watcher can reach the installed app's data container.

In **Edit Scheme > Build > Pre-actions**, add:

```sh
"$HOME/.local/bin/swift-ember" xcode prepare
```

In **Build > Post-actions**, add the following to record the manifest and
start the background watcher after a successful Debug build:

```sh
"$HOME/.local/bin/swift-ember" xcode start
```

For a terminal-managed watcher with a manifest, set the Build post-action to
`xcode record` and run `swift-ember watch` after launching the app. Select the
same app target under **Provide build settings from** for both build actions.
Use **Product > Clean Build Folder** before the first build with these actions.

Both actions use the selected app target's build settings, including the
output paths of builds run with `xcodebuild -derivedDataPath`. The pre-action
can run before the binary exists. The post-action requires the built binary.

If you use `xcode start`, add this line to **Run > Post-actions** so the
watcher exits with the app:

```sh
"$HOME/.local/bin/swift-ember" xcode stop
```

The build actions use the configuration named in the configuration file.
`xcode start` replaces the old watcher after a rebuild and returns when the
new watcher is ready. It automatically selects Xcode's active Simulator or
physical device. Watchers for different Simulators remain isolated. The background
process keeps the selected `DEVELOPER_DIR` but does not inherit transient
build-script or debugger variables. Hot-reload successes, actionable warnings,
and failures are mirrored into Xcode's debug console with a `[swift-ember]`
prefix while the app is connected. Complete stage timings and transport detail
remain in `.ember/logs`, which is the canonical log if the app is disconnected.

The executable may live inside the repository instead; use its absolute path
derived from `SRCROOT`, for example
`"$SRCROOT/../tools/swift-ember" xcode start`. If no configuration file is
used, Xcode supplies the project or workspace path. Pass `--scheme` and any
extra `--sources` to the build actions, and pass the same `--scheme` to
`xcode stop`.

To record sources in a terminal-driven build, run `swift-ember xcode
prepare --derived-data-path .build-xcode` before the build and `swift-ember
xcode record --derived-data-path .build-xcode` after it succeeds. These
examples use the project, scheme, and source roots in `.swift-ember.json`.

The build records SHA-256 hashes for watched Swift files and the Mach-O UUIDs
of the link target in `<App>.app.swift-ember-sources.json` beside the built app.
Use the same source roots and exclusions for recording and watching. Use
`--exclude` or the project configuration for generated sources written during
the build. Excluded files are still read at startup for cross-file safety
checks. In-tree Xcode build output directories are skipped automatically and
listed by `doctor`.

If the UUIDs or watched source hashes differ at startup, rebuild before
watching. The build compares both hashes and file metadata for watched
sources before and after compilation. It rejects a rewrite even if the
original bytes are restored. If a build phase rewrites watched sources,
exclude those paths before rebuilding. If a build was prepared with a
version that did not record metadata, rerun `xcode prepare` with the current
version and rebuild. If sources keep changing during startup, wait for
writes to finish and retry. A startup read or UTF-8 error lists the affected
paths and stops the watcher.

Without a source manifest, `watch` starts with a warning and takes its
baseline from the source files at startup. Save changes after `watch` is
ready so they can be applied to the running app. An incomplete, unreadable,
or stale manifest stops startup.

For a custom build using `--context`, write `ember-context.json` before
compiling, then bracket the successful build with these commands:

```sh
swift-ember xcode prepare --context ember-context.json
# Compile and link the binary described by ember-context.json.
swift-ember xcode record --context ember-context.json
```

Keep both commands in the same build script and serialize builds that share
an output product. The CounterApp example uses these commands when
`SWIFT_EMBER_CLI` points to the CLI executable.

To manage a background watcher from a terminal, use:

```sh
swift-ember start
swift-ember status
swift-ember stop
```

`start` returns only after the watcher is ready. Repeating `start` for the same
session reports the existing watcher, and `stop` is idempotent. Session records,
logs, and isolated patch output live
under `.ember/sessions`, `.ember/logs`, and `.ember/patches` beside the project
or context file. `stop` verifies the PID, executable path, and process start
time before sending SIGTERM, so a stale PID file cannot terminate an unrelated
process. Startup waits for up to 60 seconds by default. Override it with
`--startup-timeout <seconds>`. Both `start` and `status` report the selected
Simulator UDID for a running watcher. For a session started with
`--simulator`, pass the same UDID to `status` and `stop`. Those commands can
also find an implicitly started session if its recorded UDID matches.

Only one watcher can use a given Simulator and bundle ID at a time, including
across projects and worktrees. A conflicting start fails before it can replace
the app's session file. Use the owner PID and log path in the error to find the
existing watcher, or use a different Simulator.

### Using init and Ember.xcconfig (optional)

To apply the Debug Build Settings together, include
`integrations/xcode/Ember.xcconfig` from the checked-out release in your Debug
xcconfig or select it as the Debug Base Configuration. To set up the xcconfig,
configuration file, and source recording in one step, share your app's scheme
and copy `Ember.xcconfig` beside the project. Preview the changes with
`swift-ember init`, then apply them with `--write`.

```sh
swift-ember init --project App.xcodeproj --scheme App --sources Sources
swift-ember init --project App.xcodeproj --scheme App --sources Sources --write
```

Use `--workspace App.xcworkspace` for a workspace or `--ember-xcconfig <path>`
to use a template elsewhere. `init` creates `.swift-ember.json`, configures the
app target's Debug xcconfig, and adds the scheme actions for source recording.
Pass `--post-action start` to also restart the background watcher after each
successful Debug build. If Debug already has a Base Configuration, the new
xcconfig includes it first and then includes Ember. See
[Xcode integration](integrations/xcode/README.md) for CocoaPods and existing
project settings.

### Checking a shipping build

Build the shipping configuration first. Use the same scheme, destination and
DerivedData path in the build and the check.

```sh
xcodebuild -project App.xcodeproj -scheme App -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath .build-xcode build
swift-ember doctor --release --project App.xcodeproj --scheme App \
  --destination 'generic/platform=iOS' --derived-data-path .build-xcode
```

`doctor --release` defaults to `Release` even when `.swift-ember.json` selects
`Debug`. Pass `--configuration Shipping` for a custom name. To check an
archived or exported product, pass `--app <path.app>` with the settings of
the build that produced it. A missing product, failed inspection, or detected
instrumentation gives a nonzero exit status. See
[Release isolation](integrations/xcode/README.md#release-isolation) for the
checks and optional guard.

## How it works

```
your editor                          the running app
     |                                      ^
     | save                                 | dlopen
     v                                      |
  FileWatcher                          PatchLoader
     |                                      ^
     v                                      | "load generation 3"
  ChangeClassifier  --- not safe --->  rebuild required
     |                                      ^
     | implementation change                |
     v                                      |
  ReplacementGenerator  ->  swiftc  ->  IPCServer
```

Replacement itself is Swift's, not ours. Debug builds compile with
`-enable-implicit-dynamic`, which makes declarations dynamically replaceable;
a patch is an image full of `@_dynamicReplacement(for:)` declarations that the
Swift runtime binds when the image loads.

The interesting question is not how to replace a function. It is knowing when
you must not. Adding a stored property changes a type's layout, and every
object already on the heap was allocated with the old one. So the classifier
is conservative by construction: a change it does not understand is a rebuild.
A false negative costs a rebuild, a false positive corrupts a live process,
and those are not comparable.

## What reloads

Method and function bodies, computed property bodies, and the implementations
they reach. Concretely:

When one editor action saves several Swift files, the watcher treats that poll
as one reload: it checks every file first, compiles each module under its own
evaluated package flags, Swift language mode, and private-import context, links
the resulting objects into one patch image, and loads that image once. A helper
added in one file can therefore land with a changed caller in another file of
the same module, while
body edits in an app target and local package can land atomically together. If
any file or module fails classification or compilation, no image is delivered;
if runtime loading fails, no later module remains to apply as a partial prefix.

- methods on `class`, `struct`, `enum`, and `actor`, including `mutating`,
  `static`, `async`, `throws`, and `@MainActor` ones;
- bodies of generic functions, methods, and computed properties in Debug.
  This includes methods on constrained extensions and witnesses of
  conditional conformances. Plain `@inline(__always)` and `@inline(never)`
  functions also reload in the measured Debug configuration;
- **overrides**, including a body that opens with `super.viewDidLoad()`, and
  including one UIKit reaches through `objc_msgSend` rather than through
  Swift's vtable;
- **`private` and `fileprivate` bodies**, and any body that reads private
  state or names a private type. These need one more build setting than the
  rest --- `-Xfrontend -enable-private-imports` --- and it is worth the line:
  without it, 5 of 32 ordinary body edits reach a running process. With it, 31.
  Most method bodies in most types touch private state;
- **declarations you just added**. A new helper is carried in the patch rather
  than replacing anything, since nothing already running could be calling it;
- **opted-in SwiftUI `body`**. A View with `@ObserveEmber` in the same file and
  `.emberable()` as the body's outermost expression may change its whole
  tree. In the measured `List` case, `Text` became a `VStack`, the screen
  updated, the process stayed alive, and the View's existing `@State` kept the
  same identity;
- **UIKit**. `layoutSubviews`, `draw(_:)`, `viewWillLayoutSubviews`, an
  `@objc` action, a data source method --- anything UIKit calls again reaches
  the replacement, on the controller that is already on screen. The runtime
  invalidates layout and reloads lists after a patch lands, so the edit shows
  up without a tap; `Ember.RefreshOptions` is how an app turns that off.

  `viewDidLoad` is the exception, and `watch` says so rather than letting you
  wonder: it has already run, so the new body reaches the next controller of
  that type instead of the one you are looking at.

Anything that changes a type's layout, a signature, or the set of things a
protocol requires is a rebuild, and so is any declaration removed or any
declaration returning an opaque result type except the explicitly erased
SwiftUI shape above. `PRD.md` section 8 is the full tier list, and `DESIGN.md`
section 7.3b is where those two numbers come from.

Deleting or renaming a watched Swift file also requires a rebuild. The watcher
refuses the whole save batch and all later saves in that watcher session. After
the rebuild, the `xcode start` Build post-action starts a fresh watcher;
foreground `swift-ember watch` sessions must be restarted manually unless a
`rebuildCommand` is configured. Automatic recovery instead waits for the new
process and resets the existing watcher from the rebuilt sources. This keeps
the added half of a rename and any changes skipped alongside it from being
applied on their own.

## Layout

```
Tools/swift-ember/    host-only package; owns the SwiftSyntax dependency
  Sources/EmberCore   shared types: build context, wire protocol, diagnostics
  Sources/EmberGen    SwiftSyntax: what changed, and what to generate for it
  Sources/EmberDaemon watching, compiling, talking to the app
  Sources/EmberCLI    swift-ember init | doctor | watch | start | stop | status
  Tests/               classifier, generated-patch, and daemon tests
runtime/Sources        the in-app half: connect, load, report
runtime/SwiftUI        optional observation and AnyView boundary
integrations/xcode/    the xcconfig a project bases its Debug config on
fixtures/              52 cases pinning what Swift dynamic replacement does,
                       and 4 more under ui/ that need a rendering process
examples/CounterApp    a Simulator app built by script, flags in plain sight
examples/XcodeApp      the same thing as a real .xcodeproj, in SwiftUI
examples/UIKitApp      storyboards, a navigation controller, a table view
DESIGN.md              architecture and the measurements behind it
PRD.md                 scope, tiers, milestones
```

## Requirements

Xcode 26.2 or later, an arm64 macOS host, and an application deployment target
of iOS 16 or later. Compatibility evidence spans Swift 6.2.3
through 6.4.2 across ten configurations, eight locally and two on CI. The
Xcode 26.6 full run passed all 44 fixtures on the Simulator, 41 on the host
with the three Simulator-only UIKit cases skipped, and the then-current 226
tests on local Swift 6.3.3. The M6 host verification passed all 330 tests on
Swift 6.3.3 and 6.4, plus the 41 host fixtures on Swift 6.4. Xcode 27.0 and
27.2 are supported. Each passed 49 of 52 fixtures on the host, 44 of 52 on the
Simulator, and all 385 tool tests. The host skips three Simulator-only UIKit
cases, and the Simulator skips eight macOS-only cases. `DESIGN.md` section 20
records exactly what was run on each configuration. Physical-device delivery
is verified on an arm64 iPhone running iOS 26.4 with a binary targeting iOS 16,
and again with Xcode 27.2 on an iPhone 14 Pro running iOS 26.7.3: the
[release checklist](docs/release-checklist.md) passed, including a second
reload after the device dropped off CoreDevice and reconnected, with each
reload about 1.7 s from save. An actual iOS 16 device has not yet been
measured.

One thing does differ, and only by deployment target: below macOS 26 or iOS 26,
`some View` erases to `AnyView` rather than `DebugReplaceableView`. The
unannotated failure mode changes, but the conservative classification and the
explicit opt-in do not.

Other toolchains are untested rather than unsupported. `fixtures/run.sh` is how
you find out where a new one stands:

```
DEVELOPER_DIR=/Applications/Xcode-26.5.0.app/Contents/Developer \
  ./fixtures/run.sh --platform simulator
```

`DESIGN.md` section 20 keeps the matrix.

## Checking your changes

```
scripts/ci.sh                     everything, about fifteen minutes
scripts/ci.sh --skip-simulator    the stages that need no simulator
scripts/ci.sh --profile pull-request
                                  the faster suite used on pull requests
scripts/ci.sh --only tests        one stage; --list-stages to see them
```

CI runs that script and nothing else, so a red build is something you can
reproduce. It picks the toolchain itself — newest at or above the floor that has
actually been measured — which is why the workflow pins no Xcode version: an
image rotating should not look like the code breaking.

One stage is worth knowing about. `runtime-toolchains` compiles the in-app
runtime under *every* installed Xcode, because the bug that made this project
unusable on shipping toolchains was a type-checker crash that only reproduces
below Swift 6.4. Building on whichever toolchain is newest would have proved
nothing.

## What it will not do

Release builds, App Store/runtime code delivery, and anything that changes a
type's layout. Physical devices are a Debug-development workflow and require
same-Team Development signing; they are not a production patch mechanism.

Initializer body edits, generic signature changes, and edits to the bodies of
`@inlinable`, `@_transparent`, and `@_alwaysEmitIntoClient` declarations require
a rebuild. Rebuild callers of an `@inlinable` function along with its library.
An optimized caller can keep executing a copy of the old body after a
library-only rebuild. See `DESIGN.md` sections 12.4 and 12.8.

An unannotated SwiftUI `body` is a rebuild, and the reason took three attempts
to get right. `View` carries a type eraser, so the patch is safe to load, and a
replaced body does run when SwiftUI evaluates that view --- it renders. What it
also does, when the body's concrete type changes and the view is a row of a
`List`, is abort the process: the eraser stores its child in a generic box that
the graph downcasts to the type it saw first. Adding `.padding()` is enough.
`.emberable()` moves the changing tree behind an `AnyView` that is present
from the first build; it is an explicit opt-in, not a reason to weaken the
default refusal. `DESIGN.md` section 13.1 has the original measurements and
section 13.4 has the opt-in result.

The full list is `PRD.md` section 5.
