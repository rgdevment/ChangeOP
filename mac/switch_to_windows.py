#!/usr/bin/env python3
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

# MCCS input codes: 0x0F DP1, 0x10 DP2, 0x11 HDMI1, 0x12 HDMI2 (some monitors use others; check with `m1ddc get input`)
MONITOR_INPUT = 0x10
# Easy-Switch channel shown on the keyboard/mouse (1..3)
HOST_CHANNEL = 1

LOGITECH_VID = 0x046D
LONG_REPORT = 0x11
LONG_REPORT_LENGTH = 20
SOFTWARE_ID = 0x0A
CHANGE_HOST_FEATURE = 0x1814
LONG_ERROR = 0xFF
SHORT_ERROR = 0x8F
# Idle keyboards answer slowly from power saving; empty slots answer at once with an error.
REPLY_TIMEOUT_MS = 2000
APP_PATH = Path.home() / "Desktop" / "Cambiar a Windows.app"
VENV_PYTHON = Path(__file__).resolve().parent / ".venv" / "bin" / "python3"


def switch_monitor(input_code):
    subprocess.run(["m1ddc", "set", "input", str(input_code)], check=False)


def send(device, index, feature, function, *args):
    report = [LONG_REPORT, index, feature, (function << 4) | SOFTWARE_ID, *args]
    device.write(report + [0] * (LONG_REPORT_LENGTH - len(report)))


def request(device, index, feature, function, *args):
    """Returns (reply, error_code); both are None on timeout."""
    send(device, index, feature, function, *args)
    function_id = (function << 4) | SOFTWARE_ID
    while True:
        reply = device.read(LONG_REPORT_LENGTH, REPLY_TIMEOUT_MS)
        if not reply:
            return None, None
        if len(reply) < 6 or reply[1] != index:
            continue
        if reply[2] == feature and reply[3] == function_id:
            return reply, None
        if reply[2] in (LONG_ERROR, SHORT_ERROR) and reply[3] == feature and reply[4] == function_id:
            return None, reply[5]


def change_host_index(device, index):
    reply, _ = request(device, index, 0x00, 0, CHANGE_HOST_FEATURE >> 8, CHANGE_HOST_FEATURE & 0xFF)
    return reply[4] if reply else 0


def switch_host(device, host_index):
    # Every device is found before any switches, so a device leaving the receiver cannot disturb the next query.
    features = {index: change_host_index(device, index) for index in range(1, 7)}
    features = {index: feature for index, feature in features.items() if feature}
    for index, feature in features.items():
        send(device, index, feature, 1, host_index)
    return len(features)


def find_brew():
    for brew in (shutil.which("brew"), "/opt/homebrew/bin/brew", "/usr/local/bin/brew"):
        if brew and Path(brew).exists():
            return brew
    sys.exit("Homebrew not found: install it from https://brew.sh and run --install again")


def install_dependencies():
    if not shutil.which("m1ddc", path=f"/opt/homebrew/bin:/usr/local/bin:{os.environ.get('PATH', '')}"):
        subprocess.run([find_brew(), "install", "m1ddc"], check=True)
    # A private venv avoids pip refusing to touch Homebrew's externally managed Python.
    if not VENV_PYTHON.exists():
        subprocess.run([sys.executable, "-m", "venv", str(VENV_PYTHON.parent.parent)], check=True)
    subprocess.run([str(VENV_PYTHON), "-m", "pip", "install", "--quiet", "hidapi"], check=True)


def install_app():
    # Apps launched from Finder get a minimal PATH, so Homebrew (m1ddc) must be added explicitly.
    command = "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH {} {}".format(
        shlex.quote(str(VENV_PYTHON)), shlex.quote(str(Path(__file__).resolve())))
    applescript = 'do shell script "{}"'.format(command.replace("\\", "\\\\").replace('"', '\\"'))
    subprocess.run(["osacompile", "-o", str(APP_PATH), "-e", applescript], check=True)
    print(f"App created: {APP_PATH}")


def switch_logitech_devices(host_index):
    import hid

    switched = 0
    # Receivers expose HID++ long reports on the vendor collection FF00:0002; on macOS it also delivers short errors.
    for info in hid.enumerate(LOGITECH_VID, 0):
        if info["usage_page"] != 0xFF00 or info["usage"] != 0x0002:
            continue
        device = hid.device()
        device.open_path(info["path"])
        try:
            switched += switch_host(device, host_index)
        finally:
            device.close()
    return switched


def main():
    if "--install" in sys.argv[1:]:
        install_dependencies()
        install_app()
        return 0
    switch_monitor(MONITOR_INPUT)
    devices = switch_logitech_devices(HOST_CHANNEL - 1)
    print(f"Logitech devices switched: {devices}")
    return 0 if devices else 1


if __name__ == "__main__":
    sys.exit(main())
