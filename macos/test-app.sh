#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
app="$root/dist/macpadqq.app"
if [[ ! -x "$app/Contents/MacOS/macpadqq" ]]; then
	echo "Build macpadqq.app with macos/build-app.sh first." >&2
	exit 1
fi

mkdir -p .tmp
work=$(mktemp -d "$root/.tmp/native-smoke.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
export TMPDIR="$work"
export MACPAD_DATA_DIR="$work"
mkdir -p "$work/plugins" "$work/plugins-v3"
sed 's/name="Default Style" styleID="32" fgColor="000000" bgColor="FFFFFF"/name="Default Style" styleID="32" fgColor="000000" bgColor="123456"/' \
	PowerEditor/src/stylers.model.xml > "$work/Smoke.xml"
xcrun clang -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 -I macos \
	macos/tests/SelectionPlugin.c -o "$work/plugins/SelectionPlugin.dylib"
xcrun clang -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 -I macos \
	macos/tests/NativePluginV3.c -o "$work/plugins-v3/NativePluginV3.dylib"
xcrun clang -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 -I macos -DTEST_ORIGINAL_DESCRIPTOR \
	macos/tests/NativePluginV3.c -o "$work/plugins-v3/OriginalPluginV3.dylib"
cat > "$work/toolbarButtonsConf.xml" <<'XML'
<NotepadPlus><ToolbarButtons><Standard><Button id="44023" index="18" hide="yes"/></Standard></ToolbarButtons></NotepadPlus>
XML
codesign --verify --strict "$app"
xcrun lipo "$app/Contents/MacOS/macpadqq" -verify_arch arm64 x86_64
"$app/Contents/MacOS/macpadqq" --smoke-test
MACPAD_DATA_DIR="$work/lifecycle" "$app/Contents/MacOS/macpadqq" --smoke-workspace-write
MACPAD_DATA_DIR="$work/lifecycle" "$app/Contents/MacOS/macpadqq" --smoke-workspace-restore
