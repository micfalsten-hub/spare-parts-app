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
    result = subprocess.run(["adb", *args], check=False,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=timeout)
    if check and result.returncode != 0:
        print(f"adb {args}: exit {result.returncode}", flush=True)
        print(result.stdout.decode(errors="replace"), flush=True)
        print(result.stderr.decode(errors="replace"), flush=True)
        raise subprocess.CalledProcessError(result.returncode, result.args)
    return result


def diagnostics(label):
    try:
        ARTIFACTS.joinpath(f"{label}.png").write_bytes(
            adb("exec-out", "screencap", "-p", check=False).stdout)
    except Exception:
        pass
    try:
        log = adb("logcat", "-d", check=False).stdout
        ARTIFACTS.joinpath(f"{label}-logcat.txt").write_bytes(log)
        relevant = [line for line in log.decode(errors="replace").splitlines()
                    if any(marker in line.lower() for marker in
                           ("lowmemorykiller", "outofmemory", "killed", "flutter", "sqflite", "fatal exception"))]
        print("\n".join(relevant[-60:]), flush=True)
        print(adb("shell", "cat", "/proc/meminfo", check=False).stdout.decode(errors="replace"), flush=True)
    except Exception:
        pass


def require_home(label):
    for attempt in range(15):
        remote_xml = f"/sdcard/daftar-{label}-{attempt}.xml"
        adb("shell", "rm", "-f", remote_xml)
        dumped = adb("shell", "uiautomator", "dump", remote_xml, check=False)
        if dumped.returncode != 0:
            time.sleep(2)
            continue
        read = adb("shell", "cat", remote_xml, check=False)
        if read.returncode != 0:
            time.sleep(2)
            continue
        latest = read.stdout
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


def retry_adb(*args):
    for attempt in range(6):
        result = adb(*args, check=False)
        if result.returncode == 0:
            return result
        print(f"Retrying {args}: exit {result.returncode}", flush=True)
        print(result.stderr.decode(errors="replace"), flush=True)
        time.sleep(5)
    raise AssertionError(f"Emulator preparation failed: {args}")

def require_offline():
    for attempt in range(10):
        plane = retry_adb("shell", "settings", "get", "global", "airplane_mode_on").stdout.decode().strip()
        wifi = retry_adb("shell", "dumpsys", "wifi").stdout.decode(errors="replace")
        connectivity = retry_adb("shell", "dumpsys", "connectivity").stdout.decode(errors="replace")
        if plane == "1" and "Wi-Fi is disabled" in wifi and "Active default network: none" in connectivity:
            ARTIFACTS.joinpath("offline-connectivity.txt").write_text(wifi + "\n" + connectivity)
            print("Verified emulator Wi-Fi disabled and no active default network", flush=True)
            return
        time.sleep(3)
    raise AssertionError("Emulator still has an active network")


try:
    adb("install", "-r", str(APK))
    time.sleep(30)
    retry_adb("root")
    retry_adb("wait-for-device")
    identity = retry_adb("shell", "id").stdout.decode()
    assert "uid=0" in identity, identity
    retry_adb("shell", "settings", "put", "global",
              "airplane_mode_radios", "cell,bluetooth,wifi,nfc,wimax")
    retry_adb("shell", "settings", "put", "global", "airplane_mode_on", "1")
    retry_adb("shell", "am", "broadcast", "-a",
              "android.intent.action.AIRPLANE_MODE", "--ez", "state", "true")
    retry_adb("shell", "svc", "wifi", "disable")
    retry_adb("shell", "svc", "data", "disable")
    require_offline()
    adb("logcat", "-c")
    for label in ("first-launch", "relaunch"):
        require_offline()
        adb("shell", "am", "force-stop", PACKAGE)
        adb("shell", "am", "start", "-W",
            "-n", f"{PACKAGE}/.MainActivity")
        require_home(label)
finally:
    diagnostics("final")
