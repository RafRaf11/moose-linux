# Running a 3DMakerPro scanner on Ubuntu

Notes and tooling for driving a **3DMakerPro Moose Lite** from Linux instead of
from JMStudio on Windows.

The short version: **don't reverse engineer this from scratch.** Someone has
already done the hard part for the exact same software, and the one piece that
is genuinely missing can't be reverse engineered out of the binaries at all,
because it doesn't live there. Both halves of that are explained below.

## What the uploaded files turned out to be

`Launch.exe`, `AutoUpdate.exe` and `uninst.exe` from `C:\Program Files (x86)\JMStudio`
are all NSIS wrapper stubs, code-signed by "3D MAKERPRO LIMITED". They contain
an icon, three dialogs and a compressed blob each — no scanner code, no device
protocol, no USB identifiers. `Launch.exe` is a 29 KB launcher whose only
interesting content is its version resource:

```
ProductName     JMStudio
ProductVersion  2.6.10.0192
LegalCopyright  (C) 2026 jimuyida.com All Rights Reserved.
```

`version.ini` says the same, with `UpdateVersion=2.6.16.0235` and
`src_channel=Jimuyida`.

That version string is the useful part. The code that actually talks to the
scanner is in the DLLs beside these files — `JMDeviceCore.dll`,
`HCamera_x64.dll`, `SonixCamera.dll` — which weren't uploaded. And it turns out
we don't need them.

## Why not reverse engineer it

**1. It's already been done, for this exact software.** Creality's CR-Scan
Lizard is a rebadged scanner that runs the same 3DMakerPro JMStudio. Peter
Rowlands ([poita66](https://github.com/poita66)) traced its USB protocol with
`usbmon` and Ghidra against **JM Studio 2.6.10.0192 — the identical build to
yours** — and packaged a patched Wine that runs the real JMStudio on Linux:

- [`poita66/jmstudio-flatpak`](https://github.com/poita66/jmstudio-flatpak) —
  Wine 11.20 plus 15 patches, as a Flatpak.
- [`NOTES.md`](https://github.com/poita66/jmstudio-flatpak/blob/main/NOTES.md) —
  the wire-protocol write-up: camera setup, the brightness→(exposure, gain)
  tables lifted from `JMDeviceCore.dll`, the UVC extension-unit tunnel, where
  calibration comes from.

Tested on a Lizard with JM Studio 2.6.17.0237: connect, preview, brightness,
both SLAM modes, scanning and texture mapping all work.

**2. The missing piece isn't in the software.** JMStudio doesn't compute your
scanner's calibration and doesn't read it off the device. It reads the serial
number out of the camera's flash, sends it to 3DMakerPro's server, and
**downloads a per-device calibration file** (`calib_<serial>.txt`, 6780 bytes:
image size, then three rows of 15 floats that look like pinhole intrinsics plus
distortion — one per camera and one for the projector — then a 136-entry
table). Without your unit's calibration there is no metric geometry, and no
amount of disassembly produces it: it's a per-unit factory measurement held on
someone else's server.

So a from-scratch native implementation would mean reimplementing the
structured-light decode and the SLAM tracking *and* still phoning home for
calibration. Running the real software under a patched Wine gets you a working
scanner today instead.

## How the scanner actually works

From upstream's `NOTES.md`, confirmed on the wire with `usbmon`:

- The scanner is **two UVC 1.0 cameras behind a `1a40:0101` Terminus hub** in
  its own body. No vendor protocol, no custom driver, no serial side channel.
- **Camera A** is the geometry camera. The structured-light projector is on
  whenever Camera A streams — **no host command turns it on**. It sees a dense
  fixed line pattern, not a phase-stepped sequence.
- **Camera B** is the texture camera, with a different spectral filter, and
  never sees the pattern. It's added in Texture SLAM mode.
- Both stream **MJPEG 1280×720 at 10 fps**, negotiated with ordinary UVC
  PROBE/COMMIT.
- The brightness slider (1–9) is nothing but a table of **exposure and gain**
  values written to the two cameras as standard UVC controls.
- **Starting a scan sends no USB traffic at all.** Recording is purely
  host-side processing of frames that are already streaming.
- The serial number is read through a UVC **extension unit** tunnel — a flash
  read at `0xFE00` — and is accepted only if it starts with `JM` or `CR`.

Which means: streaming the scanner natively on Linux needs nothing but V4L2.
Everything hard is in the reconstruction, not the device.

## Your scanner

A Moose on Ubuntu reports ([EndeavourOS thread](https://forum.endeavouros.com/t/3d-scanner-sorftware-for-3dmakerpro-moose-3d-scanner/77272)):

| | VID:PID | Product | Serial |
|---|---|---|---|
| Hub | `1a40:0101` | USB 2.0 Hub (Terminus) | — |
| Camera A | `0c45:636a` | KYT Camera A | `JMM…` |
| Camera B | `0c45:636b` | KYT Camera B | `JMM…` (same) |

Both bind to `uvcvideo` cleanly and their streams show up in OBS, so the
hardware needs no driver work. `0c45` is Microdia/Sonix — consistent with the
`SonixCamera.dll` in JMStudio, and a different vendor ID from the Lizard's
`bcdc`, which is the only difference that matters for setup.

**Unverified for the Moose *Lite* specifically.** That table is from a Moose,
not a Moose Lite, and nobody in that thread got past seeing camera streams.
`tools/probe-scanner.sh` is how we check your unit — it works from the serial
prefix as well as the known IDs, so it will find the scanner even if the Lite
reports different PIDs.

## Route A — run the real JMStudio (recommended)

```bash
./setup-host.sh          # udev rules, usbutils, v4l-utils, flatpak, flathub
./tools/probe-scanner.sh # with the scanner plugged in
```

Then download `JMStudioSetup-*.exe` from
[3DMakerPro](https://forum.jimumeta.com/home/help/download.html) into
`~/Downloads`, and:

```bash
gh release download --repo poita66/jmstudio-flatpak --pattern '*.flatpak'
gh attestation verify jmstudio-*.flatpak --repo poita66/jmstudio-flatpak
flatpak install --user jmstudio-*.flatpak
flatpak run io.github.poita66.jmstudio
```

The attestation check matters — it ties the bundle's hash to the build workflow
and the tagged commit in that repository, rather than trusting a binary from a
stranger's releases page. The Wine source is checkable too: upstream pins
`wine-11.20.tar.xz` by sha256 and the only delta is the 15 readable patches.

Two things are worth knowing before they bite:

- **Plug the scanner straight into the machine, not a hub or dock.** Packet
  loss on the way to the host costs restart intervals inside the MJPEG frames,
  and the decoder paints the missing rows grey — grey stripes across your scan.
  Upstream measured a port through a Genesys Logic hub dropping ~100 packets in
  6 s and flagging 47 of 62 frames; the same capture on a direct port was
  perfectly clean.
- **The first connect after an idle spell may fail.** JMStudio waits ~500 ms
  for the first frame and waking a suspended camera takes 514–537 ms. The udev
  rule `setup-host.sh` installs pins `power/control=on` and removes the race.

## Route B — native capture, no Wine

```bash
./fetch-upstream.sh
./tools/moose-capture.py out/scan1 --mode texture --seconds 10
```

`tools/moose-capture.py` wraps upstream's `lizard_capture.py` — stdlib-only
Python, raw V4L2 ioctls — and swaps in the Moose's USB IDs. You get `A/*.jpg`,
`B/*.jpg`, `frames.csv` (driver `CLOCK_MONOTONIC` timestamps, because the two
cameras free-run and pair by nearest timestamp) and `meta.json`.

This proves the hardware end to end on Linux with no Windows code anywhere, and
it's the right first test if JMStudio misbehaves — it separates "the cameras
work" from "Wine is in the way".

**It is not a point cloud.** Getting geometry out of those frames needs the
calibration file and the structured-light decode, per the section above. If you
want to go that way, the honest options are to export the calibration from a
working JMStudio install (it writes `calib_<serial>.txt` and copies it to
`calib.txt` in the install directory) and then write the triangulation yourself
against the fixed line pattern. That's a real project, not an afternoon.

Two open questions upstream never answered, both relevant here: what the 136-entry
table in `calib.txt` means, and whether the brightness tables differ per model —
yours are in `JMDeviceCore.dll`, not in the Lizard's, so the exposure/gain
values in upstream's table may be wrong for a Moose Lite.

## What's in here

| Path | |
|---|---|
| `setup-host.sh` | udev rules, packages, flatpak + flathub; `--dry-run`, `--udev-only` |
| `tools/probe-scanner.sh` | read-only survey: USB identity, topology, autosuspend, V4L2 nodes, formats, controls, UVC units |
| `tools/moose-capture.py` | native V4L2 capture via upstream's script, with the Moose's IDs |
| `udev/99-3dmakerpro-scanner.rules` | keeps the two cameras out of USB autosuspend |
| `fetch-upstream.sh` | clones `poita66/jmstudio-flatpak` into `vendor/` |

The udev rule matches on **both** `idVendor` and `idProduct`. `0c45` is shared
by a great many webcams, so a vendor-only rule would pin unrelated cameras
awake; don't loosen it.

## Credit and licensing

Essentially all of the protocol knowledge here is
[poita66](https://github.com/poita66)'s, from
[`jmstudio-flatpak`](https://github.com/poita66/jmstudio-flatpak) (Wine patches
LGPL-2.1-or-later). This repository adds Moose-specific setup and diagnostics
and vendors nothing: `fetch-upstream.sh` clones upstream so it keeps its own
history and licence.

JMStudio is proprietary and is not redistributed here. Reverse engineering for
interoperability — making hardware you own work on an operating system of your
choice — is what all of this is for.
