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
mkdir -p "$resources/toolbar" "$resources/tabbar"
toolbar_icons=(new open save saveall close closeall print cut copy paste undo redo find findrep zoomIn zoomOut syncV syncH wrap allChars indentGuide udl docMap docList funcList fileBrowser monitoring startrecord stoprecord playrecord saverecord playrecord_m)
for scheme in light dark; do
	for style in regular filled; do
		destination="$resources/toolbar/$scheme/$style"
		mkdir -p "$destination"
		for icon in "${toolbar_icons[@]}"; do
			cp "PowerEditor/src/icons/$scheme/toolbar/$style/${icon}_off.ico" "$destination/"
			disabled="PowerEditor/src/icons/$scheme/toolbar/$style/${icon}_dis.ico"
			if [[ -f "$disabled" ]]; then
				cp "$disabled" "$destination/"
			fi
		done
	done
done
mkdir "$resources/toolbar/classic"
cp PowerEditor/src/icons/standard/toolbar/*.bmp "$resources/toolbar/classic/"
for scheme in standard dark; do
	mkdir -p "$resources/panels/$scheme"
	cp PowerEditor/src/icons/"$scheme"/panels/toolbar/fb_*.ico "$resources/panels/$scheme/"
done
mkdir "$resources/tabbar/dark"
cp PowerEditor/src/icons/standard/tabbar/{saved,unsaved,readonly,monitoring,pinTabButton_pinned}.ico "$resources/tabbar/"
cp PowerEditor/src/icons/dark/tabbar/{unsaved,readonly,monitoring,pinTabButton_pinned}.ico "$resources/tabbar/dark/"
for cursor in mac_cursor_busy mac_cursor_flipped; do
	sips -s format tiff "scintilla/cocoa/res/$cursor.png" --out "$resources/$cursor.tiff" >/dev/null
done
cp '.tmp/native-build/macpad++' "$app/Contents/MacOS/"
cp PowerEditor/src/{langs.model.xml,stylers.model.xml} "$resources/"
cp -R PowerEditor/installer/nativeLang "$resources/localization"
cp -R PowerEditor/installer/themes "$resources/"
cp -R PowerEditor/installer/functionList "$resources/"
cp -R PowerEditor/installer/APIs "$resources/autoCompletion"
mkdir -p "$resources/catalog"
xcrun clang++ -fobjc-arc -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
	-framework Cocoa -I macos macos/plugins/DocumentTools.mm -o "$resources/catalog/DocumentTools.dylib"
codesign --force --sign - "$resources/catalog/DocumentTools.dylib"
plugin_hash=$(shasum -a 256 "$resources/catalog/DocumentTools.dylib")
printf '{"plugins":[{"name":"Document Tools","version":"1.0.0","file":"DocumentTools.dylib","url":"catalog/DocumentTools.dylib","sha256":"%s"}]}\n' \
	"${plugin_hash%% *}" > "$resources/plugins-catalog.json"
cp -R PowerEditor/bin/userDefineLangs "$resources/"
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
