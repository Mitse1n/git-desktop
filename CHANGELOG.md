# Changelog

Notable changes are recorded here. The project is in early development; the app bundle's `0.1.0` version does not indicate a published release.

## Unreleased

### Added

- Native macOS Git client with history graph, branch management, selected-file commits, diffs, remotes, stash, and conflict tools.
- Dependency-free regression executable covering 23 core Git, diff, and graph scenarios.
- English and Simplified Chinese documentation, MIT license, contribution and security policies, and GitHub issue and pull request templates.
- macOS CI for regression checks, app packaging, signature verification, and downloadable development artifacts.

### Fixed

- Reduce branch, tag, and Log filter latency by querying only filtered history and waking immediately when Git exits. Explicit and background refreshes continue to update the full repository state.
