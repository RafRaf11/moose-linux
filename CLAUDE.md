# Notes for Claude

Goal: drive a **3DMakerPro Moose Lite** 3D scanner from Ubuntu instead of
JMStudio on Windows.

## The decision this project rests on

Don't reverse engineer JMStudio. Two findings settle it, both in the README:

1. [`poita66/jmstudio-flatpak`](https://github.com/poita66/jmstudio-flatpak)
   already runs the real JMStudio on Linux under a patched Wine, reverse
   engineered against **JM Studio 2.6.10.0192 — the same build the user has**.
   Its `NOTES.md` is the protocol reference; read it before touching anything
   device-level.
2. The per-device calibration is **downloaded from 3DMakerPro's server by
   serial number**, not computed and not stored on the scanner. So no amount of
   disassembly yields metric geometry for a given unit. This is the hard limit
   on any native reimplementation.

If the user asks for a native point-cloud pipeline anyway, be straight that it
means reimplementing structured-light decode plus SLAM *and* still sourcing
calibration from a working JMStudio install.

## Hardware facts

Two UVC 1.0 cameras behind a `1a40:0101` Terminus hub inside the scanner.
Camera A is geometry and the projector is lit whenever it streams (no host
command). Camera B is texture and never sees the pattern. Both MJPEG 1280×720
at 10 fps. Starting a scan sends **no** USB traffic.

Moose IDs (from an EndeavourOS thread, **not yet confirmed on the user's Lite**):
`0c45:636a` KYT Camera A, `0c45:636b` KYT Camera B, serial `JMM…`.
The Lizard's are `bcdc:000a` / `bcdc:000b`, serial `CRSL…`.

## Confirmed on the hardware (2026-11-12, local session)

- **The XU tunnel does not exist on this model.** `read_serial` returns `ENOENT`
  on the extension-unit query; the Lizard's flash-at-`0xFE00` path is absent.
  Consistent with `0c45` being Sonix: this unit uses the `SonixCamera.dll`
  path (`SonixCam_SerialFlashRead`, flash `0x1F100`), not the XU one. Workaround
  for native capture: `--no-serial`; the serial is in sysfs anyway.
  - Open consequence for Step 4/5: if JMStudio reads the serial through the XU
    under Wine it will fail — and **no serial means no calibration download**,
    which is the whole scan. But don't write off patches `0010`/`0011`: `0010` is
    *generic* XU passthrough, so it still carries whatever unit this device does
    expose. Enumerate the real units before concluding
    (`sudo lsusb -v -d 0c45:636a | grep -A4 -i extension`, note `bUnitID` and
    `guidExtensionCode`). `ENOENT` means *that* unit/selector is absent, not
    that XU is unsupported. If the Sonix path turns out to be vendor-USB rather
    than UVC, `wineusb0.sys` (`0009`/`0014`) is the relevant patch instead.
- **~85% of frames arrive without a JPEG EOI marker.** Every frame has an SOI,
  `lost_intervals` is clean, and **no frame carries `V4L2_BUF_FLAG_ERROR`** —
  so this is *not* the Lizard's `-EPROTO` packet loss. Upstream's script
  discards them, leaving ~1–2 fps of 10. Ruled out: buffer starvation (same at
  NBUFS 4/8/16) and inter-camera contention (single-camera geometry mode is as
  bad).
  - **Test the cheap hypothesis first:** append `\xff\xd9` to a rejected frame
    and decode it. If it renders a complete, correct image, the camera simply
    omits EOI and the fix is one line in the capture script's validity check —
    not a bandwidth problem. If the bottom is grey/missing, it is real
    truncation. A known Logitech case has exactly this shape, except that
    device sets `UVC_STREAM_ERR`; this one doesn't, which argues for "complete
    but unterminated".

## Open / unverified

- The Moose **Lite**'s own VID:PIDs. `tools/probe-scanner.sh` answers this; it
  matches on the `JM`/`CR` serial prefix as well as the known IDs, so it finds
  a scanner with unknown PIDs. **Nothing in this repo has been run against the
  hardware yet.**
- Whether the brightness→(exposure, gain) table in upstream's `lizard_capture.py`
  is right for a Moose Lite. It was read out of the Lizard's `JMDeviceCore.dll`;
  each model has its own table.
- Whether JMStudio drives this model through V4L2 (like the Lizard) or through
  libusb/`wineusb0.sys`. If the latter, uncomment the `TAG+="uaccess"` rules in
  `udev/99-3dmakerpro-scanner.rules`.

## Conventions

- `udev/*.rules` must match `idVendor` **and** `idProduct`. `0c45` is
  Microdia/Sonix, shared with many webcams; a vendor-only rule would pin
  unrelated cameras out of autosuspend.
- Don't vendor upstream's code. `fetch-upstream.sh` clones it into `vendor/`
  (gitignored) so it keeps its own history and licence; `tools/moose-capture.py`
  is a shim that imports it by path and overrides `VID`/`PIDS`.
- `tools/probe-scanner.sh` is read-only and must stay that way — it's the thing
  the user runs first, blind.

## Environment caveat

The Claude Code sandbox this was built in is a QEMU VM: no USB passthrough, no
`/dev/video*`, no flatpak, no wine. Scripts were syntax-checked and run as far
as they go without hardware; executing upstream's capture script was blocked by
the sandbox classifier. Everything device-facing is unverified by definition
and has to be run on the user's own desktop.
