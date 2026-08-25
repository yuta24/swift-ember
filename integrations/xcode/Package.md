# Making a Swift package patchable

An app is rarely one module. A file in a local package needs one line in that
package's manifest before anything in it can be hot reloaded, and this explains
why the app's own settings do not reach it.

## The setting

```swift
.target(
    name: "Feature",
    swiftSettings: [
        .unsafeFlags(["-Xfrontend", "-enable-implicit-dynamic",
                      "-Xfrontend", "-enable-private-imports"],
                     .when(configuration: .debug))
    ])
```

That is all. Optimisation and testability arrive on their own.

The second flag is what lets a patch reach the package's `private`
declarations. Without it the package is still patchable, but only for bodies
that touch nothing private --- which is a much smaller set than it sounds, since
most method bodies read private state. `doctor` reports it per module, by
asking the compiler rather than reading the setting.

## Why the xcconfig is not enough

Measured on Xcode 27, comparing the compiler invocations for an app target and
a local package target in the same build:

```
                                        app target   package target
-Onone                                       yes          yes
-enable-testing                              yes          yes
-Xfrontend -enable-implicit-dynamic          yes          no
```

`SWIFT_OPTIMIZATION_LEVEL` and `SWIFT_ENABLE_TESTABILITY` propagate into package
targets. `OTHER_SWIFT_FLAGS` does not, and that is where the flag that makes
declarations replaceable lives. A package in a correctly configured project
therefore compiles with no replacement keys at all — and until this was
understood, editing a file in one produced no patch, no error, and no reason.

## Why unsafeFlags is acceptable here

SwiftPM refuses `unsafeFlags` in a package resolved as a versioned dependency,
which is the point of the restriction: a dependency should not be able to change
how its consumers are built. A package inside your own repository, referenced by
path, is not resolved that way and is not subject to it.

If the package is one you also publish, put the setting behind a trait or keep
it in a local overlay rather than shipping it.

## Checking it worked

```
swift-splice doctor --project App.xcodeproj --scheme App
```

```
Replacement keys      OK    28 exported
  Feature             3 keys
  XcodeApp            25 keys
  a module missing from this list cannot be patched; see
  integrations/xcode/Package.md
Private imports       OK    every patchable module accepts @_private
```

The list is read out of the built binary, not out of build settings, so it
answers the question the settings cannot. A module that is missing gets a
refusal naming it when you edit it, rather than silence.

The private-imports line is asked the same way, by type-checking one import
against the built module. Both are questions a build setting can answer wrongly:
the setting can be right in a file nobody rebuilt since.
