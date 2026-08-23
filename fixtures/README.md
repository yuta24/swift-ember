# Dynamic replacement fixtures

The M0 matrix from `DESIGN.md` Appendix A, as runnable cases. Each case builds
a small application with the hot reload instrumentation, compiles a patch
against it, loads the patch into the running process, and compares observable
output before and after.

The point is not that these programs are realistic. It is that every claim the
design documents make about what Swift dynamic replacement does is backed by
something that can be re-run when the toolchain changes.

## Running

```
./run.sh                                  # macOS host
./run.sh --platform simulator             # booted arm64 iOS Simulator
./run.sh --case actor-method              # one case
./run.sh --results results.yaml           # also write the machine-readable matrix
```

`results.yaml` is the compatibility matrix that `DESIGN.md` section 20 asks
for, generated from an actual run rather than maintained by hand.

The Simulator path uses `xcrun simctl spawn booted`, so boot a simulator first.
Nothing has been run there yet; the checked-in `results.yaml` is host-only.

## Case layout

```
Cases/<id>/
├── App.swift       defines `probe() async throws -> [String]`
├── Patch.swift     the replacement (or Patch1.swift, Patch2.swift, ...)
├── expected.txt    exact stdout, one line per generation
└── case.conf       optional overrides
```

`Harness/Harness.swift` supplies `@main`. It prints `probe()` output once as
`g0`, loads each patch in turn, and reprints as `g1`, `g2`, and so on. Output
is unbuffered so a case that crashes still leaves its earlier generations on
stdout.

Cases that need to observe state preservation keep their subject in a global,
so the value predates the patch.

### case.conf keys

| key | default | meaning |
| --- | --- | --- |
| `SUPPORTED` | `yes` | whether the change is meant to be hot reloadable |
| `KIND` | `replace` | `replace`, `reject-compile`, `crash`, or `unsafe` |
| `PATCHES` | `Patch.swift` | patch sources, loaded in order |
| `APP_TESTABILITY` | `yes` | build the application with `-enable-testing` |
| `STATE_PRESERVED` | `no` | recorded in `results.yaml` |
| `EXPECT_COMPILE_ERROR` | | substring the patch build must emit, for `reject-compile` |
| `EXPECT_SIGNAL` | | signal number, for `crash` |
| `NOTE` | | recorded in `results.yaml` |

## What the negative cases establish

Four cases exist to prove the pipeline fails closed:

- `inlinable-rejected` and `transparent-rejected` --- implicit dynamic skips
  these declarations, and the patch is rejected at COMPILE with
  `replaced function ... is not marked dynamic`.
- `private-rejected` --- rejected at COMPILE with
  `replaced function ... could not be found`.
- `no-testability-rejected` --- without `-enable-testing` the patch cannot
  import the module at all. With a stale module the same misconfiguration
  surfaces one stage later, as a `dlopen` symbol-not-found error.

`opaque-result-type-changed` is the exception and the reason the classifier
matters. Changing the concrete type behind `some` passes the compiler and the
loader without a word, and the runtime result is undefined. Across otherwise
similar programs it has produced the new value, garbage characters, and
`SIGSEGV`. The determining factor observed so far is whether the opaque type's
metadata was already resolved before the patch loaded.

Because the outcome is undefined, that case records what happened instead of
asserting a specific result. Pinning an expectation to undefined behavior would
only make the suite flaky. What is not undefined is the conclusion: the
classifier must reject the edit before it ever reaches a process.

## Not covered here

The negative fixtures in `DESIGN.md` section 19.3 --- stored property added,
enum case added, signature changed --- test the change classifier, which does
not exist yet. They belong with it when it lands. These fixtures only cover
what the Swift runtime does once a patch has been built.
