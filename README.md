# swift-splice

[![CI](https://github.com/yuta24/swift-splice/actions/workflows/ci.yml/badge.svg)](https://github.com/yuta24/swift-splice/actions/workflows/ci.yml)

Apply Swift implementation changes to a running iOS Simulator app without
restarting it or losing its state.

Save a file, and the implementation you changed takes effect in the process
that is already running, with its heap, its navigation, and its login session
intact.

```
$ swift-splice watch --project App.xcodeproj --scheme App
watching examples/CounterApp/Sources
listening on 127.0.0.1:51237

connected  pid 8621, dev.swift-splice.CounterApp

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
end to end on a Simulator app --- overrides and `private` helpers among them ---
and the classifier's refusals are pinned by tests. SwiftUI `body` is not among them, for a measured reason — see below.
Read `PRD.md` for what is and is not promised.

A reload takes about 350 ms and, unlike a build, does not care how big your
project is. On a module of ten thousand declarations a full build takes 50
seconds and a patch still takes 352 ms.

Build the daemon with `swift build -c release`. Classification is SwiftSyntax
parsing, and unoptimised it costs fourteen times as much — enough to be most of
the loop on a large file.

## Try it

Boot a simulator, then:

```
examples/CounterApp/demo.sh
```

It builds the app, starts the daemon, edits a method body, and screenshots
before and after. `examples/CounterApp/README.md` walks through what happened.

## Adding it to your project

Two steps, both in Xcode — plus one line per local package, since Xcode does
not pass the app's compiler flags into package targets. See
`integrations/xcode/Package.md`.

Base your Debug configuration on `integrations/xcode/Splice.xcconfig`, then add
this package and link `SpliceRuntime` to your app target. Call `Splice.start()`
once at launch; it needs no `#if` around it, because the package compiles the
dialling and loading code only for Debug.

Then check the setup and start watching:

```
swift-splice doctor --project App.xcodeproj --scheme App
swift-splice watch  --project App.xcodeproj --scheme App
```

`doctor` names each missing setting rather than reporting a general failure,
and it verifies the claim against the built binary instead of trusting the
settings. `examples/XcodeApp` is a project wired up this way.

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
  than replacing anything, since nothing already running could be calling it.

Anything that changes a type's layout, a signature, or the set of things a
protocol requires is a rebuild, and so is any declaration removed or any
declaration returning an opaque result type. `PRD.md` section 8 is the full
tier list, and `DESIGN.md` section 7.3b is where those two numbers come
from.

## Layout

```
Sources/SpliceCore     shared types: build context, wire protocol, diagnostics
Sources/SpliceGen      SwiftSyntax: what changed, and what to generate for it
Sources/SpliceDaemon   watching, compiling, talking to the app
Sources/SpliceCLI      swift-splice doctor | watch | status
runtime/               the in-app half: connect, load, report
integrations/xcode/    the xcconfig a project bases its Debug config on
fixtures/              39 cases pinning what Swift dynamic replacement does
Tests/                 185 tests: what the classifier decides, what the
                       generated patch does in a process, what the daemon
                       does when the app goes quiet
examples/CounterApp    a Simulator app built by script, flags in plain sight
examples/XcodeApp      the same thing as a real .xcodeproj
DESIGN.md              architecture and the measurements behind it
PRD.md                 scope, tiers, milestones
```

## Requirements

Xcode 26.2 or later, and an arm64 macOS host. Verified on Swift 6.2.3 through
6.4 across six configurations, four locally and two on CI — every fixture and
every test passes on all of them.

One thing does differ, and only by deployment target: below macOS 26 or iOS 26,
`some View` erases to `AnyView` rather than `DebugReplaceableView`. Both are
concrete, so nothing about what is safe to patch changes.

Other toolchains are untested rather than unsupported. `fixtures/run.sh` is how
you find out where a new one stands:

```
DEVELOPER_DIR=/Applications/Xcode-26.5.0.app/Contents/Developer \
  ./fixtures/run.sh --platform simulator
```

`DESIGN.md` section 20 keeps the matrix.

## Checking your changes

```
scripts/ci.sh                     everything, about ten minutes
scripts/ci.sh --skip-simulator    the stages that need no simulator
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

Release builds, physical devices, and anything that changes a type's layout.

SwiftUI `body` is a rebuild too, though not for the reason you would guess.
`View` carries a type eraser, so a return type of exactly `some View` is
already concrete and patching one is safe — it just does nothing. Nested
opaque positions such as `(some View)?` are not erased and remain genuinely
unsafe. SwiftUI reaches a body through
code generated at compile time rather than through the replacement, so the
reload reports success and the screen does not change. A reload that lies is
worse than a refusal. `DESIGN.md` section 13 has the measurements.

The full list is `PRD.md` section 5.
