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
  let table = NSTableView()
  let titleLabel = label("Diff", bold: true)
  let countLabel = label("", color: Theme.muted, size: 12)
  let leftLabel = label("HEAD", color: Theme.muted, size: 12)
  let rightLabel = label("Working Tree", color: Theme.muted, size: 12)
  let emptyLabel = label("", color: Theme.muted)
  let layoutToggle = NSSegmentedControl(
    labels: ["Side-by-side", "Unified"], trackingMode: .selectOne, target: nil, action: nil)
  let whitespace = NSButton(checkboxWithTitle: "Ignore whitespace", target: nil, action: nil)
  let search = NSSearchField()
  let queue = DispatchQueue(label: "gitdesk.diff", qos: .userInitiated, autoreleaseFrequency: .workItem)
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
  var compact = false
  override func loadView() {
    view = Surface()
    configureTable(table)
    table.rowHeight = 22
    table.selectionHighlightStyle = .none
    table.delegate = self
    table.dataSource = self
    table.setAccessibilityLabel("Side-by-side diff")
    table.columnAutoresizingStyle = .noColumnAutoresizing
    layoutToggle.selectedSegment = compact ? 1 : 0
    if compact { layoutToggle.setLabel("Split", forSegment: 0) }
    layoutToggle.target = self
    layoutToggle.action = #selector(optionsChanged)
    layoutToggle.controlSize = .small
    whitespace.font = .systemFont(ofSize: 11)
    whitespace.target = self
    whitespace.action = #selector(optionsChanged)
    whitespace.contentTintColor = Theme.text
    styleCheckbox(whitespace)
    search.placeholderString = "Find in diff"
    search.target = self
    search.action = #selector(findText)
    search.widthAnchor.constraint(equalToConstant: compact ? 95 : 140).isActive = true
    let navigation: [NSView] = [
        ActionButton(symbol: "arrow.up", tooltip: "Previous Difference", size: compact ? 20 : 30) { [weak self] in
          self?.navigate(-1)
        },
        ActionButton(symbol: "arrow.down", tooltip: "Next Difference", size: compact ? 20 : 30) { [weak self] in
          self?.navigate(1)
        },
        ActionButton(symbol: "chevron.left", tooltip: "Previous File", size: compact ? 20 : 30) { [weak self] in
          self?.previousFile?()
        },
        ActionButton(symbol: "chevron.right", tooltip: "Next File", size: compact ? 20 : 30) { [weak self] in
          self?.nextFile?()
        }]
    let toolbar: NSStackView
    let options: NSStackView
    if compact {
      titleLabel.lineBreakMode = .byTruncatingMiddle
      titleLabel.usesSingleLineMode = true
      countLabel.isHidden = true
      whitespace.title = "Whitespace"
      styleCheckbox(whitespace)
      whitespace.setAccessibilityLabel("Ignore whitespace")
      whitespace.toolTip = "Ignore whitespace when comparing changes"
      whitespace.translatesAutoresizingMaskIntoConstraints = false
      whitespace.widthAnchor.constraint(equalToConstant: 90).isActive = true
      whitespace.heightAnchor.constraint(equalToConstant: 22).isActive = true
      toolbar = NSStackView(views: [row([titleLabel, NSView()]),
        row(navigation + [NSView(), layoutToggle], spacing: 2)])
      toolbar.orientation = .vertical
      toolbar.distribution = .fillEqually
      toolbar.alignment = .width
      toolbar.spacing = 2
      options = NSStackView(views: [row([leftLabel, NSView(), rightLabel]),
        row([whitespace, NSView(), search], spacing: 4)])
      options.orientation = .vertical
      options.distribution = .fillEqually
      options.alignment = .width
      options.spacing = 2
    } else {
      toolbar = row(navigation + [titleLabel, NSView(), countLabel, layoutToggle], spacing: 4)
      options = row([
        leftLabel, NSView(), labeledCheckbox(whitespace, title: "Ignore whitespace"), search,
        NSView(), rightLabel,
      ], spacing: 10)
    }
    let container = Surface()
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    options.translatesAutoresizingMaskIntoConstraints = false
    let scroll = scrollView(table)
    scroll.contentView.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(viewportChanged), name: NSView.frameDidChangeNotification,
      object: scroll.contentView)
    scroll.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(toolbar)
    container.addSubview(options)
    container.addSubview(scroll)
    pin(container, to: view)
    NSLayoutConstraint.activate([
      toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
      toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
      toolbar.topAnchor.constraint(equalTo: container.topAnchor),
      toolbar.heightAnchor.constraint(equalToConstant: compact ? 56 : 40),
      options.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      options.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
      options.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
      options.heightAnchor.constraint(equalToConstant: compact ? 48 : 32),
      scroll.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 1),
      scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(emptyLabel)
    NSLayoutConstraint.activate([
      emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
    configureColumns()
  }
  override func viewDidLayout() {
    super.viewDidLayout()
    fitColumnsToViewport()
  }
  private func fitColumnsToViewport() {
    guard let scroll = table.enclosingScrollView else { return }
    let width = scroll.contentSize.width
    guard width > 100 else { return }
    let textColumnCount = layoutToggle.selectedSegment == 1 ? 1 : 2
    let textWidth = max(80, (width - 90) / CGFloat(textColumnCount))
    for column in table.tableColumns {
      let isNumber = column.identifier.rawValue == "ln" || column.identifier.rawValue == "rn"
      let desired = isNumber ? 45 : textWidth
      if abs(column.width - desired) > 0.5 { column.width = desired }
    }
    if abs(table.frame.width - width) > 0.5 {
      table.setFrameSize(NSSize(width: width, height: table.frame.height))
    }
  }
  @objc private func viewportChanged(_ notification: Notification) {
    fitColumnsToViewport()
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
    calculatedWhitespace = nil
    requestedWhitespace = nil
    before = Data()
    after = Data()
    diff = nil
    unifiedCache = []
    table.reloadData()
    titleLabel.stringValue = "Diff"
    titleLabel.toolTip = nil
    countLabel.stringValue = ""
    leftLabel.stringValue = ""
    rightLabel.stringValue = ""
    changedIndex = -1
    emptyLabel.stringValue = "Select a file to view its changes"
    emptyLabel.isHidden = false
  }
  func configureColumns() {
    for column in table.tableColumns { table.removeTableColumn(column) }
    let unified = layoutToggle.selectedSegment == 1
    for (id, width) in unified
      ? [("ln", 50.0), ("rn", 50), ("unified", 800)]
      : [("ln", 50.0), ("left", 430), ("rn", 50), ("right", 430)]
    {
      let column = NSTableColumn(identifier: .init(id))
      column.width = width
      column.minWidth = id == "ln" || id == "rn" ? 45 : 80
      column.resizingMask = []
      table.addTableColumn(column)
    }
    table.reloadData()
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
    calculatedWhitespace = nil
    requestedWhitespace = nil
    before = Data()
    after = Data()
    diff = nil
    unifiedCache = []
    table.reloadData()
    titleLabel.stringValue = change.path
    titleLabel.toolTip = change.path
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
    if rebuildUnified { unifiedCache = buildUnifiedLines() }
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
    table.scrollRowToVisible(0)
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
    requestedWhitespace = ignore
    scheduledDiffCalculations += 1
    queue.async { [weak self] in
      guard !request.isCancelled else { return }
      guard let diff = TextDiff(before: before, after: after, ignoreWhitespace: ignore,
        shouldCancel: { request.isCancelled }) else { return }
      DispatchQueue.main.async {
        guard let self else { return }
        self.completedDiffCalculations += 1
        guard self.token == current, !request.isCancelled else { return }
        self.pendingCalculation = nil
        self.calculatedWhitespace = ignore
        self.setDiff(diff)
      }
    }
  }
  func numberOfRows(in tableView: NSTableView) -> Int {
    layoutToggle.selectedSegment == 1 ? unifiedLines().count : diff?.rows.count ?? 0
  }
  struct UnifiedLine {
    let text: String
    let left: Int?
    let right: Int?
    let kind: DiffLine.Kind
  }
  private var unifiedCache: [UnifiedLine] = []
  func unifiedLines() -> [UnifiedLine] { unifiedCache }
  func buildUnifiedLines() -> [UnifiedLine] {
    var result: [UnifiedLine] = []
    for line in diff?.rows ?? [] {
      if line.kind == .unchanged {
        result.append(
          UnifiedLine(
            text: "  " + (line.right ?? ""), left: line.leftNumber, right: line.rightNumber,
            kind: .unchanged))
      } else {
        if let text = line.left {
          result.append(
            UnifiedLine(text: "− " + text, left: line.leftNumber, right: nil, kind: .removed))
        }
        if let text = line.right {
          result.append(
            UnifiedLine(text: "+ " + text, left: nil, right: line.rightNumber, kind: .added))
        }
      }
    }
    return result
  }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row rowIndex: Int)
    -> NSView?
  {
    let id = tableColumn?.identifier.rawValue ?? ""
    let container = Surface()
    let text: String
    var background = Theme.background
    var color = Theme.text
    if layoutToggle.selectedSegment == 1 {
      let lines = unifiedLines()
      guard rowIndex < lines.count else { return nil }
      let line = lines[rowIndex]
      text =
        id == "ln"
        ? line.left.map(String.init) ?? ""
        : id == "rn" ? line.right.map(String.init) ?? "" : line.text
      if line.kind == .removed {
        background = Theme.diffRemoved
      } else if line.kind == .added {
        background = Theme.diffAdded
      }
    } else {
      guard let rows = diff?.rows, rowIndex < rows.count else { return nil }
      let line = rows[rowIndex]
      text =
        id == "ln"
        ? line.leftNumber.map(String.init) ?? ""
        : id == "rn"
          ? line.rightNumber.map(String.init) ?? ""
          : id == "left" ? line.left ?? "" : line.right ?? ""
      if line.kind != .unchanged {
        if id == "left" || id == "ln" {
          background =
            line.left == nil
            ? Theme.diffGap
            : line.kind == .modified ? Theme.diffModified : Theme.diffRemoved
        } else {
          background =
            line.right == nil
            ? Theme.diffGap
            : line.kind == .modified ? Theme.diffModified : Theme.diffAdded
        }
      }
    }
    if id == "ln" || id == "rn" { color = Theme.muted }
    container.fillColor = background
    let field = label(text, color: color, size: 12)
    field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    field.isSelectable = true
    field.lineBreakMode = .byClipping
    if id == "ln" || id == "rn" { field.alignment = .right }
    pin(field, to: container, inset: 3)
    if id == "left" || id == "right" || id == "unified" {
      let styled = NSMutableAttributedString(
        string: text, attributes: [.font: field.font!, .foregroundColor: color])
      let patterns: [(String, NSColor)] = [
        (
          "\\b(import|struct|class|enum|func|let|var|public|private|return|if|else|guard|throw|try|case|switch|nil|true|false|self)\\b",
          Theme.keyword
        ), ("\"[^\"]*\"", Theme.string), ("//.*$", Theme.muted),
      ]
      if titleLabel.stringValue.hasSuffix(".swift") || titleLabel.stringValue.hasSuffix(".java") {
        for (pattern, color) in patterns {
          if let regex = try? NSRegularExpression(pattern: pattern) {
            for match in regex.matches(
              in: text, range: NSRange(location: 0, length: (text as NSString).length))
            { styled.addAttribute(.foregroundColor, value: color, range: match.range) }
          }
        }
      } else if text.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        && titleLabel.stringValue.hasSuffix(".md")
      {
        styled.addAttribute(
          .foregroundColor, value: Theme.heading,
          range: NSRange(location: 0, length: styled.length))
      }
      field.attributedStringValue = styled
    }
    return container
  }
  func navigate(_ direction: Int) {
    let indices: [Int] =
      layoutToggle.selectedSegment == 1
      ? unifiedCache.indices.filter {
        unifiedCache[$0].kind != .unchanged && ($0 == 0 || unifiedCache[$0 - 1].kind == .unchanged)
      } : diff?.changes ?? []
    guard !indices.isEmpty else { return }
    changedIndex = (changedIndex + direction + indices.count) % indices.count
    table.scrollRowToVisible(indices[changedIndex])
    table.selectRowIndexes(IndexSet(integer: indices[changedIndex]), byExtendingSelection: false)
  }
  @objc func findText() {
    guard !search.stringValue.isEmpty else { return }
    let query = search.stringValue
    if layoutToggle.selectedSegment == 1,
      let i = unifiedLines().firstIndex(where: { $0.text.localizedCaseInsensitiveContains(query) })
    {
      table.scrollRowToVisible(i)
    } else if let i = diff?.rows.firstIndex(where: {
      ($0.left ?? "").localizedCaseInsensitiveContains(query)
        || ($0.right ?? "").localizedCaseInsensitiveContains(query)
    }) {
      table.scrollRowToVisible(i)
    }
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
    load()
  }
  required init?(coder: NSCoder) { fatalError() }
  func move(_ offset: Int) {
    index = (index + offset + files.count) % files.count
    load()
  }
  func load() {
    window?.title = "Repository Diff: \(files[index].path)  (\(index+1) of \(files.count))"
    controller.load(
      repository: repository, change: files[index], commit: commit, comparison: comparison)
  }
  func windowWillClose(_ notification: Notification) { onClose?() }
}

final class ConflictWindowController: NSWindowController, NSWindowDelegate {
  let result = NSTextView()
  let repository: GitRepository
  let file: FileChange
  var onResolve: (() -> Void)?
  var onClose: (() -> Void)?
  var binaryConflict = false
  var isLoaded = false
  var sideContents: [Int: String] = [:]
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
    for (text, title) in [(ours, "Ours"), (theirs, "Theirs")] {
      text.isEditable = false
      text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
      text.textColor = Theme.text
      text.backgroundColor = Theme.background
      text.textContainerInset = NSSize(width: 10, height: 10)
      sides.addArrangedSubview(
        makePanel(label(title, bold: true), body: scrollView(text), height: 28))
    }
    result.isRichText = false
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
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        let a = try repository.blob(ref: ":2", path: file.path, limit: 2_000_000)
        let b = try repository.blob(ref: ":3", path: file.path, limit: 2_000_000)
        let current = try repository.readWorkingFile(file.path)
        DispatchQueue.main.async {
          self?.isLoaded = true
          let data = [a, b, current]
          if data.contains(where: { $0.contains(0) || String(data: $0, encoding: .utf8) == nil }) {
            self?.binaryConflict = true
            self?.result.isEditable = false
            self?.result.string =
              "Binary conflict. Use Accept Ours / Accept Theirs in the Local Changes context menu."
            return
          }
          ours.string = String(decoding: a, as: UTF8.self)
          theirs.string = String(decoding: b, as: UTF8.self)
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
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      do {
        try Data(content.utf8).write(
          to: self.repository.workingDirectory.appendingPathComponent(self.file.path),
          options: .atomic)
        try self.repository.stage([self.file])
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
