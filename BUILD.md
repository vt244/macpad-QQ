# Building macpad++

## macOS

With Apple Command Line Tools and CMake 3.20 or later, run from the repository root:

```sh
macos/build-app.sh
```

The script builds and ad hoc signs the universal native app at `dist/macpad++.app`.
Open it in Finder, or run `open 'dist/macpad++.app'`. The app uses a profile
under `~/Library/Application Support/macpad++/`. For an isolated run, set
`MACPAD_DATA_DIR` to an absolute profile path in the launch environment.

Run the smoke test in a macOS graphical session:

```sh
macos/test-app.sh
```

It checks panel docking, tab transfers and split rotation, document I/O, XML resources,
search scopes and history, editing commands, macro playback, native plugins and
session recovery through quit and relaunch.
The [macOS workflow](.github/workflows/macos.yml) builds, tests and archives
the app with its corresponding source.

### Prepare a GitHub release

1. Resolve the app icon and theme redistribution terms recorded in
   [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
2. Run the macOS workflow for the exact commit to release. Download its
   `macpad-macOS-with-source` artifact and extract it.
3. Verify both archives with `shasum -a 256 -c SHA256SUMS`. The archive
   `macpad++-macOS.zip` contains the app and its license notices.
   `macpad++-source.zip` contains the source from the same commit.
4. Attach both archives and `SHA256SUMS` to a draft release whose tag
   points to that commit. Keep the source available alongside the app.
   If the release app is signed with Developer ID and notarized separately,
   recreate its archive and regenerate the checksum before publishing.
   [GitHub release documentation](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)

### Native plugins

Implement the entry point and callbacks in [MacpadPlugin.h](macos/MacpadPlugin.h).
[SelectionPlugin.c](macos/tests/SelectionPlugin.c) demonstrates reading and
replacing the current selection with ABI v1. The bundled
[Document Tools](macos/plugins/DocumentTools.mm) uses ABI v2 for multiple
commands, document events and an AppKit panel. To build the v1 example for both architectures:

```sh
mkdir -p .tmp
xcrun clang -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
  -I macos macos/tests/SelectionPlugin.c -o .tmp/SelectionPlugin.dylib
```

Copy a plugin you trust into the `plugins/` directory in the macpad++ profile
and restart the app. Plugins run in the editor process with its permissions.
ABI v2 host callbacks are valid during the synchronous command or event call
on the main thread. Panel views are retained while open.

Export `macpad_plugin_v3` for ABI v3. Pass the host's `v2.context` to callbacks.
The v3 host provides selection and UTF-8 byte-range access, document flags and
language, document activation and additional events for saves, selections,
path changes and language changes. Use stable UTF-8 plugin and command IDs
without slashes to preserve native shortcut assignments across renames.

In the optional v3 `onReady` callback, register toolbar buttons and any
Windows module and command IDs used by the original plugin. Check
`MacpadEditorV3.structSize` before calling optional host functions. Marker
and indicator reservation returns the first contiguous ID, or `-1` if the
range is unavailable. Pass a notification mask to `subscribeToEditor` to
receive the corresponding snapshots in `onEditorNotification`. The event
data is valid for the duration of its callback.

**Plugins → Plugin Catalog Source…** accepts a local JSON manifest or an HTTPS
manifest URL. The manifest contains a `plugins` array with `name`, `version`,
`file` (a dylib basename), `url` (absolute or relative to the manifest), and
`sha256` (the packaged library's SHA-256 digest). Increment the version when
publishing an update. The build generates the bundled manifest after signing
the library.

## Windows editor build

### Microsoft Visual Studio

**Pre-requisites:**

- Microsoft Visual Studio 2022 version 17.5 (C/C++ Compiler, v143 toolset for win32, x64, arm64)

There are three components which are built from one visual studio solution:

- `notepad++.exe`: (contains `libSciLexer.lib`)
- `libScintilla.lib` : static library based on [Scintilla](https://www.scintilla.org/)
- `libLexilla.lib` : static library based on [Lexilla](https://www.scintilla.org/Lexilla.html)

The editor is built **with** Boost regex PCRE support instead of default c++11 regex ECMAScript used by plain Scintilla.

#### Build `notepad++.exe`

 1. Open [`PowerEditor\visual.net\notepadPlus.sln`](https://github.com/notepad-plus-plus/notepad-plus-plus/blob/master/PowerEditor/visual.net/notepadPlus.sln)
 2. Select a solution configuration (Debug or Release) and a solution platform (x64 or Win32 or ARM64)
 3. Build the editor solution like a normal Visual Studio project. This will also build the dependent Scintilla and Lexilla projects.

#### Build `libScintilla.lib` and `libLexilla.lib`

As mentioned above, you'll need `libScintilla.lib` and `libLexilla.lib` for the macpad++ editor build. This is done automatically on building the whole solution. So normally you don't need to care about this.

##### Build `libScintilla.lib` with boost and `libLexilla.lib` via nmake

This is not necessary any more and just here for completeness as this option is still available.
Boost is taken from [boost 1.92.0](https://www.boost.org/users/history/version_1_92_0.html) and stripped down to the project needs available at [boost](https://github.com/notepad-plus-plus/notepad-plus-plus/tree/master/boostregex/boost) in this repo.

1. Open the Developer Command Prompt for Visual Studio
2. Go into the [`scintilla\win32\`](https://github.com/notepad-plus-plus/notepad-plus-plus/blob/master/scintilla/win32/)
3. Use the same configuration as the Windows editor:
   - Release: `nmake -f scintilla.mak`
   - Debug: `nmake DEBUG=1 -f scintilla.mak`
   - Example:
   `nmake -f scintilla.mak`
4. Go into the [`lexilla\src\`](https://github.com/notepad-plus-plus/notepad-plus-plus/tree/master/lexilla/src/)
5. Use the same configuration as the Windows editor:
   - Release: `nmake -f lexilla.mak`
   - Debug: `nmake DEBUG=1 -f lexilla.mak`

#### History

More about the previous build process: <https://community.notepad-plus-plus.org/topic/13959/building-notepad-with-visual-studio-2015-2017>

Upstream releases 6.0 through 7.9.5 used Boost.Regex in the separately distributed `SciLexer.dll`.

### GCC

If you have [MinGW-w64](https://www.mingw-w64.org/) installed, you can compile the Windows editor with GCC. Otherwise MinGW-w64 can be downloaded [here](https://sourceforge.net/projects/mingw-w64/files/). You can also download some collection of tools which supports MinGW-w64, like [MSYS2](https://www.msys2.org/) or [WinLibs](https://winlibs.com/).

The upstream Windows editor build is regularly tested on a Windows system by using [MSYS2](https://www.msys2.org/) project. Current versions of tools used to building (such as GCC, Clang, Make or Bash) can be checked by looking at some logs from the finished building (for example in the [current-build page](https://github.com/notepad-plus-plus/notepad-plus-plus/actions/workflows/CI_build.yml)). Other versions may also work but are untested.

**Note:** Before building make sure that the system `PATH` environment variable contains `$MinGW-root$\bin` directory. Otherwise you have to set this directory yourself in Windows settings. You can also use a command like `set PATH=$MinGW-root$\bin;%PATH%` each time `cmd` is launched. But beware that if `PATH` contains several versions of MinGW-w64 GCC, only the first one will be usable.

#### Compiling the Windows editor

1. Launch `cmd` and add `$MinGW-root$\bin` to `PATH` if necessary.
2. `cd` into `notepad-plus-plus\PowerEditor\gcc`.
3. Run `mingw32-make`.
4. The 32-bit or 64-bit `notepad++.exe` will be generated either in `bin.i686` or in `bin.x86_64` directory respectively, depending on the target CPU of the compiler — look for the full path to the resulting binary at the end of the build process.

##### Some additional information

- The directory containing `notepad++.exe` will also contain everything needed for the Windows editor to start.
- To have a debug build just add `DEBUG=1` to the `mingw32-make` invocation above. The output directory then will be suffixed with `-debug`.
- To see commands being executed add `VERBOSE=1` to the same command.
- When a project is built outside of the `PowerEditor/gcc` directory, for example when using `-f` option, then the entire project path must not contain any spaces. Additionally, the path to `makefile` of this project should be listed as first.
- When a project is built through MinGW-w64 with multilib support, a specific target can be forced by passing `TARGET_CPU` variable with `x86_64` or `i686` as value.
- To use Clang instead of GCC for compilation provide `CXX` variable with `clang++` as value.
- To use [Clang analyzer](https://clang-analyzer.llvm.org/) together with Clang provide `CLANGANALYZE=1` to the `mingw32-make` invocation.
