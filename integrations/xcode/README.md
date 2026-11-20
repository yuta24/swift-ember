# Xcode integration

Follow the [Debug Build Settings](../../README.md#set-debug-build-settings)
in the main README to configure your app target in Xcode, then build, run,
and start `swift-ember watch` in a terminal.

## Optional setup with init and Ember.xcconfig

To set up the Debug settings, configuration file, and source recording
together, share a scheme that builds one application target. Copy
`Ember.xcconfig` beside the project or pass the path to the template in a
swift-ember checkout.

```sh
swift-ember init --workspace App.xcworkspace --scheme App --sources Sources,Feature/Sources
swift-ember init --workspace App.xcworkspace --scheme App --sources Sources,Feature/Sources --write
```

Use `--project App.xcodeproj` for a standalone project. The first invocation
previews the edits. The second adds the app target's development Base
Configuration, creates `.swift-ember.json`, and updates the shared scheme
with Build pre- and post-actions. Use `--configuration` for a development
configuration with a custom name. The scheme's Archive configuration is
reserved for shipping.

When the app target already has a Base Configuration, init creates a wrapper
that includes the existing xcconfig first. This works with a CocoaPods
xcconfig after `pod install` has generated it. Keep the wrapper selected as
the app target's Debug Base Configuration. Source roots and includes are
stored as relative paths. Keep your Ember template in the checkout if others
will build the same project.

If Xcode shows target-level overrides for `OTHER_SWIFT_FLAGS` or
`SWIFT_ACTIVE_COMPILATION_CONDITIONS`, keep the existing values and add
`$(inherited)` to inherit the xcconfig settings. Remove any overrides that
disable testability or change optimisation from `-Onone` in Debug. If your
project uses a generator or a Base Configuration path init cannot resolve,
make the same setup in the generator or in Xcode. Include `Ember.xcconfig`
from the app target's Debug xcconfig, or select it as the Debug Base
Configuration if you have none. You can add [optional scheme actions](../../README.md#scheme-actions-optional)
to record a build source manifest or start the watcher from Xcode.

The generated scripts run for the selected development configuration. Make
`swift-ember` available to Xcode via `PATH` or `$HOME/.local/bin`, or set
`SWIFT_EMBER_CLI` to the executable path in the environment invoking Xcode.
Choose `--post-action start` to restart the watcher from the build action.
Clean the build folder before the first recorded build. See [Package.md](Package.md)
for the flags needed by local Swift packages.

## Release isolation

Keep the Ember Build Settings scoped to Debug and guard the local package flags with
`.when(configuration: .debug)`. You can include `Ember.release.xcconfig`
from the Release configuration as an explicit guard. It disables testability
and clears the Ember-specific flag and condition variables while retaining
unrelated flags and conditions. Remove literal Ember flags and
`EMBER_ENABLED` from any other Release settings.

After building, run the check against the build's scheme, configuration and
destination. The default destination is the generic iOS Simulator.
For an Archive or exported device app, use the shipped bundle directly.

```sh
swift-ember doctor --release --workspace App.xcworkspace --scheme App \
  --destination 'generic/platform=iOS' \
  --app App.xcarchive/Products/Applications/App.app
```

The check reads Xcode's effective app-target flags, testability settings and
compilation conditions. It checks the executable and embedded Mach-O images
for Swift dynamic-replacement keys and sections and for the types compiled
into the enabled Ember runtime. A Swift package's compiler flags can differ
from the app's settings. Testability and private-import support may leave no
recognisable evidence in a stripped image, so audit package compiler flags
in their manifests or build logs when checking those settings. Use the
actual shipping bundle to catch discrepancies between settings and the
artifact that will be distributed.
