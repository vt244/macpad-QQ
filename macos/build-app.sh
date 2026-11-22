#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD

mkdir -p .tmp dist
work=$(mktemp -d "$root/.tmp/package.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
export TMPDIR="$work/tmp"
mkdir "$TMPDIR"
jobs=${MACPAD_BUILD_JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}
cmake -S macos -B .tmp/native-build -DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 '-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64'
cmake --build .tmp/native-build --parallel "$jobs"

app="$work/macpad++.app"
resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$resources/licenses"

cp macos/Info.plist "$app/Contents/"
cp macos/AppIcon.icns "$resources/"
for cursor in mac_cursor_busy mac_cursor_flipped; do
	sips -s format tiff "scintilla/cocoa/res/$cursor.png" --out "$resources/$cursor.tiff" >/dev/null
done
cp '.tmp/native-build/macpad++' "$app/Contents/MacOS/"
cp PowerEditor/src/{langs.model.xml,stylers.model.xml} "$resources/"
cp -R PowerEditor/installer/nativeLang "$resources/localization"
cp -R PowerEditor/installer/themes "$resources/"
cp PowerEditor/bin/{change.log,readme.txt} "$resources/"
cp LICENSE THIRD_PARTY_NOTICES.md README.md "$resources/"
cp licenses/*.txt "$resources/licenses/"
cp scintilla/License.txt "$resources/licenses/Scintilla.txt"
cp lexilla/License.txt "$resources/licenses/Lexilla.txt"
cp PowerEditor/src/pugixml/LICENSE.md "$resources/licenses/pugixml.txt"

/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"

if [[ -e "dist/macpad++.app" ]]; then
	mv "dist/macpad++.app" "$work/previous.app"
fi
if ! mv "$app" dist/; then
	if [[ -e "$work/previous.app" ]]; then
		mv "$work/previous.app" "dist/macpad++.app"
	fi
	exit 1
fi
echo "$root/dist/macpad++.app"
