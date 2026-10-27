"""Select an installed, available iPhone simulator instead of hardcoding a model."""
import json
import re
import subprocess


def choose_device(devices):
    candidates = []
    for runtime, entries in devices.items():
        match = re.search(r"\.iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
        if not match or int(match[1]) < 16:
            continue
        version = tuple(int(p or 0) for p in match.groups())
        for device in entries:
            if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
                candidates.append((version, device["name"], device["udid"]))
    if not candidates:
        raise RuntimeError("No available iPhone simulator with iOS 16 or later. Install an iOS runtime in Xcode.")
    return sorted(candidates)[-1][2]


if __name__ == "__main__":
    result = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "--json"],
                            check=True, capture_output=True, text=True)
    print(choose_device(json.loads(result.stdout)["devices"]))
