# PRD: Swift Hot Reload Runtime

> Status: Draft\
> Audience: OSS contributors, maintainers, coding agents (including
> Claude Code)\
> Working name: `SwiftHotReload`\
> Initial target: iOS Simulator / Debug builds\
> Last updated: 2026-08-23

## 1. Summary

SwiftHotReload is an open-source development tool that reduces the
edit-build-run-debug loop for Swift iOS applications.

The initial product goal is to allow a developer to modify eligible
Swift function bodies, save the source file, and apply the new
implementation to an already-running iOS Simulator process without
restarting the application or discarding application state.

The project deliberately does **not** attempt to implement a Swift
virtual machine or replace the Swift compiler. It reuses the active
Xcode Swift toolchain and Swift runtime facilities, especially dynamic
replacement, and initially uses normal Mach-O dynamic loading. LLVM
ORC/JITLink is a later optimization path, not an MVP dependency.

## 2. Problem

A conventional iOS development loop often requires:

1.  Edit Swift source.
2.  Recompile a target.
3.  Relink the application.
4.  Relaunch or reinstall it.
5.  Reproduce navigation and application state.
6.  Reach the code path being debugged.
7.  Observe the result.

For applications with slow builds, authentication flows, deep
navigation, network state, or expensive setup, the time between editing
code and observing behavior is disproportionately high.

SwiftUI Preview solves part of the UI iteration problem, but it is not a
general replacement for modifying arbitrary logic in the stateful,
running application.

## 3. Product vision

The desired experience is:

``` text
Run app in iOS Simulator
        |
        v
Navigate to desired state
        |
        v
Edit eligible Swift code
        |
        v
Save
        |
        v
Compile only the patch
        |
        v
Load replacement
        |
        v
Continue using the same process and state
```

Target interaction latency should eventually feel closer to
scripting-language iteration than to a full Xcode rebuild.

## 4. Goals

### 4.1 MVP goals

-   Support iOS Simulator Debug builds.
-   Use the exact Swift/Xcode toolchain used to build the target.
-   Detect Swift source changes.
-   Identify changes that are eligible for hot replacement.
-   Generate and compile replacement code.
-   Load a replacement image into the running application.
-   Replace eligible Swift function implementations.
-   Preserve the process, heap objects, navigation state, and other
    runtime state.
-   Support methods on `class`, `struct`, and `enum` where replacement
    semantics permit it.
-   Support ordinary functions and computed-property accessors where
    practical.
-   Produce actionable diagnostics when a change cannot be hot reloaded.
-   Fall back cleanly to "restart/rebuild required" rather than
    attempting unsafe replacement.
-   Require no source changes in Release builds.

### 4.2 Developer-experience goals

A successful reload should produce concise feedback such as:

``` text
🔥 Hot reloaded 3 declarations in 284 ms
```

An unsupported edit should explain why:

``` text
⚠️ Hot reload unavailable:
User.swift changed stored-property layout.
Full rebuild required.
```

### 4.3 Long-term goals

-   Sub-second median hot-reload latency on medium-sized projects.
-   SwiftUI-oriented reload support with state preservation.
-   UIKit support.
-   async/await and actor-aware replacement.
-   Generic function support where ABI-compatible.
-   Multi-module projects and Swift packages.
-   Persistent compiler process to reduce frontend startup cost.
-   Replace conventional dylib linking with LLVM ORC/JITLink if
    profiling shows meaningful benefit.
-   IDE/editor-independent operation.
-   Optional integrations for Xcode, VS Code, Cursor, and agentic coding
    tools.

## 5. Non-goals

The following are explicitly outside the MVP:

-   App Store runtime code delivery.
-   Production hot patching.
-   Running downloaded Swift code in shipping applications.
-   Supporting Release/optimized builds.
-   Implementing a Swift interpreter or VM.
-   Reimplementing Swift parsing, type checking, SIL, ARC, generics, or
    concurrency.
-   Supporting arbitrary ABI-incompatible source edits.
-   Migrating existing value layouts after stored properties change.
-   iOS physical-device support.
-   Guaranteeing compatibility with private/underscored Swift compiler
    features across toolchains.
-   Replacing Xcode's build system.

## 6. Target users

### Primary

Swift/iOS engineers working on:

-   large applications,
-   stateful flows,
-   SwiftUI applications,
-   UIKit applications,
-   complex debugging sessions,
-   applications with expensive startup/navigation.

### Secondary

-   framework authors,
-   compiler/runtime researchers,
-   OSS contributors,
-   developer-tooling teams.

## 7. Core use cases

### UC-1: Replace a method body

Given:

``` swift
struct Price {
    var value: Int

    dynamic func formatted() -> String {
        "\(value)"
    }
}
```

The developer changes only the implementation. The existing application
process remains alive and subsequent calls execute the replacement.

### UC-2: Replace a mutating struct method

An existing struct value remains in memory. The implementation of a
`mutating` method changes without changing the struct layout. Subsequent
invocations use the replacement implementation.

### UC-3: Preserve deep application state

The developer navigates through login and multiple screens, changes an
eligible ViewModel/service method, reloads it, and tests the new
behavior without navigating again.

### UC-4: Reject a layout-changing edit

A developer adds a stored property to a struct or class. The tool
detects an ABI/layout-changing edit and reports that a full rebuild is
required.

### UC-5: SwiftUI iteration

A developer modifies eligible View behavior and receives a reload
without restarting the process. SwiftUI-specific support may use
additional debug infrastructure and is allowed to have stricter
compatibility rules than core function replacement.

## 8. Change classification

Every detected edit MUST be classified before application.

### Tier A: Hot patch

Verified against Xcode 27.0 Beta 4 / Swift 6.4 on the macOS host; see
`DESIGN.md` Appendix A. Re-confirmation on an iOS Simulator runtime is
still owed.

-   function body change,
-   method body change (`class`, `struct`, `enum`, `final`),
-   computed getter/setter body change,
-   `mutating` method body change,
-   `async`, `throws`, and `async throws` function body change,
-   `actor`-isolated and `@MainActor` method body change,
-   protocol witness and protocol extension default implementation body
    change, for both direct and existential dispatch,
-   static and class method body change,
-   `@objc` method body change on an `NSObject` subclass,
-   generic function body change under `-Onone`.

### Tier B: Potentially hot reloadable

Requires validation and may be introduced incrementally:

-   new helper function,
-   new method,
-   generic implementation change under any configuration other than
    `-Onone`, where specialization may bypass the replacement,
-   changes reached only through binary-only dependency modules.

### Tier C: Hot restart / rebuild required

Examples:

-   stored property added/removed,
-   stored property type changed,
-   enum case added/removed,
-   declaration signature changed,
-   generic signature changed incompatibly,
-   superclass changed,
-   ABI-relevant conformance/layout changes,
-   build settings changed,
-   imported module graph changed in an unsupported way,
-   SwiftUI `body`, or any other declaration returning an opaque result
    type, whose underlying type changes. This passes both the compiler
    and the loader without a diagnostic and is then undefined at
    runtime, observed variously as the new value, as garbage, and as a
    crash. Unsafe rather than merely unsupported,
-   `@inlinable` or `@_transparent` declaration body changed. Implicit
    dynamic does not cover these,
-   `private` / `fileprivate` declarations, which implicit dynamic does
    not cover and `@testable import` cannot reach.

Safety rule: unknown changes are Tier C.

The last three are rejected by the compiler when the patch is built, so
they fail closed even if the classifier misses them. The opaque result
type case is not, which is why the classifier exists.

## 9. Functional requirements

### FR-1 Toolchain discovery

The tool MUST discover and use the active build's Swift
compiler/toolchain rather than shipping a separately versioned Swift
compiler.

It SHOULD capture the original Swift compiler invocation or equivalent
build metadata, including relevant:

-   target triple,
-   SDK,
-   deployment target,
-   Swift language mode,
-   conditional compilation flags,
-   module search paths,
-   framework search paths,
-   bridging/import settings,
-   generated source/module paths.

### FR-2 Debug instrumentation

The project MUST provide a supported mechanism for making eligible
declarations dynamically replaceable in Debug builds.

The mechanism is the Swift frontend's hidden `-enable-implicit-dynamic`
option. It is a *frontend* option and MUST be passed as
`-Xfrontend -enable-implicit-dynamic`; the bare spelling is rejected by
the `swiftc` driver. Because this is not a stable public interface, the
implementation MUST isolate it behind a toolchain compatibility layer.

The option does not cover every declaration. `@inlinable`,
`@_transparent`, `private`, and `fileprivate` declarations receive no
replacement key. Patching them fails at compile time with an actionable
diagnostic, so the gap is safe, but the covered set is undocumented and
version-sensitive. The implementation MUST treat coverage as something
measured per toolchain rather than derived from a source-level rule.

### FR-3 Change detection

The daemon MUST detect modified `.swift` files.

The MVP MAY use file-level recompilation even when only one declaration
changed.

### FR-4 Compatibility analysis

Before loading a patch, the system MUST determine whether the change is
compatible with the running program.

A conservative false negative is acceptable. An unsafe false positive is
not.

### FR-5 Patch generation

The system MUST generate replacement declarations compatible with Swift
dynamic replacement semantics.

### FR-6 Patch compilation

The patch MUST be compiled using the same effective
toolchain/configuration as the running target.

### FR-7 Runtime communication

The host daemon and runtime library MUST have a local development-only
communication channel for:

-   reload requests,
-   patch locations or payload metadata,
-   status,
-   diagnostics,
-   timing information.

### FR-8 Runtime loading

The MVP runtime SHOULD load compiled patch images using platform
dynamic-loading facilities in the iOS Simulator.

### FR-9 Replacement activation

The Swift runtime's dynamic replacement mechanism SHOULD be responsible
for redirecting replaceable functions. The project SHOULD NOT manually
patch arbitrary machine-code call sites in the MVP.

### FR-10 Diagnostics

Errors MUST be surfaced with:

-   affected declaration/file,
-   stage that failed,
-   reason,
-   recommended recovery action.

### FR-11 Recovery

A failed patch MUST NOT intentionally corrupt the running process. When
safe recovery is uncertain, the tool MUST request a rebuild/restart.

### FR-12 Symbol visibility

The application MUST be built with `-enable-testing`
(`SWIFT_ENABLE_TESTABILITY = YES`) in the hot-reload-enabled Debug
configuration.

Dynamic replacement binds through a replacement key symbol. Swift emits
`internal` declarations with hidden visibility, so without this setting
those keys are absent from the dynamic symbol table and patch loading
fails at `dlopen`. `-Xlinker -export_dynamic` does not substitute for
it.

Generated patch source MUST import the application module with
`@testable`.

The tool MUST detect a missing testability setting up front and report
it as a configuration error, not as a reload failure.

### FR-13 Reload verification

A patch that loads without error but replaces nothing MUST be reported
as a failure, not a success.

Enumerating replacement keys in the running image is useful evidence,
but it is not sufficient on its own: an `@objc` member gets no native
replacement key and is replaceable regardless. Verification SHOULD
therefore rest on the compiler's own acceptance of the patch plus an
observable check, not on symbol presence alone.

## 10. Performance requirements

MVP performance targets are directional, not release blockers:

  Metric                                    MVP target   Long-term target
  --------------------------------------- ------------ ------------------
  File change detection                      \< 100 ms           \< 50 ms
  Simple patch compile + load                   \< 2 s          \< 500 ms
  Runtime activation                         \< 200 ms           \< 50 ms
  Full process restart on eligible edit              0                  0

Every pipeline stage SHOULD emit timing telemetry locally for profiling.

## 11. Compatibility policy

### Swift/Xcode

-   A patch MUST be produced using the same selected Xcode/Swift
    toolchain as the original build.
-   Cross-toolchain patching is unsupported.
-   Underscored compiler/runtime behavior is treated as
    version-sensitive.
-   Compatibility MUST be feature-detected where practical.
-   Toolchain-specific behavior MUST live behind adapters.

### OS

MVP support is iOS Simulator runtimes supported by the selected Xcode.

Core function replacement carries no special deployment-target floor.
SwiftUI-specific support built on `DebugReplaceableView` does: that type
is declared in SwiftUICore (re-exported by SwiftUI) and is available
only on iOS 26.0 / macOS 26.0 and later. SwiftUI support MUST document
this floor separately from core support.

The project MUST NOT initially promise physical-device support.

### Architectures

Initial priority:

1.  arm64 macOS host + arm64 iOS Simulator.
2.  x86_64 Simulator only if contributor demand justifies it.

## 12. Security and safety

This is a local developer tool.

-   Runtime functionality MUST compile only into explicitly enabled
    Debug configurations.
-   The instrumentation flags MUST NOT reach Release. This covers
    `-Xfrontend -enable-implicit-dynamic` and `-enable-testing` alike;
    the latter widens symbol visibility and is Debug-only.
-   Release builds MUST NOT contain an active reload server by default.
-   Remote network exposure MUST NOT be enabled by default.
-   The runtime SHOULD authenticate/validate the local host connection
    if a network transport is used.
-   Patch loading MUST be scoped to the current development session.
-   Unsupported changes MUST fail closed.

## 13. OSS requirements

-   Permissive license preferred; final license decision before first
    public release.
-   Repository MUST contain reproducible build/test instructions.
-   Architecture and compatibility assumptions MUST be documented.
-   Compiler-private dependencies MUST be clearly marked.
-   Toolchain compatibility tests SHOULD run against multiple supported
    Xcode versions where CI availability permits.
-   Contributions adding toolchain-specific workarounds MUST include
    tests or fixtures.

## 14. Success metrics

The project is successful at v0.1 when:

1.  A sample iOS Simulator app can remain running.
2.  An eligible Swift function/method implementation can be edited.
3.  Saving causes an automated patch build.
4.  The patch is loaded into the existing process.
5.  The next invocation executes the new implementation.
6.  Existing application state remains intact.
7.  A stored-property layout change is detected/rejected.
8.  The same demo works for at least one `struct` method and one `class`
    method.

## 15. Milestones

### M0 --- Research spike

Complete on the macOS host with Xcode 27.0 Beta 4 / Swift 6.4. The full
matrix and method are in `DESIGN.md` Appendix A.

-   [x] Top-level function.
-   [x] Class method.
-   [x] Struct method.
-   [x] Mutating struct method.
-   [x] Async method, plus `throws`, `async throws`, `actor`, and
    `@MainActor`.
-   [x] Computed property, `final` method, generic function, protocol
    witness, protocol extension default.
-   [x] Mach-O replacement metadata inspected: `__TEXT,__swift5_replace`
    in the patch, `Tx` replacement keys in the host image.
-   [x] Exact Xcode/Swift version recorded.

Two findings changed the plan:

-   `-enable-testing` is a hard requirement, not a convenience;
-   changing an opaque result type's underlying type is undefined
    behavior that neither the compiler nor the loader flags, and that
    sometimes produces the correct answer.

Implicit dynamic also turned out not to cover `@inlinable`,
`@_transparent`, `private`, or `fileprivate`, but each of those is
rejected at compile time, so the pipeline fails closed there.

The matrix is checked in as `fixtures/`, runnable with
`fixtures/run.sh`, which regenerates `fixtures/results.yaml`.

Remaining: repeat the matrix on an arm64 iOS Simulator runtime, and
cover the already-suspended-task case for `async`.

### M1 --- Manual patch PoC

-   Sample app built with Debug instrumentation.
-   Hand-authored replacement source.
-   Patch compiled as dylib.
-   Patch manually loaded.
-   State-preserving replacement demonstrated.

### M2 --- Automated local loop

-   File watcher.
-   Build-command capture.
-   Replacement source generation.
-   Automatic compilation.
-   Runtime communication.
-   Automatic loading.
-   CLI diagnostics.

### M3 --- Compatibility classifier

-   Detect common layout/signature changes.
-   Fail closed.
-   Add fixture suite for supported/unsupported changes.

### M4 --- SwiftUI spike

-   Investigate `DebugReplaceableView` and current Xcode behavior.
-   Determine opaque-result-type constraints.
-   Demonstrate state-preserving SwiftUI edit where feasible.

### M5 --- Performance

Profile:

``` text
change detection
-> source analysis
-> swift frontend
-> object generation
-> linker
-> load
-> runtime activation
```

Only after measurement, evaluate:

-   persistent compiler/frontend,
-   object-file caching,
-   LLVM ORC/JITLink,
-   out-of-process JIT linking.

## 16. Open questions

Answered by the M0 spike on the macOS host. Re-confirm each on an iOS
Simulator runtime before treating it as settled.

2.  Can generated replacement source import the application module
    cleanly for internal declarations?
    **Yes**, via `@testable import <Module>` against an application
    built with `-enable-testing`. Additional build instrumentation is
    required, but it is a supported public build setting rather than a
    private compiler feature.
3.  What metadata must be emitted/registered when loading a replacement
    image?
    A `__TEXT,__swift5_replace` section in the patch, bound to exported
    `Tx` replacement keys in the host image. dyld and the Swift runtime
    handle the rest; no manual registration was needed.
4.  How does dynamic replacement interact with async functions, actors,
    protocol witnesses, and generic specialization?
    `async`, `async throws`, `actor`, `@MainActor`, protocol witnesses
    (direct and existential), protocol extension defaults, and generic
    functions all replace correctly under `-Onone`. Specialization under
    optimization is untested and out of scope for v0.x.
7.  What exact mechanism should be used to load a patch into the
    Simulator process?
    `dlopen` of a patch dylib. Failures surface as a clear
    `symbol not found in flat namespace` diagnostic.
10. How should multiple generations of replacements be retired or
    retained safely?
    Retention is the MVP answer. The most recently loaded generation
    wins with no extra flags; chaining options exist but are not needed.

Still open:

1.  What is the smallest stable subset of Swift declarations that can be
    reliably replaced across supported toolchains?
5.  Which declaration changes can be classified reliably without
    embedding Swift compiler libraries?
6.  Is SourceKit sufficient for change classification, or is compiler
    integration required?
8.  How much latency is linker-related versus Swift frontend-related?
9.  Does JITLink correctly register every Swift-specific Mach-O section
    needed by replacement images for our supported toolchains?
11. The skipped set is measured for one toolchain (`@inlinable`,
    `@_transparent`, `private`, `fileprivate`, `deinit`), but it is
    undocumented. How should the tool track it across toolchains without
    hand-maintaining a list?
12. Can `private` / `fileprivate` declarations be supported at all, or
    must they stay permanently Tier C?
13. Is there any way to detect an opaque-result-type underlying change
    before loading, given that the compiler accepts it silently? Failing
    that, is rejecting every opaque-result-type declaration too blunt to
    be useful for SwiftUI?

## 17. References

-   Swift underscored attributes / `@_dynamicReplacement`:
    https://github.com/swiftlang/swift/blob/main/docs/ReferenceGuides/UnderscoredAttributes.md
-   Swift frontend `-enable-implicit-dynamic`:
    https://github.com/swiftlang/swift/blob/main/include/swift/Option/FrontendOptions.td
-   Swift SIL dynamically replaceable functions:
    https://github.com/swiftlang/swift/blob/main/docs/SIL/FunctionAttributes.md
-   LLVM ORCv2: https://llvm.org/docs/ORCv2.html
-   LLVM JITLink: https://llvm.org/docs/JITLink.html
-   `DebugReplaceableView` (declared in SwiftUICore, re-exported by
    SwiftUI; iOS 26.0+):
    https://developer.apple.com/documentation/swiftui/debugreplaceableview
