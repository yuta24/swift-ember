# swift-splice

Apply Swift implementation changes to a running iOS Simulator app without
restarting it or losing its state.

Save a file, and the method bodies you changed take effect in the process
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

Status: **M4 of 5**, and it works against a real `.xcodeproj`. Method bodies
reload end to end on a Simulator app, and the classifier's refusals are pinned
by tests. SwiftUI `body` is not among them, for a measured reason — see below.
Read `PRD.md` for what is and is not promised.

## Try it

Boot a simulator, then:

```
examples/CounterApp/demo.sh
```

It builds the app, starts the daemon, edits a method body, and screenshots
before and after. `examples/CounterApp/README.md` walks through what happened.

## Adding it to your project

Two steps, both in Xcode.

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
     | body-only change                     |
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

## Layout

```
Sources/SpliceCore     shared types: build context, wire protocol, diagnostics
Sources/SpliceGen      SwiftSyntax: what changed, and what to generate for it
Sources/SpliceDaemon   watching, compiling, talking to the app
Sources/SpliceCLI      swift-splice doctor | watch | status
runtime/               the in-app half: connect, load, report
integrations/xcode/    the xcconfig a project bases its Debug config on
fixtures/              24 cases pinning what Swift dynamic replacement does
Tests/                 73 tests: what the classifier decides, what the
                       generated patch does in a process, what the daemon
                       does when the app goes quiet
examples/CounterApp    a Simulator app built by script, flags in plain sight
examples/XcodeApp      the same thing as a real .xcodeproj
DESIGN.md              architecture and the measurements behind it
PRD.md                 scope, tiers, milestones
```

## Requirements

Xcode 27.0 Beta 4 with Swift 6.4, and an arm64 macOS host. Other toolchains
are untested rather than unsupported; `fixtures/run.sh` is how you find out
where a new one stands. `DESIGN.md` section 20 keeps the matrix.

## What it will not do

Release builds, physical devices, and anything that changes a type's layout.

SwiftUI `body` is a rebuild too, though not for the reason you would guess.
`View` carries a type eraser, so `some View` is already concrete and patching
one is perfectly safe — it just does nothing. SwiftUI reaches a body through
code generated at compile time rather than through the replacement, so the
reload reports success and the screen does not change. A reload that lies is
worse than a refusal. `DESIGN.md` section 13 has the measurements.

The full list is `PRD.md` section 5.
