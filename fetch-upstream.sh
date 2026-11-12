#!/usr/bin/env bash
#
# Clone the upstream work this project builds on, into ./vendor (gitignored).
#
# poita66/jmstudio-flatpak is the patched Wine build of JM Studio for Linux,
# plus NOTES.md - the wire-protocol write-up for this scanner family - and the
# native V4L2 capture tools that tools/moose-capture.py wraps.
#
# We clone rather than copy so that upstream keeps its own history and licence,
# and so a `git -C vendor/jmstudio-flatpak pull` is all an update takes.

set -euo pipefail

REPO=https://github.com/poita66/jmstudio-flatpak.git
DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vendor/jmstudio-flatpak"

mkdir -p "$(dirname "$DEST")"

if [[ -d $DEST/.git ]]; then
  echo "==> updating $DEST"
  git -C "$DEST" pull --ff-only
else
  echo "==> cloning $REPO"
  git clone "$REPO" "$DEST"
fi

echo
echo "Read: $DEST/NOTES.md   (the protocol write-up)"
echo "Tools in: $DEST/tools/"
