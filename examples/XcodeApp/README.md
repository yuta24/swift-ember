# XcodeApp

A real `.xcodeproj`, wired to swift-splice the way a project would be. Where
`CounterApp` assembles its bundle from a shell script so the flags are visible,
this one goes through Xcode and its build settings, which is the case that has
to work for anyone else to use this.

## Running it

Boot a simulator, then from the repository root:

```
xcodebuild -project examples/XcodeApp/XcodeApp.xcodeproj -scheme XcodeApp \
           -configuration Debug \
           -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

swift-splice doctor --project examples/XcodeApp/XcodeApp.xcodeproj \
                    --scheme XcodeApp --sources examples/XcodeApp/Sources
swift-splice watch  --project examples/XcodeApp/XcodeApp.xcodeproj \
                    --scheme XcodeApp --sources examples/XcodeApp/Sources
```

Install and launch the built app, then edit a method body in
`Sources/Cart.swift`. Running from Xcode itself works the same way; the daemon
only needs the project, the scheme, and a running process.

## How a project opts in

Two steps.

**Base the Debug configuration on `integrations/xcode/Splice.xcconfig`.** It
sets the four things that make a binary patchable, and `doctor` names each one
separately when it is missing, so a half-configured project gets told which
half.

**Add the package and link `SpliceRuntime`.** The runtime's dialling and
loading code is compiled only when `SPLICE_ENABLED` is defined, which the
package does for Debug and only Debug. A Release build of an app that links it
carries an inert entry point and nothing else, so the call site needs no `#if`
of its own:

```swift
.onAppear {
    Splice.start { status in ... }
}
```

## Three things that surprised us

**Xcode 16 and later split a Debug app in two.** The executable in the bundle
is a thin launcher; the code lives in `XcodeApp.app/XcodeApp.debug.dylib`. All
20 replacement keys are in the dylib and the executable has none, so linking a
patch against the executable resolves nothing. `doctor` reported a correctly
configured project as having no keys until this was understood.

Which of the two to use comes from the build's `ENABLE_DEBUG_DYLIB`, not from
the file being there. A dylib from an earlier build outlives the setting that
produced it, and picking it up would be worse than picking nothing: the patch
would link against a binary the process is not running, and `dlopen` would
resolve the load command by pulling a second copy of the whole app module into
the live process. Replacements would land in the copy, the running code would
be untouched, and the reload would be reported as successful.

**Build settings come from `xcodebuild -showBuildSettings -json`.**
`DESIGN.md` section 6.2 argued for capturing the literal compile invocation
instead. Scraping a build log for the `swift-frontend` line means requiring a
full build, parsing output with no compatibility promise, and getting nothing
when the build is already up to date. Asking Xcode for its resolved settings
avoids all three, and the reason 6.2 wanted the invocation -- not guessing --
is met a different way: nothing derived is trusted on its own, and `doctor`
reads the built binary back to check it really does export keys.

**The language mode has to travel with the patch.** Xcode reports
`SWIFT_VERSION = 5.0`, the compiler accepts only `5`, and a body written for
Swift 6 but type-checked under Swift 5 loses isolation inference and
sendability checking. That fails in the permissive direction: the replacement
can introduce a data race the original could not have had. `SWIFT_VERSION`,
`SWIFT_STRICT_CONCURRENCY`, and `SWIFT_UPCOMING_FEATURE_*` are forwarded to the
patch compile alongside the compilation conditions.

## The project file

Hand-written, and deliberately small: a synchronized source group instead of
per-file references, a local package reference to the repository root, and the
xcconfig as the Debug base configuration. There is no project generator in the
dependency list, and adding one to read a 200-line example seemed worse than
writing the 200 lines.
