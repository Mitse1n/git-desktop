import AppKit
import GitDeskCore

// Cancellation is shared by the main thread and the serial I/O/comparison queue.
private final class DiffWorkCancellation {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

final class DiffViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
  let table = DiffTable()
  let rightTable = DiffTable()
  private(set) var hunks: [DiffHunk] = []
  private var leftRows: [Int] = [], rightRows: [Int] = []
  private var sourceWidths: (CGFloat, CGFloat) = (0, 0)
  private var syncingScroll = false
  private var searchQuery = ""
  private var searchCursor = -1
  private(set) var editor: DiffEditorLayout!
  private var rightMetadata: NSStackView!
  private var leftMetadata: NSStackView!
  private let rightPathLabel = label("", color: Theme.muted, size: 13)
  private let settings = NSPopover()
  private var settingsButton: ActionButton!
  private var editButton: ActionButton!
  private var rightMetadataSplit: NSLayoutConstraint!
  private var rightMetadataSingle: NSLayoutConstraint!
  var singleSide: Bool? { before.isEmpty && !after.isEmpty ? false : after.isEmpty && !before.isEmpty ? true : nil }
  private var unified: Bool { layoutToggle.selectedSegment == 1 && singleSide == nil }
  private var mainIsLeft: Bool { singleSide ?? true }
  private var split: Bool { !unified && singleSide == nil }
  let titleLabel = label("Diff", bold: true)
  let countLabel = label("", color: Theme.muted, size: 12)
  let leftLabel = label("HEAD", color: Theme.muted, size: 12)
  let rightLabel = label("Working Tree", color: Theme.muted, size: 12)
  let emptyLabel = label("", color: Theme.muted)
  let layoutToggle = DiffLayoutControl(
    labels: ["Side-by-side", "Unified"], trackingMode: .selectOne, target: nil, action: nil)
  let synchronizedScrolling = NSButton(checkboxWithTitle: "Synchronize scrolling", target: nil, action: nil)
  let whitespace = NSButton(checkboxWithTitle: "Ignore whitespace", target: nil, action: nil)
  let search = NSSearchField()
  let queue = DispatchQueue(label: "gitdesk.diff", qos: .userInitiated, autoreleaseFrequency: .workItem)
  let filePicker = NSPopUpButton()
  private var leftSyntax: [[DiffSyntax.Token]] = [], rightSyntax: [[DiffSyntax.Token]] = []
  private var syntaxReady = false
  var before = Data(), after = Data()
  var diff: TextDiff?
  var token = 0
  private var contentToken = 0
  private var hasContents = false
  private var calculatedWhitespace: Bool?
  private var requestedWhitespace: Bool?
  private(set) var scheduledDiffCalculations = 0
  private(set) var completedDiffCalculations = 0
  private var pendingLoad: DiffWorkCancellation?
  private var pendingCalculation: DiffWorkCancellation?
  var changedIndex = -1
  var nextFile: (() -> Void)?, previousFile: (() -> Void)?
  var reviewComment: ((String, Int, Bool) -> Void)? { didSet { configureReviewComments() } }
  var compact = false
  override func loadView() {
    view = Surface(DiffPalette.background)
    for codeTable in [table, rightTable] {
      configureTable(codeTable)
      codeTable.rowHeight = 22
      codeTable.backgroundColor = DiffPalette.background
      codeTable.selectionHighlightStyle = .none
      codeTable.allowsMultipleSelection = true
      codeTable.delegate = self; codeTable.dataSource = self
      codeTable.columnAutoresizingStyle = .noColumnAutoresizing
      codeTable.copyText = { [weak self, weak codeTable] left in
        guard let self, let codeTable else { return "" }
        return self.selectedText(left: left, in: codeTable)
      }
      codeTable.navigateDifference = { [weak self] in self?.navigate($0) }
      codeTable.findRequested = { [weak self] in self?.showSettings(find: true) }
    }
    table.setAccessibilityLabel("Original version")
    rightTable.setAccessibilityLabel("Changed version")
    layoutToggle.selectedSegment = compact ? 1 : 0
    for (i, symbol) in ["rectangle.split.2x1", "rectangle"].enumerated() {
      layoutToggle.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: i == 0 ? "Side-by-side" : "Unified"), forSegment: i)
      layoutToggle.setLabel("", forSegment: i)
      layoutToggle.setWidth(compact ? 30 : 42, forSegment: i)
    }
    layoutToggle.toolTip = "Side-by-side / Unified"
    layoutToggle.target = self; layoutToggle.action = #selector(optionsChanged)
    whitespace.target = self; whitespace.action = #selector(optionsChanged)
    whitespace.font = .systemFont(ofSize: 12)
    styleCheckbox(whitespace)
    search.placeholderString = "Find in diff"
    search.target = self; search.action = #selector(findText)
    let settingsContent = NSViewController()
    settingsContent.view = Surface(DiffPalette.chrome)
    synchronizedScrolling.state = .on
    synchronizedScrolling.font = .systemFont(ofSize: 12)
    styleCheckbox(synchronizedScrolling)
    let settingRows = NSStackView(views: [whitespace, synchronizedScrolling, search])
    settingRows.orientation = .vertical; settingRows.alignment = .leading; settingRows.spacing = 14
    pin(settingRows, to: settingsContent.view, inset: 14)
    settings.contentViewController = settingsContent; settings.contentSize = NSSize(width: 260, height: 126)
    settings.behavior = .transient
    settingsButton = ActionButton(symbol: "gearshape", tooltip: "Diff options and find (⌘F)", size: 30) { [weak self] in self?.showSettings() }
    filePicker.cell = DiffFilePickerCell(textCell: "", pullsDown: false)
    filePicker.controlSize = .small
    filePicker.setAccessibilityLabel("Files in comparison")
    countLabel.textColor = DiffPalette.text; countLabel.font = .systemFont(ofSize: 13)
    for field in [leftLabel, rightLabel] { field.textColor = DiffPalette.text; field.font = .systemFont(ofSize: 13) }
    titleLabel.font = .systemFont(ofSize: 13); titleLabel.textColor = Theme.muted
    titleLabel.lineBreakMode = .byTruncatingMiddle; titleLabel.usesSingleLineMode = true
    rightPathLabel.lineBreakMode = .byTruncatingMiddle
    func separator() -> NSView {
      let view = Surface(Theme.line)
      view.widthAnchor.constraint(equalToConstant: 1).isActive = true
      view.heightAnchor.constraint(equalToConstant: 22).isActive = true
      return view
    }
    editButton = ActionButton(symbol: "pencil", tooltip: "Open working file in its default editor", size: 26) {}
    editButton.isEnabled = false
    let toolbarItems: [NSView] = [
      ActionButton(symbol: "arrow.up", tooltip: "Previous Difference (⇧F7)", size: 26) { [weak self] in self?.navigate(-1) },
      ActionButton(symbol: "arrow.down", tooltip: "Next Difference (F7)", size: 26) { [weak self] in self?.navigate(1) },
      separator(), editButton, separator(),
      ActionButton(symbol: "chevron.left", tooltip: "Previous File", size: 20) { [weak self] in self?.previousFile?() },
      filePicker,
      ActionButton(symbol: "chevron.right", tooltip: "Next File", size: 20) { [weak self] in self?.nextFile?() },
      separator(), NSView(), countLabel, layoutToggle, settingsButton,
    ]
    for case let button as NSButton in toolbarItems { button.contentTintColor = DiffPalette.text }
    let fileNavigation = row(Array(toolbarItems[5...7]), spacing: 2)
    let regularToolbar = Array(toolbarItems[0..<5]) + [fileNavigation] + Array(toolbarItems[8...])
    let toolbar = row(compact ? [toolbarItems[0], toolbarItems[1], NSView(), layoutToggle, settingsButton] : regularToolbar, spacing: 6)
    let toolbarSurface = Surface(DiffPalette.chrome)
    toolbarSurface.wantsLayer = true; toolbarSurface.layer?.cornerRadius = 6
    toolbarSurface.borderColor = DiffPalette.chromeBorder; toolbarSurface.layer?.borderWidth = 1
    pin(toolbar, to: toolbarSurface, inset: 6)
    func lock() -> NSImageView {
      let image = NSImageView(image: NSImage(systemSymbolName: "lock", accessibilityDescription: "Read-only")!)
      image.contentTintColor = DiffPalette.text
      image.widthAnchor.constraint(equalToConstant: 12).isActive = true
      return image
    }
    leftMetadata = row([lock(), leftLabel, titleLabel], spacing: 6)
    rightMetadata = row([lock(), rightLabel, rightPathLabel], spacing: 6)
    editor = DiffEditorLayout(main: table, right: rightTable)
    editor.overview.jump = { [weak self] index in self?.showHunk(index) }
    let rule = Surface(DiffPalette.line)
    for child in [toolbarSurface, leftMetadata!, rightMetadata!, rule, editor!] {
      child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child)
    }
    rightMetadataSplit = rightMetadata.leadingAnchor.constraint(equalTo: view.centerXAnchor, constant: 24)
    rightMetadataSingle = rightMetadata.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8)
    NSLayoutConstraint.activate([
      toolbarSurface.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
      toolbarSurface.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
      toolbarSurface.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
      toolbarSurface.heightAnchor.constraint(equalToConstant: 42),
      leftMetadata.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
      leftMetadata.topAnchor.constraint(equalTo: toolbarSurface.bottomAnchor, constant: 3),
      leftMetadata.heightAnchor.constraint(equalToConstant: 26),
      leftMetadata.trailingAnchor.constraint(lessThanOrEqualTo: view.centerXAnchor, constant: -12),
      rightMetadataSplit,
      rightMetadata.topAnchor.constraint(equalTo: leftMetadata.topAnchor),
      rightMetadata.heightAnchor.constraint(equalTo: leftMetadata.heightAnchor),
      rightMetadata.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
      rule.topAnchor.constraint(equalTo: leftMetadata.bottomAnchor),
      rule.leadingAnchor.constraint(equalTo: view.leadingAnchor), rule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      rule.heightAnchor.constraint(equalToConstant: 1),
      editor.topAnchor.constraint(equalTo: rule.bottomAnchor), editor.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      editor.leadingAnchor.constraint(equalTo: view.leadingAnchor), editor.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    for scroll in [editor.mainScroll, editor.rightScroll] {
      scroll.contentView.postsFrameChangedNotifications = true
      scroll.contentView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.frameDidChangeNotification, object: scroll.contentView)
      NotificationCenter.default.addObserver(self, selector: #selector(scrollChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(emptyLabel)
    NSLayoutConstraint.activate([emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
    configureColumns()
    configureReviewComments()
  }
  private func configureReviewComments() {
    for codeTable in [table, rightTable] {
      codeTable.reviewCommentRequested = reviewComment == nil ? nil : { [weak self, weak codeTable] in
        guard let self, let codeTable else { return }
        let row = codeTable.selectedRow
        guard codeTable.selectedRowIndexes.count == 1, row >= 0 else { return }
        let number: Int?, left: Bool
        if self.unified {
          guard self.unifiedCache.indices.contains(row) else { return }
          let line = self.unifiedCache[row]
          left = line.right == nil; number = left ? line.left : line.right
        } else {
          let rows = self.sourceRows(in: codeTable)
          guard rows.indices.contains(row), let diff = self.diff, diff.rows.indices.contains(rows[row]) else { return }
          left = codeTable === self.table && self.mainIsLeft
          number = left ? diff.rows[rows[row]].leftNumber : diff.rows[rows[row]].rightNumber
        }
        if let number { self.reviewComment?(self.titleLabel.stringValue, number, left) }
      }
    }
  }
  func showSettings(find: Bool = false) {
    settings.show(relativeTo: settingsButton.bounds, of: settingsButton, preferredEdge: .minY)
    if find { settings.contentViewController?.view.window?.makeFirstResponder(search) }
  }
  override func viewDidLayout() {
    super.viewDidLayout()
    fitColumnsToViewport()
  }
  private func fitColumnsToViewport() {
    guard editor != nil else { return }
    for codeTable in [table, rightTable] {
      guard let scroll = codeTable.enclosingScrollView else { continue }
      let viewport = scroll.contentSize.width
      guard viewport > 0 else { continue }
      let gutters = CGFloat(codeTable.tableColumns.filter { ["ln", "rn"].contains($0.identifier.rawValue) }.count) * 44
      let longest = codeTable === rightTable ? sourceWidths.1 : unified ? max(sourceWidths.0, sourceWidths.1) + 16 : mainIsLeft ? sourceWidths.0 : sourceWidths.1
      let textWidth = max(80, viewport - gutters, longest + 12)
      for column in codeTable.tableColumns {
        let width: CGFloat = ["ln", "rn"].contains(column.identifier.rawValue) ? 44 : textWidth
        if abs(column.width - width) > 0.5 { column.width = width }
      }
      let width = max(viewport, textWidth + gutters)
      codeTable.bottomPadding = 5 * codeTable.rowHeight
      let height = max(scroll.contentSize.height, CGFloat(codeTable.numberOfRows) * codeTable.rowHeight + codeTable.bottomPadding)
      if abs(codeTable.frame.width - width) > 0.5 || abs(codeTable.frame.height - height) > 0.5 {
        codeTable.setFrameSize(NSSize(width: width, height: height))
      }
    }
    refreshGeometry()
  }
  @objc private func viewportChanged(_ notification: Notification) { fitColumnsToViewport() }
  @objc private func scrollChanged(_ notification: Notification) {
    guard editor != nil, !syncingScroll else { return }
    if split, synchronizedScrolling.state == .on, let clip = notification.object as? NSClipView {
      syncingScroll = true
      let fromLeft = clip === editor.mainScroll.contentView
      let target = fromLeft ? editor.rightScroll : editor.mainScroll
      let mapped = DiffHunk.map(clip.bounds.minY / table.rowHeight, hunks: hunks, fromLeft: fromLeft) * table.rowHeight
      let maxY = max(0, (target.documentView?.frame.height ?? 0) - target.contentSize.height)
      target.contentView.scroll(to: NSPoint(x: target.contentView.bounds.minX, y: max(0, min(maxY, mapped))))
      target.reflectScrolledClipView(target.contentView)
      syncingScroll = false
    }
    refreshGeometry()
  }
  private func refreshGeometry() {
    guard editor != nil else { return }
    editor.divider.hunks = hunks
    editor.divider.leftOffset = editor.mainScroll.contentView.bounds.minY
    editor.divider.rightOffset = editor.rightScroll.contentView.bounds.minY
    editor.divider.needsDisplay = true
    editor.leftThumb.needsDisplay = true; editor.rightThumb.needsDisplay = true
    for (overlay, offset) in [(editor.leftBoundary, editor.divider.leftOffset), (editor.rightBoundary, editor.divider.rightOffset)] {
      overlay.hunks = hunks; overlay.offset = offset; overlay.needsDisplay = true
    }
    for (gutter, rows, offset) in [(editor.leftGutter, leftRows, editor.divider.leftOffset), (editor.rightGutter, rightRows, editor.divider.rightOffset)] {
      gutter.count = rows.count; gutter.hunks = hunks; gutter.offset = offset
      let codeTable = gutter === editor.leftGutter ? table : rightTable
      gutter.caretLine = codeTable.selectedRow >= 0 ? codeTable.selectedRow : changedIndex >= 0 && hunks.indices.contains(changedIndex)
        ? max(0, (gutter.left ? hunks[changedIndex].left : hunks[changedIndex].right).lowerBound - (gutter.left && hunks[changedIndex].left.isEmpty ? 1 : 0)) : 0
      gutter.needsDisplay = true
    }
    editor.overview.hunks = hunks; editor.overview.count = max(leftRows.count, rightRows.count)
    editor.overview.documentHeight = (split ? rightTable : table).frame.height
    editor.overview.singleSide = singleSide != nil
    editor.overview.needsDisplay = true
  }
  deinit {
    pendingLoad?.cancel()
    pendingCalculation?.cancel()
    NotificationCenter.default.removeObserver(self)
  }
  func clear() {
    pendingLoad?.cancel()
    pendingCalculation?.cancel()
    contentToken += 1
    token += 1
    hasContents = false
    syntaxReady = false
    searchQuery = ""; searchCursor = -1
    leftSyntax = []; rightSyntax = []
    calculatedWhitespace = nil
    requestedWhitespace = nil
    before = Data()
    after = Data()
    diff = nil
    unifiedCache = []
    leftRows = []; rightRows = []; hunks = []; sourceWidths = (0, 0)
    table.reloadData(); rightTable.reloadData()
    refreshGeometry()
    titleLabel.stringValue = "Diff"
    titleLabel.toolTip = nil
    rightPathLabel.stringValue = ""
    configureColumns()
    countLabel.stringValue = ""
    leftLabel.stringValue = ""
    rightLabel.stringValue = ""
    changedIndex = -1
    emptyLabel.stringValue = "Select a file to view its changes"
    emptyLabel.isHidden = false
  }
  func configureColumns() {
    guard editor != nil else { return }
    editor.split = split
    leftMetadata.isHidden = singleSide == false
    rightMetadata.isHidden = singleSide == true
    rightPathLabel.isHidden = split
    rightMetadataSplit.isActive = singleSide != false
    rightMetadataSingle.isActive = singleSide == false
    layoutToggle.isEnabled = singleSide == nil
    layoutToggle.needsDisplay = true
    for codeTable in [table, rightTable] {
      for column in codeTable.tableColumns { codeTable.removeTableColumn(column) }
      let ids: [String] = codeTable === rightTable ? ["right"] : unified ? ["ln", "rn", "unified"]
        : split ? ["left"] : mainIsLeft ? ["ln", "left"] : ["rn", "right"]
      for id in ids {
        let column = NSTableColumn(identifier: .init(id))
        column.width = ["ln", "rn"].contains(id) ? 44 : 300
        column.minWidth = 1; column.resizingMask = []
        codeTable.addTableColumn(column)
      }
      codeTable.reloadData()
    }
    editor.layoutSubtreeIfNeeded()
    fitColumnsToViewport()
  }
  func load(
    repository: GitRepository, change: FileChange, commit: Commit? = nil, staged: Bool = false,
    comparison: (String, String)? = nil
  ) {
    _ = view
    pendingLoad?.cancel()
    pendingCalculation?.cancel()
    let request = DiffWorkCancellation()
    pendingLoad = request
    contentToken += 1
    token += 1
    let current = contentToken
    hasContents = false
    syntaxReady = false
    searchQuery = ""; searchCursor = -1
    leftSyntax = []; rightSyntax = []
    calculatedWhitespace = nil
    requestedWhitespace = nil
    before = Data()
    after = Data()
    diff = nil
    unifiedCache = []
    leftRows = []; rightRows = []; hunks = []; sourceWidths = (0, 0)
    table.reloadData(); rightTable.reloadData()
    refreshGeometry()
    titleLabel.stringValue = change.path
    titleLabel.toolTip = change.path
    rightPathLabel.stringValue = change.path
    editButton.isEnabled = commit == nil && comparison == nil
    editButton.handler = { NSWorkspace.shared.open(repository.workingDirectory.appendingPathComponent(change.path)) }
    emptyLabel.stringValue = "Loading diff…"
    emptyLabel.isHidden = false
    countLabel.stringValue = ""
    leftLabel.stringValue =
      comparison.map { String($0.0.prefix(8)) }
      ?? (commit?.parents.first.map { String($0.prefix(8)) }
        ?? (commit == nil ? "HEAD" : "Empty tree"))
    rightLabel.stringValue =
      comparison.map { String($0.1.prefix(8)) } ?? commit?.shortHash
      ?? (staged ? "Index" : "Working Tree")
    queue.async { [weak self] in
      guard !request.isCancelled else { return }
      do {
        let pair =
          commit == nil && comparison == nil && !staged
          ? try repository.workingDiff(change: change)
          : try repository.contents(
            change: change, commit: commit, staged: staged, comparison: comparison)
        guard !request.isCancelled else { return }
        DispatchQueue.main.async {
          guard let self, self.contentToken == current else { return }
          self.pendingLoad = nil
          self.before = pair.0
          self.after = pair.1
          self.hasContents = true
          self.calculateDiff()
        }
      } catch {
        DispatchQueue.main.async {
          guard let self, self.contentToken == current else { return }
          self.emptyLabel.stringValue = error.localizedDescription
        }
      }
    }
  }
  func setDiff(_ diff: TextDiff, rebuildUnified: Bool = true) {
    self.diff = diff
    if rebuildUnified {
      unifiedCache = buildUnifiedLines()
      leftRows = diff.rows.indices.filter { diff.rows[$0].left != nil }
      rightRows = diff.rows.indices.filter { diff.rows[$0].right != nil }
      hunks = DiffHunk.build(diff.rows)
      // Editors display the empty terminal line; the core edit script intentionally omits it.
      let originalLeftCount = leftRows.count, originalRightCount = rightRows.count
      if before.last == 10 && !diff.rows.isEmpty { leftRows.append(-1) }
      if after.last == 10 && !diff.rows.isEmpty { rightRows.append(-1) }
      hunks = hunks.map { hunk in
        let l = hunk.left.upperBound == originalLeftCount && !hunk.left.isEmpty ? leftRows.count : hunk.left.upperBound
        let r = hunk.right.upperBound == originalRightCount && !hunk.right.isEmpty ? rightRows.count : hunk.right.upperBound
        var left = hunk.left.lowerBound..<l, right = hunk.right.lowerBound..<r
        // The original terminal blank is context for an EOF insertion starting with a blank.
        if hunk.left.isEmpty, leftRows.last == -1, hunk.left.lowerBound == originalLeftCount,
          rightRows.indices.contains(right.lowerBound), rightRows[right.lowerBound] >= 0,
          diff.rows[rightRows[right.lowerBound]].right == "" {
          left = originalLeftCount + 1..<originalLeftCount + 1
          right = right.lowerBound + 1..<right.upperBound
        }
        if hunk.right.isEmpty, rightRows.last == -1, hunk.right.lowerBound == originalRightCount,
          leftRows.indices.contains(left.lowerBound), leftRows[left.lowerBound] >= 0,
          diff.rows[leftRows[left.lowerBound]].left == "" {
          right = originalRightCount + 1..<originalRightCount + 1
          left = left.lowerBound + 1..<left.upperBound
        }
        return DiffHunk(left: left, right: right)
      }
      let font = DiffFont.regular()
      // Measure the longest candidates, not every line on the UI thread.
      func width(_ left: Bool) -> CGFloat {
        let rows = left ? leftRows : rightRows
        let candidates = rows.filter { $0 >= 0 }.map { ($0, (left ? diff.rows[$0].left! : diff.rows[$0].right!).utf16.count) }
          .sorted { $0.1 > $1.1 }.prefix(24).map { $0.0 }
        return candidates.reduce(0) { max($0, ((left ? diff.rows[$1].left! : diff.rows[$1].right!) as NSString).size(withAttributes: [.font: font]).width) }
      }
      sourceWidths = (width(true), width(false))
    }
    configureColumns()
    changedIndex = -1
    view.layoutSubtreeIfNeeded()
    fitColumnsToViewport()
    table.reloadData()
    countLabel.stringValue = diff.changes.isEmpty && !diff.identical && !diff.rows.isEmpty
      ? "Differences ignored"
      : "\(diff.changes.count) " + (diff.changes.count == 1 ? "difference" : "differences")
    emptyLabel.stringValue =
      diff.binary
      ? "Binary file · \(before.count) → \(after.count) bytes"
      : diff.tooLarge || diff.rows.isEmpty && !diff.identical
        ? "File is too large for the inline diff." : diff.identical ? "Contents are identical" : ""
    emptyLabel.isHidden = emptyLabel.stringValue.isEmpty
    syncingScroll = true
    for scroll in [editor.mainScroll, editor.rightScroll] {
      scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
    }
    syncingScroll = false; refreshGeometry()
  }
  @objc func optionsChanged() {
    let ignore = whitespace.state == .on
    configureColumns()
    // Layout changes must not cancel a pending file read or compare stale data.
    guard hasContents else { return }
    if let diff, calculatedWhitespace == ignore {
      // Keep the original asynchronous UI application order, including column
      // layout and navigation reset, without comparing or copying rows again.
      token += 1
      pendingCalculation?.cancel()
      let request = DiffWorkCancellation()
      pendingCalculation = request
      let current = token
      requestedWhitespace = ignore
      queue.async { [weak self] in
        guard !request.isCancelled else { return }
        DispatchQueue.main.async {
          guard let self, self.token == current, !request.isCancelled else { return }
          self.pendingCalculation = nil
          self.setDiff(diff, rebuildUnified: false)
        }
      }
    } else if requestedWhitespace != ignore {
      calculateDiff()
    }
  }
  private func calculateDiff() {
    pendingCalculation?.cancel()
    let request = DiffWorkCancellation()
    pendingCalculation = request
    token += 1
    let current = token
    let before = self.before
    let after = self.after
    let ignore = whitespace.state == .on
    let path = titleLabel.stringValue
    let needsSyntax = !syntaxReady
    requestedWhitespace = ignore
    scheduledDiffCalculations += 1
    queue.async { [weak self] in
      guard !request.isCancelled else { return }
      guard let diff = TextDiff(before: before, after: after, ignoreWhitespace: ignore,
        shouldCancel: { request.isCancelled }) else { return }
      let leftTokens = needsSyntax && !diff.rows.isEmpty ? DiffSyntax.tokens(before, path: path, shouldCancel: { request.isCancelled }) : []
      guard !request.isCancelled else { return }
      let rightTokens = needsSyntax && !diff.rows.isEmpty ? DiffSyntax.tokens(after, path: path, shouldCancel: { request.isCancelled }) : []
      guard !request.isCancelled else { return }
      DispatchQueue.main.async {
        guard let self else { return }
        self.completedDiffCalculations += 1
        guard self.token == current, !request.isCancelled else { return }
        self.pendingCalculation = nil
        if needsSyntax {
          self.leftSyntax = leftTokens; self.rightSyntax = rightTokens; self.syntaxReady = true
        }
        self.calculatedWhitespace = ignore
        self.setDiff(diff)
      }
    }
  }
  func numberOfRows(in tableView: NSTableView) -> Int {
    unified ? (tableView === table ? unifiedCache.count : 0) : sourceRows(in: tableView).count
  }
  struct UnifiedLine {
    let text: String
    let left: Int?
    let right: Int?
    let kind: DiffLine.Kind
    let sourceIndex: Int
  }
  private var unifiedCache: [UnifiedLine] = []
  func unifiedLines() -> [UnifiedLine] { unifiedCache }
  func buildUnifiedLines() -> [UnifiedLine] {
    var result: [UnifiedLine] = []
    for (sourceIndex, line) in (diff?.rows ?? []).enumerated() {
      if line.kind == .unchanged {
        result.append(
          UnifiedLine(
            text: "  " + (line.right ?? ""), left: line.leftNumber, right: line.rightNumber,
            kind: .unchanged, sourceIndex: sourceIndex))
      } else {
        if let text = line.left {
          result.append(
            UnifiedLine(text: "− " + text, left: line.leftNumber, right: nil, kind: .removed, sourceIndex: sourceIndex))
        }
        if let text = line.right {
          result.append(
            UnifiedLine(text: "+ " + text, left: nil, right: line.rightNumber, kind: .added, sourceIndex: sourceIndex))
        }
      }
    }
    return result
  }
  private func sourceRows(in codeTable: NSTableView) -> [Int] {
    codeTable === rightTable || !mainIsLeft ? rightRows : leftRows
  }
  func selectedText(left: Bool) -> String { selectedText(left: left, in: table) }
  func selectedText(left: Bool, in codeTable: NSTableView) -> String {
    codeTable.selectedRowIndexes.compactMap { index -> String? in
      if unified {
        guard unifiedCache.indices.contains(index) else { return nil }
        let line = unifiedCache[index]
        guard left ? line.left != nil : line.right != nil else { return nil }
        return String(line.text.dropFirst(2))
      }
      let indices = sourceRows(in: codeTable)
      guard indices.indices.contains(index), let diff else { return nil }
      if indices[index] < 0 { return "" }
      let row = diff.rows[indices[index]]
      return left ? row.left : row.right
    }.joined(separator: "\n")
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard let codeTable = notification.object as? NSTableView else { return }
    refreshGeometry()
    codeTable.enumerateAvailableRowViews { row, index in
      for case let cell as DiffCell in row.subviews { cell.selected = !((codeTable as? DiffTable)?.navigationOnlySelection ?? false) && codeTable.selectedRowIndexes.contains(index) }
    }
  }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row rowIndex: Int) -> NSView? {
    let id = tableColumn?.identifier.rawValue ?? ""
    let unified = self.unified
    let number = id == "ln" || id == "rn"
    var text = "", background = DiffPalette.background
    var tokens: [DiffSyntax.Token] = []
    var inline: [NSRange] = []
    var emphasis = Theme.diffModified
    func syntax(_ left: Bool, _ line: Int?) -> [DiffSyntax.Token] {
      let source = left ? leftSyntax : rightSyntax
      guard let line, source.indices.contains(line - 1) else { return [] }
      return source[line - 1]
    }
    if unified {
      guard unifiedCache.indices.contains(rowIndex) else { return nil }
      let line = unifiedCache[rowIndex]
      text = id == "ln" ? line.left.map(String.init) ?? "" : id == "rn" ? line.right.map(String.init) ?? "" : line.text
      if line.kind == .removed { background = Theme.diffRemoved }
      if line.kind == .added { background = DiffPalette.added }
      if !number, let source = diff?.rows[line.sourceIndex], source.kind == .modified,
        let a = source.left, let b = source.right {
        let ranges = DiffSyntax.changedSegments(a, b)
        inline = (line.right == nil ? ranges.0 : ranges.1).map {
          NSRange(location: $0.location + 2, length: $0.length)
        }
        emphasis = line.right == nil ? Theme.red : Theme.green
      }
      tokens = syntax(line.right == nil, line.right ?? line.left).map {
        DiffSyntax.Token(range: NSRange(location: $0.range.location + 2, length: $0.range.length), kind: $0.kind)
      }
    } else {
      let indices = sourceRows(in: tableView)
      guard let rows = diff?.rows, indices.indices.contains(rowIndex) else { return nil }
      let leftSide = tableView === table && mainIsLeft
      let source = indices[rowIndex] >= 0 ? rows[indices[rowIndex]] : nil
      let textLeft = source?.left ?? (indices[rowIndex] < 0 && leftSide ? "" : nil)
      let textRight = source?.right ?? (indices[rowIndex] < 0 && !leftSide ? "" : nil)
      let numberLeft = source?.leftNumber ?? (leftSide ? rowIndex + 1 : nil)
      let numberRight = source?.rightNumber ?? (!leftSide ? rowIndex + 1 : nil)
      let hunk = DiffHunk.containing(rowIndex, in: hunks, left: leftSide)
      let kind: DiffLine.Kind = hunk.map { !$0.left.isEmpty && !$0.right.isEmpty ? .modified : leftSide ? .removed : .added } ?? .unchanged
      let left = id == "left" || id == "ln"
      text = number ? (left ? numberLeft : numberRight).map(String.init) ?? "" : (left ? textLeft : textRight) ?? ""
      if kind != .unchanged {
        background = (left ? textLeft : textRight) == nil ? Theme.diffGap : kind == .modified ? Theme.diffModified : left ? Theme.diffRemoved : DiffPalette.added
      }
      tokens = syntax(left, left ? numberLeft : numberRight)
      if !number, kind == .modified, let a = textLeft, let b = textRight {
        let ranges = DiffSyntax.changedSegments(a, b)
        inline = left ? ranges.0 : ranges.1
        emphasis = left ? Theme.red : Theme.green
      }
    }
    let identifier = NSUserInterfaceItemIdentifier("diff-" + id)
    let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? DiffCell ?? DiffCell()
    cell.identifier = identifier
    cell.textInset = number ? 3 : tableView === rightTable ? 2 : split ? 17 : 18
    cell.baseColor = background
    cell.selected = !((tableView as? DiffTable)?.navigationOnlySelection ?? false) && tableView.selectedRowIndexes.contains(rowIndex)
    cell.field.alignment = number ? .right : .left
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = number ? .right : .left
    paragraph.lineBreakMode = .byClipping
    let styled = NSMutableAttributedString(string: text, attributes: [
      .paragraphStyle: paragraph,
      .font: DiffFont.regular(compact ? 12 : 13),
      .foregroundColor: number ? DiffPalette.gutter : DiffPalette.text,
    ])
    if !number {
      for token in tokens where NSMaxRange(token.range) <= styled.length {
        styled.addAttribute(.foregroundColor, value: DiffSyntax.color(token.kind), range: token.range)
        if token.kind == .heading {
          let font = DiffFont.italic(compact ? 12 : 13)
          styled.addAttribute(.font, value: font, range: token.range)
        }
      }
      for range in inline where NSMaxRange(range) <= styled.length {
        styled.addAttribute(.backgroundColor, value: emphasis.withAlphaComponent(0.28), range: range)
      }
      let query = search.stringValue
      if !query.isEmpty {
        let source = text as NSString
        var remainder = NSRange(location: 0, length: source.length)
        while remainder.length > 0 {
          let match = source.range(of: query, options: .caseInsensitive, range: remainder)
          if match.location == NSNotFound { break }
          styled.addAttribute(.backgroundColor, value: Theme.yellow.withAlphaComponent(0.3), range: match)
          remainder = NSRange(location: NSMaxRange(match), length: source.length - NSMaxRange(match))
        }
      }
    }
    cell.field.toolTip = nil
    cell.field.attributedStringValue = styled
    return cell
  }
  func navigate(_ direction: Int) {
    guard !hunks.isEmpty else { return }
    let index = changedIndex < 0 ? (direction < 0 ? hunks.count - 1 : 0) : (changedIndex + direction + hunks.count) % hunks.count
    showHunk(index)
  }
  func showHunk(_ index: Int) {
    guard hunks.indices.contains(index) else { return }
    changedIndex = index
    table.navigationOnlySelection = true; rightTable.navigationOnlySelection = true
    let hunk = hunks[index]
    if unified {
      let sources = Set((diff?.changes[index] ?? 0)..<(index + 1 < hunks.count ? diff!.changes[index + 1] : diff!.rows.count))
      if let row = unifiedCache.firstIndex(where: { sources.contains($0.sourceIndex) && $0.kind != .unchanged }) {
        table.scrollRowToVisible(row); table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      }
    } else {
      syncingScroll = true
      for (codeTable, range) in [(table, mainIsLeft ? hunk.left : hunk.right), (rightTable, hunk.right)] {
        guard let scroll = codeTable.enclosingScrollView else { continue }
        let y = max(0, CGFloat(range.lowerBound - 3) * codeTable.rowHeight)
        let maxY = max(0, codeTable.frame.height - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: min(y, maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
        codeTable.selectRowIndexes(range.isEmpty ? IndexSet() : IndexSet(integer: range.lowerBound), byExtendingSelection: false)
      }
      syncingScroll = false; refreshGeometry()
    }
  }
  @objc func findText() {
    table.reloadData(); rightTable.reloadData()
    let query = search.stringValue
    guard !query.isEmpty else { searchQuery = ""; searchCursor = -1; return }
    var matches: [(NSTableView, Int)] = []
    for codeTable in [table, rightTable] where codeTable === table || split {
      for i in 0..<numberOfRows(in: codeTable) {
        let text: String
        if unified { text = unifiedCache[i].text }
        else {
          let sourceIndex = sourceRows(in: codeTable)[i]
          guard sourceIndex >= 0 else { continue }
          let source = diff!.rows[sourceIndex]
          text = (codeTable === rightTable || !mainIsLeft ? source.right : source.left) ?? ""
        }
        if text.localizedCaseInsensitiveContains(query) { matches.append((codeTable, i)) }
      }
    }
    guard !matches.isEmpty else { return }
    if searchQuery != query { searchQuery = query; searchCursor = -1 }
    searchCursor = (searchCursor + 1) % matches.count
    let (codeTable, row) = matches[searchCursor]
    (codeTable as? DiffTable)?.navigationOnlySelection = true
    codeTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    codeTable.scrollRowToVisible(row)
  }

}
final class DiffWindowController: NSWindowController, NSWindowDelegate {
  let controller = DiffViewController()
  let repository: GitRepository
  let files: [FileChange]
  var index: Int
  let commit: Commit?
  let comparison: (String, String)?
  var onClose: (() -> Void)?
  init(
    repository: GitRepository, files: [FileChange], index: Int, commit: Commit?,
    comparison: (String, String)?
  ) {
    self.repository = repository
    self.files = files
    self.index = index
    self.commit = commit
    self.comparison = comparison
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.appearance = nil
    window.minSize = NSSize(width: 750, height: 420)
    super.init(window: window)
    window.contentViewController = controller
    window.delegate = self
    window.center()
    window.isReleasedWhenClosed = false
    controller.nextFile = { [weak self] in self?.move(1) }
    controller.previousFile = { [weak self] in self?.move(-1) }
    controller.filePicker.addItems(withTitles: files.map(\.path))
    (controller.filePicker.cell as? DiffFilePickerCell)?.caption = "\(files.count) " + (files.count == 1 ? "file" : "files")
    controller.filePicker.isBordered = false
    let caption = (controller.filePicker.cell as? DiffFilePickerCell)?.caption ?? "1 file"
    let captionWidth = (caption as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
    controller.filePicker.widthAnchor.constraint(equalToConstant: max(36, captionWidth + 6)).isActive = true
    controller.filePicker.target = self
    controller.filePicker.action = #selector(selectFile)
    controller.filePicker.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
    load()
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc func selectFile() {
    index = controller.filePicker.indexOfSelectedItem
    load()
  }
  func move(_ offset: Int) {
    index = (index + offset + files.count) % files.count
    load()
  }
  func load() {
    controller.filePicker.selectItem(at: index)
    (controller.filePicker.cell as? DiffFilePickerCell)?.caption = "\(files.count) " + (files.count == 1 ? "file" : "files")
    window?.title = "Repository Diff: \(files[index].path)  (\(index+1) of \(files.count))"
    controller.load(
      repository: repository, change: files[index], commit: commit, comparison: comparison)
  }
  func windowWillClose(_ notification: Notification) { onClose?() }
}

final class ConflictWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
  let result = NSTextView()
  let repository: GitRepository
  let file: FileChange
  var onResolve: (() -> Void)?
  var onClose: (() -> Void)?
  var binaryConflict = false
  var isLoaded = false
  var sideContents: [Int: String] = [:]
  var deletedSides = Set<Int>()
  var selectedSide: Int?
  let queue = DispatchQueue(label: "gitdesk.conflict", qos: .userInitiated)
  init(repository: GitRepository, file: FileChange) {
    self.repository = repository
    self.file = file
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Resolve Conflict: " + file.path
    window.appearance = nil
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    let container = Surface()
    window.contentView = container
    window.center()
    let toolbar = row([
      label(file.path, bold: true), NSView(),
      ActionButton("Accept Ours") { [weak self] in self?.useSide(2) },
      ActionButton("Accept Theirs") { [weak self] in self?.useSide(3) },
      ActionButton("Save and Mark Resolved") { [weak self] in self?.save() },
    ])
    let sides = NSSplitView()
    sides.isVertical = true
    sides.dividerStyle = .thin
    let ours = NSTextView()
    let theirs = NSTextView()
    let oursTitle = label("Ours", bold: true)
    let theirsTitle = label("Theirs", bold: true)
    for (text, title) in [(ours, oursTitle), (theirs, theirsTitle)] {
      text.isEditable = false
      text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
      text.textColor = Theme.text
      text.backgroundColor = Theme.background
      text.textContainerInset = NSSize(width: 10, height: 10)
      sides.addArrangedSubview(
        makePanel(title, body: scrollView(text), height: 28))
    }
    result.isRichText = false
    result.delegate = self
    result.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    result.textColor = Theme.text
    result.backgroundColor = Theme.background
    result.textContainerInset = NSSize(width: 10, height: 10)
    result.setAccessibilityLabel("Merged Result")
    let resultView = makePanel(
      label("Merged result — edit conflict markers, then save", color: Theme.blue),
      body: scrollView(result), height: 28)
    let vertical = NSSplitView()
    vertical.isVertical = false
    vertical.dividerStyle = .thin
    vertical.addArrangedSubview(sides)
    vertical.addArrangedSubview(resultView)
    pin(makePanel(toolbar, body: vertical), to: container)
    container.layoutSubtreeIfNeeded()
    vertical.setPosition(vertical.bounds.height * 0.45, ofDividerAt: 0)
    sides.setPosition(sides.bounds.width * 0.5, ofDividerAt: 0)
    result.string = "Loading conflict…"
    queue.async { [weak self] in
      do {
        let a = try repository.conflictContents(file, side: .ours)
        let b = try repository.conflictContents(file, side: .theirs)
        let current = try repository.readWorkingFile(file.path)
        DispatchQueue.main.async {
          self?.isLoaded = true
          self?.deletedSides = Set([(2, a), (3, b)].compactMap { $0.1 == nil ? $0.0 : nil })
          oursTitle.stringValue = a == nil ? "Ours (deleted)" : "Ours"
          theirsTitle.stringValue = b == nil ? "Theirs (deleted)" : "Theirs"
          let data = [a, b, current].compactMap { $0 }
          if data.contains(where: { $0.contains(0) || String(data: $0, encoding: .utf8) == nil }) {
            self?.binaryConflict = true
            self?.result.isEditable = false
            self?.result.string =
              "Binary conflict. Use Accept Ours / Accept Theirs in the Local Changes context menu."
            return
          }
          ours.string = String(decoding: a ?? Data(), as: UTF8.self)
          theirs.string = String(decoding: b ?? Data(), as: UTF8.self)
          self?.sideContents = [2: ours.string, 3: theirs.string]
          self?.result.string = String(decoding: current, as: UTF8.self)
        }
      } catch { DispatchQueue.main.async { self?.result.string = error.localizedDescription } }
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  func windowWillClose(_ notification: Notification) { onClose?() }
  func useSide(_ side: Int) {
    guard isLoaded, !binaryConflict else { return }
    result.string = sideContents[side] ?? ""
    selectedSide = side
  }
  func textDidChange(_ notification: Notification) {
    // Editing after accepting a deleted side explicitly creates a new result.
    selectedSide = nil
  }
  func save() {
    guard isLoaded, !binaryConflict else { return }
    if result.string.components(separatedBy: "\n").contains(where: {
      $0.hasPrefix("<<<<<<< ") || $0 == "=======" || $0.hasPrefix(">>>>>>> ")
    }) {
      let alert = NSAlert()
      alert.messageText = "Conflict markers remain"
      alert.informativeText = "Remove all conflict markers before marking this file resolved."
      alert.runModal()
      return
    }
    let content = result.string
    let deletion = selectedSide.flatMap { deletedSides.contains($0) ? ConflictSide(rawValue: $0) : nil }
    queue.async { [weak self] in
      guard let self else { return }
      do {
        if let deletion { try self.repository.acceptConflicts([self.file], side: deletion) }
        else { try self.repository.saveConflict(self.file, contents: Data(content.utf8)) }
        DispatchQueue.main.async {
          self.onResolve?()
          self.close()
        }
      } catch {
        DispatchQueue.main.async {
          let alert = NSAlert()
          alert.messageText = "Could not resolve conflict"
          alert.informativeText = error.localizedDescription
          alert.runModal()
        }
      }
    }
  }
}
