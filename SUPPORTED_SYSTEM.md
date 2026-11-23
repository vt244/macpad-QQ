# macpad++ compatibility

| Component | Native macOS support |
| --- | --- |
| Platform | macOS 13 or later on Apple silicon and Intel. The app includes both architectures. |
| Documents | UTF‑8 and BOM-marked UTF‑16 are recognized before heuristic detection. Legacy detection uses uchardet and checks that the decoded text round-trips to the original bytes. Windows‑1252 is the fallback. Explicitly reopening in a chosen encoding overrides detection. |
| Editor window | Independent tab strips with vertical and multi-row modes, hover previews and a Control-Tab switcher for recent documents. The rotatable split supports cloned buffers and synchronized zoom. Use File to reopen a recently closed file and View to open or move a saved document to another instance. |
| Panels | Dock, resize or float the document list, file trees, three project panels, function list, document map, clipboard history and character panel. Panels on the same edge share a reorderable tab strip and can float together. Project XML accepts workspace-relative paths and mapped Windows paths. |
| Search | Literal, Extended and Boost.Regex modes. Search in a selection, open buffers, folders and projects or refine earlier results. Set the thresholds for automatic selection scope and filling the Find field, and choose a monospaced font for dialog inputs. Five token styles support marking, navigation and copying. Volatile searches leave the previous query and history intact. Search by Unicode code point or range. Batch replacement preserves encodings and checks for stale changes. |
| Editing | Select text or columns in two steps, convert tabs and spaces, change case, insert a date using a custom format and copy the paths of open files. Jump to matching braces, adjust multiple selections, open a selected path, search with a custom search provider or redact text. Paste HTML or RTF source from the macOS clipboard and transfer binary text bytes between macpad++ documents. |
| Syntax highlighting | Built-in Lexilla languages and UDL XML 2.0 and 2.1. Edit, copy and remove definitions in the form or dockable panel. Changes to bundled definitions are saved in the profile. Function List and Auto-Completion accept bundled and profile XML rules. |
| Theme XML | Lexer styles, global overrides, fonts, editor and tab colors, selection and caret colors, fold markers and margins in the editor and search results, bookmark margins, change history, end-of-line marker colors, search status messages and the document map. Choose the end-of-line marker style under **Preferences → Editor guides**. The Style Configurator edits a copy in the profile. Some Windows GUI entries have no native equivalent. |
| Translation and menu XML | Matching menus, dialogs and panels use translation XML, including preferences, Save All confirmation and search status strings. Nine languages include supplemental native strings, with coverage varying by language. For custom strings, add `MacpadStrings` under `Native-Langue` or put `native-labels/<language>.plist` in the profile. Use keys such as `native-text:English text` for matching strings or `Find:1632` for a specific control. |
| Preferences and backups | Import supported editing, printing, tab, toolbar, search, backup, session and layout settings from `config.xml`. The original is retained as `imported-config.xml`. Editor Guides settings support current-line highlighting, wrapped-line indentation and multiple rulers. Save All confirmation is configurable. Simple or versioned backups preserve the previous file contents. |
| Sessions | Load and save session XML for saved files, including both panes, active view, selection, scroll position, bookmarks, and collapsed folds. |
| Workspace recovery | The profile remembers open documents, unsaved text, and the two-pane layout. If a file changed on disk while the app was closed, the recovered edits open in a separate untitled tab. |
| Macros | Record and replay supported editing and search actions, including search sequences from `shortcuts.xml`. Use Shortcut Mapper to assign native shortcuts. |
| Tools and Run | MD5, SHA‑1, SHA‑256 and SHA‑512. Save named macOS commands with active-document placeholders and assign them shortcuts. |
| Printing | Set print colors, line numbers, margins, header and footer templates and fonts, and form-feed page breaks. Print Now uses the selected printer. |
| Terminal | Run the executable with `--help` for options. Quote wildcard paths and add `-r` for recursion. `-fullReadOnly` and `-monitoringMode` also apply to later file opens. `-fullReadOnlySavingForbidden` blocks editor file saves after clearing read-only mode. `-x`, `-y` and `-titleAdd` configure the launch window. |
| Plugins | Plugins Admin supports local and catalog installation and version updates. ABI v2 adds document access, events, panels and multiple commands. ABI v1 selection plugins remain supported. Windows DLLs require the Windows editor. |

The macOS port uses native AppKit shortcuts and dialogs. Compatibility varies
for Windows-specific commands, unsupported XML options and older plugin APIs.
The legacy Windows source and build instructions are available in [BUILD.md](BUILD.md).

## Map Windows paths

Put a property list named `windowsPathMappings.plist` in the macpad++ profile. Each
key is a drive or UNC prefix. Each value is a local absolute directory.
For example, `C:` can map to `/Volumes/Windows` and `//server/share` can map to
`/Volumes/share`. More specific prefixes take precedence. A project saved
after opening mapped files keeps the original Windows paths.
