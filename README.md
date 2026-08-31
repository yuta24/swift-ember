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

Download the `0.3.0` binary and install it in `$HOME/.local/bin`:

```sh
version=0.3.0
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
git clone --branch 0.3.0 --depth 1 https://github.com/yuta24/swift-ember.git
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
Version** starting at `0.3.0`. Add `EmberRuntime` to a UIKit target, or
`EmberSwiftUI` to a SwiftUI target; `EmberSwiftUI` brings and re-exports the
runtime.

In another Swift package, declare the same dependency as:

```swift
.package(
    url: "https://github.com/yuta24/swift-ember.git",
    .upToNextMinor(from: "0.3.0")
)
```

## Try it

Boot a simulator, then:

```
examples/CounterApp/demo.sh
```

It builds the app, starts the daemon, edits a method body, and screenshots
before and after. `examples/CounterApp/README.md` walks through what happened.

## Configuring your project

Two steps, both in Xcode — plus one line per local package, since Xcode does
not pass the app's compiler flags into package targets. See
`integrations/xcode/Package.md`.

Copy `integrations/xcode/Ember.xcconfig` from the checked-out release into your
project, then base your Debug configuration on it (or include it from the
Debug `.xcconfig` you already use). Call `Ember.start()` once at launch; it
needs no `#if` around it, because both products compile their active code only
for Debug.

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

Then check the setup and start watching:

Create `.swift-ember.json` beside the project or workspace. Paths in this file
are relative to the configuration file, so the same file works for every
checkout:

```json
{
  "workspace": "App.xcworkspace",
  "scheme": "App",
  "sources": [
    "Sources",
    "Packages/Feature/Sources"
  ]
}
```

`project` may be used instead of `workspace`. `configuration` defaults to
`Debug`, `sources` defaults to the app target's `SRCROOT`, and the nearest
`.swift-ember.json` is found by walking upward from the current directory (or
Xcode's `SRCROOT`). Command-line options override the file. Unknown keys are
rejected so a misspelled `sources` cannot silently narrow what is watched.

A complete explicit target (`--project`/`--workspace` together with `--scheme`,
or `--context`) bypasses automatic discovery. Pass `--config <path>` to use a
specific file anyway, or `--no-config` to disable discovery explicitly. A
manifest passed with `--context` and an Xcode project/workspace are separate
target modes and cannot be combined.

```
swift-ember doctor
swift-ember watch
```

`watch` stays in the foreground, which is convenient in a terminal. To let an
Xcode action own the same watcher, run it in the background instead:

```sh
swift-ember start
swift-ember status
swift-ember stop
```

`start` returns only after the watcher is ready. A second `start` is harmless,
and `stop` is idempotent. Session records, logs, and isolated patch output live
under `.ember/sessions`, `.ember/logs`, and `.ember/patches` beside the project
or context file. `stop` verifies the PID, executable path, and process start
time before sending SIGTERM, so a stale PID file cannot terminate an unrelated
process. Startup waits for up to 60 seconds by default; unusually large or slow
projects can override that with `--startup-timeout <seconds>`.

To tie the watcher to Xcode, add this one line to the scheme's **Build >
Post-actions** and select the app target under **Provide build settings from**:

```sh
"$HOME/.local/bin/swift-ember" xcode start
```

Add the matching line to **Run > Post-actions** so the watcher exits with the
app:

```sh
"$HOME/.local/bin/swift-ember" xcode stop
```

`xcode start` skips configurations other than the one in the configuration
file, replaces the old watcher after a rebuild, and returns only when the new
watcher is ready. It also selects the active physical device when Xcode is
building for one; Simulator needs no identifier. The background process keeps
the selected `DEVELOPER_DIR` but does not inherit transient build-script or
debugger variables. Its detailed output remains in `.ember/logs`.

The executable may live inside the repository instead; use its absolute path
derived from `SRCROOT`, for example
`"$SRCROOT/../tools/swift-ember" xcode start`. If no configuration file is
used, Xcode supplies the project or workspace path, but `--scheme` and any
extra `--sources` still need to be passed. Foreground `watch` remains the
better choice when its live output should stay in a terminal. The original
fully explicit form remains supported:

```sh
swift-ember watch --project App.xcodeproj --scheme App --sources Sources
```

For a physical device, build and run the Debug app on that device once, then
select its CoreDevice identifier:

```
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
a patch is applied; iOS may suspend the file client in the background.

`doctor` names each missing setting rather than reporting a general failure,
and it verifies the claim against the built binary instead of trusting the
settings. `examples/XcodeApp` (SwiftUI, with a local package) and `examples/UIKitApp`
(storyboards, a navigation controller, a table view) are projects wired up
this way.

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

- methods on `class`, `struct`, `enum`, and `actor`, including `mutating`,
  `static`, `async`, `throws`, and `@MainActor` ones;
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

## Layout

```
Tools/swift-ember/    host-only package; owns the SwiftSyntax dependency
  Sources/EmberCore   shared types: build context, wire protocol, diagnostics
  Sources/EmberGen    SwiftSyntax: what changed, and what to generate for it
  Sources/EmberDaemon watching, compiling, talking to the app
  Sources/EmberCLI    swift-ember doctor | watch | start | stop | status
  Tests/               classifier, generated-patch, and daemon tests
runtime/Sources        the in-app half: connect, load, report
runtime/SwiftUI        optional observation and AnyView boundary
integrations/xcode/    the xcconfig a project bases its Debug config on
fixtures/              44 cases pinning what Swift dynamic replacement does,
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
through 6.4 across eight configurations, six locally and two on CI. The newest
full run passes all 44 fixtures on the Simulator, 41 on the host with the three
Simulator-only UIKit cases skipped, and all 226 tests on local Swift 6.3.3. A
44-fixture, 203-test snapshot also passes in full on Swift 6.4. `DESIGN.md`
section 20 records exactly what was run on each configuration. Physical-device
delivery is verified on an arm64 iPhone running iOS 26.4 with a binary
targeting iOS 16; an actual iOS 16 device has not yet been measured.

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
