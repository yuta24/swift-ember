# Which changes reload

Use the same declaration identity and ABI-relevant signature. The upstream
README sections **What reloads** and **What it will not do**, and DESIGN §7.2
and §7.3 describe the classifier and its restrictions.

| Usually patchable in Debug | Conditions |
| --- | --- |
| Function, method, and computed property bodies | Includes classes, structs, enums, actors, generic methods, constrained extensions, and existing `static`, `mutating`, `async`, `throws`, or `@MainActor` methods. Plain `@inline(__always)` and `@inline(never)` work in the measured Debug configuration. |
| Private and fileprivate bodies and references | The owning module must have private imports enabled. A private helper reached by an unreplaceable caller can require a rebuild. |
| Existing overrides and UIKit Objective-C entry points | The replacement runs on the next call. Layout and list refresh can trigger calls on existing instances. An already-run `viewDidLoad` needs a new controller instance. |
| A newly added helper used by a changed caller | The patch carries supported new declarations. Adding an overload of an existing name, an override, or an `@objc` entry point requires a rebuild. |
| An opted-in SwiftUI `body` | The file contains a View with `@ObserveEmber`, and the body's outermost expression ends in `.emberable()`. The running build needs this setup to preserve its `AnyView` boundary and refresh the existing view. |

Rebuild for these changes.

- Stored properties and property observers, enum cases, type layout,
  inheritance, and conformances or protocol requirements that affect witnesses
  or layout.
- Signatures, including parameter or return types, async/throws/isolation,
  generic signatures, and a computed property's getter/setter set.
- Removed declarations, deleted or renamed watched Swift files, and new
  source files missing from the build's source list.
- Initializer bodies, operator declarations, or bodies emitted into callers via
  `@inlinable`, `@_transparent`, or `@_alwaysEmitIntoClient`. Rebuild those
  callers too.
- Opaque result types (`some P`), apart from the opted-in SwiftUI case above.
  An unannotated SwiftUI `body` requires a rebuild.
- Source-location literals written directly in the changed body, such as
  `#function`, `#file`, `#line`, and `#dsohandle`. Source-location literals in
  a callee's default argument can escape this detection and report the
  generated patch location.

A single poll can group multiple saves into an atomic patch, including
changes across watched modules. A classification or compilation failure can
hold the whole batch. A watched-file deletion or rename blocks further
patches until a rebuild establishes a new baseline.

## Recovery

For a required rebuild without automatic recovery, stop the session you
started, build the Debug app with the intended edits, install and relaunch it
as appropriate, and rerun doctor and start. Then wait for the accepted
connection.

If the user already opted in to `rebuildCommand` in the project config (or
`--rebuild-command` on the command line), the command must rebuild and
relaunch the target. Ember checks that a different process connects with the
new binary identity. Keep the watcher active while the command works. The
relaunch wait defaults to 300 seconds (`rebuildTimeout`). Follow its log to
completion. Ask before adding or changing automatic recovery.
