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

### 6.5 What else has to reach the patch

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
-   language mode.

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
-   body of an `@inlinable`, `@_transparent`, `private`, or
    `fileprivate` declaration changed --- implicit dynamic does not
    cover these, so the patch cannot be built; see section 12.8.

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

Every uncovered case fails at the COMPILE stage with an actionable
diagnostic, so the fail-closed principle in section 2.4 holds:

``` text
@inlinable / @_transparent
  error: replaced function 'f()' is not marked dynamic

private / fileprivate
  error: replaced function 'f()' could not be found
```

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

It still must not be allowed, for a different reason.

In a rendering application the patch loads, reports success, and changes
nothing on screen. Both halves were observed in one render pass:
`Banner.body` was replaced twice and the banner never changed, while
`Cart.subtotalLabel()` was replaced in the same session and its row
updated immediately. So the view did re-render and still produced the
old tree. SwiftUI does not reach a body through the replaceable getter;
it goes through the `_makeView` machinery generated at compile time,
which holds the original.

That makes SwiftUI `body` a silent no-op, which is the outcome this tool
treats as worse than a refusal --- the developer edits, the CLI says
"hot reloaded", and the screen disagrees. The classifier refuses it, with
its own wording rather than the undefined-behaviour one, because telling
someone their `some View` edit is memory-unsafe would be false.

`SPLICE_EXPERIMENTAL_SWIFTUI=1` lifts the refusal so the spike can
continue. `watch` prints exactly what it will and will not do when the
variable is set. It is not a feature.

What would have to be found next: how Xcode Previews reaches a body,
given that `DebugReplaceableView` exists for that purpose and is public
but undocumented. `_makeView` and the attribute graph are where the
original implementation is captured, so an invalidation trigger alone is
not enough --- the graph re-ran and still called the old code.

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

Any SwiftUI support built on it therefore carries a hard
deployment-target floor that core function replacement does not.
Record this in the compatibility matrix (section 20).

`SWIFT_ENABLE_OPAQUE_TYPE_ERASURE` maps to
`-enable-experimental-feature OpaqueTypeErasure` and defaults to NO, but
erasure of `some View` was observed with the flag on, off, and absent, so
on this toolchain the setting is not what turns it on.

The project should investigate the current Xcode/SwiftUI preview
pipeline rather than assume ordinary method replacement is sufficient.

Proposed layering:

``` text
CoreReplacementEngine
        |
        +-- Plain Swift
        |
        +-- UIKit adapter
        |
        +-- SwiftUI adapter
              |
              +-- opaque result handling
              +-- invalidation trigger
              +-- state preservation experiments
```

Do not couple core runtime correctness to undocumented SwiftUI
internals.

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

Which failures count is decided at the three sites that know, not
derived from the stage or from `recovery`. A load that was answered
`failed`, and a request that was never answered at all, both leave a
process that cannot be described --- silence is not the same as "nothing
loaded". A runtime that answers `rejected` loaded nothing and says so, a
classifier refusal never reached the process, and "could not find the
app container" also recommends a restart while leaving the app
untouched. None of those poison the session, and demanding a relaunch
for an ordinary rejected edit would train people to ignore the message.

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
4 decls               439           0         0      174    175    349
200 decls           1,112           0         0      175    175    350
1,000 decls         4,529           0         0      174    175    349
4,000 decls        18,225           0         0      174    175    349
10,000 decls       49,797           0         0      174    178    352
```

**Patch latency does not grow with the module around the edit.** A full
build goes from 0.4 s to 50 s across that range, 113 times slower, while
the patch pipeline moves from 349 ms to 352 ms. At the top of the range
a reload is 141 times faster than a build, and costs the same as it did
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
13 lines              0      175    175    349
213 lines             2      173    175    349
813 lines             6      176    175    357
2,013 lines          18      173    175    366
```

That is 5% of the loop at two thousand lines, which is tolerable. It is
only tolerable optimised. Classification is SwiftSyntax parsing, and at
`-Onone` the same column reads 1, 21, 83, and 244 ms --- fourteen times
the cost, turning a 366 ms reload into 591 ms. A daemon built for debug
is not a daemon worth measuring, and `examples/CounterApp/demo.sh`
builds it with `-c release` for that reason.

Halving that column took caching the baseline's parsed form between
saves; it changes only when a patch lands, and re-parsing it every time
doubled the one stage that grows.

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
patch compile and load. That is met, at 385 ms, on a module of ten
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
local, Xcode 27.0b4  6.4     macosx26.0    26/26  26/26 (iOS 27.0)   109/109
CI, macos-15         6.2.4   macosx15.0    26/26  26/26 (iOS 26.2)   109/109
CI, macos-26         6.3.3   macosx26.0    26/26  26/26 (iOS 26.5)   109/109
```

The last two rows come from `.ci-results/*.yaml` uploaded by the run,
not from anything committed here, and they cover two things no machine
here can: Swift 6.3.3, which is not installed locally, and a macOS 15
deployment target, which is where `some View` erases to `AnyView`
instead of `DebugReplaceableView`. That difference is what the first CI
run caught.

Nothing measured differs between them. The unsafe cases produce SIGSEGV
on all four, the SwiftUI erasure to `DebugReplaceableView` is present on
all four, and a full reload of the sample app works on Xcode 26.5 at
434 ms.

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

Separate spike.

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
degraded-behavior failure, and it covers the ordinary
`var body: some View` case.

Mitigation:

-   classify any opaque-result-type declaration as rebuild-required
    unless the underlying type is proven identical,
-   separate SwiftUI adapter,
-   investigate Apple's debug replacement mechanisms, noting the
    iOS 26.0 floor on `DebugReplaceableView`.

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

The matrix was run on both targets. All 24 cases pass on both, and every
result below holds for both except where noted.

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
