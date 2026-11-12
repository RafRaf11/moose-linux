#!/usr/bin/env bash
#
# What is actually plugged in?
#
# Run this with the scanner connected. It prints everything the Linux side of
# the stack already knows about it: USB identity, where it sits on the bus, the
# V4L2 nodes, the formats and controls each camera offers, and the UVC units
# behind which the serial number lives.
#
# Nothing here touches the device beyond reading. Safe to run any time.
#
# The known identities are:
#   Moose          0c45:636a "KYT Camera A", 0c45:636b "KYT Camera B", serial JMM...
#   CR-Scan Lizard bcdc:000a "ICT CameraA",  bcdc:000b "ICT CameraB",  serial CRSL...
# both behind a 1a40:0101 Terminus hub inside the scanner body. If the Moose
# Lite reports something else, this script is how we find out.

set -uo pipefail

KNOWN_VIDS="0c45 bcdc"
SYSUSB=/sys/bus/usb/devices

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

read_attr() { # dir attr -> value or empty
  local f="$1/$2"
  [[ -r $f ]] && tr -d '\0' <"$f" | head -1 || true
}

# ---------------------------------------------------------------- USB survey

say "USB devices that look like a 3D scanner camera"

found=()
for dev in "$SYSUSB"/*; do
  [[ -r $dev/idVendor ]] || continue
  vid=$(read_attr "$dev" idVendor)
  pid=$(read_attr "$dev" idProduct)
  product=$(read_attr "$dev" product)
  manufacturer=$(read_attr "$dev" manufacturer)
  serial=$(read_attr "$dev" serial)

  is_candidate=no
  for known in $KNOWN_VIDS; do
    [[ $vid == "$known" ]] && is_candidate=yes
  done
  # A scanner we have not seen before: a UVC camera whose serial looks like
  # one of JM Studio's (it accepts only serials starting JM or CR).
  if [[ $serial == JM* || $serial == CR* ]]; then is_candidate=yes; fi
  [[ $is_candidate == yes ]] || continue

  found+=("$dev")
  printf '   %s  %s:%s  %-18s %-26s serial=%s\n' \
    "$(basename "$dev")" "$vid" "$pid" "${manufacturer:- }" "${product:- }" "${serial:-none}"
done

if [[ ${#found[@]} -eq 0 ]]; then
  note "Nothing matched."
  note ""
  note "If the scanner is plugged in and powered, it is reporting an identity"
  note "we do not know yet. Run this to dump every USB device, and we can pick"
  note "it out by comparing the list with the scanner unplugged:"
  note ""
  note "    lsusb && echo --- && lsusb -t"
  note ""
  if have lsusb; then
    say "Full lsusb, for comparison"
    lsusb
    say "Bus topology"
    lsusb -t
  fi
  exit 1
fi

# ------------------------------------------------------------------ topology

say "Where it sits on the bus"
note "A scanner reached through an extra hub or a dock loses USB packets, which"
note "shows up as grey stripes across the scan. Prefer a port straight on the"
note "machine. (Documented upstream in NOTES.md, 'Stripe artefacts'.)"
note ""
for dev in "${found[@]}"; do
  name=$(basename "$dev")
  chain=$(cd "$dev" && pwd -P | tr '/' '\n' | grep -E '^[0-9]+-[0-9.]+$' | tr '\n' ' ')
  speed=$(read_attr "$dev" speed)
  note "$name: path $chain(${speed:-?} Mbit/s)"
done
if have lsusb; then
  echo
  lsusb -t 2>/dev/null | sed 's/^/   /'
fi

# -------------------------------------------------------------- autosuspend

say "USB autosuspend"
note "JM Studio gives up ~500 ms after asking for the first frame. Waking a"
note "suspended camera takes longer than that, so the first connect after an"
note "idle spell fails and a retry works. setup-host.sh pins these to 'on'."
note ""
for dev in "${found[@]}"; do
  ctrl=$(read_attr "$dev" power/control)
  delay=$(read_attr "$dev" power/autosuspend_delay_ms)
  printf '   %s: power/control=%s autosuspend_delay_ms=%s\n' \
    "$(basename "$dev")" "${ctrl:-n/a}" "${delay:-n/a}"
done

# ------------------------------------------------------------- video nodes

say "V4L2 capture nodes"
for dev in "${found[@]}"; do
  name=$(basename "$dev")
  nodes=$(find "$dev" -maxdepth 3 -name 'video*' -path '*video4linux*' -printf '%f\n' 2>/dev/null | sort)
  if [[ -z $nodes ]]; then
    note "$name: no /dev/video node — not bound to uvcvideo?"
    continue
  fi
  for n in $nodes; do
    printf '   %s -> /dev/%s' "$name" "$n"
    [[ -r /dev/$n ]] && printf '  (readable)\n' || printf '  (NOT readable by you)\n'
  done
done

if have v4l2-ctl; then
  for dev in "${found[@]}"; do
    for n in $(find "$dev" -maxdepth 3 -name 'video*' -path '*video4linux*' -printf '%f\n' 2>/dev/null | sort); do
      say "/dev/$n formats"
      v4l2-ctl -d "/dev/$n" --list-formats-ext 2>&1 | sed 's/^/   /'
      say "/dev/$n controls"
      v4l2-ctl -d "/dev/$n" --list-ctrls 2>&1 | sed 's/^/   /'
    done
  done
else
  say "v4l2-ctl not installed"
  note "Install it to see the formats and exposure/gain controls:"
  note "    sudo apt install v4l-utils"
fi

# ------------------------------------------------------------- UVC descriptors

say "UVC units (the serial number lives behind an extension unit)"
if have lsusb; then
  for dev in "${found[@]}"; do
    vid=$(read_attr "$dev" idVendor); pid=$(read_attr "$dev" idProduct)
    echo "   --- $vid:$pid ---"
    # Extension units carry a GUID; the Lizard's is 1229a78c-47b4-4094-b0ce-db07386fb938.
    lsusb -d "$vid:$pid" -v 2>/dev/null |
      grep -iE 'bDescriptorSubtype|guidExtensionCode|bUnitID|bTerminalID|bNumControls|iProduct|bInterfaceClass|wMaxPacketSize|bAlternateSetting' |
      sed 's/^/   /'
  done
  note ""
  note "(Run under sudo for the full descriptor dump: sudo lsusb -v -d <vid>:<pid>)"
else
  note "lsusb not installed:  sudo apt install usbutils"
fi

say "Summary"
note "Copy this whole output back into the chat. It tells us whether the Moose"
note "Lite is the same two-UVC-camera design as the Moose and the Lizard, which"
note "decides whether the existing patched-Wine build drives it unchanged."
