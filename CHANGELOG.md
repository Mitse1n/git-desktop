# Changelog

Notable changes are recorded here. The project is in early development; the app bundle's `0.1.0` version does not indicate a published release.

## Unreleased

### Added

- IDEA-style compact history graphs: fold edges spanning 30 or more displayed rows into endpoint arrows, repack visible tracks, show continuation arrows at page boundaries, and persist the Long Edges view option. Let wide rows extend into the subject cell with per-row text/hover insets and use a subdued branch palette.

- IDEA-style branch-tree hover highlights and full-name expansion over neighboring panes, bounded by the window. Horizontal scrolling follows expanded branch widths and preserves the scroll position on refresh; collapse and filtering reclaim unused space.

- Four IDEA-inspired themes (Island Dark, Island Light, Light, Dark) with live application-wide switching in Appearance settings (⌘,) and View → Theme, persisted preferences, light/dark diff and syntax colors, and rounded outer Island tool windows. Switching preserves repository state, selected commits/files, drafts, and loaded diffs.

- Drag the message/author and author/date boundaries anywhere in the log to resize adjacent columns, with resize cursors, minimum widths, and manual widths preserved through scrolling and refreshes.
- Rounded hover highlights for commit rows, preserving selection and current-branch shading while scrolling or refreshing the log.
- In-place hover expansion of truncated commit messages, authors, and dates over neighboring columns and panes, with window-bounded wrapping and a final `...` when the text exceeds the available height.
- Commit context-menu actions for undo, latest/earlier message editing, parent/child navigation, patch export, and read-only historical repository browsing.
- Native interactive rebase editor with reorder, pick, reword, squash, fixup, and drop; persistent messages and continue/skip/abort controls for paused operations.
- History-edit validation and regression coverage for preserving unrelated staging, root commits, annotated/binary patches, file modes, quoted paths, and conflict recovery.

- Native macOS Git client with history graph, branch management, selected-file commits, diffs, remotes, stash, and conflict tools.
- Dependency-free regression executable covering 47 core Git, diff, and graph scenarios.
- Reusable local performance benchmarks with frozen source/probe snapshots, memory high-water marks, and four-theme rendering comparisons.
- English and Simplified Chinese documentation, MIT license, contribution and security policies, and GitHub issue and pull request templates.
- macOS CI for regression checks, app packaging, signature verification, and downloadable development artifacts.

### Fixed

- Load older log and search results when scrolling near the bottom, with end detection, stale-request guards, and selection/viewport preservation. Reset the loading depth when filters change and retain it on refresh.

- Inset branch-tree disclosure arrows and content together so selected top-level groups retain padding inside their rounded highlight; include the inset when sizing long branch rows.

- Match IDEA's current-branch log highlighting: suppress the background when filtering to HEAD or the checked-out branch and in detached HEAD; use dedicated theme colors instead of selection blue.

- Use rounded selection highlights in historical changed-file trees and open the selected file's existing Diff window with Space, without treating key repeats or modified Space as preview requests.

- Match branch-row selection backgrounds to the existing rounded hover highlight, including viewport insets while horizontally scrolling.

- Reuse Diff calculations when switching layouts, cancel obsolete work, and accelerate exact ordered/unique-line comparisons while preserving original alignment for ambiguous input. Avoid rebuilding unchanged history during working-tree refreshes, prepare history presentation off the main thread, and cache ancestry with ref/boundary invalidation and concurrent-update publication guards.

- Make truncated author/date hover expansion respond across the full metadata cell, pass label pointer events through to the log, and allow expansion in visible inactive windows.

- Keep graph ancestry independent of the visible log limit. Old branch filters retain main-line tracks, nested merge ordering, distinct branch colors, and current-branch shading even when none of their commits are in the recent log. Cache lightweight parent links on repository refresh and reuse them when filtering.

- Align the Log sidebar with IDEA: changed-file tree above compact commit details, no embedded historical diff or duplicate hash header, and flat internal panes with thin dividers across all four themes. Keep double-click/⌘D diff windows.

- Keep commit graph dots and connections on the same branch color through shared ancestors, passing lanes, merges, and filtered history. Remove per-row UI recoloring that could split a connection into different colors.

- Match IDEA's branch toolbar actions: the star marks/unmarks the selected favorite, and the target button navigates the log to the selected branch head. Disable them for invalid selections; keep favorite-only filtering in branch settings.
- Preserve all selected commit revisions when refreshed history inserts/reorders rows, show details for the topmost selected commit, and invalidate pending details when filtering removes the selection.
- Read Amend's message from HEAD independently of log filters, restore the previous draft when Amend is cancelled, and avoid overwriting edits typed while the message is loading.
- Keep whitespace comparison options when navigating files; prevent layout/option changes during loading from cancelling the requested diff or showing stale file contents. Keep an empty preview empty when changing options.
- Connect the Commit preview's previous/next file controls to its changed-file selection.

- Give Log, branch settings, and historical-file eye buttons their own functional view menus instead of unrelated shared actions. Persist display choices; support historical directory/module grouping, details visibility, and file counts.
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
