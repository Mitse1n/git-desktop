# Changelog

Notable changes are recorded here. The project is in early development; the app bundle's `0.1.0` version does not indicate a published release.

## Unreleased

### Added

- Commit context-menu actions for undo, latest/earlier message editing, parent/child navigation, patch export, and read-only historical repository browsing.
- Native interactive rebase editor with reorder, pick, reword, squash, fixup, and drop; persistent messages and continue/skip/abort controls for paused operations.
- History-edit validation and regression coverage for preserving unrelated staging, root commits, annotated/binary patches, file modes, quoted paths, and conflict recovery.

- Native macOS Git client with history graph, branch management, selected-file commits, diffs, remotes, stash, and conflict tools.
- Dependency-free regression executable covering 31 core Git, diff, and graph scenarios.
- English and Simplified Chinese documentation, MIT license, contribution and security policies, and GitHub issue and pull request templates.
- macOS CI for regression checks, app packaging, signature verification, and downloadable development artifacts.

### Fixed

- Reduce branch, tag, and Log filter latency by querying only filtered history and waking immediately when Git exits. Explicit and background refreshes continue to update the full repository state.
- Load the bundled app icon explicitly at launch so the Dock does not retain a generic placeholder.

### Changed

- Replace the app icon with a white tile and layered cyan Git branch, packaged at all macOS icon sizes with transparent corners.
