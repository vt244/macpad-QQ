# macpad++ license and third-party notices

macpad++ is based on Notepad++ by Don Ho and the Notepad++ contributors.
The macOS port was added in November 2026. The native macOS port includes an AppKit interface,
brand changes, and macOS build and packaging scripts.
The editor is distributed under [GNU GPL version 3](LICENSE).

| Component | Terms and attribution |
| --- | --- |
| Scintilla and Lexilla | Neil Hodgson and contributors. See [Scintilla](scintilla/License.txt) and [Lexilla](lexilla/License.txt). |
| Boost.Regex | [Boost Software License 1.0](licenses/Boost-1.0.txt). |
| pugixml | [MIT license](PowerEditor/src/pugixml/LICENSE.md), Arseny Kapoulkine and contributors. |
| nlohmann/json | [MIT license](licenses/nlohmann-json.txt), Niels Lohmann and contributors. |
| uchardet | Mozilla Universal Charset Detector and contributors. The bundled source carries MPL 1.1 / GPL 2.0 or later / LGPL 2.1 or later notices. This build uses the GPL option. |
| Windows dark-mode code | MIT notices for [win32-darkmode](licenses/win32-darkmode.txt), [UAHMenuBar](licenses/UAHMenuBar.txt) and [PolyHook 2.0](licenses/PolyHook-2.0.txt). |
| Directory change monitor | James E Beveridge. MIT notice in [ReadDirectoryChanges.h](PowerEditor/src/WinControls/ReadDirectoryChanges/ReadDirectoryChanges.h). |
| Hash implementations | The bundled MD5 implementation is derived from the RSA Data Security, Inc. MD5 Message-Digest Algorithm. See [md5.h](PowerEditor/src/MISC/md5/md5.h). Dominik Reichl's SHA-1 implementation is marked public domain. The SHA-256 source cites [Wikipedia's SHA-2 article](https://en.wikipedia.org/wiki/SHA-2) for its pseudocode and comments. |
| Bundled Markdown language definitions | [MIT license](licenses/markdown-plus-plus.txt), Edditoria and contributors. |
| Bundled themes | The themes are separate XML works with their original notices. Zenburn and DarkModeDefault identify [GPL version 2](licenses/GPL-2.0.txt). Several themes use MIT or [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/). DansLeRuSH-Dark names [CC BY-NC-SA 3.0](https://creativecommons.org/licenses/by-nc-sa/3.0/) in addition to a permissive grant in the same file. Apply the noncommercial terms when redistributing that theme unless its author clarifies the grant. |
| Localizations and other XML resources | Original contributors' notices and attribution remain in the resource files. |
| Plugins | Added separately by users. Native plugins have their own terms. |

The notices also cover dependencies retained in the legacy Windows source.

When publishing a macOS binary, make the corresponding source archive from
the same revision available alongside it for the same download period.
The source includes the build scripts, the bundled library source and the XML
resources. Keep the license texts and attribution in the app and on the source
archive. Consult [GPLv3 §6](https://www.gnu.org/licenses/gpl-3.0.html#section6)
for other distribution arrangements. Check the terms of any added runtime,
plugin, or other components before including them in a release.
