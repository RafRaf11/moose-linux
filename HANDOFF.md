# Handoff: get the 3DMakerPro Moose Lite scanning on Ubuntu

**For a Claude Code instance running locally on the user's Ubuntu machine, with
the scanner physically attached.**

This file is self-contained — you don't need the earlier conversation. It was
written in a sandbox VM with **no USB passthrough, no `/dev/video*`, no flatpak
and no wine**, so nothing below has been run against the hardware. You have the
hardware; that's the whole point of the handoff.

## 0. Getting this repo

`RafRaf11/moose-linux` is **private**, so a bare `git clone` will fail with
"repository not found" (that's what GitHub says for a private repo you can't
see — it does not mean the URL is wrong).

**Preferred — authenticate as the repo owner.** Check first; the machine may
already be logged in:

```bash
gh auth status
```

If it isn't, start the login yourself and hand the user only the one-time code
and URL to enter in their browser — don't ask them to run the command:

```bash
gh auth login --web --git-protocol https --hostname github.com
```

Then:

```bash
gh repo clone RafRaf11/moose-linux
cd moose-linux && cat CLAUDE.md
```

**Fallback — the git bundle, no credentials needed.** The user was sent
`moose-linux.bundle`, a complete clone of the repo including history. If it's
in `~/Downloads`:

```bash
git clone ~/Downloads/moose-linux.bundle moose-linux
cd moose-linux
git remote set-url origin https://github.com/RafRaf11/moose-linux.git
cat CLAUDE.md
```

That gives you the full working tree immediately. You'll still need `gh auth
login` before you can **push** anything back.

**Last resort:** everything you strictly need to proceed is in this file. The
repo adds the four scripts, which you could rewrite from the descriptions in
§5 — but ask the user for access before spending time on that.

---

## 1. The task

The user owns a **3DMakerPro Moose Lite** 3D scanner. Its software, **JMStudio**,
ships for Windows and macOS only. They want to use the scanner from Ubuntu.
They originally asked for JMStudio to be reverse engineered.

## 2. What was established, and why the plan is what it is

**Reverse engineering JMStudio from scratch is the wrong move.** Two findings:

**(a) It's already been done, against the user's exact build.** Creality's
CR-Scan Lizard is a rebadged scanner running the same 3DMakerPro JMStudio.
[poita66](https://github.com/poita66) traced its USB protocol with `usbmon` and
Ghidra against **JM Studio 2.6.10.0192**, and packaged a patched Wine that runs
the real JMStudio on Linux:

- [`poita66/jmstudio-flatpak`](https://github.com/poita66/jmstudio-flatpak) —
  Wine 11.20 + 15 patches, as a Flatpak. Tested on a Lizard with JM Studio
  2.6.17.0237 on Fedora 43: connect, preview, brightness, both SLAM modes,
  scanning and texture mapping all work.
- [`NOTES.md`](https://github.com/poita66/jmstudio-flatpak/blob/main/NOTES.md) —
  the protocol write-up. **Read this before anything device-level.**
- `tools/` in that repo — native V4L2 capture and `usbmon` loggers.

The user's `C:\Program Files (x86)\JMStudio\version.ini` says
`ProductVersion=2.6.10.0192`, `UpdateVersion=2.6.16.0235`, `src_channel=Jimuyida`
— **the same build poita66 reverse engineered.**

The three `.exe` files from that folder (`Launch.exe`, `AutoUpdate.exe`,
`uninst.exe`) were examined: all NSIS wrapper stubs signed by "3D MAKERPRO
LIMITED", containing an icon, three dialogs and a compressed blob each. No
device code, no USB IDs, no protocol. The real code is in `JMDeviceCore.dll`,
`HCamera_x64.dll` and `SonixCamera.dll`, which weren't available — and aren't
needed.

**(b) A native pipeline has a hard blocker that isn't in the binaries.**
JMStudio does **not** compute the scanner's calibration and does **not** read it
off the device. It reads the serial from the camera's flash, sends it to
3DMakerPro's server, and **downloads a per-unit calibration file**
(`calib_<serial>.txt`, 6780 bytes — image size, then three rows of 15 floats
that look like pinhole intrinsics plus distortion, one per camera and one for
the projector, then a 136-entry table). It writes it to `download/` and copies
it to `calib.txt` in the install directory.

So without that file there's no metric geometry, and no amount of disassembly
produces it — it's a factory measurement of this specific unit, held on
someone else's server. **Don't promise the user a native point cloud without
saying this.**

## 3. How the hardware actually works

From upstream's `NOTES.md`, confirmed on the wire with `usbmon`:

- The scanner is **two UVC 1.0 cameras behind a `1a40:0101` Terminus hub** inside
  its own body. No vendor protocol, no custom driver, no serial side channel.
- **Camera A** is geometry. The structured-light projector is lit **whenever
  Camera A streams — no host command turns it on.** It projects a dense *fixed*
  line pattern, not a phase-stepped sequence (frame-to-frame difference is flat
  at ~2.7 grey levels, i.e. noise).
- **Camera B** is texture, has a different spectral filter, and never sees the
  pattern. Added in Texture SLAM mode.
- Both stream **MJPEG 1280×720 at 10 fps**, negotiated with ordinary UVC
  PROBE/COMMIT.
- The brightness slider (1–9) is just a table of **exposure and gain** written
  as standard UVC controls (CT `EXPOSURE_TIME_ABSOLUTE`, PU `GAIN`).
- **Starting a scan sends no USB traffic at all.** Recording is host-side
  processing of frames already streaming.
- The serial is read through a UVC **extension unit** tunnel (flash read at
  `0xFE00`) and JMStudio accepts it only if it starts with `JM` or `CR`.

Upshot: streaming this scanner natively on Linux needs **nothing but V4L2**.

## 4. USB identities

A **Moose** on Ubuntu reports ([EndeavourOS thread](https://forum.endeavouros.com/t/3d-scanner-sorftware-for-3dmakerpro-moose-3d-scanner/77272)):

| | VID:PID | Product | Serial |
|---|---|---|---|
| Hub | `1a40:0101` | USB 2.0 Hub (Terminus) | — |
| Camera A | `0c45:636a` | KYT Camera A | `JMM4003238` |
| Camera B | `0c45:636b` | KYT Camera B | same |

Both bound to `uvcvideo` and their streams showed up in OBS. `0c45` is
Microdia/Sonix — consistent with `SonixCamera.dll`. The Lizard's are
`bcdc:000a` / `bcdc:000b`, serial `CRSL…`.

⚠️ **That's a Moose, not a Moose Lite.** The Lite's own IDs are unconfirmed.
Nobody in that thread got past seeing camera streams. **Your first job is to
find out what the user's unit reports.**

## 5. Do this, in order

### Step 1 — find out what's actually attached

```bash
./tools/probe-scanner.sh        # scanner plugged in; read-only, safe
```

It matches on the `JM`/`CR` serial prefix as well as the known IDs, so it finds
the scanner even with unknown PIDs. It prints USB identity, bus topology,
autosuspend state, `/dev/video*` nodes, formats, controls and UVC units. If it
finds nothing it falls back to a full `lsusb`/`lsusb -t` dump — then compare
with the scanner unplugged.

**Record the real VID:PIDs.** If they differ from `0c45:636a`/`636b`, update
`udev/99-3dmakerpro-scanner.rules`, the `DEFAULT_PID_*` constants in
`tools/moose-capture.py`, and the tables in `README.md` and `CLAUDE.md`.

### Step 2 — host setup

```bash
./setup-host.sh --dry-run       # read it first
./setup-host.sh
```

Installs the udev rule, `usbutils`, `v4l-utils`, `flatpak` and the flathub
remote. It auto-detects an attached scanner whose IDs the shipped rule doesn't
cover and appends a rule for it. Needs `sudo` for the rule and the packages;
the flatpak install is `--user`.

### Step 3 — prove the hardware works natively, before involving Wine

```bash
./fetch-upstream.sh
./tools/moose-capture.py out/scan1 --mode texture --seconds 10
```

Writes `A/*.jpg`, `B/*.jpg`, `frames.csv` (driver `CLOCK_MONOTONIC` timestamps —
the cameras free-run and pair by nearest timestamp, skew drifted 22–78 ms over
50 frames upstream) and `meta.json`.

**Look at the JPEGs.** Camera A should show the projected line pattern on the
object; Camera B should show plain texture and no pattern. That confirms the
projector fires and both cameras stream, with no Windows code anywhere. This
step is what separates "the cameras work" from "Wine is in the way" later.

`tools/moose-capture.py` is a shim: it imports upstream's `lizard_capture.py`
by path and overrides its `VID`/`PIDS` module globals (verified to be read at
call time in `find_capture_node` and `main`). `--show-ids` prints what it would
use; `--vid/--pid-a/--pid-b` override.

⚠️ The brightness→(exposure, gain) table in `lizard_capture.py` was read out of
the **Lizard's** `JMDeviceCore.dll` at `0x18001e4a0`/`0x18001e590`. Each model
has its own. If the Moose Lite's images are badly over- or under-exposed, that's
why — the table needs deriving for this model, or just drive exposure/gain
directly.

### Step 4 — run the real JMStudio

Download `JMStudioSetup-*.exe` from
<https://forum.jimumeta.com/home/help/download.html> into `~/Downloads`, then:

```bash
gh release download --repo poita66/jmstudio-flatpak --pattern '*.flatpak'
gh attestation verify jmstudio-*.flatpak --repo poita66/jmstudio-flatpak
flatpak install --user jmstudio-*.flatpak
flatpak run io.github.poita66.jmstudio
```

**Do the attestation check** — it ties the bundle's sha256 to the build
workflow and tagged commit, rather than trusting a stranger's release binary.
The Wine source is checkable too: upstream pins `wine-11.20.tar.xz` by sha256
(signed by Alexandre Julliard, key `DA23579A74D4AD9AF9D3F945CEFAC8EAAF17519D`)
and the only delta is 15 readable patches in `patches/wine/`.

First launch runs the Windows installer inside its own Wine prefix at
`~/.var/app/io.github.poita66.jmstudio/data/prefix` — click through, keep the
default install location. Deleting that folder starts over.

### Step 5 — if JMStudio doesn't see the scanner

```bash
flatpak run --env=WINEDEBUG=err+all,warn+qcap \
    --env=LIBV4L2_LOG_FILENAME=$HOME/.var/app/io.github.poita66.jmstudio/data/libv4l2.log \
    io.github.poita66.jmstudio 2> jmstudio-wine.log
```

JMStudio's own logs (millisecond timestamps, records UI clicks and mode changes):

```
~/.var/app/io.github.poita66.jmstudio/data/prefix/drive_c/users/$USER/AppData/Roaming/Jimuyida/JMStudio/log/
```

The patches that matter for device detection are `0007`/`0008` (USB VID/PID in
capture device names, as on Windows — this is how JMStudio recognises the
scanner) and `0004`–`0006`/`0010`–`0011` (qcap `IAMCameraControl`, `VideoProcAmp`,
`IKsControl` XU passthrough). If the Moose Lite is rejected where the Lizard is
accepted, suspect the device-name format in `0008` first.

If it turns out JMStudio drives this model through **libusb** (`wineusb0.sys`,
patches `0009`/`0014`) rather than V4L2, uncomment the `TAG+="uaccess"` lines in
`udev/99-3dmakerpro-scanner.rules` so the raw USB device is reachable.

## 5a. Already established on the hardware (2026-11-12)

A local session ran steps 1–3. Two results change what follows.

**The XU tunnel doesn't exist on this model.** `read_serial` → `ENOENT`; the
Lizard's flash-at-`0xFE00` path is absent. `0c45` is Sonix, so this unit
presumably uses the `SonixCamera.dll` path (`SonixCam_SerialFlashRead`, flash
`0x1F100`). Use `--no-serial` for native capture; the serial is in sysfs.

This matters for step 4 — **no serial means no calibration download, which is
the entire scan.** Before concluding the Wine patches can't help: `0010` is a
*generic* UVC extension-unit passthrough, and `ENOENT` means the unit/selector
you asked for is absent, not that XU is unsupported. Enumerate what this device
actually exposes:

```bash
sudo lsusb -v -d 0c45:636a | grep -iA6 'extension\|guidExtension\|bUnitID'
```

If there's an XU with a different `bUnitID`/GUID, patch `0010` still carries it.
If the Sonix path is vendor-USB rather than UVC, `wineusb0.sys` (`0009`/`0014`)
is the relevant one, and the `TAG+="uaccess"` udev lines need uncommenting.

**~85% of frames have no JPEG EOI.** Every frame has an SOI, `lost_intervals`
is clean, and **no frame has `V4L2_BUF_FLAG_ERROR`** — so this is *not* the
`-EPROTO` packet loss in §6. Upstream's script discards them → ~1–2 fps of 10.
Buffer starvation (NBUFS 4/8/16) and inter-camera contention (geometry mode
alone is as bad) are both ruled out.

Work the cheap hypothesis first, in this order:

1. **Append `\xff\xd9` to a rejected frame and decode it.** Complete, correct
   image → the camera just omits EOI, and the fix is one line in the script's
   validity check. Grey or missing bottom → real truncation, go to 2. This one
   test splits the whole problem and costs a minute.
2. `v4l2-ctl -d /dev/videoN --get-fmt-video` — if `sizeimage` is smaller than a
   real 1280×720 MJPEG frame, the buffer is the limit (the `dwMaxVideoFrameSize`
   theory). The Lizard negotiated 1,843,200.
3. `dmesg | grep -i uvcvideo` while streaming — look for "No fast enough alt
   setting for requested bandwidth", dropped payloads, or overflow messages.
4. Capture independently of the script:
   `v4l2-ctl -d /dev/videoN --set-fmt-video=width=1280,height=720,pixelformat=MJPG --stream-mmap --stream-count=20 --stream-to=/tmp/x.mjpg`.
   Same short frames → not the script. Also compare frame byte sizes: real
   truncation is erratic and small, a missing EOI is not.

## 6. Two failure modes that will otherwise waste your time

**Grey stripes across the image.** Not a software bug. USB packets are lost on
the way to the host; each lost packet removes one or more MJPEG restart
intervals (DRI is 80 MCUs = one 8 px row at 1280×720), and the decoder paints
the missing rows grey. Upstream measured a port behind a Genesys Logic
`05e3:0610` hub dropping ~100 of 50,000 packets in 6 s and flagging 47 of 62
frames; the same capture on a direct root-port was **0 of 122 frames flagged**.
**Fix: plug the scanner straight into the machine, not a hub or dock.**

**First connect after idle fails, retry works.** JMStudio gives up ~500 ms
after asking for the first frame. Open-to-first-frame is 514–537 ms from USB
autosuspend, ~365 ms warm, 391–395 ms with autosuspend off. The udev rule in
step 2 pins `power/control=on` and removes the race. A Flatpak can't set this
itself — it has to be a host udev rule.

## 7. If the user wants a genuinely native pipeline

Be straight with them about scope: it means the structured-light decode and the
SLAM tracking, written from scratch, *and* sourcing calibration from a working
JMStudio install (`calib.txt` in the install dir, or `download/calib_<serial>.txt`).
Steps 1–4 are the prerequisite anyway — you need a working JMStudio to get the
calibration file at all.

Open questions upstream never resolved, all relevant:

- What the 136-entry table in `calib.txt` means, and the fields beyond image size.
- Whether the projector also runs when no camera is streaming.
- Why Camera A sometimes doesn't get a gain `SET_CUR` at stream start.
- Whether this model answers the XU tunnel (flash `0xFE00`, prefix `JM`/`CR`) or
  the `SonixCamera.dll` path (`SonixCam_SerialFlashRead`, flash `0x1F100`).
  Given `0c45` is Sonix, the Lite may well use the Sonix path — the Lizard used
  the XU one.

## 8. Ground rules

- `tools/probe-scanner.sh` is read-only and must stay that way — it's what gets
  run first, blind.
- udev rules match `idVendor` **and** `idProduct`. `0c45` is shared by a great
  many webcams; a vendor-only rule would pin unrelated cameras out of
  autosuspend. Don't loosen it.
- Don't vendor upstream's code. `fetch-upstream.sh` clones it into `vendor/`
  (gitignored) so it keeps its own history and licence.
- JMStudio is proprietary and isn't redistributed. This is interoperability
  work — making hardware the user owns run on the OS they choose.
- Update `CLAUDE.md` as findings land, especially the real USB IDs and anything
  that turns out to differ from the Lizard.
