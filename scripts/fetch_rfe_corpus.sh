#!/usr/bin/env bash
# Clones the FNFE France_RFE corpus into tools/rfe/ (gitignored), pinned to the
# tag the vendored schematrons in test/fixtures/schematron/ were copied from.
# Only scripts/refresh_oracle.exs needs it: the reference XSLTs live there and
# are too bulky to vendor.
set -euo pipefail

TAG="${RFE_TAG:-v1.4.0.04}"
DEST="${RFE_DEST:-tools/rfe}"
REPO=https://github.com/fnfempe/France_RFE.git

if [ -d "$DEST/.git" ]; then
  git -C "$DEST" fetch --depth 1 origin "+refs/tags/$TAG:refs/tags/$TAG"
  git -C "$DEST" checkout --quiet "$TAG"
else
  mkdir -p "$(dirname "$DEST")"
  git clone --depth 1 --branch "$TAG" "$REPO" "$DEST"
fi

echo "France_RFE $TAG in $DEST ($(git -C "$DEST" rev-parse --short HEAD))"
