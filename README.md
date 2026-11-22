# macpad++

macpad++ is a native macOS source-code editor derived from
[Notepad++](https://github.com/notepad-plus-plus/notepad-plus-plus).
It uses AppKit, Scintilla Cocoa and Lexilla, and runs on Apple silicon and Intel Macs with macOS 13 or later.

## Run on macOS

Build `macpad++.app` using the [build guide](BUILD.md) or get the app and its
matching source archive from a successful [macOS build](https://github.com/vt244/macpad-plus-plus/actions/workflows/macos.yml).
Open the app in Finder. Use **File → Open** or **Open With → macpad++** to edit a file.

The editor supports syntax highlighting for built-in languages, UTF‑8 and
UTF‑16, tabs, undo, word wrap, and find and replace with regular expressions.
See [compatibility](SUPPORTED_SYSTEM.md) for the scope of the native port.

## Themes, translations and plugins

User files live in `~/Library/Application Support/macpad++/profile/`.

| Extension | Where to put it | How to use it |
| --- | --- | --- |
| Theme XML | `themes/` | Choose **View → Theme**. Use **Import XML…** to add a file. |
| Translation XML | `localization/` | Choose **Settings → Interface Language**. Use **Import XML…** to add a file. The default choice reads `nativeLang.xml` from the profile root when present. |
| Native plugin | `plugins/*.dylib` | Restart macpad++ and use its **Plugins** menu. The [native plugin API](macos/MacpadPlugin.h) supports commands that read and replace the active selection. |

Windows plugin DLLs require Windows. Plugins with source code can be adapted
to the native plugin API. [Build and adapt a plugin](BUILD.md#native-plugins)

## Source and licenses

macpad++ is a modified version of Notepad++ by Don Ho and the Notepad++ contributors.
The editor is distributed under the [GNU GPL version 3](LICENSE).
See [third-party notices](THIRD_PARTY_NOTICES.md) for components with separate
terms, including bundled themes. [Contribution rules](CONTRIBUTING.md) apply to this fork.
