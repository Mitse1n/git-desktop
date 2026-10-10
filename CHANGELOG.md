# Changelog

Notable changes are recorded here. The project is in early development; the app bundle's `0.1.0` version does not indicate a published release.

## Unreleased

### Added

- Drag the message/author and author/date boundaries anywhere in the log to resize adjacent columns, with resize cursors, minimum widths, and manual widths preserved through scrolling and refreshes.
- Rounded hover highlights for commit rows, preserving selection and current-branch shading while scrolling or refreshing the log.
- In-place hover expansion of truncated commit messages, authors, and dates over neighboring columns and panes, with window-bounded wrapping and a final `...` when the text exceeds the available height.
- Commit context-menu actions for undo, latest/earlier message editing, parent/child navigation, patch export, and read-only historical repository browsing.
- Native interactive rebase editor with reorder, pick, reword, squash, fixup, and drop; persistent messages and continue/skip/abort controls for paused operations.
- History-edit validation and regression coverage for preserving unrelated staging, root commits, annotated/binary patches, file modes, quoted paths, and conflict recovery.

- Native macOS Git client with history graph, branch management, selected-file commits, diffs, remotes, stash, and conflict tools.
- Dependency-free regression executable covering 35 core Git, diff, and graph scenarios.
- English and Simplified Chinese documentation, MIT license, contribution and security policies, and GitHub issue and pull request templates.
- macOS CI for regression checks, app packaging, signature verification, and downloadable development artifacts.

### Fixed

- Match IDEA's branch toolbar actions: the star marks/unmarks the selected favorite, and the target button navigates the log to the selected branch head. Disable them for invalid selections; keep favorite-only filtering in branch settings.
- Preserve all selected commit revisions when refreshed history inserts/reorders rows, show details for the topmost selected commit, and invalidate pending details when filtering removes the selection.
- Read Amend's message from HEAD independently of log filters, restore the previous draft when Amend is cancelled, and avoid overwriting edits typed while the message is loading.
- Keep whitespace comparison options when navigating files; prevent layout/option changes during loading from cancelling the requested diff or showing stale file contents. Keep an empty preview empty when changing options.
- Connect the Commit preview's previous/next file controls to its changed-file selection.

- Give Log, branch settings, and historical-file eye buttons their own functional view menus instead of unrelated shared actions. Persist display choices; support historical directory/module grouping, details visibility, and embedded diff preview with file navigation.
- Preserve selected commits when toggling Log appearance, reclaim hidden author/date column widths, and keep resizing valid when a neighboring column is hidden.
- Disable diff/staging/rollback actions for ignored entries while retaining Copy Path and Show in Finder; honor explicit context-menu disabled states. Clear stale diff counts and revision labels when selection disappears.

- Match the Commit eye menu to IDEA with Group By Directory/Module and Show Ignored Files, real collapsible grouping, persistent options, and ignored entries excluded from commit selections.
- Include `origin/main` and `origin/master` in default branch favorites so they sort above ordinary remote branches; show the current-branch marker before the favorite star and prioritize the current branch. Preserve explicitly saved favorite choices.
- Connect merge graph edges between commit centers so branch departures and convergence meet the commit dots instead of turning at row boundaries.
- Order graph tracks from branch ancestry, preserve that ordering through filters, and size the graph column from typical track density instead of the widest distant row.
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
