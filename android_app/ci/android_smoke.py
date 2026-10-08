from pathlib import Path
import subprocess
import time
import xml.etree.ElementTree as ET

PACKAGE = "com.daftar.spare_parts"
APK = Path("build/app/outputs/flutter-apk/app-release.apk")
ARTIFACTS = Path("artifacts")
ARTIFACTS.mkdir(exist_ok=True)
HOME_MARKERS = ("دفتر القطع", "دفترك محفوظ على هذا الهاتف")
ERROR_MARKER = "تعذر فتح الدفتر المحلي"


def adb(*args, check=True, timeout=45):
    return subprocess.run(["adb", *args], check=check,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=timeout)


def diagnostics(label):
    try:
        ARTIFACTS.joinpath(f"{label}.png").write_bytes(
            adb("exec-out", "screencap", "-p", check=False).stdout)
    except Exception:
        pass
    try:
        ARTIFACTS.joinpath(f"{label}-logcat.txt").write_bytes(
            adb("logcat", "-d", check=False).stdout)
    except Exception:
        pass


def require_home(label):
    for _ in range(15):
        adb("shell", "uiautomator", "dump",
            "/sdcard/daftar-smoke.xml", check=False)
        latest = adb("shell", "cat", "/sdcard/daftar-smoke.xml",
                     check=False).stdout
        ARTIFACTS.joinpath(f"{label}.xml").write_bytes(latest)
        try:
            root = ET.fromstring(latest)
            labels = "\n".join(n.get("text", "") + "\n" +
                                n.get("content-desc", "")
                                for n in root.iter("node"))
        except ET.ParseError:
            time.sleep(2)
            continue
        if ERROR_MARKER in labels:
            raise AssertionError("SQLite startup failure screen appeared.")
        if all(marker in labels for marker in HOME_MARKERS):
            diagnostics(label)
            print(f"{label}: release home screen loaded offline", flush=True)
            return
        time.sleep(2)
    raise AssertionError("Release did not reach the successful home screen.")


try:
    adb("install", "-r", str(APK))
    adb("shell", "svc", "wifi", "disable")
    adb("shell", "svc", "data", "disable")
    adb("logcat", "-c")
    for label in ("first-launch", "relaunch"):
        adb("shell", "am", "force-stop", PACKAGE)
        adb("shell", "am", "start", "-W",
            "-n", f"{PACKAGE}/.MainActivity")
        require_home(label)
finally:
    diagnostics("final")
