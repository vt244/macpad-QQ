#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
app="$root/dist/macpad++.app"
if [[ ! -x "$app/Contents/MacOS/macpad++" ]]; then
	echo "Build macpad++.app with macos/build-app.sh first." >&2
	exit 1
fi

mkdir -p .tmp
work=$(mktemp -d "$root/.tmp/native-smoke.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
export TMPDIR="$work"
export MACPAD_DATA_DIR="$work"
mkdir -p "$work/plugins"
sed 's/name="Default Style" styleID="32" fgColor="000000" bgColor="FFFFFF"/name="Default Style" styleID="32" fgColor="000000" bgColor="123456"/' \
	PowerEditor/src/stylers.model.xml > "$work/Smoke.xml"
xcrun clang -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 -I macos \
	macos/tests/SelectionPlugin.c -o "$work/plugins/SelectionPlugin.dylib"
codesign --verify --strict "$app"
xcrun lipo "$app/Contents/MacOS/macpad++" -verify_arch arm64 x86_64
"$app/Contents/MacOS/macpad++" --smoke-test
