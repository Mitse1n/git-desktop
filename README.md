# GitDesk

A native Git desktop client for macOS, built with Swift and AppKit.

[![CI](https://github.com/Mitse1n/git-desktop/actions/workflows/ci.yml/badge.svg)](https://github.com/Mitse1n/git-desktop/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift 6.0+](https://img.shields.io/badge/Swift-6.0%2B-orange)

English · [简体中文](README.zh-CN.md)

GitDesk brings commit history, branches, selected-file commits, and diffs into one native window. Its workflow is inspired by the Git tools in IntelliJ IDEA. It uses the system Git executable and has no third-party package dependencies.

**Status: early development.** Build from source using the instructions below. App bundles are ad-hoc signed, without Developer ID signing or notarization.

![GitDesk commit history, branch tree, graph, and file details](docs/gitdesk-log.png)

*Screenshots show a demo repository in an earlier development build; the current interface has since changed.*

## Features

- **Themes:** Island Dark, Island Light, Light, and Dark. Choose GitDesk → Settings… (⌘,) → Appearance, or View → Theme. Changes apply immediately to every window and persist across launches; Island themes round the outer tool window; internal panes stay flat with thin dividers.

- **History:** drag the message/author/date column boundaries to adjust widths, rounded commit-row hover highlights, in-place expansion of truncated messages/authors/dates with window-bounded wrapping and overflow ellipses, colored commit graph with consistent branch colors for dots and connections, ancestry-ordered tracks that remain correct for old branches beyond the visible log limit, connections meeting commit centers, and IDEA-style compact graph tracks with per-row message insets and arrows for edges spanning 30 or more displayed rows (toggle Long Edges in Log View Options), branch and tag decorations, a distinct current-branch marker and default favorites for local/origin main and master, text/hash search, regex and case options, branch/author/date/path filters, and first-parent history.
- **History actions:** undo the latest commit while preserving local/index changes, edit latest or earlier messages, parent/child navigation, patch export, and a read-only repository snapshot browser. A native interactive rebase editor supports reorder, pick, reword, squash, fixup, and drop.
- **Branches:** horizontal/vertical branch-tree scrolling, gray row hover highlights and window-bounded expansion of clipped names, grouped local/remote branches and tags, favorites, checkout, create, rename, delete, compare, merge, rebase, and worktrees. Branch pane settings control directory grouping, tag visibility, and single-click filtering or navigation to a branch head.
- **View options:** independent Log, branch, historical-file, and Commit menus. Log options control compact references, tag names, reference placement, author/date columns, and highlighting. Historical files support directory/module grouping (Control-P/Control-M), commit details visibility, and file counts. The right sidebar contains the file tree above compact commit details; open diffs with double-click or ⌘D. Display choices persist, and changing Log appearance retains selected commits.
- **Commits:** changes grouped by directory or detected IDEA module, click/Space inclusion with mixed group states, a resizable message area, stage/unstage, change previews, amend, message history, and commit and push. View options group by Directory/Module and show ignored files separately (ignored entries cannot be included in commits; their context menu offers Copy Path and Show in Finder while disabling diff, stage, unstage, and rollback); Module grouping reads IDEA module definitions and uses the repository as a single module when none exist; commit options set an optional author and sign-off trailer. Ordinary selected-file commits preserve unrelated staged changes using a temporary index.
- **Diffs:** side-by-side and unified views, line numbers, change navigation, search, whitespace options, and basic syntax highlighting.
- **Remotes:** clone, fetch, fast-forward-only pull, push, and remote configuration. Authentication uses existing Git/SSH/credential-helper configuration.

- **Repository tools:** initialize/open repositories, recent repositories, repository-local identity, stash, text conflict resolution, cherry-pick, revert, reset, and continue/abort operations.

History initially loads 2,000 commits and loads another batch as you scroll near the bottom, including filtered and search results. It stops at the end of the matching history. Refresh retains the loaded depth; changing filters starts a new first batch. History refresh preserves multiple selections by revision. The branch toolbar star toggles the selected favorite, and its target button locates that branch's tip in the log. Amend reads HEAD even when it is filtered out and restores the previous draft when cancelled. Commit previews support previous/next file navigation, and whitespace options stay active across files and layout changes.

<details>
<summary>Commit and diff screenshots</summary>

![GitDesk commit panel and file preview](docs/gitdesk-commit.png)

![GitDesk side-by-side diff](docs/gitdesk-diff.png)

</details>

## Requirements

- macOS 14 Sonoma or later.
- Swift 6.0 or later through Xcode or compatible Xcode Command Line Tools. The package currently uses Swift 5 language mode.
- System Git at `/usr/bin/git`.

Install Apple's developer command line tools if needed, then check your toolchain:

```sh
xcode-select --install
swift --version
git --version
```

Local verification has been performed on Apple Silicon with Swift 6.1.2. The build script targets the host architecture; it does not produce a universal binary.

## Quick start

```sh
git clone https://github.com/Mitse1n/git-desktop.git
cd git-desktop
swift run GitDesk /absolute/path/to/your/repository
```

Run `swift run GitDesk` without a path to restore the last repository, or use **File → Open Repository…** (`⌘O`).

To create and open an app bundle:

```sh
./scripts/build-app.sh
open dist/GitDesk.app
```

The bundle is generated locally; `dist/` and `.build/` are not committed. Use `./scripts/build-app.sh debug` for a debug bundle. A local ad-hoc signature is not a notarized distribution signature; macOS may show a security prompt when a bundle is transferred to another machine.

## Try a demo repository

```sh
./scripts/create-demo.sh
swift run GitDesk /tmp/gitdesk-demo
```

The demo includes branches, a merge, a tag, and uncommitted changes. An existing destination is left untouched. Pass a different path to the script to create another demo.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘N` | New empty window |
| `⌘O` | Open repository in the current window |
| `⌘K` | Commit panel |
| `⇧⌘K` | Push |
| `⌘T` | Pull |
| `⌘R` | Refresh |
| `⌘L` | Search text/hash |
| `⌘F` | Go to hash, branch, or tag |
| `⌘D` | Show diff |
| `⌥⌘N` | New branch |
| `⌘1` / `⌘2` | Log / Console |

Opening or choosing a recent repository replaces the project in the current window. Use **New Window** (`⌘N`) for another independent project window. Double-clicking a commit updates its selection and details without opening a diff window; use **Show Diff** or `⌘D` to open one explicitly.

## Editing history

Right-click a commit in Log to open the history actions. **Undo Commit** is available only for the current branch tip; it keeps the index and working files intact and restores the message in the Commit panel. **Edit Commit Message** on HEAD excludes unrelated staged files; earlier messages are changed through the rebase editor.

The rebase editor lists the selected commit through HEAD, oldest first. Use **Move Up / Move Down** to reorder rows and select Pick, Reword, Squash, Fixup, or Drop. Squash and Fixup combine with the preceding retained row; use the message area for Reword or a custom Squash message. Leaving the Squash message automatic combines the messages. Invalid plans can be corrected without losing edits.

Rebase requires a clean working tree, supports up to 10,000 commits, and rejects ranges containing merge commits. When conflicts pause an operation, the toolbar provides **Resolve Conflicts**, **Continue**, **Skip**, and **Abort**. Resolve and stage files before continuing. GitDesk keeps its message files in the worktree's Git directory so a paused rebase can continue after restarting the app. Rewriting history displays a warning when affected commits are reachable from local remote-tracking refs; this check does not fetch the server or implement hosting-provider branch protection. GitDesk does not force push.

**Create Patch** exports a Git-format patch for a normal/root commit, and a binary-capable first-parent diff for a merge. **Show Repository at Revision** browses files without checking out the revision; text previews are read only, capped at 2 MB, and do not follow symlinks or open submodules.

## Development

```sh
swift build
./scripts/test.sh
./scripts/build-app.sh
codesign --verify --deep --strict dist/GitDesk.app
```

`scripts/test.sh` runs a dependency-free regression executable, using temporary repositories and a local bare remote. It does not need XCTest, contact a network remote, or operate on existing repositories. Use this script rather than `swift test`; the checks are an executable target, not an XCTest target.

GitHub Actions runs these checks and bundles the app on Apple Silicon and Intel macOS runners. CI bundles are development artifacts for the corresponding architecture, not notarized releases.

| Path | Purpose |
| --- | --- |
| `Sources/GitDesk/` | AppKit windows, controllers, menus, themes, diffs and conflict UI |
| `Sources/GitDeskCore/` | Git processes, parsing, repository models, graph layout and text diffs |
| `Tests/GitDeskCoreTests/` | Regression executable (`GitDeskChecks`) |
| `scripts/` | App packaging, icon rendering, checks and demo generation |
| `docs/` | Screenshots and [verification notes](docs/verification.md) |

## Current limits

- Selected commits operate on whole files. Hunk/line staging, changelists/shelves, dedicated submodule/LFS management, signature verification, image diffs, and hosting-account integration are not implemented.
- Text conflict editing supports UTF-8 files; binary conflicts can use Accept Ours / Accept Theirs.
- Diff previews are limited to a combined 2 MB and 20,000 lines. Individual file reads are capped at 2 MB. Git subprocesses time out after 120 seconds.
- Git runs without interactive terminal input. Configure authentication before remote operations; failures appear in the UI/Console. Force push is not offered.
- Console keeps about 200,000 UTF-16 units of recent text and truncates individual command previews at 20,000 units. Git results used by the app are unaffected.
- This is an independent project, with no affiliation with JetBrains or IntelliJ IDEA.

## Contributing and support

Bug reports, small improvements, documentation, and regression cases are welcome. English and Chinese are both welcome.

- Read the [contribution guide](CONTRIBUTING.md) before opening a pull request.
- Report bugs or propose changes through [GitHub Issues](https://github.com/Mitse1n/git-desktop/issues).
- See [SECURITY.md](SECURITY.md) for sensitive reports.
- See [CHANGELOG.md](CHANGELOG.md) for project changes.

## License

GitDesk's source code and original documentation are available under the [MIT License](LICENSE). Third-party product names and reference screenshots retain their respective owners' rights; see [NOTICE.md](NOTICE.md).
