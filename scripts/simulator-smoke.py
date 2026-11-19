#!/usr/bin/env python3
"""Build, launch, and hot-reload a disposable copy of the real XcodeApp."""

import contextlib
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
SCHEME = "XcodeApp"
BEFORE = "775 cents"
AFTER = "Ember patched"


class SmokeFailure(RuntimeError):
    pass


def run(args, *, timeout=30, log=None, stdin=None):
    output = log.open("w") if log else contextlib.nullcontext(subprocess.PIPE)
    with output as stream, subprocess.Popen(
        args, cwd=ROOT, text=True, start_new_session=True,
        stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
        stdout=stream, stderr=subprocess.STDOUT,
    ) as process:
        try:
            stdout, _ = process.communicate(stdin, timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            if isinstance(error, KeyboardInterrupt):
                raise
            raise SmokeFailure(f"{args[0]} timed out after {timeout}s ({log or shlex.join(map(str, args))})") from error
        if process.returncode:
            raise SmokeFailure(f"{args[0]} exited {process.returncode}: {log or stdout.strip()}")
        return stdout or ""


def stage_project(work, ember, device, logs):
    # Preserve the relative local SwiftPM and xcconfig references in the project.
    shutil.copy2(ROOT / "Package.swift", work)
    for directory in ("runtime", "integrations/xcode", "examples/XcodeApp"):
        shutil.copytree(ROOT / directory, work / directory, ignore=shutil.ignore_patterns(
            ".build", ".ember", "xcuserdata", "project.xcworkspace",
        ))
    project = work / "examples/XcodeApp/XcodeApp.xcodeproj"
    scheme = project / "xcshareddata/xcschemes/XcodeApp.xcscheme"
    tree = ET.parse(scheme)
    build = tree.find("BuildAction")
    target = build.find("BuildActionEntries/BuildActionEntry/BuildableReference")

    for phase, actions in (("PreActions", ("prepare",)), ("PostActions", ("record", "start"))):
        section = ET.Element(phase)
        build.insert(0 if phase == "PreActions" else 1, section)
        for action in actions:
            command = shlex.join(map(str, (ember, "xcode", action, "--no-config",
                                           "--project", project, "--scheme", SCHEME)))
            install = ""
            if action == "start":
                # The watcher writes its session into the installed app's data container.
                install = '''echo 'Installing XcodeApp'
/usr/bin/xcrun simctl install "$TARGET_DEVICE_IDENTIFIER" "$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
'''
            script = f'''set -eu
exec >> {shlex.quote(str(logs / 'scheme-actions.log'))} 2>&1
echo 'Running xcode {action}'
test "$TARGET_DEVICE_IDENTIFIER" = {shlex.quote(device)}
{install}{command} --sources "$SRCROOT/Sources,$SRCROOT/Feature/Sources" --startup-timeout 45
echo 'Passed xcode {action}'
'''
            execution = ET.SubElement(section, "ExecutionAction", {
                "ActionType": "Xcode.IDEStandardExecutionActionsCore.ExecutionActionType.ShellScriptAction",
            })
            content = ET.SubElement(execution, "ActionContent", title=f"Ember {action}", scriptText=script)
            ET.SubElement(content, "EnvironmentBuildable").append(ET.Element(target.tag, target.attrib))
    tree.write(scheme, encoding="utf-8", xml_declaration=True)
    return project


def wait_for(description, seconds, condition):
    deadline = time.monotonic() + seconds
    while True:
        if condition():
            return
        if time.monotonic() >= deadline:
            raise SmokeFailure(f"Timed out after {seconds}s waiting for {description}")
        time.sleep(1)


def smoke(work, cache, logs):
    sdk = run(("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version")).strip()
    devices = run(("xcrun", "simctl", "list", "devices", "available"))
    (logs / "devices.log").write_text(devices)
    device = run(("bash", ROOT / "scripts/select-simulator-device.sh", sdk), stdin=devices).strip()
    if not device:
        raise SmokeFailure(f"No iPhone Simulator is available for the iOS {sdk} SDK")
    initially_shutdown = f"({device}) (Shutdown)" in devices
    if not initially_shutdown and f"({device}) (Booted)" not in devices:
        raise SmokeFailure(f"Simulator {device} is changing state; wait for it to settle")
    print(f"Using iOS {sdk} Simulator {device}", flush=True)

    swift_build = ("swift", "build", "--package-path", ROOT / "Tools/swift-ember",
                   "--scratch-path", cache / "host", "--cache-path", cache / "cache",
                   "--config-path", cache / "config", "--security-path", cache / "security")
    print("Building swift-ember", flush=True)
    run(swift_build, timeout=420, log=logs / "swift-build.log")
    ember = Path(run((*swift_build, "--show-bin-path")).strip()) / "swift-ember"
    ocr = work / "simulator-smoke-ocr"
    run(("xcrun", "swiftc", ROOT / "scripts/simulator-smoke-ocr.swift", "-o", ocr),
        timeout=45, log=logs / "ocr-build.log")

    project = stage_project(work, ember, device, logs)
    product = work / "DerivedData/Build/Products/Debug-iphonesimulator/XcodeApp.app"
    bundle = f"dev.swift-ember.XcodeApp.smoke.{uuid.uuid4().hex}"
    simctl = ("xcrun", "simctl")
    stop = (ember, "stop", "--no-config", "--project", project, "--scheme", SCHEME,
            "--simulator", device)
    watcher_logs = project.parent / ".ember/logs"
    boot_requested = False
    build_started = False
    cleanup_errors = []

    def cleanup_command(command, *, log, timeout=15):
        try:
            run(command, timeout=timeout, log=logs / log)
        except (SmokeFailure, OSError) as error:
            cleanup_errors.append(str(error))

    actions_log = logs / "scheme-actions.log"
    try:
        boot_command = (*simctl, "bootstatus", device)
        if initially_shutdown:
            boot_command += ("-b",)
            boot_requested = True
        for attempt in (1, 2):
            try:
                run(boot_command, timeout=75, log=logs / f"boot-{attempt}.log")
                break
            except SmokeFailure as error:
                if attempt == 2:
                    raise
                print(f"Retrying Simulator readiness after {error}", flush=True)

        print("Building XcodeApp and running its Scheme actions", flush=True)
        build_started = True
        run(("xcodebuild", "-project", project, "-scheme", SCHEME, "-configuration", "Debug",
             "-destination", f"platform=iOS Simulator,id={device}",
             "-derivedDataPath", work / "DerivedData", "-resultBundlePath", logs / "XcodeApp.xcresult",
             f"PRODUCT_BUNDLE_IDENTIFIER={bundle}", "build"),
            timeout=180, log=logs / "xcodebuild.log")
        actions = actions_log.read_text() if actions_log.exists() else ""
        for action in ("prepare", "record", "start"):
            if f"Passed xcode {action}" not in actions.splitlines():
                raise SmokeFailure(f"Scheme action {action} did not complete; see {actions_log}")
        if not product.with_name(f"{product.name}.swift-ember-sources.json").is_file():
            raise SmokeFailure("Xcode did not record source hashes beside the built app")
        watchers = list(watcher_logs.glob("*.log"))
        if len(watchers) != 1:
            raise SmokeFailure(f"Expected one watcher log; found {len(watchers)} in {watcher_logs}")
        watcher = watchers[0]

        launch_log = logs / "launch.log"
        run((*simctl, "launch", device, bundle), log=launch_log)
        launched = re.search(rf"^{re.escape(bundle)}: (\d+)$", launch_log.read_text(), re.MULTILINE)
        if not launched:
            raise SmokeFailure(f"Could not identify the launched app process; see {launch_log}")
        pid = int(launched[1])
        connected = f"connected  pid {pid}, {bundle}"
        wait_for(connected, 30, lambda: connected in watcher.read_text())

        def rendered(label, phase):
            screenshot = logs / f"{phase}.png"
            run((*simctl, "io", device, "screenshot", screenshot), timeout=10)
            text = run((ocr, screenshot), timeout=25)
            (logs / f"{phase}.txt").write_text(text)
            return re.search(rf"\b{re.escape(label)}\b", " ".join(text.split()), re.IGNORECASE)

        wait_for(f"the original '{BEFORE}' on screen", 25, lambda: rendered(BEFORE, "before"))
        print("Saving a change to Cart.subtotalLabel()", flush=True)
        subject = project.parent / "Sources/Cart.swift"
        original = r'"\(subtotalCents) cents"'
        source = subject.read_text()
        if source.count(original) != 1:
            raise SmokeFailure("The smoke edit no longer matches XcodeApp's subtotalLabel()")
        temporary = subject.with_suffix(".tmp")
        temporary.write_text(source.replace(original, f'"{AFTER}"'))
        temporary.replace(subject)

        wait_for("the daemon's hot reload acknowledgement", 60,
                 lambda: "hot reloaded" in watcher.read_text())
        wait_for(f"'{AFTER}' on screen", 25, lambda: rendered(AFTER, "after"))
        os.kill(pid, 0)  # The process launched before the edit is still alive.
        print(f"Verified {BEFORE!r} → {AFTER!r} in XcodeApp (PID {pid})", flush=True)
    except (SmokeFailure, OSError, KeyboardInterrupt) as error:
        (logs / "failure.log").write_text(f"{error or 'interrupted'}\n")
        cleanup_command((*simctl, "io", device, "screenshot", logs / "failure.png"),
                        log="failure-screenshot.log")
        cleanup_command((*simctl, "spawn", device, "log", "show", "--last", "5m", "--style", "compact",
                         "--predicate", 'process == "XcodeApp"'), log="simulator-app.log", timeout=20)
        raise
    finally:
        if build_started:
            cleanup_command(stop, log="stop.log")
        if actions_log.exists() and "Installing XcodeApp" in actions_log.read_text().splitlines():
            # Uninstall also terminates the app. Its unique ID belongs only to this run.
            cleanup_command((*simctl, "uninstall", device, bundle), log="uninstall.log")
        if boot_requested:
            cleanup_command((*simctl, "shutdown", device), log="shutdown.log")
        for log in watcher_logs.glob("*.log"):
            shutil.copy2(log, logs / "watcher.log")
        if cleanup_errors:
            message = "\n".join(cleanup_errors)
            (logs / "cleanup-errors.log").write_text(f"{message}\n")
            if sys.exc_info()[0] is None:
                raise SmokeFailure(f"Cleanup failed: {message}")


def main():
    results = Path(os.environ.get("EMBER_RESULTS_DIR", ROOT / ".ci-results")).resolve() / "simulator-smoke"
    results.mkdir(parents=True, exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix="run-", dir=results))
    print(f"Simulator smoke artifacts at {logs}", flush=True)
    cache = Path(os.environ.get("EMBER_SMOKE_BUILD_DIR", ROOT / ".build/simulator-smoke")).resolve()
    (cache / "module-cache").mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("CLANG_MODULE_CACHE_PATH", str(cache / "module-cache"))
    os.environ.setdefault("SWIFTPM_MODULECACHE_OVERRIDE", str(cache / "module-cache"))
    if not os.environ.get("DEVELOPER_DIR"):
        os.environ["DEVELOPER_DIR"] = run((ROOT / "scripts/select-xcode.sh",),
                                            # Probes every installed Xcode.
                                            timeout=300).strip()
    with tempfile.TemporaryDirectory(prefix="project-", dir=cache) as directory:
        smoke(Path(directory), cache, logs)


def interrupted(_signal, _frame):
    raise KeyboardInterrupt


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (SmokeFailure, OSError, KeyboardInterrupt) as error:
        sys.exit(f"Simulator smoke test failed: {error or 'interrupted'}")
