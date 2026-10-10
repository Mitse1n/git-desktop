# Changelog

Notable changes are recorded here. The project is in early development; the app bundle's `0.1.0` version does not indicate a published release.

## Unreleased

### Added

- Commit context-menu actions for undo, latest/earlier message editing, parent/child navigation, patch export, and read-only historical repository browsing.
- Native interactive rebase editor with reorder, pick, reword, squash, fixup, and drop; persistent messages and continue/skip/abort controls for paused operations.
- History-edit validation and regression coverage for preserving unrelated staging, root commits, annotated/binary patches, file modes, quoted paths, and conflict recovery.

- Native macOS Git client with history graph, branch management, selected-file commits, diffs, remotes, stash, and conflict tools.
- Dependency-free regression executable covering 32 core Git, diff, and graph scenarios.
- English and Simplified Chinese documentation, MIT license, contribution and security policies, and GitHub issue and pull request templates.
- macOS CI for regression checks, app packaging, signature verification, and downloadable development artifacts.

### Fixed

- Bound Console entries before main-thread delivery and cap retained text before insertion; avoid hidden-console scrolling and TextKit 2 viewport estimation that could hang large-repository branch filtering.
- Align titlebar repository and branch labels with the window controls, using regular text weight and tighter branch icon spacing.
- Reduce branch, tag, and Log filter latency by querying only filtered history and waking immediately when Git exits. Explicit and background refreshes continue to update the full repository state.
- Load the bundled app icon explicitly at launch so the Dock does not retain a generic placeholder.

### Changed

- Remove the Hide Git Branches chevron from the branch toolbar while keeping the other branch actions in place.
- Keep repository opening and recent-project switching in the current window; add independent empty project windows with Command-N and route menu actions to the active window. Commit double-clicks update details without opening a diff window.
- Rework the Commit panel around a separate toolbar, grouped changes with inline directory names, mixed inclusion checkboxes and Space/arrow-key navigation, a resizable message area, and IDEA-style amend and commit controls. Preserve tree selection while updating inclusion or refreshing.
- Add optional author and sign-off settings for ordinary, amended, and merge commits without bypassing Git hooks.
- Remove the outer left tool strip and give its space to the Git panel, with matching window margins.
- Replace the app icon with a white tile and layered cyan Git branch, packaged at all macOS icon sizes with transparent corners.
