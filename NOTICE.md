# Notices

GitDesk is an independent project. It is not affiliated with or endorsed by JetBrains. IntelliJ IDEA and other third-party names belong to their respective owners.

`docs/idea-reference.png` and `docs/idea-diff.png` are reference screenshots of IntelliJ IDEA used to document interface research. Third-party interface artwork and trademarks in those screenshots are not licensed under this project's MIT License.

The diff editor bundles unmodified JetBrains Mono Regular and Italic fonts, copyright 2020 The JetBrains Mono Project Authors, under the SIL Open Font License 1.1. See `assets/fonts/OFL.txt`; the packaged app includes the same notice under `Contents/Resources/Fonts/`. The font assets are not covered by this project’s MIT license.

GitDesk uses macOS system fonts and SF Symbols through AppKit APIs. These system resources are provided by Apple and are not relicensed by this project. The app icon is rendered locally by `scripts/render-icon.swift` using a system symbol.

The terminal embeds SwiftTerm 1.20.0, copyright Miguel de Icaza and the contributors listed in its MIT license. The packaged app includes that license under `Contents/Resources/Licenses/SwiftTerm.txt`. The resolved Swift package graph also includes swift-argument-parser for SwiftTerm’s tooling; it is not linked into the GitDesk application. Git operations are delegated to the system installation of Git; Git itself is not bundled or relicensed by this repository.

File-type SVG icons in `assets/file-icons/` are unmodified IntelliJ Community platform icons, copyright JetBrains s.r.o. and contributors, provided under Apache License 2.0 (see `assets/file-icons/LICENSE-2.0.txt`). Their original source locations are `platform/icons/src/expui/fileTypes/` and `platform/icons/src/language/`. The app packages these icons and the license in `Contents/Resources/FileIcons/`; they are not covered by this project’s MIT License.
