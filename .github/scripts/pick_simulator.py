"""Pick a simulator UDID from `xcrun simctl list devices available -j` on stdin.

Prefers the named device (argv[1]) on an iOS 27 runtime (the deployment
target), then that device on any iOS runtime (newest first), then any iPhone on the newest iOS runtime.
Prints the chosen runtime and device name to stderr.
"""
import json
import re
import sys

wanted = sys.argv[1] if len(sys.argv) > 1 else "iPhone 17 Pro Max"
devices = json.load(sys.stdin)["devices"]


def version(runtime):
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return (int(match.group(1)), int(match.group(2))) if match else (0, 0)


runtimes = sorted((r for r in devices if "iOS" in r), key=version, reverse=True)
candidates = (
    [(r, d) for r in runtimes if version(r)[0] == 27 for d in devices[r] if d["name"] == wanted]
    + [(r, d) for r in runtimes for d in devices[r] if d["name"] == wanted]
    + [(r, d) for r in runtimes for d in devices[r] if d["name"].startswith("iPhone")]
)
if not candidates:
    sys.exit("No iPhone simulator available")
runtime, device = candidates[0]
print(f"Using {device['name']} on {runtime}", file=sys.stderr)
print(device["udid"])
