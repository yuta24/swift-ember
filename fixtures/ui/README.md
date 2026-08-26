# UI fixtures

Cases whose outcome is only visible in a process that renders.

`../run.sh` builds a console process, which is right for almost everything this
project measures: whether a replacement binds, what an image registers, which
edits are refused. It is wrong for one class of question, and the gap cost this
project two wrong conclusions in a row.

`../Cases/swiftui-body-direct-call` reads `body` directly after loading a patch
and passes. It passed while `DESIGN.md` said the replacement never runs, and it
passed while `DESIGN.md` said it runs and is safe. A direct read never touches
the storage SwiftUI keeps for an erased view, which is where the third and
measured answer lives.

## Running

```
./run.sh                     # every case
./run.sh --case <id>         # one case
DEPLOY=18.0 ./run.sh         # a different deployment target
```

Boot a simulator first. The default deployment target is the SDK's own version.

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
└── case.conf    EXPECT=alive|crash, optional MIN_DEPLOY and NOTE
```

`Harness/Loader.swift` supplies the heartbeat and the inbox poller.

## What these three establish

They exist to pin `DESIGN.md` section 13.1, which is the part of this project
that has been wrong most often.

- **`body-shape-change-in-list`** — a `some View` body whose concrete type
  changes, in a `List`, **aborts the process**. The erasure makes the return
  type concrete and keeps the child in a generic box; the graph downcasts that
  box to the type it recorded first. `MIN_DEPLOY=26.0`, because below that
  `some View` erases to `AnyView`, which tolerates the change.
- **`body-shape-change-in-vstack`** — the same patch against the same view,
  with one line different, does not. The container is the condition, and
  `List` is not a corner case.
- **`body-literal-change-in-list`** — an edit that leaves the body's concrete
  type identical survives in the same `List`. That is the safe subset, and the
  reason the classifier refuses it anyway is that nothing syntactic separates
  it from the first case.

A toolchain that changes any of this should fail here rather than in somebody's
application.
