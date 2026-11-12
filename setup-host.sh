#!/usr/bin/env bash
#
# Set this machine up to run the 3D scanner.
#
#   ./setup-host.sh              # udev rules + prerequisites, then tell you what's next
#   ./setup-host.sh --udev-only  # just the udev rules
#   ./setup-host.sh --dry-run    # print what it would do and change nothing
#
# Two things need root: writing the udev rule, and installing packages. Nothing
# else here does, and the Flatpak install is deliberately --user.

set -euo pipefail

RULES_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/udev/99-3dmakerpro-scanner.rules"
RULES_DST=/etc/udev/rules.d/99-3dmakerpro-scanner.rules
DRY_RUN=no
UDEV_ONLY=no

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=yes ;;
    --udev-only) UDEV_ONLY=yes ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
run() {
  if [[ $DRY_RUN == yes ]]; then
    printf '    [dry-run] %s\n' "$*"
  else
    printf '    + %s\n' "$*"
    "$@"
  fi
}

# --------------------------------------------------------------- the udev rule

step "USB autosuspend rule"

if [[ ! -r $RULES_SRC ]]; then
  echo "missing $RULES_SRC" >&2
  exit 1
fi

# If a scanner is plugged in and reports IDs the shipped rule does not cover,
# add them rather than leaving the user with a rule that matches nothing.
extra=""
for dev in /sys/bus/usb/devices/*; do
  [[ -r $dev/idVendor ]] || continue
  serial=$(tr -d '\0' <"$dev/serial" 2>/dev/null | head -1 || true)
  [[ $serial == JM* || $serial == CR* ]] || continue
  vid=$(tr -d '\0' <"$dev/idVendor"); pid=$(tr -d '\0' <"$dev/idProduct")
  if ! grep -qi "idProduct}==\"$pid\"" "$RULES_SRC" && ! grep -qi "idVendor}==\"$vid\", TEST" "$RULES_SRC"; then
    note "found an uncovered scanner device: $vid:$pid (serial $serial)"
    extra+="ACTION==\"add\", SUBSYSTEM==\"usb\", ATTR{idVendor}==\"$vid\", ATTR{idProduct}==\"$pid\", TEST==\"power/control\", ATTR{power/control}=\"on\"\n"
  fi
done

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cp "$RULES_SRC" "$tmp"
if [[ -n $extra ]]; then
  {
    echo
    echo "# Added by setup-host.sh from the scanner plugged in at the time."
    printf '%b' "$extra"
  } >>"$tmp"
fi

if [[ -r $RULES_DST ]] && cmp -s "$tmp" "$RULES_DST"; then
  note "already installed and unchanged: $RULES_DST"
else
  run sudo install -m 0644 "$tmp" "$RULES_DST"
  run sudo udevadm control --reload-rules
  note "Unplug and replug the scanner for the rule to take effect."
fi

if [[ $UDEV_ONLY == yes ]]; then exit 0; fi

# -------------------------------------------------------------- prerequisites

step "Diagnostic tools"
missing=()
for pkg_cmd in "usbutils:lsusb" "v4l-utils:v4l2-ctl"; do
  pkg=${pkg_cmd%%:*}; cmd=${pkg_cmd##*:}
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$pkg")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  run sudo apt-get install -y "${missing[@]}"
else
  note "lsusb and v4l2-ctl are present."
fi

step "Flatpak"
if ! command -v flatpak >/dev/null 2>&1; then
  run sudo apt-get install -y flatpak
  note "On a fresh flatpak install, log out and back in so the app menu picks"
  note "up new applications."
else
  note "flatpak is present."
fi

if ! flatpak remotes --columns=name 2>/dev/null | grep -qx flathub; then
  run flatpak remote-add --user --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo
else
  note "flathub remote is configured."
fi

# ------------------------------------------------------------------- what next

step "Next steps"
cat <<'EOF'
    1. Check what the scanner reports, with it plugged in:

           ./tools/probe-scanner.sh

    2. Download the JM Studio installer for Windows (JMStudioSetup-*.exe) into
       ~/Downloads, from:

           https://forum.jimumeta.com/home/help/download.html

    3. Install the patched-Wine build of JM Studio. Check the release's
       provenance first, then install it for your user only:

           gh release download --repo poita66/jmstudio-flatpak --pattern '*.flatpak'
           gh attestation verify jmstudio-*.flatpak --repo poita66/jmstudio-flatpak
           flatpak install --user jmstudio-*.flatpak

    4. Run it. The first launch runs the Windows installer inside its own Wine
       prefix; click through and keep the default install location.

           flatpak run io.github.poita66.jmstudio

    If the cameras appear but JM Studio does not see the scanner, capture a log
    and we will read it:

        flatpak run --env=WINEDEBUG=err+all,warn+qcap \
            io.github.poita66.jmstudio 2> jmstudio-wine.log
EOF
