# Physical iPhone release checklist

Complete these checks before publishing the draft GitHub Release. Use the CLI
from the draft asset and run the commands from the matching tagged checkout
so the app links that tag's runtime. Record the tag, CLI version, Xcode version,
iPhone model and iOS version, and each outcome in the release verification notes.

- [ ] Pair and unlock a development iPhone with Developer Mode enabled. Find
  its CoreDevice identifier with `xcrun devicectl list devices`. Build and run
  `examples/XcodeApp` in Debug on that iPhone using the team's Apple Development
  identity and a matching provisioning profile. Record the subtotal and
  **Session** value on screen.
- [ ] Run `swift-ember doctor` and then `swift-ember watch` with
  `--project examples/XcodeApp/XcodeApp.xcodeproj --scheme XcodeApp`,
  `--sources examples/XcodeApp/Sources,examples/XcodeApp/Feature/Sources`, and
  `--device <CoreDevice-ID>`. Include `--derived-data-path` if the build used a
  custom path. Confirm that doctor resolves the intended Debug build and
  development signing identity. Supply `--signing-identity <name-or-SHA>` if
  Xcode's settings do not expose the identity.
- [ ] Keep the app in the foreground and save a body-only edit to
  `Cart.subtotalLabel()`. Confirm the watcher reports `hot reloaded`, which on
  a physical device follows signing, the Team ID check, CoreDevice transfer,
  and the app's load acknowledgement. Confirm the new subtotal is visible
  with the same **Session** value. Verify the app and the patch dylib under
  `examples/XcodeApp/.ember/patches/` have the same `TeamIdentifier` using
  `codesign -dv --verbose=4` on each.
- [ ] Interrupt the device connection and confirm the iPhone becomes
  unreachable from CoreDevice. Restore the connection, unlock the phone, and
  bring the app to the foreground with the same watcher running. Save a second
  body-only edit and confirm a new successful reload and visible subtotal.
  Verify that the original **Session** value is still present.
- [ ] Save the watcher log and before, after, and reconnect screenshots with
  the verification notes. Stop the watcher and restore the example source.
  Resolve any failed check before publishing.
