"""Drive a disposable Android emulator, retaining evidence of actual WebView/APK install.

Only run via android_emulator_smoke.yml. No forum login, forum submissions or
production user data are used. The seeded update metadata points at public v1.30.0;
the production downloader, digest check, signer check and installer remain intact.
"""
import json
import pathlib
import re
import subprocess
import time
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "outputs/android-emulator"
OUT.mkdir(parents=True, exist_ok=True)
PACKAGE = "com.tsdm.tsdm_client"
RUNNER = f"{PACKAGE}.test/androidx.test.runner.AndroidJUnitRunner"


def adb(*args, timeout=60):
    return subprocess.run(["adb", *args], check=True, capture_output=True,
                          text=True, timeout=timeout).stdout


def screenshot(name):
    with (OUT / f"{name}.png").open("wb") as image:
        subprocess.run(["adb", "exec-out", "screencap", "-p"], stdout=image,
                       check=True, timeout=30)


def instrument(class_name):
    print(f"Starting Android instrumentation: {class_name}", flush=True)
    adb("logcat", "-c")
    output = OUT / f"{class_name}.txt"
    failure = None
    # Persist output as it arrives: a runner crash can leave am instrument waiting
    # forever, and subprocess.run's TimeoutExpired would otherwise hide its output.
    with output.open("w", encoding="utf-8") as stream:
        process = subprocess.Popen([
            "adb", "shell", "am", "instrument", "-w", "-r", "-e", "class",
            f"kzs.th000.tsdm_client.{class_name}", RUNNER,
        ], stdout=stream, stderr=subprocess.STDOUT, text=True)
        deadline = time.monotonic() + 480
        try:
            while process.poll() is None:
                time.sleep(5)
                crash = adb("logcat", "-d", "-b", "crash")
                if "FATAL EXCEPTION" in crash and f"Process: {PACKAGE}," in crash:
                    failure = "Android instrumentation host crashed; see crash log"
                    (OUT / f"{class_name}-crash.txt").write_text(crash, encoding="utf-8")
                    break
                if time.monotonic() >= deadline:
                    failure = "Android instrumentation exceeded 480 seconds"
                    break
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
            log = adb("logcat", "-d", "-v", "threadtime")
            (OUT / f"{class_name}-logcat.txt").write_text(log, encoding="utf-8")
    result = output.read_text(encoding="utf-8")
    print(result, flush=True)
    if failure or process.returncode != 0 or not re.search(r"OK \(1 test\)", result) or "FAILURES" in result:
        screenshot(f"{class_name}-failure")
        adb("shell", "am", "force-stop", PACKAGE)
        raise RuntimeError(f"{class_name}: {failure or 'instrumentation failed'}")
    print(f"Passed Android instrumentation: {class_name}", flush=True)


def installed_code():
    details = adb("shell", "dumpsys", "package", PACKAGE)
    matches = re.findall(r"versionCode=(\d+)", details)
    return int(matches[0]) if matches else None


def ui_xml(name):
    adb("shell", "uiautomator", "dump", "/sdcard/emulator-ui.xml")
    xml = adb("shell", "cat", "/sdcard/emulator-ui.xml")
    (OUT / f"{name}.xml").write_text(xml, encoding="utf-8")
    return ET.fromstring(xml)


def tap_node(node):
    bounds = [int(x) for x in re.findall(r"\d+", node.get("bounds", ""))]
    assert len(bounds) == 4
    adb("shell", "input", "tap", str((bounds[0] + bounds[2]) // 2), str((bounds[1] + bounds[3]) // 2))


results = {"physical_device": False, "real_forum_submissions": 0}
failures = []
try:
    print("Inspecting disposable Android emulator and installing test packages", flush=True)
    abi = adb("shell", "getprop", "ro.product.cpu.abilist").strip()
    (OUT / "device.json").write_text(json.dumps({
        "abi": abi, "android": adb("shell", "getprop", "ro.build.version.release").strip(),
        "model": adb("shell", "getprop", "ro.product.model").strip(),
        "webview": adb("shell", "dumpsys", "webviewupdate"),
        "metadata": "Pinned public v1.30.0; real GitHub download and Android installation",
        "entry": "test_driver/android_update_smoke.dart; production UpdatePage and native viewer",
    }, indent=2), encoding="utf-8")
    assert "arm64-v8a" in abi.split(","), f"System image lacks required ARM64 translation: {abi}"
    app = ROOT / "build/app/outputs/flutter-apk/app-release.apk"
    tests = list((ROOT / "build/app/outputs/apk/androidTest/release").glob("*.apk"))
    assert app.is_file() and len(tests) == 1, "Expected universal app and exactly one instrumentation APK"
    adb("install", str(app), timeout=180)
    adb("install", "-t", str(tests[0]), timeout=180)
    assert installed_code() == 1199
    results["baseline_versionCode"] = 1199
    # These paths are independent: retain updater evidence even if HTML fails.
    for test in ("InteractiveHtmlDeviceTest", "UpdateInstallerDeviceTest"):
        try:
            instrument(test)
            results[test] = "passed"
        except Exception as error:
            results[test] = str(error)
            failures.append(str(error))
            print(f"FAILED: {error}", flush=True)
    if results.get("UpdateInstallerDeviceTest") != "passed":
        raise RuntimeError("Update test did not reach installation permission settings")
    # Android kills the target app when REQUEST_INSTALL_PACKAGES changes. The
    # real Settings tap must happen outside the target instrumentation process.
    print("Granting installation permission through the actual Android Settings UI", flush=True)
    root = ui_xml("unknown-source-permission-before")
    toggles = [node for node in root.iter("node")
               if node.get("package") == "com.android.settings"
               and node.get("class") == "android.widget.Switch"
               and node.get("checkable") == "true" and node.get("checked") == "false"]
    assert len(toggles) == 1, "Expected one unchecked per-app installation permission toggle"
    tap_node(toggles[0])
    screenshot("unknown-source-permission-enabled")
    adb("shell", "input", "keyevent", "4")
    instrument("UpdateInstallerResumeDeviceTest")
    results["UpdateInstallerResumeDeviceTest"] = "passed"
    # Instrumentation must finish before updating its host package, which Android kills.
    print("Confirming Android system installation of verified official APK", flush=True)
    root = ui_xml("installer-final")
    actions = [node for node in root.iter("node")
               if node.get("text", "").upper() in {"INSTALL", "UPDATE"}
               and node.get("enabled") == "true"
               and "packageinstaller" in node.get("package", "")]
    assert len(actions) == 1, "Expected one visible Android system Install/Update confirmation"
    screenshot("system-installer-before-confirm")
    tap_node(actions[0])
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline and installed_code() != 1209:
        time.sleep(1)
    assert installed_code() == 1209, "System installation did not upgrade the package to official versionCode1209"
    screenshot("system-install-complete")
    results["installed_versionCode"] = installed_code()
    print("Official update installed: versionCode1209", flush=True)
except Exception as error:
    failures.append(str(error))
finally:
    results["failures"] = failures
    (OUT / "result.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    try:
        subprocess.run(["adb", "pull", "/sdcard/Download/tsdm-emulator-evidence", str(OUT)],
                       check=False, timeout=60)
        (OUT / "logcat.txt").write_text(adb("logcat", "-d", "-v", "threadtime"), encoding="utf-8")
        screenshot("final-screen")
    except (subprocess.SubprocessError, OSError) as error:
        print(f"Evidence collection error: {error}", flush=True)
if failures:
    raise SystemExit("; ".join(failures))
