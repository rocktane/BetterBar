#!/bin/bash
# Uses a disposable app with two real status items. Temporarily changes global
# spacing, restores it on completion, and never restarts the user's other apps.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir=$(mktemp -d /tmp/betterbar-spacing.XXXXXX)
trap 'rm -rf "$fixture_dir"' EXIT
mkdir -p "$fixture_dir/SpacingFixture.app/Contents/MacOS"
cp Tests/SpacingFixture/Info.plist "$fixture_dir/SpacingFixture.app/Contents/Info.plist"
swiftc -swift-version 6 -target arm64-apple-macosx27.0 Tests/SpacingFixture/main.swift -o "$fixture_dir/SpacingFixture.app/Contents/MacOS/SpacingFixture"
swiftc -swift-version 6 -target arm64-apple-macosx27.0 Sources/Core/*.swift Sources/App/Inventory.swift Sources/App/MenuBarSpacing.swift Sources/App/MenuBarAppRelauncher.swift Tests/SpacingRelaunch/main.swift -o "$fixture_dir/SpacingRelaunch"
"$fixture_dir/SpacingRelaunch" "$fixture_dir"
