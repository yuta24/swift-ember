# CounterApp --- M1 manual patch PoC

A real iOS Simulator app whose method bodies are replaced while it keeps
running. This is the M1 milestone from `PRD.md`: hand-authored patches, no
daemon, no classifier, no source watching.

| before | after |
| --- | --- |
| ![before](Screenshots/before.png) | ![after](Screenshots/after.png) |

The session token is generated once at launch and is identical in both
screenshots. That is the whole point: the process was never restarted, the
`Cart` instance and its items are the same objects, and only the two rows under
"Patched output" changed.

```
Session    9D02E6      ->  9D02E6      (unchanged)
Subtotal   775 cents   ->  $7.75 across 2 item(s)
Discount   none        ->  spend $10 to unlock
```

## Running it

Boot a simulator, then:

```
./demo.sh
```

That builds, launches, captures `before.png`, compiles and delivers both
patches, and captures `after.png` into `.build/demo/`.

The pieces are usable separately:

```
./build.sh                          instrumented build, install, launch
./build.sh --release                uninstrumented, and assert isolation
./patch.sh Patches/Patch1.swift     compile one patch and deliver it
```

## How it is put together

```
Sources/Cart.swift      the subject: stored properties plus patchable methods
Sources/App.swift       SwiftUI views that call those methods
Runtime/Splice.swift    the whole runtime: find images, dlopen them
Patches/Patch*.swift    hand-authored replacements
Info.plist              minimal app bundle metadata
```

There is no Xcode project. The bundle is assembled by `build.sh` so that every
flag the design documents argue about is visible in one place rather than
buried in a `.pbxproj`. Real projects will get these through xcconfig, which is
`DESIGN.md` section 5.2's problem, not this example's.

### The build settings that matter

```
-Onone                                keep replacement dispatch intact
-Xfrontend -enable-implicit-dynamic    make declarations replaceable
-enable-testing                        export the replacement keys
-D SPLICE_ENABLED                      compile in the runtime
```

`-enable-testing` is the one that is easy to miss. Without it the replacement
keys exist but stay hidden, and a patch cannot bind to them at all. See
`DESIGN.md` section 5.4.

### How a patch is built

```
swiftc -Onone -emit-library
       -I <dir with CounterApp.swiftmodule>
       -Xlinker -bundle
       -Xlinker -bundle_loader -Xlinker <the app binary>
```

Linking against the application binary means an unresolvable replacement key
fails here, at LINK, with `Undefined symbols`. The alternative,
`-undefined dynamic_lookup`, defers the same failure to `dlopen` inside the
running process, and is deprecated for the iOS Simulator besides.

Patch compilation takes roughly 250--500 ms on this app. That is the number
`DESIGN.md` section 18 wants profiled once there is a pipeline around it.

## Release isolation

```
$ ./build.sh --release
configuration      release
replacement keys   0 exported
release isolation  OK (no keys, no runtime)
```

`build.sh --release` fails if the binary exports any replacement key or
contains the `Splice` runtime, which is the check `DESIGN.md` section 5.3 asks
for.

## What is deliberately missing

M1 proves the compile-deliver-load half works before a daemon exists. Absent by
design:

- **No source watching.** You write the replacement by hand. Generating it from
  a diff is M2.
- **No classifier.** Nothing stops you from writing a patch that changes a
  stored property or an opaque result type. M3 adds the checks; until then the
  compiler is the only guard, and for opaque result types it is not one.
- **No IPC.** The runtime polls `Documents/Patches` twice a second. This is a
  placeholder for the daemon pushing over a socket, and it is the wrong place
  for the decision to live: `DESIGN.md` section 4.3 wants the runtime to hold
  minimal policy.
- **No unloading.** Every generation stays resident, per section 10.2.
- **Same module.** The runtime is compiled into the app module rather than
  linked as a library. Splitting it out belongs with M2.
