# macpad++ licensing and attribution

macpad++ is an independent fork of Notepad++ by Don Ho and contributors.
The fork was modified in November 2026 to add the native macOS editor, its
build and packaging scripts, and macpad++ branding. The editor is distributed
under GNU GPL version 3. The original license and copyright notices remain
in the source and the application bundle. [LICENSE](LICENSE)

## Native app

| Component | Terms and attribution |
| --- | --- |
| Scintilla Cocoa | Neil Hodgson, Oracle, Sun Microsystems and other contributors. Files that offer both LGPL 2.1 and the Scintilla license are used under the Scintilla license. [Scintilla license](scintilla/License.txt) |
| Lexilla | Neil Hodgson and contributors. [Lexilla license](lexilla/License.txt) |
| Boost.Regex | [Boost Software License 1.0](licenses/Boost-1.0.txt) |
| pugixml | Arseny Kapoulkine and contributors. [MIT license](PowerEditor/src/pugixml/LICENSE.md) |
| uchardet | Mozilla Universal Charset Detector and contributors. The source offers MPL 1.1, GPL 2.0 or later, or LGPL 2.1 or later. macpad++ uses the GPL option. [GPL 2.0](licenses/GPL-2.0.txt) |
| Markdown language definitions | Edditoria and contributors. [MIT license](licenses/markdown-plus-plus.txt) |
| Toolbar and tab icons | Original editor artwork in the source tree. [GPLv3](LICENSE) |
| Localizations and language data | Original contributors' notices remain in the resource files, including the bundled Function List and Auto-Completion XML. |
| Themes | Separate XML works distributed with their original notices. See the details below. |
| App icon | Artwork supplied for this fork. The same artwork is used in the application icon and README. |
| Plugins | The bundled Document Tools plugin is GPLv3. Other plugins are added separately by users under their own terms. [Source](macos/plugins/DocumentTools.mm) |

## Theme terms

- **Zenburn** and **DarkModeDefault** identify GPL version 2. Their XML source
  is included, with the notices intact. [GPL version 2](licenses/GPL-2.0.txt)
- **Bespin**, **Black board**, **Choco**, **Mono Industrial**, **Monokai**,
  **Plastic Code Wrap** and **Twilight** carry permissive notices in the XML.
- **HotFudgeSundae**, **khaki**, **MossyLawn**, **Navajo**, **Solarized** and
  **Solarized-light** carry Creative Commons attribution notices in the XML.
  [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/)
- **DansLeRuSH-Dark**, by Franck Albaret, carries both a permissive grant and
  a CC BY-NC-SA 3.0 notice. Preserve its attribution and observe the
  noncommercial terms unless the author clarifies the grant.
  [CC BY-NC-SA 3.0](https://creativecommons.org/licenses/by-nc-sa/3.0/)
- **Deep Black**, **Ruby Blue** and **Vibrant Ink** use the unspecific wording
  “GNU Free License” in their original notices. The name and version of the
  intended license remain to be confirmed before public redistribution.

## Legacy Windows source

| Component | Terms and attribution |
| --- | --- |
| Boost.Regex | [Boost Software License 1.0](licenses/Boost-1.0.txt) |
| nlohmann/json | Niels Lohmann and contributors. [MIT license](licenses/nlohmann-json.txt) |
| uchardet | Same encoding detector and license as the native app. [GPL 2.0](licenses/GPL-2.0.txt) |
| Windows dark-mode code | MIT notices for [win32-darkmode](licenses/win32-darkmode.txt), [UAHMenuBar](licenses/UAHMenuBar.txt) and [PolyHook 2.0](licenses/PolyHook-2.0.txt). |
| Directory change monitor | James E Beveridge. [MIT license](licenses/ReadDirectoryChanges.txt) |
| Hash implementations | The MD5 code is derived from the RSA Data Security, Inc. MD5 Message-Digest Algorithm. Dominik Reichl's SHA-1 implementation is marked public domain. The SHA-256 code cites Wikipedia for its pseudocode and comments. [RSA MD5 notice](licenses/RSA-MD5.txt) · [SHA-2 article](https://en.wikipedia.org/wiki/SHA-2) |
| Markdown language definitions | Edditoria and contributors. [MIT license](licenses/markdown-plus-plus.txt) |

## Distributing builds

For an online binary release, make the corresponding source from the same
revision available alongside the binary with equivalent access. Include the
build scripts, library source and resource files so recipients can rebuild.
The macOS workflow packages the app and a source archive from the same revision.
Preserve the license and attribution in both. [GPLv3 sections 5 and 6](https://www.gnu.org/licenses/gpl-3.0.html#section5)
