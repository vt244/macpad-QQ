# macpad++ compatibility

| Component | Native macOS support |
| --- | --- |
| Platform | macOS 13 or later on Apple silicon and Intel. The app includes both architectures. |
| Documents | UTF‑8 with or without a BOM, and BOM-marked UTF‑16 LE/BE. Saving preserves the encoding, BOM and existing line endings. |
| Syntax highlighting | Built-in Lexilla languages selected by file extension. User Defined Language (UDL) XML requires the legacy Windows editor. |
| Theme XML | Default and lexer styles, available fonts, and selection and line number colors from the Notepad++ format. Windows-specific GUI theme entries have no macOS equivalent. |
| Translation XML | Matching menu and command labels from the Notepad++ format. AppKit controls and new macOS commands use their own labels. |
| Plugins | macOS dylibs for the running CPU architecture. See the [native plugin interface](macos/MacpadPlugin.h) for supported commands. Existing Win32 DLLs require the Windows editor. |

The native editor includes core editing, search and replace, and native window
tabbing. Windows-only features such as macros, session restoration and the
upstream Plugins Admin have no implementation in this port.
The legacy Windows source and build instructions are available in [BUILD.md](BUILD.md).
