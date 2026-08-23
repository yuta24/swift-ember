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
-   underlying type of an opaque result type (`some P`) changed --- this
    compiles cleanly, loads cleanly, and then behaves as undefined; see
    section 12.7,
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

Section 12.7 makes the stakes concrete: an ordinary
`@_dynamicReplacement` of `body` whose underlying type changes is not
merely unsupported, it is undefined behavior that no diagnostic warns
about and that may appear to work. SwiftUI `body` replacement is
therefore rebuild-required until a SwiftUI-specific mechanism is proven.

Apple exposes `DebugReplaceableView` for debug-time replacement
scenarios. Two facts constrain its use:

-   it is declared in **SwiftUICore**, not SwiftUI, and reaches callers
    through SwiftUI's re-export;
-   it is annotated
    `@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)`.

Any SwiftUI support built on it therefore carries a hard
deployment-target floor that core function replacement does not.
Record this in the compatibility matrix (section 20).

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
justified.

## 19. Testing strategy

### 19.1 Unit tests

-   change classifier,
-   build-context normalization,
-   replacement source generation,
-   protocol serialization,
-   toolchain feature probing.

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

All must fail closed.

### 19.4 Integration test

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

First measured data point, on the macOS host and an arm64 iOS Simulator
(see Appendix A):

``` yaml
toolchains:
  - xcode: "27.0 Beta 4"
    swift: "6.4 (swiftlang-6.4.0.27.1)"
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

### Step 5: Automation

Watcher + generator + compiler + IPC.

### Step 6: Classifier

Reject unsafe changes.

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
-   [ ] CI/unit/fixture tests are documented and runnable.

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
