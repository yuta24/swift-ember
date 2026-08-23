# swift-splice

Apply Swift implementation changes to a running iOS Simulator app without
restarting it or losing its state.

Save a file, and the method bodies you changed take effect in the process
that is already running, with its heap, its navigation, and its login session
intact.

```
$ swift-splice watch
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

Status: **M2 of 5**. The loop works end to end for method bodies on a real
Simulator app. Read `PRD.md` for what is and is not promised.

## Try it

Boot a simulator, then:

```
examples/CounterApp/demo.sh
```

It builds the app, starts the daemon, edits a method body, and screenshots
before and after. `examples/CounterApp/README.md` walks through what happened.

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
fixtures/              24 cases pinning what Swift dynamic replacement does
examples/CounterApp    a Simulator app wired up end to end
DESIGN.md              architecture and the measurements behind it
PRD.md                 scope, tiers, milestones
```

## Requirements

Xcode 27.0 Beta 4 with Swift 6.4, and an arm64 macOS host. Other toolchains
are untested rather than unsupported; `fixtures/run.sh` is how you find out
where a new one stands. `DESIGN.md` section 20 keeps the matrix.

## What it will not do

Release builds, physical devices, and anything that changes a type's layout.
SwiftUI `body` is currently a rebuild: changing the underlying type behind
`some View` compiles cleanly, loads cleanly, and then corrupts the process,
which `DESIGN.md` section 12.7 covers in detail. The full list is `PRD.md`
section 5.
