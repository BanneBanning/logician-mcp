#!/bin/bash
# Build, sign and install the LogicMCPSensor AUv2 component, then validate it.
set -euo pipefail
cd "$(dirname "$0")"

# Build in a non-iCloud-synced staging directory: cloud sync adds FinderInfo
# and fileprovider extended attributes that make codesign refuse the bundle.
STAGING="$(mktemp -d /tmp/logicmcpsensor-build.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
BUNDLE="$STAGING/LogicMCPSensor.component"
INSTALL_DIR="$HOME/Library/Audio/Plug-Ins/Components"

mkdir -p "$BUNDLE/Contents/MacOS"

clang -O2 -Wall -bundle \
    -framework AudioToolbox \
    -framework CoreFoundation \
    -o "$BUNDLE/Contents/MacOS/LogicMCPSensor" \
    LogicMCPSensor.c

cp Info.plist "$BUNDLE/Contents/Info.plist"
xattr -cr "$BUNDLE"
codesign --force --sign - "$BUNDLE"

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/LogicMCPSensor.component"
ditto --norsrc --noextattr "$BUNDLE" "$INSTALL_DIR/LogicMCPSensor.component"
codesign --force --sign - "$INSTALL_DIR/LogicMCPSensor.component"

echo "Installed to $INSTALL_DIR/LogicMCPSensor.component"
echo "Validating with auval..."
auval -v aufx lmsn LMcp
