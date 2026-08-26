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
./run.sh --results results-macos.yaml     # also write the machine-readable matrix
```

`results-macos.yaml` and `results-simulator.yaml` are the compatibility matrix
that `DESIGN.md` section 20 asks for, generated from actual runs rather than
maintained by hand.

The Simulator path uses `xcrun simctl spawn booted`, so boot a simulator first.
Both checked-in result files come from Xcode 27.0 Beta 4; the Simulator run
used an iPhone 17 Pro on iOS 27.0. All 43 cases pass on the Simulator; the three UIKit cases have nothing to
say on the host and are skipped there, leaving 40.

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
| `PLATFORMS` | `macos simulator` | where the case can build; elsewhere it is skipped and named |
| `EXTRA_SOURCES` | | repository-relative sources compiled into the application, with `SPLICE_ENABLED` defined |
| `SUPPORTED` | `yes` | whether the change is meant to be hot reloadable |
| `KIND` | `replace` | `replace`, `reject-compile`, `crash`, or `unsafe` |
| `PATCHES` | `Patch.swift` | patch sources, loaded in order |
| `APP_TESTABILITY` | `yes` | build the application with `-enable-testing` |
| `APP_PRIVATE_IMPORTS` | `yes` | build the application with `-enable-private-imports` |
| `STATE_PRESERVED` | `no` | recorded in `results.yaml` |
| `EXPECT_COMPILE_ERROR` | | substring the patch build must emit, for `reject-compile` |
| `EXPECT_SIGNAL` | | signal number, for `crash` |
| `NOTE` | | recorded in `results.yaml` |

## What the UIKit cases establish

Three cases, Simulator-only (`PLATFORMS="simulator"`), behind the question
DESIGN.md section 13a exists to answer: SwiftUI reaches a `body` through code
generated at compile time and never sees a replacement, so does UIKit have the
same problem? It does not.

- `uikit-live-instance` --- `layoutSubviews`, `viewWillLayoutSubviews`,
  `draw(_:)` and an `@objc` method, all reached on the controller and view
  that already exist. Every one of them runs the replacement once something
  asks for a layout or a render pass. This is the case SwiftUI fails.
- `uikit-data-source` --- the same conclusion for a protocol requirement on a
  separate object rather than an override on a subclass.
- `uikit-view-did-load` --- the exception, and the limit. Nothing calls
  `viewDidLoad` again, so replacing it changes nothing; discarding the
  controller's view does re-run it, with the controller's own state intact,
  and the rebuilt view is measured as **not** reinstalled where the old one
  was. That last line is why the runtime does not offer this as a feature.

They run as a console process with no `UIApplication`, so the views are alive
but on no screen, and the render pass a real app would perform is forced by
hand. What they pin is dispatch --- whether a call reaches the replacement ---
not the runtime's window discovery, which needs a real application.

All three patches carry an Objective-C category and no `__swift5_replace`
section, because every entry point above is `@objc`. That is the mechanism
DESIGN.md section 13a.2 describes, and it is worth knowing when reading them:
these cases exercise one dispatch shape, not two.

`registered-replacements` is the case that turns that mechanism into a number.
It compiles `runtime/Sources/RegisteredReplacements.swift` --- the reader the
daemon's FR-13 check depends on --- into the fixture application and asks it
about the image the harness just loaded. The subject carries a Swift record, an
`@objc` category method, an `@objc` `{ get set }` property, and one declaration
the patch merely *carries*. The answer has to be 4: the carried one replaced
nothing and does not count.

Which class each of those lives in decides what the case covers. `@objcMembers`
reaches every member, so a plain method placed beside the others becomes `@objc`
and the image stops carrying a `__swift5_replace` section at all --- the total
stays 4, the case still passes, and the whole Swift-section half of the reader
goes unexercised. That happened once. The plain method has a class of its own
for that reason.

It is the only case that runs runtime code rather than observing runtime
behaviour, which is what `EXTRA_SOURCES` exists for.

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

It also diverges by target. This case returns the new value on the macOS host
and crashes on the iOS Simulator, from identical source built by the same
toolchain. Compare the `observed:` field in the two result files.

Because the outcome is undefined, that case records what happened instead of
asserting a specific result. Pinning an expectation to undefined behavior would
only make the suite flaky. What is not undefined is the conclusion: the
classifier must reject the edit before it ever reaches a process.

## What the capability cases establish, and what they do not

Five cases pin behavior the classifier does not yet use. They exist because the
daemon refuses these edits, and it was not clear whether the refusals were about
Swift or about this tool:

- `override-method`, `override-objc-dispatch`, `override-super-call` --- an
  override gets a replacement key of its own, and the replacement goes in an
  extension because it is not itself an override. It is reached through the base
  class, through `objc_msgSend`, and it may call `super`. That last one decides
  the question in practice: an overridden method whose body opens with
  `super.viewDidLoad()` would be out of reach even with the key present.
- `patch-local-declaration` --- a declaration carried only in the patch is
  callable from a replaced body. Nothing in the running binary can reach it,
  since it did not exist when that binary was linked, which is what makes adding
  one layout-neutral.
- `private-via-caller` --- a private function's new implementation reaches the
  process when the patch carries a copy and replaces the callers. `private` is
  file-scoped, so the file is the whole closure. Replacing some callers and not
  others would leave two versions live at once, so the case replaces all of them.

The three `override-*` cases are what the classifier does. The other three are
history: they pin a route to `private` declarations --- carry a copy, replace
the callers --- that worked, shipped, and was then withdrawn in favour of
`-enable-private-imports`, under which a private declaration simply has a
replacement key. They stay because they document what the toolchain does, and
because `patch-local-declaration` still describes how an *added* declaration
reaches the process.

The `private-*` cases below are the route that replaced them.

These cases came first and the implementation followed, which is the order that
made it cheap. Each one answered "is this Swift or is this us?" before any code
was written to act on the answer --- and for overrides the answer had been
assumed, wrongly, for the life of the project.

## What the private-import cases establish

Seven cases pin `-Xfrontend -enable-private-imports`, which the app build now
carries and `fixtures/run.sh` passes by default:

- `private-function-replaced`, `private-type-member`,
  `private-stored-property-read` --- a private declaration has a replacement key
  of its own, a private type can be extended by a patch, and private storage
  can be read from one.
- `private-default-argument`, `private-witness`, `private-override` --- the
  three places a *copy* was reached wrongly, or not at all. A default
  argument's generator, a witness table entry, and a vtable slot all find a
  replacement, because it is bound at the key they already go through.
- `no-private-imports-rejected` --- what a project that has not added the
  setting sees. `APP_PRIVATE_IMPORTS=no` turns the flag off for that one case,
  and the daemon translates this exact diagnostic into the setting.

## Not covered here

The negative fixtures in `DESIGN.md` section 19.3 --- stored property added,
enum case added, signature changed --- test the change classifier, which does
not exist yet. They belong with it when it lands. These fixtures only cover
what the Swift runtime does once a patch has been built.
