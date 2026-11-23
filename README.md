# macpad++

macpad++ is a native macOS code and text editor. It is an independent fork of
Notepad++, originally created by Don Ho and developed by its contributors.
The macOS port uses AppKit for the interface, Scintilla Cocoa for editing,
and Lexilla for syntax highlighting. [Upstream project](https://github.com/notepad-plus-plus/notepad-plus-plus)

## Install on macOS

macpad++ runs natively on Apple silicon and Intel Macs with macOS 13 or later.
It reads existing XML themes, translations and user-defined languages.
Plugins use the [macOS plugin API](macos/MacpadPlugin.h). Windows DLLs need
to be ported and rebuilt to run inside macpad++.

Check [GitHub Releases](https://github.com/vt244/macpad-plus-plus/releases) for
published builds. When a macOS release is available, download
`macpad++-macOS.zip` and `SHA256SUMS`, verify the archive, then unpack it
and move `macpad++.app` to Applications.

```sh
shasum -a 256 macpad++-macOS.zip
```

Compare the output with the app archive entry in `SHA256SUMS`.

## Build from source

To build from source, install the Apple Command Line Tools and CMake 3.20 or
later, then run these commands from the repository root.

```sh
macos/build-app.sh
open 'dist/macpad++.app'
```

Local and CI builds use ad hoc signing. The macOS workflow tests the native
app and bundles it with matching source and SHA-256 checksums.
[Build and release instructions](BUILD.md) · [macOS workflow](.github/workflows/macos.yml)

## What you can do

- Edit in two tabbed views, move tabs by dragging, and rotate the split from the divider's context menu. Use **View → Move/Clone Current Document** to open a second view.
- Move, resize or float panels such as **Document List**, **Folder as Workspace**, **Project Panels**, **Function List** and **Document Map**.
- Find, replace, count and mark matches using literal, extended or regular expression search. Search within a selection, across open documents, in folders or in projects.
- Refine previous searches from the results panel and navigate between hits with **Search → Next Search Result** and **Previous Search Result**.
- Use the **Edit** menu for column insertion, multiple selections, commenting, line sorting and autocompletion. **Clipboard History** keeps recent text entries in memory while its panel is open.
- Open, save and convert UTF‑8, BOM-marked UTF‑16 and Windows‑1252 text.
- Reopen legacy text with its original encoding from **Encoding → Character Set**.
- Follow log files with **View → Monitoring (tail -f)**. Configure detection of external changes in **Settings → Preferences**.
- Record and replay editing, search and replace actions from the **Macro** menu. **Import Macros…** reads compatible actions from `shortcuts.xml`. Assign keys to macros and named **Run** commands in **Settings → Shortcut Mapper**.
- Generate checksums from **Tools**, run macOS commands and save or open XML sessions.
- Reopen the working session, including unsaved drafts, after quitting or restarting.
- Import existing XML themes, translations and user-defined languages.

Open files from **File → Open** or from Finder with **Open With → macpad++**.
Use the executable directly to open a file from the terminal at a specific line and column.

```sh
'dist/macpad++.app/Contents/MacOS/macpad++' -n20 -c4 -lpython example.py
```

[Compatibility and current limitations](SUPPORTED_SYSTEM.md)

## Customize macpad++

The profile folder is `~/Library/Application Support/macpad++/profile/`.

| Resource | Where to install it | Where to use it |
| --- | --- | --- |
| XML theme | `themes/` | **View → Theme** selects a theme. **Settings → Style Configurator** edits colors and fonts. Enable individual attributes from the theme’s **Global override** style in **Preferences → Global style override**. |
| XML translation | `localization/` | **Settings → Interface Language**. **Import XML…** copies the file into the profile. The default option also reads `nativeLang.xml` at the profile root. |
| User Defined Language XML | `userDefineLangs/` or `userDefineLang.xml` | Create, edit, import and export definitions from **Language**. Apply a definition from the menu or by file extension. |
| Function and completion rules | `functionList/` and `autoCompletion/` | Override the supplied XML rules for **Function List** and **Auto-Completion**. |
| Context menus | `contextMenu.xml` and `tabContextMenu.xml` | Edit the editor and tab menus from **Settings**. |
| Toolbar | `toolbarButtonsConf.xml` and `toolbarIcons/` | Set built-in button visibility and supply icon overrides. Relaunch to apply changes. |
| Windows project and session paths | `windowsPathMappings.plist` | Map drive letters and UNC shares to local directories. See [path mapping examples](SUPPORTED_SYSTEM.md#map-windows-paths). |
| macOS plugin | `plugins/*.dylib` | Install from a local file or the catalog in **Plugins → Plugins Admin…**, then restart. Disabled files remain in `plugins/Disabled/`. |

The native plugin API supports document access, editor events, AppKit panels
and multiple menu commands.
[Native plugin API](macos/MacpadPlugin.h) · [Plugin build example](BUILD.md#native-plugins)

## License and contributions

The editor is distributed under the GNU General Public License version 3.
The fork preserves upstream copyright notices. Third-party components, themes
and artwork have their own attribution and distribution considerations.
[GPLv3](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md)

Report macOS issues in this fork and include your macOS and macpad++ versions.
[Issues](https://github.com/vt244/macpad-plus-plus/issues) · [Contributing](CONTRIBUTING.md)
