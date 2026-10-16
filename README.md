# Notepad++ for macOS

### [Download Notepad++ for Mac (.dmg)](https://raw.githubusercontent.com/ashutosh1412/Notepad-for-Mac/main/build/NotepadPlusPlus.dmg)

Open the DMG and drag **Notepad++** to Applications. It's a universal app (Apple silicon and Intel) for macOS 11 Big Sur and later. The DMG is about 3.6 MB.

> The app isn't notarized yet. The first time you open it, right-click it and choose **Open**.
> The download link works once a release named with the file `NotepadPlusPlus.dmg` is published on GitHub (Releases > Draft a new release > attach `build/NotepadPlusPlus.dmg`).
> Unofficial: not affiliated with the Notepad++ project (notepad-plus-plus.org).

A fast, lightweight Notepad++-style editor for Mac, built with AppKit and Scintilla (the same editing engine as Notepad++). Menus, tab right-click menu and editor right-click menu follow the latest Notepad++.

## Features

- Tabs with pin, color and drag to reorder; session restore; recent files; Finder right-click **Open in Notepad++**
- Syntax highlighting and folding for about 95 languages; encodings (ANSI, UTF-8, UTF-8-BOM, UTF-16) and CR/LF/CRLF line endings
- Find / Replace / Find in Files / Mark with regex and extended modes; incremental search; bookmarks; change history
- Line operations, sorting, case conversion, multi-select, column editor, macros, Run menu, Monitoring (tail -f)
- Function List, Document Map, Document List, Folder as Workspace, Preferences, Style Configurator, Shortcut Mapper

Notepad++ plugins are Windows DLLs and can't run on macOS; simple JSON snippet packs are supported.

## Build from source

Needs the macOS Command Line Tools.

```bash
bash build.sh        # build/Notepad++.app
bash build-dmg.sh    # build/NotepadPlusPlus.dmg
bash tests/run.sh    # file-handling tests
bash tests/selftest.sh   # in-app command tests
```

To sign and notarize for distribution, set `SIGN_IDENTITY` and `NOTARY_PROFILE` (see the comments in `build-dmg.sh`).

## License

MIT. Scintilla and Lexilla keep their own license.
