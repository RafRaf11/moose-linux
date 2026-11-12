#!/usr/bin/env python3
"""Capture raw frames from the scanner's two cameras, natively, with no Wine.

This is a thin shim over upstream's ``lizard_capture.py``, which does the real
work: raw V4L2 ioctls, MJPEG 1280x720 at 10 fps, manual exposure and gain, and
a CSV of driver timestamps so the two cameras' frames can be paired. The only
thing it gets wrong for a 3DMakerPro scanner is which USB IDs to look for, so
that is all this overrides.

    ./tools/moose-capture.py out/scan1 --mode texture --seconds 10

Run ``fetch-upstream.sh`` first to put lizard_capture.py in ./vendor.

What you get is two folders of JPEGs and a frames.csv - the geometry camera's
view of the projected pattern, and the texture camera's plain view. That is the
scanner's raw output, and it is enough to confirm the hardware works on Linux
without Windows anywhere in the picture. It is *not* a point cloud: turning
these frames into geometry needs the per-device calibration and the structured
light decode, neither of which is public. See the README.

Pass --vid/--pid-a/--pid-b if your scanner reports something other than the
Moose's IDs; probe-scanner.sh prints them.
"""

from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

# Moose: 0c45:636a "KYT Camera A", 0c45:636b "KYT Camera B".
# Lizard (upstream's default): bcdc:000a / bcdc:000b.
DEFAULT_VID = "0c45"
DEFAULT_PID_A = "636a"
DEFAULT_PID_B = "636b"

SEARCH = [
    ROOT / "vendor" / "jmstudio-flatpak" / "tools" / "lizard_capture.py",
    ROOT / "vendor" / "lizard_capture.py",
]


def find_upstream(explicit: Path | None) -> Path:
    if explicit:
        if not explicit.is_file():
            sys.exit(f"not a file: {explicit}")
        return explicit
    for candidate in SEARCH:
        if candidate.is_file():
            return candidate
    sys.exit(
        "lizard_capture.py not found. Run ./fetch-upstream.sh to clone it, or\n"
        "pass --upstream /path/to/lizard_capture.py.\n"
        "Looked in:\n  " + "\n  ".join(str(p) for p in SEARCH)
    )


def load(path: Path):
    spec = importlib.util.spec_from_file_location("lizard_capture", path)
    if spec is None or spec.loader is None:
        sys.exit(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    # Keep it out of sys.modules under its own name only long enough to exec.
    sys.modules["lizard_capture"] = module
    spec.loader.exec_module(module)
    return module


def main() -> None:
    # Only our own options are parsed here; everything else is handed through to
    # upstream's parser untouched, so its --mode/--brightness/--seconds and any
    # option it gains later keep working.
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--upstream", type=Path)
    ap.add_argument("--vid", default=DEFAULT_VID)
    ap.add_argument("--pid-a", default=DEFAULT_PID_A)
    ap.add_argument("--pid-b", default=DEFAULT_PID_B)
    ap.add_argument("--show-ids", action="store_true",
                    help="print the IDs that would be used, then exit")
    mine, rest = ap.parse_known_args()

    if mine.show_ids:
        print(f"VID {mine.vid}  CameraA {mine.vid}:{mine.pid_a}  CameraB {mine.vid}:{mine.pid_b}")
        return

    if "-h" in rest or "--help" in rest:
        print(__doc__)
        print("Options passed through to upstream lizard_capture.py:\n")

    upstream = find_upstream(mine.upstream)
    module = load(upstream)

    for name in ("VID", "PIDS"):
        if not hasattr(module, name):
            sys.exit(
                f"{upstream} has no {name}; upstream has changed shape and this "
                "shim needs updating."
            )

    module.VID = mine.vid
    module.PIDS = {"A": mine.pid_a, "B": mine.pid_b}

    sys.argv = [str(upstream), *rest]
    module.main()


if __name__ == "__main__":
    main()
