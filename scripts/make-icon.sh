#!/bin/bash
# Build a macOS icon from the single source PNG using Apple's bundled tools.
set -euo pipefail
icon_source=$1
icon_output=$2
mkdir -p "$(dirname "$icon_output")"
icon_temp=$(mktemp -d)
trap 'rm -rf "$icon_temp"' EXIT
icon_set="$icon_temp/AppIcon.iconset"
mkdir -p "$icon_set"
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    suffix=""
    if [ "$scale" -eq 2 ]; then suffix="@2x"; fi
    pixels=$((size * scale))
    sips -z "$pixels" "$pixels" "$icon_source" \
      --out "$icon_set/icon_${size}x${size}${suffix}.png" >/dev/null
  done
done
iconutil -c icns "$icon_set" -o "$icon_output"
