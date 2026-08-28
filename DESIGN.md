# Design Doc: Swift Hot Reload Runtime

> Status: Draft / Architecture proposal\
> Companion document: `PRD.md`\
> Intended reader: maintainers, contributors, coding agents\
> Principle: correctness first; optimize only after profiling

## 1. Executive summary

SwiftHotReload applies ABI-compatible Swift implementation changes to a
running iOS Simulator application while preserving process state.

The initial architecture is:

``` text
Xcode build
   |
   +--> capture build/toolchain context
   |
Running Simulator App
   ^
   | load patch
   |
HotReload Runtime <---- IPC ---- Host Daemon
                              |
source save ----------------->|
                              v
                       change classifier
                              |
                              v
                    replacement generator
                              |
                              v
                    active swift toolchain
                              |
                              v
                       patch dylib/object
```

The MVP uses:

-   existing Swift compiler,
-   Debug-only dynamic instrumentation,
-   Swift `@_dynamicReplacement`,
-   Mach-O/dylib loading in the Simulator,
-   conservative compatibility checking.

LLVM ORC/JITLink is explicitly a Phase 2/3 optimization. It should
replace a measured linker/loading bottleneck, not introduce a new
compiler/runtime dependency before the replacement model is proven.

## 2. Design principles

### 2.1 Reuse Swift semantics

Do not implement a Swift VM.

Parsing, type checking, ownership, ARC, SIL lowering, generics,
concurrency, ABI lowering, and machine-code generation remain the Swift
compiler's responsibility.

### 2.2 Let Swift own replacement dispatch

Prefer compiler/runtime-generated dynamic replacement metadata over
arbitrary machine-code rewriting.

### 2.3 Same toolchain, same world

A patch is compiled using the same selected Xcode toolchain and
effective build configuration as the running binary.

### 2.4 Fail closed

If compatibility cannot be proven sufficiently, require a rebuild.

### 2.5 Simulator first

Do not distort the architecture to support physical iOS devices in v0.x.

### 2.6 Separate correctness from speed

First prove:

``` text
source -> patch -> load -> replacement
```

Then profile and optimize individual stages.

## 3. Background

Swift supports dynamically replaceable functions at the SIL/runtime
level.

The compiler's underscored `@_dynamicReplacement(for:)` attribute marks
a replacement for a `dynamic` function. Swift's documentation describes
replacement occurring at program start or when a shared library is
loaded.

SIL also models dynamically replaceable functions explicitly, preventing
optimizations from assuming a fixed implementation.

The frontend currently exposes a hidden `-enable-implicit-dynamic` flag
whose help text is "Add 'dynamic' to all declarations." This is useful
for experimentation but is not a stable public contract and therefore
must be isolated.

It is a *frontend* option (`FrontendOption, NoInteractiveOption,
HelpHidden`), not a driver option. Passing it bare to `swiftc` fails:

``` text
error: unknown argument: '-enable-implicit-dynamic'
```

It must be spelled `-Xfrontend -enable-implicit-dynamic`.

Two further hidden frontend options bear on generation management
(section 16):

``` text
-enable-dynamic-replacement-chaining
-disable-previous-implementation-calls-in-dynamic-replacements
```

Appendix A records measured behavior for a specific toolchain.

LLVM ORC supports both LLVM IR compilation and runtime linking of
relocatable objects. JITLink explicitly targets language-runtime
registration requirements, including Swift/Objective-C use cases. These
capabilities make it a plausible later replacement for conventional
linking/loading.

## 4. Architecture

### 4.1 Components

``` text
swift-hot-reload/
├── cli/
│   └── user-facing command
├── daemon/
│   ├── FileWatcher
│   ├── BuildContextStore
│   ├── ChangeClassifier
│   ├── ReplacementGenerator
│   ├── PatchCompiler
│   ├── PatchCoordinator
│   └── Diagnostics
├── runtime/
│   ├── RuntimeBootstrap
│   ├── IPCServer
│   ├── PatchLoader
│   ├── ReloadRegistry
│   └── RuntimeDiagnostics
├── toolchains/
│   ├── ToolchainAdapter
│   └── SwiftFeatureProbe
├── integrations/
│   └── xcode/
├── fixtures/
└── examples/
```

The repository structure is conceptual; implementation language
boundaries may change. The tree above uses the working product name; the
actual repository is `swift-splice`.

### 4.2 Host daemon

Runs on macOS.

Responsibilities:

-   monitor source files,
-   capture/reconstruct build context,
-   classify edits,
-   generate replacement source,
-   invoke compiler,
-   communicate with runtime,
-   collect timing and diagnostics.

### 4.3 Runtime library

Linked only into an opted-in Debug application.

Responsibilities:

-   establish local development IPC,
-   receive patch requests,
-   load patch images,
-   report success/failure,
-   track patch generations.

It should contain minimal policy. Source compatibility decisions belong
on the host.

### 4.4 Toolchain adapter

All unstable Swift-specific behavior lives behind:

``` text
ToolchainAdapter
```

Conceptual interface:

``` swift
protocol ToolchainAdapter {
    var identity: ToolchainIdentity { get }

    func probeCapabilities() throws -> ToolchainCapabilities
    func compilePatch(_ request: PatchCompileRequest) throws -> PatchArtifact
    func inspectArtifact(_ artifact: PatchArtifact) throws -> ArtifactMetadata
}
```

No other subsystem should assume a particular hidden frontend option or
private metadata encoding unless unavoidable.

## 5. Build instrumentation

### 5.1 Requirement

Original call sites must remain replacement-aware.

For research/MVP, compile Debug targets with:

``` text
-Onone
-Xfrontend -enable-implicit-dynamic
-enable-testing                    # SWIFT_ENABLE_TESTABILITY = YES
```

`-enable-implicit-dynamic` is hidden/private and therefore MUST NOT be
treated as a permanent API. It is also a frontend option: the bare
spelling is rejected by the `swiftc` driver.

`-enable-testing` is a stable, publicly documented build setting and is
**required**, not optional. See section 5.4.

### 5.2 Integration strategies

Evaluate in this order:

1.  Xcode `.xcconfig` / build setting injection.
2.  Swift compiler flags applied only to opted-in Debug configuration.
3.  Source transformation or generated annotations if compiler flag
    compatibility becomes unacceptable.
4.  Compiler plugin/fork only as a last resort.

Option 1 was enough. `integrations/xcode/Splice.xcconfig` carries the
four settings; a project bases its Debug configuration on it and changes
nothing else. `doctor` reads each setting back separately, so a
half-configured project is told which half.

The runtime arrives as a package product rather than as source to copy,
and is Debug-only by construction: the target defines `SPLICE_ENABLED`
only `.when(configuration: .debug)`, so a Release build links an inert
entry point and nothing that dials or loads. That is what lets a call
site say `Splice.start()` with no `#if` around it, which matters because
a conditional at every call site is a thing projects get wrong.

### 5.3 Release isolation

A project integrating SwiftHotReload MUST be able to verify:

``` text
Release:
  runtime linked?       no
  reload IPC enabled?   no
  implicit dynamic?     no
  testability enabled?  no
```

Provide a CI check eventually. `examples/CounterApp/build.sh --release`
is a first version of it: the build fails if the binary exports any
replacement key or still contains the runtime.

### 5.4 Symbol visibility (required)

Making a declaration `dynamic` is necessary but not sufficient. The
Swift runtime binds a replacement to its target through a *dynamic
replacement key* symbol (mangled suffix `Tx`). A separately compiled
patch image must resolve that symbol against the running binary at load
time.

Swift emits `internal` declarations with hidden visibility. In an
application built without `-enable-testing`, every `Tx` key is therefore
absent from the dynamic symbol table and `dlopen` fails:

``` text
dlopen FAILED: symbol not found in flat namespace
'_$s7DemoApp14internalHelperSSyFTx'
```

`-Xlinker -export_dynamic` does **not** fix this; the linker cannot
export symbols the compiler already marked hidden.

The working configuration is:

``` text
application:  SWIFT_ENABLE_TESTABILITY = YES   (-enable-testing)
patch source: @testable import <ModuleName>
```

One setting resolves both halves of the problem: source-level access to
`internal` declarations, and link-time visibility of the replacement
keys. Both are ordinary supported build settings, not private compiler
behavior.

## 6. Build context capture

Patch compilation must mirror the original target environment.

### 6.1 Data model

``` text
BuildContext
├── xcodePath
├── swiftCompilerPath
├── swiftCompilerVersion
├── targetTriple
├── sdkPath
├── deploymentTarget
├── swiftLanguageMode
├── moduleName
├── moduleSearchPaths[]
├── frameworkSearchPaths[]
├── includeSearchPaths[]
├── defines[]
├── plugin/macro paths[]
├── generatedSourcePaths[]
├── bridgingHeader?
└── relevant frontend flags[]
```

### 6.2 Preferred acquisition

Prefer capturing the actual compile invocation generated by Xcode rather
than reverse-engineering every Xcode build setting.

The implementation should normalize the captured invocation into
`BuildContext`, excluding flags that are inappropriate for patch
compilation.

**Amended after implementing it.** The context comes from
`xcodebuild -showBuildSettings -json` instead. Scraping a build log for
the `swift-frontend` line means requiring a full build, parsing output
with no compatibility promise, and getting nothing back when the build
is already up to date. Asking Xcode for its resolved settings has none
of those problems and is a supported interface.

The concern behind the original preference was not guessing, and that is
met a different way: nothing derived is trusted on its own. `doctor`
reads the built binary back and checks it actually exports replacement
keys, which is the only evidence that counts. Everything else is a
hypothesis about what the build did.

Only one field is genuinely derived rather than looked up: the target
triple, assembled from architecture, platform, and deployment target.

### 6.3a What reaches the patch compile, and from where

Everything that changes how a body is *interpreted* has to reach the patch, and
a review measured three ways that was not happening.

`OTHER_SWIFT_FLAGS` was read for one `doctor` check and otherwise dropped. A
project putting `-DUSE_LIVE_PRICING` there --- the same file this tool asks
projects to base Debug on --- had `#if USE_LIVE_PRICING` take the other branch
in every patch, silently. `-enable-bare-slash-regex`, which Xcode passes as a
matter of course, made every body containing a regex literal fail to compile
against generated source. It is now forwarded whole.

`SWIFT_UPCOMING_FEATURE_*` was forwarded by its setting suffix. Xcode turns
`SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY` into
`-enable-upcoming-feature ExistentialAny`; this passed `EXISTENTIAL_ANY`, and
swiftc accepts an unknown feature name without a word --- so it forwarded
nothing, for every feature, silently.

The language mode is per *module*, and this was per project. `-showBuildSettings`
reports the targets of the scheme and a local package's are not among them, so
the daemon used the application's for everything: in the example project, a
Swift 6 package compiled under Swift 5. Measured accepting a body the project's
own compiler rejects as a data race --- which is precisely what forwarding the
language mode exists to prevent. A package target's mode is now read from its
manifest, and a manifest that cannot be evaluated is refused rather than
guessed.

One thing the same review found *not* to be a problem is worth writing down, so
it is not re-litigated. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is not
forwarded, and does not need to be: a declaration's isolation is serialized into
the module, and `@_dynamicReplacement` takes the replaced declaration's. Marking
the replacement `nonisolated` explicitly is rejected, and an ordinary function
in the same patch touching the same state is rejected too --- only the
unannotated replacement compiles, which is the one the generator writes.

### 6.4 What a patch links against

Not always the executable. Xcode 16 and later build a Debug
configuration as a thin launcher plus a `.debug.dylib` holding the code,
and the replacement keys are all in the dylib --- the executable has
none. Linking a patch against the executable therefore resolves nothing,
and the symptom is indistinguishable from a project that was never
configured: `doctor` reports zero keys for a build whose settings are
entirely correct.

`BuildContext.debugDylibPath` is set from the build's own
`ENABLE_DEBUG_DYLIB`, never inferred from the file being present. A
dylib from an earlier build is still on disk after the setting is turned
off, and preferring it would be worse than useless: the patch would link
against a binary the process is not running, and `dlopen` would resolve
the load command by bringing a second copy of the whole app module into
the live process. Replacements would bind into the copy, the running
code would be untouched, and the tool would report success.

### 6.5 Which module a file belongs to

An app is rarely one module, and the build system will not say which one a
file is in: `xcodebuild -showBuildSettings` reports the scheme's targets
and a local Swift package's targets are not among them.

It is inferred from the path instead, using the layout SwiftPM requires
--- a target's sources under `Sources/<TargetName>/` beneath a
`Package.swift`. A wrong guess cannot pass silently, because the module
has to appear in the built binary's replacement keys before anything is
generated for it.

That check is also the answer to a harder problem. Xcode propagates
`SWIFT_OPTIMIZATION_LEVEL` and `SWIFT_ENABLE_TESTABILITY` into package
targets but not `OTHER_SWIFT_FLAGS`, so a package in a correctly
configured project compiles with no implicit dynamic and produces no
replacement keys --- while every build setting the daemon can see still
says the project is set up. Counting the keys the binary exports, per
module, is the only check that notices, and it turns an edit that
silently did nothing into a refusal that names the module and the one
line of manifest that fixes it. `integrations/xcode/Package.md` has the
measurement and the snippet.

A local package's code links into the application binary, so the patch
still links against the same target as an app-module patch does.

### 6.6 What else has to reach the patch

Anything that changes how the patched body is *interpreted*, not only
what it can see. Conditional compilation flags are the obvious case: a
`#if` inside a patched body must take the branch the app took.

The dangerous one is the language mode. A body written for Swift 6 and
type-checked under Swift 5 loses isolation inference and sendability
checking, so the replacement can introduce a data race the original
could not have had --- and it fails in the permissive direction, which
is the one that matters. `SWIFT_VERSION`, `SWIFT_STRICT_CONCURRENCY`,
and any `SWIFT_UPCOMING_FEATURE_*` are forwarded alongside the
conditions.

Xcode reports the language mode as `5.0` and `6.0`; the compiler accepts
only `4`, `4.2`, `5`, and `6`.

### 6.3 Validation

Before applying a patch, compare:

``` text
running build identity
vs
patch build identity
```

At minimum validate:

-   module,
-   target architecture,
-   SDK family,
-   Swift compiler identity,
-   language mode,
-   the link target's Mach-O UUIDs.

The last one is the only entry that separates two builds rather than two
configurations, and it is the only one the runtime can check against the
*process*. Everything above it is a string the daemon wrote into the
session file and the runtime read back, so comparing them said nothing
about the binary the process is executing. Measured: rebuild an app while
it is running and every field above matched, so a patch linked against the
new binary was applied to a process running the old one; with the UUIDs it
is refused, naming the rebuild.

Two details are load-bearing. A Simulator binary is universal and
`dwarfdump --uuid` prints a different UUID per architecture slice, so the
daemon sends all of them and the runtime matches whichever it is running
--- taking the first gave the x86_64 slice's while the process ran arm64.
And the daemon re-reads them whenever the binary's size or modification
date changes, not once per session: the module inventory may be cached on
the grounds that a rebuild means a relaunch, and this check exists
precisely because it does not.

## 7. Change detection and classification

### 7.1 File watcher

The watcher emits:

``` text
SourceChanged(path, timestamp)
```

Debounce rapid editor writes.

### 7.2 Classifier

The classifier compares old and new declaration structure.

Output:

``` text
ChangeClassification
├── hotPatch(declarations)
├── experimental(reason, declarations)
└── rebuildRequired(reason)
```

### 7.3 Initial rules

#### Safe candidate

Same declaration identity and ABI-relevant signature, body changed only.

Examples:

``` swift
func f(_ x: Int) -> Int
```

body changes while signature remains identical.

Methods on:

-   class,
-   struct,
-   enum.

`mutating` status must remain unchanged.

`private` and `fileprivate` declarations are among them. Under
`-enable-private-imports` they have replacement keys like any other and the
patch names them through `@_private(sourceFile:)`, so nothing about them is
special. Section 7.3c is how that was decided and what it replaced.

One further shape is a safe candidate without being a body-only change: a
declaration that did not exist in the built binary. It is carried in the
patch rather than replacing anything. Nothing already running can call it,
so it displaces nothing and changes no layout.

#### Unsafe

-   stored-property set/layout changed,
-   function parameters changed,
-   return type changed,
-   async/throws/isolation characteristics changed unless proven
    ABI-compatible,
-   enum cases changed,
-   generic signature changed,
-   inheritance changed,
-   conformance changes that affect witnesses/layout,
-   declaration removed while referenced,
-   any declaration returning an opaque result type (`some P`), whether
    or not the underlying type changed --- see section 12.7,
-   property observers (`willSet`/`didSet`), which look like accessors
    but have real backing storage,
-   operator declarations, which are replaceable but whose
    `@_dynamicReplacement(for:)` spelling this generator does not know,
-   protocol requirements, whose shape is the witness table's,
-   body of an `@inlinable` or `@_transparent` declaration changed ---
    implicit dynamic does not cover these, so the patch cannot be built;
    see section 12.8,
-   body of a `private` or `fileprivate` declaration changed, where any
    caller cannot itself be replaced: an initialiser, a stored property's
    initial value, a top-level statement, or an `@inlinable` body. The copy
    the patch carries would then be reached by some callers and not others,
-   an `override` or `@objc` declaration *added*. An extension is the only
    place a patch can put a member, and it may declare neither,
-   a declaration *removed*. The original stays in the binary and nothing
    can say what still calls it,
-   a declaration *added* that overloads a name already in the binary.
    Adding `kind(_: Int)` beside `kind(_: Any)` changes what every existing
    call to `kind` resolves to, including from bodies the edit did not touch
    and the patch does not replace. Measured: one caller edited, the other
    left running the old resolution, and the process matched no version of
    the file while the reload reported success,
-   a body using `#function`, `#file`, `#fileID`, `#filePath`, `#line`,
    `#column`, or `#dsohandle`. These expand against the declaration the
    patch emits, not the one in the source: measured, `#function` in a
    replaced body reported `splice_g1_label____()`. Nothing warns, and the
    wrong value lands in the code that exists to say where you are. Only the
    literal written in the body is detected; one arriving through a callee's
    default argument, as in `func log(_ m: String, function: String =
    #function)`, is evaluated at the call site and so also expands in the
    patch. That case is a known limitation rather than a refusal,
-   a computed property gaining or losing an accessor. `var v: Int` reads the
    same either way, so this looked like a body change: the patch loaded,
    reported a reload, and the new setter was dead, because the original key
    has none to bind to. The accessors a property declares are part of its
    signature.

### 7.3b Reach

The question this section does not otherwise answer is what fraction of
ordinary edits reach a running process.

Measured by editing every function body, accessor, `init`, `subscript` and
`deinit` in turn, across three hand-written files in the shapes this tool is
for --- an `ObservableObject` view model, an `actor` service, a view controller
--- and classifying each edit on its own:

``` text
                            bodies   before   after
CartViewModel.swift             10        2       9
FeedService.swift                9        1       9
ProfileViewController.swift     13        2      13
                                32        5      31
```

Before and after are the same files and the same sweep, run against the
classifier as it stood at commit 90eefba and as it stands now. What changed
between them is section 7.3c.

Every one of the twenty-seven refusals in the "before" column names a
`private` declaration the patch could not reach --- a stored property, a
helper, a type. That was not the analysis being blunt. A patch simply could
not write the name down, because `@testable import` elevates `internal` and
stops there, and a method that touches private state is most methods in most
real types. A view controller is almost entirely methods that touch private
outlets, which is why it scored two.

The one refusal left is an `init`, which is residue and always was.

Two whole-file limits remain, both unrelated: nothing inside an `#if` is ever
patchable, since the block is residue, and a removed declaration is a rebuild.

### 7.3c Private imports

`-Xfrontend -enable-private-imports` on the module's build, and
`@_private(sourceFile:)` on the patch's import.

Measured on Xcode 26.2 through 27.0 Beta 4, on the macOS host and on an iOS
Simulator, and pinned by seven fixtures:

``` text
read a private stored property from a patched body    works
replace a private function directly, by its own key   works
replace a member of a private type                    works
a default argument's generator sees the replacement   works
an existential through a private witness table        works
an overridden fileprivate member keeps its dispatch   works
without the flag: rejected at COMPILE                 works
```

The second line is the one that mattered. With private imports a private
declaration has a replacement key of its own, so it is *replaced* rather than
copied --- and the replacement was observed through an unpatched caller, which
a copy could never be.

That distinction is why this section replaced a large amount of code rather
than adding to it. Reaching a private declaration by copying meant carrying
the copy in the patch and replacing every caller, which needed a call-graph
closure over the file and three guards around the ways a copy can be reached,
or not reached, by something the analysis could not see: an override that
turns a copy into a statically-dispatched impostor, a default argument's
generator that keeps calling the original, a witness table entry that is not a
syntactic reference at all. Two reviews found ten defects in that machinery,
every one of them a consequence of copying rather than replacing. Replacement
has none of them, and the machinery is gone.

What it costs, measured on `examples/XcodeApp`:

``` text
debug dylib                496,664 -> 502,216 bytes   +1.1%
clean build                     10 s -> 8 s           no penalty
incremental build         2,094-2,317 -> 1,986-2,382 ms   no difference
dispatch, 20M calls          1,455 -> 1,461 ms        +0.4%
```

The costs it does carry are not in the numbers. It is a second undocumented
frontend option to keep behind the adapter in section 4.4, and it changes what
every integrating project must build with --- one line in the xcconfig, and one
per local package, since Xcode does not pass `OTHER_SWIFT_FLAGS` into package
targets. `doctor` asks the compiler per module rather than reading the setting,
because a setting can be right in a file nobody has rebuilt since; that exact
mistake is how this was first measured wrong.

A patch emits the private import only for files that declare something
file-local, so a project that has not added the setting keeps working for
every file without private code rather than failing everywhere at once. The
test is syntactic and does not evaluate `#if`, so a `private` declaration in a
branch this build never compiles still counts --- the fallback is a courtesy
during migration, not a guarantee. When
it does fail, `PatchCompiler` translates the compiler's diagnostic into the
setting that is missing.

### 7.3d What a patch leaves behind

A patch is not only applied, it is *remembered*. Two things a session emits do
not exist anywhere else, and the next patch for that file has to account for
both.

A carried declaration lives in the patch dylib and in no other image. When the
patch lands the baseline advances, so on the next save that declaration is no
longer an addition --- and without a record of it, it is neither carried again
nor replaceable. Every later patch naming it fails to compile, permanently for
that file, since a rejection does not advance the baseline either. Measured
four ways in, one of them the most ordinary loop there is: extract a helper,
then keep tuning the caller.

A replaced body calls the copy in *its own* patch. So when a carried
declaration changes, every body that calls it has to be re-emitted alongside,
or those callers keep running against the older copy.

Both follow from one rule rather than a case each: **a patch for a file
contains the current version of everything this session has changed in that
file.** `SessionMemory` is the two sets that make it hold, and the newest
generation wins for all of them (Appendix A, `two-generations`).

None of this was visible to the test suite, because every end-to-end test ran
exactly one generation. `Loop.runGenerations` is the harness that would have
caught it.

### 7.4 Implementation options

Phase 1 can be conservative and file/declaration based.

Candidates:

-   SwiftSyntax for syntactic declaration comparison,
-   SourceKit for semantic information,
-   compiler AST integration if required later.

Do not embed Swift compiler internals until simpler mechanisms fail.

The implementation uses SwiftSyntax, and so far nothing has needed
semantic information. Two details make the syntactic approach hold up:

-   Everything the indexer does not model is hashed into a residue, so a
    change nobody classified still forces a rebuild rather than passing
    unnoticed. Being unable to parse something is a rejection, not a
    blind spot --- which only holds if there is no path out of the
    indexer that writes nothing anywhere, and one such path (a
    comma-separated `var a = 1, b = 2`) got as far as a review before
    being found. The residue preserves document order: sorting it made a
    pure reordering of declarations invisible.
-   Declaration identity carries parameter types, not only argument
    labels, so overloads stay distinct. Keying on labels alone let two
    overloads collide in the index, and an edit to whichever one lost
    the write disappeared without either a patch or a rebuild.
-   Two declarations that still reduce to the same identity are both
    demoted to unsupported rather than one silently overwriting the
    other.
-   Generation reuses the original declaration node as a template and
    rewrites only its name, instead of reassembling a signature from
    parts. Reassembly would eventually drop something --- an ownership
    modifier, a global actor, a where clause --- and the failure would
    be silent.

## 8. Replacement generation

Given original:

``` swift
struct Calculator {
    dynamic func calculate(_ x: Int) -> Int {
        x * 2
    }
}
```

and a body edit, conceptually generate:

``` swift
extension Calculator {
    @_dynamicReplacement(for: calculate(_:))
    func __shr_calculate_generation_42(_ x: Int) -> Int {
        x * 100
    }
}
```

Actual generation must preserve:

-   generic parameters,
-   constraints,
-   actor/global-actor annotations,
-   `async`,
-   `throws`,
-   ownership/calling-convention-relevant attributes,
-   access needed to compile,
-   declaration context.

### 8.1 Internal/private access

Originally recorded as an open research risk. It is now resolved for
`internal` declarations.

A separately compiled patch reaches `internal` declarations by importing
the application module with `@testable`, which requires the application
to be built with `-enable-testing`. This is the same mechanism unit test
bundles already use, and it simultaneously satisfies the symbol
visibility requirement in section 5.4.

Generated patch source therefore begins with:

``` swift
@testable import <ModuleName>
```

Still open:

-   `private` / `fileprivate` declarations, which `@testable` does not
    expose,
-   declarations in modules the application consumes as binary
    dependencies,
-   whether per-file same-module compilation is ever preferable to
    external-module extensions.

## 9. Patch compilation

### 9.1 MVP artifact

Preferred MVP artifact:

``` text
Patch_<generation>.dylib
```

Reason:

-   easiest way to validate Swift runtime registration,
-   normal dyld path handles Mach-O metadata,
-   minimizes custom linker/runtime work.

### 9.2 Alternative artifact

If direct dylib generation is awkward:

``` text
.swift -> .o -> link -> .dylib
```

Keep compile and link timing separate.

Measured note from `examples/CounterApp`: linking the patch against the
application binary with

``` text
-Xlinker -bundle -Xlinker -bundle_loader -Xlinker <app binary>
```

is preferable to `-undefined dynamic_lookup`. It resolves replacement
keys at LINK, so a declaration that is not actually replaceable fails
with `Undefined symbols` before anything reaches the running process.
`-undefined dynamic_lookup` is also deprecated for the iOS Simulator.

### 9.3 Artifact validation

Before requesting runtime load, inspect:

-   architecture,
-   platform,
-   minimum OS,
-   expected replacement symbols/sections where feasible, keeping in
    mind that an absent native replacement key does not by itself prove
    a declaration is unpatchable (section 12.8),
-   unresolved dependencies if detectable.

## 10. Runtime loading

### 10.1 MVP

The runtime receives a patch-generation request and loads the generated
image using supported Simulator/macOS dynamic loading mechanisms.

Conceptual API:

``` swift
struct LoadPatchRequest: Codable {
    let generation: UInt64
    let path: String
    let buildIdentity: String
}
```

Result:

``` swift
enum LoadPatchResult: Codable {
    case loaded(generation: UInt64, durationMs: Double)
    case rejected(reason: String)
    case failed(stage: String, message: String)
}
```

### 10.2 Lifecycle

Initially, loaded generations may remain resident for the lifetime of
the process.

Do not attempt unloading until replacement-chain semantics and Swift
metadata lifetime are understood.

This trades memory for correctness during early development.

## 11. IPC

### 11.1 Requirements

-   local development only,
-   low latency,
-   bidirectional diagnostics,
-   reconnectable after app relaunch,
-   simple to debug.

Candidate transports:

-   Unix domain socket where practical,
-   localhost TCP with session token,
-   other Simulator-friendly local IPC.

MVP should optimize for observability rather than cleverness.

### 11.1a What a connection is allowed to do before it proves itself

Accepting a socket is not the same thing as becoming the session, and for most
of this project's life it was.

An incoming connection used to clear the session, fail every request in flight,
and take the slot before a single byte was read. Measured against the sample
app: a loop that opened and closed a TCP connection every 20 ms made four
consecutive saves fail with "no app is connected", printed seventeen
`connected` lines, and never printed `disconnected` --- because the eviction
path did not go through the code that reports one. Anything on the machine
could end a developer's session: a port scan, a stray `nc`, a second `watch`.
The session token, added later, did not help: by the time a peer's `hello` is
examined, the app has already been evicted.

So a connection now carries its own buffer and nothing else until its `hello`
presents the token. Only then does it supersede whatever held the session, in
that order: the old socket is cancelled, what it was carrying is settled, the
new session is announced.

Two limits belong to the same change. A peer that never completes a message is
dropped at one megabyte, and the newline search resumes where the last one
stopped rather than re-scanning the whole accumulation --- 32 MiB of
newline-free bytes cost 61 seconds at 100% of a core, on the same serial queue
that fires reply handlers and request timeouts, so a half-millisecond save
became a 32-second stall and then a poisoned session. The same flood now costs
3 ms.

### 11.2 Protocol

Messages SHOULD be versioned:

``` json
{
  "protocolVersion": 1,
  "type": "loadPatch",
  "requestId": "...",
  "payload": {}
}
```

Protocol incompatibility should fail with a clear diagnostic.

## 12. Dynamic replacement constraints

### 12.1 Struct support

Struct methods are not excluded merely because the receiver has value
semantics.

A body-only method replacement can operate on existing struct values so
long as the ABI/layout and method signature remain compatible.

### 12.2 Layout changes

This is not supported:

``` swift
struct User {
    var name: String
}
```

to:

``` swift
struct User {
    var name: String
    var age: Int
}
```

Existing values were allocated according to the old layout. The tool
must require rebuild/restart.

The same principle applies to class stored layout and ABI-relevant enum
changes.

### 12.3 Optimization

Hot reload assumes a Debug configuration that preserves replacement
dispatch.

Do not support optimized Release behavior in v0.x.

### 12.4 Generics

`-enable-implicit-dynamic` does emit a replacement key for generic
declarations, and a generic function body replacement has been observed
to work under `-Onone` (Appendix A).

Remaining risks concern optimized or already-specialized call paths:

-   specialization,
-   metadata accessors,
-   witness tables,
-   pre-existing specialized call paths.

Because the supported configuration is `-Onone`, a generic *body* change
may be treated as a hot patch candidate. A generic *signature* change
remains rebuild-required.

### 12.5 Protocol witnesses

Measured (Appendix A): a replacement applies to both direct and
existential dispatch, and to default implementations declared in
protocol extensions. The earlier concern that witness-mediated calls
would diverge from direct calls was not borne out.

Keep explicit fixtures anyway, to catch regressions across toolchains:

``` swift
protocol P { func f() }
struct S: P { func f() {} }
```

Test both:

``` swift
S().f()
```

and:

``` swift
let p: any P = S()
p.f()
```

### 12.6 async/await and actors

Treat as experimental until tested.

Fixtures must cover:

-   async instance method,
-   throwing async method,
-   `@MainActor`,
-   actor instance method,
-   task already suspended when patch loads,
-   invocation started after patch loads.

Expected initial semantic rule:

> Existing stack frames continue executing old machine code; future
> calls may use the replacement.

This must be verified.

Measured (Appendix A): `async`, `throws`, `async throws`, `actor`
instance methods and `@MainActor` methods all replace successfully with
state preserved, for invocations started after the patch loads. The
already-suspended-task case is still owed.

### 12.7 Opaque result types are memory-unsafe to change

This is the most dangerous case found so far, because the compiler does
not diagnose it.

Given:

``` swift
struct Opaque {
    var body: some CustomStringConvertible { "OLD" }
}
```

a replacement whose underlying type differs:

``` swift
extension Opaque {
    @_dynamicReplacement(for: body)
    var __patched: some CustomStringConvertible { 42 }   // String -> Int
}
```

**compiles without error or warning** and loads successfully. What
happens next is undefined.

Across otherwise similar programs the same edit has produced the new
value, garbage characters, and `SIGSEGV` with no diagnostic output. The
determining factor observed so far is whether the opaque type's metadata
had already been resolved before the patch loaded: a program that reads
the property only after loading tends to get the new value, while one
that read it beforehand reads an `Int` through cached `String` metadata.

It diverges by platform too. The identical fixture returns the new value
on the macOS host and crashes with `SIGSEGV` on the iOS Simulator.

Undefined behavior that sometimes produces the right answer is worse
than a reliable crash, because it survives casual testing.

Consequences:

-   the classifier is the only defense; neither the compiler nor the
    loader provides one,
-   any declaration returning an opaque result type MUST be
    rebuild-required unless the underlying type is proven identical,
-   this is the ordinary SwiftUI `var body: some View` case, so it
    governs section 13.

The fixture for this case records the observed outcome rather than
asserting one, since pinning an expectation to undefined behavior would
only produce a flaky test.

The classifier rejects any declaration whose result type mentions
`some`, without trying to establish whether the underlying type actually
changed. Proving that needs type checking, and the cost of being wrong
is not symmetric: over-rejecting costs a rebuild, under-rejecting
corrupts a process. A review found this check missing entirely --- the
signature text `var body: some View` is identical before and after, so
neither the signature comparison nor the residue noticed --- which meant
the case the design calls its most dangerous was undefended in the
implementation. `Tests/SpliceGenTests/SoundnessTests.swift` pins it.
### 12.8 What implicit dynamic does not cover

`-enable-implicit-dynamic` is not exhaustive. Measured coverage
(Appendix A):

``` text
covered      internal, public, @usableFromInline
             static and class methods
             init, subscript, operator functions
             computed properties, lazy properties
             nested type methods, extensions on imported types
             generic functions

not covered  @inlinable
             @_transparent
             private, fileprivate
             deinit
```

Overrides are covered, and were refused for years of this document's life
on the mistaken ground that they could not be. The replacement is a
separate declaration bound to the original's key rather than an override
of its own, so an extension accepts it, and the original is then reached
through the base class, through `objc_msgSend`, and from a body calling
`super`. Pinned by `fixtures/Cases/override-*`.

Every uncovered case fails at the COMPILE stage with an actionable
diagnostic, so the fail-closed principle in section 2.4 holds:

``` text
@inlinable / @_transparent
  error: replaced function 'f()' is not marked dynamic

private / fileprivate
  error: replaced function 'f()' could not be found
```

The `private` row holds only without `-enable-private-imports`. With it,
private and fileprivate declarations get keys like anything else and are
replaced normally; section 7.3c has the measurements and what adopting it
removed.

Two cautions apply to reading this table.

First, an absent replacement key does not prove a declaration is
unpatchable. An `@objc` member of an `NSObject` subclass gets no native
`Tx` key because it dispatches through the Objective-C runtime, yet
dynamic replacement still applies to it.

Second, the covered set is undocumented and version-sensitive. Treat the
table as a per-toolchain measurement, not a language rule, and re-run
the fixtures when the toolchain changes.

## 13. SwiftUI design

SwiftUI support is a separate compatibility layer, not a prerequisite
for core replacement.

Problem:

``` swift
var body: some View
```

may preserve its source-level signature while its opaque underlying
result type changes when the view tree changes.

**Measured, and it is not what section 12.7 predicted.**

`View` is the one protocol found to carry a type eraser:

``` swift
@_typeEraser(DebugReplaceableView) @_typeEraser(AnyView)
@preconcurrency @MainActor public protocol View
```

A *whole* opaque return type spelled `some View` is therefore already
erased to a concrete type regardless of what the body returns.

Which of the two erasers applies depends on the deployment target.
`DebugReplaceableView` is available from iOS 26 and macOS 26; below
that the compiler falls back to the second one, `AnyView`. Both are
concrete, so the property that matters holds either way, and the
fixture asserts that one of them applied rather than naming one. It
originally named `DebugReplaceableView`, which passed on every machine
here and failed on the first CI runner that was older --- which is a
fair summary of why the matrix needed to leave one laptop.

The word whole is load-bearing. Erasure does not reach an opaque
position nested inside a type: `func f() -> (some View)?` measures as
`Optional<Text>`, unerased, and replacing it with a different tree
crashes the process exactly as section 12.7 describes. The exception is
recognised by matching the return type against `some View` at the root
and requiring the file to import SwiftUI, because the guarantee comes
from `@_typeEraser` on Apple's `View` and not from the spelling --- a
`some ViewModelProtocol`, or a protocol of one's own named `View`, has no
eraser at all. The undefined behaviour in section 12.7 comes from a
caller holding stale metadata for a type that changed; here there is no
such type. Changing a view tree's shape in a patch is safe. A fixture
pins this, and a second one pins that the replacement dispatches: a
direct read of `body` after loading really does run the new code.

It renders, too --- and it still must not be allowed, for a reason that
took three attempts to state correctly. Section 13.1 has the
measurements.

A replaced `body` runs whenever SwiftUI evaluates that body, and
produces the new tree on screen. What it also does, when the body's
concrete type changes and the view is a row of a `List`, is abort the
process. The erasure makes the *return* type concrete; it does not make
the type behind it free to change, because `DebugReplaceableView` keeps
its child in a generic box that the graph downcasts to whatever it saw
first. So section 12.7 is relocated rather than escaped.

The classifier refuses `some View` by default, with wording of its own rather
than the undefined-behaviour one, because "undefined at runtime" is the wrong
description of a clean `SIGABRT` in a cast --- and because the two earlier
wordings, "does nothing" and "is safe and useless", were both measured wrong.
Section 13.4 describes the explicit boundary that lifts this refusal without
trying to infer the underlying type.

### 13.1 Three answers, and the measurements that separate them

This section has carried three conclusions. The first two were wrong,
and it is worth being precise about how, because the same mistake is
available to anyone who measures this again.

**One: "SwiftUI never evaluates a body through the replacement."**
Wrong. It was measured on a view SwiftUI had no reason to evaluate. A
view whose value compares equal to its predecessor is skipped, so a
stateless view's body runs once at launch and never again --- and that
looks identical to a body being evaluated and ignored unless you log
from inside it. The corrected experiment logs every evaluation:

``` text
                      before the patch        after the patch loads
Stateless   no stored properties      1 eval  never evaluated again
Valued      takes a changing value    every tick   every tick, NEW
Stateful    drives its own @State     every beat   every beat, NEW
```

and the screen agreed exactly: `Stateless: OLD`, `Valued: NEW 7`,
`Stateful: NEW`. So a replaced body **does** run, and renders, with no
invalidation sent to SwiftUI at all. Measured under both erasers.

**Two: "so it is safe, and the refusal was wrong."** Also wrong, and
this one had a patch shipped against it for a few hours. Changing the
body's concrete type aborts the process:

``` text
Could not cast value of type
  'DebugReplaceableViewStorage<VStack<TupleContent<Pack{Text, Text}>>>'
to
  'DebugReplaceableViewStorage<Text>'
```

`SIGABRT`, in `DebugReplaceableViewChild.updateValue()` under
`AG::Graph::UpdateStack::update()`. The eraser erases the outer type and
stores the child in a *generic* box; the graph downcasts that box to the
type recorded on first evaluation. A concrete return type does not make
the underlying type free to change.

Two conditions, both measured by changing one thing at a time:

-   **The eraser.** At an iOS 18 deployment target `some View` erases to
    `AnyView`, which tolerates a type change because that is what
    `AnyView` is for, and the same patch renders correctly. At iOS 26
    and later it is `DebugReplaceableView`, and it aborts.
-   **The container.** The same patch against the same view is harmless
    inside a `VStack` and aborts inside a `List` --- changing only that
    line turns one into the other. `List` builds a view list, which is
    the path the generic storage is cast on. `List` is not a corner
    case.

The reach of the damage is what makes this a refusal rather than a
caveat. The safe set is exactly "edits that leave the body's concrete
type bit-identical" --- a different string, a different number, a
modifier that happens to return the same type. Adding `.padding()` is
outside it. Nothing syntactic tells those apart reliably, and the cost
of being wrong is the developer's process, so the whole shape is
refused.

**Three: refused by default, because a change to the underlying type aborts.**
That remains the answer for an unannotated body, and unlike the first two it names a
mechanism that was reproduced from a clean container, with a single
patch, on two deployment targets.

It is also the first of the three with an artifact. `fixtures/ui/`
builds a rendering application, delivers one patch, and asks whether the
process is still beating; four cases hold the whole statement in place
--- the abort in a `List`, the same patch surviving in a `VStack`, and a
literal-only edit surviving in the `List`, plus the shape change surviving
behind the opt-in boundary with its `@State` unchanged. The console matrix could not
have caught any of this, and `swiftui-body-direct-call` passed happily
through both wrong answers because a direct read of `body` never touches
the storage that aborts.

The measurement that would change it is Apple making the storage
non-generic, or `some View` ceasing to erase to `DebugReplaceableView`.
Neither is something this project can arrange.

### 13.2 What the opt-in does not attempt

Nothing about reaching a body is open. Nor does the implementation attempt to
identify edits that happen to leave the concrete type equal. A token-level
comparison that ignores literal contents is not sound, since a literal's
*type* can change what a generic expression instantiates to. The opt-in instead
makes the body concrete type `AnyView` before the session starts. That is a
property the classifier can see on both sides of an edit, not a claim about
what an arbitrary view-builder expression means.

### 13.3 The `DebugReplaceableView` route, followed and closed

Followed before the mistake above was found. Kept because it answers a
question this document had been carrying, and because it says something
about a route somebody will otherwise try again --- but note that it is
no longer needed for anything.

`DebugReplaceableView` is a struct with `Body = Never` and a `_makeView`
of its own; it conforms to SwiftUI's internal `DynamicView` and holds
its erased child in a class, so the child could in principle be swapped
without disturbing any layout. SwiftUICore exports

``` text
T _$s7SwiftUI20DebugReplaceableViewV20invalidateEverythingyyFZ
     static SwiftUI.DebugReplaceableView.invalidateEverything() -> ()
```

which is absent from the swiftinterface but externally visible, so
`dlsym` finds it. Disassembled, it takes an unfair lock and walks a
global `LazyContainerManager`, with no feature check in it. Called from
an application it returns without doing anything observable.

The reason is that the dynamic path is gated on
`_ViewListInputs.debugReplaceableViewCount`, an optional box the view
host passes down. Neither it nor `DebugReplaceableViewCount` nor
`DebugReplaceableViewInfo` appears in the swiftinterface, and
`_ViewListInputs` itself is public and **empty**:

``` swift
public struct _ViewListInputs { }
```

An opaque token with no members and no initialiser, so only whatever
creates the host --- Previews --- can supply the input, and the manager
`invalidateEverything` walks is empty in an ordinary application.

Worth keeping because it is the route somebody will otherwise try
again, and because the storage it describes is the same storage section
13.1 measures aborting: `DebugReplaceableViewStorage` is where both the
hoped-for hook and the actual crash live.

Apple exposes `DebugReplaceableView` for debug-time replacement
scenarios. Three facts constrain its use:

-   it is declared in **SwiftUICore**, not SwiftUI, and reaches callers
    through SwiftUI's re-export;
-   it is annotated
    `@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)`;
-   it is already in play whether or not anyone asks for it, as the
    first `@_typeEraser` on `View` --- but only where it is available.
    Below iOS 26 or macOS 26 the second eraser, `AnyView`, applies
    instead.

Any SwiftUI support that calls this private invalidation route directly would
therefore carry a hard deployment-target floor that core function replacement
does not. `SpliceSwiftUI` does not use the route: its explicit `AnyView`
boundary works below and above that floor.

`SWIFT_ENABLE_OPAQUE_TYPE_ERASURE` maps to
`-enable-experimental-feature OpaqueTypeErasure` and defaults to NO, but
erasure of `some View` was observed with the flag on, off, and absent, so
on this toolchain the setting is not what turns it on.

### 13.4 Explicit `AnyView` boundary

The shippable route uses two source-level opt-ins and no SwiftUI internals:

``` swift
struct ReceiptView: View {
    @ObserveSplice private var splice

    var body: some View {
        ReceiptContents()
            .enableSplice()
    }
}
```

In Debug, `.enableSplice()` returns `AnyView`. Because it is the outermost
expression from the initial build onward, the generic child stored by
`DebugReplaceableView` is `AnyView` in every generation even when the tree
inside it changes. In Release it is an inlined identity returning `Self`.

`@ObserveSplice` is a `DynamicProperty` containing an `@ObservedObject`. The
core runtime publishes a generation only after `dlopen` succeeds; the separate
`SpliceSwiftUI` target maps that framework-neutral SPI event onto the main
actor and increments the object. SwiftUI therefore invalidates the enclosing
View and calls the replaced getter. Keeping the adapter in a separate target
means a UIKit-only application links `SpliceRuntime` without importing
SwiftUI or Combine.

Measured in `fixtures/ui/Cases/body-shape-change-enabled-in-list`, on the same
iOS 27 `List` where an unannotated body aborts:

``` text
body                         Text -> VStack<Text, Text>
process                      alive
rendered                     old -> new
Row @State UUID              unchanged
registered replacements      2
```

Two replacement records are expected: one for the getter and one for its
opaque-result descriptor. The classifier records both, so REGISTER can verify
the image instead of treating every SwiftUI reload as an unexplained overcount.

The method spelling is not trusted as a type proof. Generated source assigns
the edited body's outer call to a module-qualified `SwiftUI.AnyView` temporary.
That result context makes the compiler select the erasing overload instead of
a same-spelled overload returning `Self`. For the running generation, the
daemon reserves `enableSplice` across the watched source files in the same
module, because overload lookup performed in the patch module cannot reproduce
the original app module's choice for an imported extension.

The syntax rule is deliberately narrow. The enclosing nominal type must have
`@ObserveSplice` in the same file, that file must import `SpliceSwiftUI`
unconditionally as a top-level whole-module import, the declaration must be
`body: some View`, and the implicit
getter's outermost expression must be `.enableSplice()` in both the built and
edited source. The import prevents an unrelated same-spelled API from widening
the opaque-result exception. Adding either opt-in changes layout or type
semantics and therefore requires one rebuild before a reload session. Applying
the modifier to a child, using an explicit accessor shape not measured, using
only a conditional, declaration-level, or re-exported import, qualifying the
observer through another module, or placing the observer in another file is
refused. These are false negatives, not invitations to guess.

The rendering fixture drives the same `Splice.load(generation:path:)` function
as the daemon; `loadPendingPatches()` only supplies its inbox and synthetic
generation number. This keeps the standalone fixture independent of IPC while
preventing the notification paths from drifting. The opt-in case is also run
at deployment targets 18 and 27: below the `DebugReplaceableView` availability
floor and above it.

State preservation has the normal SwiftUI boundary. State owned by the
annotated View survives, as measured. State inside a subtree whose identity or
shape the edit replaces follows SwiftUI reconciliation and is not promised to
survive.

Implemented layering:

``` text
CoreReplacementEngine
        |
        +-- Plain Swift
        |
        +-- UIKit adapter
        |
        +-- SwiftUI adapter
              |
              +-- explicit AnyView boundary
              +-- generation observer
              +-- state-preservation fixture
```

Do not couple core runtime correctness to undocumented SwiftUI
internals.

## 13a. UIKit adapter

Measured. Section 13 reached a similar place by a different road: both
frameworks run a replaced body when they call it again, and the work is
in getting them to call it again.

UIKit dispatches at call time --- through the class's vtable, or through
`objc_msgSend` for an `@objc` member --- so every entry point it calls
again reaches the replacement. Nothing about a loaded image makes it
call anything again, which is the whole of the problem and the whole of
the fix. `runtime/Sources/UIKitRefresh.swift` sends the reasons: it
invalidates layout, constraints, and drawing across every window, and
reloads every table and collection view. `Splice.RefreshOptions` is
what an application can turn off.

Three declaration shapes, each with a fixture:

``` text
uikit-live-instance   layoutSubviews, viewWillLayoutSubviews, draw(_:),
                      and an @objc method, on the controller and view
                      that already exist                           -> new
uikit-data-source     cellForRowAt, a protocol requirement on a
                      separate object, after reloadData            -> new
uikit-view-did-load   viewDidLoad, unprompted                      -> not called
```

Three *declarations*, one dispatch shape. Every entry point above is
`@objc`, so all three patches carry an Objective-C category and no
`__swift5_replace` section (section 13a.2), and the vtable half of the
sentence above is exercised by the host cases rather than by these. The
UIKit method a developer most often edits is the other kind --- an
ordinary Swift method the controller calls --- and that is what the
example app demonstrates.

The cases are Simulator-only, which `fixtures/run.sh` learned to
express: `PLATFORMS` in `case.conf`, validated against the platforms the
runner knows, and a skipped case is counted and named rather than
quietly absent. Asking for a skipped case by name exits non-zero, since
a request that ran nothing is not a pass.

They run as a console process with no `UIApplication`, so the views are
alive but on no screen and the render pass is forced by hand. What they
pin is dispatch. The runtime's window discovery --- walking
`connectedScenes` --- needs a real application and is covered only by
the example below.

`examples/UIKitApp` is the shape this section is about: a storyboard, a
scene delegate, a navigation controller, a table view with prototype
cells, an outlet, a segue and an `@IBAction`. It is where the two halves
of the one-shot note are visible next to each other --- `awakeFromNib`
on a pooled cell, which the reuse pool means really does not change, and
the application delegate, where the advice is that a build is needed.
Both were measured against it, and the screen agreed with what `watch`
said in each case.

End to end in `examples/XcodeApp`, whose `ReceiptController` is a real
`UIViewController` inside the SwiftUI app: an edit to a method the
controller calls during layout reached the screen in 498 ms, with the
process's session token unchanged. One save, Xcode 27.0 Beta 4, iPhone
17 Pro on iOS 27.0; the neighbouring saves in the same session measured
396--516 ms, so read it as the same order as section 18.1's numbers and
not as a benchmark.

### 13a.1 `viewDidLoad` is named, not fixed

`viewDidLoad` has already run for every controller that exists. The
patch replaces it correctly and nothing calls it again, which is the
outcome this tool treats as worse than a refusal --- so `watch` says so,
and
`PatchCoordinator.oneShotLifecycleTargets` is the list it says it for.
The reload still stands: the next controller of that type runs the new
body.

The list keys on the replacement target --- the name with its argument
labels --- and only for a member of some type, which is what keeps
`application(_:didFinishLaunchingWithOptions:)` in and two false
positives out. A *property* called `viewDidLoad` is re-read on every
access, so the note would have been the reverse of the truth; a
top-level function has no type for the advice to name. Both were
reachable and both are now tested.

What keeps the property out is the spelling --- every entry carries its
parentheses and a property's target is the bare name --- so that
invariant is pinned by a test of its own rather than left to be noticed.

The advice depends on the entry. A view controller or a scene can be
made again inside the live process, which holds the patch, so the next
one runs the new body. An application delegate cannot: there is one per
process, and a relaunched process starts from the built binary with
nothing loaded, so for those the honest advice is that seeing the change
takes a build. Saying "the next instance gets it" there would have been
advice that does not work.

A tier that discarded each loaded controller's view was built, measured,
and removed. Discarding the view does re-run `viewDidLoad`, and the
controller's own state survives; `uikit-view-did-load` still measures
that. What it does not do is put the rebuilt view back --- a
controller's view is held by whatever installed it --- so on the example
app it left a black window, the SwiftUI hosting controller's view having
been discarded with nothing to rebuild it. Recorded so it is not
re-attempted without solving the re-installation problem first.

### 13a.2 An `@objc` replacement is a category, not a record

The finding that made UIKit support work at all.

`@_dynamicReplacement` on an `@objc` member emits **no**
`__TEXT,__swift5_replace` section. It emits an Objective-C category,
which the Objective-C runtime installs over the class's own method at
image load:

``` text
__CATEGORY_INSTANCE_METHODS__TtC8XcodeApp17ReceiptController_$_Patch_001
```

FR-13's check counts what the image registered, and it counted only the
Swift section. So every UIKit lifecycle edit produced "the patch
registered 1 replacements; 2 were generated", ended the session, and
demanded a restart --- for a reload that had worked and was on screen.

The category carries **two** method entries for one replaced
declaration, the original selector and the replacement's own, sharing a
single `imp`. Counting entries said two replacements for one edited
declaration, which reads as "the image did more than was asked" and
left every such reload unverified.

Counting distinct implementations fixed that and broke something worse.
A declaration the patch merely *carries* also lands in that category
when the class is `@objcMembers`, and it is indistinguishable from a
replacement by that measure --- so allowing for it meant widening the
accepted total, and the width cancelled the check. Measured: an edit
that also extracted one helper produced a patch whose replacement was
missing entirely, whose carried helper made up the difference, and which
was reported as a **verified reload**. That is the single failure FR-13
exists to catch. It was also cumulative, since `SessionMemory` re-emits
carried declarations, so the slack grew with every save for the rest of
the session.

What separates them is in the image. A replacement is reachable from two
selectors; something that replaced nothing is reachable from one:

``` text
count 3
  name 0x8078  imp (0xbb8)   \_ the replaced @objc method
  name 0x8080  imp (0xbb8)   /
  name 0x7290  imp (0xc6c)   -- a carried helper, replacing nothing
```

So the runtime counts implementations reached by two or more selectors,
carried declarations are absent from both sides of the comparison, and
the check is an equality again. `fixtures/Cases/registered-replacements`
carries one of each and requires the answer to be 4; under the previous
rule it is 5.

Accessors are the same problem in the other direction. A computed
property is one declaration and one record *per accessor*, so a
`{ get set }` edit registered two where one was asked for. What FR-13
compares against is therefore a sum of
`PatchableDeclaration.replacementCount` rather than a count of
declarations.

This evidence is weaker than the Swift section's, and the code says so:
a category method whose selector the class already has replaces it, one
it does not have is added, and nothing readable from the image tells
them apart.

## 14. LLVM ORC/JITLink phase

### 14.1 Why it is deferred

Measured, in section 18.1: `ld` is 38% of a reload and is fixed
overhead rather than work that grows. Replacing it is the largest single
saving available, and JITLink is the only proposal here that would.

It is still deferred, because the target it would beat is already met
and because it is the only option here that adds an LLVM dependency.

The original reasoning, which the measurement confirms rather than
contradicts:

If MVP is:

``` text
.swift
 -> swift frontend
 -> .o
 -> system linker
 -> dylib
 -> load
```

profiling may show the linker/image pipeline is material.

Only then consider:

``` text
.swift
 -> swift frontend
 -> .o
 -> ORC ObjectLinkingLayer
 -> JITLink
 -> executor process
```

This avoids implementing Swift IR handling ourselves.

### 14.2 Prefer object-level JIT linking first

Prefer:

``` text
Swift -> object -> JITLink
```

over:

``` text
Swift -> LLVM IR -> ORC IRCompileLayer
```

because the Swift compiler remains responsible for complete code
generation.

### 14.3 Relevant ORC capabilities

ORCv2 supports:

-   runtime linking of relocatable Mach-O objects,
-   LLVM IR compilation,
-   in-process and cross-process executor models.

JITLink aims to support language-runtime registration and explicitly
calls out Swift/Objective-C requirements.

### 14.4 Research gate

Before adopting JITLink, prove that it correctly handles the
Swift-specific Mach-O sections and runtime registrations emitted by the
supported toolchain for dynamic replacement.

Required experiment:

1.  Compile the same replacement to `.o`.
2.  Link/load normally; verify replacement.
3.  Link the object using JITLink.
4.  Compare registered sections/symbol behavior.
5.  Verify replacement.
6.  Compare latency.

If step 5 fails, retain dylib loading.

## 15. Persistent compiler phase

Once linking is optimized, frontend startup may dominate.

Measured, in section 18.1: the frontend's own work is 21% of a reload
and process launches are another 28%, most of which a resident compiler
would also remove. That makes it comparable to JITLink in value and
cheaper in dependencies, which is the opposite of the ordering sections
14 and 15 assumed.

Potential architecture:

``` text
Source edits
    |
    v
Persistent Compiler Service
    |
    +-- cached modules
    +-- cached dependency graph
    +-- incremental parsing/type checking
    |
    v
Patch object
```

This is substantially more invasive than invoking the installed
compiler.

Do not begin this work without timing data.

Potential implementation routes:

-   long-lived compiler process using existing driver/frontend
    capabilities,
-   integration with Swift incremental compilation infrastructure,
-   compiler library embedding/fork as a later research project.

## 16. Patch generations

Each successful patch receives a monotonic generation:

``` text
g0 original
g1 patch
g2 patch
g3 patch
```

Runtime registry:

``` text
ReloadRegistry
└── module
    └── declaration
        ├── latestGeneration
        └── diagnostic metadata
```

Do not assume old code can be unloaded.

Measured (Appendix A): loading generation `g2` over `g1` works with no
additional flag; the most recently loaded replacement wins. The hidden
options

``` text
-enable-dynamic-replacement-chaining
-disable-previous-implementation-calls-in-dynamic-replacements
```

exist and affect chaining semantics, but the MVP does not need them.
Evaluate them only if a patch must call the previous implementation.

Provide a configurable warning after many generations if process memory
grows materially.

## 17. Failure handling

Pipeline stages:

``` text
WATCH
CLASSIFY
GENERATE
COMPILE
LINK
TRANSFER
LOAD
REGISTER
VERIFY
```

Every error contains a stage.

Example:

``` text
[COMPILE] CheckoutViewModel.swift
Replacement failed because `CheckoutService.internalState`
is not accessible from the generated patch context.

Action: full rebuild required.
```

The runtime should remain usable after compile/link failures.

A load/registration failure may put the process into an uncertain state;
mark the session "restart recommended" unless proven recoverable.

Implemented. After such a failure the daemon stops patching that process
and says so on every subsequent save, until the app reconnects --- a new
process being the only state it can vouch for without having watched it
become that way. Repeated rather than said once, because the developer
is editing, watching nothing happen, and the reason scrolled away.

The question is only ever "could this patch have taken effect", and
there are exactly two ways for the answer to be unknown:

-   the request was sent and no answer came back, whether it timed out
    or the socket went away. Silence is not the same as nothing having
    loaded;
-   the runtime answered at a stage where it cannot vouch for what
    happened, which is REGISTER or VERIFY.

Everything else is known. A request that never left the daemon --- the
ordinary case of saving before launching the app --- leaves the process
exactly as built. A classifier refusal never reached it. A failure to
find the app container never reached it. And every failure the runtime
answers today means nothing took effect: a missing image was never
opened, and `dlopen` unmaps an image it could not finish binding. The
runtime documents that promise next to the two stages it uses, so a
future failure mode that cannot make it has to say so with a different
stage rather than inherit the benefit of the doubt.

An earlier version of this poisoned on any failure that recommended a
restart, which made saving a file with no app running mark the session
undescribable and then hide every later error behind that message.

Clearing needs evidence of a new process, not of a new socket. The
runtime re-dials whenever its connection drops --- a suspend and resume in
the simulator is enough --- so `hello` carries the pid and only a
different one clears the flag.

### 17.1 REGISTER

The stage that turns "the image loaded" into "the image replaced something".

`dlopen` returning a handle says the image mapped. It says nothing about the
Swift runtime having bound anything in it, and this project's default refusal
of an unsafe SwiftUI `body` follows the same rule: a reload which lies is worse
than a refusal. Reporting a reload on the strength of `dlopen` alone was that
fault in a smaller font.

After loading, the runtime reads the image's `__TEXT,__swift5_replace` section,
which is the one the Swift runtime itself reads, and counts the replacements it
declares. The layout is measured rather than documented:

``` text
section   uint32 flags
          uint32 numScopes
          per scope: int32 relative pointer, uint32 flags
scope     uint32 flags
          uint32 numReplacements
          descriptors...
```

`Tests/SpliceEndToEndTests/ReplacementSectionTests.swift` pins that a patch
emitting one replacement declares one and a patch emitting three declares
three, so a toolchain that moves this fails there rather than in a session.

Three outcomes, and the difference between them matters:

-   the count matches: an ordinary reload,
-   the count is *lower*, zero included: a REGISTER failure. The patch did
    less than it said, the process may have had some of it applied, and no
    more can be said about it --- so the session ends rather than the save.
    REGISTER is one of the two stages section 17 reserves for exactly that,
-   the count is *higher*, or could not be read: the reload stands and
    `watch` says it was not verified. A patch cannot register a replacement
    it does not contain, so a count above the expected one says this reader
    misread the image rather than that the process is wrong; ending a session
    every time a toolchain moved a field is not a trade worth making, and
    neither is refusing because a check could not run.

The reader validates every address it derives against the image's own mapped
segments before following it, because the layout it walks is measured rather
than documented. How much that is worth was itself measured: five corrupted
sections were built and loaded, and four killed the process inside `dlopen` ---
the Swift runtime reads this same section to bind replacements and gets there
first, so the wild-pointer case is mostly not ours to catch. The fifth, a
pointer landing just outside the image, survived that far and the bounds check
is what stopped it. What the checks cannot catch is a layout that is different
but *valid*, where the Swift runtime is content and these offsets read the
wrong field --- which is why the count is treated as evidence, the "higher than
expected" case is not fatal, and
`Tests/SpliceEndToEndTests/ReplacementSectionTests.swift` pins the layout so a
change fails there first.

## 18. Observability

Emit one structured event per stage:

``` json
{
  "generation": 42,
  "stage": "compile",
  "durationMs": 183.4,
  "success": true
}
```

CLI summary:

``` text
change detection       21 ms
classification         14 ms
generation              8 ms
swift frontend         231 ms
link                   318 ms
load                    17 ms
--------------------------------
total                  609 ms
```

This data determines whether ORC or persistent compiler work is
justified. It has now been collected; section 18.1 has it.

### 18.1 Measured

`Sources/SpliceBench` generates a synthetic application of a given size,
builds it, and drives the real classifier, generator, and compiler
through an edit. Median of five patches after a discarded warmup,
milliseconds, from an optimised build of the daemon:

``` text
module size    full build    classify  generate  compile  link   total
4 decls               439           0         0      176    175    349
200 decls           1,161           0         0      174    174    347
1,000 decls         4,502           0         0      175    174    349
4,000 decls        18,463           0         0      175    174    349
10,000 decls       50,416           0         0      175    181    356
```

**Patch latency does not grow with the module around the edit.** A full
build goes from 0.4 s to 50 s across that range, 115 times slower, while
the patch pipeline moves from 349 ms to 356 ms. At the top of the range
a reload is 142 times faster than a build, and costs the same as it did
at the bottom.

Two qualifications, both found by reviewing the first version of this
section, which measured only one axis and drew a broader conclusion than
it had earned.

The first is that the patch here names one small type. `@testable
import` deserialises lazily, so a patch that reaches into many of the
module's types pays more: a 510-line patch naming 500 types costs about
40 ms more than one naming a single type. The statement that survives is
"latency does not grow with module size for an edit of fixed reach",
which is still the useful one --- an edit reaches what it reaches
regardless of how large the project around it is.

The second is that one stage does scale, with the file being edited
rather than the module:

``` text
edited file    classify  compile  link   total
13 lines              0      175    174    349
213 lines             1      173    175    349
813 lines             4      172    174    349
2,013 lines           9      173    175    358
```

That is under 3% of the loop at two thousand lines, which is tolerable. It is
only tolerable optimised. Classification is SwiftSyntax parsing, and at
`-Onone` it costs roughly fourteen times as much. A daemon built for
debug is not a daemon worth measuring, and `examples/CounterApp/demo.sh`
builds it with `-c release` for that reason.

Halving that column took caching the baseline's parsed form between
saves; it changes only when a patch lands, and re-parsing it every time
doubled the one stage that grows.

That column ended up *faster* than before the classifier grew a reference
analysis, which it had no right to be, and the route there is worth
recording because every step was found by re-measuring rather than by
reading.

The analysis added an identifier walk per declaration --- 2 ms on a
2,000-line file, never the problem --- and a way to ignore comments. The
first attempt at ignoring them rewrote the tree with comment trivia
removed, per declaration, and indexing that file went to 4,760 ms.
Mutating a SwiftSyntax node that has a parent rebuilds the whole tree it
belongs to, so N declarations meant N rebuilds of the file. Doing it once
at the root brought it to 2,930 ms, which was still absurd: the rewriter
returned a *new* token even where it had changed nothing, and rebuilding
every token rebuilds every ancestor with it. Returning the original token
when there is no comment: 32 ms.

Then a review found that the comparison key --- built by collapsing
whitespace in the printed source --- collapsed it inside string literals
too, so `"Total:  9"` and `"Total: 9"` compared equal and the save was
reported as no change at all. The fix removed the rewrite entirely: the
key is now built from the tokens and the statement boundaries, and
nothing touches trivia, so comments are ignored without being removed.
That also fixed a second defect the same review found, where a comment
had been the only thing separating two tokens and removing it emitted
`1 ++2`.

Building the key over *every* node kind cost 55 ms, because naming a
`SyntaxKind` allocates. Marking only statement boundaries --- the one
structure whitespace can change --- costs 9 ms, and `.detached` on the
signature path is worth another 65 ms on a file that size. Hence a
column that reads 0, 1, 4, 9 where it used to read 0, 2, 6, 18.

None of this undercuts the conclusion, but it does narrow it. Neither
section 14 nor section 15 was proposed because 350 ms is too slow; both
were proposed in case the pipeline scaled badly with the project. It
does not.

Where the 385 ms of a real reload actually goes, decomposed by running
each layer directly:

``` text
ld                                   145 ms   38%
process and driver overhead          109 ms   28%
Swift frontend, real work             81 ms   21%
dlopen and registration               27 ms    7%
classification                        15 ms    4%
```

The overhead line is three drivers and two process launches: `swiftc`
costs about 60 ms before it does anything, and the link invocation pays
another 34 ms of `swiftc` driver plus 15 ms of `clang` driver before
reaching `ld`.

`ld` is the single largest item and it is fixed cost, not work: it does
not grow with the module it links against, so it is the SDK's tbds and
the linker's own startup rather than anything about the patch.

### 18.2 What this says about sections 14 and 15

Defer both.

The long-term target in PRD.md section 10 is under 500 ms for a simple
patch compile and load. That is met, at 356 ms, on a module of ten
thousand declarations.

If either is picked up later, the numbers point at them roughly equally
and for different reasons. JITLink (section 14) addresses the 38% in
`ld` and nothing else. A persistent compiler (section 15) addresses the
21% of frontend work plus most of the 28% of process overhead, so about
37%, and needs no new dependency on LLVM.

The cheapest available win needs neither: merging the compile and link
invocations back into one saves about 60 ms. It is deliberately not
taken --- two invocations are what make section 9.2's separate timing
possible, and stage attribution currently costs 16% of the loop. That is
a trade worth revisiting only when something else has made 60 ms matter.

## 19. Testing strategy

### 19.1 Unit tests

-   change classifier,
-   build-context normalization,
-   replacement source generation,
-   protocol serialization,
-   toolchain feature probing.

The daemon needs its own, and for a specific reason: its two worst
failures so far were both invisible from the outside. `IPCServer.request` could not
time out, and because `watch` awaits each save in turn, one unanswered
request stopped the daemon from ever processing another --- with no
error and no log. The second was a teardown race: `NWConnection.cancel()` is graceful, so
an app that crashed mid-patch could have its old socket finish tearing
down after the relaunched one had already connected, and the stale
teardown wiped the fresh session. Every later save then reported "no app
is connected", permanently, because the runtime only says hello once.
Connections are tagged with a generation now, and a teardown that is not
the current one does nothing.

`SpliceDaemonTests` drives the server against a fake runtime that speaks
the wire format directly, which also makes it a second reader of the
protocol, so a drift between the two sides shows up there.

### 19.2 Compiler fixtures

Implemented in `fixtures/`. `fixtures/run.sh` builds each case, loads its
patch into the running process, compares observable output across
generations, and regenerates `fixtures/results.yaml` for section 20. It
takes `--platform simulator` for the Simulator matrix.

Covered:

-   top-level function,
-   class instance method,
-   final class,
-   struct method,
-   mutating struct method,
-   enum method,
-   computed property,
-   closure capture,
-   generic method,
-   protocol witness,
-   async,
-   throws,
-   actor,
-   `@MainActor`.

Each fixture records:

-   supported?,
-   expected output before patch,
-   expected output after patch,
-   expected state preservation.

One case, the opaque result type change, records what it observed rather
than asserting an expectation, because its behavior is undefined
(section 12.7).

### 19.3 Negative fixtures

These exercise the change classifier, which does not exist yet, so they
are not in `fixtures/` --- that suite covers only what the runtime does
once a patch has been built. The four build-time rejections that are
covered today are listed in `fixtures/README.md`.

-   stored property added,
-   stored property removed,
-   property type changed,
-   enum case added,
-   function signature changed,
-   generic constraints changed,
-   inheritance changed.

All must fail closed. Implemented as
`Tests/SpliceGenTests/RebuildRequiredTests.swift`, one test per entry
above so the list cannot quietly narrow.

Two of these are order-sensitive rather than text-sensitive, and both
were initially missed. Enum cases and stored properties both determine
layout by declaration order, so a reordering is a real change; the
residue fingerprint therefore preserves document order, and the order in
which declarations are rejected is part of it. Reordering a method is
not a change by the same reasoning, and is deliberately still accepted
as no change.

### 19.4 End-to-end generation

The gap between "the classifier said yes" and "the patch works" needs
its own suite, because a verdict nobody executes is a guess. For each
declaration kind the classifier accepts, `SpliceEndToEndTests` takes a
real edit through the real classifier and generator, compiles the
result, loads it into a live process, and checks the output.

This is what the toolchain fixtures cannot do: they use hand-written
patches, so they say nothing about the generator. Two generator bugs ---
constrained extensions losing their `where` clause, and overloads
sharing an identity --- were invisible to every other suite.

Host-only, because the toolchain behaviour underneath is already pinned
on the Simulator by `fixtures/run.sh --platform simulator`, and building
for the host keeps a full pass in seconds.

### 19.5 Integration test

Automate:

1.  Build sample app.
2.  Launch Simulator.
3.  Put app in known state.
4.  Modify fixture source.
5.  Wait for reload.
6.  Invoke behavior.
7.  Assert new behavior.
8.  Assert state token is unchanged.

## 20. Compatibility matrix

Maintain in-repo machine-readable data eventually:

``` yaml
toolchains:
  - xcode: "<version>"
    swift: "<version>"
    simulator:
      arm64: true
    features:
      implicit_dynamic: true
      dynamic_replacement: true
      struct_method: tested
      async_method: experimental
      swiftui: experimental
```

Four toolchains measured, three of them shipping releases. Every entry
below is `fixtures/run.sh` and `swift test` actually run, not inferred:

``` text
                     swift   host target   host   simulator          tests
local, Xcode 26.2    6.2.3   macosx26.0    26/26  26/26 (iOS 26.2)   109/109
local, Xcode 26.3    6.2.4   macosx26.0    26/26  not run            109/109
local, Xcode 26.5    6.3.2   macosx26.0    26/26  26/26 (iOS 26.5)   109/109
local, Xcode 27.0b4  6.4     macosx26.0    40/43  43/43 (iOS 27.0)   203/203
CI, macos-15         6.2.4   macosx15.0    26/26  26/26 (iOS 26.2)   109/109
CI, macos-26         6.3.3   macosx26.0    26/26  26/26 (iOS 26.5)   109/109
```

The counts differ by row because the matrix grew, from 26 cases to 43, and
the test suite with it. The host column reads 40 of 43 rather than a
failure: the three UIKit cases are Simulator-only and are skipped by
name, which `fixtures/run.sh` counts separately. Only the Xcode 27.0b4 row has been re-run against the
current matrix; the others report what they were actually measured against.
Of the seventeen cases added since those rows, thirteen were run separately
on the host under Xcode 26.2, 26.3 and 26.5 and pass on all three ---
including the seven that depend on `-enable-private-imports`, which
matters most, since that is a second undocumented frontend option. The
other four --- the three UIKit cases and `registered-replacements` --- have
been run only on Xcode 27.0b4. Nothing suggests the older rows would differ,
but a row is not re-measured until it is re-run.

The last two rows come from `.ci-results/*.yaml` uploaded by the run,
not from anything committed here, and they cover two things no machine
here can: Swift 6.3.3, which is not installed locally, and a macOS 15
deployment target, which is where `some View` erases to `AnyView`
instead of `DebugReplaceableView`. That difference is what the first CI
run caught.

Nothing measured differs between them. The SwiftUI erasure to
`DebugReplaceableView` is present on all four, and a full reload of the
sample app works on Xcode 26.5 at 434 ms.

The unsafe cases are the exception, and they differ by *target* rather
than by toolchain: `opaque-inside-a-type` produces SIGSEGV everywhere,
while `opaque-result-type-changed` produces SIGSEGV on the Simulator and
`exit 0; g0: old g1: 42` on the host. Both files record what they
observed; an earlier sentence here claimed SIGSEGV for all of them,
which the results files have never agreed with. Undefined is undefined,
which is the conclusion those cases exist to support.

Reproduce a row with:

``` text
DEVELOPER_DIR=/Applications/Xcode-26.5.0.app/Contents/Developer \
  ./fixtures/run.sh --platform simulator
```

One toolchain-specific workaround exists, in
`runtime/Sources/SpliceClient.swift`. Written with an implicit `self`,

``` swift
lock.withLock { connection }?.cancel()
```

crashes the type checker with signal 5 on Swift 6.3.2 and earlier, which
is every shipping toolchain at the time of writing. Spelling `self.`
explicitly compiles everywhere. It was found by building the package
under each toolchain rather than by reading anything.

The earlier data point, on the macOS host and an arm64 iOS Simulator
(see Appendix A):

``` yaml
toolchains:
  - xcode: "26.2 / 26.3 / 26.5 / 27.0 Beta 4"
    swift: "6.2.3 / 6.2.4 / 6.3.2 / 6.4"
    host: arm64-apple-macosx26.0
    simulator:
      arm64: tested
    features:
      implicit_dynamic: true
      dynamic_replacement: true
      requires_enable_testing: true
      top_level_function: tested
      class_method: tested
      struct_method: tested
      enum_method: tested
      mutating_struct_method: tested
      computed_property: tested
      final_method: tested
      generic_function: tested
      protocol_witness: tested
      protocol_extension_default: tested
      async_method: tested
      throws_method: tested
      async_throws_method: tested
      actor_method: tested
      main_actor_method: tested
      static_method: tested
      objc_method: tested
      override_method: tested
      override_via_objc_dispatch: tested
      super_call_in_replacement: tested
      patch_local_declaration: tested
      carried_declaration_across_generations: tested
      private_function_with_private_imports: tested
      private_type_member: tested
      private_stored_property_read: tested
      private_default_argument: tested
      private_witness: tested
      private_override: tested
      private_imports_absent: rejected_at_compile
      inlinable: unsupported
      transparent: unsupported
      private: unsupported
      opaque_result_type_change: undefined
      swiftui: untested
      debug_replaceable_view_min_os: "iOS 26.0"
```

Do not claim a version is supported until CI/manual fixtures pass.

## 21. Proposed CLI

Initial commands:

``` text
swift-hot-reload doctor
swift-hot-reload attach
swift-hot-reload watch
swift-hot-reload status
```

`doctor` verifies:

-   selected Xcode,
-   compiler identity,
-   project instrumentation,
-   testability (`SWIFT_ENABLE_TESTABILITY`),
-   exported dynamic replacement keys in the running image,
-   running Simulator target,
-   runtime connection,
-   feature probes.

Example:

``` text
$ swift-hot-reload doctor

Xcode                 OK
Swift toolchain       OK
Simulator             OK
Implicit dynamic      OK
Testability           OK   SWIFT_ENABLE_TESTABILITY = YES
Replacement keys      OK   142 exported
Runtime               OK
Dynamic replacement   OK

Ready.
```

## 22. Implementation sequence

### Step 1: Compiler/runtime proof

No daemon.

-   Build a macOS or Simulator-compatible fixture.
-   Mark original declaration dynamic.
-   Build replacement dylib.
-   Load it.
-   Verify new implementation.

### Step 2: Struct/class matrix

Prove:

-   class method,
-   struct method,
-   mutating struct method.

### Step 3: Real iOS Simulator app

Add runtime library and load a patch while the process remains alive.

Done, in `examples/CounterApp`. Two hand-authored patches replace two
methods on a live `ObservableObject` while its instance, its items, and
the launch-time session token survive unchanged.

### Step 4: Build context capture

Recompile patch against a real application module.

Done, from the weaker end: the application's build emits the manifest
rather than the daemon recovering it from Xcode. That is enough to prove
the rest of the pipeline and cannot drift from the binary it describes,
but it does not yet satisfy section 6.2.

### Step 5: Automation

Watcher + generator + compiler + IPC.

Done. `swift-splice watch` runs the loop against
`examples/CounterApp`. Two decisions from the build-out are worth
recording:

-   The runtime dials the daemon rather than listening, which makes
    reconnection after an app relaunch fall out for free. The first
    version leaned on `NWConnection` recovering from `.waiting` by
    itself and an app whose daemon had stopped never reconnected; the
    retry is now explicit.
-   Control travels over the socket and the image travels through the
    file system. The daemon can already write into the application's
    container, and a path keeps the artifact inspectable after the
    fact, which is what section 10.1's `LoadPatchRequest` assumed.

### Step 6: Classifier

Reject unsafe changes.

Done. The refusal list in section 19.3 is now one test each, and the
suites are split by what they can be held to: the toolchain fixtures
cover what Swift does, the unit tests cover what the classifier decides,
and an end-to-end suite covers what the generated patch actually does in
a process.

### Step 7: SwiftUI research

Done. The unannotated failure and explicit opt-in are both pinned by rendering
fixtures; section 13 records the route and the two earlier wrong answers.

### Step 8: Profile

Measure end-to-end.

### Step 9: JITLink experiment

Only if link/load is worth optimizing.

### Step 10: Persistent compiler experiment

Only if frontend startup/repeated semantic work dominates.

## 23. Key technical risks

### R1: Private Swift interfaces

`@_dynamicReplacement` and `-enable-implicit-dynamic` are not stable
public interfaces.

Mitigation:

-   adapter boundary,
-   feature probes,
-   compatibility matrix,
-   narrow supported toolchains,
-   fixtures.

### R2: Patch compilation access and symbol visibility

Largely resolved, and downgraded in severity. The real obstacle turned
out to be link-time visibility of dynamic replacement key symbols rather
than source-level access control; `-enable-testing` plus
`@testable import` fixes both (sections 5.4, 8.1).

Residual risk:

-   `private` / `fileprivate` declarations remain unreachable,
-   binary-only dependency modules remain unreachable,
-   a project that cannot enable testability in Debug cannot be
    supported.

Mitigation:

-   require and verify testability in `doctor`,
-   reject unsupported declarations.

### R3: Runtime metadata registration

A replacement image may depend on Swift metadata sections beyond
ordinary symbols.

Mitigation:

-   use normal dylib/dyld first,
-   inspect artifacts,
-   defer JITLink until equivalent registration is proven.

### R4: Opaque result types (memory safety, not only SwiftUI)

Upgraded in severity. Changing the underlying type of an opaque result
type compiles cleanly and then crashes the process with `SIGSEGV` and no
diagnostic (section 12.7). This is a memory-safety failure rather than a
degraded-behavior failure. The ordinary unannotated `var body: some View` case
fails through `DebugReplaceableView`'s generic storage instead.

Mitigation:

-   classify opaque-result-type declarations as rebuild-required by default;
-   allow only the measured SwiftUI opt-in whose initial and patched outer
    value is `AnyView`;
-   keep the SwiftUI adapter separate from the core runtime;
-   retain the iOS 26 `DebugReplaceableView` crash as a compatibility fixture.

### R5: Existing stack frames

Reload cannot safely rewrite code already executing.

Mitigation:

-   define semantics as "future calls use new generation";
-   do not attempt stack migration.

### R6: ABI/layout drift

Unsafe replacement can corrupt memory.

Mitigation:

-   conservative classifier,
-   fail closed,
-   no layout migration in v0.x.

### R7: Undocumented coverage of implicit dynamic

`-enable-implicit-dynamic` skips `@inlinable`, `@_transparent`, and
`private`/`fileprivate` declarations (section 12.8). Today each of those
fails closed at the COMPILE stage, so the immediate safety risk is low.
The risk is that the covered set is undocumented, so it can change
between toolchains without notice, and the tool's idea of what is
patchable would silently drift from the compiler's.

Mitigation:

-   treat coverage as a per-toolchain measurement, not a language rule,
-   re-run the fixture matrix on every supported toolchain,
-   record the result in the compatibility matrix,
-   prefer the compiler's own diagnostic over a hand-maintained source
    rule when the two disagree.

## 24. Decisions

### D-001: No custom Swift VM

Accepted.

Reason: the installed Swift compiler already implements language
semantics; reimplementation would dramatically expand scope.

### D-002: Simulator-only MVP

Accepted.

Reason: development value is high and code-signing/JIT restrictions on
physical devices would distract from proving the core model.

### D-003: Dynamic replacement before machine-code interposition

Accepted.

Reason: it is Swift-aware and minimizes ABI-level patching.

### D-004: Dylib before ORC/JITLink

Accepted.

Reason: normal loading is the simplest correctness baseline.

### D-005: Object-level JITLink before LLVM-IR JIT

Provisional.

Reason: keeps Swift code generation inside the Swift compiler and
narrows custom responsibilities to runtime linking.

### D-006: Unknown changes require rebuild

Accepted.

Reason: state preservation is valuable only if it is trustworthy.

## 25. Research commands / notes for coding agents

When exploring a toolchain, record exact outputs and do not generalize
across Xcode versions.

Useful categories of investigation:

``` bash
xcrun --find swift
xcrun --find swiftc
xcrun swiftc --version
xcode-select -p
```

Inspect hidden frontend support using the selected toolchain rather than
assuming flags exist.

For generated artifacts, useful inspection tools may include:

``` text
nm
otool
dwarfdump
swift-demangle
```

When modifying compiler flags, isolate changes to a disposable fixture
project first.

Do not make unsupported claims about ABI behavior based solely on symbol
names.

## 26. Definition of done for v0.1

A release candidate is ready when all are true:

-   [ ] CLI can validate the supported environment.
-   [ ] Example iOS Simulator app integrates runtime.
-   [ ] File save triggers patch workflow.
-   [ ] Class method body reload passes.
-   [ ] Struct method body reload passes.
-   [ ] Mutating struct method body reload passes.
-   [ ] Existing runtime state is preserved.
-   [ ] At least one unsupported layout edit is correctly rejected.
-   [ ] Failures have stage-specific diagnostics.
-   [ ] Release configuration does not activate hot reload, including
    testability and implicit dynamic.
-   [ ] `doctor` verifies the testability/symbol-visibility
    precondition.
-   [ ] A declaration with no exported replacement key is rejected
    rather than reported as reloaded.
-   [ ] An opaque-result-type change is rejected rather than loaded.
-   [ ] Supported Xcode/Swift versions are explicitly documented.
-   [ ] End-to-end timing is reported.
-   [x] CI/unit/fixture tests are documented and runnable.
    `scripts/ci.sh` is what CI runs and what a contributor runs; the
    workflow contains no steps of its own, including the choice of
    toolchain.

    Three properties are worth stating because the first version of it
    had none of them. An unknown stage name is an error rather than a
    silent skip of everything. A fixture run that matches no cases fails
    rather than reporting a clean pass. And the artifact CI publishes is
    what that run measured, not the results file checked into git.

## Appendix A: measured toolchain behavior

Recorded so that later toolchains can be compared against a concrete
baseline. Do not generalize these results across Xcode versions.

### A.1 Environment

``` text
Xcode       27.0 Beta 4
swiftc      Apple Swift version 6.4 (swiftlang-6.4.0.27.1 clang-2100.3.27.1)
host        arm64-apple-macosx26.0
simulator   arm64-apple-ios27.0-simulator (iPhone 17 Pro, iOS 27.0)
```

The matrix was run on both targets. All 43 cases pass on the Simulator;
40 pass on the host, the other three being UIKit cases that are skipped
there by name. Every result below holds for both except where noted.

Reproduce with `fixtures/run.sh` and `fixtures/run.sh --platform
simulator`, which regenerate `fixtures/results-macos.yaml` and
`fixtures/results-simulator.yaml`.

### A.2 Method

Application fixture:

``` text
swiftc -parse-as-library -Onone
       -enable-testing
       -Xfrontend -enable-implicit-dynamic
       -module-name DemoApp
       -emit-module -emit-module-path DemoApp.swiftmodule
       -emit-executable -o app Fixture.swift
```

Patch:

``` text
swiftc -Onone -emit-library -o patch1.dylib
       -module-name Patch1 -I . Patch1.swift
       -Xlinker -undefined -Xlinker dynamic_lookup
```

The fixture prints observable state, `dlopen`s each patch named on the
command line, then prints again.

### A.3 Results

``` text
top-level function                            replaced
class instance method                         replaced, state preserved
struct method                                 replaced
enum method                                   replaced
mutating struct method                        replaced, value mutated
computed property                             replaced
final class method                            replaced
generic function                              replaced
protocol witness, direct call                 replaced
protocol witness, existential call            replaced
protocol extension default                    replaced
async function                                replaced
throws function                               replaced
async throws function                         replaced
actor instance method                         replaced, state preserved
@MainActor method                             replaced, state preserved
static method                                 replaced
@objc method on an NSObject subclass          replaced
override, called through the base class       replaced, state preserved
override, called through objc_msgSend         replaced
override whose replacement calls super        replaced, state preserved
declaration carried only in the patch         callable from a replaced body
two patches carrying the same private name    no collision; newest wins

with -enable-private-imports:
private function, by its own key              replaced; unpatched caller sees it
member of a private type                      replaced
private stored property, read from a patch    readable
private helper behind a default argument      replaced; the generator sees it
private witness, existential call             replaced
overridden fileprivate member                 replaced; dispatch unchanged
without the flag                              rejected at COMPILE
opaque result type, same underlying type      replaced
two generations loaded in sequence            newest wins

@inlinable function                           rejected at COMPILE
@_transparent function                        rejected at COMPILE
private function                              rejected at COMPILE
patch against a non-testable module           rejected at COMPILE
opaque result type, changed underlying type   undefined behavior
```

Diagnostics for the rejected cases:

``` text
@inlinable / @_transparent
  error: replaced function 'f()' is not marked dynamic
private
  error: replaced function 'f()' could not be found
non-testable module
  error: module 'Fixture' was not compiled for testing
```

The opaque result type case is the only one that reaches a running
process, and its outcome varies:

``` text
read only after the patch loads     new value returned
read before and after               garbage characters, or SIGSEGV

macOS host, fixture case            exit 0, returned the new value
iOS Simulator, same fixture case    SIGSEGV
```

The last two lines are the same source compiled by the same toolchain,
differing only in target. A developer who tries this edit on one
platform learns nothing about the other.

### A.4 Coverage of implicit dynamic

Declarations of each kind were compiled with implicit dynamic and the
emitted replacement keys compared against the source:

``` text
key emitted      internal, public, @usableFromInline
                 static and class methods
                 overrides of class methods
                 init, subscript, operator functions
                 computed properties, lazy properties
                 nested type methods, extensions on imported types
                 generic functions

no key emitted   @inlinable, @_transparent
                 private, fileprivate
                 deinit
                 @objc members of NSObject subclasses
```

The last line is the trap: `@objc` members get no native key because
they dispatch through the Objective-C runtime, but they are replaceable
anyway. Key presence is evidence, not proof.

### A.5 Symbol visibility

Exported dynamic replacement keys in the host executable, out of 14
emitted:

``` text
-enable-testing               14
-Xlinker -export_dynamic       0
neither                        0
```

With zero exported keys, loading fails as:

``` text
dlopen FAILED: symbol not found in flat namespace
'_$s7DemoApp14internalHelperSSyFTx'
```

The patch image carries the expected `__TEXT,__swift5_replace` section.

### A.6 Flag verification

``` text
$ swiftc -enable-implicit-dynamic ...
error: unknown argument: '-enable-implicit-dynamic'
```

Frontend definition:

``` text
def enable_implicit_dynamic : Flag<["-"], "enable-implicit-dynamic">,
  Flags<[FrontendOption, NoInteractiveOption, HelpHidden]>,
  HelpText<"Add 'dynamic' to all declarations">;
```

Xcode build setting mapping, from `Swift.xcspec`:

``` text
SWIFT_ENABLE_TESTABILITY = YES  ->  -enable-testing
```

### A.7 DebugReplaceableView

From
`iPhoneSimulator27.0.sdk/.../SwiftUICore.swiftmodule/arm64-apple-ios-simulator.swiftinterface`:

``` swift
@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
nonisolated public struct DebugReplaceableView: View, ~Sendable {
    public init<V>(erasing view: V) where V: View
    // ...
}
```

It is not declared in the SwiftUI module itself.

## 27. References

-   Swift underscored attributes:
    https://github.com/swiftlang/swift/blob/main/docs/ReferenceGuides/UnderscoredAttributes.md
-   Swift frontend options:
    https://github.com/swiftlang/swift/blob/main/include/swift/Option/FrontendOptions.td
-   SIL function attributes:
    https://github.com/swiftlang/swift/blob/main/docs/SIL/FunctionAttributes.md
-   LLVM ORCv2: https://llvm.org/docs/ORCv2.html
-   LLVM JITLink: https://llvm.org/docs/JITLink.html
-   `DebugReplaceableView` (declared in SwiftUICore, re-exported by
    SwiftUI; iOS 26.0+):
    https://developer.apple.com/documentation/swiftui/debugreplaceableview
