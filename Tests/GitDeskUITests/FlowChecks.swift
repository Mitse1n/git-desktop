import AppKit
import GitDeskCore

func runFlowChecks() throws {
  var failures: [String] = []
  func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message); print("FAIL " + message) }
  }
  func drain(_ queue: DispatchQueue) {
    // File delivery can schedule a second background job to compute the diff.
    for _ in 0..<2 {
      var done = false
      queue.async { DispatchQueue.main.async { done = true } }
      let deadline = Date().addingTimeInterval(15)
      while !done && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
      }
      precondition(done, "Background operation timed out")
    }
  }
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gitdesk-flows-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repo = GitRepository(directory: directory)
  try repo.run(["init", "-b", "main"])
  try repo.run(["config", "user.name", "Flow Test"])
  try repo.run(["config", "user.email", "flow@example.test"])
  try repo.run(["config", "commit.gpgsign", "false"])
  try repo.run(["config", "core.hooksPath", "/dev/null"])
  func write(_ path: String, _ text: String) throws {
    try Data(text.utf8).write(to: directory.appendingPathComponent(path))
  }
  func commit(_ message: String) throws {
    try repo.run(["add", "."])
    try repo.run(["commit", "--allow-empty", "-m", message])
  }
  try write("first.txt", "one\ntwo\nthree\n")
  try write("space.txt", "value = 1\n")
  try commit("Initial")
  try commit("Current subject\n\nCurrent body")
  let head = try repo.commit(at: "HEAD")
  try repo.run(["branch", "feature/older", "HEAD~1"])
  let longBranch = "feature/" + String(repeating: "very-long-branch-中文-", count: 10)
  try repo.run(["branch", longBranch, "HEAD~1"])
  try write("first.txt", "ONE\ntwo\nTHREE\n")
  try write("space.txt", "value   = 1\n")
  let changes = try repo.status()
  let first = changes.first { $0.path == "first.txt" }!
  let space = changes.first { $0.path == "space.txt" }!

  let viewer = DiffViewController()
  viewer.load(repository: repo, change: first)
  drain(viewer.queue)
  viewer.whitespace.state = .on
  viewer.optionsChanged()
  drain(viewer.queue)
  viewer.load(repository: repo, change: space)
  drain(viewer.queue)
  check(viewer.diff?.changes.isEmpty == true && viewer.countLabel.stringValue == "Differences ignored",
    "Ignore whitespace survives file navigation")

  // Hold I/O so changing layout/options occurs while the next file is loading.
  let gate = DispatchSemaphore(value: 0)
  viewer.queue.async { gate.wait() }
  viewer.load(repository: repo, change: first)
  viewer.layoutToggle.selectedSegment = 1
  viewer.optionsChanged()
  viewer.whitespace.state = .off
  viewer.optionsChanged()
  gate.signal()
  drain(viewer.queue)
  drain(viewer.queue)
  check(String(decoding: viewer.after, as: UTF8.self) == "ONE\ntwo\nTHREE\n",
    "Changing diff options during loading keeps the requested file")
  check(viewer.diff?.identical == false && !viewer.unifiedLines().isEmpty,
    "Changing diff layout during loading renders the requested diff")
  viewer.clear()
  viewer.optionsChanged()
  drain(viewer.queue)
  check(viewer.diff == nil && viewer.emptyLabel.stringValue == "Select a file to view its changes",
    "Changing options without a file preserves the empty state")

  let oldPreviewPreference = UserDefaults.standard.object(forKey: "detailShowDiffPreview")
  UserDefaults.standard.set(true, forKey: "detailShowDiffPreview")
  defer {
    if let oldPreviewPreference { UserDefaults.standard.set(oldPreviewPreference, forKey: "detailShowDiffPreview") }
    else { UserDefaults.standard.removeObject(forKey: "detailShowDiffPreview") }
  }
  let controller = RepositoryController()
  let savedFavorites = UserDefaults.standard.object(forKey: "favoriteRefs")
  defer {
    if let savedFavorites { UserDefaults.standard.set(savedFavorites, forKey: "favoriteRefs") }
    else { UserDefaults.standard.removeObject(forKey: "favoriteRefs") }
  }
  _ = controller.view
  check(controller.detailsSplit?.arrangedSubviews.count == 2
    && controller.detailsSplit?.arrangedSubviews.first is Surface,
    "Log sidebar contains only files and details, even with an old diff-preview preference")
  let shortDetails = CommitDetails.text(for: Commit(hash: head.hash, parents: head.parents,
    author: head.author, email: head.email, subject: "Subject"))
  check(shortDetails.string.hasPrefix("Subject\n\n\(head.shortHash) \(head.author)")
    && !shortDetails.string.contains("Parents:"),
    "Commit metadata follows the subject without blank body sections or a separate hash header")
  let emailRange = (shortDetails.string as NSString).range(of: "<\(head.email)>")
  check(shortDetails.attribute(.link, at: emailRange.location, effectiveRange: nil) is URL,
    "Commit email remains an actionable link")
  check(CommitDetails.text(for: head).string.hasPrefix("Current subject\n\nCurrent body\n\n"),
    "Commit details preserve the full message body")
  controller.watcher?.invalidate()
  controller.repository = repo
  var filtered = LogFilter()
  filtered.text = "Initial"
  controller.snapshot = try repo.snapshot(filter: filtered)
  controller.updateUI()
  controller.amend.state = .on
  controller.amendChanged()
  drain(controller.queue)
  check(controller.commitMessage.string == head.fullMessage,
    "Amend loads HEAD's message even when the log filter hides HEAD")
  controller.commitMessage.string = ""
  let amendGate = DispatchSemaphore(value: 0)
  controller.queue.async { amendGate.wait() }
  controller.amendChanged()
  controller.commitMessage.string = "New draft while reading HEAD"
  amendGate.signal()
  drain(controller.queue)
  check(controller.commitMessage.string == "New draft while reading HEAD",
    "Delayed Amend delivery never overwrites a newly typed draft")
  controller.amend.state = .off
  controller.amendChanged()
  check(controller.commitMessage.string.isEmpty, "Cancelling Amend restores the previous empty draft")
  controller.commitMessage.string = "Original draft"
  controller.amend.state = .on
  controller.amendChanged()
  drain(controller.queue)
  check(controller.commitMessage.string == head.fullMessage,
    "Amend temporarily replaces an existing draft with HEAD's message, as in IDEA")
  controller.amend.state = .off
  controller.amendChanged()
  check(controller.commitMessage.string == "Original draft", "Cancelling Amend restores the original draft")

  controller.snapshot = try repo.snapshot()
  controller.updateUI()
  controller.logTable.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
  check(controller.selectedCommit?.hash == head.hash,
    "Multiple selection shows the topmost selected commit, as in IDEA")
  let selected = Set(controller.snapshot!.commits.map(\.hash))
  try commit("New commit above selection")
  controller.snapshot = try repo.snapshot()
  controller.updateUI()
  let refreshed = Set(controller.logTable.selectedRowIndexes.map { controller.snapshot!.commits[$0].hash })
  check(refreshed == selected, "Refreshing preserves every selected commit by hash")
  drain(controller.queue)

  check(controller.branchHeadButton?.isEnabled == false,
    "Branch-head navigation stays disabled without a branch selection")
  let branchRow = (0..<controller.branchOutline.numberOfRows).first {
    (controller.branchOutline.item(atRow: $0) as? BranchNode)?.branch?.name == "feature/older"
  }!
  controller.branchOutline.selectRowIndexes(IndexSet(integer: branchRow), byExtendingSelection: false)
  check(controller.branchHeadButton?.isEnabled == true, "Selecting a branch enables head navigation")
  controller.navigateSelectedBranchHead()
  drain(controller.queue)
  let branchHead = try repo.resolve("feature/older")
  check(controller.selectedCommit?.hash == branchHead,
    "Branch-head navigation selects that branch's tip in the log")
  check(controller.selectedBranch?.name == "feature/older" && controller.filter.branch == nil,
    "Branch-head navigation preserves branch selection and an unfiltered log")
  let olderBranch = controller.selectedBranch!
  let wasFavorite = controller.favoriteRefs.contains(olderBranch.fullRef)
  controller.branchFavoriteButton?.handler?()
  check(controller.favoriteRefs.contains(olderBranch.fullRef) != wasFavorite && !controller.favoriteOnly,
    "The branch star toggles the selected branch's favorite instead of filtering branches")
  check(controller.selectedBranch?.fullRef == olderBranch.fullRef,
    "Toggling a branch favorite preserves its selection")
  controller.branchFavoriteButton?.handler?()
  check(controller.favoriteRefs.contains(olderBranch.fullRef) == wasFavorite,
    "The branch star can unmark the same favorite")

  // A filtered-out selection must also invalidate already queued detail reads.
  let detailsGate = DispatchSemaphore(value: 0)
  controller.queue.async { detailsGate.wait() }
  controller.logTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
  var empty = LogFilter()
  empty.text = "no matching commit"
  controller.snapshot = try repo.snapshot(filter: empty)
  controller.updateUI()
  detailsGate.signal()
  drain(controller.queue)
  check(controller.selectedCommit == nil && controller.detailFiles.isEmpty && controller.loadedDetailHash == nil,
    "Filtered-out commits cannot restore stale details after loading")

  try write("first.txt", "ONE\ntwo\nTHREE\nfour\n")
  try write("space.txt", "new value\n")
  controller.snapshot = try repo.snapshot()
  controller.updateUI()
  let firstRow = controller.workingRows.firstIndex { $0.file?.path == "first.txt" }!
  controller.changesTable.selectRowIndexes(IndexSet(integer: firstRow), byExtendingSelection: false)
  controller.previewWorkingDiff()
  check(controller.inlineDiff?.nextFile != nil && controller.inlineDiff?.previousFile != nil,
    "Commit preview file navigation is connected")
  controller.inlineDiff?.nextFile?()
  check(controller.inlineDiff?.titleLabel.stringValue == "space.txt",
    "Next File changes both the Commit selection and its preview")
  controller.inlineDiff?.previousFile?()
  check(controller.inlineDiff?.titleLabel.stringValue == "first.txt",
    "Previous File returns to the preceding changed file")
  if let preview = controller.inlineDiff { drain(preview.queue) }
  let originalTheme = Theme.current
  defer { Theme.apply(originalTheme, persist: false) }
  let defaults = UserDefaults(suiteName: "GitDeskThemeChecks." + UUID().uuidString)!
  defaults.set("unknown-theme", forKey: "appearanceTheme")
  check(AppTheme.saved(in: defaults) == .dark, "Unknown theme falls back to Dark")
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentViewController = controller
  window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
  window.orderFront(nil)
  controller.view.layoutSubtreeIfNeeded()
  controller.split.setPosition(320, ofDividerAt: 0)
  controller.split.setPosition(850, ofDividerAt: 1)
  controller.view.layoutSubtreeIfNeeded()
  let outline = controller.branchOutline
  outline.fitContentWidth()
  let branchScroll = outline.enclosingScrollView!
  let branchClip = branchScroll.contentView
  check(branchScroll.hasHorizontalScroller && outline.frame.width > branchClip.bounds.width,
    "Expanded long branches make the branch tree horizontally scrollable")
  func rowForBranch(_ name: String) -> Int {
    (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? BranchNode)?.branch?.name == name }!
  }
  func hoverBranch(_ row: Int) {
    outline.scrollRowToVisible(row)
    outline.layoutSubtreeIfNeeded()
    _ = outline.rowView(atRow: row, makeIfNecessary: true)
    outline.view(atColumn: 0, row: row, makeIfNecessary: true)?.layoutSubtreeIfNeeded()
    outline.layoutSubtreeIfNeeded()
    let point = outline.convert(NSPoint(x: outline.visibleRect.minX + 8,
      y: outline.rect(ofRow: row).midY), to: nil)
    let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
      clickCount: 0, pressure: 0)!
    outline.mouseMoved(with: event)
  }
  let longRow = rowForBranch(longBranch)
  let branchSelection = outline.selectedRowIndexes
  hoverBranch(longRow)
  check(outline.hoveredRow == longRow
    && (outline.rowView(atRow: longRow, makeIfNecessary: false) as? SelectionRow)?.isHovered == true,
    "Hover highlights the branch row without selecting it")
  check(outline.selectedRowIndexes == branchSelection && outline.expansionView != nil,
    "Clipped branch names expand without changing selection")
  if let expanded = outline.expansionView, let content = window.contentView {
    check(content.bounds.contains(expanded.frame) && expanded.textLayout.lines.count > 1,
      "Long branch expansion wraps within the window")
    check(expanded.hitTest(.zero) == nil, "Branch expansion passes clicks through")
    check(expanded.fillColor.alphaComponent == 1, "Branch expansion covers neighboring content with an opaque gray fill")
  }
  hoverBranch(rowForBranch("main"))
  check(outline.expansionView == nil, "Short branch names do not create an expansion")
  branchClip.scroll(to: NSPoint(x: 100, y: branchClip.bounds.minY))
  branchScroll.reflectScrolledClipView(branchClip)
  check(branchClip.bounds.minX > 0, "The branch tree actually scrolls horizontally")
  controller.rebuildBranches()
  check(branchClip.bounds.minX > 0, "Branch refresh preserves horizontal scroll position")
  outline.collapseItem(nil, collapseChildren: true)
  outline.fitContentWidth()
  check(outline.frame.width == branchScroll.contentSize.width && branchClip.bounds.minX == 0
    && outline.expansionView == nil, "Collapsing branches shrinks content and clears clipped expansions")
  outline.expandItem(nil, expandChildren: true)
  outline.fitContentWidth()
  controller.branchSearch.stringValue = "older"
  controller.rebuildBranches()
  check(outline.frame.width == branchScroll.contentSize.width,
    "Filtering out long branches removes excess horizontal scroll space")
  controller.branchSearch.stringValue = ""
  controller.rebuildBranches()
  NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
  check(outline.expansionView == nil, "Changing focus dismisses the old branch expansion")
  window.orderOut(nil)
  hoverBranch(rowForBranch(longBranch))
  check(outline.expansionView == nil, "A hidden window never creates a branch expansion")
  print("Branch hover: highlight, bounded expansion, click-through, horizontal scrolling, refresh, collapse and filtering passed")
  let diffWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
    styleMask: [.titled], backing: .buffered, defer: false)
  diffWindow.isReleasedWhenClosed = false
  diffWindow.contentViewController = viewer
  defer { window.close(); diffWindow.close(); defaults.removeObject(forKey: "appearanceTheme") }
  viewer.load(repository: repo, change: first)
  drain(viewer.queue)
  controller.commitMessage.string = "Theme switch draft 中文🙂"
  controller.logTable.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
  drain(controller.queue)
  let selection = controller.logTable.selectedRowIndexes
  let workingSelection = controller.changesTable.selectedRowIndexes
  let diffContents = viewer.after
  let settings = AppearanceWindowController()
  defer { settings.close() }
  let menu = ThemeMenu()
  for theme in AppTheme.allCases {
    defaults.set(theme.rawValue, forKey: "appearanceTheme")
    check(AppTheme.saved(in: defaults) == theme, "Theme preference round trips: " + theme.title)
    Theme.apply(theme, persist: false)
    check(NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (theme.isDark ? .darkAqua : .aqua),
      "Native appearance updates: " + theme.title)
    check(controller.mainBody.layer?.cornerRadius == (theme.isIsland ? 10 : 0),
      "Island panel geometry updates: " + theme.title)
    check(controller.detailsSplit?.dividerThickness == 1 && controller.split.dividerThickness == 1
      && controller.detailsSplit?.arrangedSubviews.allSatisfy { $0.layer?.cornerRadius == 0 } == true,
      "Internal panes stay flat with thin dividers: " + theme.title)
    check(controller.mainBody.layer?.backgroundColor == theme.color(.background).cgColor,
      "Existing layer backgrounds update: " + theme.title)
    check(viewer.table.backgroundColor.cgColor == theme.color(.background).cgColor,
      "An existing diff window updates: " + theme.title)
    check(controller.logTable.selectedRowIndexes == selection && controller.changesTable.selectedRowIndexes == workingSelection,
      "Theme switching preserves log and file selection: " + theme.title)
    check(controller.commitMessage.string == "Theme switch draft 中文🙂" && viewer.after == diffContents,
      "Theme switching preserves draft and loaded diff: " + theme.title)
    check(settings.themePopup.titleOfSelectedItem == theme.title, "Settings tracks the selected theme")
    menu.menuNeedsUpdate(menu)
    check(menu.items.filter { $0.state == .on }.map(\.title) == [theme.title], "Theme menu marks exactly one selection")
    let text = Theme.text.usingColorSpace(.sRGB)!
    let background = Theme.background.usingColorSpace(.sRGB)!
    check(theme.isDark ? text.brightnessComponent > background.brightnessComponent : text.brightnessComponent < background.brightnessComponent,
      "Text and background remain readable: " + theme.title)
  }
  print("Themes: four palettes, native appearance, live layers, multiple windows, selection/draft preservation and saved preferences passed")
  if !failures.isEmpty { throw GitFailure(failures.joined(separator: "\n")) }
  print("Functional flows: diff options/loading, filtered amend/draft safety, refresh/filter selection, branch-head and Commit file navigation passed")
}
