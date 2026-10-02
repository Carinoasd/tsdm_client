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
        subprocess.run(["adb", "exec-out", "screencap", "-p"], stdout=image, check=True)


def instrument(class_name):
    result = adb("shell", "am", "instrument", "-w", "-r", "-e", "class",
                 f"kzs.th000.tsdm_client.{class_name}", RUNNER, timeout=480)
    (OUT / f"{class_name}.txt").write_text(result, encoding="utf-8")
    print(result, flush=True)
    if not re.search(r"OK \(1 test\)", result) or "FAILURES" in result:
        raise RuntimeError(f"Real-device instrumentation failed: {class_name}")


def installed_code():
    details = adb("shell", "dumpsys", "package", PACKAGE)
    matches = re.findall(r"versionCode=(\d+)", details)
    return int(matches[0]) if matches else None


try:
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
    instrument("InteractiveHtmlDeviceTest")
    instrument("UpdateInstallerDeviceTest")
    # Instrumentation must finish before updating its host package, which Android kills.
    adb("shell", "uiautomator", "dump", "/sdcard/installer.xml")
    xml = adb("shell", "cat", "/sdcard/installer.xml")
    (OUT / "installer-final.xml").write_text(xml, encoding="utf-8")
    root = ET.fromstring(xml)
    actions = [node for node in root.iter("node")
               if node.get("text", "").upper() in {"INSTALL", "UPDATE"}
               and node.get("enabled") == "true"
               and "packageinstaller" in node.get("package", "")]
    assert len(actions) == 1, "Expected one visible Android system Install/Update confirmation"
    bounds = [int(x) for x in re.findall(r"\d+", actions[0].get("bounds", ""))]
    assert len(bounds) == 4
    screenshot("system-installer-before-confirm")
    adb("shell", "input", "tap", str((bounds[0] + bounds[2]) // 2), str((bounds[1] + bounds[3]) // 2))
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline and installed_code() != 1209:
        time.sleep(1)
    assert installed_code() == 1209, "System installation did not upgrade the package to official versionCode1209"
    screenshot("system-install-complete")
    (OUT / "result.json").write_text(json.dumps({
        "html_instrumentation": "passed", "update_instrumentation": "passed",
        "baseline_versionCode": 1199, "installed_versionCode": installed_code(),
        "real_forum_submissions": 0, "physical_device": False,
    }, indent=2), encoding="utf-8")
finally:
    subprocess.run(["adb", "pull", f"/sdcard/Android/data/{PACKAGE}/files/emulator-evidence", str(OUT)], check=False)
    (OUT / "logcat.txt").write_text(adb("logcat", "-d", "-v", "threadtime"), encoding="utf-8")
    screenshot("final-screen")
