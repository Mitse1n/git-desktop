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

  // Use the real window without fixed root-view constraints: those constraints
  // hide accidental content hugging that can shrink an otherwise resizable window.
  do {
    let defaults = UserDefaults.standard
    let savedFrame = defaults.object(forKey: "NSWindow Frame MainWindow")
    let owner = RepositoryWindowController()
    let window = owner.window!
    defer {
      window.close()
      if let savedFrame { defaults.set(savedFrame, forKey: "NSWindow Frame MainWindow") }
      else { defaults.removeObject(forKey: "NSWindow Frame MainWindow") }
    }
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFront(nil)
    func resizeCheck(_ mode: String, height: CGFloat) {
      owner.repositoryController.setMode(mode)
      window.setContentSize(NSSize(width: 1200, height: height))
      for _ in 0..<4 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
      check(abs((window.contentView?.bounds.height ?? 0) - height) < 1,
        "\(mode) retains requested window height \(height) after layout")
    }
    for mode in ["Log", "Commit", "Console", "Reviews"] {
      resizeCheck(mode, height: 820)
      resizeCheck(mode, height: 640)
    }
    let terminal = owner.repositoryController.terminalWorkspace
    owner.repositoryController.repository = repo
    terminal.repositoryURL = directory
    terminal.newSession(executable: "/bin/sh", arguments: [])
    for mode in ["Terminal", "Log", "Reviews"] {
      resizeCheck(mode, height: 800)
      resizeCheck(mode, height: 680)
    }
    check(terminal.activeTerminal?.bounds.height ?? 0 > 400,
      "Terminal viewport grows with the repository window")
    print("Repository window: empty terminal, all pages and active PTY resize checks completed")
  }

  let viewer = DiffViewController()
  viewer.load(repository: repo, change: first)
  drain(viewer.queue)
  check(viewer.table.allowsMultipleSelection, "Diff supports multiple code lines")
  viewer.table.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
  check(viewer.selectedText(left: true) == "one\nthree" && viewer.selectedText(left: false) == "ONE\nTHREE",
    "Discontiguous selection copies original left/right lines")
  let savedClipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item -> NSPasteboardItem in
    let copy = NSPasteboardItem()
    for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
    return copy
  }
  viewer.table.copySide(true)
  check(NSPasteboard.general.string(forType: .string) == "one\nthree", "Copy uses the selected side")
  NSPasteboard.general.clearContents()
  NSPasteboard.general.writeObjects(savedClipboard)
  viewer.changedIndex = -1; viewer.navigate(-1)
  check(viewer.table.selectedRow == 2, "Previous difference starts at the last change")
  viewer.search.stringValue = "two"; viewer.findText()
  check(viewer.table.selectedRow == 1, "Find selects a matching line")
  viewer.search.stringValue = ""
  let syntax = DiffSyntax.tokens(Data("/* comment\n still comment */ let value = \"return\" // class\n".utf8), path: "test.ts")
  check(syntax[1].first?.kind == .comment, "Multiline comments retain lexical state")
  check(syntax[1].contains { $0.kind == .string } && syntax[1].last?.kind == .comment,
    "Strings and comments take precedence over keywords")
  let edits = DiffSyntax.changedSegments("let a = 1; let b = 2", "let a = 3; let b = 4")
  check(edits.0.count == 2 && edits.1.count == 2, "Separated inline edits preserve unchanged words")
  let emoji = DiffSyntax.changedSegments("a👩🏽‍💻b", "a🙂b")
  check(emoji.0 == [NSRange(location: 1, length: "👩🏽‍💻".utf16.count)],
    "Inline changes preserve extended Unicode graphemes")
  check(DiffSyntax.tokens(Data("plain".utf8), path: "test.unknown").isEmpty, "Unknown languages remain plain text")
  // Match the supplied IDEA examples, including asymmetric document geometry.
  check(DiffFont.regular().fontName == "JetBrainsMono-Regular", "Diff loads its bundled JetBrains Mono regular face")
  check(DiffFont.italic().fontName == "JetBrainsMono-Italic"
    && !NSFontManager.shared.traits(of: DiffFont.italic()).contains(.boldFontMask),
    "Markdown uses the regular italic face rather than bold italic")
  let xml = "<?xml version=\"1.0\"?>\n<project version=\"4\">\n</project>\n"
  let xmlTokens = DiffSyntax.tokens(Data(xml.utf8), path: "vcs.xml")
  check(xmlTokens[1].contains { $0.kind == .tag } && xmlTokens[1].contains { $0.kind == .string },
    "XML distinguishes element names from attribute strings")
  let headingTokens = DiffSyntax.tokens(Data("## Features\n".utf8), path: "README.md")
  check(headingTokens[0].contains { $0.kind == .headingMarker } && headingTokens[0].contains { $0.kind == .heading },
    "Markdown heading punctuation has a separate style")
  let presentation = DiffViewController()
  let presentationWindow = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1006, height: 360),
    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
  presentationWindow.isReleasedWhenClosed = false
  presentationWindow.contentViewController = presentation
  presentation.view.setFrameSize(NSSize(width: 1006, height: 360))
  func present(_ before: String, _ after: String) {
    presentation.before = Data(before.utf8); presentation.after = Data(after.utf8)
    presentation.setDiff(TextDiff(before: presentation.before, after: presentation.after))
    presentation.view.layoutSubtreeIfNeeded()
  }
  present("", xml)
  check(presentation.singleSide == false && !presentation.editor.split
    && presentation.table.tableColumns.map { $0.identifier.rawValue } == ["rn", "right"],
    "An added file uses one full-width editor without an empty pane")
  check(presentation.table.enclosingScrollView!.frame.width > 980,
    "Added file content occupies the viewport width")
  present(xml, "")
  check(presentation.singleSide == true && !presentation.editor.split,
    "A deleted file uses one full-width original editor")
  present("a\nb\n", "a\nx\ny\nb\n")
  check(presentation.numberOfRows(in: presentation.table) == 3 && presentation.numberOfRows(in: presentation.rightTable) == 5,
    "Split editors retain their original line counts without padding")
  check(presentation.hunks.count == 1 && presentation.hunks[0].left == 1..<1 && presentation.hunks[0].right == 1..<3,
    "A multiline insertion produces one continuous hunk connector")
  check(presentation.editor.divider.hunks.count == 1, "The divider paints one polygon per hunk")
  let longLine = String(repeating: "word ", count: 300)
  let original = (0..<200).map { "line \($0) " + longLine }
  var revised = original
  revised.insert(contentsOf: (0..<40).map { "inserted \($0)" }, at: 50)
  present(original.joined(separator: "\n"), revised.joined(separator: "\n"))
  let gutterX = presentation.editor.leftGutter.frame.minX
  presentation.editor.mainScroll.contentView.scroll(to: NSPoint(x: 120, y: 70 * 22))
  check(abs(presentation.editor.rightScroll.contentView.bounds.minY - 110 * 22) < 1,
    "Scrolling maps matching document lines across an insertion")
  check(presentation.editor.leftGutter.frame.minX == gutterX && presentation.table.frame.width > 1000,
    "Long lines scroll horizontally while line numbers remain fixed")
  // A hunk can extend far above or below the viewport when its two source
  // ranges have different lengths. Rendering must never touch the chrome.
  func chromePixels() -> Data {
    let root = presentation.view
    let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
    root.cacheDisplay(in: root.bounds, to: bitmap)
    let chromeHeight = root.bounds.maxY - presentation.editor.frame.maxY
    let rows = Int(chromeHeight * CGFloat(bitmap.pixelsHigh) / root.bounds.height)
    return Data(bytes: bitmap.bitmapData!, count: rows * bitmap.bytesPerRow)
  }
  let clippingTheme = Theme.current
  for theme in AppTheme.allCases {
    Theme.current = theme
    presentationWindow.appearance = theme.appearance
    present(original.joined(separator: "\n"), revised.joined(separator: "\n"))
    presentation.editor.divider.leftOffset = 0
    presentation.editor.divider.rightOffset = 0
    presentation.editor.rightGutter.offset = 0
    presentation.editor.leftBoundary.offset = 0
    let cleanChrome = chromePixels()
    presentation.editor.divider.leftOffset = 50 * 22
    presentation.editor.divider.rightOffset = 70 * 22
    presentation.editor.rightGutter.offset = 70 * 22
    presentation.editor.leftBoundary.offset = 50 * 22
    for overlay in [presentation.editor.divider, presentation.editor.rightGutter,
      presentation.editor.leftBoundary] { overlay.needsDisplay = true }
    check(chromePixels() == cleanChrome,
      "Offscreen diff curves, gutter fills and boundaries stay out of toolbar/revision chrome in \(theme.rawValue)")
  }
  Theme.current = clippingTheme
  presentationWindow.appearance = clippingTheme.appearance
  var stripeRevised = original
  stripeRevised.insert("first insertion", at: 5); stripeRevised.insert("second insertion", at: 31)
  present(original.joined(separator: "\n"), stripeRevised.joined(separator: "\n"))
  let stripe = presentation.editor.overview
  let firstMarker = stripe.markerRect(for: presentation.hunks[0])
  let clickLocation = stripe.convert(NSPoint(x: firstMarker.midX, y: firstMarker.midY), to: nil)
  let click = NSEvent.mouseEvent(with: .leftMouseDown, location: clickLocation, modifierFlags: [],
    timestamp: 0, windowNumber: presentationWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  stripe.mouseDown(with: click)
  check(presentation.changedIndex == 0, "Clicking a painted overview marker opens that exact hunk")
  presentationWindow.close()
  var reviewLocation: (String, Int, Bool)?
  presentation.reviewComment = { reviewLocation = ($0, $1, $2) }
  presentation.titleLabel.stringValue = "review.swift"
  present("old\ncontext\n", "new\ncontext\n")
  presentation.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
  presentation.table.reviewCommentRequested?()
  check(reviewLocation?.0 == "review.swift" && reviewLocation?.1 == 1 && reviewLocation?.2 == true,
    "Review comments map original diff rows to original source line numbers")
  presentation.rightTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
  presentation.rightTable.reviewCommentRequested?()
  check(reviewLocation?.1 == 1 && reviewLocation?.2 == false,
    "Review comments map changed diff rows to updated source line numbers")
  let calculationsBeforeLayout = viewer.scheduledDiffCalculations
  let rowsBeforeLayout = viewer.diff!.rows
  let unifiedBeforeLayout = viewer.unifiedLines().map(\.text)
  for layout in [1, 0, 1, 0] {
    viewer.layoutToggle.selectedSegment = layout
    viewer.optionsChanged()
    drain(viewer.queue)
    check(viewer.diff!.rows == rowsBeforeLayout && viewer.unifiedLines().map(\.text) == unifiedBeforeLayout,
      "Layout switches preserve exact split and unified rows")
  }
  check(viewer.scheduledDiffCalculations == calculationsBeforeLayout,
    "Layout switches reuse the current comparison without scheduling more work")
  viewer.layoutToggle.selectedSegment = 1; viewer.optionsChanged(); drain(viewer.queue)
  viewer.table.selectRowIndexes(IndexSet([0, 1, 3, 4]), byExtendingSelection: false)
  check(viewer.selectedText(left: true) == "one\nthree" && viewer.selectedText(left: false) == "ONE\nTHREE",
    "Unified copy excludes the other side and strips visual prefixes")
  viewer.layoutToggle.selectedSegment = 0; viewer.optionsChanged(); drain(viewer.queue)
  viewer.table.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
    timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
    isARepeat: false, keyCode: 98)!)
  check(viewer.table.selectedRow == 0, "F7 navigates to the first difference")
  let computedBeforeBurst = viewer.completedDiffCalculations
  let cancelGate = DispatchSemaphore(value: 0)
  viewer.queue.async { cancelGate.wait() }
  for _ in 0..<5 {
    viewer.whitespace.state = .on; viewer.optionsChanged()
    viewer.whitespace.state = .off; viewer.optionsChanged()
  }
  viewer.whitespace.state = .on; viewer.optionsChanged()
  cancelGate.signal(); drain(viewer.queue)
  check(viewer.completedDiffCalculations == computedBeforeBurst + 1,
    "Only the final queued whitespace request performs a comparison")
  check(viewer.diff!.rows == TextDiff(before: viewer.before, after: viewer.after, ignoreWhitespace: true).rows,
    "Cancelling obsolete comparisons keeps the final requested result")
  viewer.whitespace.state = .off; viewer.optionsChanged(); drain(viewer.queue)
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

  let multiDiff = DiffWindowController(repository: repo, files: [first, space], index: 0, commit: nil, comparison: nil)
  drain(multiDiff.controller.queue)
  check(multiDiff.controller.filePicker.numberOfItems == 2 && !multiDiff.controller.filePicker.isHidden,
    "Multi-file diff exposes a file chooser")
  multiDiff.controller.filePicker.selectItem(at: 1); multiDiff.selectFile()
  drain(multiDiff.controller.queue)
  check(multiDiff.index == 1 && multiDiff.controller.titleLabel.stringValue == "space.txt",
    "File chooser loads the selected file")
  multiDiff.move(1); drain(multiDiff.controller.queue)
  check(multiDiff.index == 0 && multiDiff.controller.filePicker.indexOfSelectedItem == 0,
    "File arrows wrap within the chosen files and update the chooser")
  multiDiff.close()

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
  let previousLog = controller.displayedLogCommits
  let previousGraphs = controller.graphs.map { row in
    "\(row.lane):\(row.color):" + row.edges.map { "\($0.from),\($0.to),\($0.color)" }.joined(separator: ";")
  }
  let previousDetailToken = controller.detailToken
  let previousDetails = controller.detailsText.string
  try write("worktree-refresh-only.txt", "new worktree file\n")
  controller.refresh(); drain(controller.queue)
  check(controller.snapshot!.changes.contains { $0.path == "worktree-refresh-only.txt" },
    "Worktree-only refresh updates changed files")
  check(controller.displayedLogCommits == previousLog && controller.graphs.map { row in
    "\(row.lane):\(row.color):" + row.edges.map { "\($0.from),\($0.to),\($0.color)" }.joined(separator: ";")
  } == previousGraphs, "Worktree-only refresh preserves all graph lanes, edges and colors")
  check(controller.detailToken == previousDetailToken && controller.detailsText.string == previousDetails,
    "Worktree-only refresh retains the selected immutable commit details")
  check(Set(controller.logTable.selectedRowIndexes.map { controller.snapshot!.commits[$0].hash }) == selected,
    "Worktree-only refresh preserves multiple selected commits")
  check(controller.commitMessage.string == "Original draft", "Worktree-only refresh preserves the commit draft")
  let snapshotForPreparation = controller.snapshot!
  let graphBeforePreparation = controller.graphs.map { row in
    "\(row.lane):\(row.color):" + row.edges.map { "\($0.from),\($0.to),\($0.color)" }.joined(separator: ";")
  }
  let reachabilityBeforePreparation = controller.currentBranchHistory
  var backgroundPresentation: RepositoryHistoryPresentation?
  var preparedOnBackground = false
  controller.queue.async {
    let presentation = RepositoryHistoryPresentation.prepare(snapshotForPreparation)
    let wasBackground = !Thread.isMainThread
    DispatchQueue.main.async { backgroundPresentation = presentation; preparedOnBackground = wasBackground }
  }
  drain(controller.queue)
  controller.updateUI(presentation: backgroundPresentation!)
  check(preparedOnBackground && controller.graphs.map { row in
    "\(row.lane):\(row.color):" + row.edges.map { "\($0.from),\($0.to),\($0.color)" }.joined(separator: ";")
  } == graphBeforePreparation && controller.currentBranchHistory == reachabilityBeforePreparation,
    "Background preparation preserves graph coordinates, colors and HEAD ancestry")

  let savedHighlight = controller.highlightCurrentBranch
  let savedBranchFilter = controller.filter.branch
  let highlightSelection = controller.logTable.selectedRowIndexes
  controller.highlightCurrentBranch = true
  func checkBranchHighlight(_ branch: String?, expected: Bool, _ message: String) {
    controller.filter.branch = branch
    controller.reloadLogAppearance()
    let row = controller.tableView(controller.logTable, rowViewForRow: 0) as! SelectionRow
    check(controller.shouldHighlightCurrentBranch == expected
      && (row.backgroundTint != nil) == expected, message)
    check(controller.logTable.selectedRowIndexes == highlightSelection,
      "Changing branch highlighting preserves the selected commits")
  }
  checkBranchHighlight(nil, expected: true, "All branches retain current-branch highlighting")
  checkBranchHighlight("main", expected: false, "Filtering by the current short branch name suppresses highlighting")
  checkBranchHighlight("refs/heads/main", expected: false,
    "Filtering by the current full branch ref suppresses highlighting")
  checkBranchHighlight("HEAD", expected: false, "HEAD filtering suppresses highlighting")
  checkBranchHighlight("refs/heads/feature/older", expected: true,
    "Another branch filter retains current-branch highlighting")
  checkBranchHighlight("refs/remotes/origin/main", expected: true,
    "A remote branch with the same short name is not the checked-out local branch")
  try repo.run(["branch", "highlight-same-tip", "main"])
  checkBranchHighlight("refs/heads/highlight-same-tip", expected: true,
    "Another branch at the same commit does not suppress highlighting")
  try repo.run(["branch", "-D", "highlight-same-tip"])
  controller.filter.branch = nil
  let highlightSnapshot = controller.snapshot
  try repo.run(["checkout", "feature/older"])
  controller.snapshot = try repo.snapshot()
  controller.filter.branch = "refs/heads/main"
  check(controller.shouldHighlightCurrentBranch,
    "Changing the checked-out branch re-evaluates the filter suppression rule")
  try repo.run(["checkout", "--detach"])
  controller.snapshot = try repo.snapshot()
  controller.filter.branch = nil
  check(!controller.shouldHighlightCurrentBranch, "Detached HEAD has no current-branch background")
  try repo.run(["checkout", "main"])
  controller.snapshot = highlightSnapshot
  controller.highlightCurrentBranch = false
  check(!controller.shouldHighlightCurrentBranch, "Disabling the highlight option suppresses its background")
  for theme in AppTheme.allCases {
    check(theme.color(.currentBranchBackground) != theme.color(.activeSelection),
      "Current-branch and selected-row colors are distinct in \(theme.title)")
  }
  controller.highlightCurrentBranch = true
  controller.filter.branch = nil
  controller.reloadLogAppearance()
  let unchangedHighlightSnapshot = controller.snapshot
  controller.filter.branch = "refs/heads/main"
  controller.refresh(logOnly: true)
  drain(controller.queue)
  check(controller.snapshot == unchangedHighlightSnapshot
    && !controller.displayedCurrentBranchHighlight
    && (controller.logTable.rowView(atRow: 0, makeIfNecessary: true) as? SelectionRow)?.backgroundTint == nil,
    "All to current-branch filtering clears existing row backgrounds even when commit data is unchanged")
  controller.filter.branch = nil
  controller.refresh(logOnly: true)
  drain(controller.queue)
  check(controller.displayedCurrentBranchHighlight
    && (controller.logTable.rowView(atRow: 0, makeIfNecessary: true) as? SelectionRow)?.backgroundTint != nil,
    "Returning to All restores current-branch backgrounds without changing commit data")
  controller.highlightCurrentBranch = savedHighlight
  controller.filter.branch = savedBranchFilter
  controller.reloadLogAppearance()
  drain(controller.queue)
  print("Current branch highlight: all/current/HEAD/other/same-tip/remote filters, checkout, detached HEAD, themes and selection preservation passed")

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

  try repo.run(["tag", "selection-test"])
  controller.snapshot = try repo.snapshot()
  controller.showTags = true
  controller.rebuildBranches()
  let multiRows = IndexSet((0..<controller.branchOutline.numberOfRows).filter {
    let branch = (controller.branchOutline.item(atRow: $0) as? BranchNode)?.branch
    return branch?.name == "selection-test" || branch?.name == "feature/older"
  })
  check(multiRows.count == 2 && controller.branchOutline.allowsMultipleSelection,
    "Branches and tags allow a shared native multiple selection")
  controller.branchOutline.selectRowIndexes(multiRows, byExtendingSelection: false)
  let multiRefs = Set(controller.selectedBranches.map(\.fullRef))
  check(multiRefs.count == 2 && controller.selectedBranch == nil
    && controller.selectedBranchRevision == nil && controller.branchHeadButton?.isEnabled == false,
    "Multiple references never silently choose one branch for single-reference actions")
  let originalFavorites = controller.favoriteRefs
  controller.toggleSelectedBranchFavorites()
  check(multiRefs.isSubset(of: controller.favoriteRefs)
    && Set(controller.selectedBranches.map(\.fullRef)) == multiRefs,
    "Batch favorites preserve branch and tag selection across sorting and reload")
  controller.rebuildBranches()
  check(Set(controller.selectedBranches.map(\.fullRef)) == multiRefs,
    "Refreshing the branches tree retains every selected reference")
  check(controller.branchContextMenu().items.map(\.title) == ["Delete"],
    "Multiple reference menus offer batch actions rather than an arbitrary checkout")
  let localRows = IndexSet((0..<controller.branchOutline.numberOfRows).filter {
    (controller.branchOutline.item(atRow: $0) as? BranchNode)?.branch?.kind == .local
  })
  controller.branchOutline.selectRowIndexes(localRows, byExtendingSelection: false)
  check(controller.branchContextMenu().items.last?.title == "Delete Branches"
    && controller.branchContextMenu().items.last?.isEnabled == false,
    "Branch batch delete is disabled when the selection includes the current branch")
  let menuSnapshot = controller.snapshot!
  controller.snapshot = RepositorySnapshot(branches: menuSnapshot.branches, commits: menuSnapshot.commits,
    changes: menuSnapshot.changes, currentBranch: menuSnapshot.currentBranch, remotes: ["origin"],
    stashes: menuSnapshot.stashes, operation: menuSnapshot.operation)
  let batchMenu = controller.branchContextMenu()
  check(batchMenu.items.map(\.title) == ["Update Selected", "Delete Branches"]
    && batchMenu.items.first?.isEnabled == false && batchMenu.items.first?.image != nil
    && batchMenu.items.last?.image != nil && batchMenu.items.last?.keyEquivalent == "\u{8}",
    "The branch batch menu matches IDEA, with icons, delete shortcut and missing-upstream disablement")
  controller.snapshot = menuSnapshot
  controller.favoriteRefs = originalFavorites
  controller.rebuildBranches()
  controller.branchOutline.deselectAll(nil)

  // The same outline is used for file and reference selections; a right click
  // inside an existing selection must retain it, as NSTableView already does.
  let menuOutline = controller.branchOutline
  menuOutline.selectRowIndexes(multiRows, byExtendingSelection: false)
  let selectedRect = menuOutline.rect(ofRow: multiRows.first!)
  let contextEvent = NSEvent.mouseEvent(with: .rightMouseDown,
    location: menuOutline.convert(NSPoint(x: 20, y: selectedRect.midY), to: nil),
    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
    eventNumber: 0, clickCount: 1, pressure: 1)!
  _ = menuOutline.menu(for: contextEvent)
  check(menuOutline.selectedRowIndexes == multiRows,
    "Opening an outline context menu preserves an existing multiple selection")
  menuOutline.deselectAll(nil)
  print("Branch/tag multiple selection, batch favorites, refresh and context-menu preservation passed")

  func pressFileSpace(repeatKey: Bool = false, modifiers: NSEvent.ModifierFlags = []) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: 0, context: nil, characters: " ",
      charactersIgnoringModifiers: " ", isARepeat: repeatKey, keyCode: 49)!
    controller.filesTable.keyDown(with: event)
  }
  check(controller.filesTable.allowsMultipleSelection, "Historical file list allows multiple selection")
  controller.filesTable.deselectAll(nil)
  pressFileSpace()
  check(controller.diffWindows.isEmpty, "Space without a file selection does not open Diff")
  let previewRow = (0..<controller.filesTable.numberOfRows).first {
    (controller.filesTable.item(atRow: $0) as? FileNode)?.file?.path == "space.txt"
  }!
  controller.filesTable.selectRowIndexes(IndexSet(integer: previewRow), byExtendingSelection: false)
  let selectedFilesRows = (0..<controller.filesTable.numberOfRows).filter {
    (controller.filesTable.item(atRow: $0) as? FileNode)?.file != nil
  }
  controller.filesTable.selectRowIndexes(IndexSet(selectedFilesRows), byExtendingSelection: false)
  let selectedFiles = controller.selectedDetailFiles
  check(selectedFiles.count >= 2, "Historical selection includes multiple files")
  controller.showDiff()
  if let preview = controller.diffWindows.first {
    check(preview.files.map(\.path) == selectedFiles.map(\.path), "Multi-selection limits diff navigation to selected files")
    drain(preview.controller.queue); preview.close()
  } else { check(false, "Multi-selection opens a diff window") }
  if let group = (0..<controller.filesTable.numberOfRows).first(where: {
    (controller.filesTable.item(atRow: $0) as? FileNode)?.file == nil
  }) {
    controller.filesTable.selectRowIndexes(IndexSet(selectedFilesRows + [group]), byExtendingSelection: false)
    check(controller.selectedDetailFiles.count == Set(controller.selectedDetailFiles.map(\.path)).count,
      "Selecting a group and its files does not duplicate files")
  }
  controller.filesTable.selectRowIndexes(IndexSet(integer: previewRow), byExtendingSelection: false)
  let previewSelection = controller.filesTable.selectedRowIndexes
  pressFileSpace(repeatKey: true)
  pressFileSpace(modifiers: .shift)
  check(controller.diffWindows.isEmpty, "Repeated or modified Space does not open a preview")
  pressFileSpace()
  check(controller.diffWindows.count == 1, "Space opens one Diff window for the selected file")
  if let preview = controller.diffWindows.first {
    drain(preview.controller.queue)
    check(preview.files[preview.index].path == "space.txt" && preview.commit?.hash == branchHead,
      "Space preview uses the selected historical file and commit, as double-click does")
    preview.close()
  }
  check(controller.filesTable.selectedRowIndexes == previewSelection,
    "Space preview preserves file selection")
  print("File preview: Space opens selected historical Diff, preserves selection, and ignores empty/repeated/modified requests")

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
  let dateSelection = controller.logTable.selectedRowIndexes
  let dateViewport = controller.logTable.enclosingScrollView!.contentView.bounds
  let dateCell = controller.logTable.view(atColumn: 3, row: 0, makeIfNecessary: true) as! LogMetadataCell
  controller.refreshLogDates(now: controller.snapshot!.commits[0].date.addingTimeInterval(300))
  check(dateCell.textField?.stringValue == "5 minutes ago" && dateCell.toolTip != "5 minutes ago",
    "Visible log dates refresh their relative text while retaining an absolute timestamp tooltip")
  check(controller.logTable.selectedRowIndexes == dateSelection
    && controller.logTable.enclosingScrollView!.contentView.bounds == dateViewport,
    "Refreshing log dates preserves multiple selection and scroll position")
  controller.refreshLogDates()
  let metadataSelection = controller.logTable.selectedRowIndexes
  for column in [2, 3] {
    let table = controller.logTable
    let cell = table.view(atColumn: column, row: 0, makeIfNecessary: true) as! LogMetadataCell
    let original = cell.textField!.stringValue
    cell.textField!.stringValue = column == 2 ? "Alex Christopher Longname" : "2026/10/12 09:41:32 +08:00"
    cell.layoutSubtreeIfNeeded()
    let text = cell.hoverText!
    check(cell.hitTest(NSPoint(x: cell.frame.midX, y: cell.frame.midY)) == nil,
      "Metadata labels pass pointer events to the log table")
    let point = cell.convert(NSPoint(x: text.rect.midX, y: cell.bounds.minY + 1), to: nil)
    let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
      clickCount: 0, pressure: 0)!
    table.mouseMoved(with: event)
    check(window.contentView!.subviews.contains { $0 is LogTextExpansionView },
      "Truncated metadata column \(column) expands on hover")
    check(table.selectedRowIndexes == metadataSelection, "Metadata hover preserves commit selection")
    table.mouseExited(with: event)
    check(!window.contentView!.subviews.contains { $0 is LogTextExpansionView },
      "Leaving metadata dismisses its expansion")
    cell.textField!.stringValue = "T"
    table.mouseMoved(with: event)
    check(!window.contentView!.subviews.contains { $0 is LogTextExpansionView },
      "Unclipped metadata does not expand")
    cell.textField!.stringValue = original
  }
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
  // Narrow the pane and repeatedly move its viewport in both directions.
  // Probe the fill above the text: stale copies of a rounded right edge produce
  // several alternating background/hover segments instead of one solid span.
  controller.split.setPosition(180, ofDividerAt: 0)
  controller.view.layoutSubtreeIfNeeded()
  outline.fitContentWidth()
  let horizontalSelection = outline.selectedRowIndexes
  for x in [0, 18, 36, 72, 105, 140, 110, 80, 40, 0] {
    branchClip.scroll(to: NSPoint(x: CGFloat(x), y: branchClip.bounds.minY))
    branchScroll.reflectScrolledClipView(branchClip)
    hoverBranch(longRow)
    outline.dismissTextExpansion()
    window.displayIfNeeded()
    guard let row = outline.rowView(atRow: longRow, makeIfNecessary: true) as? SelectionRow else {
      check(false, "The hovered long branch remains visible while scrolling"); continue
    }
    let area = row.visibleRect
    let bitmap = row.bitmapImageRepForCachingDisplay(in: area)!
    row.cacheDisplay(in: area, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / area.width
    let y = min(bitmap.pixelsHigh - 1, Int(scale))
    let first = min(bitmap.pixelsWide - 1, Int(12 * scale))
    let last = max(first, bitmap.pixelsWide - Int(12 * scale))
    let fill = bitmap.colorAt(x: first, y: y)!
    check((first..<last).allSatisfy { bitmap.colorAt(x: $0, y: y) == fill },
      "Narrow branch hover has one continuous fill after horizontal scroll to \(x)")
    check(outline.selectedRowIndexes == horizontalSelection,
      "Horizontal branch scrolling preserves the existing selection")
  }
  controller.split.setPosition(320, ofDividerAt: 0)
  controller.view.layoutSubtreeIfNeeded()
  outline.fitContentWidth()
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
    check(viewer.table.backgroundColor.cgColor == DiffPalette.background.cgColor,
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
