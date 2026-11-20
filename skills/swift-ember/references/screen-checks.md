# Checking the running screen

After an acknowledged patch, observe the same app on the same destination.
Check a visible or accessible value that exercises the changed declaration.
For paths that run on interaction, perform that interaction in the app while
the patch is loaded. A hot-reload status message alone does not establish
that the rendered result changed.

If the device-relay skill is available, follow it to select the matching
Simulator or physical device and use the appropriate runner session. With
the app visible, capture and inspect the screenshot and accessibility
hierarchy as needed.

```sh
relay screenshot --scale 1
relay source --format compact
```

Read the screenshot from the printed path. Keep the user’s app process alive
while checking it, so the loaded patch remains active. If you started a relay
runner for the task, follow its skill's cleanup steps.

For a Simulator without device-relay, save the image with the same UDID used
for the running app, then open the PNG. Substitute the literal UDID and
an output path in an existing directory.

```sh
xcrun simctl io 'SIMULATOR_UDID' '.ember/after.png'
```
