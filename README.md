# macpad++

macpad++ is a native macOS code and text editor. It is an independent fork of
Notepad++, originally created by Don Ho and developed by its contributors.
The macOS port uses AppKit for the interface, Scintilla Cocoa for editing,
and Lexilla for syntax highlighting. [Upstream project](https://github.com/notepad-plus-plus/notepad-plus-plus)

## Get started

macpad++ runs on Apple silicon and Intel Macs with macOS 13 or later.
The app runs directly on macOS.

To build from source, install the Apple Command Line Tools and CMake 3.20 or
later, then run these commands from the repository root.

```sh
macos/build-app.sh
open 'dist/macpad++.app'
```

GitHub Actions also provides the app and its matching source archive from
successful builds. Local and CI builds are signed ad hoc. [Build guide](BUILD.md) · [GitHub Actions](https://github.com/vt244/macpad-plus-plus/actions/workflows/macos.yml)

## What you can do

- Edit text and source files in tabs, with syntax highlighting, line numbers and word wrap.
- Find and replace text with optional regular expressions.
- Open and save UTF‑8 and BOM-marked UTF‑16 files while preserving their encoding and line endings.
- Import existing theme and translation XML files.

Open files from **File → Open** or from Finder with **Open With → macpad++**.
The native port uses the existing XML formats for editor styles and matching
menu labels. [Compatibility and current limitations](SUPPORTED_SYSTEM.md)

## Customize macpad++

The profile folder is `~/Library/Application Support/macpad++/profile/`.

| Resource | Where to install it | Where to use it |
| --- | --- | --- |
| XML theme | `themes/` | **View → Theme**. **Import XML…** copies the file into the profile. |
| XML translation | `localization/` | **Settings → Interface Language**. **Import XML…** copies the file into the profile. The default option also reads `nativeLang.xml` at the profile root. |
| macOS plugin | `plugins/*.dylib` | Restart macpad++ and open **Plugins**. |

Native plugins can read and replace the current selection. Windows DLL plugins
require Windows. Plugins with source code can be adapted and rebuilt for macOS.
[Native plugin API](macos/MacpadPlugin.h) · [Plugin build example](BUILD.md#native-plugins)

## License and contributions

The editor is distributed under the GNU General Public License version 3.
The fork preserves upstream copyright notices. Third-party components, themes
and artwork have their own attribution and distribution considerations.
[GPLv3](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md)

Report macOS issues in this fork and include your macOS and macpad++ versions.
[Issues](https://github.com/vt244/macpad-plus-plus/issues) · [Contributing](CONTRIBUTING.md)
