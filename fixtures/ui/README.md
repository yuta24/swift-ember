# UI fixtures

Cases whose outcome is only visible in a process that renders.

`../run.sh` builds a console process, which is right for almost everything this
project measures: whether a replacement binds, what an image registers, which
edits are refused. It is wrong for one class of question, and the gap cost this
project two wrong conclusions in a row.

`../Cases/swiftui-body-direct-call` reads `body` directly after loading a patch
and passes. It passed while `DESIGN.md` said the replacement never runs, and it
passed while `DESIGN.md` said it runs and is safe. A direct read never touches
the SwiftUI storage involved in the iOS 26 abort.

## Running

```
./run.sh                     # every case
./run.sh --case <id>         # one case
DEPLOY=16.0 ./run.sh         # the supported deployment floor
```

Boot a simulator first. `DEPLOY` selects the compile-time deployment target
and defaults to the SDK's own version. The summary reports that target and
the booted Simulator's runtime version separately.
For an iOS 26.5 Simulator under Xcode 27.2, use `DEPLOY=26.0 ./run.sh`.
The default iOS 27.2 build requires SwiftUI symbols available on the newer
runtime and exits at launch on iOS 26.5.

## How a case is decided

An application is built, installed, and launched; it beats a counter into its
own `Documents/heartbeat` and polls `Documents/Patches` the way the real
runtime polls its inbox. The runner delivers one patch and then reads the
heartbeat twice.

Twice, and after the patch rather than against a reading from before it. A
process that is about to abort still beats a few times while the patch settles,
so a single comparison called a dead process alive. Asking the simulator
whether the process is still listed is worse: `launchctl` listed one that had
already aborted.

```
Cases/<id>/
├── App.swift    a whole SwiftUI application, including @main
├── Patch.swift  the replacement
└── case.conf    EXPECT=alive|crash and optional per-case settings
```

`MIN_DEPLOY` skips the case below the specified deployment target.
`ALIVE_FROM_RUNTIME` selects `EXPECT=alive` at or above the specified runtime
version. Each result line displays the selected expectation. A case expecting
`alive` can also set `EXPECT_RENDERED_PREFIX` to require a matching record in
`Documents/rendered`. `Harness/Loader.swift` supplies the heartbeat, render
record writer, and inbox poller.

## What these four establish

They exist to pin `DESIGN.md` section 13.1, which is the part of this project
that has been wrong most often.

- **`body-shape-change-in-list`** measures a `Text` to `VStack` change in a
  `List` row. With `DebugReplaceableView`, the graph downcast aborts on iOS
  26.2 and 26.5. On iOS 27.2, the replacement's `row N` and `second line`
  appear and the heartbeat continues. The case expects this behavior from
  runtime iOS 27.0 onward and records the row contents when the second line
  appears. With the same Xcode 27.2 SDK and iOS 26.0 deployment target, the
  result changed between runtimes 26.5 and 27.2. `MIN_DEPLOY=26.0` selects
  builds that use `DebugReplaceableView`. Earlier deployment targets use
  `AnyView`, which tolerates a type change.
- **`body-shape-change-in-vstack`** is the container control. The same change
  survives in a `VStack`, including on the iOS 26 runtimes where the `List`
  case aborts.
- **`body-literal-change-in-list`** — an edit that leaves the body's concrete
  type identical survives in the same `List` on both runtime versions.
- **`body-shape-change-enabled-in-list`** — the first case with the production
  `EmberSwiftUI` opt-in. `@ObserveEmber` makes the row evaluate after the
  real loader publishes a generation, and the outermost `.emberable()`
  keeps the stored child at `AnyView`. The process stays alive, the new
  `VStack` renders, the row's `@State` UUID survives, and the loaded image
  reports the expected two replacement records.

The classifier still requires a rebuild for these edits to an unannotated
`some View` body. Apps can still run on affected iOS 26 runtimes, and the build
does not determine the runtime where the patch will execute. The classifier
also cannot reliably distinguish a literal-only edit from a type change using
syntax alone.
